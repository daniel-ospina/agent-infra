// Regression tests for #653 — the #73 coordinated-delete guard matched the
// delete target as TEXT, so whenever the target was produced by the SHELL the
// guard looked up a name no worktree can hold and ALLOWED the delete.
//
//   PR_BRANCH=$(gh pr view 645 --json headRefName -q '.headRefName')
//   git push origin --delete "$PR_BRANCH"
//     → extractor target `$PR_BRANCH`, no such ref, `_coordinatedDeleteBlock` → null
//     → index.ts push-delete arm → `return undefined` (ALLOW), delete runs.
//
// MEASURED on the pre-fix tree (this file's Part A pins the extraction half):
//   `git push origin --delete "$PR_BRANCH"`        → ["$PR_BRANCH"]   → ALLOW
//   `git push origin -d $(echo held/branch)`       → ["$(echo","held/branch)"] → ALLOW
//   `git push origin -d `cat list``                → ["`cat","list`"] → ALLOW
//   `git push origin -d {held,other}`              → ["{held,other}"] → ALLOW (brace expansion → TWO words)
//
// That is #73's protection defeated by ORDINARY shell usage — and the ceremony
// snippets in skills/commit-workflow assigned the branch to a variable first, so
// the documented path was the unmatched one.
//
// THE FIX IS #653's OPTION 2 (the issue names option 1 — resolve simple
// assignments — and option 2 — fail closed). Option 2 is taken because it closes
// the CLASS rather than one spelling of it: `$VAR`, `${X:-y}`, `$(…)`, backticks,
// brace and glob expansion all reach the guard as text, and option 1 would still
// leave every form it cannot resolve. `unresolvableDeleteTargets` (classify-git)
// decides resolvability, and index.ts `_coordinatedDeleteBlock` refuses BEFORE
// the checkout lookup — so the refusal holds in every arm that reaches that seam
// (the degradation arm, the push-delete arm, and the later-segment delete arm)
// and does not depend on a state read that may itself fail.
//
// ⛔ PR #3962 IS NOT THIS FIX, but after it the arm no longer ALLOWS either — and the difference matters
// to a reader deciding which change to trust. #3962 stops the extractor reporting a substitution
// FRAGMENT (`$(echo`) as a ref name; on its own it used to DROP the collapsed span, and a dropped
// target never reaches `_coordinatedDeleteBlock`, so the #73 arm was still never consulted (measured:
// `-d $(echo held/branch)` → `null` → ALLOW). That made #3962 a REGRESSION against `main`'s
// fragment-based refusal once #653 landed, so #3962's collision with this file was resolved by having
// the collapsed span report a shell-shaped MARKER (`$(…)`) instead of nothing: unresolvable, therefore
// refused by the SAME #653 decision, and the refusal names it. The two changes are complementary —
// #653 decides "an unknowable target fails closed", #3962 makes the attribution able to SAY it is
// unknowable instead of inventing `$(echo` or discarding the target.
//
// Run: node extensions/main-worktree-guard/test-653-delete-target.mjs
//      node extensions/main-worktree-guard/test-653-delete-target.mjs --mutations
import { execSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");
const MUTATIONS = process.argv.includes("--mutations");

let pass = 0, fail = 0, skip = 0;
// ⛔ THE BEHAVIOURAL HALF IS THIS FILE'S POINT, so its absence is a FAILURE even
// when Part A's pure rows still passed. `skip > 0 && pass === 0` (the sibling
// harnesses' test) is NOT enough here: Part A runs before the loader check, so a
// Node without `stripTypeScriptTypes` would print "23 passed, 1 skipped" and exit
// 0 — green over a run where the shipped gate was never driven at all.
let behaviouralSkipped = false;
function expect(name, got, expected) {
  const ok = JSON.stringify(got) === JSON.stringify(expected);
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

// ── Part A — the pure policy seam (classify-git.mjs) ──────────────────────
console.log("── Part A: unresolvableDeleteTargets (classify-git.mjs) ──");
const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { unresolvableDeleteTargets, isResolvableDeleteTarget, extractPushDeleteBranch } = cg;

// Resolvable = the extracted token IS the word git will be given. Everything the
// shell rewrites is not, and a literal non-empty ref name is.
for (const [name, target, want] of [
  ["literal short ref", "feat/x", true],
  ["literal full ref", "refs/heads/feat/x", true],
  ["literal remote-name over-capture", "origin", true],
  ["a legal comma in a ref name is NOT unresolvable", "release,2026", true],
  ["dots/dashes/underscores", "a-b_c.d", true],
  ["$VAR", "$PR_BRANCH", false],
  ["${VAR}", "${PR_BRANCH}", false],
  ["${VAR:-default}", "${BRANCH:-feat/x}", false],
  ["command-substitution fragment", "$(echo", false],
  ["backtick fragment", "`cat", false],
  ["glob", "feat/*", false],
  ["lone glob star", "*", false],
  // ⛔ THE SECURITY-RELEVANT MEMBERS THAT HAD NO ROW (review P2 of PR #3978, measured):
  // `?` and `[` are ILLEGAL in a ref name AND shell globs — the SHELL expands
  // `feat/experiment-?` to real branch names before git ever sees a legal ref, so
  // refusing them is load-bearing rather than "free". Without these rows a future
  // "reduce the over-block" edit could drop either char and every check stayed green.
  ["? shell glob (illegal in a ref name — still expands)", "feat/experiment-?", false],
  ["[ character class (a shell glob)", "feat/[ab]", false],
  ["lone closing bracket (accepted over-block — pinned)", "feat/x]", false],
  ["lone closing brace (accepted over-block — pinned)", "feat/x}", false],
  ["brace expansion", "{feat/a,feat/b}", false],
  ["tilde", "~/x", false],
  ["backslash escape", "feat/x\\ y", false],
  ["empty", "", false],
]) {
  expect(`A: isResolvableDeleteTarget(${name})`, isResolvableDeleteTarget(target), want);
}
expect("A: the whole set is filtered, deduped", unresolvableDeleteTargets(["$A", "feat/x", "$A", "$(cat"]), ["$A", "$(cat"]);
expect("A: an all-literal set yields nothing to refuse", unresolvableDeleteTargets(["feat/x", "refs/heads/y"]), []);
expect("A: a non-array is inert (never throws into the gate)", unresolvableDeleteTargets(undefined), []);

// The EXTRACTION half — why the lookup never matched. These rows are the
// MEASURED PRE-FIX attribution (the tree before #504/#3962's segment helper): a substitution reached the
// guard as a token fragment. ⛔ THEY ARE HISTORY, NOT CURRENT BEHAVIOUR: after #3962 a collapsed span in
// a TARGET slot is reported as the unresolvable marker `$(…)` (see `_cleanDeleteTarget`), because a
// `null`/empty target list ALLOWS — which is what makes the policy layer load-bearing.
// HARNESS-SENSITIVE: they changed once already when `main` merged the file that introduced them, so
// treat a red here as "the attribution moved", and read the block's marker comment before "fixing" it.
expect("A: $VAR extract", extractPushDeleteBranch(`git push origin --delete "$PR_BRANCH"`), ["$PR_BRANCH"]);
expect("A: $(…) extract (UNRESOLVABLE marker, not a ref)", extractPushDeleteBranch("git push origin -d $(echo held/branch)"), ["$(…)"]);
expect("A: backtick extract (UNRESOLVABLE marker, not a ref)", extractPushDeleteBranch("git push origin -d `cat list`"), ["$(…)"]);
expect("A: brace expansion extract (ONE token, shell makes TWO words)", extractPushDeleteBranch("git push origin -d {held,other}"), ["{held,other}"]);

// ── Round-7 review (P0 ×2): the two capture-level gaps that made the segment helper WORSE than
// `origin/main`, both measured as `extractPushDeleteBranch → null` = the #73 arm never consulted. ──
// 1. A NEWLINE is a list separator ("a bare NEWLINE ends a simple command exactly like `;`", the
//    module's own `_tokenize` doc, agent-infra#1158). `segRe`'s capture spanned it, so the SECOND
//    command arrived inside the first body and its `(` was read as a span OPENER — the `-d` and its
//    target were skipped as span content. `origin/main` blocked these; the extractor returned `null`.
// ⛔ EVERY ONE OF THESE MUST NAME THE REAL TARGET, not merely `$(…)`: the point is that the second
//    command was ATTRIBUTED, which is what the #73 lookup needs.
for (const [name, cmd, want] of [
  ["a NEWLINE + parenthesized later segment", "git push origin HEAD:feat\n( git push origin -d held/branch )", ["held/branch"]],
  ["a CRLF later segment", "git push origin HEAD:feat\r\n( git push origin -d held/branch )", ["held/branch"]],
  ["a TAB-indented later segment", "git push origin origin/HEAD\n\t( git push origin -d held/branch )", ["held/branch"]],
  ["a NEWLINE + `--delete` later segment", "git push origin HEAD:feat\n( git push origin --delete held/branch )", ["held/branch"]],
  ["a bare NEWLINE-separated delete (no parens)", "git push origin HEAD:feat\n git push origin -d held/branch", ["held/branch"]],
  // 2. A BACKSLASH-NEWLINE is a LINE CONTINUATION: bash joins the lines before parsing words, so the
  //    capture must NOT be cut there. Resolved before the scan, so the delete survives.
  ["a BACKSLASH-NEWLINE continuation keeps the delete", "git push origin \\\n-d held/branch", ["held/branch"]],
]) {
  expect(`A: ${name} → the real target is ATTRIBUTED`, extractPushDeleteBranch(cmd), want);
}

// ── The TRUNCATED SPAN (round-7 review, P0): a substitution whose BODY contains `;`/`&`/`|` is cut by
// the capture before its closer, so the span never closes. Dropping an unclosed span is the same
// fail-open on the other side: `origin/main` refused these on a fragment, this branch returned `null`.
// The truncated span is ONE unknowable word, so it reports the same `$(…)` marker a closed one does.
for (const [name, cmd] of [
  ["a pipe inside the substitution body", "git push origin -d $(cat f | head -1)"],
  ["a semicolon inside the substitution body", "git push origin -d $(echo a; echo b)"],
  ["an `&&` inside the substitution body", "git push origin -d $(echo a && echo b)"],
  ["a pipe inside a BACKTICK body", "git push origin -d `echo a && echo b`"],
  ["a truncated span in a compound's later segment", "git push origin HEAD:refs/heads/feat && git push origin -d $(cat f | head -1)"],
]) {
  expect(`A: ${name} → UNRESOLVABLE marker`, extractPushDeleteBranch(cmd), ["$(…)"]);
}
// ── Round-8 review (P0 ×2): the newline rule must be QUOTE/SPAN AWARE, and `$'…'` is a QUOTED string
// to bash but not to `_tokenize`. Both were measured as `null` here = the #73 arm never consulted,
// where `origin/main` reported a real target — i.e. regressions this PR introduced by taking the target
// list from the tokenizer/capture rather than from `split(/\s+/)`. ──
// ⛔ EVERY ROW ASSERTS `held/branch`: the point is that the delete is still ATTRIBUTED after a newline
// that only LOOKS like a boundary, or after an ANSI-C literal that only LOOKS like an open quote.
for (const [name, cmd] of [
  ["a newline inside a DOUBLE-quoted push option", 'git push origin -o "a\nb" -d held/branch'],
  ["a newline inside a SINGLE-quoted push option", "git push origin -o 'a\nb' -d held/branch"],
  ["a newline inside a command substitution", "git push origin -o $(echo a\n) -d held/branch"],
  ["a newline inside a backtick substitution", "git push origin -o `echo a\n` -d held/branch"],
  ["a newline inside a ${…} expansion", "git push origin -o ${R:-a\nb} -d held/branch"],
  ["an ANSI-C literal whose escaped quote must NOT close it", "git push -o $'don\\'t' origin -d held/branch"],
  ["an ANSI-C literal before the flag, later segment", "git push origin HEAD:refs/heads/feat && git push -o $'don\\'t' origin -d held/branch"],
]) {
  expect(`A: ${name} → the real target is ATTRIBUTED`, extractPushDeleteBranch(cmd), ["held/branch"]);
}
// …and the unquoted twin really is still a boundary (the control for the rows above).
expect("A: an UNQUOTED newline between two commands is still a boundary", extractPushDeleteBranch("git push origin HEAD:feat\ngit push origin -d held/branch"), ["held/branch"]);

// ── Round-9 review (P0 ×3): the newline mask hid a REAL separator in three shapes, and one quote
// tracker let an inner `"` close an enclosing one. Each masked a separator, so the second command
// landed in the first body and its `(`/`$(` was read as a span OPENER — the `-d` and its target were
// skipped and the #73 arm was never consulted. Measured against `origin/main` over a 644-row shape
// corpus: 12 rows where main BLOCKS and this branch ALLOWED, in exactly these classes. ──
for (const [name, cmd] of [
  ["an apostrophe inside a `#` COMMENT before a later newline",
    "git push origin HEAD:feat # don't\ngit push origin -d held/branch"],
  ["an apostrophe inside a `#` COMMENT before a parenthesized later segment",
    "git push origin HEAD:feat # don't\n( git push origin -d held/branch )"],
  // `$'…'` is its OWN quoting context in bash (`\'` does not close it). Reading the `'` as a plain
  // single quote closed the literal at the escape and re-opened one that never closed.
  ["an ANSI-C literal before a later newline",
    "git push origin -o $'don\\'t'\n( git push origin -d held/branch )"],
  // ONE shared span counter meant the `}` of `${R:-(}` left the counter non-zero and masked the
  // next newline. `}` must close only a `${`, and inside `${ … }` a bare `(` is DATA (bash:
  // `${R:-(}` is the complete expansion yielding `(`).
  ["a `${…}` whose `}` must not close a `$(` span",
    "git push origin -o ${R:-(}\n( git push origin -d held/branch )"],
]) {
  expect(`A: ${name} → the real target is ATTRIBUTED`, extractPushDeleteBranch(cmd), ["held/branch"]);
}
// ⛔ A `"` INSIDE `$( … )` OPENS A NEW QUOTING CONTEXT (bash re-enters the enclosing one at the
// matching `)`). With a single flat `quote`, the inner `"` CLOSED the enclosing one, so the span's
// `)` arrived unmasked and `_pushSegmentTokens` read it as the #504 boundary and broke — dropping the
// `-d` and its target. Measured: all four ALLOWED here, BLOCKED on `origin/main`.
for (const [name, cmd, want] of [
  ["a double quote inside a substitution in a double-quoted option",
    'git push origin -o "title=$(echo "fix) bug")" -d held/branch', ["bug)", "held/branch"]],
  ["a quoted close-paren inside a substitution",
    'git push origin -o "$(echo ")" )" -d held/branch', ["held/branch"]],
  ["a nested substitution carrying a quoted paren before the flag",
    'git push -o "x=$(echo "a)")" origin -d held/branch', ["held/branch"]],
]) {
  expect(`A: ${name} → the real target survives the span`, extractPushDeleteBranch(cmd), want);
}
// CONTROLS for the `#`-comment rule — every one pins a state where `#` is NOT a comment, so the skip
// cannot be widened to swallow a real delete.
expect("A: a QUOTED `#` is data, not a comment", extractPushDeleteBranch('git push origin -o "a#b" -d held/branch'), ["held/branch"]);
expect("A: an unquoted `#` MID-WORD is not a comment", extractPushDeleteBranch("git push origin -o a#b -d held/branch"), ["held/branch"]);
// CONTROLS for the span stack — the `${…}` handling must not have been weakened in either direction.
expect("A: a quoted brace does not close the expansion", extractPushDeleteBranch("git push origin -o ${R:-'}'x)} -d b"), ["b"]);
expect("A: a substitution span inside a parameter expansion", extractPushDeleteBranch("git push $(echo ${R:-)}) origin -d b"), ["origin", "b"]);

// ⛔ ONLY A BALANCED QUOTE IS A QUOTE (round-10 review, P0 F1). The capture is bounded by list
// separators, NOT by quoting, so a compound that hands the push to a shell (`sh -c '…'`, `eval`) puts
// the OUTER word's closing quote inside the segment. `_tokenize` then swallows the following
// whitespace into the word, and the target came out as `held/branch ` — a trailing space is not in
// `DELETE_TARGET_UNRESOLVABLE_RE`, so #653 did not refuse it and the #73 lookup asked for
// `refs/heads/held/branch ` (an exact-key miss) and ALLOWED the delete of a sibling-held branch.
// MEASURED before the fix: base `["held/branch"]` (BLOCK) vs this branch `["held/branch "]` (ALLOW).
// The fix is `_dropUnmatchedQuote` — NOT a whitespace rule in the refusal class, which was tried and
// reverted: the same over-capture carries push-option VALUES (`-o "a b"`), so refusing whitespace
// turned an ordinary `-o … -d <literal>` into a FALSE BLOCK.
for (const [name, cmd] of [
  ["a `sh -c '…'` closer inside the segment", "git push origin HEAD:feat && sh -c 'git push origin -d held/branch'"],
  ["…with a tail after the closer", "git push origin HEAD:feat && sh -c 'git push origin -d held/branch' && echo done"],
  ["a `bash -c \"…\"` closer inside the segment", 'git push origin HEAD:feat && bash -c "git push origin -d held/branch"'],
  ["an `eval '…'` closer inside the segment", "git push origin HEAD:feat && eval 'git push origin -d held/branch'"],
]) {
  expect(`A: ${name} → the real target, with NO glued whitespace`, extractPushDeleteBranch(cmd), ["held/branch"]);
}
// ⛔ A GLUED SUBSTITUTION PLACEHOLDER IS UNRESOLVABLE, NOT A REF (round-10 review, P0 F2). The
// placeholder was matched by EQUALITY, so a substitution CONCATENATED with the ref (`$''held/branch` —
// bash joins them, the argv word IS `held/branch`) produced one token that matched neither the marker
// arm nor the refusal class, was treated as a literal ref, missed the lookup, and ALLOWED the delete.
// `_cleanDeleteTarget` now matches CONTAINMENT: a NUL cannot occur in a shell word at all.
for (const [name, cmd] of [
  ["an empty ANSI-C literal GLUED after the ref", "git push origin HEAD:feat && git push origin -d held/branch$''"],
  ["an empty ANSI-C literal GLUED before the ref", "git push origin HEAD:feat && git push origin -d $''held/branch"],
  ["a PAIRED backtick span GLUED before the ref", "git push origin HEAD:feat ; git push origin -d `date`held/branch"],
]) {
  expect(`A: ${name} → the UNRESOLVABLE marker (never a literal ref)`, extractPushDeleteBranch(cmd), ["$(…)"]);
}
// ⛔ A PROCESS-SUBSTITUTION OPENER IS A SPAN (round-10 review, P0 F3), and a `$( … )` INSIDE `"…"`
// opens one in a FRESH quoting context (P0 F4). Both were invisible to the newline mask, so a DATA
// newline inside them ended the capture and the delete+target were lost (base BLOCKED, this branch
// ALLOWED). `<( list )`/`>( list )` is ONE WORD of the outer command (bash manual, Process
// Substitution); a substitution body is its own command list (bash manual, Command Substitution).
for (const [name, cmd] of [
  ["a DATA newline inside `<(`", "git push origin HEAD:feat && git push origin -o <(cat ff\n) -d held/branch"],
  ["a DATA newline inside `>(`", "git push origin HEAD:feat && git push origin -o >(cat ff\n) -d held/branch"],
  ["a DATA newline inside a `$( … )` opened in a double quote", 'git push origin HEAD:feat && git push origin -o "$(echo "a\nb")" -d held/branch'],
]) {
  expect(`A: ${name} is DATA, not a separator → the real target survives`, extractPushDeleteBranch(cmd), ["held/branch"]);
}
// CONTROL for F1's fix: a BALANCED quoted word keeps its content (the drop is only for the ONE
// unmatched quote), so a genuinely quoted ref whose text ends in a paren is still the real ref.
expect("A: a BALANCED quoted ref is untouched by the unmatched-quote drop", extractPushDeleteBranch("git push origin -d 'feat/x)'"), ["feat/x)"]);

// ⛔ ONE STACK FOR `${ … }`, NOT A COUNTER (round-11 review, P0). A flat `expDepth` + a parallel
// `substQuotes` modelled neither of bash's two rules for a `}` that is DATA, so 48 of 64 measured
// shapes returned `null` where `origin/main` reported the real target — the #73 arm was never
// consulted and the delete of a sibling-held branch was ALLOWED. The two families:
//   (i)  a `}` inside a QUOTE THAT OPENED INSIDE THE EXPANSION — `${A:-"}"x)}`: the quoted arm fired
//        on ANY `}` and dropped the level. `quoteExpDepth` (expDepth when the quote opened) fixes it.
//   (ii) a `}` inside a `$( … )` NESTED IN THE EXPANSION — `${A:-$(printf "}")}`: the `$(` got no
//        level (`expDepth === 0` gate), so the argument's `}` closed the expansion and the expansion's
//        own `)` then arrived UNMASKED as the #504 operator token.
// The `-o` VALUE is the carrier in every row (an ordinary push-option form), and `held/branch` must
// survive intact — a phantom beside it is fine (it is refused), a MISSING one is the hazard.
for (const [name, cmd, want] of [
  ["a quoted `}` inside an expansion does not close it", `git push origin -o ${'${A:-"}"x)}'} -d held/branch`, ["held/branch"]],
  ["…with text on both sides of the quoted `}`", `git push origin -o ${'${A:-"a}b"x)}'} --delete held/branch`, ["held/branch"]],
  ["…in the `--del` spelling", `git push origin -o ${'${A:-x"}"x)}'} --del held/branch`, ["held/branch"]],
  ["…and in the `:ref` spelling", `git push origin -o ${'${A:-"}"x)}'} :held/branch`, ["held/branch"]],
  ["…in a LATER segment (the wholeCommandDeleteTargets arm)", `git push origin HEAD:feat && git push origin -o ${'${A:-"}"x)}'} -d held/branch`, ["held/branch"]],
  ["a `}` argument of a `$( … )` nested in the expansion", `git push origin -o ${'${A:-$(echo })}'} -d held/branch`, ["})}", "held/branch"]],
  ["…quoted inside that nested substitution", `git push origin -o ${'${A:-$(printf "}")}'} -d held/branch`, ["})}", "held/branch"]],
  // CONTROLS: the pre-existing `${…}` arms must not have been weakened in either direction.
  ["CONTROL: the data paren of `${R:-)}`", `git push origin -o ${'${R:-)}'} -d held/branch`, ["held/branch"]],
  ["CONTROL: a SINGLE-quoted `}` in an expansion", `git push origin -o ${'${R:-\'}\'x)}'} -d held/branch`, ["held/branch"]],
  ["CONTROL: a nested expansion's data paren", `git push origin -o ${'${A:-${B:-)}}'} -d held/branch`, ["held/branch"]],
]) {
  expect(`A: ${name} → the real target survives the expansion`, extractPushDeleteBranch(cmd), want);
}

// …and the marker really is what #653 refuses, end-to-end at the seam these rows live in.
for (const t of ["$(…)"]) expect(`A: #653 refuses the truncated-span marker ${t}`, unresolvableDeleteTargets([t]), [t]);
// ⚠️ CONTROL (not a discriminator): a backtick with NOTHING after it in the segment is the #504
// CLOSER, whose partner belongs to an outer command — it still ends the body, so the real target
// survives and is NOT replaced by a marker.
expect("A: an unpaired CLOSING backtick keeps the real target", extractPushDeleteBranch("echo `git push origin -d held/branch`"), ["held/branch"]);

// ── Round-12 review (P1): an ANSI-C literal handed to a SHELL is a PROGRAM, not a word ────────────
// `_foldAnsiCStrings` replaces the whole `$'…'` literal with the opaque placeholder, which is right
// for a BARE word (bash manual §3.1.2.4: `$'string'` expands to one single-quoted WORD, so
// `$'git push origin -d b'` alone is an ARGUMENT and runs nothing). It was WRONG when the word is the
// operand of `sh -c` / `bash -c` / `bash -lc` / `eval`, where that shell DECODES the literal and runs
// the text as a program. Measured: `origin/main` reported `["held/branch"]` for every row below and
// this branch reported `null`, so `_coordinatedDeleteBlock` was never consulted — and for the
// `--delete` spelling both trees reach `block:push-delete`, which in the DEGRADATION arm
// (`index.ts` `rawDeleteNames = extractPushDeleteBranch(…) ?? []`) means the target list was the only
// difference, i.e. a silent ALLOW in the arm that exists for the classifier-unavailable case.
for (const [name, cmd] of [
  ["`sh -c` with an ANSI-C program", "sh -c $'git push origin -d held/branch'"],
  ["`bash -c` with an ANSI-C `--delete` program", "bash -c $'git push origin --delete held/branch'"],
  ["`bash -lc` with an ANSI-C program", "bash -lc $'git push origin -d held/branch'"],
  ["`env … bash -c` with an ANSI-C program", "env FOO=1 bash -c $'git push origin -d held/branch'"],
  ["`eval` of an ANSI-C program", "eval $'git push origin -d held/branch'"],
  ["`sh -c` ANSI-C program in a LATER segment", "git push origin HEAD:feat && sh -c $'git push origin -d held/branch'"],
]) {
  expect(`A: ${name} → the real target is ATTRIBUTED`, extractPushDeleteBranch(cmd), ["held/branch"]);
}
// ⚠️ CONTROL (not a discriminator): a BARE ANSI-C literal is a WORD passed to nothing — bash runs no
// git at all (stub-`git` probe: 0 invocations) — so it must stay FOLDED rather than be read as a push.
// `origin/main` reports a target here, and that report is an over-capture of a non-runnable command.
expect("A: CONTROL — a BARE ANSI-C literal is a word, not a program", extractPushDeleteBranch("$'git push origin -d held/branch'"), null);

// ── Round-13 review (P1): a newline inside a SPAN is a COMMAND SEPARATOR, not data ────────────────
// `_maskQuotedNewlines` masks a newline so the segment CAPTURE is not cut at it — right for every span.
// But inside `$( … )`, `<( … )`, backticks, or the body of a `-c` operand the shell ALSO parses that
// newline as a list separator, and bash runs both sides. Masking it as DATA glued the next command's
// first word onto the ref (`held/branch\necho`), which names no ref and is NOT in the unresolvable
// class (so #653 did not fire either) — #73 looked it up, found nothing and ALLOWED. `origin/main`
// reported the real `held/branch`. The mask now distinguishes the two ORIGINS (`_NL_DATA` for `"…"` /
// `${ … }`, `_NL_SPAN` for a command-list span), and `_pushSegmentTokens` splits on the latter.
for (const [name, cmd] of [
  ["a newline inside a `bash -c` program", 'bash -c "git push origin -d held/branch\necho done"'],
  ["a newline inside a `sh -c --delete` program", 'sh -c "git push origin --delete held/branch\ntrue"'],
  ["a newline inside a `bash -lc` program", 'bash -lc "git push origin -d held/branch\ncd /tmp"'],
  ["a newline inside an `eval` program", 'eval "git push origin -d held/branch\ntrue"'],
  ["a newline inside a command substitution", "$( git push origin -d held/branch\nsleep 1 )"],
]) {
  const got = extractPushDeleteBranch(cmd);
  expectTrue(`A: ${name} → the real target is ATTRIBUTED`, Array.isArray(got) && got.includes("held/branch"), JSON.stringify(got));
}
// ⚠️ CONTROLS (not discriminators): a newline inside `"…"`, `'…'`, a backtick or a `${…}` is DATA —
// it must NOT become a word break, or an option VALUE would be shredded into fake targets.
for (const [name, cmd] of [
  ["a newline inside a DOUBLE-quoted push option", 'git push origin -o "a\nb" -d held/branch'],
  ["a newline inside a SINGLE-quoted push option", "git push origin -o 'a\nb' -d held/branch"],
  ["a newline inside a backtick substitution", "git push origin -o `echo a\n` -d held/branch"],
  ["a newline inside a ${…} expansion", "git push origin -o ${R:-a\nb} -d held/branch"],
]) {
  expect(`A: ${name} → DATA, the real target survives`, extractPushDeleteBranch(cmd), ["held/branch"]);
}

// ── Round-17 review (P1 fail-open + P2 false block): a QUOTED substitution is ONE opaque WORD ─────
// `_maskDataParens` masks a quoted span's parens (right for the parenthesis rules), and that was ALL it
// did — so the token came back as literal text `$(echo -d)` and the segment walk never recognised it as
// a span. Two consequences, both measured against `origin/main` with a stub-`git` argv probe:
//
//   (a) FAIL-OPEN: `git push origin -o "x -d y" "$(echo -d)" held/branch` → bash argv
//       `push origin -o x -d y -d held/branch`, i.e. a REAL delete of `held/branch`. This branch
//       returned `null` (no flag attributed → #73 never consulted → ALLOWED) where `origin/main` refused
//       it. gnu.org *Command Substitution*: "If the substitution appears within double quotes, word
//       splitting and pathname expansion are not performed on the results" — the span is exactly ONE
//       argv word, so it belongs in `_SUBST_PLACEHOLDER` like its bare twin, and `_spanCarriesDeleteSpelling`
//       must descend into `"…"` to see the spelling at all. A backtick inside `"…"` expands the same way
//       (that shape was mis-allowed on BOTH trees before this round — a pre-existing gap, now closed).
//   (b) FALSE BLOCK: `git push origin -o $(echo -d) HEAD:feat` → argv `push origin -o -d HEAD:feat`,
//       where `-d` is `-o`'s VALUE and nothing is deleted (`origin/main` allowed). The arm now skips a
//       span that sits in an option-value slot, using the module's own `_markOptionValueSlots`.
for (const [name, cmd, want] of [
  ["quoted `$( … )` flag word after quoted option text (the P1 fail-open)",
    `git push origin -o "x -d y" "$(echo -d)" held/branch`, ["$(…)", "held/branch"]],
  ["quoted `$( … )` flag word, bare twin", `git push origin "$(echo -d)" held/branch`, ["$(…)", "held/branch"]],
  ["quoted BACKTICK flag word after quoted option text", "git push origin -o \"x -d y\" \"`echo -d`\" held/branch", ["$(…)", "held/branch"]],
  ["quoted BACKTICK flag word, bare twin", "git push origin \"`echo -d`\" held/branch", ["$(…)", "held/branch"]],
  // ⛔ ROUND-17 REVIEW P0 — MY OWN OFF-BY-ONE, and the two rows above are what HID it. The backtick branch
  // emitted ONE character while also doing `i++`, so it ate the span's first letter and then the closing
  // quote; the rest of the segment fell inside the quoted word. Their first revision asserted `["$(…)"]`
  // — the CORRUPTED output — so the suite stayed green over a real delete of the sibling-held ref
  // (`-o -d "`echo -d`" -d held/branch`: bash argv `push origin -o -d -d held/branch`, where the second
  // `-d` is a real flag). `held/branch` in the expected value IS the pin: it can only be attributed if
  // the segment AFTER the span survives the mask.
  ["a quoted BACKTICK span does not eat the delete AFTER it (the P0 shape)",
    "git push origin -o -d \"`echo -d`\" -d held/branch", ["$(…)", "held/branch"]],
  ["a quoted `$( … )` span does not eat the delete after it (the same shape, paren spelling)",
    `git push origin -o -d "$(echo -d)" -d held/branch`, ["$(…)", "held/branch"]],
  // ⛔ PRE-EXISTING FAIL-OPEN promoted to a pin (round-17 review NOTE; real git on all three trees): an
  // `-o -d` supplies no flag, but it LOOKED like one to the arm's "this segment already has its own
  // delete" test while the target scan correctly skipped it as a VALUE — so BOTH halves declined and
  // nothing was attributed:
  //   git push origin -o -d $(echo -d) held/branch
  //     bash argv → push origin -o -d -d held/branch → the SECOND `-d` is a flag → real git DELETES the
  //     sibling-held ref, and `origin/main`, the previous head and the shipped head all returned null.
  // That test now reads through `_markOptionValueSlots`, so the arm fires for the span that carries it.
  ["an `-o -d` VALUE does not disarm the arm (the pre-existing fail-open)",
    `git push origin -o -d $(echo -d) held/branch`, ["$(…)", "held/branch"]],
  ["a BARE span in a flag slot still fires (control: the value-slot narrowing must not disarm it)",
    "git push origin $(echo -d) held/branch", ["$(…)", "held/branch"]],
  ["a value-slot span AND a flag-slot span in one segment (only the flag slot fires)",
    "git push origin -o $(echo -d) $(echo -d) held/branch", ["$(…)", "held/branch"]],
]) {
  expect(`A: ${name} → the delete spelling is UNATTRIBUTABLE, never absent`, extractPushDeleteBranch(cmd), want);
}
// ⚠️ CONTROLS: a QUOTED span in an `-o`/`--push-option` VALUE slot is a VALUE — `-o` takes exactly one
// argv word and a quoted substitution is exactly one word (gnu.org: no word splitting inside `"…"`), so
// a delete spelling inside it cannot become a flag (real git 2.43: `git push -o -d origin` is a plain
// push). These are the case the exemption exists FOR; `origin/main` allowed all of them and so does head.
for (const [name, cmd] of [
  ["`-o \"$(echo -d)\"` (quoted span in the value slot — the case the exemption exists for)", `git push origin -o "$(echo -d)" main`],
  ["`-o \"pre$(echo -d)post\"` — a quoted span glued into a longer word is still ONE word",
    `git push origin -o "pre$(echo -d)post" HEAD:feat`],
  // ⛔ CONTROL for the value-slot-aware own-flag test (round-17 review NOTE): `-o -d` supplies no flag
  // AND the segment's only span carries no spelling, so there is no delete to refuse — the arm must NOT
  // fire merely because a `-d`-shaped VALUE exists. bash argv: `push origin -o -d <date> held/branch`
  // = a plain push (the `-o` value is `-d`; nothing deletes).
  ["`-o -d $(date) held/branch` (an `-o -d` value is not a delete, and its span has no spelling)",
    `git push origin -o -d $(date) held/branch`],
  ["`-o $(date) main` — a span in the value slot with NO spelling in its body", `git push origin -o $(date) main`],
]) {
  expect(`A: a QUOTED span in an option VALUE slot (${name}) → nothing deleted`, extractPushDeleteBranch(cmd), null);
}
// ⛔ AN **UNQUOTED** SPAN IN A VALUE SLOT IS NOT EXEMPT — IT CAN SPILL (round-17 review P1, MEASURED as a
// FAIL-OPEN on the GUARDED ref, and the first version of the block above asserted the opposite).
// `-o` consumes ONE argv word; an unquoted substitution WORD-SPLITS, so only its first word is the value
// and the rest is ordinary argv, where a delete flag is a real flag:
//   git push origin -o $(echo "x -d held/branch")
//     bash argv → push origin -o x -d held/branch   (`-o` takes `x`; `-d held/branch` DELETES the ref)
//     real git on a bare remote: `- [deleted] held/branch`
// A blanket exemption returned `null` there, so #73 was never consulted — while `origin/main` and
// `aa5104539` both REFUSED. Which expanded word carries the spelling is unknowable statically, so these
// fail CLOSED. The cost is a documented over-block on `-o $(echo -d)` (an expansion that is exactly
// `-d`, i.e. not a push option anyone writes); the alternative is a deleted sibling branch.
for (const [name, cmd] of [
  ["the P1 shape: `-o $(echo \"x -d held/branch\")` — the flag is word 2, i.e. REAL argv",
    `git push origin -o $(echo "x -d held/branch")`],
  ["`-o $(echo \"x --delete held/branch\")` — the long spelling in the spill", `git push origin -o $(echo "x --delete held/branch")`],
  ["`--push-option $(echo \"x -d held/branch\")` — the long option in the spill",
    `git push origin --push-option $(echo "x -d held/branch")`],
  ["`-o \`echo \"x\" -d\` held/branch` — a BACKTICK spill",
    "git push origin -o `echo \"x\" -d` held/branch"],
  ["`-o $(echo -d) main` — the documented fail-closed over-block (expansion is exactly `-d`)",
    `git push origin -o $(echo -d) main`],
  // ⛔ A **MIXED** TOKEN — an UNQUOTED span ADJACENT to a QUOTED one — IS NOT ONE WORD (round-17 review
  // cycle 3, P1, MEASURED as a FAIL-OPEN with real git). `_foldBacktickSubstitutions` splices an unquoted
  // backtick span INLINE with no separator, so both collapses can land in ONE token; a `contains(_QS_MARK)`
  // test then called the whole word "quoted" and the value-slot exemption fired on a word bash splits:
  //   git push origin -o `echo "x -d held"`"$(echo )"
  //     bash argv → push origin -o x -d held   → the unquoted half spills → REAL delete of `held`
  //     a contains-test → exempt → null → ALLOWED (origin/main REFUSED it on the `"$(echo` fragment)
  // A token carrying both markers takes the BARE placeholder, which the exemption rejects (fails closed).
  ["a MIXED token: unquoted backtick span + quoted `$( )`, empty quoted half",
    "git push origin -o `echo \"x -d held\"`\"$(echo )\""],
  ["a MIXED token, the `--push-option` twin",
    "git push origin --push-option `echo \"x -d held\"`\"$(echo )\""],
  ["a MIXED token, quoted half non-empty",
    "git push origin `echo \"x -d held\"`\"$(echo x)\""],
  ["a MIXED token, the other order (quoted first)",
    "git push origin -o \"$(echo x)\"`echo \" -d held\"`"],
]) {
  const got = extractPushDeleteBranch(cmd);
  expectTrue(`A: an UNQUOTED span in a value slot (${name}) → REFUSED, never dropped`,
    Array.isArray(got) && got.some((t) => !isResolvableDeleteTarget(t)), JSON.stringify(got));
}
// …and the same slot must not launder a REAL delete elsewhere in the segment.
expect("A: `-o <literal> <span> -d held/branch` → the real target survives beside the marker",
  extractPushDeleteBranch(`git push origin -o "title" "$(cat f)" -d held/branch`), ["$(…)", "held/branch"]);

// ── Round-18 review (P1 fail-open + P2 false block) ──────────────────────────────────────────
// ⛔ P1 — AN ANSI-C PROGRAM'S NEWLINE IS A LIST SEPARATOR, AND THE PROGRAM FLAG WAS READ ONE
// CHARACTER TOO LATE. `_foldAnsiCStrings` decides "is this `$'…'` the PROGRAM operand of
// `sh -c`/`bash -c`/`eval`?" at the `$` and keeps the literal VERBATIM when it is; `_maskQuotedNewlines`
// then re-derived the same decision at the `'`, where the preceding word is `$` — a word no
// `-c`/`eval` pattern matches — so it answered FALSE for EVERY ANSI-C program operand and classified
// the program's own newline as `_NL_DATA` (a word-CONTINUATION char) instead of `_NL_SPAN` (a
// separator). The next command's first word was then glued onto the delete target:
//
//   sh -c $'git push origin -d held/branch<LF>echo done'
//     bash really runs BOTH commands.  origin/main → ["held/branch","echo","done"]
//     before this fix → ["held/branch\necho","done"]
//
// and that glued name is a FAIL-OPEN, not a cosmetic difference: a newline is not in
// `DELETE_TARGET_UNRESOLVABLE_RE`, so #653 does not refuse it, and `_coordinatedDeleteBlock`'s exact
// `refs/heads/${target}` lookup misses — measured on BOTH trees:
//   unresolvableDeleteTargets(["held/branch\necho","done"]) → []
// so a sibling-checked-out branch was deletable from a linked worktree (M2-exempt) where `origin/main`
// BLOCKED. The row below is the pin: `held/branch` can only appear SPLIT OFF from `echo` once the two
// passes agree on what the literal is.
const ANSI_NL = "\n";
for (const [name, cmd, want] of [
  ["`sh -c` ANSI-C program with an interior newline", `sh -c $'git push origin -d held/branch${ANSI_NL}echo done'`, ["held/branch", "echo", "done"]],
  ["`bash -c` ANSI-C `--delete` program with an interior newline", `bash -c $'git push origin --delete held/branch${ANSI_NL}echo done'`, ["held/branch", "echo", "done"]],
  ["`eval` of an ANSI-C program with an interior newline", `eval $'git push origin -d held/branch${ANSI_NL}echo done'`, ["held/branch", "echo", "done"]],
  ["`env … bash -c` ANSI-C program with an interior newline", `env FOO=1 bash -c $'git push origin -d held/branch${ANSI_NL}echo done'`, ["held/branch", "echo", "done"]],
]) {
  expect(`A: ${name} → the target is NOT glued to the next command`, extractPushDeleteBranch(cmd), want);
}
// …and the same spelling in a LATER segment reaches the later-segment arm with the real name.
expect("A: `… && sh -c $'…<LF>…'` → the later-segment arm sees the REAL target",
  cg.wholeCommandDeleteTargets("block:push", `git push origin HEAD:feat && sh -c $'git push origin -d held/branch${ANSI_NL}echo done'`),
  ["held/branch", "echo", "done"]);
// The pre-fix output is a REAL fail-open, not a naming difference — pin the reason (a property of the
// CURRENT tree, so this row cannot go stale silently).
expect("A: …and the GLUED pre-fix target is NOT in #653's unresolvable class (that is why it was an allow)",
  unresolvableDeleteTargets([`held/branch${ANSI_NL}echo`, "done"]), []);

// ⛔ P2 — THE SPAN COLLAPSE DISCARDED THE TOKEN'S NON-SPAN PREFIX, so an ATTACHED option value lost its
// option and was re-reported as a bare positional refspec. `-o"$(…)"` is ONE argv word carrying BOTH the
// option and its value (`_markOptionValueSlots`: "Inline attached values (`-doDraft`, `-odraft`,
// `--push-option=x`) carry their value in-token … no slot"), so it is not a refspec at all:
//
//   git push origin -o"$(cat msg)" -d old
//     bash argv → push origin -o<msg> -d old → deletes the plain literal `old`
//     origin/main → ["msg)","old"] (an over-captured fragment)   before this fix → ["$(…)","old"]
//     #653 on that list → ["$(…)"] → the later-segment/degraded arm REFUSED a command that deletes a
//     literal `old` which no other worktree holds — a FALSE BLOCK this PR introduced.
for (const [name, cmd] of [
  ["`-o` short option, attached value", 'git push origin -o"$(cat msg)" -d old'],
  ["`--push-option=` long option, attached value", 'git push origin --push-option="$(cat msg)" -d old'],
  ["the SEPARATED twin — same argv words, so it must agree with the attached one", 'git push origin -o "$(cat msg)" -d old'],
]) {
  expect(`A: an ATTACHED option value is not a refspec (${name}) → only the real target`, extractPushDeleteBranch(cmd), ["old"]);
}
expect("A: …so #653 resolves the list (the false block's whole mechanism)",
  unresolvableDeleteTargets(extractPushDeleteBranch('git push origin -o"$(cat msg)" -d old')), []);
expect("A: …and the LATER-SEGMENT arm the false block ran through now sees only `old`",
  cg.wholeCommandDeleteTargets("block:push", 'git push origin HEAD:feat && git push origin -o"$(cat msg)" -d old'), ["old"]);
// ⚠️ CONTROLS for the same edit, in BOTH directions — the prefix must not become a way to hide a flag.
// A MERGED cluster (`-do…`) really carries `-d`, so its delete must never disappear:
expect("A: CONTROL — `-do<attached value> old` really IS a delete (the merged cluster keeps its flag)",
  extractPushDeleteBranch('git push origin -do"$(cat msg)" old'), ["old"]);
// …and an attached value that cannot be a flag must stay ALLOWED (the round-17 P2, same arm):
expect("A: CONTROL — `-o<attached value>` is a plain push (the value is `-d`, not a flag)",
  extractPushDeleteBranch('git push origin -o"$(echo -d)" main'), null);

// ── Part B — the SHIPPED gate (real index.ts tool_call handler) ───────────
if (typeof stripTypeScriptTypes !== "function" ||
    (typeof register !== "function" && typeof registerHooks !== "function")) {
  const msg = `node ${process.versions.node} lacks stripTypeScriptTypes (needs Node >= 22.13)`;
  if (MUTATIONS) expectTrue("M: the mutation leg REQUIRES the real index.ts loader", false, msg);
  else { behaviouralSkipped = true; skipped("Part B/M: real index.ts load", msg); }
} else {
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  // HOME IS IN THIS LIST because the fixture REBINDS it (the hermetic ~/.pi/agent), and
  // the `finally` restore branches on `savedEnv.get("HOME")` — leaving it out DELETED the
  // real HOME instead of restoring it (review observation on PR #3978).
  const savedEnv = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "AGENT_INFRA_PATH", "AGENT_LOCKS_DIR", "HOME"]
    .map((v) => [v, process.env[v]]));
  const HATCH = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];

  /** Load ONE copy of the extension (the real one, or a mutant copy) and return a
   *  bash driver bound to `cwd`. */
  async function loadGuard(indexPath, cwd) {
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    let mod;
    try { mod = await import(pathToFileURL(indexPath).href); } finally { console.warn = realWarn; }
    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    const sessionStart = handlers.get("session_start")?.[0];
    // ⛔ THE SESSION DIRECTORY IS MUTABLE AND IS WHAT EVERY LATER CALL RUNS IN
    // (review P2 of PR #3978, MEASURED). `start(at)` used to chdir for
    // `session_start` only and restore the previous cwd, while `bash` chdir'd to the
    // LOAD-time cwd — so Part E ("from a WORKTREE") actually drove the handler from
    // the fixture HUB. The guard reads `process.cwd()` at call time, so the rows
    // exercised a shape the fleet never has, and a future worktree exemption
    // inserted ahead of the delete arm would have left E1 GREEN.
    let cur = cwd;
    const bash = async (command) => {
      const prev = process.cwd();
      process.chdir(cur);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    const start = async (at) => {
      cur = at;
      const prev = process.cwd();
      process.chdir(at);
      try { await sessionStart({}, undefined); } finally { process.chdir(prev); }
    };
    return { bash, start, warnings, loaded: typeof toolCall === "function" };
  }

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-653-")));
  const home = join(tmp, "home");
  mkdirSync(join(home, ".pi", "agent"), { recursive: true });
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const heldDir = join(tmp, "held");
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const reasons = (r) => String(r?.reason ?? "");
  // The #653 refusal's OWN text — never a bare `block === true`, so an unrelated
  // gate that happens to refuse the command cannot satisfy these pins.
  const FAIL_CLOSED = "not a literal ref name";
  const HOLDS = "currently checked out";
  const refusedBy = (r, needle) => !!r && r.block === true && reasons(r).includes(needle);

  try {
    mkdirSync(hub, { recursive: true });
    execSync(`git init -q -b main "${hub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: hub, stdio: "ignore" });
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    // `stale`/`stale2` exist as REAL branches nothing holds; `held` is checked
    // out in a sibling worktree, which is what the #73 check must still see.
    execSync("git add -A && git commit -qm init && git branch stale && git branch stale2 && git branch held",
      { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q -b wtmain "${wt}"`, { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q "${heldDir}" held`, { cwd: hub, stdio: "ignore" });
    writeFileSync(join(tmp, "branch-file"), "held\n");
    for (const v of HATCH) delete process.env[v];
    process.env.HOME = home;
    process.env.AGENT_INFRA_PATH = hub;
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");

    // ── Part B: the #653 class is REFUSED (hub-rooted session, on baseline) ──
    console.log("\n── Part B: the #653 class, through the shipped handler ──");
    const real = await loadGuard(INDEX_TS, hub);
    expectTrue("B0: the real index.ts loaded with a tool_call + session_start handler",
      real.loaded, JSON.stringify(real.warnings.filter((w) => w.includes("[main-worktree-guard]"))));
    await quiet(() => real.start(hub));

    // The issue's own repro, verbatim — the ceremony's `PR_BRANCH=$(gh …)` shape.
    expectTrue("B1 #653: the ISSUE REPRO `git push origin --delete \"$PR_BRANCH\"` → REFUSED (was ALLOW)",
      refusedBy(await quiet(() => real.bash(`git push origin --delete "$PR_BRANCH"`)), FAIL_CLOSED));
    // …and the refusal names the target it could not resolve, so the operator can act.
    const b1 = await quiet(() => real.bash(`git push origin --delete "$PR_BRANCH"`));
    expectTrue("B1b: the refusal NAMES the unresolved target (a block with no name is unactionable)",
      reasons(b1).includes("$PR_BRANCH"), reasons(b1).split("\n").slice(0, 3).join(" / "));

    const deny = [
      ["B2 #653: `-d` short spelling of the same form", `git push origin -d "$PR_BRANCH"`],
      ["B3 #653: `${VAR}` braced expansion", `git push origin --delete \${PR_BRANCH}`],
      ["B4 #653: COMMAND SUBSTITUTION `$(echo held/branch)` (a sibling-held ref, written indirectly)", `git push origin -d $(echo held/branch)`],
      ["B5 #653: BACKTICK substitution", "git push origin -d `cat list`"],
      ["B6 #653: substitution from a FILE that names the held branch", `git push origin -d "$(cat ${join(tmp, "branch-file")})"`],
      ["B7 #653: BRACE EXPANSION (the shell makes two words the guard never sees)", `git push origin -d {held,other}`],
      ["B8 #653: GLOB in the target", `git push origin -d 'feat/*'`],
      ["B9 #653: colon (empty-source) spelling carrying a variable", `git push origin :"$PR_BRANCH"`],
      ["B10 #653: an assignment in the SAME command is NOT resolved (the fix judges TEXT, it does not emulate the shell)", `BRANCH=stale && git push origin --delete "$BRANCH"`],
      ["B11 #653: LATER-SEGMENT delete in a compound (the wholeCommandDeleteTargets arm)", `git push origin main && git push origin -d "$PR_BRANCH"`],
      ["B12 #653: a benign lead segment must not launder the delete", `git status && git push origin --delete "$PR_BRANCH"`],
      // #3962 round-7 review P0: the substitution's OWN body carries a pipe, so the segment capture cuts
      // before the closer and the span never closes. It used to be DROPPED, which left no refusable
      // token: the extractor said `null` and this arm was never consulted (ALLOWED end-to-end).
      ["B13 #3962: a TRUNCATED span (a pipe inside the substitution body)", `git push origin -d $(printf held/branch | head -1)`],
      // #3962 round-8 review P0: `$'…'` is a QUOTED string to bash, but `_tokenize` has no ANSI-C
      // quoting — it opened a plain `'…'` at the `$`, the `\'` inside CLOSED it, and the rest of the
      // segment was swallowed, so the delete vanished and the arm was never consulted.
      ["B14 #3962: an ANSI-C literal with an escaped quote before the delete", `git push -o $'don\\'t' origin -d "$PR_BRANCH"`],
      // #3962 round-17 review P1 — a delete spelling carried by a QUOTED substitution, beside quoted
      // OPTION TEXT. End-to-end: before this round the extractor returned `null`, so this arm was never
      // consulted and the handler ALLOWED the delete of the sibling-held `held`.
      ["B15 #3962: a delete flag supplied by a QUOTED substitution", `git push origin -o "x -d y" "$(echo -d)" held`],
      ["B16 #3962: the same, QUOTED BACKTICK spelling", "git push origin -o \"x -d y\" \"`echo -d`\" held"],
    ];
    for (const [name, cmd] of deny) {
      expectTrue(`${name} → REFUSED`, refusedBy(await quiet(() => real.bash(cmd)), FAIL_CLOSED),
        `handler returned ${JSON.stringify(await quiet(() => real.bash(cmd)))?.slice(0, 200)}`);
    }

    // ── Part C: NO FALSE BLOCK — the literal form is untouched ──────────────
    console.log("\n── Part C: the literal delete path is unchanged ──");
    for (const [name, cmd] of [
      ["C1: `--delete <literal>` of a branch nothing holds", "git push origin --delete stale"],
      ["C2: full-ref literal", "git push origin -d refs/heads/stale"],
      ["C3: colon literal", "git push origin :stale"],
      ["C4: `-d` of a branch nothing holds", "git push origin -d stale2"],
      ["C5: later-segment LITERAL delete in a compound", "git push origin main && git push origin -d stale"],
    ]) {
      const r = await quiet(() => real.bash(cmd));
      expectTrue(`${name} → ALLOWED (fail-closed must not become over-block)`, r === undefined,
        `handler returned ${JSON.stringify(r)?.slice(0, 200)}`);
    }

    // ── Part C2: the round-17 value-slot rule, both halves, end-to-end ──────────────────
    // ⛔ THESE ROWS MUST BE READ AS A PAIR, because the rule is a PAIR: `-o`/`--push-option` consumes
    // exactly ONE argv word. A QUOTED substitution is exactly one word, so it IS the value and cannot be
    // a flag → the delete arm must stay SILENT. An UNQUOTED substitution WORD-SPLITS, so only its first
    // word is the value and the rest is argv → a spelling there is a REAL flag → the arm must FIRE.
    // ⛔ THE `$(…)` OUTCOMES CANNOT BE "full allow" rows: M2 (the off-baseline push gate, a DIFFERENT arm)
    // refuses any push whose refspec list is a substitution — its reason says `Push target(s): $` — and
    // that is pre-existing behaviour on both trees. So each row asserts what THIS fix owns: the delete
    // arm's own verdict, identified by #653's reason text.
    for (const [name, cmd, wantDeleteArm] of [
      ["C8 #3962: `-o \"$(echo -d)\"` — a QUOTED span in the value slot is ONE word, the value",
        `git push origin -o "$(echo -d)" main`, "silent"],
      ["C9 #3962: `-o \"pre$(echo -d)post\"` — a quoted span glued into a longer word is still ONE word",
        `git push origin -o "pre$(echo -d)post" main`, "silent"],
      // The P1 fail-open family: bash argv `push origin -o x -d held/branch` — a REAL delete.
      ["C6 #3962 (P1): `-o $(echo \"x -d held/branch\")` — the flag is word 2, i.e. REAL argv",
        `git push origin -o $(echo "x -d held/branch")`, "fires"],
      ["C7 #3962 (P1): `--push-option $(echo \"x -d held/branch\")` — the long option in the spill",
        `git push origin --push-option $(echo "x -d held/branch")`, "fires"],
      // …and the documented fail-closed over-block: an expansion that is exactly `-d`.
      ["C10 #3962 (documented over-block): `-o $(echo -d)` — unknowable, so it fails CLOSED",
        `git push origin -o $(echo -d) main`, "fires"],
    ]) {
      const r = await quiet(() => real.bash(cmd));
      const fired = reasons(r).includes(FAIL_CLOSED);
      expectTrue(`${name} → the delete arm ${wantDeleteArm === "silent" ? "stays SILENT" : "FIRES (#653)"}`,
        wantDeleteArm === "fires" ? fired : !fired,
        `handler returned ${JSON.stringify(r)?.slice(0, 220)}`);
    }

    // ── Part D: #73 still does its ORIGINAL job (the literal path) ──────────
    console.log("\n── Part D: #73's own protection survives ──");
    expectTrue("D1: a LITERAL delete of a sibling-checked-out branch → #73 BLOCK (its own reason text)",
      refusedBy(await quiet(() => real.bash("git push origin --delete held")), HOLDS));
    expectTrue("D2: the same, colon spelling → #73 BLOCK",
      refusedBy(await quiet(() => real.bash("git push origin :held")), HOLDS));
    expectTrue("D3: an UNRESOLVABLE delete of the same held branch is refused by #653's arm (not silently allowed)",
      refusedBy(await quiet(() => real.bash(`git push origin --delete "$(printf held)"`)), FAIL_CLOSED));
    // #3962 round-7 review P0: a NEWLINE is a list separator exactly like `;`, so the second command is
    // its OWN push segment. The capture used to span the newline, the second segment's `(` was read as a
    // span OPENER, and the `-d` + target were skipped — ALLOWED end-to-end, where `origin/main` blocked it.
    // ⚠️ Asserted against #73's OWN reason text (`currently checked out`), not a bare `block === true`, so
    // an unrelated refusal cannot satisfy it — and not against FAIL_CLOSED, because the correct answer
    // here is the #73 lookup on the REAL target, which is a different arm.
    expectTrue("D4 #3962: a NEWLINE-separated later segment is #73-blocked on the REAL target (the newline ends the segment)",
      refusedBy(await quiet(() => real.bash("git push origin HEAD:refs/heads/feat\n( git push origin -d held )")), HOLDS),
      `handler returned ${JSON.stringify(await quiet(() => real.bash("git push origin HEAD:refs/heads/feat\n( git push origin -d held )")))?.slice(0, 200)}`);
    // ⛔ #3962 round-8 review P0, the OTHER half of the newline rule: bash does NOT end a command at a
    // newline that sits inside quotes or a span — there it is DATA. Cutting the capture on every `\n`
    // lost the delete after `-o "a<LF>b"` (a real push-option form), so this row is the boundary's
    // CONTROL: same target, newline present, and it must still reach #73 on the REAL name.
    // ⛔ D5 IS AN END-TO-END CONTROL, NOT A DISCRIMINATOR — and it says so (round-8 review P2, the same
    // class as B73b). MEASURED: with `_maskQuotedNewlines` reverted the row stays GREEN while
    // `extractPushDeleteBranch` returns null and `wholeCommandDeleteTargets` returns [] — so another arm
    // of the handler refuses this shape end-to-end. The rows that actually redden for this fix are
    // Part A's quoted-newline rows (6 failures with the mask reverted); this one only asserts that the
    // user-visible outcome is still a refusal, which is worth pinning but proves nothing about the mechanism.
    expectTrue("D5 #3962: a newline inside QUOTES is DATA, not a separator — the delete after it still reaches #73 (CONTROL: stays green under the mask mutant)",
      refusedBy(await quiet(() => real.bash('git push origin -o "a\nb" -d held')), HOLDS),
      `handler returned ${JSON.stringify(await quiet(() => real.bash('git push origin -o "a\nb" -d held')))?.slice(0, 200)}`);
    // ⛔ D5b IS A DISCRIMINATOR (unlike D5 above), and it is the round-17 P1's end-to-end row: the
    // spelling is carried by a QUOTED substitution, so `_maskDataParens`' `_QS_MARK` is the only thing
    // that turns this word into a placeholder. Reverting that one line makes the extractor return `null`
    // and the handler ALLOWS the delete — the mutant below measures exactly that.
    // ⚠️ Asserted against #653's OWN reason text (`not a literal ref name`): the marker `$(…)` is in a
    // refspec slot, so the correct answer is the refusal that NAMES it, not the #73 lookup.
    expectTrue("D5b round-17 P1: a delete flag inside a QUOTED substitution is REFUSED, not dropped",
      refusedBy(await quiet(() => real.bash(`git push origin -o "x -d y" "$(echo -d)" held`)), FAIL_CLOSED),
      `handler returned ${JSON.stringify(await quiet(() => real.bash(`git push origin -o "x -d y" "$(echo -d)" held`)))?.slice(0, 200)}`);

    // ── Part D (round 10): the four P0 classes from the round-10 adversarial review ──────────
    // Each row is END-TO-END through the shipped handler, and each is a shape where the pre-fix head
    // ALLOWED a delete of the sibling-held `held` while `origin/main` BLOCKED on the real name.
    // D6 asserts #73's OWN reason text: the correct answer is the lookup on the REAL ref, which is a
    // different arm from #653's refusal — so a mere `block === true` cannot satisfy it.
    expectTrue("D6 round-10 F1: an `sh -c '…'` closer with a TAIL no longer glues whitespace onto the target → #73 BLOCK on the REAL name",
      refusedBy(await quiet(() => real.bash("git push origin HEAD:feat && sh -c 'git push origin -d held' && echo done")), HOLDS),
      `handler returned ${JSON.stringify(await quiet(() => real.bash("git push origin HEAD:feat && sh -c 'git push origin -d held' && echo done")))?.slice(0, 200)}`);
    expectTrue("D7 round-10 F2: a GLUED substitution placeholder in the target slot is REFUSED by #653",
      refusedBy(await quiet(() => real.bash("git push origin HEAD:feat && git push origin -d held$''")), FAIL_CLOSED),
      `handler returned ${JSON.stringify(await quiet(() => real.bash("git push origin HEAD:feat && git push origin -d held$''")))?.slice(0, 200)}`);
    expectTrue("D8 round-10 F3: a DATA newline inside `<(` is not a separator → #73 BLOCK on the REAL name",
      refusedBy(await quiet(() => real.bash("git push origin HEAD:feat && git push origin -o <(cat ff\n) -d held")), HOLDS),
      `handler returned ${JSON.stringify(await quiet(() => real.bash("git push origin HEAD:feat && git push origin -o <(cat ff\n) -d held")))?.slice(0, 200)}`);
    expectTrue("D9 round-10 F4: a DATA newline inside a `$( … )` in a double quote → #73 BLOCK on the REAL name",
      refusedBy(await quiet(() => real.bash('git push origin HEAD:feat && git push origin -o "$(echo "a\nb")" -d held')), HOLDS),
      `handler returned ${JSON.stringify(await quiet(() => real.bash('git push origin HEAD:feat && git push origin -o "$(echo "a\nb")" -d held')))?.slice(0, 200)}`);
    // ── Part D (round 18): an ANSI-C `-c` PROGRAM's interior newline, END-TO-END ─────────────
    // The Part-A rows above pin the extractor's LIST; this pins the arm an agent actually meets, which
    // is the only place the two can disagree. `_foldAnsiCStrings` keeps a program operand VERBATIM, and
    // `_maskQuotedNewlines` then re-derived "is this quote a program?" one character LATER (at the `'`,
    // where the preceding word is `$`), so it said NO and masked the program's own newline as a
    // word-CONTINUATION char — gluing `echo` onto the ref (`held\necho`, in NEITHER the #653
    // unresolvable class NOR the worktree map). Measured: ALLOWED here, BLOCKED on `origin/main`.
    expectTrue("D11 round-18 P1: a newline inside an ANSI-C `-c` PROGRAM is a separator → #73 BLOCK on the REAL name",
      refusedBy(await quiet(() => real.bash("git push origin HEAD:feat && sh -c $'git push origin -d held\necho done'")), HOLDS),
      `handler returned ${JSON.stringify(await quiet(() => real.bash("git push origin HEAD:feat && sh -c $'git push origin -d held\necho done'")))?.slice(0, 200)}`);

    // ── Part D (round 11): the `${ … }` family, end-to-end ──────────────────────────────
    // A `}` that bash treats as DATA used to close the expansion level, so the expansion's own `)`
    // arrived as the #504 operator token, the segment ended, and the delete was never refused.
    // Asserted against #73's OWN reason text: the answer here is the lookup on the REAL ref.
    for (const [name, cmd, needle] of [
      ["a quoted `}` inside an expansion", "git push origin -o ${A:-\"}\"x)} -d held", HOLDS],
      // ⚠️ This one is refused by #653 BEFORE the #73 lookup: the nested substitution also yields an
      // over-captured `})}` word (measured: `["})}","held/branch"]` in Part A), and `}` is in the
      // refusal class. That is fail-closed and correct; Part A's row pins that `held`/`held/branch` is
      // still ATTRIBUTED beside it, which is the property this end-to-end row cannot see.
      ["a `}` inside a `$( … )` nested in the expansion", 'git push origin -o ${A:-$(printf "}")} -d held', FAIL_CLOSED],
      ["the same in a LATER segment", "git push origin HEAD:feat && git push origin -o ${A:-\"}\"x)} -d held", HOLDS],
    ]) {
      expectTrue(`D10 round-11 P0: ${name} → REFUSED (never allowed)`,
        refusedBy(await quiet(() => real.bash(cmd)), needle),
        `handler returned ${JSON.stringify(await quiet(() => real.bash(cmd)))?.slice(0, 200)}`);
    }

    // ── Part E: a WORKTREE session is NOT exempt ────────────────────────────
    // The #73 arm has never been worktree-exempt, and the fleet's lanes run from
    // worktrees — the case the issue's own ceremony hits first.
    console.log("\n── Part E: worktree-rooted session (the fleet's actual shape) ──");
    await quiet(() => real.start(wt));
    expectTrue("E1 #653: from a WORKTREE, `-d \"$PR_BRANCH\"` → REFUSED (the arm is not worktree-exempt)",
      refusedBy(await quiet(() => real.bash(`git push origin -d "$PR_BRANCH"`)), FAIL_CLOSED));
    expectTrue("E2 #653: from a WORKTREE, a literal delete of an unheld branch stays ALLOWED",
      (await quiet(() => real.bash("git push origin -d stale"))) === undefined);
    await quiet(() => real.start(hub));

    // ── Part F: the escape hatch still works (the remedy the message offers) ─
    console.log("\n── Part F: the documented override ──");
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    expectTrue("F1: AGENT_ALLOW_MAIN_EDITS=1 still bypasses (the refusal is a guard, not a lock-out)",
      (await quiet(() => real.bash(`git push origin --delete "$PR_BRANCH"`))) === undefined);
    delete process.env.AGENT_ALLOW_MAIN_EDITS;

    // ── Part M — MUTATION EVIDENCE (--mutations) ────────────────────────────
    // A pin is only a pin if it can FAIL. The mutant reverts EXACTLY #653's
    // decision — `if (unresolved.length > 0)` → `if (false)` — in a TEMP copy, and
    // every Part B row must then be ALLOWED again. The real module must refuse
    // them in the same run, so a mutant that "passes" because the fixture broke
    // cannot be mistaken for evidence.
    if (MUTATIONS) {
      console.log("\n── Part M: mutation evidence (the pin can fail) ──");
      const src = readFileSync(INDEX_TS, "utf-8");
      const NEEDLE = "  if (unresolved.length > 0) {";
      if (!src.includes(NEEDLE)) {
        expectTrue("M1: the mutation target is present in index.ts (a stale anchor is a SKIP, never a green)", false,
          `missing ${JSON.stringify(NEEDLE)}`);
      } else {
        const mutDir = join(tmp, "ext-mutant");
        cpSync(join(HERE, ".."), mutDir, {
          recursive: true,
          filter: (p) => !p.includes("node_modules") && !p.endsWith(".git"),
        });
        const mutIndex = join(mutDir, "main-worktree-guard", "index.ts");
        writeFileSync(mutIndex, src.replace(NEEDLE, "  if (false) {"));
        const mut = await loadGuard(mutIndex, hub);
        expectTrue("M2: the mutant copy loaded (a mutation leg that cannot load proves nothing)", mut.loaded);
        await quiet(() => mut.start(hub));
        for (const [name, cmd] of [
          ["M3", `git push origin --delete "$PR_BRANCH"`],
          ["M4", `git push origin -d $(echo held/branch)`],
          ["M5", `git push origin -d {held,other}`],
          ["M6", `git push origin main && git push origin -d "$PR_BRANCH"`],
        ]) {
          const rm = await quiet(() => mut.bash(cmd));
          const rr = await quiet(() => real.bash(cmd));
          expectTrue(`${name} mutant: "${cmd.slice(0, 46)}" is ALLOWED without the #653 decision (it WENT RED) and REFUSED with it`,
            rm === undefined && refusedBy(rr, FAIL_CLOSED),
            `mutant ${JSON.stringify(rm)?.slice(0, 120)} / real ${JSON.stringify(rr)?.slice(0, 120)}`);
        }
        // The control: the mutant must NOT redden the literal rows — otherwise the
        // "redden exactly the pins it reverts" claim would be false.
        // ── M9/M10 — the SKEW path (review P1 of PR #3978) ──────────────────
        // A stale/short `classify-git.mjs` must leave the fail-safe DEFAULT, never
        // bind `undefined`: a destructuring-target binding did the latter and
        // THREW a TypeError out of `_coordinatedDeleteBlock` on every
        // delete-shaped command (`classifierLoaded` is still true — nothing threw
        // at import). The mutant here is that stale module: the new export is
        // gone, everything else is the shipped file.
        const skewDir = join(tmp, "ext-skew");
        cpSync(join(HERE, ".."), skewDir, {
          recursive: true,
          filter: (p2) => !p2.includes("node_modules") && !p2.endsWith(".git"),
        });
        const skewClassify = join(skewDir, "main-worktree-guard", "classify-git.mjs");
        {
          const cgSrc = readFileSync(skewClassify, "utf-8");
          const start = cgSrc.indexOf("export function unresolvableDeleteTargets(");
          const end = cgSrc.indexOf("\n}\n", start);
          expectTrue("M9: the skew mutant could be built (a stale-module row that cannot be built proves nothing)",
            start !== -1 && end !== -1);
          if (start !== -1 && end !== -1) {
            writeFileSync(skewClassify, cgSrc.slice(0, start) + cgSrc.slice(end + 3));
          }
        }
        const skew = await loadGuard(join(skewDir, "main-worktree-guard", "index.ts"), hub);
        expectTrue("M9b: the skewed module still LOADS (the export's absence must not be an import-time throw)",
          skew.loaded, JSON.stringify(skew.warnings.filter((w) => w.includes("main-worktree-guard"))).slice(0, 200));
        await quiet(() => skew.start(hub));
        let skewThrew = null;
        let skewLiteral = null;
        try {
          skewLiteral = await quiet(() => skew.bash("git push origin --delete held"));
        } catch (e) {
          skewThrew = String(e).slice(0, 160);
        }
        expectTrue("M10 (P1): under module skew a delete-shaped command does NOT throw — the fail-safe default holds",
          skewThrew === null, String(skewThrew));
        expectTrue("M10b (P1): and #73's own literal block still fires from the skewed module",
          refusedBy(skewLiteral, HOLDS), `handler returned ${JSON.stringify(skewLiteral)?.slice(0, 160)}`);
        let skewUnresolvedThrew = null;
        try {
          await quiet(() => skew.bash(`git push origin --delete "$PR_BRANCH"`));
        } catch (e) {
          skewUnresolvedThrew = String(e).slice(0, 160);
        }
        expectTrue("M10c (P1): the unresolvable form also does not throw under skew (it degrades to the pre-#653 ALLOW, which is what a stale module can know)",
          skewUnresolvedThrew === null, String(skewUnresolvedThrew));

        // ── M11 — the SAME skew, with the PRE-FIX BINDING (a destructuring target) ──
        // This is the discriminating half of M10: the absent export is bound as
        // `undefined` (a destructuring assignment overwrites the declared default),
        // so the seam THROWS instead of degrading. If M11 does not throw, M10 is
        // not measuring the binding and the P1 pin is dead weight.
        const skew2Dir = join(tmp, "ext-skew-destructure");
        cpSync(skewDir, skew2Dir, { recursive: true });
        const skew2Index = join(skew2Dir, "main-worktree-guard", "index.ts");
        {
          const iSrc = readFileSync(skew2Index, "utf-8");
          const guardBlock = `  if (typeof _m5.unresolvableDeleteTargets === "function") {\n    unresolvableDeleteTargets = _m5.unresolvableDeleteTargets;\n  }`;
          const destructureAnchor = "     extractPushDeleteBranch, wholeCommandDeleteTargets, getWorktreeBranches, isBranchInMainCheckout,";
          const built = iSrc.includes(guardBlock) && iSrc.includes(destructureAnchor);
          expectTrue("M11: the pre-fix-binding mutant could be built (a stale anchor is a failure, never a green)", built);
          if (built) {
            writeFileSync(skew2Index, iSrc
              .replace(guardBlock, "")
              .replace(destructureAnchor, destructureAnchor + "\n     unresolvableDeleteTargets,"));
          }
        }
        if (skew2Dir) {
          const skew2 = await loadGuard(skew2Index, hub);
          await quiet(() => skew2.start(hub));
          let preFixThrew = null;
          try {
            await quiet(() => skew2.bash("git push origin --delete held"));
          } catch (e) {
            preFixThrew = String(e).slice(0, 120);
          }
          expectTrue("M11 (P1, DISCRIMINATING): the destructuring binding THROWS under module skew — the shipped typeof guard does not",
            preFixThrew !== null, "no throw: the M10 row is not measuring the binding");
        }

        expectTrue("M7 mutant control: the literal delete of an unheld branch stays ALLOWED under the mutant",
          (await quiet(() => mut.bash("git push origin -d stale"))) === undefined);
        expectTrue("M8 mutant control: #73's own literal protection stays BLOCKED under the mutant",
          refusedBy(await quiet(() => mut.bash("git push origin --delete held")), HOLDS));
      }

      // ── M12–M15 — the round-17 pins can FAIL (both directions) ─────────
      // Each mutant reverts EXACTLY ONE decision in a temp copy, and each is asserted on the PURE
      // extractor (`extractPushDeleteBranch`) rather than through the handler. That is deliberate and it
      // was measured: M2's branch-ownership arm refuses ANY argv carrying a substitution (`Push
      // target(s): $`), on both trees, so an end-to-end assertion cannot see which arm fired — the first
      // revision of M13 asserted the handler and reported a false failure for exactly that reason. The
      // module-level value has no such ambiguity, and the handler consequence is already pinned
      // end-to-end by D5b/B15/B16 (refused) and C6–C9 (delete arm silent).
      // ⛔ M12's FIRST VERSION COVERED ONLY THE `$(` EMISSION (round-17 review P2.3, MEASURED): the
      // backtick branch is a second, independent decision on its own line, so reverting one left the
      // other unpinned — and the off-by-one P0 lived in exactly that uncovered branch. Each emission now
      // gets its own mutant, and M15 reverts the off-by-one itself.
      {
        const qsNeedle = 'quote = null; out += ch + _QS_MARK; i++; continue;';
        const qsReplacement = 'quote = null; out += ch + swap("("); i++; continue;';
        const btNeedle = 'if (quote === \'"\' && ch === "`") { out += _QS_MARK; continue; }';
        const btReplacement = 'if (quote === \'"\' && ch === "`") { out += swap(ch); continue; }';
        const btOffByOne = 'if (quote === \'"\' && ch === "`") { out += _QS_MARK; i++; continue; }';
        // ⛔ M13 reverts the QUOTED/UNQUOTED split — the ONE line the round-17 P1 turned on — back to the
        // blanket "a span in a value slot is exempt" rule. That mutant is discriminating in BOTH
        // directions, which is why it carries two rows: it restores the false block on the quoted form
        // AND the fail-open on the unquoted spill.
        const spanNeedle = 'const _opaqueInFlagSlot = tokens.some((t, i) =>\n    _isSpanTok(t) && !((_valueSlot[i] && _isQuotedSpanTok(t)) || _isInlineOptValue(t)));';
        // Two reverts of the SAME line, because the split has two halves and each has its own failure:
        //   `always`  — the pre-P2 rule (any span fires)  → the quoted value slot is a false block again;
        //   `blanket` — a value-slot span is always exempt → the unquoted SPILL is a fail-open again.
        const spanAlways = 'const _opaqueInFlagSlot = tokens.some((t) => _isSpanTok(t));';
        const spanBlanket = 'const _opaqueInFlagSlot = tokens.some((t, i) => _isSpanTok(t) && !_valueSlot[i]);';
        const ownNeedle = 'const _ownFlag = tokens.some((t, i) => !_valueSlot[i] && _isPushDeleteFlagToken(t));';
        const ownReplacement = 'const _ownFlag = tokens.some((t) => _isPushDeleteFlagToken(t));';
        // ⛔ M16 — the MIXED-token rule (round-17 review cycle 3): a token that carries BOTH a bare
        // placeholder and a quoted-span mark has an unquoted part and CAN split, so it must lose the
        // value-slot exemption. Reverting it to "always quoted" restores the fail-open. The anchor is
        // the PUSH line only (round-18): the `mixed` variable's own line is unchanged, so anchoring on
        // both lines made this mutant's anchor stale the moment the push line grew the prefix.
        const mixedNeedle = 'tokens.push(mixed ? (head + _SUBST_PLACEHOLDER) : (head + _SUBST_PLACEHOLDER + _QUOTED_SPAN_SUFFIX));';
        const mixedReplacement = 'tokens.push(head + _SUBST_PLACEHOLDER + _QUOTED_SPAN_SUFFIX);';
        // ⛔ M17/M18 — the ROUND-18 pins, each reverting EXACTLY ONE of that round's two decisions:
        //   M17 `progAt` — ask "is this quote a `-c` program operand?" at the `'` again (the pre-fix
        //       off-by-one), which glues the next command's first word onto the delete target;
        //   M18 the span-token prefix — collapse the WHOLE token to the placeholder again, so an
        //       attached `-o` value becomes a bare positional refspec and #653 false-blocks a literal.
        // Both are asserted on the pure extractor for the same reason M12-M16 are (see above).
        const progNeedle = 'const progAt = s[i - 1] === "$" ? i - 1 : i;';
        const progReplacement = 'const progAt = i;';
        const prefixNeedle = 'const raw = t.slice(0, t.indexOf(_QS_MARK));\n      const head = raw.endsWith("$") ? raw.slice(0, -1) : raw;';
        const prefixReplacement = 'const head = "";';
        const cgPath = join(HERE, "classify-git.mjs");
        const cgSrc = readFileSync(cgPath, "utf-8");
        // (M15 mutates the SAME line M14 does, in the other direction, so btNeedle covers both anchors.)
        for (const [name, needle] of [["M12", qsNeedle], ["M14/M15", btNeedle],
                                      ["M13", spanNeedle], ["M13d", ownNeedle], ["M16", mixedNeedle],
                                      ["M17", progNeedle], ["M18", prefixNeedle]]) {
          expectTrue(`${name}: the mutation anchor is present (a stale anchor is a FAILURE, never a green)`,
            cgSrc.includes(needle), `missing ${JSON.stringify(needle)}`);
        }
        /** Build a temp copy with ONE replacement and return its pure classifier. */
        const mutantExtractor = async (tag, from, to) => {
          const d = join(tmp, `ext-mut-${tag}`);
          cpSync(join(HERE, ".."), d, {
            recursive: true,
            filter: (p2) => !p2.includes("node_modules") && !p2.endsWith(".git"),
          });
          writeFileSync(join(d, "main-worktree-guard", "classify-git.mjs"), cgSrc.replace(from, to));
          return import(pathToFileURL(join(d, "main-worktree-guard", "classify-git.mjs")).href);
        };
        const allPresent = cgSrc.includes(qsNeedle) && cgSrc.includes(btNeedle)
          && cgSrc.includes(spanNeedle) && cgSrc.includes(ownNeedle)
          && cgSrc.includes(mixedNeedle) && cgSrc.includes(progNeedle) && cgSrc.includes(prefixNeedle);
        if (allPresent) {
          const cases = [
            ["M12", "qs", qsNeedle, qsReplacement,
              `git push origin -o "x -d y" "$(echo -d)" held/branch`, null,
              "the quoted-`$( )` marker reverted → the delete spelling is INVISIBLE again (a fail-open)"],
            ["M14", "bt", btNeedle, btReplacement,
              "git push origin -o \"x -d y\" \"`echo -d`\" held/branch", null,
              "the quoted-BACKTICK marker reverted → the backtick half is invisible (pinned independently of `$(`)"],
            ["M15", "btoff", btNeedle, btOffByOne,
              "git push origin -o -d \"`echo -d`\" -d held/branch", ["$(…)"],
              "the off-by-one restored → the real target AFTER the span is SWALLOWED (only the marker survives)"],
            ["M13", "spanAlways", spanNeedle, spanAlways,
              `git push origin -o "$(echo -d)" main`, ["main", "$(…)"],
              "the value-slot exemption removed → the FALSE BLOCK is back on a quoted value slot"],
            ["M13b2", "spanBlanket", spanNeedle, spanBlanket,
              `git push origin -o $(echo "x -d held/branch")`, null,
              "the quoted/unquoted split reverted → the SPILL FAIL-OPEN is back (a real delete, attr. nothing)"],
            ["M13d", "own", ownNeedle, ownReplacement,
              "git push origin -o -d $(echo -d) held/branch", null,
              "the naive own-flag test restored → the PRE-EXISTING fail-open is back (all three trees said null)"],
            ["M16", "mixed", mixedNeedle, mixedReplacement,
              "git push origin -o `echo \"x -d held\"`\"$(echo )\"", null,
              "the mixed-token rule reverted → a PARTLY unquoted word is exempted again (real delete, attr. nothing)"],
            ["M17", "progAt", progNeedle, progReplacement,
              `sh -c $'git push origin -d held/branch\necho done'`,
              ["held/branch\necho", "done"],
              "the ANSI-C program flag read at the `'` again → the next command's first word GLUES onto the target (a fail-open)"],
            ["M18", "spanPrefix", prefixNeedle, prefixReplacement,
              `git push origin -o"$(cat msg)" -d old`, ["$(…)", "old"],
              "the span token's prefix discarded again → an attached `-o` value becomes a bare refspec and #653 false-blocks a literal"],
          ];
          for (const [name, tag, from, to, cmd, wantMutant, why] of cases) {
            const ext = await mutantExtractor(tag, from, to);
            const gotMutant = ext.extractPushDeleteBranch(cmd);
            const gotReal = extractPushDeleteBranch(cmd);
            expect(`${name} (DISCRIMINATING): ${why}`, gotMutant, wantMutant);
            expectTrue(`${name}b: …and the SHIPPED module disagrees on the same input (the row measures the code, not the fixture)`,
              JSON.stringify(gotReal) !== JSON.stringify(gotMutant),
              `shipped ${JSON.stringify(gotReal)} vs mutant ${JSON.stringify(gotMutant)}`);
          }
        }
      }
    }
  } catch (e) {
    expectTrue("#653 suite ran without throwing", false, String(e?.stack ?? e).slice(0, 400));
  } finally {
    if (savedEnv.get("HOME") === undefined) delete process.env.HOME; else process.env.HOME = savedEnv.get("HOME");
    for (const v of ["AGENT_INFRA_PATH", "AGENT_LOCKS_DIR"]) {
      if (savedEnv.get(v) === undefined) delete process.env[v]; else process.env[v] = savedEnv.get(v);
    }
    for (const v of HATCH) {
      if (savedEnv.get(v) === undefined) delete process.env[v]; else process.env[v] = savedEnv.get(v);
    }
    rmSync(tmp, { recursive: true, force: true });
  }
}

// ⛔ THE EXIT CODE IS THE DELIVERABLE, AND IT IS NOT THE AGGREGATE's (review P0 of
// this PR, and it is the category-A shape: a suite that prints `❌` and exits 0).
// `reportVerdict` RETURNS the code — `verdict.mjs:96-98` says so in as many words
// ("the caller still owns `process.exit`") — so a harness that discards it is
// green over every failure, which makes BOTH ci.yml steps over this file inert,
// including the `--mutations` leg whose entire job is to prove the pins can fail.
// Same contract as the two siblings that gate on the same `stripTypeScriptTypes`
// capability (test-m2-compound-ownership.mjs, test-unborn-head.mjs): the 4th
// argument is `{ skip, red }` — NOT the bare `skip` number, whose `opts.skip` /
// `opts.red` reads are `undefined` and silently drop the `, N skipped` tail — and
// a run where the whole behavioural half was SKIPPED (`pass === 0`) is a FAILURE,
// never a clean pass.
const vacuous = (skip > 0 && pass === 0) || behaviouralSkipped;
reportVerdict("test-653-delete-target", pass, fail, { skip, red: vacuous });
if (vacuous) console.log("❌ the suite could not run its behavioral half (or ran NOTHING) — the shipped gate was never driven, so this is not a pass");
process.exit(fail === 0 && !vacuous ? 0 : 1);
