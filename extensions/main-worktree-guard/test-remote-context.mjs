// test-remote-context.mjs — #3444: the REMOTE-EXEC context boundary.
//
// The defect: every guard in this extension resolves PATHS and HUB STATE against
// the LOCAL checkout. A command whose execution target is another box —
// `cmux vm exec <vm> -- …`, `ssh <host> …`, `docker exec <c> …` — was judged by
// those local reads anyway. Measured 2026-11-04 from a hub-rooted session:
//
//   #1919  `cmux vm exec cell -- sh -c 'git worktree add rev-3168'`
//          → refused, and the refusal named the LOCAL path
//            (/Users/…/.worktrees/rev-3168) for a command that runs on a cell;
//   #1484  `… -- sh -c 'cd /srv/repo && git checkout feat/x'`
//          → refused by the hub-state gate on the LOCAL checkout;
//   #1144  `… -- sh -c 'cd /srv/repo && git pull --ff-only && make test'`
//          → refused because the LOCAL tree had no baseline and was dirty;
//   #709   a payload PIPED TO A SHELL inside a remote command
//          → refused as an unverifiable piped payload that never runs here.
//
// It made ~87 idle lanes on four cells unusable from the hub, and the only route
// that worked was spelling an ABSOLUTE remote path (which cannot be mistaken for
// a local one).
//
// ⚠️ HONEST SCOPE NOTE (measured, not assumed): the issue also reports a BASE64
// payload piped to a remote shell. At this head that spelling alone is NOT
// refused (`echo <b64> | base64 -d | sh`, remote or local) — the piped-payload
// arm keys on a discard VERB in the visible text, which an encoded payload does
// not carry. The family that IS refused, and that this suite pins, is a payload
// piped to a shell whose text is visible (B4). The base64 spelling is covered on
// the MASK side (A2e: the whole payload is opaque to the local gates either way).
//
// Structure (the sibling-suite shape: parts A/B always, part M opt-in):
//   Part A — classifier-level pins on maskRemoteExecPayloads (zero-dep)
//   Part B — BEHAVIORAL: the REAL index.ts handler, driven against a hermetic
//            hub. Each pinned case asserts BOTH directions: the remote form is
//            ALLOWED and the SAME command run locally is still REFUSED.
//   Part M — MUTATION EVIDENCE (--mutations, its own CI step): TWENTY-ONE mutants are
//            built in a TEMP copy of this extension and each must redden the
//            specific assertion it reverts — the pre-fix identity mask, an
//            over-reaching mask that ignores separators, a swallowed heredoc
//            terminator, a split unquoted-backtick region, a quote-scanned
//            comment, an ANSI-C quote read as a plain quote, a piped payload
//            that blinds the local-shell arm, a dropped heredoc delimiter-line
//            tail, a pipe-head SHELL ALLOW-LIST (the pre-inversion polarity), a
//            heredoc body cut at the physical newline, a delimiter word without
//            quote removal, a pipe bail that skips no redirection target, an
//            array literal treated as command position, an undecodable ANSI-C
//            escape taken literally, a CRLF delimiter word trimmed, a paren depth
//            ignored for the heredoc newline, a process substitution not bailed, a
//            substitution feeding a local command, a delimiter continuation kept
//            as a newline, a local substitution masked anyway (the spawner-wrapper loss), and a
//            redirection `&` treated as a job separator. The leg FAILS (never skips green) when the real-module
//            loader is unavailable, because it is evidence.
//
// Run: node extensions/main-worktree-guard/test-remote-context.mjs
//      node extensions/main-worktree-guard/test-remote-context.mjs --mutations
import { execSync } from "node:child_process";
import {
  cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");
const REPO_EXTENSIONS = join(HERE, "..");

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

const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });

// ─────────────────────────────────────────────────────────────────────────
// Part A — classifier level: maskRemoteExecPayloads
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: the remote-exec mask (classify-git.mjs) ──");
const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { maskRemoteExecPayloads: mask, REMOTE_PAYLOAD_PLACEHOLDER } = cg;

const hasGitWord = (s) => /\bgit\b|\bworktree\b/.test(String(s));

// A1: IDENTITY — a command with no remote boundary is returned BYTE-FOR-BYTE.
// (This is the property that makes the mask safe to run on every bash call: it
// cannot relax a local guard by a byte unless a boundary is really there.)
const IDENTITY = [
  "git worktree add rev-3168",
  "git reset --hard origin/main",
  "git pull --ff-only && make test",
  "echo \"cmux vm exec cell -- git worktree add x\"",
  "grep -rn 'cmux vm exec' docs/ scripts/",
  "git worktree add .worktrees/wt && git commit -m x",
  "ssh",
  "ssh cell-a",                        // an interactive login runs nothing remotely
  "docker exec builder",               // a container shell, no command
  "docker ps -a",
  "cmux vm ls",
  "cmux vm exec cell-a",               // NO `--`: no command was handed over
  "printf 'git checkout -- a.txt' | bash -s",
  "",
];
for (const c of IDENTITY) expect(`A1: identity — ${JSON.stringify(c)}`, mask(c), c);

// A2: `cmux vm exec … <vm> -- <payload>` — the payload is masked, in every
// payload spelling the fleet uses (quoted `-c`, absolute cd, MULTI-LINE, base64,
// and direct argv with no shell wrapper).
const CMUX_CASES = [
  ["A2a", `cmux vm exec cell-a -- sh -c 'git worktree add rev-3168'`],
  ["A2b", `cmux vm exec --timeout 60 cell-a -- sh -c 'cd /srv/repo && git checkout feat/x'`],
  ["A2c", `cmux vm exec cell-a -- sh -c 'cd /srv/repo && git pull --ff-only && make test'`],
  ["A2d", `cmux vm exec cell-a -- sh -c '\ngit worktree add rev-3168\n'`],
  ["A2f", `cmux vm exec cell-a -- git worktree add rev-3168`],
  ["A2g", `cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add rev-3168\nEOS`],
];
for (const [id, c] of CMUX_CASES) {
  const out = mask(c);
  expectTrue(`${id}: the remote payload is masked — ${JSON.stringify(c)}`,
    !hasGitWord(out), JSON.stringify(out));
  expectTrue(`${id}: …and the placeholder marks where it was`, out.includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(out));
}
// A2e: an ENCODED payload carries no git word of its own, so only the
// placeholder/identity-difference half can discriminate here (the non-vacuity is
// the "the text CHANGED and the git-bearing words after it are gone" pair).
{
  const c = `cmux vm exec cell-a -- sh -c 'echo Z2l0IGNv | base64 -d | sh'`;
  const out = mask(c);
  expectTrue("A2e: a base64 payload is masked (placeholder inserted)", out.includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(out));
  expectTrue("A2e: …the transformed text is not the input", out !== c, JSON.stringify(out));
  const c2 = `cmux vm exec cell-a -- sh -c 'echo Z2l0IGNv | base64 -d | sh' && git worktree add loc`;
  expectTrue("A2e: …and a LOCAL command after it survives", mask(c2).includes("git worktree add loc"), JSON.stringify(mask(c2)));
}
expect("A2h: the placeholder is an inert word (no git verb in it)", hasGitWord(REMOTE_PAYLOAD_PLACEHOLDER), false);

// A3: `ssh <host> …` — including options that take a separate value.
for (const [id, c] of [
  ["A3a", `ssh cell-a 'git worktree add rev-3168'`],
  ["A3b", `ssh -p 2222 -o BatchMode=yes cell-a git reset --hard`],
  ["A3c", `ssh -i ~/.ssh/id_ed25519 cell-a 'cd /srv/r && git checkout feat/x'`],
]) {
  expectTrue(`${id}: ssh payload masked — ${JSON.stringify(c)}`, !hasGitWord(mask(c)), JSON.stringify(mask(c)));
}
expectTrue("A3d: `ssh -p 2222 cell-a` with NO command stays identity (nothing runs remotely)",
  mask("ssh -p 2222 cell-a") === "ssh -p 2222 cell-a", mask("ssh -p 2222 cell-a"));

// A4: `docker exec <container> …`
for (const [id, c] of [
  ["A4a", `docker exec builder sh -c 'git worktree add rev-3168'`],
  ["A4b", `docker exec -e A=1 -u root builder git reset --hard`],
]) {
  expectTrue(`${id}: docker exec payload masked — ${JSON.stringify(c)}`, !hasGitWord(mask(c)), JSON.stringify(mask(c)));
}
expectTrue("A4c: `docker exec -e A=1 builder` with no command stays identity",
  mask("docker exec -e A=1 builder") === "docker exec -e A=1 builder", mask("docker exec -e A=1 builder"));

// A5: THE SAFETY HALF — everything outside the remote command stays verbatim and
// therefore stays gated: a LOCAL segment after the boundary, a LOCAL segment
// before it, and a redirection target (a local file write).
const SAFETY = [
  ["A5a", `cmux vm exec cell-a -- sh -c 'git status' ; git worktree add loc`, "git worktree add loc"],
  ["A5b", `cmux vm exec cell-a -- sh -c 'git status' && git reset --hard`, "git reset --hard"],
  ["A5c", `git worktree add lead && cmux vm exec cell-a -- git status`, "git worktree add lead"],
  ["A5d", `cmux vm exec cell-a -- sh -c 'git worktree add rev' > /hub/MEMORY.md`, "> /hub/MEMORY.md"],
  ["A5e", `ssh cell-a 'git status' && git worktree add loc`, "git worktree add loc"],
  ["A5f", `cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`, "git worktree add after"],
];
for (const [id, c, kept] of SAFETY) {
  const out = mask(c);
  expectTrue(`${id}: the LOCAL text is preserved (still gated) — ${JSON.stringify(c)}`,
    out.includes(kept), JSON.stringify(out));
}
// A5g: the heredoc TERMINATOR is structure, not payload — without it the next
// local command reads as heredoc DATA to every downstream parser (a fail-open
// this suite measured while the fix was being written).
expectTrue("A5g: the heredoc terminator line survives on its own line",
  /\nEOS\n/.test(mask(`cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`)),
  JSON.stringify(mask(`cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`)));
expectTrue("A5h: …and the body itself is masked",
  !mask(`cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`).includes("worktree add inside"));

// A6: a substitution that RUNS IN THIS SHELL is never masked. An unquoted or
// DOUBLE-quoted `$(…)` is executed locally even when it sits inside a remote
// command; a SINGLE-quoted one runs on the remote box.
const LOCAL_SUBST = `cmux vm exec cell-a -- echo "$(git worktree add loc-sub)"`;
expectTrue("A6a: a double-quoted local substitution is preserved verbatim",
  mask(LOCAL_SUBST).includes("$(git worktree add loc-sub)"), JSON.stringify(mask(LOCAL_SUBST)));
const LOCAL_SUBST_BARE = `cmux vm exec cell-a -- echo $(git reset --hard)`;
expectTrue("A6b: an unquoted local substitution is preserved verbatim",
  mask(LOCAL_SUBST_BARE).includes("git reset --hard"), JSON.stringify(mask(LOCAL_SUBST_BARE)));
const REMOTE_SUBST = `cmux vm exec cell-a -- sh -c 'echo $(git reset --hard)'`;
expectTrue("A6c: a SINGLE-quoted substitution is remote — masked",
  !hasGitWord(mask(REMOTE_SUBST)), JSON.stringify(mask(REMOTE_SUBST)));

// A7: TWO remote invocations in one command are BOTH masked (the walk re-arms
// after each boundary).
const TWO = `cmux vm exec cell-a -- sh -c 'git worktree add a' && ssh cell-b 'git reset --hard'`;
expectTrue("A7: both remote payloads are masked", !hasGitWord(mask(TWO)), JSON.stringify(mask(TWO)));

// A8: a remote head at COMMAND POSITION only — an operand that merely mentions
// the verb is not a boundary (`grep 'cmux vm exec' …` is A1), and a word inside
// a quoted string does not mask the text after it.
expect("A8: a quoted mention masks nothing", mask(`echo "cmux vm exec cell -- git reset --hard"`),
  `echo "cmux vm exec cell -- git reset --hard"`);

// A9: WRAPPER heads are not modelled, and the mask must leave them ALONE —
// `sudo cmux …` / `env K=V cmux …` keep exactly today's (gated) behaviour. This
// is the fail-closed residual: a boundary recogniser that guessed at wrappers
// would relax the local guards for a command it had not actually resolved.
for (const c of [
  `sudo cmux vm exec cell-a -- sh -c 'git worktree add x'`,
  `env FOO=1 cmux vm exec cell-a -- sh -c 'git worktree add x'`,
  `bash -c "cmux vm exec cell-a -- git worktree add x"`,
]) {
  expect(`A9: a wrapped remote head is NOT masked (fail-closed) — ${JSON.stringify(c)}`, mask(c), c);
}

// A10: THE NAME MUST BE PROVABLY THE TRANSPORT. Two ways a "remote" head can
// resolve LOCALLY instead:
//   (i)  it is not the bare command word — `./ssh` (or `/usr/bin/ssh`, or a
//        quoted `"ssh"`) is a local FILE that executes the same argv HERE;
//   (ii) the name was REDEFINED before it (`ssh() { … }`, `alias ssh=…`), or
//        built from text no scan can read (`eval`, `source`, POSIX `.`).
// Both keep today's gating: a boundary that cannot be proven is not a boundary.
const FAIL_CLOSED_HEADS = [
  `./ssh cell-a git worktree add x`,
  `/usr/bin/ssh cell-a git worktree add x`,
  `"ssh" cell-a git worktree add x`,
  `./cmux vm exec cell-a -- git worktree add x`,
  `ssh() { git worktree add x; }; ssh cell-a git reset --hard`,
  `function ssh { git worktree add x; }; ssh cell-a git reset --hard`,
  `alias ssh=git; ssh cell-a git worktree add x`,
  `eval "$X"; ssh cell-a git worktree add x`,
  `. ./defs.sh; ssh cell-a git worktree add x`,
  `source defs.sh; ssh cell-a git worktree add x`,
  `FOO=1 ssh cell-a git worktree add x`,   // an assignment head: not command position
];
for (const c of FAIL_CLOSED_HEADS) {
  expect(`A10: an unprovable transport head is NOT masked (fail-closed) — ${JSON.stringify(c)}`, mask(c), c);
}
// A10b: ssh's OWN argv is executed LOCALLY, so it must stay VISIBLE even when
// the boundary is recognised (`-o ProxyCommand=…` runs a command here). The mask
// only removes the payload — it must not swallow the transport's arguments.
expectTrue("A10b: ssh's own argv (a local ProxyCommand) survives the mask",
  mask(`ssh -o ProxyCommand='git reset --hard' cell-a ls -la`).includes("ProxyCommand='git reset --hard'"),
  JSON.stringify(mask(`ssh -o ProxyCommand='git reset --hard' cell-a ls -la`)));
// A10c: PATH-qualified transports inside a larger command stay gated too.
expectTrue("A10c: a path-qualified head in a compound is not masked",
  mask(`git status && /usr/bin/ssh cell-a git worktree add x`).includes("git worktree add x"),
  JSON.stringify(mask(`git status && /usr/bin/ssh cell-a git worktree add x`)));

// A11 (#3478 review P0): an UNQUOTED backtick region runs in THIS shell. The
// opening token used to be kept while the rest of the region was masked, so
// `` `git reset --hard` `` inside a remote command lost its verb and the LOCAL
// reset was allowed. The WHOLE region must survive.
for (const c of [
  `cmux vm exec cell-a -- \`git reset --hard\``,
  `cmux vm exec cell-a -- echo \`git reset --hard\``,
  `ssh cell-a \`git reset --hard\``,
  // A DOUBLE-quoted backtick region is a local execution too (double quotes do
  // not stop substitution) — it must survive with the token that holds it.
  `cmux vm exec cell-a -- sh -c "echo \`git reset --hard\`"`,
]) {
  const out = mask(c);
  expectTrue(`A11: a LOCAL backtick region survives — ${JSON.stringify(c)}`,
    out.includes("git reset --hard"), JSON.stringify(out));
}
// …while a backtick region in the REMOTE script (single quotes) is masked with it.
for (const c of [
  `cmux vm exec cell-a -- sh -c 'echo \`git reset --hard\`'`,
  `cmux vm exec cell-a -- sh -s <<'EOS'\necho \`git reset --hard\`\nEOS`,
]) {
  expectTrue(`A11b: a remote backtick region is masked — ${JSON.stringify(c)}`,
    !hasGitWord(mask(c)), JSON.stringify(mask(c)));
}

// A12 (#3478 review P0): a REDIRECT in the operand position is the LOCAL shell's
// write — `ssh cell-a > a.txt` truncates a LOCAL file and hands ssh no command at
// all. The operand walk used to read the redirect's TARGET as the payload and
// mask it, hiding a tracked-hub write.
for (const c of [`ssh cell-a > a.txt`, `docker exec b > a.txt`, `cmux vm exec cell-a -- > a.txt`]) {
  expect(`A12: a redirect-only remote form is NOT masked (its target is local) — ${JSON.stringify(c)}`, mask(c), c);
}

// A13 (#3478 review P1): a TRAILING separator is the last token, and the walk
// dereferenced the token after it — a TypeError that escaped the hook and aborted
// the whole bash call (no guard message at all). Every shape must return a string.
const TRAILING = [
  `cmux vm exec cell-a -- ls\n`,
  `cmux vm exec cell-a -- sh -s <<'EOS'\nls\nEOS\n`,
  `ssh cell-a 'ls' &`,
  `cmux vm exec cell-a -- ls ;`,
  `cmux vm exec cell-a -- ls |`,
  `docker exec b ls &&`,
];
for (const c of TRAILING) {
  let threw = null;
  let out = null;
  try { out = mask(c); } catch (e) { threw = String(e && e.message); }
  expectTrue(`A13: a trailing separator does not throw — ${JSON.stringify(c)}`, threw === null, threw ?? "");
  expectTrue(`A13: …and the payload is still masked — ${JSON.stringify(c)}`,
    typeof out === "string" && out.includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(out));
}

// A14 (#3478 review P2): an INDENTED terminator does NOT close a plain `<<`
// heredoc, so everything after it is still BODY (the shell would warn and read the
// rest as the body) — masking it all is correct, and stopping at the indented line
// would expose remote script text as local commands. `<<-` DOES strip leading tabs.
{
  const c = `cmux vm exec cell-a -- sh -s <<'EOS'\nls\n  EOS\ngit worktree add after`;
  expectTrue("A14: an indented terminator does not end a plain `<<` heredoc",
    !hasGitWord(mask(c)), JSON.stringify(mask(c)));
  const c2 = `cmux vm exec cell-a -- sh -s <<-'EOS'\nls\n\tEOS\ngit worktree add after`;
  expectTrue("A14b: an indented terminator DOES end a `<<-` heredoc",
    mask(c2).includes("git worktree add after"), JSON.stringify(mask(c2)));
}

// A15 (#3478 review P2): two heredocs on ONE line make the body order depend on
// source position, not token order — unprovable, so the command is left gated.
{
  const c = `cmux vm exec cell-a -- sh -s <<'A' <<'B'\nx\nA\ny\nB`;
  expect("A15: two heredocs on one line → NOT masked (fail-closed)", mask(c), c);
}

// A16 (#3478 review cycle 2 P0): a `#` at the START of a word begins a COMMENT,
// and the shell discards the rest of the LINE — quote characters included. The
// tokenizer quote-scanned comments, so `# don't` opened a region that swallowed
// the newline and the NEXT, genuinely LOCAL, line was masked away.
for (const c of [
  `cmux vm exec cell-a -- ls # it's fine\ngit reset --hard`,
  `cmux vm exec cell-a -- ls # don't\n echo x >> a.txt`,
  `ssh cell-a ls # it's\ngit worktree add rev-9`,
  `cmux vm exec cell-a -- ls # say "hi\ngit reset --hard`,
]) {
  expectTrue(`A16: a quote inside a COMMENT does not swallow the next local line — ${JSON.stringify(c)}`,
    mask(c).includes(c.slice(c.indexOf("\n") + 1)), JSON.stringify(mask(c)));
}
// …and a `#` that does NOT start a word is still an ordinary character.
expect("A16b: `ls#x` is not a comment (the word stays payload)", hasGitWord(mask(`cmux vm exec cell-a -- ls#git`)), false);

// A17 (#3478 review cycle 2 P0): `$'…'` is ANSI-C quoting, where `\'` ESCAPES and
// does not close the region. Read as plain quoting it closed early, re-opened, and
// again ate the newline — masking a local line.
{
  const c = `cmux vm exec cell-a -- echo $'don\\'t'\ngit reset --hard`;
  expectTrue("A17: `$'don\\'t'` does not swallow the next local line",
    mask(c).includes("git reset --hard"), JSON.stringify(mask(c)));
}

// A18 (#3478 review cycle 2 P1): a pipe that FEEDS A LOCAL SHELL runs the remote
// stdout as a local script (#709's case). Masking the seed left that arm with
// nothing to inspect, so a refused piped payload became allowed — leave the
// command UNMASKED and let the pre-fix refusal stand.
for (const c of [
  `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | bash -s`,
  `cmux vm exec cell-a -- printf 'x' | sh`,
  `cmux vm exec cell-a -- printf 'x' | /bin/bash -s`,
  `cmux vm exec cell-a -- printf 'x' | cat | bash -s`,
  `cmux vm exec cell-a -- printf 'x' | env FOO=1 bash`,
]) {
  expectTrue(`A18: a payload piped into a LOCAL shell is NOT masked — ${JSON.stringify(c)}`,
    hasGitWord(mask(c)) || mask(c).includes("printf"), JSON.stringify(mask(c)));
}
// …while a pipe whose target is NOT an interpreter is still masked (the pipe
// itself is local, so its target stays visible and gated).
expectTrue("A18b: a payload piped into a non-shell is still masked",
  mask(`cmux vm exec cell-a -- x | grep y`).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(`cmux vm exec cell-a -- x | grep y`)));
expectTrue("A18c: an unrelated local `… | bash` in another command does not disable the mask",
  mask(`cmux vm exec cell-a -- x ; git log | bash`).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(`cmux vm exec cell-a -- x ; git log | bash`)));

// A19 (#3478 review cycle 2 P2): `$(` is a top-level separator for this scanner,
// so an UNQUOTED substitution ENDS the mask (fail-closed: the remainder is gated
// exactly as today). Pinned so the documented behaviour and the code agree.
{
  const c = `cmux vm exec cell-a -- echo $((1+2)) git reset --hard`;
  expectTrue("A19: an unquoted `$(` ends the mask (the remainder stays GATED)",
    mask(c).includes("git reset --hard"), JSON.stringify(mask(c)));
}

// A20: an UNTERMINATED quote is a command this scanner does not understand — in
// valid bash that only happens inside a comment — so the command is left
// unmasked (fail-closed) rather than masked on a misreading.
{
  const c = "cmux vm exec cell-a -- sh -c 'unterminated";
  expect("A20: an unterminated quote leaves the command UNMASKED", mask(c), c);
}

// A21 (#3478 review cycle 3 P0): the REST OF THE DELIMITER LINE is LOCAL text.
// bash runs `cmd <<'EOS'; foo` / `… && foo` / `… | tee f` / `… > f` HERE after the
// body is consumed; that tail used to be DROPPED (not masked — dropped), so
// `… <<'EOS'; git worktree add loc` and `… <<'EOS' > a.txt` went BLOCKED →
// ALLOWED. The tail must survive VERBATIM.
for (const [c, must] of [
  [`cmux vm exec cell-a -- sh -s <<'EOS'; git worktree add rev-9999\nbody\nEOS`, "git worktree add rev-9999"],
  [`cmux vm exec cell-a -- sh -s <<'EOS' && git worktree add rev-9999\nbody\nEOS`, "git worktree add rev-9999"],
  [`cmux vm exec cell-a -- sh -s <<'EOS' | tee a.txt\nbody\nEOS`, "tee a.txt"],
  [`cmux vm exec cell-a -- sh -s <<'EOS' > a.txt\nbody\nEOS`, "> a.txt"],
  [`cmux vm exec cell-a -- sh -s <<-'EOS'; git worktree add loc\nbody\nEOS`, "git worktree add loc"],
]) {
  expectTrue(`A21: the heredoc DELIMITER-LINE tail is kept verbatim — ${JSON.stringify(c)}`,
    mask(c).includes(must), JSON.stringify(mask(c)));
  expectTrue(`A21: …and the body is still masked — ${JSON.stringify(c)}`,
    mask(c).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(c)));
  expectTrue(`A21: …and the terminator still closes the heredoc — ${JSON.stringify(c)}`,
    /\nEOS\s*$/.test(mask(c)), JSON.stringify(mask(c)));
}

// A22 (#3478 review cycle 3 P0): the local-shell pipe bail must not be a
// spelling allow-list — `|&`, subshell/brace decorations, a `$SHELL`/quoted head
// and a multi-word launcher all execute the remote stdout HERE.
for (const c of [
  `cmux vm exec cell-a -- printf 'git checkout -- a.txt' |& bash -s`,
  `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | (bash -s)`,
  `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | { bash -s; }`,
  `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | "$SHELL"`,
  `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | busybox sh`,
  `X=$(cmux vm exec cell-a -- printf 'git checkout -- a.txt' | bash -s); echo "$X"`,
]) {
  expectTrue(`A22: a piped payload into a LOCAL shell is unmasked — ${JSON.stringify(c)}`,
    mask(c).includes("git checkout -- a.txt"), JSON.stringify(mask(c)));
}

// A23 (#3478 review cycle 3 P2, fail-closed gaps the issue's goal needs closed):
// a heredoc payload with no payload WORD (`ssh cell <<'EOS'`), and value flags
// carrying their value (`-p22`, `-L8080:host:80`, `-oK=V`) which used to swallow
// the HOST and lose the boundary entirely.
for (const c of [
  `ssh cell <<'EOS'\ngit worktree add rev\nEOS`,
  `ssh -p22 cell 'git worktree add x'`,
  `ssh -L8080:localhost:80 cell 'git worktree add x'`,
  `ssh -oProxyCommand=x cell 'git worktree add x'`,
  `ssh -o ProxyCommand=x cell 'git worktree add x'`,
]) {
  expectTrue(`A23: a remote payload is recognised — ${JSON.stringify(c)}`,
    hasGitWord(mask(c)) === false, JSON.stringify(mask(c)));
}
// …while a redirect-only ssh form is STILL not a boundary (its write is local).
expect("A23b: `ssh cell > a.txt` stays unmasked", mask(`ssh cell > a.txt`), `ssh cell > a.txt`);

// A25 (#3478 review cycle 4 P0): the heredoc body starts after the LOGICAL line,
// not the first PHYSICAL newline. A `\`+newline continuation (or a quote spanning
// a newline) joins the command line, so cutting at the physical newline dropped
// the joined remainder — a local write, hidden.
for (const [c, must] of [
  [`cmux vm exec c -- sh -s <<'EOS'; \\\necho hacked > a.txt\nbody\nEOS`, "echo hacked > a.txt"],
  [`cmux vm exec c -- sh -s <<'EOS'; \\\ngit worktree add loc\nbody\nEOS`, "git worktree add loc"],
  [`ssh cell <<'EOS'; \\\ngit worktree add loc\nbody\nEOS`, "git worktree add loc"],
  [`cmux vm exec c -- sh -s <<'EOS'; echo "a\nb" && git worktree add loc\nbody\nEOS`, "git worktree add loc"],
]) {
  expectTrue(`A25: a CONTINUED delimiter line keeps its local remainder — ${JSON.stringify(c)}`,
    mask(c).includes(must), JSON.stringify(mask(c)));
  expectTrue(`A25: …and the body is still masked — ${JSON.stringify(c)}`,
    mask(c).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(c)));
}

// A26 (#3478 review cycle 4 P0): a heredoc delimiter word goes through SHELL QUOTE
// REMOVAL, so `<<$'EOS'`, `<<$"EOS"`, `<<E"OS"` and `<<\EOS` all terminate at
// `EOS`. Before, the quotes were kept, no terminator matched, and the mask ran to
// end-of-string — hiding every LOCAL command after the real terminator.
for (const [c, must] of [
  [`cmux vm exec c -- sh -s <<$'EOS'\nbody\nEOS\necho hacked > a.txt`, "echo hacked > a.txt"],
  [`cmux vm exec c -- sh -s <<$"EOS"\nbody\nEOS\ngit worktree add loc`, "git worktree add loc"],
  [`cmux vm exec c -- sh -s <<E"OS"\nbody\nEOS\ngit worktree add loc`, "git worktree add loc"],
  [`cmux vm exec c -- sh -s <<\\EOS\nbody\nEOS\ngit worktree add loc`, "git worktree add loc"],
  [`ssh cell <<$'EOS'\nbody\nEOS\ngit worktree add loc`, "git worktree add loc"],
]) {
  expectTrue(`A26: a QUOTED delimiter still terminates at the plain word — ${JSON.stringify(c)}`,
    mask(c).includes(must), JSON.stringify(mask(c)));
}
// …while an EXPANSION in a delimiter stays literal (bash does not expand it), so the
// heredoc terminates at `$X` and the next line is still local text.
expectTrue("A26b: `<<$X` is literal, so the next line is preserved",
  mask(`cmux vm exec c -- sh -s <<$X\nbody\n$X\ngit worktree add loc`).includes("git worktree add loc"),
  JSON.stringify(mask(`cmux vm exec c -- sh -s <<$X\nbody\n$X\ngit worktree add loc`)));

// A27 (#3478 review cycle 4 P0): the piped-payload rule is a CLOSED allow-list of
// consumers that cannot execute stdin — every other stage head bails to gating.
for (const c of [
  `cmux vm exec cell -- printf 'git checkout -- a.txt' | > /tmp/f bash -s`,
  `cmux vm exec cell -- printf 'git checkout -- a.txt' | timeout 5 bash -s`,
  `cmux vm exec cell -- printf 'git checkout -- a.txt' |\n bash -s`,
  `cmux vm exec cell -- printf 'git checkout -- a.txt' | { S=bash; $S -s; }`,
  `cmux vm exec cell -- printf 'git checkout -- a.txt' | (python3 -c 'import sys')`,
  `cmux vm exec cell -- printf 'git checkout -- a.txt' | awk '{print}'`,
  `cmux vm exec cell -- printf 'git checkout -- a.txt' | sed ''`,
]) {
  expectTrue(`A27: a stage head that may RUN its stdin is not masked — ${JSON.stringify(c)}`,
    mask(c).includes("git checkout -- a.txt"), JSON.stringify(mask(c)));
}
// …and a proven DATA consumer still lets the payload be masked.
for (const c of [
  `cmux vm exec cell -- printf x | grep y`,
  `cmux vm exec cell -- printf x | cat`,
  `cmux vm exec cell -- printf x | /usr/bin/grep y`,
  `cmux vm exec cell -- printf x | wc -l`,
  `cmux vm exec cell -- printf x | sort | uniq -c`,
]) {
  expectTrue(`A27b: a DATA consumer does not disable the mask — ${JSON.stringify(c)}`,
    mask(c).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(c)));
}

// A28: a payload-word heredoc emits the placeholder ONCE (the body placeholder is
// for the `ssh cell <<'EOS'` shape, where there is no payload word to mask).
{
  const out = mask(`cmux vm exec c -- sh -s <<'EOS'\nbody\nEOS`);
  expect("A28: exactly ONE placeholder for a payload-word heredoc",
    out.split(REMOTE_PAYLOAD_PLACEHOLDER).length - 1, 1);
}

// A29 (#3478 review cycle 5 P0): a heredoc delimiter must be resolved EXACTLY or
// the command is left alone — a WRONG delimiter never matches the real terminator,
// so the mask runs to end-of-string and hides every LOCAL command after it.
for (const c of [
  // bash decodes character-code escapes in `$'…'`; this remover does not ⇒ bail.
  `cmux vm exec c -- sh -s <<$'E\\101OS'\nbody\nEAOS\ngit worktree add octal`,
  `cmux vm exec c -- sh -s <<$'\\x45OS'\nbody\nEOS\ngit worktree add hex`,
  `cmux vm exec c -- sh -s <<$'\\u0045OS'\nbody\nEOS\ngit worktree add uni`,
  // …and an unknown escape KEEPS its backslash (bash: `$'\d'` is `\d`), so this
  // one must still resolve and mask.
]) {
  expect("A29: an undecodable ANSI-C delimiter leaves the command UNMASKED", mask(c), c);
}
expectTrue("A29b: an unknown ANSI-C escape keeps its backslash (still resolvable)",
  mask(`cmux vm exec c -- sh -s <<$'\\dS'\nbody\n\\dS\ngit worktree add d`).includes("git worktree add d"),
  JSON.stringify(mask(`cmux vm exec c -- sh -s <<$'\\dS'\nbody\n\\dS\ngit worktree add d`)));

// A30 (#3478 review cycle 5 P0): CR is NOT IFS whitespace — `<<'EOS'` + CRLF has the
// delimiter `EOS\r`. The tokenizer trims the CR, so the computed word never matches
// and the mask would run past every LOCAL command after the terminator.
for (const c of [
  `cmux vm exec c -- sh -s <<'EOS'\r\nbody\r\nEOS\r\ngit worktree add crlf`,
  `ssh cell <<'EOS'\r\nbody\r\nEOS\r\ngit worktree add crlf`,
  `cmux vm exec c -- sh -s <<EOS\r\nbody\r\nEOS\r\ngit worktree add crlf`,
]) {
  expect("A30: a CRLF delimiter word leaves the command UNMASKED", mask(c), c);
}

// A31 (#3478 review cycle 5 P0): `(` is a separator token, so a newline inside an
// unquoted `$(…)` / `$((…))` on the delimiter line is NOT the body start — bash ends
// the line at depth 0, and taking the inner newline dropped the substitution's
// local remainder.
for (const c of [
  `cmux vm exec c -- sh -s <<'EOS' $(true\n) ; git worktree add NL1\nbody\nEOS`,
  `cmux vm exec c -- sh -s <<'EOS' $((1 +\n1)) ; git worktree add NL2\nbody\nEOS`,
  `ssh cell <<'EOS' $(true\n) ; git worktree add NL3\nbody\nEOS`,
]) {
  expectTrue(`A31: a newline inside a substitution does not end the delimiter line — ${JSON.stringify(c)}`,
    /git worktree add NL[123]/.test(mask(c)), JSON.stringify(mask(c)));
}

// A32 (#3478 review cycle 5 P0): a PROCESS SUBSTITUTION hands the payload to a
// command THIS shell runs (`bash <(cmux vm exec …)`), which #709 refused before the
// mask existed — so the command is left unmasked.
for (const c of [
  `bash <(cmux vm exec c -- printf 'git checkout -- a.txt')`,
  `sh <(cmux vm exec c -- printf 'git checkout -- a.txt')`,
  `bash < <(cmux vm exec c -- printf 'git checkout -- a.txt')`,
]) {
  expect("A32: process substitution is NOT masked", mask(c), c);
}

// A33 (#3478 review cycle 5 P2): an ARRAY LITERAL is not command position —
// `arr=(ssh cell 'x')` stores words, it runs nothing, so the identity invariant holds.
{
  const c = `arr=(ssh cell 'x')`;
  expect("A33: an array literal is not masked", mask(c), c);
}

// A34 (#3478 review cycle 6 P0): a COMMAND SUBSTITUTION whose body is the boundary
// hands remote stdout to a command THIS shell runs. `_rbFeedsLocalShell` only sees
// `|` stages and the `<(` bail only process substitution, so this was masked while
// origin/main refused it (#1919).
for (const c of [
  `bash -c $(cmux vm exec cell-a -- sh -c 'git worktree add rev-9')`,
  `sh -c $(cmux vm exec cell-a -- sh -c 'git worktree add rev-9')`,
  `$(cmux vm exec cell-a -- sh -c 'git worktree add rev-9')`,
  `env bash -c $(cmux vm exec cell-a -- sh -c 'git worktree add rev-9')`,
  `python3 -c $(cmux vm exec cell-a -- sh -c 'x')`,
]) {
  expect("A34: a substitution that feeds a LOCAL command is NOT masked", mask(c), c);
}
// …while a pure ASSIGNMENT has no consumer here and stays masked.
for (const c of [
  `x=$(cmux vm exec cell-a -- printf x)`,
  `X=$(cmux vm exec cell-a -- printf x); echo done`,
]) {
  expectTrue(`A34b: a substitution consumed by nobody stays masked — ${JSON.stringify(c)}`,
    mask(c).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(c)));
}
// …and a DATA consumer consuming it still allows the mask.
expectTrue("A34c: a substitution fed to grep is still masked",
  mask(`grep $(cmux vm exec cell-a -- printf x) file`).includes(REMOTE_PAYLOAD_PLACEHOLDER),
  JSON.stringify(mask(`grep $(cmux vm exec cell-a -- printf x) file`)));

// A37 (#3478 review cycle 8 P1): `&` is a job separator ONLY when it is not part
// of a REDIRECTION. Splitting on a redirection `&` cut the segment between the
// payload and its pipe, so `… 2>&1 | bash -s` was masked again — the #709 class
// the bail exists to prevent.
for (const redir of ["2>&1", ">&2", "&>/dev/null", "&>>/tmp/log", "2>/dev/null"]) {
  for (const shell of ["bash -s", "sh", "bash -s -- -x"]) {
    const c = `cmux vm exec cell-a -- printf 'git reset --hard' ${redir} | ${shell}`;
    expect(`A37: a REDIRECTION \`&\` is not a stage boundary — ${JSON.stringify(c)}`, mask(c), c);
  }
}
// …while a backgrounding `&` IS a boundary: `grep x & bash -c $(…)` must bail.
expect("A37b: a backgrounded consumer does not hide a later executor",
  mask(`grep x & bash -c $(cmux vm exec cell-a -- printf 'y')`),
  `grep x & bash -c $(cmux vm exec cell-a -- printf 'y')`);


// A36 (#3478 review cycle 7 P1): a local substitution INSIDE the masked run loses
// the `sh -c` SPAWNER wrapper that #1919 walks, so keeping the token verbatim was
// not enough — origin/main refused `sh -c "echo $(git worktree add loc)"` and the
// mask turned it into an allow. A local substitution found inside a masked run
// leaves the WHOLE command unmasked.
for (const c of [
  `cmux vm exec cell-a -- sh -c "echo $(git worktree add loc)"`,
  `cmux vm exec cell-a -- sh -c "$(git worktree add loc)"`,
  `cmux vm exec cell-a -- sh -c "echo x $(git worktree add loc) y"`,
  `cmux vm exec cell-a -- sh -c "x=$(git worktree add loc); echo $x"`,
  "cmux vm exec cell-a -- sh -c \"echo ${x:-$(git worktree add loc)}\"",
  `cmux vm exec cell-a -- sh -c "echo \`echo $(git worktree add loc)\`"`,
  `ssh cell-a sh -c "echo $(git worktree add loc)"`,
  `docker exec c sh -c "echo $(git worktree add loc)"`,
]) {
  expect("A36: a local substitution INSIDE the payload leaves the command UNMASKED", mask(c), c);
}
// …while the SINGLE-quoted spelling (remote text, no local execution) is still masked.
for (const c of [
  `cmux vm exec cell-a -- sh -c 'echo $(git worktree add loc)'`,
  `cmux vm exec cell-a -- sh -c 'git worktree add rev'`,
]) {
  expectTrue(`A36b: remote script text is still masked — ${JSON.stringify(c)}`,
    mask(c).includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(mask(c)));
}


// A35 (#3478 review cycle 6 P2): a `\`+newline INSIDE a delimiter word is DELETED by
// bash (not a newline). Emitting the newline computed a delimiter the shell never
// uses, so no terminator matched and the mask ran to end-of-string.
for (const c of [
  `cmux vm exec cell-a -- sh -s <<EO\\\nS\n:\nEOS\ngit worktree add cont1\n`,
  `cmux vm exec cell-a -- sh -s <<"EO\\\nS"\n:\nEOS\ngit worktree add cont2\n`,
]) {
  expectTrue(`A35: a continued delimiter word still terminates at EOS — ${JSON.stringify(c)}`,
    /git worktree add cont[12]/.test(mask(c)), JSON.stringify(mask(c)));
}


// ─────────────────────────────────────────────────────────────────────────
// Part B — BEHAVIORAL: the real index.ts handler against a hermetic hub
// ─────────────────────────────────────────────────────────────────────────
if (typeof stripTypeScriptTypes !== "function" ||
    (typeof register !== "function" && typeof registerHooks !== "function")) {
  // The mutation leg is EVIDENCE: if the loader is unavailable it cannot run, and
  // a green exit would claim proof it never produced. Fail closed there; the
  // plain leg keeps the suite's Part-A coverage and reports the skip.
  if (process.argv.includes("--mutations")) {
    expectTrue("M: the mutation leg REQUIRES the real index.ts loader", false,
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  } else {
    skipped("Part B/C/M: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  }
} else {
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  const savedEnv = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"]
    .map((v) => [v, process.env[v]]));

  /** Load ONE copy of the extension (the real one, or a mutant copy) and return a
   *  `bash(command)` driver bound to `hub`. */
  async function loadGuard(indexPath, hub) {
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    let mod;
    try { mod = await import(pathToFileURL(indexPath).href); } finally { console.warn = realWarn; }
    const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]") && w.includes("failed to load"));
    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    const bash = async (command) => {
      const prev = process.cwd();
      process.chdir(hub);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    return { bash, degradation, loaded: typeof toolCall === "function" };
  }

  /** The pinned command set. `remote` must be ALLOWED, `local` must be BLOCKED,
   *  and `marker` is the guard-specific text the refusal must carry (so the pair
   *  proves WHICH guard the local form still trips). */
  const PINNED = [
    { id: "B1", guard: "#1919 nested worktree",
      remote: `cmux vm exec cell-a -- sh -c 'git worktree add rev-3168'`,
      local: "git worktree add rev-3168",
      marker: "#1919" },
    { id: "B2", guard: "#1484 hub-state / M3 branch-state",
      remote: `cmux vm exec cell-a -- sh -c 'cd /srv/repo && git checkout feat/x'`,
      local: "git checkout feat/x",
      marker: "MAIN checkout" },
    { id: "B3", guard: "#1144 sync allowance",
      remote: `cmux vm exec cell-a -- sh -c 'cd /srv/repo && git pull --ff-only && make test'`,
      local: "git pull --ff-only && make test",
      marker: "blocked" },
    { id: "B4", guard: "#709 piped payload",
      // ⛔ THIS PIN CANNOT DISCRIMINATE THE PRE-FIX MUTANT, and that is MEASURED, not assumed.
      // Under `no remote boundary` (mask = identity) the pre-fix guard ALLOWS this remote form
      // too, so `expectRed` cannot hold it. The reason is structural, not a stale anchor: the
      // pipe and its `bash -s` target live INSIDE the `sh -c` script, so there is no TOP-LEVEL
      // pipe and no LOCAL stage head for the walk to gate. (That — not "the payload is an argument
      // to printf" — is the decisive fact: `sh -c 'git checkout -- a.txt | bash -s'` puts a discard
      // verb in command position and is STILL allowed in both worlds. The top-level pipe is what
      // pre-fix sees, which is why the heredoc pin B4b below DOES flip.)
      // What this pin IS is COVERAGE, and it is worth keeping: a fully-REMOTE pipeline must not be
      // false-blocked. End-to-end mutation evidence for #709 is carried by B4b (the heredoc
      // spelling, which flips) and by the pipe-family MASK mutants ("piped payload masked (local
      // shell blinded)", "pipe head allow-list (shells only)", "pipe redirect target not skipped").
      // ⛔ B16/B16r, B19 and the B21 stage-head allow-list are NOT offered here as discriminating
      // #709 pins, and that is MEASURED (#3774 review, P2): a top-level pipe into a LOCAL shell is
      // REFUSED under the pre-fix mask AND under the fixed one, so those pins cannot flip either —
      // naming them as "discriminating" would send the next lane to re-add one to `expectRed` and
      // reproduce exactly the red this change removes.
      preFixDiscriminating: false,
      remote: `cmux vm exec cell-a -- sh -c 'printf "git checkout -- a.txt" | bash -s'`,
      local: `printf 'git checkout -- a.txt' | bash -s`,
      marker: "#709" },
    { id: "B4b", guard: "#709 piped payload via a REMOTE heredoc",
      // The #709 arm's DISCRIMINATING spelling (measured): `sh -s <<'EOS'` keeps the pipe at the
      // top level of the payload the walk sees, so reverting the mask makes the pre-fix guard
      // REFUSE the remote form again — while the real mask allows it, because the payload runs on
      // the CELL. Same local twin as B4, so the pair still proves which guard the local form trips.
      remote: `cmux vm exec cell-a -- sh -s <<'EOS'\nprintf "git checkout -- a.txt" | bash -s\nEOS`,
      local: `printf 'git checkout -- a.txt' | bash -s`,
      marker: "#709" },
    { id: "B5", guard: "ssh → #1919",
      // The BARE-ARGV spelling: `ssh` is a spawner word, so the classifier walks
      // its trailing argv as a command and the pre-fix guard refused the remote
      // worktree add exactly like the local one (that is what makes this pin
      // discriminating — the QUOTED spelling was never walked pre-fix).
      remote: `ssh cell-a git worktree add rev-3168`,
      local: "git worktree add rev-3168",
      marker: "#1919" },
    { id: "B6", guard: "docker exec → branch-state",
      remote: `docker exec -e A=1 builder sh -c 'git checkout feat/x'`,
      local: "git checkout feat/x",
      marker: "MAIN checkout" },
    { id: "B7", guard: "remote payload + LOCAL redirect into a tracked hub file",
      remote: `cmux vm exec cell-a -- sh -c 'git status' > a.txt`,
      local: `cmux vm exec cell-a -- sh -c 'git status' > a.txt`,
      marker: "tracked file",
      both: "block" },
    { id: "B8", guard: "remote payload + trailing LOCAL worktree add",
      remote: `cmux vm exec cell-a -- sh -c 'git status' && git worktree add loc`,
      local: `cmux vm exec cell-a -- sh -c 'git status' && git worktree add loc`,
      marker: "#1919",
      both: "block" },
    { id: "B9", guard: "remote heredoc + trailing LOCAL worktree add",
      remote: `cmux vm exec cell-a -- sh -s <<'EOS'\ngit status\nEOS\ngit worktree add after`,
      local: `cmux vm exec cell-a -- sh -s <<'EOS'\ngit status\nEOS\ngit worktree add after`,
      marker: "#1919",
      both: "block" },
  ];

  const blocked = (r) => !!r && r.block === true;
  const reasonOf = (r) => String(r?.reason ?? "");

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "remote-ctx-")));
  const hub = join(tmp, "hub");
  try {
    mkdirSync(hub, { recursive: true });
    gg("init -q -b main", hub);
    gg("config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "a.txt"), "v1\n");
    gg("add -A && git commit -qm init", hub);

    const home = join(tmp, "home");
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;
    process.env.SKILL_ENFORCER_DISABLED = "1";

    console.log("\n── Part B: real index.ts handler, hermetic hub ──");
    const real = await loadGuard(INDEX_TS, hub);
    expect("B0: index.ts loads with no degradation warning", real.degradation.length, 0);
    expectTrue("B0: factory registered a tool_call handler", real.loaded, "none");

    // B1-B6: remote ALLOWED / local REFUSED, on a CLEAN hub (the state #1919
    // refused from — it needs no disorder precondition).
    for (const p of PINNED.filter((x) => !x.both)) {
      const r = await real.bash(p.remote);
      expectTrue(`${p.id}: REMOTE form ALLOWED (${p.guard})`, !blocked(r), `blocked: ${reasonOf(r).split("\n")[0]}`);
      const l = await real.bash(p.local);
      expectTrue(`${p.id}: LOCAL twin still REFUSED (${p.guard})`, blocked(l), "allowed — the local guard was relaxed");
      expectTrue(`${p.id}: …by the guard that owns it (reason contains ${JSON.stringify(p.marker)})`,
        reasonOf(l).includes(p.marker), reasonOf(l).split("\n")[0]);
    }
    // B7-B9: the LOCAL text beside a remote payload is still gated, both on a
    // clean and (for the tracked-write arm) a disordered hub.
    for (const p of PINNED.filter((x) => x.both)) {
      const r = await real.bash(p.remote);
      expectTrue(`${p.id}: still REFUSED (${p.guard})`, blocked(r), "allowed — the mask swallowed local text");
      expectTrue(`${p.id}: …by the owning guard`, reasonOf(r).includes(p.marker), reasonOf(r).split("\n")[0]);
    }

    // B10: the SAME pins hold when the hub is DIRTY (M4 active) — a remote
    // command is not held hostage by local disorder either, and a local one is
    // still refused.
    writeFileSync(join(hub, "wip-untracked.txt"), "wip\n");
    for (const p of PINNED.filter((x) => ["B1", "B6"].includes(x.id))) {
      const r = await real.bash(p.remote);
      expectTrue(`${p.id}d: REMOTE form ALLOWED on a DIRTY hub`, !blocked(r), `blocked: ${reasonOf(r).split("\n")[0]}`);
      const l = await real.bash(p.local);
      expectTrue(`${p.id}d: LOCAL twin still REFUSED on a DIRTY hub`, blocked(l), "allowed");
    }
    rmSync(join(hub, "wip-untracked.txt"));

    // B11: the escape hatch still bypasses everything (unchanged semantics).
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    const hatched = await real.bash("git worktree add rev-hatched");
    delete process.env.AGENT_ALLOW_MAIN_EDITS;
    expectTrue("B11: AGENT_ALLOW_MAIN_EDITS=1 still bypasses (hatch intact)", !blocked(hatched), reasonOf(hatched).split("\n")[0]);

    // B12: the wrapper forms we do NOT model stay GATED — the fix is a boundary
    // recogniser, not a licence. `sudo cmux …` keeps the pre-fix (fail-closed)
    // behaviour: the git verb inside the payload is still refused.
    const residual = await real.bash(`sudo cmux vm exec cell-a -- sh -c 'git worktree add rev-inside'`);
    expectTrue("B12: a WRAPPED remote head (`sudo cmux …`) is not exempted (fail-closed residual)",
      blocked(residual), "allowed — the residual must not silently widen");

    // B13 (#3478 review P0): a LOCAL backtick substitution inside a remote
    // command RUNS HERE. It must still be refused — the pre-fix guard refused it
    // (measured), and a mask that keeps only the opening token turns it into an
    // allow.
    const b13 = await real.bash("cmux vm exec cell-a -- `git reset --hard`");
    expectTrue("B13: a local BACKTICK region inside a remote command is still REFUSED",
      blocked(b13), "allowed — a local substitution was masked away");

    // B14 (#3478 review P0): `ssh <host> > <file>` truncates a LOCAL file and
    // hands ssh no command. The redirect target must stay visible to the
    // tracked-write gate.
    const b14 = await real.bash("ssh cell-a > a.txt");
    expectTrue("B14: `ssh <host> > <tracked hub file>` is still REFUSED (a local write)",
      blocked(b14), "allowed — the redirect target was masked as remote payload");
    expectTrue("B14: …by the tracked-write gate", reasonOf(b14).includes("tracked file"), reasonOf(b14).split("\n")[0]);

    // B15 (#3478 review P1): a TRAILING separator must not throw. A thrown guard
    // aborts the whole bash call with an internal error instead of a message, so
    // assert the handler RESOLVES and the remote form is allowed.
    let b15threw = null;
    let b15 = null;
    try { b15 = await real.bash("cmux vm exec cell-a -- ls\n"); } catch (e) { b15threw = String(e && e.message); }
    expectTrue("B15: a trailing newline does not throw in the handler", b15threw === null, b15threw ?? "");
    expectTrue("B15: …and the remote command is ALLOWED", !blocked(b15), `blocked: ${reasonOf(b15).split("\n")[0]}`);

    // B16 (#3478 review cycle 2 P1): a payload piped into a LOCAL shell is
    // executed HERE (#709). The mask must not hide the seed from that arm.
    const b16 = await real.bash(`printf 'git checkout -- a.txt' | bash -s`);
    expectTrue("B16 control: a local `… | bash -s` payload is REFUSED", blocked(b16), "allowed — the control itself is broken");
    const b16r = await real.bash(`cmux vm exec cell-a -- printf 'git checkout -- a.txt' | bash -s`);
    expectTrue("B16: …and the SAME payload behind a remote exec is still REFUSED", blocked(b16r),
      "allowed — the local pipe into a shell was masked away");

    // B17 (#3478 review cycle 2 P0): a quote inside a `#` comment must not mask
    // the next LOCAL line.
    const b17 = await real.bash("cmux vm exec cell-a -- ls # it's fine\ngit reset --hard");
    expectTrue("B17: a COMMENT with a quote does not hide the next local line", blocked(b17),
      "allowed — the comment swallowed the newline and the local line with it");

    // B18 (#3478 review cycle 3 P0): the heredoc DELIMITER-LINE tail is LOCAL.
    // It used to be dropped from the gated string, so these went ALLOWED.
    const b18a = await real.bash("cmux vm exec cell-a -- sh -s <<'EOS'; git worktree add rev-9999\nbody\nEOS");
    expectTrue("B18: `… <<'EOS'; git worktree add loc` is REFUSED", blocked(b18a),
      "allowed — the delimiter-line tail was dropped from the gated string");
    expectTrue("B18: …by the #1919 arm", reasonOf(b18a).includes("#1919"), reasonOf(b18a).split("\n")[0]);
    const b18b = await real.bash("cmux vm exec cell-a -- sh -s <<'EOS' > a.txt\nbody\nEOS");
    expectTrue("B18: `… <<'EOS' > <tracked file>` is REFUSED (a local write)", blocked(b18b),
      "allowed — the local redirect target was dropped");
    const b18c = await real.bash("cmux vm exec cell-a -- sh -s <<'EOS'\nbody\nEOS");
    expectTrue("B18 control: a plain heredoc payload is ALLOWED", !blocked(b18c), `blocked: ${reasonOf(b18c).split("\n")[0]}`);

    // B19 (#3478 review cycle 3 P0): `|&` is a pipe — its target runs LOCALLY.
    const b19 = await real.bash(`cmux vm exec cell-a -- printf 'git checkout -- a.txt' |& bash -s`);
    expectTrue("B19: a `|&` payload into a local shell is REFUSED", blocked(b19),
      "allowed — the `|&` stage head was not recognised");

    // B21 (#3478 review cycle 4 P0): the piped-payload bail must be a CLOSED
    // allow-list — these stage heads run what they read, so the mask must not
    // hide the seed and the pre-fix #709 refusal must still stand.
    for (const c of [
      `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | > /tmp/f bash -s`,
      `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | timeout 5 bash -s`,
    ]) {
      const r = await real.bash(c);
      expectTrue(`B21: a stage that RUNS its stdin is still REFUSED — ${JSON.stringify(c)}`,
        blocked(r), `allowed: ${reasonOf(r).split("\n")[0]}`);
    }
    // ⛔ NOT pinned here, and deliberately (measured, not assumed): a stage head the
    // guard's OWN #709 arm cannot recognise either (`| { S=bash; $S -s; }`, a
    // variable indirection) is allowed — and it was allowed before this PR too, on
    // the raw command. The mask now leaves such a command UNMASKED (verified at the
    // mask level, A27), so this PR neither creates nor fixes that gap; asserting a
    // refusal here would be asserting behaviour the guard never had.
    //
    // The same honesty applies to a `\`+newline CONTINUATION on a heredoc's
    // DELIMITER line: the guard's own heredoc parser reads that tail as body, so the
    // form was never refused at origin/main either (measured on both heads). The
    // MASK keeps the local tail visible (A25) and, for a QUOTED delimiter, resolves
    // the terminator correctly (A26) — which is what keeps the latter's #1919
    // refusal intact, as it already was at origin/main.

    // B24 (#3478 review cycle 4): a data-consumer stage still allows the mask, so a
    // legitimate piped remote command stays ALLOWED.
    const b24 = await real.bash("cmux vm exec cell-a -- printf 'x' | grep y");
    expectTrue("B24 control: a data-consumer pipe is ALLOWED", !blocked(b24), `blocked: ${reasonOf(b24).split("\n")[0]}`);

    // B20 (#3478 review cycle 3 P2): a value flag with an ATTACHED value
    // (`-p22`, `-L8080:host:80`, `-oK=V`) must not swallow the host.
    const b20 = await real.bash("ssh -p22 cell-a 'git worktree add rev-9999'");
    expectTrue("B20: `ssh -p22 <host> '<payload>'` is ALLOWED (boundary recognised)", !blocked(b20),
      `blocked: ${reasonOf(b20).split("\n")[0]}`);
    const b20h = await real.bash("ssh -p22 cell-a <<'EOS'\ngit worktree add rev-9999\nEOS");
    expectTrue("B20b: a heredoc payload after an attached-value flag is ALLOWED", !blocked(b20h),
      `blocked: ${reasonOf(b20h).split("\n")[0]}`);

    // ── Part C — mutation evidence ──────────────────────────────────────
    if (process.argv.includes("--mutations")) {
      console.log("\n── Part M: mutation evidence (#3444) ──");

      /** Copy this extension (plus the two shared modules index.ts imports) into
       *  a temp tree and apply ONE textual revert to classify-git.mjs. */
      function buildMutant(label, revert) {
        const root = realpathSync(mkdtempSync(join(tmpdir(), `remote-ctx-mut-${label}-`)));
        const ext = join(root, "extensions");
        mkdirSync(join(ext, "main-worktree-guard"), { recursive: true });
        mkdirSync(join(ext, "shared"), { recursive: true });
        for (const f of ["index.ts", "classify-git.mjs", "module-load-hooks.mjs"]) {
          cpSync(join(HERE, f), join(ext, "main-worktree-guard", f));
        }
        for (const f of ["print-mode.ts", "audit-log.ts", "tool-call-event.ts", "branch-ownership.mjs"]) {
          cpSync(join(REPO_EXTENSIONS, "shared", f), join(ext, "shared", f));
        }
        const cgPath = join(ext, "main-worktree-guard", "classify-git.mjs");
        const src = readFileSync(cgPath, "utf8");
        const mutated = revert(src);
        const applied = mutated !== src;
        writeFileSync(cgPath, mutated);
        return { root, index: join(ext, "main-worktree-guard", "index.ts"), applied };
      }

      const MUTANTS = [
        {
          // The pre-fix behaviour: no boundary is recognised at all. Every
          // REMOTE-ALLOWED assertion must go RED (the command is refused again).
          label: "pre-fix (no remote boundary)",
          revert: (src) => src.replace(
            "export function maskRemoteExecPayloads(command) {",
            "export function maskRemoteExecPayloads(command) {\n  return String(command ?? \"\"); // MUTANT: pre-fix identity",
          ),
          // ⛔ `preFixDiscriminating: false` on a pin is a CLAIM WITH A REASON, never a waiver:
          // it says this pin's answer cannot change when the mask is reverted (see B4), so
          // holding it here would assert evidence the mutant never produced. A pin may opt out
          // ONLY for that structural reason, and the opt-out is ASSERTED rather than trusted: the
          // `optOutInvariant` leg below re-runs every opted-out pin under this mutant and fails if
          // its answer changed. `M0` still proves every pin GREEN on the unmutated module, so an
          // exempted pin remains a live assertion (#3774).
          optOutInvariant: true,
          expectRed: PINNED.filter((x) => !x.both && x.preFixDiscriminating !== false).map((x) => x.id),
          check: (r) => blocked(r),                  // RED means "refused again"
          probe: (p) => p.remote,
        },
        {
          // The OVER-REACH direction: the mask ignores the top-level separators,
          // so a LOCAL trailing segment is swallowed as if it were remote. The
          // safety assertions (B8/B9) must go RED (the local command is allowed).
          label: "over-reach (mask across separators)",
          revert: (src) => src.replace(
            "      if (_RB_SEPARATORS.has(tk.text)) {\n        // The remote command ENDS here: everything after it can run LOCALLY.",
            "      if (false) {\n        // MUTANT: over-reach — the boundary never ends",
          ),
          expectRed: ["B8", "B9"],
          check: (r) => !blocked(r),                  // RED means "allowed although local"
          probe: (p) => p.remote,
        },
        {
          // The structural fail-open measured while writing the fix: masking the
          // heredoc TERMINATOR fuses it onto the delimiter word, so the next
          // local command is read as heredoc DATA by every downstream parser.
          // B9 must go RED.
          label: "heredoc terminator swallowed",
          revert: (src) => src.replace(
            "        if (body.afterTerm > last) { out += s.slice(body.termStart, body.afterTerm); last = body.afterTerm; }",
            "        // MUTANT: terminator swallowed with the body",
          ),
          expectRed: ["B9"],
          check: (r) => !blocked(r),
          probe: (p) => p.remote,
        },
        {
          // #3478 review P0: the unquoted-backtick region is one LOCAL token. The
          // revert keeps only the opening token (the shipped defect), so the pin
          // that requires the region to survive must go RED. Asserted at the MASK
          // level, because that is the unit the revert changes.
          // ⚠️ This is the AGGREGATE "cycle-1 world" revert: the region is defended
          // twice now (region-keeping AND the local-substitution bail), so both are
          // removed here. The bail's OWN discriminator is the dedicated
          // `local substitution masked with its spawner` mutant below.
          label: "unquoted backtick region split",
          kind: "mask",
          revert: (src) => src
            .split("i = _rbBacktickRegionEnd(s, i)").join("i = i + 1")
            .replace("  if (out !== s && _rbSubstFeedsShell(out)) return s;", "  // MUTANT: no substitution bail")
            .replace("  if (localSubstMasked) return s;", "  // MUTANT: no local-substitution bail"),
          maskProbe: "cmux vm exec cell-a -- `git reset --hard`",
          check: (out) => !String(out).includes("git reset --hard"),
        },
        {
          // #3478 review cycle 2 P0: a `#` comment is discarded by the shell, so
          // its text must not be quote-scanned. TWO protections implement that (the
          // comment branch, and the unterminated-quote bail that catches a stray
          // quote), so the mutant removes BOTH — the reverted world is the one that
          // shipped in cycle 1, where the quote inside the comment swallowed the
          // newline. A16 (mask) and B17 (handler) must go RED.
          label: "comment text quote-scanned",
          kind: "mask",
          revert: (src) => src
            .replace("    if (ch === \"#\") {", "    if (false) {")
            .replace("  if (unterminated) return s;", "  // MUTANT: no unterminated bail"),
          maskProbe: "cmux vm exec cell-a -- ls # it's fine\ngit reset --hard",
          check: (out) => !String(out).includes("git reset --hard"),
        },
        {
          // #3478 review cycle 2 P0: `$'…'` is ANSI-C quoting, where `\'` is an
          // ESCAPE. Without that mode the region closes early and re-opens, eating
          // the newline. TWO protections cover it (the mode, and the
          // unterminated-quote bail that catches the odd-quote fall-out), so the
          // mutant removes both — the reverted world is what shipped in cycle 1.
          // A17 must go RED.
          label: "ANSI-C quote read as plain quote",
          kind: "mask",
          revert: (src) => src
            .replace(
              "      if (c === \"$\" && s[i + 1] === \"'\") { quote = \"$'\"; text += \"$'\"; i += 2; continue; }",
              "      // MUTANT: no ANSI-C mode",
            )
            .replace("  if (unterminated) return s;", "  // MUTANT: no unterminated bail"),
          maskProbe: "cmux vm exec cell-a -- echo $'don\\'t'\ngit reset --hard",
          check: (out) => !String(out).includes("git reset --hard"),
        },
        {
          // #3478 review cycle 2 P1: a payload piped INTO a local shell is executed
          // here (#709). Without the bail the seed is masked and the arm is blind —
          // A18 and B16 must go RED.
          label: "piped payload masked (local shell blinded)",
          kind: "mask",
          revert: (src) => src.replace(
            "  if (out !== s && _rbFeedsLocalShell(out)) return s;",
            "  // MUTANT: no local-shell pipe bail",
          ),
          maskProbe: `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | bash -s`,
          check: (out) => !String(out).includes("git checkout"),
        },
        {
          // #3478 review cycle 3 P0: the rest of the heredoc DELIMITER LINE is
          // LOCAL text and used to be dropped from the gated string. Reverting the
          // tail emit makes A21 and B18 go RED.
          label: "heredoc delimiter-line tail dropped",
          kind: "mask",
          revert: (src) => src.replace(
            "        if (nlAt > last) { out += s.slice(last, nlAt); last = nlAt; }   // delimiter-line tail: LOCAL",
            "        // MUTANT: delimiter-line tail dropped",
          ),
          maskProbe: "cmux vm exec cell-a -- sh -s <<'EOS'; git worktree add rev-9999\nbody\nEOS",
          check: (out) => !String(out).includes("git worktree add rev-9999"),
        },
        {
          // #3478 review cycles 3-4 P0: `_rbFeedsLocalShell` must BAIL (not mask)
          // unless the downstream stage is a proven data consumer. Reverting it to
          // the shell allow-list makes A22/B21 and B19 go RED.
          label: "pipe head allow-list (shells only)",
          kind: "mask",
          revert: (src) => src.replace(
            "      if (!_rbIsDataConsumer(head)) return true;",
            "      if (!/^(?:ba|z|k|da|a)?sh$|^(?:python[0-9.]*|perl|ruby|node|awk|tclsh|lua)$/.test(head)) continue;",
          ),
          maskProbe: `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | timeout 5 bash -s`,
          check: (out) => !String(out).includes("git checkout"),
        },
        {
          // #3478 review cycle 4 P0: the body starts after the LOGICAL line; a
          // `\`+newline continuation joins it. Reverting to the first PHYSICAL
          // newline drops the joined remainder — A25 goes RED.
          label: "heredoc body cut at physical newline",
          kind: "mask",
          revert: (src) => src.replace(
            "            if (depth === 0) { nlAt = t.start; break; }",
            "            if (depth >= 0) { nlAt = s.indexOf(\"\\n\", tk.end); break; }",
          ),
          maskProbe: "cmux vm exec c -- sh -s <<'EOS'; \\\ngit worktree add loc\nbody\nEOS",
          check: (out) => !String(out).includes("git worktree add loc"),
        },
        {
          // #3478 review cycle 4 P0: the delimiter word needs SHELL QUOTE REMOVAL.
          // Reverting to `slice(1, -1)` keeps the quotes of `$'EOS'`, no terminator
          // matches, and the mask runs past the real one — A26 goes RED.
          label: "delimiter word not unquoted",
          kind: "mask",
          revert: (src) => src.replace(
            "        const delim = _rbUnquoteDelim(tk.text);",
            "        const delim = String(tk.text ?? \"\").trim().replace(/^'|'$/g, \"\");  // MUTANT: quote-pair slice only",
          ),
          maskProbe: "cmux vm exec c -- sh -s <<$'EOS'\nbody\nEOS\ngit worktree add loc",
          check: (out) => !String(out).includes("git worktree add loc"),
        },
        {
          // #3478 review cycle 4 P0: the pipe bail must skip a redirection's TARGET
          // word (`| > /tmp/f bash -s`). Without that skip the head resolves to
          // `/tmp/f`, `bash` is never examined, and the payload is masked.
          label: "pipe redirect target not skipped",
          kind: "mask",
          revert: (src) => src.replace(
            "          const takesNext = !/^\\d*(?:>&|<&)\\d+$/.test(w) && !/^\\d*>>?\\S/.test(w);\n          j += takesNext ? 2 : 1;",
            "          j += 1;  // MUTANT: target word not skipped",
          ),
          // The probe's redirect TARGET is deliberately a name that LOOKS like a
          // data consumer (`/tmp/grep`): with the target skipped the real head is
          // `bash` (bail); without the skip the head IS `/tmp/grep` (masked).
          maskProbe: `cmux vm exec cell-a -- printf 'git checkout -- a.txt' | > /tmp/grep bash -s`,
          check: (out) => !String(out).includes("git checkout"),
        },
        {
          // #3478 review cycle 5 P0: an ARRAY-LITERAL element is not command
          // position. Reverting the `(`-after-`name=` check masks `arr=(ssh cell 'x')`
          // — A33 goes RED.
          label: "array literal treated as command position",
          kind: "mask",
          revert: (src) => src.replace(
            "    if (prev && prev.op && prev.text === \"(\") {",
            "    if (false) {",
          ),
          maskProbe: `arr=(ssh cell 'x')`,
          check: (out) => String(out) !== `arr=(ssh cell 'x')`,
        },
        {
          // #3478 review cycle 5 P0: an undecodable ANSI-C escape must BAIL, not
          // produce a wrong word. Reverting to "take the escape char literally"
          // makes the delimiter wrong and the mask run past the real terminator —
          // A29 goes RED.
          label: "undecodable ANSI-C escape taken literally",
          kind: "mask",
          revert: (src) => src.replace(
            "          if (/[0-7xuUcE]/.test(nx)) return null;",
            "          // MUTANT: undecodable escape taken literally",
          ),
          maskProbe: `cmux vm exec c -- sh -s <<$'E\\101OS'\nbody\nEAOS\ngit worktree add octal`,
          check: (out) => !String(out).includes("git worktree add octal"),
        },
        {
          // #3478 review cycle 5 P0: a CR after the delimiter word means the WORD
          // carries the CR. Without the bail the computed word never matches and the
          // mask eats every local command after the terminator — A30 goes RED.
          label: "CRLF delimiter word trimmed",
          kind: "mask",
          revert: (src) => src.replace(
            "        if (s[tk.end] === \"\\r\") return s;",
            "        // MUTANT: CR-trimmed delimiter word accepted",
          ),
          maskProbe: "cmux vm exec c -- sh -s <<'EOS'\r\nbody\r\nEOS\r\ngit worktree add crlf",
          check: (out) => !String(out).includes("git worktree add crlf"),
        },
        {
          // #3478 review cycle 5 P0: only a DEPTH-0 newline ends the delimiter line.
          // Reverting the paren depth takes the newline inside `$( … )` as the body
          // start and drops the substitution's local remainder — A31 goes RED.
          label: "paren depth ignored for heredoc newline",
          kind: "mask",
          revert: (src) => src.replace(
            "            if (depth === 0) { nlAt = t.start; break; }",
            "            { nlAt = t.start; break; }",
          ),
          maskProbe: "cmux vm exec c -- sh -s <<'EOS' $(true\n) ; git worktree add NL1\nbody\nEOS",
          check: (out) => !String(out).includes("git worktree add NL1"),
        },
        {
          // #3478 review cycle 5 P0: a process substitution runs the payload HERE.
          // Without the bail `bash <(cmux vm exec …)` masks it — A32 goes RED.
          label: "process substitution not bailed",
          kind: "mask",
          revert: (src) => src.replace(
            "  if (out !== s && /[<>]\\(/.test(out)) return s;",
            "  // MUTANT: no process-substitution bail",
          ),
          maskProbe: `bash <(cmux vm exec c -- printf 'git checkout -- a.txt')`,
          check: (out) => !String(out).includes("git checkout"),
        },
        {
          // #3478 review cycle 6 P0: a substitution that feeds a LOCAL command runs
          // the remote stdout HERE. Without the bail it is masked — A34 goes RED.
          label: "substitution feeding a local command not bailed",
          kind: "mask",
          revert: (src) => src.replace(
            "  if (out !== s && _rbSubstFeedsShell(out)) return s;",
            "  // MUTANT: no substitution bail",
          ),
          maskProbe: `bash -c $(cmux vm exec cell-a -- sh -c 'git worktree add rev-9')`,
          check: (out) => !String(out).includes("git worktree add rev-9"),
        },
        {
          // #3478 review cycle 6 P2: `\`+newline inside a delimiter word is DELETED by
          // bash. Emitting a newline computes a word the shell never uses, so the
          // terminator never matches and the mask eats everything after — A35 RED.
          label: "delimiter continuation kept as newline",
          kind: "mask",
          revert: (src) => src
            .split('if (t[i + 1] === "\\n") { i += 2; continue; }')
            .join("/* MUTANT: continuation kept as newline */"),
          maskProbe: "cmux vm exec cell-a -- sh -s <<EO\\\nS\n:\nEOS\ngit worktree add cont1\n",
          check: (out) => !String(out).includes("git worktree add cont1"),
        },
        {
          // #3478 review cycle 7 P1: a local substitution INSIDE the masked run loses
          // the `sh -c` SPAWNER wrapper #1919 walks, so the whole command must be left
          // unmasked. This is the DEDICATED discriminator for that bail (pins A36/A36b):
          // with it removed the spawner wrapper is masked away again.
          label: "local substitution masked with its spawner",
          kind: "mask",
          revert: (src) => src.replace(
            "  if (localSubstMasked) return s;",
            "  // MUTANT: no local-substitution bail",
          ),
          maskProbe: `cmux vm exec cell-a -- sh -c "echo $(git worktree add loc)"`,
          // RED means: the mask HID the `sh -c` spawner wrapper that #1919 walks.
          check: (out) => !String(out).includes("sh -c"),
        },
        {
          // #3478 review cycle 8 P1: `&` must split only as a JOB separator, never
          // as part of a redirection (`2>&1`). Splitting on the redirection `&` cut
          // the segment between the payload and its pipe, so `… 2>&1 | bash -s` was
          // masked again — A37 goes RED.
          label: "redirection & treated as a job separator",
          kind: "mask",
          revert: (src) => src.replace(
            "  for (const cmd of cmdText.split(/;|&&|\\|\\||\\n|(?<![<>])&(?!>)/)) {",
            "  for (const cmd of cmdText.split(/;|&&|\\|\\||\\n|&/)) {",
          ),
          maskProbe: `cmux vm exec cell-a -- printf 'git reset --hard' 2>&1 | bash -s`,
          check: (out) => !String(out).includes("git reset --hard"),
        },
      ];

      // ⛔ THE EXEMPTION MECHANISM'S OWN ENABLEMENT IS ASSERTED (#3774 review, P2-1). The
      // `optOutInvariant` leg below is the ONLY thing that turns a `preFixDiscriminating: false`
      // declaration into evidence, and ONE line on ONE mutant enables it. Measured: deleting
      // `optOutInvariant: true` from the pre-fix mutant left this suite at 341 passed / 0 failed,
      // exit 0 — the leg vanished and nothing named it, so the flag could hollow out the mutation
      // evidence with no red anywhere. These rows redden on that deletion, and on an EMPTIED
      // opt-out set (a mechanism with no exempted pin asserts nothing either).
      // ⛔ AND THE FLAG IS BOUND TO THE MUTANT WHOSE FILTER IT PROTECTS (#3774 review round 2, P2).
      // A COUNT is not a binding: measured, MOVING `optOutInvariant: true` one mutant down (onto
      // "over-reach") left the suite at 345 passed / 0 failed, exit 0, while B4 stayed filtered
      // out of the PRE-FIX mutant's `expectRed` — so the pin was re-checked only under a mutant it
      // is trivially invariant under, never under the one the exemption claims it cannot
      // discriminate. The row named "so the exemption leg RUNS" printed ✅ over exactly that hole.
      const PRE_FIX_LABEL = "pre-fix (no remote boundary)";
      const optOutMutants = MUTANTS.filter((m) => m.optOutInvariant === true);
      const optedOut = PINNED.filter((x) => x.preFixDiscriminating === false);
      expectTrue("M: exactly one mutant declares optOutInvariant, AND it is the pre-fix mutant whose expectRed the exemption filters",
        optOutMutants.length === 1 && optOutMutants[0].label === PRE_FIX_LABEL,
        `${optOutMutants.length} mutant(s) declare it (${optOutMutants.map((m) => m.label).join("; ") || "none"}) — anywhere else, the pre-fix exemption is verified NOWHERE`);
      expectTrue("M: at least one pin is exempted, so the optOutInvariant leg asserts a real claim",
        optedOut.length > 0,
        "no pin carries `preFixDiscriminating: false` — the leg would assert nothing");
      for (const m of optOutMutants) {
        expectTrue(`M: the ${m.label} mutant does NOT hold its exempted pins in expectRed`,
          optedOut.every((p) => !m.expectRed.includes(p.id)),
          `expectRed still holds ${optedOut.map((p) => p.id).join(", ")} — the exemption would be graded twice, against evidence the mutant never produced`);
      }

      // The pins must be LIVE on the unmutated module first — a mutation whose
      // pin was already red proves nothing. `both:"block"` pins are GREEN only
      // when the command is REFUSED.
      for (const p of PINNED) {
        const r = await real.bash(p.remote);
        const green = p.both === "block" ? blocked(r) : !blocked(r);
        expectTrue(`M0: the pin ${p.id} is GREEN on the unmutated module`, green,
          `unexpectedly ${blocked(r) ? "BLOCKED" : "allowed"}: ${reasonOf(r).split("\n")[0]}`);
      }

      // Execution FLOOR for the invariance leg: a DECLARED flag is satisfied by a neutralised
      // consumer. Measured: turning the `if (mut.optOutInvariant) {` gate below into `if (false) {`
      // gives 344 passed / 0 failed, exit 0 — every row above still passes, the leg is simply gone.
      // The count below is the difference between "the flag exists" and "the assertion ran".
      let optOutLegRan = 0;

      for (const mut of MUTANTS) {
        const built = buildMutant(mut.label.replace(/[^a-z0-9]+/gi, "-"), mut.revert);
        expectTrue(`M: the ${mut.label} defect was actually reintroduced (anchor applied)`, built.applied,
          "textual revert did not apply — a stale anchor proves nothing");
        try {
          if (mut.kind === "mask") {
            // MASK-level mutant: import the MUTATED classifier directly and show
            // the pin's own predicate flips.
            const mutated = await import(pathToFileURL(join(built.root, "extensions", "main-worktree-guard", "classify-git.mjs")).href);
            const out = mutated.maskRemoteExecPayloads(mut.maskProbe);
            expectTrue(`M: under ${mut.label}, the pin goes RED (so the pin CAN fail)`, mut.check(out), `masked to ${JSON.stringify(out)}`);
            // …and the UNMUTATED module must satisfy it, or the pin asserts nothing.
            const realOut = mask(mut.maskProbe);
            expectTrue(`M0: the mask pin is GREEN on the unmutated module (${mut.label})`, !mut.check(realOut), JSON.stringify(realOut));
            continue;
          }
          const g = await loadGuard(built.index, hub);
          expect("M: the mutant copy loads without a degradation warning", g.degradation.length, 0);
          for (const id of mut.expectRed) {
            const p = PINNED.find((x) => x.id === id);
            const r = await g.bash(mut.probe(p));
            expectTrue(`M: under ${mut.label}, pin ${id} goes RED (so the pin CAN fail)`,
              mut.check(r), `still ${blocked(r) ? "BLOCKED" : "allowed"} — this pin is not discriminating`);
          }
          // ⛔ AN OPT-OUT IS EVIDENCE, NOT A WAIVER (#3774 review, P2). `preFixDiscriminating: false`
          // is only legitimate when the pin's answer CANNOT change under this mutant, so ASSERT the
          // invariance instead of trusting the declaration. Measured without this leg: adding the
          // flag to B1 — a pin that demonstrably DOES flip — deleted B1's discrimination assertion
          // silently, with ZERO failures and one assertion simply gone. The flag could therefore be
          // used to hollow out the
          // mutation evidence with no red anywhere.
          if (mut.optOutInvariant) {
            for (const p of PINNED.filter((x) => x.preFixDiscriminating === false)) {
              const underMutant = await g.bash(mut.probe(p));
              const live = await real.bash(mut.probe(p));
              optOutLegRan++;
              expectTrue(`M: ${p.id} is exempted as non-discriminating, and it IS invariant under ${mut.label}`,
                blocked(underMutant) === blocked(live),
                `it FLIPPED (pre-fix ${blocked(underMutant) ? "BLOCKED" : "allowed"}, live ${blocked(live) ? "BLOCKED" : "allowed"}) — this pin IS discriminating and must not be exempted`);
            }
          }
        } finally {
          rmSync(built.root, { recursive: true, force: true });
        }
      }
      expectTrue("M: the opt-out invariance leg RE-RAN every exempted pin (an executed floor, not a declared flag)",
        optOutLegRan === optedOut.length && optOutLegRan > 0,
        `the leg re-ran ${optOutLegRan} of ${optedOut.length} exempted pin(s) — a neutralised consumer leaves every row above green`);
    }
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(tmp, { recursive: true, force: true });
  }
}

// agent-infra#2723 — emit through the shared emitter so the failing arm always
// carries the `runner::test-remote-context` identity the merge rail reads.
reportVerdict("test-remote-context", pass, fail, { skip });
process.exit(fail === 0 ? 0 : 1);
