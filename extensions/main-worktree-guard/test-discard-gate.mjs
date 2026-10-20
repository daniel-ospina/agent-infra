// test-discard-gate.mjs — #709: the effect-keyed working-tree-discard gate (M5).
//
// Why this suite exists: `main-worktree-guard` used to gate *git argv*, so
//   - `git checkout -- <path>` — the 2026-09-10 incident verb — was classified
//     `allow` (pinned by test.mjs:108), and
//   - every destructive-verb arm (`restore`, `checkout .`, `reset --hard`)
//     returned early for linked worktrees (`eff.isWorktree`),
// which is exactly where the `pi -p` review fixers run their mutation probes.
// M4 covers the incident verb only while the hub is DISORDERED (test.mjs:2247).
// #709 adds M5: a discard-family command is blocked when the checkout it
// targets is carrying uncommitted work the discard would destroy — in the hub
// AND in a linked worktree.
//
// Two parts:
//   Part A — pure classification/effect (classify-git.mjs, zero-dep)
//   Part B — behavioral: the REAL index.ts is loaded through
//            ./module-load-hooks.mjs and its registered tool_call handler is
//            driven against a hermetic hub + linked worktree fixture.
//            The env hatches are removed for the duration (mirroring the
//            `pi -p` child env after #617/#623), which is the actor in scope.
//
// Run: node extensions/main-worktree-guard/test-discard-gate.mjs
import { execSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0, fail = 0, skip = 0;
function expect(name, got, expected) {
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${JSON.stringify(got)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
  ok ? pass++ : fail++;
}
function expectTrue(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

// ─────────────────────────────────────────────────────────────────────────
// Part A — pure classification + effect decision
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: extraction + effect decision (classify-git.mjs) ──");

const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { extractWorkingTreeDiscards, discardDestroysWip } = cg;

/** first descriptor for `cmd` (or null). */
const first = (cmd) => extractWorkingTreeDiscards(cmd)[0] ?? null;

// A1: family coverage — every form the issue names must extract.
const FAMILY = [
  ["git checkout -- src/x.ts", "checkout-paths", "paths", ["src/x.ts"], false],
  ["git checkout HEAD -- src/x.ts", "checkout-paths", "paths", ["src/x.ts"], true],
  ["git checkout -- .", "checkout-paths", "paths", ["."], false],
  ["git checkout .", "checkout-paths-bare", "paths", ["."], false],
  ["git checkout -f", "checkout-force", "all", [], false],
  ["git checkout -f main", "checkout-force", "all", ["main"], false],
  ["git restore src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git restore --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git restore -s HEAD src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git switch --discard-changes main", "switch-discard", "all", [], false],
  ["git reset --hard", "reset-hard", "all", [], false],
  ["git reset --hard HEAD~1", "reset-hard", "all", [], false],
  ["git reset --hard -- src/x.ts", "reset-hard-paths", "paths", ["src/x.ts"], true],
  ["git checkout-index -f -- src/x.ts", "checkout-index", "paths", ["src/x.ts"], false],
  ["git checkout-index -a -f", "checkout-index-all", "paths", ["."], false],
  ["git show HEAD:src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
  // Reviewer round-4: slashy revs and the INDEX source are the same revert.
  ["git show refs/heads/main:src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
  ["git show :src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
  // Reviewer round-1 fold-in: prefix spellings, tree-ish+paths without `--`,
  // leading-dash pathspecs, xargs/empty pathspecs, rm/read-tree.
  ["git reset --har", "reset-hard", "all", [], false],
  ["git reset --h", "reset-hard", "all", [], false],
  ["git switch --discard feat", "switch-discard", "all", [], false],
  ["git checkout HEAD src/x.ts", "checkout-treish-paths", "paths", ["src/x.ts"], true],
  ["git checkout -- -dashfile", "checkout-paths", "paths", ["-dashfile"], false],
  ["printf 'a\\n' | xargs git checkout --", "checkout-pathspec-empty", "all", [], false],
  ["git rm -f src/x.ts", "rm-force", "paths", ["src/x.ts"], true],
  ["git read-tree --reset -u HEAD", "read-tree-reset-update", "all", [], true],
  ["git apply -R /tmp/p.patch", "apply-reverse", "all", [], false],
  ["git apply --reverse /tmp/p.patch", "apply-reverse", "all", [], false],
  // Reviewer round-2 fold-in: a surviving `--staged` resets the index from
  // HEAD, so it is tree-sourced; `-p/--patch` is interactive hunk discard.
  ["git restore --source=HEAD --staged --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], true],
  ["git restore --staged --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], true],
  ["git checkout -p src/x.ts", "checkout-patch", "paths", ["src/x.ts"], false],
  ["git checkout --patch src/x.ts", "checkout-patch", "paths", ["src/x.ts"], false],
  ["git checkout -p", "checkout-patch-all", "all", [], false],
  // Reviewer round-3 fold-in: the conflict spellings yield a descriptor (the
  // effect probe + unmerged-skip decide); `checkout-index --stdin`'s target list
  // is runtime-supplied (fail closed); `apply -R3`/`-3R` is the same reverse.
  ["git checkout --ours src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout --theirs src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout -m src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout --merge src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout --conflict=merge src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  // Reviewer round-4: `-2`/`-3` are the numeric `--ours`/`--theirs` stages.
  ["git checkout -2 src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout -3 src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout -2q src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout-index -f --stdin", "checkout-index-stdin", "all", [], false],
  ["git apply -R3 /tmp/p.patch", "apply-reverse", "all", [], true],  // -3 implies --index
  ["git apply -3R /tmp/p.patch", "apply-reverse", "all", [], true],
  // Reviewer round-4: a single bare token is ref-or-path — the pure extractor
  // flags the ambiguity and the handler's `rev-parse` probe decides.
  ["git checkout HEAD~1", "checkout-bare-path", "paths", ["HEAD~1"], false],
];
for (const [cmd, form, scope, pathspecs, fromTree] of FAMILY) {
  const d = first(cmd);
  expectTrue(
    `A1: ${cmd} → ${form}/${scope}${fromTree ? "/tree" : ""}`,
    !!d && d.form === form && d.scope === scope && d.fromTree === !!fromTree &&
      JSON.stringify(d.pathspecs) === JSON.stringify(pathspecs),
    `got ${JSON.stringify(d && { form: d.form, scope: d.scope, pathspecs: d.pathspecs, fromTree: d.fromTree })}`,
  );
}

// A2: NOT in the family — the negative classification surface.
const NOT_FAMILY = [
  "git status",
  "git log --oneline -3",
  "git diff",
  "git checkout -b feat/x",
  "git checkout -",
  "git switch -c feat/x",
  "git reset --soft HEAD~1",
  "git reset --mixed HEAD~1",
  "git clean -fd",              // documented residual: untracked-only
  "git restore --staged src/x.ts", // index-only, non-destructive (#709 note)
  "git restore --stage src/x.ts",  // index-only via unambiguous prefix
  // Reviewer round-3 P1: `--ours`/`--theirs`/`-m`/`--conflict=` are conflict
  // resolution ONLY on an UNMERGED path; on a plain modified file they are a
  // normal index-source checkout. So they DO yield a descriptor and the EFFECT
  // probe decides — the unmerged-skip in `discardDestroysWip` (A3: UU/AA/DD)
  // keeps genuine resolution allowed.
  "ls -la",
  "cat src/x.ts",
  "rg -n foo .",
  // Reviewer round-1/2 fold-in: heredoc DATA bodies and comments are not code.
  "cat <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "# git checkout -- src/x.ts\nls",
  "echo hi # git checkout -- src/x.ts", // mid-line comment (quote-aware)
  "true # git reset --hard",
  // Reviewer round-4 P1: an ESCAPED space before `#` does not start a comment
  // (the `#` is mid-word) — but the inverse case must stay a comment.
  "echo '`git checkout -- src/x.ts`'", // single quotes suppress substitution
  "echo '$(git checkout -- src/x.ts)'",   // …and so does a single-quoted $( )
  "git apply /tmp/p.patch", // forward apply is not a reverse
  "git apply --reject /tmp/p.patch",
  "git apply -R --check /tmp/p.patch",  // round-3: dry-run/report only
  "git apply -R --stat /tmp/p.patch",
  "git rm -f --cached src/x.ts",         // round-3: index-only
  "git rm -nf src/x.ts",                 // round-3: dry-run
  "git checkout-index -f -a --prefix=/tmp/out/", // round-3: exports elsewhere
  "git checkout -m",                     // round-3: switch-with-merge, no path
  "git apply -R --cached /tmp/p.patch",  // round-4: index-only
];
for (const cmd of NOT_FAMILY) {
  expect(`A2: ${cmd.split("\n")[0]} → no discard descriptor`, extractWorkingTreeDiscards(cmd).length, 0);
}

// A2c: a bare single token is REF-OR-PATH — the pure extractor flags it
// `ambiguousRef` so index.ts can run its `rev-parse` probe (reviewer round-4).
for (const tok of ["main", "HEAD~1", "v1.0"]) {
  const d = first(`git checkout ${tok}`);
  expectTrue(`A2c: \`git checkout ${tok}\` → ambiguousRef descriptor`,
    !!d && d.form === "checkout-bare-path" && d.ambiguousRef === true &&
      JSON.stringify(d.pathspecs) === JSON.stringify([tok]),
    `got ${JSON.stringify(d && { form: d.form, pathspecs: d.pathspecs })}`);
}
for (const cmd of ["git checkout ':(glob)**/x.ts'", "git checkout ':(top)x.ts'", "git checkout :/x.ts"]) {
  const d = first(cmd);
  expectTrue(`A2c: ${cmd} → magic pathspec IS a discard`,
    !!d && d.form === "checkout-paths-bare" && d.pathspecs.length === 1,
    `got ${JSON.stringify(d && { form: d.form, pathspecs: d.pathspecs })}`);
}

// A2b: interpreter-fed heredocs and piped-to-shell bodies ARE code.
for (const cmd of [
  "bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "cat <<'EOF' | bash\ngit checkout -- src/x.ts\nEOF",
  "python3 <<PY\nimport subprocess\nsubprocess.run(['git','checkout','--','src/x.ts'])\nPY",
  // `<<` inside a QUOTED string must not open a phantom heredoc and blind the
  // rest of the command (reviewer round-2 P1).
  'echo "a << operator"\ngit checkout -- src/x.ts',
  // Reviewer round-3 P1: SPAWNER-wrapped interpreters still execute the body.
  "env bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "nice bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "nohup bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "command bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "timeout 5 bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "/bin/sh <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "busybox sh <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "cat <<'EOF' | env bash\ngit checkout -- src/x.ts\nEOF",
  "cat <<'EOF' | sudo bash\ngit checkout -- src/x.ts\nEOF",
  // Round-3 P2: backtick substitution + in-command git aliases.
  "`git checkout -- src/x.ts`",
  "echo \"`git checkout -- src/x.ts`\" >/dev/null",
  "git -c alias.z='checkout --' z src/x.ts",
  "git config alias.zz 'checkout --' && git zz src/x.ts",
  // Reviewer round-4: the consumer need not be the FIRST token of the line.
  "true && bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "set -e; bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "cd /tmp && bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  // Reviewer round-4: an apostrophe inside DOUBLE quotes must not hide a later
  // backtick span (double quotes do not stop substitution).
  "echo \"it's\" ; `git checkout -- src/x.ts`",
  // Reviewer round-4: escaped whitespace before `#` is not a comment.
  "echo a\\ #b && git checkout -- src/x.ts",
  // Reviewer round-4: ANSI-C command words are decoded before the walk.
  "$'\\x67it' checkout -- src/x.ts",
  "$'git' checkout -- src/x.ts",
  // Reviewer round-5: a data heredoc no longer eats the NEXT command word
  // (the delimiter is re-emitted for the walker's `<<` + operand skip).
  "cat <<'EOF'\nhello\nEOF\ngit checkout -- src/x.ts",
  // `<<` in ARITHMETIC and inside a multi-line QUOTED string is not a heredoc.
  "(( x = 1 << 2 ))\ngit checkout -- src/x.ts",
  'echo "a\nb << c"\ngit checkout -- src/x.ts',
  // A QUOTED `<<` earlier in the line must not demote the real shell heredoc.
  "echo 'a<<b' && bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  // ANSI-C decoding is restricted to a plain word, so it cannot inject syntax.
  "echo $'\"' ; git checkout -- src/x.ts",
  "echo $'\\x3c\\x3c' x\ngit checkout -- src/x.ts",
  // A QUOTED command substitution still RUNS in bash.
  "echo \"$(git checkout -- src/x.ts)\"",
]) {
  expectTrue(`A2b: ${cmd.split("\n")[0]} → discard IS detected`,
    extractWorkingTreeDiscards(cmd).length > 0, true);
}

// A2c: hidden-pathspec forms carry a fail-closed marker.
for (const cmd of ["git checkout --pathspec-from-file=/tmp/p", "git restore --pathspec-from-file=/tmp/p", "git checkout-index -f --pathspec-from-file=/tmp/p"]) {
  const d = first(cmd);
  expectTrue(`A2c: ${cmd} → unverifiable (fail closed)`, !!d && d.unverifiable === true, JSON.stringify(d));
}

// A2d: non-static INDIRECTION fails closed rather than sailing past the
// verb-keyed switch (reviewer round-5 P1/P2).
for (const cmd of [
  'f() { git "$@"; }; f checkout -- src/x.ts',
  'f() { git "$@"; }; f restore src/x.ts',
  "printf 'src/x.ts\\n' | xargs git checkout",
  "find . -name src -exec git checkout-index -f {} \\;",
  "bash <<< 'git checkout -- src/x.ts'",
  "bash <(printf 'git checkout -- src/x.ts')",
  "bash < <(printf 'git checkout -- src/x.ts')",
]) {
  const d = first(cmd);
  expectTrue(`A2d: ${cmd} → fail-closed descriptor`,
    !!d && (d.unverifiable === true || d.form === "feeder-pathspec" || d.pathspecs.some((p) => String(p).includes("{}"))), JSON.stringify(d));
}

// A2e: a NEWLINE is a word boundary, so a `#` on the line AFTER a code line is
// still a COMMENT — and a comment cannot open a quote that hides the code below
// it. `atWordStart` used to be part of the carried state, so whether a leading
// `#` was a comment depended on the character the PREVIOUS line ended with.
// Measured on `scripts/checkout-hygiene/hub-worktree.sh` (2026-10-19, #1949):
//
//     166  fi                 ← ends on a word character
//     167  (blank)
//     168  # The branch-name checks are create/salvage-only: …
//     169  # advances the hub's own main.       ← its apostrophe opens a quote
//     …    (further re-opens at 222 / 242 / 463 keep the state desynced)
//     476  target="$(git -C "$MAIN_REPO" show "HEAD:$rest" …)"
//     488  rm -f …; git -C "$MAIN_REPO" show "HEAD:$rest" > "$MAIN_REPO/$rest"
//
// 168–169 were scanned as CODE and the resulting phantom quote left 464–509
// (both `git show "HEAD:$rest"` lines) inside a quoted region, so the extractor
// reported ZERO `cat-file-revert` descriptors for that 725-line recovery helper.
// The M5 walk then read a COPY of it as discard-free and ALLOWED it in a DIRTY
// checkout — the #1139 fail-open whose pins (B12b2 / C1 below) are the RED that
// caught it. Removing the one apostrophe does NOT restore detection (the later
// re-opens still desync it): the defect is the carried word start, not the
// apostrophe. The mirror direction is a false BLOCK — a commented-out discard
// on the line after a code line harvested as live, which the case below pins.
const APOS_COMMENT = "fi\n# the hub's own main.\ngit checkout -- src/x.ts";
expectTrue("A2e (#1949): a discard below an apostrophe-bearing COMMENT is still found (the newline ends the word, so that `#` line IS a comment)",
  extractWorkingTreeDiscards(APOS_COMMENT).length === 1 && first(APOS_COMMENT)?.pathspecs?.[0] === "src/x.ts",
  JSON.stringify(extractWorkingTreeDiscards(APOS_COMMENT)).slice(0, 240));
expectTrue("A2e (#1949) mirror: a COMMENTED-OUT discard on the line after a code line is NOT harvested (no false block)",
  extractWorkingTreeDiscards("fi\n# git checkout -- src/x.ts\n").length === 0,
  JSON.stringify(extractWorkingTreeDiscards("fi\n# git checkout -- src/x.ts\n")).slice(0, 240));

// A2f/A2g (#2161): TWO MORE WORD BOUNDARIES, each one a fail-OPEN before the
// fix: the `#` stayed in the scanned text, its prose apostrophe opened a phantom
// single-quote state, and everything below it — including a real discard — was
// scanned inside that phantom quote. Both spellings are legal bash and both are
// probe-verified below (rc 0, and the arm/word behaves as the comment says), so
// neither is a hypothetical.
//
// R1 — `)` ENDS A WORD. A `case` arm needs no space after the pattern:
//     x=a; case $x in a)# it's a match … → bash runs the arm body (prints
//     `INSIDE-a`), i.e. everything after `#` on that line is a comment.
const CASE_ARM_COMMENT = "x=a\ncase $x in\n  a)# it's a match\n    echo \"INSIDE-$x\"\n    ;;\nesac\ngit checkout -- src/x.ts";
const caseArmDiscs = extractWorkingTreeDiscards(CASE_ARM_COMMENT);
expectTrue("A2f (#2161 R1): a discard below a `case` arm whose `#` comment needs no leading space is STILL found",
  caseArmDiscs.length === 1 && caseArmDiscs[0]?.pathspecs?.[0] === "src/x.ts",
  JSON.stringify(caseArmDiscs).slice(0, 240));
expectTrue("A2f (#2161 R1) mirror: the same arm with the discard COMMENTED OUT is NOT harvested (no false block)",
  extractWorkingTreeDiscards(CASE_ARM_COMMENT.replace("git checkout -- src/x.ts", "# git checkout -- src/x.ts")).length === 0,
  JSON.stringify(extractWorkingTreeDiscards(CASE_ARM_COMMENT.replace("git checkout -- src/x.ts", "# git checkout -- src/x.ts"))).slice(0, 240));
// R1 boundary — a `)` is NOT always a word end, and this is the direction that
// would HIDE live text if `)` were treated as one unconditionally. Probe-verified
// in bash: `x=$(echo a)#; echo RAN` prints `RAN` (so `#` is LITERAL after a
// substitution close) while `(true)# ; echo HIDDEN` prints nothing (a bare
// subshell close DOES end the word). A scanner that called every `)` a word
// start would swallow the `; git checkout …` tail below and allow a real discard.
expectTrue("A2f2 (#2161 R1 boundary): `#` after a `$( … )` close is LITERAL, so a discard on the same line is still found",
  extractWorkingTreeDiscards("x=$(date)#; git checkout -- src/x.ts").length === 1,
  JSON.stringify(extractWorkingTreeDiscards("x=$(date)#; git checkout -- src/x.ts")).slice(0, 240));
expectTrue("A2f2 (#2161 R1 boundary): `#` after an arithmetic `$(( … ))` close is LITERAL too",
  extractWorkingTreeDiscards("y=$((1+1))#; git checkout -- src/x.ts").length === 1,
  JSON.stringify(extractWorkingTreeDiscards("y=$((1+1))#; git checkout -- src/x.ts")).slice(0, 240));
expectTrue("A2f2 (#2161 R1 boundary) mirror: a bare subshell close DOES end the word, so the text after `#` is a comment",
  extractWorkingTreeDiscards("(true)# ; git checkout -- src/x.ts").length === 0,
  JSON.stringify(extractWorkingTreeDiscards("(true)# ; git checkout -- src/x.ts")).slice(0, 240));
// R2 — `$'it\'s'` is ONE ANSI-C word in bash (`\` escapes the quote; running it
// prints `it's`). The old matcher closed the quote at the escaped `'` and the
// shared tokenizer then held an unclosed quote across the rest of the script.
const ANSI_ESC = "echo $'it\\'s'\ngit checkout -- src/x.ts";
expectTrue("A2g (#2161 R2): a discard below an ANSI-C word with an ESCAPED quote is STILL found",
  extractWorkingTreeDiscards(ANSI_ESC).length === 1,
  JSON.stringify(extractWorkingTreeDiscards(ANSI_ESC)).slice(0, 240));
expectTrue("A2g (#2161 R2) mirror: the ANSI-C word alone produces NO descriptor (it is data, not a discard)",
  extractWorkingTreeDiscards("echo $'it\\'s'\n").length === 0,
  JSON.stringify(extractWorkingTreeDiscards("echo $'it\\'s'\n")).slice(0, 240));

// A2f3 (#2161 R1, review cycle-1 P1): the `)` counter UNDER-COUNTS, because a
// `)` inside a substitution is often LITERAL — a `case` pattern, a `${x:-)}`, a
// backtick region — and no bash parser here can tell it from the closer. On
// those lines the counter reached 0 one `)` early, the REAL closing `)` was
// treated as a word end, and the `#` glued to it was dropped as a comment —
// measured `main=1 head=0` (a fail-open REGRESSION) before the `sawSubst` arm.
// bash ground truth, probe-verified: every tail below RUNS (`LIVE` prints and
// the git command executes), so the `#` is part of the WORD, not a comment. The
// fix is the fail-closed direction: once any substitution was opened on the
// line, no later `)` ends the word, so the worst case is over-scanning (a false
// block), never a missed discard.
const SUBST_LITERAL_PAREN = [
  ["`case` pattern", "f=$(case $x in a) echo hi;; esac)#; LIVE=1; COM@@"],
  ["`${x:-)}` operator", "x=$(echo ${y:-)} )#; LIVE=1; COM@@"],
  ["argument position", "echo $(case $x in a) echo hi;; esac)#; LIVE=1; COM@@"],
];
for (const [label, template] of SUBST_LITERAL_PAREN) {
  const src = template.replace("COM@@", "git checkout -- src/x.ts");
  const discs = extractWorkingTreeDiscards(src);
  expectTrue(`A2f3 (#2161 R1): a LITERAL \`)\` inside \`$( … )\` (${label}) does not swallow the live discard after \`)#\``,
    discs.length === 1 && discs[0]?.pathspecs?.[0] === "src/x.ts",
    JSON.stringify(discs).slice(0, 240));
}
// … and the mirror: the guard must not over-correct into "`#` is never a comment
// after a `)`", so a line with NO substitution still ends the word at `)` —
// `(true)# <discard>` prints nothing in bash, i.e. `#` really IS a comment there.
const noSubst = "(true)# ; " + "git checkout -- src/x.ts";
expectTrue("A2f3 (#2161 R1) mirror: with NO substitution on the line a `)` still ends the word, so the `#` is a real comment",
  extractWorkingTreeDiscards(noSubst).length === 0,
  JSON.stringify(extractWorkingTreeDiscards(noSubst)).slice(0, 240));


// A3: effect decision — block iff uncommitted tracked work would be destroyed.
const EFFECT = [
  [" M src/x.ts", { scope: "paths", fromTree: false }, true, "worktree-modified, index source"],
  [" M src/x.ts", { scope: "paths", fromTree: true }, true, "worktree-modified, tree source"],
  ["M  src/x.ts", { scope: "paths", fromTree: false }, false, "staged-only survives `checkout --`"],
  ["M  src/x.ts", { scope: "paths", fromTree: true }, true, "staged-only dies to a tree source"],
  [" D src/x.ts", { scope: "paths", fromTree: false }, true, "worktree-deleted file would be restored"],
  ["D  src/x.ts", { scope: "paths", fromTree: false }, false, "staged-only delete survives `checkout --`"],
  ["?? new.txt", { scope: "paths", fromTree: false }, false, "untracked-only dirt"],
  ["?? new.txt", { scope: "all", fromTree: false }, false, "untracked-only dirt (all scope)"],
  [" M src/x.ts", { scope: "all", fromTree: false }, true, "tracked dirt (all scope)"],
  ["", { scope: "all", fromTree: false }, false, "clean tree"],
  // Reviewer round-1 fold-in: unmerged conflict entries are not discarded WIP.
  ["UU e.txt", { scope: "paths", fromTree: false }, false, "unmerged entry (UU) — `checkout --ours`"],
  ["UU e.txt", { scope: "paths", fromTree: true }, false, "unmerged entry (UU) — tree source"],
  ["AA e.txt", { scope: "all", fromTree: false }, false, "unmerged entry (AA)"],
  ["DD e.txt", { scope: "paths", fromTree: true }, false, "unmerged entry (DD)"],
];
for (const [porcelain, d, expected, why] of EFFECT) {
  expect(`A3: ${why}`, discardDestroysWip(porcelain, d), expected);
}

// ─────────────────────────────────────────────────────────────────────────
// Part B — real index.ts load + handler-driven effect tests
// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part B: real index.ts load + handler-driven discard gate ──");

const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];

async function partB() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("B: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
    return;
  }
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...a) => warnings.push(a.map(String).join(" "));
  let mod;
  try { mod = await import(pathToFileURL(INDEX_TS).href); } finally { console.warn = realWarn; }
  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  expect(`B1: index.ts loads with no degradation warning`, degradation.length, 0);
  if (typeof mod.default !== "function") { expectTrue("B2: default export is a factory", false, typeof mod.default); return; }
  pass++; console.log("✅ B2: default export is a factory");

  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  if (typeof toolCall !== "function") { expectTrue("B3: factory registered a tool_call handler", false, "none"); return; }
  pass++; console.log("✅ B3: factory registered a tool_call handler");

  // Hermetic hub + linked worktree (realpath: macOS /var → /private/var — the
  // guard realpaths its toplevel, and the marker realpath check needs it too).
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "discard-gate-")));
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const wt2 = join(tmp, "wt2");
  const home = join(tmp, "home");
  const savedEnv = new Map([...HATCH_VARS, "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"]
    .map((v) => [v, process.env[v]]));
  const prevCwd = process.cwd();
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
  const write = (p, s) => writeFileSync(p, s);

  try {
    sh(`git init -q -b main "${hub}"`, tmp);
    gg("config user.email t@t && git config user.name t", hub);
    write(join(hub, "clean.txt"), "v1\n");
    write(join(hub, "dirty.txt"), "v1\n");
    write(join(hub, "staged.txt"), "v1\n");
    write(join(hub, "-dashfile"), "v1\n");
    gg("add -A && git commit -qm init", hub);
    gg(`worktree add -q -b feat "${wt}"`, hub);
    gg(`worktree add -q -b feat2 "${wt2}"`, hub);
    // A SECOND linked worktree, deliberately DIRTY from the start — B5f below
    // needs a real discard aimed at a tree OTHER than the one the command runs in.
    write(join(wt2, "dirty.txt"), "MUTANT-WT2\n");
    const wtTop = execSync("git rev-parse --show-toplevel", { cwd: wt, encoding: "utf8" }).trim();
    const wtCommon = execSync("git rev-parse --git-common-dir", { cwd: wt, encoding: "utf8" }).trim();
    const wtGit = execSync("git rev-parse --git-dir", { cwd: wt, encoding: "utf8" }).trim();
    expectTrue("B4: `wt` is a real LINKED worktree (git-dir ≠ git-common-dir)",
      wtTop === wt && wtCommon !== wtGit, `top=${wtTop} git=${wtGit} common=${wtCommon}`);
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });

    // The `pi -p` child environment: env hatches stripped (#617/#623), no
    // marker session, HOME pointed at the fixture. SKILL_ENFORCER_DISABLED=1 is
    // set for the run (the child env sets it) — the guard must not care.
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;
    process.env.SKILL_ENFORCER_DISABLED = "1";

    const bash = async (command, cwd) => {
      const prev = process.cwd();
      process.chdir(cwd);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    const allowed = (r) => r === undefined || r === null;
    const blocked = (r) => !!r && r.block === true;

    // ── B5: clean targets / read-only / index-only → ALLOW ──
    expectTrue("B5a: worktree, clean target → `git checkout -- clean.txt` ALLOWED",
      allowed(await bash("git checkout -- clean.txt", wt)), "was blocked");
    expectTrue("B5b: `git restore --staged clean.txt` (index-only) ALLOWED",
      allowed(await bash("git restore --staged clean.txt", wt)), "was blocked");
    for (const cmd of ["ls -la", "cat clean.txt", "git status", "git log --oneline -2", "git diff", "rg -n v1 .", "grep -n v1 clean.txt"]) {
      const r = await bash(cmd, wt);
      expectTrue(`B5c: read-only negative — \`${cmd}\` ALLOWED`, allowed(r), `blocked: ${r?.reason?.slice(0, 120)}`);
    }

    // ── #1210 / #1229: an unreadable script ALWAYS fails closed, and says WHY honestly.
    //
    // An unreadable path means the discard target is UNKNOWN, not "nothing": the
    // script may discard in ANY checkout, so a clean session tree does not entail
    // "nothing to lose". The block therefore stays; what changes is only its
    // MESSAGE, which must not name a state the arm never measured.
    //
    // B5d is the fail-closed pin: it must block, and its reason must NOT claim
    // the checkout is dirty (it provably is not — this runs before any dirtying).
    const cleanUndoEarly = join(tmp, "undo-clean-early.sh");
    write(cleanUndoEarly, "git checkout -- clean.txt\n");
    const indefClean = await bash(`S=${cleanUndoEarly}; bash $S`, wt);
    expectTrue("B5d: CLEAN tree + unresolvable script path → BLOCKED (unreadable ⇒ unverifiable ⇒ fail closed)",
      blocked(indefClean),
      "was allowed — an unreadable script's discard target is UNKNOWN, not nothing");
    expectTrue("B5d2: its reason does NOT assert a state claim that was never observed",
      !/carries\s+uncommitted changes/.test(indefClean?.reason ?? "") &&
      /not statically resolvable/.test(indefClean?.reason ?? ""),
      `reason=${JSON.stringify(indefClean?.reason ?? "").slice(0, 300)}`);

    // B5d3 is the mutation pin for the MESSAGE. The pre-fix string ("the script
    // path is not statically resolvable — it is built at runtime …") satisfies
    // B5d and B5d2, so those two pin nothing; this additionally requires the
    // OBSERVED text (a `$` or backtick in the path) and the remedy — neither of
    // which the old message carries.
    const reasonClean = indefClean?.reason ?? "";
    expectTrue("B5d3: the reason names the observed text and the remedy, not an inferred cause",
      /contains a \$ or a backtick/.test(reasonClean) &&
      /pass the path literally/.test(reasonClean) &&
      /bash \.\/tools\/your-script\.sh/.test(reasonClean),
      `reason=${JSON.stringify(reasonClean).slice(0, 300)}`);

    // The converse: the SAME shape with a DIRTY target must ALSO block — this is
    // what stops the block being satisfied by an accident of the clean fixture.
    write(join(wt, "dirty.txt"), "MUTANT-EARLY\n");
    expectTrue("B5e: DIRTY target + the same unresolvable script path → STILL BLOCKED (no fail-open)",
      blocked(await bash(`S=${cleanUndoEarly}; bash $S`, wt)),
      "was allowed — an unreadable script must never let a real discard through");
    // Restore the committed content so the B6 sequence below starts from clean.
    write(join(wt, "dirty.txt"), "v1\n");

    // B5f: an unresolvable script path plus a discard-shaped command must not be
    // silently allowed. The session tree is CLEAN here, so this also pins that the
    // refusal is not an accident of a dirty fixture; `wt2` is a DIFFERENT dirty
    // worktree that the command really does discard.
    expectTrue("B5f: CLEAN session tree + indirection + discard against a DIFFERENT dirty worktree → BLOCKED (not silently allowed)",
      blocked(await bash(`S=${cleanUndoEarly}; bash $S; git -C ${wt2} checkout -- dirty.txt`, wt)),
      "was allowed — an unresolvable script path does not excuse an accompanying discard");

    // ── B6: DIRTY tracked target in a LINKED WORKTREE → BLOCK (the #709 core) ──
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const core = await bash("git checkout -- dirty.txt", wt);
    expectTrue("B6a: worktree + dirty target → `git checkout -- <file>` BLOCKED (#709)",
      blocked(core), JSON.stringify(core)?.slice(0, 200));
    expectTrue("B6b: block reason names the gate + the copy-based probe",
      /#709/.test(core?.reason ?? "") && /COPY/.test(core?.reason ?? ""), String(core?.reason).slice(0, 160));
    // The mutant is still on disk — the gate blocked BEFORE git ran.
    expectTrue("B6c: the working tree is untouched (gate blocked pre-execution)",
      execSync("cat dirty.txt", { cwd: wt, encoding: "utf8" }).trim(), "MUTANT");

    for (const cmd of [
      "git restore dirty.txt",
      "git restore --worktree dirty.txt",
      "git checkout HEAD -- dirty.txt",
      "git checkout .",
      "git checkout -- .",
      "git checkout -f",
      "git reset --hard",
      "git switch --discard-changes feat",
      "git show HEAD:dirty.txt > dirty.txt",
    ]) {
      const r = await bash(cmd, wt);
      expectTrue(`B6d: worktree + dirty target → \`${cmd}\` BLOCKED`, blocked(r), JSON.stringify(r)?.slice(0, 160));
    }

    // ── B6e: script-FILE surface — `bash /tmp/undo.sh` ──
    // The command text carries no verb (`undo.sh`), so only reading the script
    // reveals the discard. M4's _backdoorBlock returns early for worktrees, so
    // this is the one surface a worktree `pi -p` child could otherwise hide in.
    const undo = join(tmp, "undo.sh");
    const undoClean = join(tmp, "undo-clean.sh");
    write(undo, "git checkout -- dirty.txt\n");
    write(undoClean, "git checkout -- clean.txt\n");
    expectTrue("B6e: script-file discard (`bash undo.sh`) BLOCKED",
      blocked(await bash(`bash ${undo}`, wt)), "was allowed");
    expectTrue("B6f: script-file discard on a CLEAN target ALLOWED",
      allowed(await bash(`bash ${undoClean}`, wt)), "was blocked");
    // B6h (#1949): the script-file surface is walked with the SAME quote-aware
    // scan, so a COMMENT carrying an apostrophe must not swallow the discard
    // below it. `dirty.txt` is tracked-dirty in this worktree (B6 above).
    const undoApos = join(tmp, "undo-apos.sh");
    const undoAposCommented = join(tmp, "undo-apos-commented.sh");
    write(undoApos, "set -e\n# revert the hub's own copy\ngit checkout -- dirty.txt\n");
    write(undoAposCommented, "set -e\n# revert the hub's own copy\n# git checkout -- dirty.txt\n");
    expectTrue("B6h (#1949): a script whose COMMENT carries an apostrophe still BLOCKS its real discard",
      blocked(await bash(`bash ${undoApos}`, wt)),
      "was allowed — the comment's apostrophe opened a quote that hid the discard");
    expectTrue("B6h (#1949) control: the same script with the discard COMMENTED OUT is ALLOWED (the fix is not a blanket block)",
      allowed(await bash(`bash ${undoAposCommented}`, wt)), "was blocked");
    rmSync(undoApos, { force: true });
    rmSync(undoAposCommented, { force: true });

    // ── B6k / B6l (#2161): the same LIVE-DISCARD contract for the two word
    // boundaries Part A pins in isolation. Part A proves the extractor finds the
    // discard; these prove the HANDLER still refuses to run it — a fix that made
    // the scan quietly permissive would satisfy Part A and fail here.
    //
    // Both scripts really discard `dirty.txt`, which is tracked and modified in
    // `wt` at this point (B6), so the block is a claim about real WIP. The
    // mutation rows are the honest half: strip the discard's target dirt (or
    // comment the discard out) and the SAME shape must be ALLOWED, so neither
    // pin can be satisfied by an unconditional block.
    const caseArmScript = join(tmp, "undo-case-arm.sh");
    const caseArmClean = join(tmp, "undo-case-arm-clean.sh");
    write(caseArmScript, "set -e\nx=go\ncase $x in\n  go)# it's a match\n    ;;\nesac\ngit checkout -- dirty.txt\n");
    write(caseArmClean, "set -e\nx=go\ncase $x in\n  go)# it's a match\n    ;;\nesac\n# git checkout -- dirty.txt\n");
    expectTrue("B6k (#2161 R1): a script whose `case` arm carries an unspaced `#` comment still BLOCKS its real discard",
      blocked(await bash(`bash ${caseArmScript}`, wt)),
      "was allowed — the arm's comment line was scanned as CODE and its apostrophe hid the discard");
    expectTrue("B6k (#2161 R1) mutation: the SAME shape with the discard removed is ALLOWED (the block is about the discard, not the shape)",
      allowed(await bash(`bash ${caseArmClean}`, wt)), "was blocked — an unconditional block proves nothing");
    rmSync(caseArmScript, { force: true });
    rmSync(caseArmClean, { force: true });

    const ansiScript = join(tmp, "undo-ansi-escaped.sh");
    write(ansiScript, "set -e\necho $'it\\'s a match'\ngit checkout -- dirty.txt\n");
    expectTrue("B6l (#2161 R2): a script containing an ANSI-C word with an escaped quote still BLOCKS its real discard",
      blocked(await bash(`bash ${ansiScript}`, wt)),
      "was allowed — the escaped quote closed the ANSI-C word early and left the rest of the script inside a phantom quote");
    rmSync(ansiScript, { force: true });

    // The mutation the issue asks for, at the level this lane cares about: strip
    // the guard's own detection and the row above goes GREEN in the wrong
    // direction — so pin the DIRECT form too, with no comment and no quoting
    // anywhere: a plain discard of tracked-dirty content is refused. If a later
    // change to the word-boundary scan ever blunts the family, this row fails.
    expectTrue("B6l mutation: a PLAIN `git restore` of tracked-dirty content is still BLOCKED (the gate still bites)",
      blocked(await bash(`git restore ${join(wt, "dirty.txt")}`, wt)),
      "was allowed — the discard family stopped biting");
    rmSync(undo, { force: true });
    rmSync(undoClean, { force: true });

    // ── B6g: reviewer round-1 bypass closures (all real git-destroy paths) ──
    write(join(wt, "-dashfile"), "MUTANT\n");
    const execUndo = join(tmp, "undo-exec.sh");
    write(execUndo, "#!/bin/sh\ngit checkout -- dirty.txt\n");
    execSync(`chmod +x ${execUndo}`);
    // A real patch to reverse (`git diff HEAD` of the dirty file).
    const patch = join(tmp, "revert.patch");
    write(patch, execSync("git diff HEAD -- dirty.txt", { cwd: wt, encoding: "utf8" }));
    // Reviewer round-8 regression guard: the discard verb lives only in a FILE
    // NAME here, so a word-anchored verb test would let these two fail OPEN
    // (`bash -c "$(cat /tmp/checkout-undo.sh)"` really reverts the file).
    const verbPath = join(tmp, "checkout-undo.sh");
    write(verbPath, "git checkout -- dirty.txt\n");
    // Reviewer round-8b: a producer path that names NO verb (`plain-undo.sh`),
    // plus the ANSI-C escaped verb and the arbitrary xargs placeholder.
    const plainVerbPath = join(tmp, "plain-undo.sh");
    write(plainVerbPath, "git checkout -- dirty.txt\n");
    const bypass = [
      ["prefix spelling `git reset --har`", "git reset --har"],
      ["interactive hunk discard (`git checkout -p dirty.txt`)", "git checkout -p dirty.txt"],
      ["code heredoc (`python3 <<PY`)", "python3 <<PY\nimport subprocess\nsubprocess.run(['git','checkout','--','dirty.txt'])\nPY"],
      ["phantom heredoc (`<<` inside a quoted string)", 'echo "a << operator" && git checkout -- dirty.txt'],
      ["`git apply -R <patch>`", `git apply -R ${patch}`],
      ["prefix spelling `git switch --discard feat`", "git switch --discard feat"],
      ["tree-ish+paths without `--` (`git checkout HEAD dirty.txt`)", "git checkout HEAD dirty.txt"],
      ["quote-split verb (`git ch'ec'kout -- dirty.txt`)", "git ch'ec'kout -- dirty.txt"],
      ["`git rm -f dirty.txt`", "git rm -f dirty.txt"],
      ["`git read-tree --reset -u HEAD`", "git read-tree --reset -u HEAD"],
      ["executable shebang script (direct `./undo-exec.sh`)", execUndo],
      ["`eval 'git checkout -- dirty.txt'`", "eval 'git checkout -- dirty.txt'"],
      ["xargs-fed empty pathspec", "printf 'dirty.txt\\n' | xargs git checkout --"],
      ["find -exec placeholder pathspec", "find . -name dirty.txt -exec git checkout -- {} \\;"],
      ["leading-dash pathspec (`git checkout -- -dashfile`)", "git checkout -- -dashfile"],
      // ── reviewer round-3 closures ──
      ["`git checkout --ours` on a plain modified file", "git checkout --ours dirty.txt"],
      ["`git checkout -m` on a plain modified file", "git checkout -m dirty.txt"],
      ["`git checkout --conflict=merge` on a plain modified file", "git checkout --conflict=merge dirty.txt"],
      ["`git checkout-index -f --stdin` (runtime path list)", "printf 'dirty.txt\\n' | git checkout-index -f --stdin"],
      ["`git apply -R3` (digits in the short cluster)", `git apply -R3 ${patch}`],
      ["`git apply -3R <patch>`", `git apply -3R ${patch}`],
      ["backtick substitution (`` `git checkout -- dirty.txt` ``)", "`git checkout -- dirty.txt`"],
      ["in-command git alias (`-c alias.z=…`)", "git -c alias.z='checkout --' z dirty.txt"],
      ["in-command git alias (`config alias.zz … && git zz …`)", "git config alias.zz 'checkout --' && git zz dirty.txt"],
      ["spawner-wrapped shell heredoc (`env bash <<EOF`)", "env bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["spawner-wrapped shell heredoc (`timeout 5 bash <<EOF`)", "timeout 5 bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["piped spawner heredoc (`cat <<EOF | sudo bash`)", "cat <<'EOF' | sudo bash\ngit checkout -- dirty.txt\nEOF"],
      ["absolute-path interpreter (`/bin/sh undo.sh`)", `/bin/sh ${execUndo}`],
      // ── reviewer round-4 closures ──
      ["bare path (`git checkout dirty.txt` — the incident verb without `--`)", "git checkout dirty.txt"],
      ["git magic pathspec (`git checkout ':(glob)**/dirty.txt'`)", "git checkout ':(glob)**/dirty.txt'"],
      ["numeric stage (`git checkout -2 dirty.txt`)", "git checkout -2 dirty.txt"],
      ["non-first heredoc consumer (`true && bash <<EOF`)", "true && bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["non-first heredoc consumer (`set -e; bash <<EOF`)", "set -e; bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["non-first heredoc consumer (`cd <wt> && bash <<EOF`)", `cd ${wt} && bash <<'EOF'\ngit checkout -- dirty.txt\nEOF`],
      ["escaped whitespace before `#` (`echo a\\ #b && git checkout -- dirty.txt`)", "echo a\\ #b && git checkout -- dirty.txt"],
      ["ANSI-C command word (`$'\\x67it' checkout -- dirty.txt`)", "$'\\x67it' checkout -- dirty.txt"],
      ["apostrophe in double quotes before a backtick span", 'echo "it\'s" ; `git checkout -- dirty.txt`'],
      ["index-source revert (`git show :dirty.txt > dirty.txt`)", "git show :dirty.txt > dirty.txt"],
      // `checkout-index -a -f` copies the index over the whole tree — dirty.txt
      // has UNSTAGED changes here, so this is a real destroy.
      ["whole-tree index copy over unstaged work (`git checkout-index -a -f`)", "git checkout-index -a -f"],
      // ── reviewer round-5 closures ──
      ["data heredoc then a discard on a LATER line", "cat <<'EOF'\nhello\nEOF\ngit checkout -- dirty.txt"],
      ["arithmetic shift before a discard (`(( x = 1 << 2 ))`)", "(( x = 1 << 2 ))\ngit checkout -- dirty.txt"],
      ["multi-line quoted string before a discard", 'echo "a\nb << c"\ngit checkout -- dirty.txt'],
      ["quoted `<<` earlier in the line (`echo 'a<<b' && bash <<EOF`)", "echo 'a<<b' && bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["shell-function verb indirection (`f(){ git \"$@\"; }; f checkout -- f`)", 'f() { git "$@"; }; f checkout -- dirty.txt'],
      ["quoted command substitution (`echo \"$(git checkout -- f)\"`)", 'echo "$(git checkout -- dirty.txt)"'],
      ["xargs-fed pathspec (`printf … | xargs git checkout`)", "printf 'dirty.txt\\n' | xargs git checkout"],
      ["`$VAR` script path (`bash $S`)", `S=${execUndo}; bash $S`],
      ["script piped into a shell (`cat undo.sh | bash`)", `cat ${execUndo} | bash`],
      // ── reviewer round-6 closures ──
      ["punctuated heredoc delimiter (`cat <<E-O-F`)", "cat <<E-O-F\nx\nE-O-F\ngit checkout -- dirty.txt"],
      ["dotted heredoc delimiter (`cat <<EOF.txt`)", "cat <<EOF.txt\nx\nEOF.txt\ngit checkout -- dirty.txt"],
      ["redirection before the interpreter (`2>/dev/null bash <<EOF`)", "2>/dev/null bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["alternate shell (`ash <<EOF`)", "ash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["here-string into an interpreter (`bash <<< 'git checkout -- f'`)", "bash <<< 'git checkout -- dirty.txt'"],
      ["process substitution into an interpreter (`bash <(printf …)`)", "bash <(printf 'git checkout -- dirty.txt')"],
      ["opaque interpreter `-c` payload (`S=…; bash -c \"$S\"`)", 'S="git checkout -- dirty.txt"; bash -c "$S"'],
      // ── reviewer round-7 closures ──
      ["single-dash letter run inline payload (`bash -lc '…'`)", "bash -lc 'git checkout -- dirty.txt'"],
      ["backslash-newline continuation before the verb (`git \\\n checkout -- f`)", "git \\\n checkout -- dirty.txt"],
      ["ANSI-C quoted `eval` payload (`eval $'git …'`)", "eval $'git checkout -- dirty.txt'"],
      ["literal `-c` payload sourcing a script (`bash -c 'source <undo.sh>'`)", `bash -c 'source ${execUndo}'`],
      ["`find … -exec sh {} \\;` placeholder runs the file as a script", `find ${execUndo} -exec sh {} \\;`],
      ["opaque quoted `-c` payload NAMING the verb (`bash -c \"$(printf …)\"`)", `bash -c "$(printf 'git checkout -- dirty.txt')"`],
      ["piped producer feeding an opaque payload (`printf … | bash -c \"$(cat)\"`)", "printf 'git checkout -- dirty.txt\\n' | bash -c \"$(cat)\""],
      // ── reviewer round-7, second pass (non-literal producers) ──
      ["command-substitution assignment (`S=$(printf …); bash -c \"$S\"`)", `S=$(printf 'git checkout -- dirty.txt'); bash -c "$S"`],
      ["`printf -v` assignment (`printf -v S …; bash -c \"$S\"`)", `printf -v S '%s' 'git checkout -- dirty.txt'; bash -c "$S"`],
      ["here-string `read` assignment (`read -r S <<<…; bash -c \"$S\"`)", `read -r S <<<'git checkout -- dirty.txt'; bash -c "$S"`],
      ["`eval` assignment (`eval \"S='…'\"; bash -c \"$S\"`)", `eval "S='git checkout -- dirty.txt'"; bash -c "$S"`],
      ["file-fed opaque payload (`printf … > p.sh; bash -c \"$(cat p.sh)\"`)", `printf '%s' 'git checkout -- dirty.txt' > ${tmp}/p-709.sh; bash -c "$(cat ${tmp}/p-709.sh)"`],
      // ── reviewer round-8 closures ──
      ["unquoted variable `eval` payload (`P='git checkout -- f'; eval $P`)", "P='git checkout -- dirty.txt'; eval $P"],
      ["quoted variable `eval` payload (`P='…'; eval \"$P\"`)", `P='git checkout -- dirty.txt'; eval "$P"`],
      ["`read`-fed `eval` payload (`read -r P <<<…; eval $P`)", `read -r P <<<'git checkout -- dirty.txt'; eval $P`],
      ["command-substitution `eval` payload (`P=$(printf …); eval $P`)", `P=$(printf 'git checkout -- dirty.txt'); eval $P`],
      ["code piped into a shell (`printf … | bash`)", "printf 'git checkout -- dirty.txt\\n' | bash"],
      ["code piped into a shell (`echo … | bash`)", "echo 'git checkout -- dirty.txt' | bash"],
      ["indirect piped code (`C=$(printf …); printf … \"$C\" | bash`)", `C=$(printf 'git checkout -- dirty.txt'); printf '%s\\n' "$C" | bash`],
      ["`xargs` runtime placeholder payload (`… | xargs -I{} sh -c '{}'`)", "printf 'git checkout -- dirty.txt\\n' | xargs -I{} sh -c '{}'"],
      ["brace-expansion pathspec (`git checkout -- {dirty,clean}.txt`)", "git checkout -- {dirty,clean}.txt"],
      ["opaque payload fed from a PATH-named discard (`bash -c \"$(cat checkout-undo.sh)\"`)", `bash -c "$(cat ${verbPath})"`],
      ["`eval` payload fed from a PATH-named discard (`eval \"$(cat checkout-undo.sh)\"`)", `eval "$(cat ${verbPath})"`],
      // ── reviewer round-8b closures ──
      ["ANSI-C escaped verb in a `-c` payload (`bash -c $'git \\x63heckout -- f'`)", "bash -c $'git \\x63heckout -- dirty.txt'"],
      ["ANSI-C escaped verb via a variable (`CMD=$'…'; bash -c \"$CMD\"`)", "CMD=$'git \\x63heckout -- dirty.txt'; bash -c \"$CMD\""],
      ["opaque payload whose producer path names NO verb (`bash -c \"$(cat plain-undo.sh)\"`)", `bash -c "$(cat ${plainVerbPath})"`],
      ["non-`{}` xargs placeholder payload (`xargs -I@ sh -c '@'`)", "printf 'git checkout -- dirty.txt\\n' | xargs -I@ sh -c '@'"],
      ["named xargs placeholder payload (`xargs -I PERCENT sh -c 'PERCENT'`)", "printf 'git checkout -- dirty.txt\\n' | xargs -I PERCENT sh -c 'PERCENT'"],
      // ── reviewer round-9 closures ──
      ["feeder supplies the VERB (`printf 'checkout -- f' | xargs git`)", "printf 'checkout -- dirty.txt\\n' | xargs git"],
      ["xargs placeholder as a PATHSPEC (`… | xargs -I@ git checkout -- @`)", "git diff --name-only | xargs -I@ git checkout -- @"],
      ["piped code into a spawner-wrapped shell (`… | env bash`)", "printf 'git checkout -- dirty.txt\\n' | env bash"],
      ["piped code into a flagged shell (`… | bash -x`)", "printf 'git checkout -- dirty.txt\\n' | bash -x"],
      ["piped code into a stdin-reading shell (`… | sh -s`)", "printf 'git checkout -- dirty.txt\\n' | sh -s"],
      // ── reviewer round-10 closures ──
      ["embedded xargs placeholder pathspec (`… | xargs -I@ git checkout -- ./@`)", "printf 'dirty.txt\\n' | xargs -I@ git checkout -- ./@"],
      ["quote-split verb supplied by the feeder (`printf 'check''out …' | xargs git`)", "printf 'check''out -- dirty.txt\\n' | xargs git"],
      ["ANSI-escaped verb supplied by the feeder (`printf 'check\\x6fut …' | xargs git`)", "printf 'check\\x6fut -- dirty.txt\\n' | xargs git"],
      ["piped code followed by a filter (`… | bash | cat`)", "printf 'git checkout -- dirty.txt\\n' | bash | cat"],
      ["piped code followed by `tee` (`… | bash | tee f`)", "printf 'git checkout -- dirty.txt\\n' | bash | tee /tmp/709-tee.log"],
      ["spawner-wrapped piped code followed by a filter (`… | env bash | cat`)", "printf 'git checkout -- dirty.txt\\n' | env bash | cat"],
      // ── reviewer round-10b corrections ──
      ["path-qualified feeder (`… | /usr/bin/xargs -I@ git checkout -- @`)", "printf 'dirty.txt\\n' | /usr/bin/xargs -I@ git checkout -- @"],
      ["quoted feeder word (`… | \"xargs\" -I@ git checkout -- @`)", `printf 'dirty.txt\\n' | "xargs" -I@ git checkout -- @`],
      ["BSD `-J` replstr (`… | xargs -J@ git checkout -- @`)", "printf 'dirty.txt\\n' | xargs -J@ git checkout -- @"],
      ["stdin-alias script operand (`printf … | python3 /dev/stdin`)", "printf 'import subprocess\\nsubprocess.run([\"git\",\"checkout\",\"--\",\"dirty.txt\"])\\n' | python3 /dev/stdin"],
      ["stdin-alias script operand (`printf … | node /dev/stdin`)", "printf 'require(\"child_process\").execSync(\"git checkout -- dirty.txt\")\\n' | node /dev/stdin"],
      // ── reviewer round-11 closures ──
      ["redirect after the piped shell (`… | bash 2>/dev/null`)", "printf 'git checkout -- dirty.txt\\n' | bash 2>/dev/null"],
      ["redirect after the piped shell (`… | sh -s &>/dev/null`)", "printf 'git checkout -- dirty.txt\\n' | sh -s &>/dev/null"],
      ["escaped feeder word (`… | \\xargs -I@ git checkout -- @`)", "printf 'dirty.txt\\n' | \\xargs -I@ git checkout -- @"],
      ["placeholder as a filename suffix (`… | xargs -I@ git checkout -- @.txt`)", "printf 'dirty\\n' | xargs -I@ git checkout -- @.txt"],
      ["multi-char placeholder as a prefix (`… | xargs -I PERCENT git checkout -- PERCENT.txt`)", "printf 'dirty\\n' | xargs -I PERCENT git checkout -- PERCENT.txt"],
    ];
    for (const [why, cmd] of bypass) {
      const r = await bash(cmd, wt);
      expectTrue(`B6g: ${why} → BLOCKED`, blocked(r), JSON.stringify(r)?.slice(0, 160));
    }
    // Reviewer round-7, second pass — DOCUMENTED RESIDUAL (conservative block):
    // an unresolvable opaque payload sharing a command with a discard verb blocks
    // even when the visible git invocation is legitimate. Payload-scoping this
    // test let the five producer forms above destroy WIP, so the arm is
    // deliberately whole-command (the pre-round-7 contract).
    expectTrue("B6j: opaque payload + a discard verb in ONE command → BLOCKED (documented residual, fail-closed)",
      blocked(await bash('bash -c "$L" && git checkout main', wt)), "was allowed");
    // Reviewer round-7: `-c`/`-C` are branch-CREATE flags for `git switch` and
    // rejected outright by `git checkout` (unknown switch, exit 129 — verified
    // against real git), so neither form can discard a path.
    expectTrue("B6k: `git checkout -c dirty.txt` ALLOWED (git rejects `-c`: unknown switch)",
      allowed(await bash("git checkout -c dirty.txt", wt)), "was blocked");
    // Reviewer round-8 P2: the fail-closed verb test is word-anchored, so an
    // unrelated word containing the letters of a verb (`normal`, `format`,
    // `terraform`) no longer blocks an unresolvable payload.
    expectTrue("B6l: `bash -c \"$CMD\" && echo normal` ALLOWED (no discard verb — `rm` is not a substring match)",
      allowed(await bash('bash -c "$CMD" && echo normal', wt)), "was blocked");
    expectTrue("B6l: `bash -c \"$CMD\" && terraform plan` ALLOWED (no discard verb)",
      allowed(await bash('bash -c "$CMD" && terraform plan', wt)), "was blocked");
    // Reviewer round-9: widening the pipeline-consumer analysis must not block a
    // shell fed harmless data.
    expectTrue("B6l: `printf 'hello\\n' | env bash` ALLOWED (piped code with no discard verb)",
      allowed(await bash("printf 'hello\\n' | env bash", wt)), "was blocked");
    // Reviewer round-10 P2: the placeholder harvest is scoped to real xargs
    // segments, and a code interpreter with its own code/script operand reads
    // the pipe as DATA.
    expectTrue("B6l: `grep -I clean.txt clean.txt ; git checkout -- clean.txt` ALLOWED (`-I` is grep's, not xargs')",
      allowed(await bash("grep -I clean.txt clean.txt ; git checkout -- clean.txt", wt)), "was blocked");
    expectTrue("B6l: `git log --grep=reset --oneline | python3 -m json.tool` ALLOWED (pipe is DATA to python)",
      allowed(await bash("git log --grep=reset --oneline | python3 -m json.tool", wt)), "was blocked");
    expectTrue("B6l: `git status | python3 -c 'pass' > out-709.txt` ALLOWED (pipe is DATA to python)",
      allowed(await bash("git status | python3 -c 'pass' > out-709.txt", wt)), "was blocked");
    // Reviewer round-10b corrections: a shell with its own code/script operand
    // reads the pipe as DATA, and a one-character `-I` replstr must not turn
    // every dotted pathspec into a placeholder.
    expectTrue("B6l: `grep -c checkout clean.txt | bash -c 'wc -l' | tee f` ALLOWED (bash -c reads the pipe as DATA)",
      allowed(await bash("grep -c checkout clean.txt | bash -c 'wc -l' | tee /tmp/709-tee2.log", wt)), "was blocked");
    expectTrue("B6l: `printf 'x\\n' | xargs -I c echo c ; git checkout -- clean.txt` ALLOWED (single-char replstr is not a substring match)",
      allowed(await bash("printf 'x\\n' | xargs -I c echo c ; git checkout -- clean.txt", wt)), "was blocked");
    // Reviewer round-11 P2 — DOCUMENTED FAIL-CLOSED COST, not a bug: the walker
    // consumes `--version`, so this null-verb invocation is indistinguishable
    // from the bare feeder-fed `git` the arm exists for. It only fires when the
    // tree is dirty and the command mentions a feeder word (see README).
    expectTrue("B6l: `echo 'use xargs to batch' && git --version` BLOCKED (documented fail-closed cost)",
      blocked(await bash("echo 'use xargs to batch' && git --version", wt)), "was allowed");
    rmSync(execUndo, { force: true });
    rmSync(patch, { force: true });
    rmSync(verbPath, { force: true });
    rmSync(plainVerbPath, { force: true });
    // `--work-tree` targets a DIFFERENT working tree than the cwd: run from a
    // non-repo dir (tmp) with the dirty tree supplied only by the flag.
    const wtFlag = await bash(`git --git-dir=${wt}/.git --work-tree=${wt} checkout -- dirty.txt`, tmp);
    expectTrue("B6g: `--work-tree` targeting another working tree → BLOCKED (probes the work-tree)",
      blocked(wtFlag), JSON.stringify(wtFlag)?.slice(0, 160));

    // ── B6h: hidden-pathspec forms fail CLOSED ──
    expectTrue("B6h: `--pathspec-from-file` fails closed",
      blocked(await bash("git checkout --pathspec-from-file=/tmp/nope.txt", wt)), "was allowed");

    // ── B6i: reviewer round-3 read-only / non-worktree false positives ──
    expectTrue("B6i: `git rm -f --cached dirty.txt` ALLOWED (index-only)",
      allowed(await bash("git rm -f --cached dirty.txt", wt)), "was blocked");
    expectTrue("B6i: `git rm -nf dirty.txt` ALLOWED (dry run)",
      allowed(await bash("git rm -nf dirty.txt", wt)), "was blocked");
    expectTrue("B6i: `git apply -R --check <patch>` ALLOWED (report only)",
      allowed(await bash(`git apply -R --check ${patch}`, wt)), "was blocked");
    expectTrue("B6i: `git apply -R --stat <patch>` ALLOWED (report only)",
      allowed(await bash(`git apply -R --stat ${patch}`, wt)), "was blocked");
    expectTrue("B6i: `git checkout-index -a -f --prefix=<dir>` ALLOWED (exports elsewhere)",
      allowed(await bash(`git checkout-index -a -f --prefix=${tmp}/out-709/`, wt)), "was blocked");
    expectTrue("B6i: `git checkout -m` (no path) ALLOWED (switch-with-merge)",
      allowed(await bash("git checkout -m", wt)), "was blocked");
    expectTrue("B6i: `git -c alias.z=status z` ALLOWED (read-only alias)",
      allowed(await bash("git -c alias.z=status z", wt)), "was blocked");
    // Reviewer round-4: a bare token that IS a ref is a switch, not a discard.
    expectTrue("B6i: `git checkout HEAD` ALLOWED (token resolves to a commit)",
      allowed(await bash("git checkout HEAD", wt)), "was blocked");
    // Reviewer round-4 P2: `--source` without `--staged` is WORKTREE-only, so a
    // staged-only change survives and must not block.
    gg("add staged.txt && printf 'staged\n' > staged.txt && git add staged.txt", wt);
    expectTrue("B6i: `git restore -s HEAD staged.txt` ALLOWED (worktree-only source)",
      allowed(await bash("git restore -s HEAD staged.txt", wt)), "was blocked");
    expectTrue("B6i: `git apply -R --cached <patch>` ALLOWED (index-only)",
      allowed(await bash(`git apply -R --cached ${patch}`, wt)), "was blocked");
    // Reviewer round-5 P2: `-f <PATH>` restores just that path (the ref/path
    // probe decides) and an index-only `--pathspec-from-file` restore is not a
    // working-tree discard.
    expectTrue("B6i: `git checkout -f clean.txt` ALLOWED (path, not a ref)",
      allowed(await bash("git checkout -f clean.txt", wt)), "was blocked");
    const psf = join(tmp, "psf.txt");
    write(psf, "staged.txt\n");
    expectTrue("B6i: `git restore --staged --pathspec-from-file=<list>` ALLOWED (index-only)",
      allowed(await bash(`git restore --staged --pathspec-from-file=${psf}`, wt)), "was blocked");
    rmSync(psf, { force: true });
    expectTrue("B6i: bare `git restore` ALLOWED (git usage error, no-op)",
      allowed(await bash("git restore", wt)), "was blocked");
    expectTrue("B6i: `echo <<< '…'` ALLOWED (non-interpreter here-string)",
      allowed(await bash("echo <<< 'git checkout -- dirty.txt'", wt)), "was blocked");
    gg("reset -q staged.txt", wt);

    // ── B7: staged-only change survives `checkout --` but not a tree source ──
    gg("add staged.txt && printf 'staged\\n' > staged.txt && git add staged.txt", wt);
    // porcelain is now `M  staged.txt` (X=M, Y=' ') — index-only difference.
    expectTrue("B7a: worktree + staged-only target → `git checkout -- staged.txt` ALLOWED",
      allowed(await bash("git checkout -- staged.txt", wt)), "was blocked");
    expectTrue("B7b: worktree + staged-only target → `git checkout HEAD -- staged.txt` BLOCKED (tree source)",
      blocked(await bash("git checkout HEAD -- staged.txt", wt)), "was allowed");
    // Reviewer round-1 fold-in: a FLAG before `--` is not a tree-ish, so the
    // index-source semantics (staged-only survives) must hold for `-q` too.
    expectTrue("B7c: `git checkout -q -- staged.txt` ALLOWED (a flag is not a tree-ish)",
      allowed(await bash("git checkout -q -- staged.txt", wt)), "was blocked");
    expectTrue("B7d: `git restore --stage staged.txt` ALLOWED (index-only prefix)",
      allowed(await bash("git restore --stage staged.txt", wt)), "was blocked");
    // Reviewer round-2 P1: a `--staged` that survives alongside `--worktree`
    // (or with a `--source=`) resets the index from HEAD → tree-sourced.
    expectTrue("B7d2: `git restore --staged --worktree staged.txt` BLOCKED (index reset from HEAD)",
      blocked(await bash("git restore --staged --worktree staged.txt", wt)), "was allowed");
    expectTrue("B7d3: `git restore --source=HEAD --staged --worktree staged.txt` BLOCKED",
      blocked(await bash("git restore --source=HEAD --staged --worktree staged.txt", wt)), "was allowed");
    // Reviewer round-1 fold-in: heredoc DATA and comments are not code.
    mkdirSync(join(wt, "sub"), { recursive: true });
    write(join(wt, "sub", "noop.sh"), "#!/bin/sh\ntrue\n");
    expectTrue("B7e: `cd sub && bash sub/noop.sh && git checkout -- clean.txt` ALLOWED (cd chain not double-applied)",
      allowed(await bash(`cd sub && bash noop.sh && git checkout -- clean.txt`, wt)), "was blocked");
    expectTrue("B7f: heredoc DATA body mentioning a discard ALLOWED",
      allowed(await bash("cat <<'EOF'\ngit checkout -- dirty.txt\nEOF", wt)), "was blocked");
    const commented = join(tmp, "commented.sh");
    write(commented, "# git checkout -- dirty.txt\nls\n");
    expectTrue("B7g: commented-out discard in a script ALLOWED",
      allowed(await bash(`bash ${commented}`, wt)), "was blocked");
    rmSync(commented, { force: true });
    // Reviewer round-2 P2: a MID-LINE comment is not a command either.
    expectTrue("B7h: mid-line `#` comment mentioning a discard ALLOWED",
      allowed(await bash("echo hi # git checkout -- dirty.txt", wt)), "was blocked");
    expectTrue("B7i: mid-line comment with a destructive verb ALLOWED",
      allowed(await bash("true # git reset --hard", wt)), "was blocked");
    gg("reset -q --hard", wt); // fixture cleanup, direct git call (not the handler)

    // ── B8: untracked-only dirt → ALLOW (`checkout -- .` never deletes `??`) ──
    write(join(wt, "scratch-untracked.txt"), "wip\n");
    expectTrue("B8a: untracked-only dirt → `git checkout -- .` ALLOWED",
      allowed(await bash("git checkout -- .", wt)), "was blocked");
    expectTrue("B8b: untracked-only dirt → `git checkout -f` ALLOWED",
      allowed(await bash("git checkout -f", wt)), "was blocked");
    expectTrue("B8c: untracked-only dirt → `git reset --hard` ALLOWED (untracked survives)",
      allowed(await bash("git reset --hard", wt)), "was blocked");
    execSync("rm -f scratch-untracked.txt", { cwd: wt, stdio: "ignore" });

    // ── B9: HUB-targeted discard from a worktree session → BLOCK ──
    // M4 is inert here (the SESSION is in a worktree, so hub disorder reads
    // null), the legacy arms are worktree-scoped on the invocation, and
    // `checkout --` is `allow` by classification — M5 is the only blocker.
    write(join(hub, "dirty.txt"), "MUTANT\n");
    const hubHit = await bash(`git -C "${hub}" checkout -- dirty.txt`, wt);
    expectTrue("B9: worktree session + HUB dirty target → BLOCKED (M5 resolves the invocation target)",
      blocked(hubHit), JSON.stringify(hubHit)?.slice(0, 200));
    execSync("git checkout -- dirty.txt && git clean -qfd", { cwd: hub, stdio: "ignore" });

    // ── B10: unverifiable targets fail CLOSED ──
    expectTrue("B10a: unresolvable pathspec (`$FILE`) fails closed",
      blocked(await bash("git checkout -- \"$FILE\"", wt)), "was allowed");
    expectTrue("B10b: unresolvable invocation target (`cd $SUBDIR`) fails closed",
      blocked(await bash("cd $SUBDIR && git checkout -- clean.txt", wt)), "was allowed");

    // ── B12 (#1139): M5's sanctioned-framework-script exemption ──
    // `hub-worktree.sh`'s salvage path reverts the hub's tracked dirt with
    // `git show "HEAD:$rest" > "$MAIN_REPO/$rest"`. The pure extractor can only
    // surface that as a `cat-file-revert` HINT whose pathspec is the SHELL LOOP
    // VARIABLE `$rest`, so the unresolvable-pathspec rule fails CLOSED — on a
    // provably CLEAN checkout, for the framework's own documented recovery
    // helper. #1129 exempted this file from M4's content walk; M5 never asked,
    // so the helper stayed blocked from a hub-rooted session (and its message
    // claimed uncommitted work that did not exist).
    const sanctionedRecovery = join(HERE, "..", "..", "scripts", "checkout-hygiene", "hub-worktree.sh");
    expectTrue("B12-pre: the sanctioned recovery helper is where the anchor expects it",
      readFileSync(sanctionedRecovery, "utf8").includes("hub-worktree.sh"), sanctionedRecovery);
    execSync("git checkout -q -- dirty.txt && git clean -qfd", { cwd: hub, stdio: "ignore" });
    const hubClean = execSync("git status --porcelain", { cwd: hub, encoding: "utf8" }).trim();
    expect(`B12-pre2: the hub is CLEAN (so any block here cannot be about real WIP): ${JSON.stringify(hubClean)}`, hubClean, "");
    // No args → usage + exit 2, so the run has no side effects on the fixture.
    const sanctionedRun = await bash(`bash "${sanctionedRecovery}"`, hub);
    expectTrue("B12a: #1139 — the sanctioned recovery helper is ALLOWED from a hub-rooted session (M5 exempts it, as M4 does)",
      allowed(sanctionedRun), `reason=${JSON.stringify(sanctionedRun?.reason ?? "").slice(0, 300)}`);

    // The SAME content at the SAME relpath in a DIFFERENT checkout must still be
    // GATED: the anchor is the guard's own checkout, never a relpath match and
    // never the invoking cwd. Driven from the hermetic WORKTREE so the gate that
    // fires has to be M5's.
    //
    // #1060 CHANGED THE SHAPE OF THIS PIN, and the change IS the point. The
    // helper's salvage redirect is `git show "HEAD:$rest" > "$MAIN_REPO/$rest"`:
    // `$rest` (the source) and `$MAIN_REPO` (the target's anchor, computed by
    // the script at runtime from `git rev-parse --git-common-dir`) are BOTH
    // statically unresolvable. #1139 left that to the generic
    // unresolvable-pathspec rule, which failed CLOSED — so a COPY was refused
    // even on a provably pristine fixture. That is precisely the #940 class
    // (a legitimate `$var` pathspec refused on a clean checkout), so #1060's
    // state predicate necessarily changes it. The PROPERTY this test exists for
    // — a copy in another checkout is not exempt — is asserted directly instead
    // of as a side effect of the fail-closed text: a copy in a checkout that
    // CARRIES tracked dirt BLOCKS; on a pristine fixture there is nothing to
    // destroy and it is allowed. Both halves are pinned, so neither the
    // exemption nor the gate can drift unnoticed.
    mkdirSync(join(hub, "scripts", "checkout-hygiene"), { recursive: true });
    const copyPath = join(hub, "scripts", "checkout-hygiene", "hub-worktree.sh");
    write(copyPath, readFileSync(sanctionedRecovery, "utf8"));
    // (a) PRISTINE fixture (B12-pre2 pinned the hub CLEAN) → the copy is not
    // exempt, but with nothing to destroy the state predicate allows it.
    const copyPristine = await bash(`bash "${copyPath}"`, wt);
    expectTrue("B12b: #1139+#1060 — a copy in another checkout is NOT exempt, but a PRISTINE fixture has nothing to lose, so it is ALLOWED (state, not text)",
      allowed(copyPristine), `reason=${JSON.stringify(copyPristine?.reason ?? "").slice(0, 300)}`);
    // (b) The #1139 threat itself: a copy in a checkout that CARRIES TRACKED
    // DIRT must block. `wt2` is the linked worktree the fixture already left
    // dirty, and it is agent-WRITABLE — exactly the copy #1139 refuses to
    // exempt. Run from `wt` (clean), so nothing about the session's own tree
    // can be the reason.
    mkdirSync(join(wt2, "scripts", "checkout-hygiene"), { recursive: true });
    const copyDirtyPath = join(wt2, "scripts", "checkout-hygiene", "hub-worktree.sh");
    write(copyDirtyPath, readFileSync(sanctionedRecovery, "utf8"));
    const copyDirty = await bash(`bash "${copyDirtyPath}"`, wt);
    expectTrue("B12b2: #1139 — the same copy in a DIRTY checkout (wt2, agent-writable) is STILL BLOCKED: the exemption is path-keyed, and the gate is state-keyed",
      blocked(copyDirty) && /#709/.test(copyDirty?.reason ?? "") && /cat-file-revert/.test(copyDirty?.reason ?? ""),
      `reason=${JSON.stringify(copyDirty?.reason ?? "").slice(0, 300)}`);
    rmSync(copyDirtyPath, { force: true });

    // #1060 — the FAIL-CLOSED TEXT assertions move to a producer that still
    // reaches that arm (#940's fix removed the `cat-file-revert` route to it,
    // because for THAT form the pathspec is the read-only SOURCE and the
    // redirect is the destruction). `git checkout -- "$FILE"` is the arm's
    // canonical producer: the pathspec names what is destroyed and it is not
    // statically resolvable, so the arm must still fail closed. The message
    // contract itself is unchanged, and it is asserted here rather than only in
    // B10a so the four properties below keep a live producer.
    const unverifiableMsg = (await bash('git checkout -- "$FILE"', wt))?.reason ?? "";
    expectTrue("B12c: the fail-closed message does NOT claim uncommitted changes exist",
      /NOT a claim that the checkout is dirty/.test(unverifiableMsg) &&
      !/carries\s+uncommitted changes/.test(unverifiableMsg) &&
      /not statically resolvable/.test(unverifiableMsg),
      `reason=${JSON.stringify(unverifiableMsg).slice(0, 320)}`);
    expectTrue("B12c2: it names the real reason (target resolution) and does NOT offer the AGENT_ALLOW_MAIN_EDITS hatch as its remedy",
      /not its remedy/.test(unverifiableMsg) &&
      !/Deliberate discard: set AGENT_ALLOW_MAIN_EDITS=1/.test(unverifiableMsg),
      `reason=${JSON.stringify(unverifiableMsg).slice(0, 320)}`);
    // Review fold-in: the fail-closed arm serves NINE reasons, only two of which
    // are target-resolution failures (the status-read arm resolves the target
    // and then fails the probe). A headline naming one cause for all nine is the
    // misattribution class this PR removes, so the arm's own wording must stay
    // cause-neutral and defer to the `⚠️ <reason>` line.
    expectTrue("B12c3: the fail-closed headline is CAUSE-NEUTRAL (no single-cause claim for all nine reasons)",
      /the discard's effect could not be verified, failing closed/.test(unverifiableMsg) &&
      !/target not statically resolvable, failing closed/.test(unverifiableMsg),
      `reason=${JSON.stringify(unverifiableMsg).slice(0, 160)}`);
    // Review fold-in (#1139's own sibling defect class): the message recommended
    // the RELATIVE `scripts/checkout-hygiene/hub-worktree.sh`, which from a
    // linked-worktree session resolves to that worktree's own ~gated~ copy — the
    // gate telling the reader to run a command the gate blocks. The recommended
    // spelling must be the framework checkout's own (exempt) path, and running
    // it from the SAME worktree session must be ALLOWED.
    const recommended = /bash "([^"]*checkout-hygiene\/hub-worktree\.sh)" <branch>/.exec(unverifiableMsg)?.[1] ?? "";
    expectTrue("B12c4: the remedy names the framework checkout's OWN absolute path (not the relative spelling)",
      recommended !== "" && recommended === sanctionedRecovery,
      `recommended=${JSON.stringify(recommended)}`);
    expectTrue("B12c5: the recommended command is itself ALLOWED from the same worktree session (no advice loop)",
      allowed(await bash(`bash "${recommended}"`, wt)), "the remedy the gate printed is blocked by the gate");

    // Negative control — the correction is not a blanket deletion of the claim:
    // the arm that DID read a dirty scope still says so, and still names the
    // hatch (that arm's legitimate remedy).
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const dirtyMsg = (await bash("git checkout -- dirty.txt", wt))?.reason ?? "";
    expectTrue("B12d: control — the DIRTY arm still claims uncommitted changes and still names the hatch",
      /carries uncommitted changes to tracked files/.test(dirtyMsg) &&
      /Deliberate discard: set AGENT_ALLOW_MAIN_EDITS=1/.test(dirtyMsg) &&
      !/NOT a claim that the checkout is dirty/.test(dirtyMsg),
      `reason=${JSON.stringify(dirtyMsg).slice(0, 320)}`);
    // #1141 — this same message was itself a measured TEXTUAL producer: it
    // taught `cp <file> /tmp/probe-<file>` and `git worktree add /tmp/probe`
    // with no cleanup obligation (docs/ops/load-policy.md, producer evidence).
    // The dirty arm must now teach the self-cleaning worktree recipe and carry
    // the ban — otherwise the rule the skills state and the gate the guard
    // prints disagree, and the gate keeps minting the debris #1141 removed.
    expectTrue("B12d2: #1141 — the dirty arm teaches a WORKTREE recipe, not a /tmp copy",
      !/cp <file> \/tmp\/probe-<file>/.test(dirtyMsg) &&
      !/worktree add \/tmp\/probe/.test(dirtyMsg) &&
      /scratch-worktree\.sh run/.test(dirtyMsg) &&
      /NEVER .git clone./.test(dirtyMsg),
      `reason=${JSON.stringify(dirtyMsg).slice(0, 320)}`);
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });

    // SET-scoped, not command-scoped: the exemption drops the sanctioned
    // SCRIPT's harvested set; a direct discard sharing the same command is
    // still gated by the command's own argv set (`script: null`).
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const compound = await bash(`bash "${sanctionedRecovery}" && git checkout -- dirty.txt`, wt);
    expectTrue("B12e: the exemption is SET-scoped — a direct discard in the same command is still BLOCKED",
      blocked(compound) && /it would destroy uncommitted work/.test(compound?.reason ?? "") &&
      /dirty\.txt/.test(compound?.reason ?? ""),
      `reason=${JSON.stringify(compound?.reason ?? "").slice(0, 300)}`);
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });

    // Realpath, not cwd: the framework's own copy is exempt however the session
    // addresses it — and a worktree-local COPY at the same relpath is a
    // different realpath, so it is still gated (B12b's geometry). This is the
    // documented residual: a linked-worktree copy is agent-WRITABLE, so it must
    // not be exempt; sessions that want the helper from a worktree call the
    // framework checkout's own path.
    const fromWt = await bash(`bash "${sanctionedRecovery}"`, wt);
    expectTrue("B12f: the framework's own copy is exempt by REALPATH from any invoking cwd",
      allowed(fromWt), `reason=${JSON.stringify(fromWt?.reason ?? "").slice(0, 300)}`);

    // The exemption can only ever drop discards harvested FROM the sanctioned
    // file's own bytes — a set's `script` is always the file its `discs` were
    // read from. Naming the sanctioned path from elsewhere therefore buys
    // nothing: a discard riding along in the SAME payload is still gated.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const laundered = await bash(
      `bash -c 'source "${sanctionedRecovery}"; git checkout -- dirty.txt'`, wt);
    expectTrue("B12g: naming the sanctioned path inside a `-c` payload does NOT launder a discard riding along in it",
      blocked(laundered) && /it would destroy uncommitted work/.test(laundered?.reason ?? ""),
      `reason=${JSON.stringify(laundered?.reason ?? "").slice(0, 300)}`);
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });

    // Second hop: a WRAPPER that sources the sanctioned helper does not become
    // sanctioned — sets are per-FILE, so the wrapper's own discards stay in the
    // wrapper's set (which is not exempt).
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const wrapper = join(wt, "wrapper-1139.sh");
    write(wrapper, `#!/bin/sh\n. "${sanctionedRecovery}" 2>/dev/null || true\ngit checkout -- dirty.txt\n`);
    const wrapped = await bash(`bash "${wrapper}"`, wt);
    expectTrue("B12h: a wrapper that SOURCES the sanctioned helper does NOT inherit the exemption",
      blocked(wrapped) && /it would destroy uncommitted work/.test(wrapped?.reason ?? ""),
      `reason=${JSON.stringify(wrapped?.reason ?? "").slice(0, 300)}`);
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });
    // (`wrapper` is kept for the pipe-form arms below; `copyPath` is done with.)
    rmSync(copyPath, { force: true });

    // T4 in its PIPE form (review P1 — pre-existing, reproducible before this
    // change): the pipe-seed walk kept the SHELL QUOTES on the token, so
    // `cat "<wrapper>" | bash` resolved `'"<wrapper>"'`, realpathSync threw and
    // the file was never read — a discard inside it ran UNGATED, while the
    // identical UNQUOTED spelling was walked. The same second-hop wrapper as
    // B12h, fed through the pipe instead of as an argv script.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const quotedPipe = await bash(`cat "${wrapper}" | bash`, wt);
    expectTrue("B12i: a QUOTED path piped into a shell is walked like the unquoted spelling (no quote-blind seed)",
      blocked(quotedPipe) && /it would destroy uncommitted work/.test(quotedPipe?.reason ?? ""),
      `reason=${JSON.stringify(quotedPipe?.reason ?? "").slice(0, 300)}`);
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });
    // A quoted path CONTAINING SPACES, behind a flag — the suffix-seed half.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const spaced = join(wt, "spaced wrapper-1139.sh");
    write(spaced, readFileSync(wrapper, "utf8"));
    const spacedPipe = await bash(`cat -n "${spaced}" | bash`, wt);
    expectTrue("B12i2: a quoted path with SPACES behind a flag is walked too",
      blocked(spacedPipe) && /it would destroy uncommitted work/.test(spacedPipe?.reason ?? ""),
      `reason=${JSON.stringify(spacedPipe?.reason ?? "").slice(0, 300)}`);
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });

    // NEGATIVE direction (review cycle-2 P1): a seed must be a string the shell
    // itself reads as ONE word. The first attempt at the pipe fix dequoted the
    // whole segment then split on whitespace, which (a) invented a joined token
    // for unquoted input and (b) over-split a quoted word — either way seeding a
    // file the shell NEVER reads, which pins a FALSE BLOCK on it. Both cases
    // below ALLOWED on the over-seeding version and must stay allowed.
    //   B12k  : `cat <harmless-a> <harmless-b> | bash` — the joined name
    //           "<harmless-a> <harmless-b>" exists and CARRIES A DISCARD, but the
    //           shell reads only the two separate files, so seeding the join is
    //           grounds for a false block.
    //   B12k2 : `cat "<split-name>" | bash` — the quoted name is harmless, but
    //           the first whitespace-separated half (`w`) carries a discard, so
    //           over-splitting blocks a command that touches nothing dirty.
    // `dirty.txt` is left DIRTY for these two so a false seed HAS something to
    // block on — otherwise even the over-seeding version would allow and the
    // test would pass vacuously.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const harmlessA = "harmless-a-1139.sh";
    const harmlessB = "harmless-b-1139.sh";
    write(join(wt, harmlessA), "true\n");
    write(join(wt, harmlessB), "true\n");
    write(join(wt, `${harmlessA} ${harmlessB}`), `git checkout -- dirty.txt\n`);
    const joined = await bash(`cat ${harmlessA} ${harmlessB} | bash`, wt);
    expectTrue("B12k: an unquoted word PAIR is not joined into an invented seed (no false block)",
      allowed(joined), `reason=${JSON.stringify(joined?.reason ?? "").slice(0, 240)}`);
    const splitName = "w-1139 split-1139.sh";
    write(join(wt, "w-1139"), `git checkout -- dirty.txt\n`);
    write(join(wt, splitName), "true\n");
    const overSplit = await bash(`cat "${splitName}" | bash`, wt);
    expectTrue("B12k2: a QUOTED word containing a space is not over-split into its halves (no false block)",
      allowed(overSplit), `reason=${JSON.stringify(overSplit?.reason ?? "").slice(0, 240)}`);
    for (const f of [harmlessA, harmlessB, `${harmlessA} ${harmlessB}`, splitName, "w-1139"]) rmSync(join(wt, f), { force: true });
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });

    // SHELL FIDELITY (review cycle-3 P1). A seed must equal what the shell reads
    // as ONE word, in BOTH directions. The cycle-2 fix stripped every quote and
    // every backslash anywhere in the token, so `'a\b.sh'` (one file, backslash
    // LITERAL) became `ab.sh` — a seed for a file the shell never reads, i.e. a
    // fail-open regression against the parent commit AND a latent false block.
    // The cycle-3 dequote follows the shell's rules (single quotes literal,
    // backslash escapes outside quotes, and inside double quotes only
    // `$"`/backtick/backslash/newline). Each row below names which file carries
    // the discard, so a row whose file is NOT the one the shell reads is a
    // no-mis-seed assertion.
    const fidelity = [
      ["cat 'a\\b.sh' | bash", "a\\b.sh", true, "single-quoted backslash is LITERAL"] ,
      ["cat 'a\\b.sh' | bash", "ab.sh", false, "…so `ab.sh` must not be seeded"],
      ["cat \"un'do.sh\" | bash", "un'do.sh", true, "a single quote inside double quotes is literal"],
      ["cat \"un'do.sh\" | bash", "undo.sh", false, "…so `undo.sh` must not be seeded"],
      ["cat 'a b.sh' | bash", "a b.sh", true, "single-quoted space is one word"],
      ["cat a\\ b.sh | bash", "a b.sh", true, "backslash-escaped space is one word"],
      ['cat \'a" b.sh\' | bash', 'a" b.sh', true, "a double quote inside single quotes is literal"],
      ['cat "a\\" b.sh" | bash', 'a" b.sh', true, "an escaped quote does not close the word"],
    ];
    const fidelityNames = ["ab.sh", "a\\b.sh", "undo.sh", "un'do.sh", "a b.sh", 'a" b.sh'];
    let fid = 0;
    for (const [cmd, discardIn, wantBlock, why] of fidelity) {
      for (const n of fidelityNames) write(join(wt, n), n === discardIn ? "git checkout -- dirty.txt\n" : "true\n");
      // dirty.txt must be DIRTY in every iteration, or a row expecting a block
      // would pass vacuously (the same trap as the /tmp probe, found in review).
      write(join(wt, "dirty.txt"), "MUTANT\n");
      const res = await bash(cmd, wt);
      const gotBlock = blocked(res);
      expectTrue(`B12l.${++fid}: pipeline-seed fidelity — ${why} (${wantBlock ? "blocks" : "allows"} with the discard in ${JSON.stringify(discardIn)})`,
        gotBlock === wantBlock, `got ${gotBlock ? "BLOCKED" : "ALLOWED"}: ${JSON.stringify(res?.reason ?? "").slice(0, 200)}`);
    }
    for (const n of fidelityNames) rmSync(join(wt, n), { force: true });
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });
    rmSync(wrapper, { force: true });

    // The ONE allow arm of the status probe: a target with NO working tree has
    // nothing to discard. The branch was DEAD before this change —
    // `stdio[2] = "ignore"` left `error.stderr` null, so the not-a-checkout
    // regex could never match and every such target failed closed (review P1).
    // A BARE repo is the reachable geometry: a plain non-repo directory never
    // gets this far (`resolveInvocationTarget` fails first, and that arm fails
    // closed). Verified by reverting `"pipe"` → `"ignore"` in a copy: this
    // exact command BLOCKS under the old stdio and ALLOWS under the new one.
    const bare = join(tmp, "bare-1139.git");
    execSync(`git init --bare -q "${bare}"`, { cwd: tmp, stdio: "ignore" });
    const bareTarget = await bash(`git -C "${bare}" checkout -- f.txt`, wt);
    expectTrue("B12j: a discard aimed at a target with NO working tree (bare repo) is ALLOWED (documented fail-open arm, now reachable)",
      allowed(bareTarget), `reason=${JSON.stringify(bareTarget?.reason ?? "").slice(0, 240)}`);


    // ── B13 (#1228): the verdict must not depend on the TEXT SHAPE of a script
    // path. A runtime-EXPANDED path (glob / tilde / brace / char-class, or a
    // `$VAR` producer) names a script the shell will really run but the guard
    // could never READ, so the discard inside it ran UNGATED. Same script, same
    // discard, opposite verdict before this change — measured on the fixtures
    // below. Every expansion form now fails closed, and the literal spelling
    // stays gated exactly as before (the first two controls, and B6e/B6g).
    const undoExp = join(wt, "undo-1228.sh");
    const undoExpGlob = join(wt, "undo-1228-glob.sh");
    const undoExpHome = join(home, "undo-1228.sh");
    const undoExpSubDir = join(wt, "sub-1228");
    mkdirSync(undoExpSubDir, { recursive: true });
    const undoExpSub = join(undoExpSubDir, "undo.sh");
    const undoCleanGlob = join(wt, "cleanonly-1228.sh");
    write(undoExp, "git checkout -- dirty.txt\n");
    write(undoExpGlob, "git checkout -- dirty.txt\n");
    write(undoExpHome, "git checkout -- dirty.txt\n");
    write(undoExpSub, "git checkout -- dirty.txt\n");
    execSync(`chmod +x ${undoExpSub}`);
    write(undoCleanGlob, "git checkout -- clean.txt\n");
    // A nested script that RUNS an expanded path (B13's last case).
    const outerExp = join(wt, "outer-1228.sh");
    write(outerExp, "bash ./undo-1228*.sh\n");
    // A nested script that PIPES an expanded producer into a shell one level in
    // (the pipe-inside-a-wrapper case review cycle 1 found still open).
    const outerPipeExp = join(wt, "outer-pipe-1228.sh");
    write(outerPipeExp, "bash -c 'cat ./undo-1228*.sh | bash'\n");
    // A file whose CONTENT becomes a `-c` payload via `$(cat …)`.
    const producerExp = join(wt, "producer-1228.sh");
    write(producerExp, "cat ./undo-1228*.sh | bash\n");
    // A nested script whose own BODY is a bare pipeline (the line-ending case
    // that defeated the consumer test before the producer scan trimmed it).
    const outerBarePipeExp = join(wt, "outer-bare-pipe-1228.sh");
    write(outerBarePipeExp, "cat ./undo-1228*.sh | bash\n");
    // A script named BY a `-c` / `eval` payload whose own body runs an expanded
    // path (the payload-text check cannot see inside the named file).
    const outerGlobPayload = join(wt, "outer-glob-payload-1228.sh");
    write(outerGlobPayload, "bash ./undo-1228*.sh\n");
    // A script body with an ASSIGNMENT and a `case` pattern — the segment scan
    // must not read those as commands (B12a caught exactly this on the
    // sanctioned helper).
    const casePatternExp = join(wt, "case-pattern-1228.sh");
    write(casePatternExp, 'X="${Y:-/tmp/z}"\ncase "$X" in\n  /tmp/*|/private/tmp/*) echo hi ;;\nesac\n');
    const blockReason1228 = (r) => String(r?.reason ?? "");
    const exp1228 = [
      ["control: literal `bash ./undo-1228.sh`", "bash ./undo-1228.sh", /#709/],
      ["control: literal `cat undo-1228.sh | bash`", "cat undo-1228.sh | bash", /#709/],
      ["glob `bash ./undo-1228*.sh`", "bash ./undo-1228*.sh", /not statically resolvable/],
      ["char-class `bash ./undo-1228-[g]lob.sh`", "bash ./undo-1228-[g]lob.sh", /not statically resolvable/],
      ["brace `bash ./undo-1228{-glob,}.sh`", "bash ./undo-1228{-glob,}.sh", /not statically resolvable/],
      ["tilde `bash ~/undo-1228.sh`", "bash ~/undo-1228.sh", /not statically resolvable/],
      ["extglob via `bash -O extglob -c 'bash ./undo-1228@(-glob|).sh'` (the reachable form)", "bash -O extglob -c 'bash ./undo-1228@(-glob|).sh'", /not statically resolvable/],
      ["direct `./undo-1228*.sh`", "./undo-1228*.sh", /not statically resolvable/],
      ["direct `~/undo-1228.sh`", "~/undo-1228.sh", /not statically resolvable/],
      ["direct static relative `sub-1228/undo.sh` (executable, previously unread)", "sub-1228/undo.sh", /#709/],
      ["pipe glob `cat ./undo-1228*.sh | bash`", "cat ./undo-1228*.sh | bash", /piped producer/],
      ["pipe char-class `cat ./undo-1228-[g]lob.sh | bash`", "cat ./undo-1228-[g]lob.sh | bash", /piped producer/],
      ["pipe variable `F=./undo-1228.sh; cat $F | bash`", "F=./undo-1228.sh; cat $F | bash", /piped producer/],
      // #1228 — the SAME expanded path behind the indirection wrappers the
      // walk also reads (`-c` payload, `eval` payload, nested script). These
      // are ordinary agent shapes; each was a one-level-in fail-open.
      ["interpreter `-c` payload `bash -c 'bash ./undo-1228*.sh'`", "bash -c 'bash ./undo-1228*.sh'", /not statically resolvable/],
      ["interpreter `-c` payload `sh -c 'source ./undo-1228*.sh'`", "sh -c 'source ./undo-1228*.sh'", /not statically resolvable/],
      ["`eval` payload `eval 'bash ./undo-1228*.sh'`", "eval 'bash ./undo-1228*.sh'", /not statically resolvable/],
      ["nested script runs an expanded path (`bash ./outer-1228.sh`)", "bash ./outer-1228.sh", /not statically resolvable/],
      // #1228 review cycle 1 — the piped-producer form is ALSO reachable one
      // level in. The first cut checked it only at the TOP level, so
      // `bash -c 'cat ./undo*.sh | bash'` (and the `eval` / nested-script
      // equivalents) still ALLOWED while destroying the tree. Each row below
      // was reproduced as ALLOW+destroy on the pre-fix head.
      ["bare `?` glob `bash ./undo-1228?.sh`", "bash ./undo-1228?.sh", /not statically resolvable/],
      ["pipe glob inside `-c` payload `bash -c 'cat ./undo-1228*.sh | bash'`", "bash -c 'cat ./undo-1228*.sh | bash'", /piped producer/],
      ["pipe char-class inside `-c` payload `sh -c 'cat ./undo-1228-[g]lob.sh | bash'`", "sh -c 'cat ./undo-1228-[g]lob.sh | bash'", /piped producer/],
      ["pipe variable inside `-c` payload `bash -c 'F=./undo-1228.sh; cat $F | bash'`", "bash -c 'F=./undo-1228.sh; cat $F | bash'", /piped producer/],
      ["pipe tilde inside `eval` payload `eval 'cat ~/undo-1228.sh | bash'`", "eval 'cat ~/undo-1228.sh | bash'", /piped producer/],
      ["nested script pipes an expanded path (`bash ./outer-pipe-1228.sh`)", "bash ./outer-pipe-1228.sh", /piped producer/],
      ["nested script BODY is a bare pipe (`bash ./outer-bare-pipe-1228.sh`)", "bash ./outer-bare-pipe-1228.sh", /piped producer/],
      ["variable-resolved `-c` payload `S='cat ./undo-1228*.sh | bash'; bash -c \"$S\"`", "S='cat ./undo-1228*.sh | bash'; bash -c \"$S\"", /piped producer/],
      ["`$(cat FILE)` payload whose file pipes an expanded path", "bash -c \"$(cat ./producer-1228.sh)\"", /piped producer/],
      ["variable-resolved `eval` payload `P='cat ./undo-1228*.sh | bash'; eval \"$P\"`", "P='cat ./undo-1228*.sh | bash'; eval \"$P\"", /piped producer/],
      ["nested script named by a `-c` payload (`bash -c 'bash ./outer-glob-payload-1228.sh'`)", "bash -c 'bash ./outer-glob-payload-1228.sh'", /not statically resolvable/],
      ["nested script named by an `eval` payload (`eval 'bash ./outer-glob-payload-1228.sh'`)", "eval 'bash ./outer-glob-payload-1228.sh'", /not statically resolvable/],
      // #1228 review cycle 2 — a script invocation after a SEPARATOR is still
      // the interpreter-operand position; the position-0 arms missed it and the
      // discard ran ungated.
      ["prefixed `&&` `true && bash ./undo-1228*.sh`", "true && bash ./undo-1228*.sh", /not statically resolvable/],
      ["prefixed `;` `true; bash ./undo-1228*.sh`", "true; bash ./undo-1228*.sh", /not statically resolvable/],
      ["prefixed `then` `if true; then bash ./undo-1228*.sh; fi`", "if true; then bash ./undo-1228*.sh; fi", /not statically resolvable/],
      ["prefixed inside `-c` payload `bash -c 'true; bash ./undo-1228*.sh'`", "bash -c 'true; bash ./undo-1228*.sh'", /not statically resolvable/],
      ["`$(cat glob)` `-c` payload `bash -c \"$(cat ./undo-1228*.sh)\"`", "bash -c \"$(cat ./undo-1228*.sh)\"", /not statically resolvable/],
      ["`$(cat glob)` `eval` payload `eval \"$(cat ./undo-1228*.sh)\"`", "eval \"$(cat ./undo-1228*.sh)\"", /not statically resolvable/],
      ["process substitution `bash <(cat ./undo-1228*.sh)`", "bash <(cat ./undo-1228*.sh)", /not statically resolvable/],
      ["depth-2 `-c` chain `bash -c \"bash -c 'bash ./undo-1228*.sh'\"`", "bash -c \"bash -c 'bash ./undo-1228*.sh'\"", /not statically resolvable/],
      ["`eval` `$VAR` names a nested script `W=./outer-pipe-1228.sh; eval \"bash $W\"`", "W=./outer-pipe-1228.sh; eval \"bash $W\"", /not statically resolvable/],
    ];
    for (const [why, cmd, reasonRe] of exp1228) {
      write(join(wt, "dirty.txt"), "MUTANT\n");
      const r = await bash(cmd, wt);
      expectTrue(`B13: ${why} → BLOCKED`, blocked(r), JSON.stringify(r)?.slice(0, 200));
      expectTrue(`B13: ${why} → reason names what was observed`,
        reasonRe.test(blockReason1228(r)), `reason=${JSON.stringify(blockReason1228(r)).slice(0, 240)}`);
    }
    // Documented fail-closed COST, not a bug: an expansion-shaped path is
    // refused WITHOUT reading it, so a glob that happens to match only a clean
    // script blocks too. That is the accepted price of the fix — resolving
    // globs would re-open a (globbing-semantics) mismatch between the guard's
    // expansion and the shell's, which is the fail-open class #1228 closes.
    // The reason must offer the literal-spelling remedy.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const cleanGlob = await bash("bash ./cleanonly-1228*.sh", wt);
    expectTrue("B13: glob over a CLEAN script BLOCKED (documented fail-closed cost) and offers the literal remedy",
      blocked(cleanGlob) && /pass the path literally/.test(blockReason1228(cleanGlob)),
      `reason=${JSON.stringify(blockReason1228(cleanGlob)).slice(0, 240)}`);
    // Negative control: a piped producer with no expansion and no discard stays
    // allowed (the arm must not fail closed on every pipe into a shell).
    expectTrue("B13: `printf 'hello\\n' | bash` ALLOWED (no expansion, no discard)",
      allowed(await bash("printf 'hello\\n' | bash", wt)), "was blocked");
    // Regression control (review cycle-1 P2): the extglob raw-word scan must
    // NOT refuse a non-script command whose ARGUMENT carries an extglob
    // operator. All three were ALLOWED before #1228 and were blocked by its
    // first cut, which scanned every word of every command.
    for (const cmd of ["git add src/@(a|b).ts", "rg -n 'foo' src/@(a|b).ts", "find . -path '*/@(a|b)/*'", "python3 -c \"print(1/2*(3+4))\"", "node -e 'const x=a/b*(c)'", "awk 'BEGIN{print 1/2*(3)}' f"]) {
      write(join(wt, "dirty.txt"), "MUTANT\n");
      expectTrue(`B13: non-script extglob/arith argument ALLOWED — ${cmd}`, allowed(await bash(cmd, wt)), "was blocked");
    }
    // The refusal must name the OBSERVED text and HEDGE the runtime expansion:
    // a QUOTED metachar path is not expanded by the shell, so asserting "is
    // expanded by the shell at runtime" is a claim the guard cannot observe
    // (#1229/#1210). Pins the reworded reason.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const quotedGlob = await bash("bash './undo-1228*.sh'", wt);
    expectTrue("B13: quoted metachar path BLOCKED with a HEDGED reason (no unobserved expansion claim)",
      blocked(quotedGlob) && /not statically resolvable/.test(blockReason1228(quotedGlob)) &&
        !/is expanded by the shell at runtime/.test(blockReason1228(quotedGlob)),
      `reason=${JSON.stringify(blockReason1228(quotedGlob)).slice(0, 240)}`);
    // Documented fail-closed cost (review cycle-1 P3): the piped-producer arm
    // cannot tell a producer token that names the piped FILE from one that names
    // a PATTERN argument, so `grep '<glob-regex>' file | bash` is refused.
    // Narrowing it to path-like tokens would REOPEN the measured
    // `cat undo-[12].sh | bash` bypass (no `/` in the token), so the over-block
    // stands. Pinned here so it is a recorded cost, not a silent one.
    write(join(wt, "dirty.txt"), "MUTANT\n");
    expectTrue("B13: `grep -n 'foo*' file | bash` BLOCKED (documented producer-token over-block)",
      blocked(await bash("grep -n 'foo*' file | bash", wt)), "was allowed");
    // Regression control (review cycle-2): a script body carrying an ASSIGNMENT
    // and a `case` pattern must be ALLOWED — the new command-segment scan read
    // both as commands and false-blocked the SANCTIONED recovery helper (B12a).
    write(join(wt, "dirty.txt"), "MUTANT\n");
    expectTrue("B13: a script body with an assignment + `case` pattern is ALLOWED (no discard)",
      allowed(await bash("bash ./case-pattern-1228.sh", wt)), "was blocked");
    execSync("git checkout -- dirty.txt", { cwd: wt, stdio: "ignore" });
    for (const f of [undoExp, undoExpGlob, undoExpHome, undoExpSub, undoCleanGlob, outerExp, outerPipeExp, producerExp, outerBarePipeExp, outerGlobPayload, casePatternExp]) rmSync(f, { force: true });

    // ── B11: escape hatches unchanged ──
    write(join(wt, "dirty.txt"), "MUTANT\n");
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    expectTrue("B11a: env hatch (AGENT_ALLOW_MAIN_EDITS=1) bypasses M5",
      allowed(await bash("git checkout -- dirty.txt", wt)), "was blocked");
    delete process.env.AGENT_ALLOW_MAIN_EDITS;
    expectTrue("B11b: removing the hatch re-arms M5",
      blocked(await bash("git checkout -- dirty.txt", wt)), "was allowed");
    // Marker: stamped JSON, session-scoped, TTL'd (#207).
    process.env.PI_SESSION_ID = "discard-gate-sid";
    write(join(home, ".pi", "agent", ".allow-main-edits"),
      JSON.stringify({ session_id: "discard-gate-sid", reason: "#709 test", ts: new Date().toISOString() }) + "\n");
    expectTrue("B11c: stamped TTL marker bypasses M5",
      allowed(await bash("git checkout -- dirty.txt", wt)), "was blocked");
    rmSync(join(home, ".pi", "agent", ".allow-main-edits"), { force: true });
    delete process.env.PI_SESSION_ID;
    expectTrue("B11d: removing the marker re-arms M5",
      blocked(await bash("git checkout -- dirty.txt", wt)), "was allowed");

    // ── B13 (#1125): a `cat-file-revert` HINT with NO write surface is NOT a
    // discard — the sanctioned read-only triage tool must be RUNNABLE ──
    //
    // The form models "committed content reproduced onto its own path"
    // (`git show HEAD:x > x`); the handler intersects the hint with the
    // command's bash write targets for exactly that reason. With NO write
    // target there is nowhere for the content to land. The fail-closed arm on
    // an UNRESOLVABLE pathspec ran BEFORE that intersection, so a purely
    // read-only probe whose path is a loop variable was refused:
    // `scripts/stale-main-triage.sh` (the sanctioned diagnosis tool) could not
    // be run by an agent, and the 2026-09-17 fleet-durability sweep hit the
    // same construct in three repos. The negative controls below are the pins
    // that this is an ordering fix, NOT a relaxation of the discard gate.
    //
    // The triage tool, driven on the DIRTY hub state it exists to diagnose
    // (M4 is active there too — its git surface is read-only, so it must pass
    // BOTH gates).
    write(join(hub, "dirty.txt"), "MUTANT-HUB\n");
    const triage = join(HERE, "..", "..", "scripts", "stale-main-triage.sh");
    const triageRun = await bash(`bash "${triage}" --repo "${hub}"`, hub);
    expectTrue("B13a (#1125): the sanctioned read-only triage tool RUNS on a dirty hub (was: `the target pathspec is not statically resolvable`)",
      allowed(triageRun), `reason=${JSON.stringify(triageRun?.reason ?? "").slice(0, 240)}`);
    // The sweep's shape: a per-file read-only existence probe inside a loop.
    expectTrue("B13b (#1125): a `for`-loop `git cat-file -e \"origin/$ref:$f\"` probe (no write surface) is ALLOWED",
      allowed(await bash(`for f in clean.txt; do git cat-file -e "origin/main:$f" || echo "not in origin"; done`, wt)),
      "was blocked — a read-only existence probe is not a discard");
    // Negative control 1: the SAME invocation WITH a landing redirect is still a
    // real revert and must stay blocked (the loop variable makes the hint
    // unresolvable, so this exercises the fail-closed arm the fix narrowed).
    write(join(wt, "dirty.txt"), "MUTANT\n");
    expectTrue("B13c (control): `for f in …; do git cat-file -e \"HEAD:$f\" > \"$f\"; done` is STILL BLOCKED (a write surface exists)",
      blocked(await bash(`for f in dirty.txt; do git cat-file -e "HEAD:$f" > "$f"; done`, wt)),
      "was allowed — the committed content lands on a write target");
    // Negative control 2: a RESOLVABLE hint that lands on its own path is
    // unchanged (`git show HEAD:x > x` — the form's core case).
    expectTrue("B13d (control): a resolvable hint that lands on its own path (`git show HEAD:dirty.txt > dirty.txt`) is STILL BLOCKED",
      blocked(await bash("git show HEAD:dirty.txt > dirty.txt", wt)),
      "was allowed — the discard gate was relaxed");
    // Negative control 3: a resolvable hint with NO write surface stays allowed
    // (unchanged pre-existing behaviour — the fix only aligns the unresolvable
    // case with it).
    expectTrue("B13e (control): a resolvable hint with no write surface (`git cat-file -e HEAD:dirty.txt`) stays ALLOWED",
      allowed(await bash("git cat-file -e HEAD:dirty.txt", wt)),
      "was blocked — the fix over-tightened");

    // ── B14 (#1125): the M4 block NAMES the disordered checkout + condition ──
    // `"the shared main checkout"` was ambiguous across a machine with several
    // checkouts: it sent two agents to the wrong repository for ~40 minutes and
    // produced a destructive-command request against a healthy repo, because
    // the disorder was in a DIFFERENT (unnamed) checkout. The hub is DIRTY
    // right now (B13a), on main → the block must print `off-main`/`dirty` with
    // the ABSOLUTE path, on BOTH the bash route and the write/edit route.
    const bashMsg = (await bash("git commit -m x", hub))?.reason ?? "";
    expectTrue("B14a: the bash-route M4 block NAMES the checkout and its resolved condition",
      bashMsg.includes(`   Checkout: ${hub} (`) && bashMsg.includes("dirty: 1 path(s)"),
      `reason=${JSON.stringify(bashMsg).slice(0, 260)}`);
    process.chdir(hub);
    let writeBlock;
    try { writeBlock = await toolCall({ toolName: "write", input: { path: join(hub, "clean.txt") } }, undefined); }
    finally { process.chdir(prevCwd); }
    const writeMsg = writeBlock?.reason ?? "";
    expectTrue("B14b: the write/edit-route M4 block NAMES the checkout too (same ambiguity, same fix)",
      !!writeBlock?.block && writeMsg.includes(`   Checkout: ${hub} (`) && writeMsg.includes("dirty: 1 path(s)"),
      `reason=${JSON.stringify(writeMsg).slice(0, 260)}`);

    execSync("git checkout -q -- dirty.txt", { cwd: wt, stdio: "ignore" });
    execSync("git checkout -q -- dirty.txt && git clean -qfd", { cwd: hub, stdio: "ignore" });
  } catch (e) {
    expectTrue("B: part B ran without throwing", false, String(e?.message ?? e).slice(0, 240));
  } finally {
    process.chdir(prevCwd);
    for (const [v, val] of savedEnv) {
      if (val === undefined) delete process.env[v]; else process.env[v] = val;
    }
    try { execSync(`git worktree remove --force "${wt}"`, { cwd: hub, stdio: "ignore" }); } catch { /* best-effort */ }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await partB();

// ────────────────────────────────────────────────────────────────────────
// Part C (#1139, threat class T6) — a guard loaded from a checkout that does
// NOT carry the listed scripts must FAIL CLOSED, not fail open. `_frameworkRoot`
// is derived from the guard's own module URL; when no listed relpath exists
// under it, `realpathSync(resolve(_frameworkRoot, rel))` throws for every entry,
// `_sanctionedScriptExemption` returns null, and the exemption must be INERT —
// the harvested set stays gated. The fixture is a COPY of the extension in a
// layout with no `scripts/`, driven against the SAME command and the SAME cwd
// as the anchor-correct control, so the only difference is the anchor.
// ────────────────────────────────────────────────────────────────────────
async function partC() {
  const tmpc = realpathSync(mkdtempSync(join(tmpdir(), "guard-noanchor-")));
  const prevCwd = process.cwd();
  const savedEnv = [...HATCH_VARS, "HOME", "PI_SESSION_ID"].map((v) => [v, process.env[v]]);
  try {
    const extDir = join(tmpc, "extensions", "main-worktree-guard");
    mkdirSync(join(tmpc, "extensions", "shared"), { recursive: true });
    mkdirSync(extDir, { recursive: true });
    for (const f of ["index.ts", "classify-git.mjs"]) copyFileSync(join(HERE, f), join(extDir, f));
    for (const f of ["print-mode.ts", "audit-log.ts", "branch-ownership.mjs"]) copyFileSync(join(HERE, "..", "shared", f), join(tmpc, "extensions", "shared", f));
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.HOME = tmpc; // no TTL marker under this HOME
    delete process.env.PI_SESSION_ID;
    // Capture the guard's one-time load warnings so C0 can prove the fixture
    // differs from the real guard in EXACTLY one respect — the framework root.
    // (A load fallback would disable M1/M2/M3 and the C1 block below could then
    // be attributed to the wrong walk.) The copy's realpath is what makes
    // `_frameworkRoot` = tmpc, which carries no `scripts/`.
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => { warnings.push(a.map(String).join(" ")); };
    let mod;
    try { mod = await import(pathToFileURL(join(extDir, "index.ts")).href); }
    finally { console.warn = realWarn; }
    const handlers = new Map();
    mod.default({ on(n, fn) { if (!handlers.has(n)) handlers.set(n, []); handlers.get(n).push(fn); } });
    const inertToolCall = handlers.get("tool_call")?.[0];
    // The framework checkout owns the SANCTIONED path; the SESSION cwd is a
    // HERMETIC repo that carries tracked dirt, and both arms are driven from
    // there. #1060 made the session cwd's dirt load-bearing: the M5 arm is now
    // decided on state, so a fixture that sat in the (clean, in CI) framework
    // checkout made C1's expectation depend on whether whoever ran the suite
    // happened to have uncommitted edits — which is precisely how the arm was
    // decided anyway, and which CI caught. The hermetic dirty cwd makes the
    // pair deterministic AND stronger: the ONLY difference between C1 and C2 is
    // the loaded guard, the command is identical, and the candidate checkout
    // holds real tracked dirt the discard would destroy.
    const frameworkCheckout = realpathSync(join(HERE, "..", ".."));
    const sanctioned = join(frameworkCheckout, "scripts", "checkout-hygiene", "hub-worktree.sh");
    const cmd = `bash "${sanctioned}"`;
    const cHub = join(tmpc, "c-hub");
    execSync(`git init -q -b main "${cHub}"`, { cwd: tmpc, stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: cHub, stdio: "ignore" });
    writeFileSync(join(cHub, "wip.txt"), "v1\n");
    execSync("git add -A && git commit -qm init", { cwd: cHub, stdio: "ignore" });
    writeFileSync(join(cHub, "wip.txt"), "MUTANT\n"); // tracked dirt
    process.chdir(cHub);
    expectTrue("C0: the fixture guard loads with its non-M5 machinery intact (the anchor is the only difference)",
      !warnings.some((w) => /DISABLED/.test(w)), `warnings=${JSON.stringify(warnings).slice(0, 240)}`);
    const inert = await inertToolCall?.({ toolName: "bash", input: { command: cmd } }, undefined);
    expectTrue("C1 (#1139 T6): an anchor carrying NO listed script keeps the discard GATED — with tracked dirt in the candidate checkout that is a BLOCK (the exemption is inert, never fail-open)",
      !!inert && inert.block === true && /#709/.test(inert.reason ?? "") && /cat-file-revert/.test(inert.reason ?? ""),
      `handler returned ${JSON.stringify(inert)?.slice(0, 240)}`);
    // Control: the SAME command, SAME cwd, through the anchor-CORRECT guard.
    // The exemption drops the harvested set, so the discard arm has nothing to
    // decide even though the candidate checkout is dirty — which is what makes
    // C1 a test of the ANCHOR and not of the dirt.
    const real = await import(pathToFileURL(INDEX_TS).href);
    const rh = new Map();
    real.default({ on(n, fn) { if (!rh.has(n)) rh.set(n, []); rh.get(n).push(fn); } });
    const anchored = await rh.get("tool_call")[0]({ toolName: "bash", input: { command: cmd } }, undefined);
    expectTrue("C2 control: the SAME command through the anchor-CORRECT guard is ALLOWED (the exemption fires on a dirty candidate)",
      anchored === undefined || anchored === null,
      `handler returned ${JSON.stringify(anchored)?.slice(0, 240)}`);
  } catch (e) {
    expectTrue("C: part C ran without throwing", false, String(e?.message ?? e).slice(0, 240));
  } finally {
    process.chdir(prevCwd);
    for (const [v, val] of savedEnv) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(tmpc, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await partC();

// ────────────────────────────────────────────────────────────────────────
// Part D (#1060) — the `cat-file-revert` arm is decided on STATE.
//
// The arm used to intersect the SOURCE pathspec (`HEAD:<path>`) with the
// command's bash write targets by EXACT STRING EQUALITY of two independently
// anchored templates. Measured on `origin/main` (`3262a25c`, and on `41efece`
// where the issue was filed), with `dirty.txt` tracked and modified in the hub:
//
//     MAIN_REPO=<hub>; git -C "$MAIN_REPO" show HEAD:dirty.txt > "$MAIN_REPO/dirty.txt"
//
// is ALLOWED. The two spellings of the ONE path do not compare equal, so the arm
// `continue`d; the redirect reverts TRACKED, MODIFIED hub content that was never
// a git object and has no other copy — unrecoverable loss. The same template
// weakness in the other direction is #940's friction: a `$var` pathspec
// (`HEAD:"$x"`) matches no literal target either, but the generic
// unresolvable-pathspec rule catches it and fails CLOSED, refusing a read-only
// `git show` on a provably pristine checkout.
//
// D1–D3 pin the closure. D4–D6 pin the #940 shapes (allowed on a pristine
// fixture, blocked where tracked dirt is reachable). D7 is the negative-control
// surface. D8 pins the second reachability gap the issue names in the same code
// path: M4's disorder early-return used to return BEFORE M5 ever evaluated, so
// on a disordered hub the `HEAD:"$x" > "$x"` self-overwrite was allowed and
// nothing else could decide it.
// ────────────────────────────────────────────────────────────────────────
async function partD() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("D: real index.ts load", `node ${process.versions.node} lacks module.stripTypeScriptTypes`);
    return;
  }
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");
  const realWarn = console.warn;
  console.warn = () => {};
  let mod;
  try { mod = await import(pathToFileURL(INDEX_TS).href); } finally { console.warn = realWarn; }
  const handlers = new Map();
  mod.default({ on(n, fn) { if (!handlers.has(n)) handlers.set(n, []); handlers.get(n).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  if (typeof toolCall !== "function") { expectTrue("D0: factory registered a tool_call handler", false, "none"); return; }

  const tmpd = realpathSync(mkdtempSync(join(tmpdir(), "discard-1060-")));
  const hub = join(tmpd, "hub");
  const wt = join(tmpd, "wt");
  const wt2 = join(tmpd, "wt2");
  const home = join(tmpd, "home");
  const prevCwd = process.cwd();
  const savedEnv = [...HATCH_VARS, "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"]
    .map((v) => [v, process.env[v]]);
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
  try {
    sh(`git init -q -b main "${hub}"`, tmpd);
    gg("config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "clean.txt"), "v1\n");
    writeFileSync(join(hub, "dirty.txt"), "v1\n");
    gg("add -A && git commit -qm init", hub);
    gg(`worktree add -q -b feat "${wt}"`, hub);
    gg(`worktree add -q -b feat2 "${wt2}"`, hub);
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;
    process.env.SKILL_ENFORCER_DISABLED = "1";

    const bash = async (command, cwd) => {
      process.chdir(cwd);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prevCwd); }
    };
    const allowed = (r) => r === undefined || r === null;
    const blocked = (r) => !!r && r.block === true;
    const reason = (r) => String(r?.reason ?? "");
    const hubDirty = () => writeFileSync(join(hub, "dirty.txt"), "MUTANT-HUB\n");
    const hubClean = () => { gg("checkout -q -- dirty.txt", hub); };
    const setScript = join(tmpd, "argscript-1060.sh");
    writeFileSync(setScript, '#!/bin/sh\nf="$1"\ngit show HEAD:"$f" > "$f"\n');
    const sanctionedD = realpathSync(join(HERE, "..", "..", "scripts", "checkout-hygiene", "hub-worktree.sh"));

    // ── D1: the fail-open itself, in BOTH session geometries ──
    // The issue measured it from a tracked-dirty hub; the worktree-rooted
    // geometry is the one a `pi -p` child actually runs in, and it is closed by
    // resolving a same-command `NAME=<literal>` assignment in the write target
    // (`$MAIN_REPO` here) instead of comparing templates.
    const X4 = `MAIN_REPO=${hub}; git -C "$MAIN_REPO" show HEAD:dirty.txt > "$MAIN_REPO/dirty.txt"`;
    hubDirty();
    const x4Hub = await bash(X4, hub);
    expectTrue("D1a (#1060): a self-overwrite of TRACKED-DIRTY hub content via `-C \"$MAIN_REPO\"` is BLOCKED from a hub-rooted session",
      blocked(x4Hub) && /#709/.test(reason(x4Hub)) && /cat-file-revert/.test(reason(x4Hub)),
      `reason=${JSON.stringify(reason(x4Hub)).slice(0, 240)}`);
    const x4Wt = await bash(X4, wt);
    expectTrue("D1b (#1060): … and BLOCKED from a WORKTREE-rooted session (the same-command `$MAIN_REPO` is resolved before the probe)",
      blocked(x4Wt) && /#709/.test(reason(x4Wt)), `reason=${JSON.stringify(reason(x4Wt)).slice(0, 240)}`);
    expectTrue("D1c: the block names the checkout that actually carries the dirt (the HUB), not the session's own clean worktree",
      /Checkout: .*\/hub\b/.test(reason(x4Wt)), `reason=${JSON.stringify(reason(x4Wt)).slice(0, 240)}`);
    // The converse: no new block when nothing is at stake. A pristine hub must
    // ALLOW the shape — a fail-closed-on-text arm would block it, and that is
    // exactly how #940's friction was produced.
    hubClean();
    expectTrue("D2: on a PRISTINE hub the same command is ALLOWED (the fix must not become a blanket block)",
      allowed(await bash(X4, hub)), "was blocked");

    // ── D3: the same-command variable in the session's own tree ──
    writeFileSync(join(wt, "dirty.txt"), "MUTANT-WT\n");
    const x6 = await bash('F=dirty.txt; git show HEAD:dirty.txt > "$F"', wt);
    expectTrue("D3: `F=dirty.txt; git show HEAD:dirty.txt > \"$F\"` on a dirty tree is BLOCKED (the target is not the literal spelling)",
      blocked(x6) && /#709/.test(reason(x6)), `reason=${JSON.stringify(reason(x6)).slice(0, 240)}`);
    writeFileSync(join(wt, "dirty.txt"), "v1\n");

    // ── D4: the four #940 shapes on a PRISTINE hub — all ALLOWED ──
    // F1 is the framework's own recovery helper (exempt by #1139's sanctioned
    // list, which is checked BEFORE the discard walk and is deliberately NOT
    // affected by this change: the helper exists to revert the hub's tracked
    // dirt after capturing it, so blocking it on a dirty hub would break the
    // recovery path #1139 re-opened).
    hubClean();
    const f1 = await bash(`bash "${sanctionedD}"`, hub);
    expectTrue("D4a (#940 F1): the sanctioned recovery helper is ALLOWED on a pristine hub",
      allowed(f1), `reason=${JSON.stringify(reason(f1)).slice(0, 200)}`);
    const f2 = await bash(`bash -n ${setScript}`, hub);
    expectTrue("D4b (#940 F2): `bash -n <script>` (a pure syntax check) is ALLOWED on a pristine hub",
      allowed(f2), `reason=${JSON.stringify(reason(f2)).slice(0, 200)}`);
    const f3 = await bash(`x=dirty.txt; git show HEAD:"$x" > /tmp/1060-d4-f3.txt`, hub);
    expectTrue("D4c (#940 F3): `git show HEAD:\"$x\" > /tmp/…` is ALLOWED on a pristine hub",
      allowed(f3), `reason=${JSON.stringify(reason(f3)).slice(0, 200)}`);
    const f4 = await bash(`bash ${setScript} dirty.txt`, hub);
    expectTrue("D4d (#940 F4): an arg-taking script with a `$var` pathspec is ALLOWED on a pristine hub",
      allowed(f4), `reason=${JSON.stringify(reason(f4)).slice(0, 200)}`);

    // ── D5: …and BLOCKED when the checkout the command runs in is dirty ──
    // The question is about STATE, so on a tracked-dirty checkout the three
    // non-sanctioned shapes keep failing CLOSED (they did before this change
    // too — no new blocks on a dirty tree).
    hubDirty();
    expectTrue("D5a (#940 F2): `bash -n <script>` is BLOCKED on a tracked-dirty hub",
      blocked(await bash(`bash -n ${setScript}`, hub)), "was allowed");
    expectTrue("D5b (#940 F3): `git show HEAD:\"$x\" > /tmp/…` is BLOCKED on a tracked-dirty hub",
      blocked(await bash(`x=dirty.txt; git show HEAD:"$x" > /tmp/1060-d5-f3.txt`, hub)), "was allowed");
    expectTrue("D5c (#940 F4): the `$var` reader is BLOCKED on a tracked-dirty hub",
      blocked(await bash(`bash ${setScript} dirty.txt`, hub)), "was allowed");
    expectTrue("D5d (#940 F1): the SANCTIONED helper stays ALLOWED on a dirty hub — #1139's exemption is deliberate and precedes the walk",
      allowed(await bash(`bash "${sanctionedD}"`, hub)), "was blocked — the recovery path #1139 re-opened");

    // ── D7: negative controls — nothing that blocks today may start to allow ──
    // (Run on the same tracked-dirty hub, so each row is a live discard.)
    for (const [why, cmd, cwd] of [
      ["literal self-overwrite", "git show HEAD:dirty.txt > dirty.txt", wt],
      ["index-source self-overwrite", "git show :dirty.txt > dirty.txt", wt],
      ["plain path restore", "git checkout -- dirty.txt", wt],
      ["tree-source path restore", "git checkout HEAD -- dirty.txt", wt],
      ["bare restore", "git restore dirty.txt", wt],
      ["worktree-wide checkout", "git checkout -- .", wt],
    ]) {
      writeFileSync(join(wt, "dirty.txt"), "MUTANT-WT\n");
      const r = await bash(cmd, cwd);
      expectTrue(`D7: negative control — \`${why}\` still BLOCKED`, blocked(r), JSON.stringify(r)?.slice(0, 160));
      writeFileSync(join(wt, "dirty.txt"), "v1\n");
    }
    // The ALLOW half: a bare read and a `/dev/null` sink destroy nothing, and
    // untracked-only dirt is not tracked loss. These are the rows that catch an
    // over-broad rewrite of this arm.
    const allowRows = [
      ["bare read (`git show HEAD:dirty.txt`, no redirect)", "git show HEAD:dirty.txt", wt],
      // The pure-read half of the #940 friction: an unresolvable SOURCE with no
      // redirect destroys nothing, so it must not reach the fail-closed arm.
      ["bare read with a `$var` source (`git show HEAD:\"$x\"`)", 'x=dirty.txt; git show HEAD:"$x"', wt],
      ["`/dev/null` sink", "git show HEAD:dirty.txt > /dev/null", wt],
    ];
    for (const [why, cmd, cwd] of allowRows) {
      writeFileSync(join(wt, "dirty.txt"), "MUTANT-WT\n");
      hubDirty();
      const r = await bash(cmd, cwd);
      expectTrue(`D7: negative control — \`${why}\` ALLOWED (nothing is discarded)`, allowed(r),
        `blocked: ${JSON.stringify(reason(r)).slice(0, 160)}`);
      writeFileSync(join(wt, "dirty.txt"), "v1\n");
      hubClean();
    }
    // The outside-checkout sink is the arm's DECLARED FAIL-CLOSED COST, on BOTH
    // sides of the state line — pinned so it is a recorded choice and not an
    // accident. `git show HEAD:dirty.txt > /tmp/out` provably discards nothing,
    // but the predicate asks whether a candidate checkout is pristine rather
    // than proving the target is elsewhere (the issue's criterion 2 states
    // exactly this: the #940 shapes are ALLOWED on a pristine hub and BLOCKED on
    // a tracked-dirty one). Over-blocking is the direction this arm deliberately
    // errs in: one wrong ALLOW here is unrecoverable, one wrong BLOCK costs a
    // retry. A relaxant that scopes the `writeCwd` probe away when every target
    // is statically outside every checkout would restore the allow — that is the
    // documented trade, not a bug to "fix" silently.
    hubClean();
    expectTrue("D7: outside-checkout sink on a PRISTINE tree ALLOWED (the cost is state-conditional, not constant)",
      allowed(await bash(`git show HEAD:dirty.txt > ${tmpd}/1060-d7-clean.txt`, hub)), "was blocked");
    hubDirty();
    expectTrue("D7: outside-checkout sink on a TRACKED-DIRTY tree BLOCKED (declared fail-closed cost, criterion 2)",
      blocked(await bash(`git show HEAD:dirty.txt > ${tmpd}/1060-d7-dirty.txt`, hub)), "was allowed");
    // Untracked-only dirt in a candidate checkout is NOT tracked loss — the arm
    // must not degrade into "any dirt anywhere blocks".
    writeFileSync(join(hub, "scratch-untracked-1060.txt"), "wip\n");
    hubClean(); // tracked content restored — only the untracked file is left
    expectTrue("D7: untracked-only dirt in the hub → the X4 shape is ALLOWED (no tracked loss)",
      allowed(await bash(X4, wt)), "was blocked");
    rmSync(join(hub, "scratch-untracked-1060.txt"), { force: true });

    // ── D8: M4's disorder early-return must not shadow M5 ──
    // The issue names this as a second reachability gap in the same region, to
    // be assessed with the fix rather than separately. Measured before the fix
    // on a DISORDERED hub from a hub-rooted session, this command was ALLOWED:
    // M4 returned (the "recovery/allowed, non-push" early return) before M5 ran,
    // `_hubBashTrackedWrite` cannot see a `$x` redirect, and `git show` is
    // read-only by classification — so nothing decided it. The hub's own tracked
    // dirt is exactly what it destroys.
    hubDirty();
    const shadow = await bash('x=dirty.txt; git show HEAD:"$x" > "$x"', hub);
    expectTrue("D8 (#1060): on a DISORDERED hub the `HEAD:\"$x\" > \"$x\"` self-overwrite is BLOCKED (M4 no longer shadows M5)",
      blocked(shadow) && /#709/.test(reason(shadow)), `reason=${JSON.stringify(reason(shadow)).slice(0, 240)}`);

    // ── D9: the reason names the REDIRECT, never the source ──
    // `git show HEAD:clean.txt > <target>` discards the TARGET; a message that
    // names the source is the misattribution class #1139 removed from this very
    // function. The target here is spelled through TWO variables, so only the
    // state predicate (not the tracked-write gate) can own the decision.
    hubDirty();
    const cross = await bash(`M=${hub}; T=dirty.txt; git -C "$M" show HEAD:clean.txt > "$M/$T"`, wt);
    expectTrue("D9 (#1060): the block for a cross-path revert names the REDIRECT target (`dirty.txt`), not the source (`clean.txt`)",
      blocked(cross) && /#709/.test(reason(cross)) &&
      /Target: dirty\.txt/.test(reason(cross)) && !/Target: clean\.txt/.test(reason(cross)),
      `reason=${JSON.stringify(reason(cross)).slice(0, 300)}`);
    hubClean();
  } catch (e) {
    expectTrue("D: part D ran without throwing", false, String(e?.message ?? e).slice(0, 240));
  } finally {
    process.chdir(prevCwd);
    for (const [v, val] of savedEnv) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { execSync(`git worktree remove --force "${wt}"`, { cwd: hub, stdio: "ignore" }); } catch { /* best-effort */ }
    try { execSync(`git worktree remove --force "${wt2}"`, { cwd: hub, stdio: "ignore" }); } catch { /* best-effort */ }
    try { rmSync(tmpd, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await partD();

// ────────────────────────────────────────────────────────────────────────
// Part M (#2161) — MUTATION EVIDENCE: the new pins must be able to FAIL.
//
// A pin that cannot go red is not a pin. Each row below reintroduces ONE of the
// three defects into a TEMP copy of `classify-git.mjs`, imports that copy, and
// requires the PAIRED pinned source to go BLIND (zero descriptors). If the
// mutated copy still detects the discard, the pin is not discriminating and
// this suite FAILS — the same construction the fleet-liveness suite uses
// (`tools/fleet/liveness.test.py --mutations`) rather than a prose claim that
// the tests "would catch it".
//
// The defects are reintroduced as TEXTUAL reverts of this change, so each one is
// provably the edit it claims to be (and the pre-mutation module is imported
// alongside, so a mutation that silently failed to apply cannot pass either).
// ────────────────────────────────────────────────────────────────────────
if (process.argv.includes("--mutations")) {
  console.log("\n── Part M: mutation evidence (#2161) ──");
  const { execFileSync } = await import("node:child_process");
  const mutRoot = realpathSync(mkdtempSync(join(tmpdir(), "discard-mut-")));
  const SRC = readFileSync(join(HERE, "classify-git.mjs"), "utf8");
  // String.raw keeps each anchor BYTE-EXACT against the module, so a revert
  // cannot silently fail to match (which is why `applied === 0` is its own
  // assertion below).
  const PAIRS = [
    // [label, the pinned source, the textual reverts that reintroduce the defect]
    ["`case` arm with an unspaced `#` comment (R1)", CASE_ARM_COMMENT, [[
      String.raw`      out += ch; i++; atWordStart = true; continue;
    }
    if (ch === "(") {`,
      String.raw`      out += ch; i++; atWordStart = false; continue;
    }
    if (ch === "(") {`,
    ]]],
    ["ANSI-C word with an escaped quote (R2)", ANSI_ESC, [
      // no escape handling inside the `$'…'` word …
      [String.raw`      if (ansiC && ch === "\\") { out += ch + (line[i + 1] ?? ""); i += 2; continue; }`,
       String.raw`      if (false) { out += ch + (line[i + 1] ?? ""); i += 2; continue; }`],
      // … and the payload left in the scanned text instead of neutralised.
      [String.raw`    return inert === "" ? m : inert;`,
       String.raw`    return m;`],
    ]],
    // BOTH arms, because the pin now rests on either one: `subst` handles the
    // `$( … )` close and `sawSubst` handles the under-counted closer. Reverting
    // only one leaves the shape detected — which is exactly what the row above
    // measured when the cycle-1 P1 fix was added, so this is the honest revert.
    ["`#` after a `$( … )` close is LITERAL (R1 boundary)", "x=$(date)#; git checkout -- src/x.ts", [[
      String.raw`      if (subst > 0) { subst--; out += ch; i++; atWordStart = false; continue; }
      if (sawSubst) { out += ch; i++; atWordStart = false; continue; }`,
      String.raw`      if (false) { subst--; out += ch; i++; atWordStart = false; continue; }
      if (false) { out += ch; i++; atWordStart = false; continue; }`,
    ]]],
    ["a LITERAL `)` inside `$( … )` (review cycle-1 P1)", "f=$(case $x in a) echo hi;; esac)#; git checkout -- src/x.ts", [[
      String.raw`      if (sawSubst) { out += ch; i++; atWordStart = false; continue; }`,
      String.raw`      if (false) { out += ch; i++; atWordStart = false; continue; }`,
    ]]],
  ];
  for (const [label, pinnedSource, reverts] of PAIRS) {
    const expected = extractWorkingTreeDiscards(pinnedSource).length;
    expectTrue(`M0: the pin for ${label} is live on the UNMUTATED module (it finds the discard)`, expected === 1,
      `unmutated descriptors=${expected} — the pin asserts nothing`);
    let mutated = SRC;
    let applied = 0;
    for (const [from, to] of reverts) { if (!mutated.includes(from)) continue; mutated = mutated.replace(from, to); applied++; }
    expectTrue(`M: the ${label} defect was actually reintroduced (the textual revert applied)`, applied > 0,
      "no revert applied — the mutation is stale against the module and proves nothing");
    const copy = join(mutRoot, `mut-${applied}-${Math.random().toString(36).slice(2)}.mjs`);
    writeFileSync(copy, mutated);
    let discs = null;
    try {
      const m = await import(pathToFileURL(copy).href);
      discs = m.extractWorkingTreeDiscards(pinnedSource).length;
    } catch (e) {
      expectTrue(`M: mutated module for ${label} loaded`, false, String(e?.message ?? e).slice(0, 160));
      continue;
    }
    expectTrue(`M: with the ${label} defect reintroduced the pinned case goes BLIND — so the pin CAN fail`,
      discs === 0, `mutated descriptors=${discs} (want 0; the pin would not go red)`);
  }
  try { rmSync(mutRoot, { recursive: true, force: true }); } catch { /* best-effort */ }
}

console.log(`\n${fail === 0 ? "✅" : "❌"} test-discard-gate: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
