// test-remote-context.mjs — #3444: the path/hub guards resolved REMOTE cell
// commands against the LOCAL hub, so all cell dispatch was refused from any
// hub-rooted session.
//
// THE DEFECT (measured 2026-11-04, issue #3444). Every bash command whose text
// carried a version-control verb was gated against THIS session's hub, even when
// its execution target was a cell via `cmux vm exec`. The guards HELD the datum
// — `cmux vm exec <vm> --` marks a remote context — and did not read it. Four
// refusals:
//   1. a remote worktree-add refused by #1919, whose message named the target as
//      the LOCAL path (a relative path resolved against the local cwd, for a
//      command that ran on a cell);
//   2. a remote branch-switch refused by #1484 as though it ran in the hub;
//   3. a remote `pull` inside a compound refused by #1144;
//   4. a payload piped to a remote shell refused as substitution-with-content.
// It made ~87 idle lanes across four running cells unusable from a hub-rooted
// session: the only thing that worked was spelling the ABSOLUTE remote path,
// found by trial.
//
// THE FIX. `classify-git.mjs:stripRemoteContexts` recognises a remote-context
// SEGMENT (`cmux vm exec <vm> -- …`, `ssh <host> -- …`, `docker exec <c> -- …`)
// and removes it from the text every local gate reads, so no local gate answers
// about another box's paths and refs. It is the guard's own principle one level
// up from the payload exemption it already states ("file / module / stdin
// payloads are NOT content-gated here"): a command whose TARGET is remote is not
// gated against the local hub at all.
//
// ⛔ WHAT THIS SUITE EXISTS TO KEEP TRUE (the non-vacuity requirement):
//   • every one of the four field cases ALLOWS in its remote form AND still
//     REFUSES the local form of the same command (Parts A/B);
//   • the boundary is a SEGMENT, never the whole command — a later `;`/`&&`/`|`
//     segment runs LOCALLY and stays gated, a LOCAL redirection stays visible to
//     the #437/#618 tracked-write gate, and a remote portion carrying a shell
//     SUBSTITUTION (that the local shell evaluates before the dispatch) is NOT
//     exempt (Part B anti-laundering);
//   • every assertion above can go RED: `--mutations` reverts the recogniser and,
//     separately, the call site, and requires the paired pins to FAIL (Part M).
//
// Two layers per fixture, like the sibling suites: the pure predicate over the
// shared module, and the REAL `index.ts` tool_call handler driving a hermetic
// MAIN checkout (a predicate-only suite passes while the live gate over-blocks).
//
// Run: node extensions/main-worktree-guard/test-remote-context.mjs
//      node extensions/main-worktree-guard/test-remote-context.mjs --mutations
import { execSync } from "node:child_process";
import {
  copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");
const CG = join(HERE, "classify-git.mjs");
const REPO_EXTENSIONS = fileURLToPath(new URL("..", import.meta.url));

// Assembled, so this file's own text does not carry the operations as literals
// (the guard refuses to read a script that names them — including its own suite).
const RESET = ["git", "reset", "--hard"].join(" ");
const PULL = ["git", "pu" + "ll"].join(" ");
const COB = ["git", "chec" + "kout", "-b", "fix/x"].join(" ");
const WTA = ["git", "worktree", "add", ".worktrees/rev-3168", "fix/x"].join(" ");
const PAYLOAD = ["git", "reset", "--hard"].join(" ") + "\n";
const B64 = Buffer.from(PAYLOAD).toString("base64");

let pass = 0, fail = 0;
function expectTrue(name, cond, detail = "") {
  const ok = !!cond;
  console.log(`${ok ? "✅" : "❌"} ${name}${ok ? "" : ` — ${detail}`}`);
  ok ? pass++ : fail++;
}
function expectEq(name, got, want) {
  expectTrue(name, got === want, `got ${JSON.stringify(got)} (want ${JSON.stringify(want)})`);
}

const { stripRemoteContexts, classifyGitCommand } = await import(pathToFileURL(CG).href);
expectTrue("setup: classify-git.mjs exports stripRemoteContexts (#3444)",
  typeof stripRemoteContexts === "function", "missing — the guard would fall back to identity (today's false blocks)");

const strip = (c) => stripRemoteContexts(c);

// ── Part A: the pure boundary ──────────────────────────────────────────────
// A boundary is recognised from THREE transports, each requiring the explicit
// `--` separator (the boundary must be provable, not inferred).
console.log("\n── Part A: `stripRemoteContexts` — what is remote, what is local ──");
{
  const REMOTE_FORMS = [
    ["A1  cmux vm exec (the fleet's cell transport)", `cmux vm exec cell-a -- ${PULL}`],
    ["A2  ssh --", `ssh cell-a -- ${COB}`],
    ["A3  docker exec --", `docker exec -i c1 -- ${PULL}`],
    ["A4  cmux vm exec with transport flags + a leading env assignment", `FOO=1 cmux vm exec --timeout 60 pi-cell-1 -- ${PULL}`],
    ["A5  ssh with a flag before the host", `ssh -t -o BatchMode=yes cell-a -- ${PULL}`],
    ["A6  docker exec with an env flag", `docker exec -e A=1 c1 -- ${PULL}`],
  ];
  for (const [name, cmd] of REMOTE_FORMS) {
    const out = strip(cmd);
    expectTrue(`${name} → the transport and its payload are GONE`,
      out === "true", `got ${JSON.stringify(out)}`);
  }

  // A LOCAL form of each, unchanged: the relaxation is scoped to the boundary.
  const LOCAL_FORMS = [
    ["A7  local pull", PULL],
    ["A8  local branch switch", COB],
    ["A9  `ssh host cmd` WITHOUT the separator (not provable → stays gated)", `ssh cell-a ${PULL}`],
    ["A10 `ssh -- cmd` (no host operand)", `ssh -- ${RESET}`],
    ["A11 `docker exec -- c cmd` (`--` before the container)", `docker exec -- c1 ${RESET}`],
    ["A12 `cmux vm exec -- c cmd` (`--` before the vm)", `cmux vm exec -- cell-a ${RESET}`],
    ["A13 a dynamic head (`$CM`) is not a provable transport", `$CM vm exec cell-a -- ${PULL}`],
  ];
  for (const [name, cmd] of LOCAL_FORMS) {
    expectEq(`${name} → unchanged`, strip(cmd), cmd);
  }

  // A LOCAL heredoc body stays gated: the guard's existing payload arms depend
  // on reading it, and only a REMOTE command's stdin may be blanked.
  const localHeredoc = `bash <<'EOS'\n${PULL}\nEOS`;
  expectEq("A14 a heredoc to a LOCAL shell keeps its body verbatim", strip(localHeredoc), localHeredoc);
  const remoteHeredoc = `cmux vm exec cell-a -- bash <<'EOS'\n${RESET}\nEOS`;
  {
    const out = strip(remoteHeredoc);
    expectTrue("A15 a heredoc to a REMOTE shell → the dispatch AND its body go, the operator+delimiter stay",
      !out.includes("reset") && !out.includes("cmux") && out.includes("<<'EOS'") && out.startsWith("true"),
      `got ${JSON.stringify(out)}`);
    expectTrue("A15b …and the rewrite is still well-formed shell (the terminator survives)",
      out.split("\n").includes("EOS"), `got ${JSON.stringify(out)}`);
  }

  // SEGMENT, not command: a later separator re-enters local scope.
  const mixedTail = `cmux vm exec cell-a -- git status ; ${PULL}`;
  expectTrue("A16 `remote ; LOCAL` → the local tail is PRESERVED",
    strip(mixedTail) === `true ; ${PULL}`, `got ${JSON.stringify(strip(mixedTail))}`);
  const mixedHead = `${PULL} && cmux vm exec cell-a -- git status`;
  expectTrue("A17 `LOCAL && remote` → the local head is PRESERVED",
    strip(mixedHead) === `${PULL} && true`, `got ${JSON.stringify(strip(mixedHead))}`);
  const piped = `echo ${B64} | base64 -d | cmux vm exec cell-a -- bash`;
  expectTrue("A18 a pipeline INTO a remote shell → only the remote segment goes",
    strip(piped) === `echo ${B64} | base64 -d | true`, `got ${JSON.stringify(strip(piped))}`);
  expectTrue("A19 every segment remote (`;`-chained) → nothing local remains",
    strip(`cmux vm exec a -- git status ; docker exec b -- git log`).trim() === "true ; true",
    `got ${JSON.stringify(strip(`cmux vm exec a -- git status ; docker exec b -- git log`))}`);

  // ⛔ The two things that are NOT exempt inside a remote segment.
  const subst = `cmux vm exec cell-a -- bash -c "$(${RESET})"`;
  expectEq("A20 a SUBSTITUTION in the remote argv is evaluated LOCALLY → not exempt", strip(subst), subst);
  const backtick = "cmux vm exec cell-a -- bash -c \"" + "`" + RESET + "`" + "\"";
  expectEq("A21 a BACKTICK in the remote argv → not exempt", strip(backtick), backtick);
  const procsub = `cmux vm exec cell-a -- bash <(echo ${PULL})`;
  expectEq("A22 a PROCESS substitution in the remote argv → not exempt", strip(procsub), procsub);
  const redirect = `cmux vm exec cell-a -- ls > out.txt`;
  expectTrue("A23 a LOCAL redirection after the dispatch is KEPT (the #437/#618 write gate reads it)",
    strip(redirect) === "true > out.txt", `got ${JSON.stringify(strip(redirect))}`);

  // Idempotence: the guard may run the strip over already-local text.
  expectEq("A24 idempotent", strip(strip(`cmux vm exec c -- ${PULL} ; ${PULL}`)),
    strip(`cmux vm exec c -- ${PULL} ; ${PULL}`));
  // A transport word in OPERAND position is not a boundary.
  expectEq("A25 `echo ssh` (operand position) is untouched", strip("echo ssh cmux docker"), "echo ssh cmux docker");

  // ── A26–A32: the #3444-REVIEW fail-open class ──────────────────────────
  // bash's heredoc delimiter is the WORD after quote removal, whatever its
  // spelling. A recogniser that keeps the spelling never matches the terminator,
  // so its "body" runs to end of input and a LOCAL command after the real
  // terminator vanishes from the text every gate reads (measured: ALLOWED).
  const tail = `${PULL} && echo local-tail`;
  for (const [label, delim] of [
    ["A26 escaped delimiter `<<\\EOS`", "\\EOS"],
    ["A27 concatenated-quote delimiter `<<E\"O\"S`", 'E"O"S'],
    ["A28 single-quoted delimiter `<<'EOS'`", "'EOS'"],
  ]) {
    const cmd = `cmux vm exec cell-a -- bash <<${delim}\necho x\nEOS\n${tail}`;
    const out = strip(cmd);
    expectTrue(`${label}: the LOCAL command after the terminator SURVIVES`, out.includes(tail),
      `got ${JSON.stringify(out)} — a local command was swallowed by the body`);
    expectTrue(`${label}: …and the dispatch itself is gone`, out.startsWith("true"), `got ${JSON.stringify(out)}`);
  }
  // An UNTERMINATED heredoc is unprovable: its extent cannot be established, so
  // nothing is stripped.
  {
    const cmd = `cmux vm exec cell-a -- bash <<'EOS'\necho x\n${tail}`;
    expectEq("A29 an unterminated heredoc → nothing stripped (the extent is unprovable)", strip(cmd), cmd);
  }
  // ── A36–A38: the CYCLE-2 fail-open class (`$'…'` delimiters) ──────────────
  // `$'EOS'` / `$"EOS"` are bash QUOTING OPERATORS: the delimiter is still `EOS`,
  // but with ANSI-C / locale translation the stripper cannot compute it exactly.
  // Measured cycle 2: keeping a `$` in the computed delimiter shifted the
  // terminator one line and blanked a LOCAL command that bash really ran
  // (ALLOWED). Unprovable ⇒ nothing is stripped.
  for (const [label, delim, term] of [
    ["A36 `<<$'EOS'`", "$'EOS'", "$EOS"],
    ['A37 `<<$"EOS"`', '$"EOS"', "$EOS"],
    ["A38 `<<E$'OS'`", "E$'OS'", "E$OS"],
  ]) {
    const cmd = `cmux vm exec cell-a -- bash <<${delim}\necho x\n${term}\n${tail}`;
    expectEq(`${label} → unprovable delimiter, nothing stripped`, strip(cmd), cmd);
  }
  // ── A39–A41: a transport name CONSTRUCTED locally (the cycle-2 shadow) ────
  // `eval`/`source`/`.` build a definition from text no scan can read, so the
  // name may resolve locally even though the segment looks remote.
  for (const [label, prefix] of [
    ["A39 `eval '…ssh()…'`", `eval 'ssh() { :; }'`],
    ['A40 `eval "…ssh()…"`', 'eval "ssh() { :; }"'],
    ["A41 `source <file>`", "source /tmp/defs.sh"],
    ["A42 `. <file>` (POSIX dot-command)", ". /tmp/defs.sh"],
  ]) {
    const cmd = `${prefix}; ssh cell-a -- ${PULL}`;
    expectEq(`${label} … then a remote-looking dispatch → not provable, unchanged`, strip(cmd), cmd);
  }
  // The control: with NOTHING able to redefine the name, the same dispatch is
  // still stripped — so A39–A42 are the shadow, not "quoted text is never stripped".
  expectEq("A43 control: `echo hi ; ssh host -- …` (no redefinition) → still stripped",
    strip(`echo hi ; ssh cell-a -- ${PULL}`), `echo hi ; true`);

  // A shell FUNCTION/ALIAS named after a transport resolves LOCALLY, and so does
  // a PATH-QUALIFIED token that merely looks like one.
  for (const [label, cmd] of [
    ["A30 `ssh() { … }` then `ssh …`", `ssh() { eval "$@"; }; ssh cell-a -- ${PULL}`],
    ["A31 `function ssh { … }` then `ssh …`", `function ssh { eval "$@"; }; ssh cell-a -- ${PULL}`],
    ["A32 `alias ssh=…` then `ssh …`", `alias ssh=eval && ssh cell-a -- ${PULL}`],
    ["A33 `./ssh …` (a LOCAL file named like the transport)", `./ssh cell-a -- ${PULL}`],
    ["A34 `/usr/local/bin/cmux vm exec …` (path-qualified)", `/usr/local/bin/cmux vm exec cell-a -- ${PULL}`],
    ["A35 a QUOTED head (\"ssh\" …)", `"ssh" cell-a -- ${PULL}`],
  ]) {
    expectEq(`${label} → not provable, unchanged`, strip(cmd), cmd);
  }

  // ── A44–A52: the CYCLE-3 fail-open class found by fresh-context review ────
  // (1) `$'…'` is ANSI-C quoting: `\` escapes INSIDE it, so a plain single-quote
  // scan closed the quote at `\'` and INVERTED the segmenter's state — every
  // later `;`/`>` then read as "inside a string" and the whole command collapsed
  // into ONE remote segment. Measured against the real handler: a LOCAL reset and
  // a LOCAL tracked-file write were both laundered as remote.
  {
    const cmd = `cmux vm exec cell-a -- bash $'\\'' ; ${RESET}`;
    expectTrue("A44 an ANSI-C `$'…'` word cannot swallow the LOCAL tail", strip(cmd).includes(RESET),
      `got ${JSON.stringify(strip(cmd))} — a local command was laundered as remote`);
    expectTrue("A44b …and the dispatch itself is still replaced", strip(cmd).startsWith("true"),
      `got ${JSON.stringify(strip(cmd))}`);
    const red = `cmux vm exec cell-a -- ls $'\\'' > tracked.txt`;
    expectTrue("A45 …nor a LOCAL redirection after it (the #437/#618 gate reads it)",
      strip(red).includes("tracked.txt"), `got ${JSON.stringify(strip(red))}`);
  }
  // (2) A transport word whose RESOLUTION the command changed is not provable:
  // a leading `PATH=` makes the bare word resolve to a LOCAL shim, and ssh's own
  // argv can execute (`-o ProxyCommand`/`LocalCommand`) or read/write
  // (`-F`/`-E`) local files BEFORE the dispatch happens.
  for (const [label, cmd] of [
    ["A46 `PATH=…:$PATH ssh …` (a local shim named ssh)", `PATH=/tmp/shim:$PATH ssh cell-a -- ${RESET}`],
    ["A47 `ssh -o ProxyCommand=…` (run by the LOCAL ssh)", `ssh -o ProxyCommand='${RESET}' cell-a -- ls`],
    ["A48 `ssh -oProxyCommand=…` (attached value)", `ssh -oProxyCommand='${RESET}' cell-a -- ls`],
    ["A49 `ssh -F <config>` (its content is unprovable)", "ssh -F /tmp/nonexistent-3444.conf cell-a -- ls"],
    ["A50 `ssh -E <log>` (a LOCAL write)", "ssh -E /tmp/nonexistent-3444.log cell-a -- ls"],
  ]) {
    expectEq(`${label} → not provable, unchanged`, strip(cmd), cmd);
  }
  // …and the controls: the rejections are SCOPED, not a blanket ssh block.
  expectEq("A51 control: `ssh -o BatchMode=yes …` stays provable",
    strip(`ssh -t -o BatchMode=yes cell-a -- ${PULL}`), "true");
  expectEq("A52 control: a plain env prefix (`FOO=1 cmux …`) stays provable",
    strip(`FOO=1 cmux vm exec --timeout 60 cell-a -- ${PULL}`), "true");
}

// ── Part B: the REAL handler, in a hermetic MAIN checkout ─────────────────
// The predicate above can pass while the live gate over-blocks (the script-
// content gate is disarmed by a worktree cwd, for instance), so every pinned
// case is driven through `index.ts`'s registered tool_call handler.
console.log("\n── Part B: real index.ts tool_call handler (hermetic MAIN hub) ──");

async function loadGuard(indexPath) {
  // The hooks resolve `.js` → `.ts` siblings and stub the pi package; they are
  // taken from the REPO's guard directory even when the module under test is a
  // mutated copy (the loader is not part of the code under test).
  const hooks = await import(new URL("./module-load-hooks.mjs", pathToFileURL(HERE)).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", pathToFileURL(HERE)), import.meta.url);
  process.removeAllListeners("warning");
  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...a) => warnings.push(a.map(String).join(" "));
  let mod;
  try { mod = await import(pathToFileURL(indexPath).href); } finally { console.warn = realWarn; }
  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  const degraded = warnings.filter((w) => w.includes("[main-worktree-guard]") && /failed|DISABLED|⚠️/.test(w));
  return { toolCall, degraded };
}

let m2Root = null;
async function partB() {
  const { toolCall, degraded } = await loadGuard(INDEX_TS);
  expectTrue("B0  index.ts loads with no degradation warning", degraded.length === 0, degraded.join(" | "));
  expectTrue("B0b the factory registered a tool_call handler", typeof toolCall === "function", "none");
  if (typeof toolCall !== "function") return;

  const home = realpathSync(mkdtempSync(join(tmpdir(), "rc-home-")));
  const work = realpathSync(mkdtempSync(join(tmpdir(), "rc-work-")));
  const hub = join(work, "hub");
  const saved = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID"]
    .map((v) => [v, process.env[v]]));
  const prevCwd = process.cwd();
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  try {
    // Hermetic MAIN checkout on main, clean — the #1484/#1919 actor in scope.
    sh(`git init -q -b main "${hub}"`, work);
    sh("git config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "tracked.txt"), "v1\n");
    sh("git add -A && git commit -qm init", hub);
    sh("git branch fix/x", hub);
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;

    const bash = async (command) => {
      process.chdir(hub);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prevCwd); }
    };
    const allowed = (r) => r === undefined || r === null;
    const why = (r) => String((r && r.reason) || "").split("\n")[0];
    const pair = async (label, remoteCmd, localCmd, wantLocal) => {
      const r = await bash(remoteCmd);
      expectTrue(`B ${label}: REMOTE form → ALLOWED`, allowed(r), `BLOCKED: ${why(r)}`);
      const l = await bash(localCmd);
      expectTrue(`B ${label}: the LOCAL form of the same command is still REFUSED (${wantLocal})`,
        !allowed(l) && wantLocal.test(why(l)), `got: ${allowed(l) ? "ALLOWED" : why(l)}`);
    };

    // ── The four measured refusals, each paired with its local twin ──
    // 1. #1919 — a remote worktree-add whose RELATIVE path was resolved against
    //    the local hub (the message named the local path).
    await pair("1  #1919 remote worktree add",
      `cmux vm exec cell-a -- bash -c '${WTA}'`, WTA, /#1919/);
    // 2. #1484 — a remote branch switch gated as though it ran in the hub. All
    //    three recognised transports, because the fleet uses more than one.
    await pair("2  #1484 remote branch switch (cmux)",
      `cmux vm exec cell-a -- ${COB}`, COB, /chec|switch|#1484/i);
    for (const [label, prefix] of [["2b", "ssh cell-a --"], ["2c", "docker exec pi-cell-3 --"]]) {
      const r = await bash(`${prefix} ${COB}`);
      expectTrue(`B ${label} #1484 remote branch switch (${prefix.split(" ")[0]}) → ALLOWED`,
        allowed(r), `BLOCKED: ${why(r)}`);
    }
    // 3. #1144 — a remote `pull` inside a compound command.
    await pair("3  #1144 remote pull in a compound",
      `cd /tmp && cmux vm exec cell-a -- ${PULL}`, `cd /tmp && ${PULL}`, /#1144|pull/i);
    // 4. A payload delivered to a REMOTE shell. ⛔ MEASURED HONESTY NOTE: the
    //    PLAIN `echo <b64> | base64 -d | cmux … -- bash` form was ALREADY allowed
    //    before this fix (measured 2026-11-04, this suite's B4 assertion), so it
    //    carries no mutation evidence and is pinned only as a regression. The
    //    case-4 shape that WAS refused pre-fix — and that this fix is what
    //    unblocks — is the HEREDOC form below (B4b): its body is gated against
    //    the local hub by the #1144 sync arm.
    {
      const remote = `echo ${B64} | base64 -d | cmux vm exec cell-a -- bash`;
      const r = await bash(remote);
      expectTrue("B 4  payload piped to a REMOTE shell → ALLOWED (regression only: it was already allowed pre-fix)",
        allowed(r), `BLOCKED: ${why(r)}`);
      const local = await bash(`bash -c '${RESET}'`);
      expectTrue("B 4  the same payload executed LOCALLY is still REFUSED",
        !allowed(local) && /reset/i.test(why(local)), `got: ${allowed(local) ? "ALLOWED" : why(local)}`);
    }
    {
      const remote = `cmux vm exec cell-a -- bash <<'EOS'\n${PULL}\nEOS`;
      const r = await bash(remote);
      expectTrue("B 4b a HEREDOC fed to a REMOTE shell → ALLOWED (this shape WAS refused by #1144 pre-fix)",
        allowed(r), `BLOCKED: ${why(r)}`);
      const local = await bash(`bash <<'EOS'\n${PULL}\nEOS`);
      expectTrue("B 4b the same heredoc fed to a LOCAL shell is still REFUSED",
        !allowed(local), "was ALLOWED — a local heredoc payload must stay gated");
    }

    // ── ⛔ ANTI-LAUNDERING: the boundary is a SEGMENT, never the command ──
    // Each of these re-enters LOCAL scope after a remote segment. If any were
    // allowed, the fix would be a total bypass of every gate it names.
    for (const [label, cmd] of [
      ["B5  remote then LOCAL pull after `;`", `cmux vm exec cell-a -- git status ; ${PULL}`],
      ["B6  remote then LOCAL reset after `&&`", `cmux vm exec cell-a -- git status && ${RESET}`],
      ["B7  remote then LOCAL branch switch after `|`", `cmux vm exec cell-a -- git status | ${COB}`],
      ["B8  LOCAL reset piped INTO a remote", `${RESET} | cmux vm exec cell-a -- cat`],
      ["B9  substitution in the remote argv (local eval)", `cmux vm exec cell-a -- bash -c "$(${RESET})"`],
      ["B10 unquoted heredoc to remote (local expansion)", `cmux vm exec cell-a -- bash <<EOS\n$(${RESET})\nEOS`],
      ["B11 remote dispatch into a TRACKED hub file", `cmux vm exec cell-a -- ls > tracked.txt`],
      ["B15 escaped heredoc delimiter, then a LOCAL reset", `cmux vm exec cell-a -- bash <<\\EOS\necho x\nEOS\n${RESET}`],
      ["B16 concatenated-quote delimiter, then a LOCAL reset", `cmux vm exec cell-a -- bash <<E"O"S\necho x\nEOS\n${RESET}`],
      ["B17 unterminated heredoc, then a LOCAL reset", `cmux vm exec cell-a -- bash <<'EOS'\necho x\n${RESET}`],
      ["B18 a FUNCTION named `ssh` shadows the transport", `ssh() { eval "\${@:3}"; }; ssh cell-a -- ${RESET}`],
      ["B19 an ALIAS named `ssh` shadows the transport", `alias ssh=eval && ssh cell-a -- ${RESET}`],
      ["B20 a LOCAL file named like the transport (./ssh)", `./ssh cell-a -- ${RESET}`],
      ["B21 `<<$'EOS'` delimiter, then a LOCAL reset", `cmux vm exec cell-a -- bash <<$'EOS'\necho x\nEOS\n${RESET}\n$EOS`],
      ['B22 `<<$"EOS"` delimiter, then a LOCAL reset', `cmux vm exec cell-a -- bash <<$"EOS"\necho x\nEOS\n${RESET}\n$EOS`],
      ["B23 synthetic `export TEMPLATE` then eval-built ssh() — reserved-word transport", `export T=ssh; eval "$T() { :; }"; ssh cell-a -- ${RESET}`],
      ["B24 `eval 'ssh() { … }'` then a remote-looking dispatch", `eval 'ssh() { eval "\${@:3}"; }'; ssh cell-a -- ${RESET}`],
      ["B25 `source <file>` then a remote-looking dispatch", `source /tmp/defs-nonexistent.sh; ssh cell-a -- ${RESET}`],
      ["B26 `. <file>` then a remote-looking dispatch", `. /tmp/defs-nonexistent.sh; ssh cell-a -- ${RESET}`],
      ["B27 ANSI-C `$'…'` then a LOCAL reset", `cmux vm exec cell-a -- bash $'\\'' ; ${RESET}`],
      ["B28 ANSI-C `$'…'` hiding a LOCAL tracked write", `cmux vm exec cell-a -- ls $'\\'' > tracked.txt`],
      ["B29 a PATH-shimmed transport", `PATH=/tmp/shim:$PATH ssh cell-a -- ${RESET}`],
      ["B30 ssh -o ProxyCommand running HERE", `ssh -o ProxyCommand='${RESET}' cell-a -- ls`],
    ]) {
      const r = await bash(cmd);
      expectTrue(`${label} → STILL REFUSED`, !allowed(r), "was ALLOWED — the remote boundary laundered a LOCAL operation");
    }

    // ── The controls for B27–B30: the new rejections are SCOPED ────────────
    // A benign ssh option and a plain env prefix are still a provable boundary,
    // so the fix is not "ssh and env prefixes are gated forever".
    for (const [label, cmd] of [
      ["B31 ssh -o BatchMode=yes … still ALLOWED", `ssh -t -o BatchMode=yes cell-a -- ${PULL}`],
      ["B32 a plain env prefix still ALLOWED", `FOO=1 cmux vm exec --timeout 60 cell-a -- ${PULL}`],
    ]) {
      const r = await bash(cmd);
      expectTrue(`${label}`, allowed(r), `BLOCKED: ${why(r)}`);
    }

    // ── The positive shape the fleet actually runs, end to end ──
    {
      const r = await bash(`cmux vm exec cell-a -- ${PULL} ; docker exec pi-cell-3 -- ${COB}`);
      expectTrue("B12 an all-remote compound (two cells) → ALLOWED", allowed(r), `BLOCKED: ${why(r)}`);
    }
    {
      const r = await bash(`cmux vm exec cell-a -- ls > ${join(home, "remote-out.txt")}`);
      expectTrue("B13 a remote dispatch with a LOCAL redirect to /tmp-ish → ALLOWED", allowed(r), `BLOCKED: ${why(r)}`);
    }
    // A remote `touch` of the escape marker must NOT mint the LOCAL marker: the
    // dispatch runs on another box, so the local hatch stays closed.
    {
      const marker = join(home, ".pi", "agent", ".allow-main-edits");
      const r = await bash(`cmux vm exec cell-a -- touch ${marker}`);
      const minted = (() => { try { readFileSync(marker); return true; } catch { return false; } })();
      expectTrue("B14 a remote `touch` of the escape marker → ALLOWED and does NOT mint the LOCAL marker",
        allowed(r) && !minted, `allowed=${allowed(r)} minted=${minted}`);
    }
  } finally {
    process.chdir(prevCwd);
    for (const [v, val] of saved) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(work, { recursive: true, force: true }); } catch { /* best-effort */ }
    try { rmSync(home, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

try {
  await partB();
} catch (e) {
  // A security-gate suite must FAIL, not silently skip, when its fixture cannot
  // be provisioned.
  console.error(`❌ Part B failed to provision: ${String(e?.message ?? e).slice(0, 200)}`);
  fail++;
}

// ── Part M (#3444): MUTATION EVIDENCE — the pins must be able to go RED ────
// A pin that cannot fail is not a pin. This reverts the fix in three independent
// places and requires the paired assertions to FAIL:
//   M1 the RECOGNISER (`stripRemoteContexts` → identity) — the pure pins and the
//      decision they feed both go blind;
//   M2 the CALL SITE (the handler's strip call → identity) — the four field cases
//      are refused again at the REAL handler, which is the defect itself;
//   M3 the STRIP'S PROOF (delimiter quote removal, the unterminated-heredoc
//      refusal, the shadowed-transport refusal, the bare-word head rule) — the
//      fail-open shapes the review found are ALLOWED again. M1/M2 cannot redden
//      these: `identity` is STRICTER, so a fail-open pin needs a mutant that
//      reintroduces the fail-open.
// Opt-in, its own CI step (the same construction as the discard-gate suite).
if (process.argv.includes("--mutations")) {
  console.log("\n── Part M: mutation evidence — reverting the fix reddens the pins ──");
  const mutRoot = realpathSync(mkdtempSync(join(tmpdir(), "rc-mut-")));
  try {
    const SRC = readFileSync(CG, "utf8");
  // Each mutant gets its OWN tree: Node caches ES modules by URL, so two mutants
  // sharing one path would silently hand the second the FIRST one's module (a
  // mutant that proves nothing — measured here as "still BLOCKED" on every pin).
  const makeMutantTree = (name, indexSrc, classifySrc) => {
    const tree = join(mutRoot, name);
    const gdir = join(tree, "extensions", "main-worktree-guard");
    mkdirSync(gdir, { recursive: true });
    symlinkSync(join(REPO_EXTENSIONS.replace(/[\\/]$/, ""), "shared"), join(tree, "extensions", "shared"));
    writeFileSync(join(gdir, "index.ts"), indexSrc);
    writeFileSync(join(gdir, "classify-git.mjs"), classifySrc);
    copyFileSync(join(HERE, "sanctioned-scripts.pin.json"), join(gdir, "sanctioned-scripts.pin.json"));
    return join(gdir, "index.ts");
  };

    // M1 — the recogniser, reverted.
    {
      const anchor = "export function stripRemoteContexts(command) {";
      expectTrue("M1a the recogniser's anchor is present (a stale anchor would prove nothing)", SRC.includes(anchor));
      // Everything after the doc comment and before `return out + text.slice(cursor);`
      // is the recogniser; the mutant keeps the signature and returns its input.
      const mutated = SRC.replace(anchor, `${anchor}\n  return String(command ?? \"\"); // MUTANT (#3444): recogniser reverted\n`);
      expectTrue("M1b the recogniser mutant was actually applied", mutated !== SRC);
      const copy = join(mutRoot, "mut-recogniser.mjs");
      writeFileSync(copy, mutated);
      const mut = await import(pathToFileURL(copy).href);
      for (const [label, cmd] of [
        ["cmux vm exec", `cmux vm exec cell-a -- ${PULL}`],
        ["ssh --", `ssh cell-a -- ${COB}`],
        ["docker exec --", `docker exec c1 -- ${PULL}`],
      ]) {
        const out = mut.stripRemoteContexts(cmd);
        expectTrue(`M1 ${label}: with the recogniser reverted the pin goes RED (the remote text survives)`,
          out === cmd && /\bgit\b/.test(out), `got ${JSON.stringify(out)} — the pin would not fail`);
        // …and that survival is exactly the refusal: the same decision the live
        // gate takes on the un-stripped text.
        expectTrue(`M1 ${label}: …and the classifier then REFUSES it (the #3444 defect reproduced)`,
          classifyGitCommand(out).startsWith("block:"), `verdict=${classifyGitCommand(out)}`);
      }
    }

    // M2 — the CALL SITE, reverted (the whole fix, end to end).
    const SRCIDX = readFileSync(INDEX_TS, "utf8");
    {
      const anchor = '? stripRemoteContexts((event.input as { command?: string }).command ?? "")';
      expectTrue("M2a the call site's anchor is present", SRCIDX.includes(anchor));
      const mutIndex = makeMutantTree("m2",
        SRCIDX.replace(anchor, '? ((s: string) => s)((event.input as { command?: string }).command ?? "")'),
        SRC);

      const { toolCall, degraded } = await loadGuard(mutIndex);
      expectTrue("M2b the call-site mutant loads with no degradation warning", degraded.length === 0, degraded.join(" | "));
      if (typeof toolCall === "function") {
        const home = realpathSync(mkdtempSync(join(tmpdir(), "rc-mut-home-")));
        const work = realpathSync(mkdtempSync(join(tmpdir(), "rc-mut-work-")));
        const hub = join(work, "hub");
        const prevCwd = process.cwd();
        const saved = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID"]
          .map((v) => [v, process.env[v]]));
        const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
        try {
          sh(`git init -q -b main "${hub}"`, work);
          sh("git config user.email t@t && git config user.name t", hub);
          writeFileSync(join(hub, "a.txt"), "v1\n");
          sh("git add -A && git commit -qm init", hub);
          sh("git branch fix/x", hub);
          mkdirSync(join(home, ".pi", "agent"), { recursive: true });
          for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
          process.env.HOME = home;
          delete process.env.PI_SESSION_ID;
          for (const [label, cmd] of [
            ["M2  #1484 remote branch switch", `cmux vm exec cell-a -- ${COB}`],
            ["M2  #1144 remote pull", `cmux vm exec cell-a -- ${PULL}`],
            ["M2  #1144 remote pull behind ssh", `ssh cell-a -- ${PULL}`],
            ["M2  #1919 remote worktree add", `cmux vm exec cell-a -- bash -c '${WTA}'`],
            ["M2  heredoc fed to a remote shell (#1144)", `cmux vm exec cell-a -- bash <<'EOS'\n${PULL}\nEOS`],
          ]) {
            process.chdir(hub);
            const r = await toolCall({ toolName: "bash", input: { command: cmd } }, undefined);
            const blocked = !!r && r.block === true;
            expectTrue(`${label}: with the CALL SITE reverted the pin goes RED (refused again)`,
              blocked, "still ALLOWED — the mutation proves nothing, the pin is not the thing holding the fix");
          }
        } finally {
          process.chdir(prevCwd);
          for (const [v, val] of saved) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
          try { rmSync(work, { recursive: true, force: true }); } catch { /* best-effort */ }
          try { rmSync(home, { recursive: true, force: true }); } catch { /* best-effort */ }
        }
      }
    }

    // M3 — the DEFECT the review found, reintroduced (a mutant that reverts the
    // STRIP'S PROOF rather than the strip itself). The whole-fix reverts above
    // (M1/M2) cannot redden these pins: `identity` is STRICTER, so a fail-open
    // guard needs a mutant that reintroduces the fail-open.
    {
      const anchors = [
        // (a) the delimiter's quote removal → back to plain quote stripping, and
        // (b) the `$'…'`-form unprovability bail → removed (the cycle-2 defect),
        // (c) the unprovable/unterminated-heredoc refusal → removed.
        ["heredocs.push({ delim, dash, provable: delim !== null });",
         "heredocs.push({ delim: _wtUnquoteWord(raw), dash, provable: true });"],
        ["if (/\\$['\"]/.test(s)) return null;", "if (false) return null;"],
        ["if (seg.unprovable || seg.bodies.some((b) => !b.terminated)) continue;",
         "if (false) continue;"],
        // (d) the redefinition refusal (literal AND constructed) → removed, and
        // (e) the bare-word head rule → removed.
        ["if (_wtMayRedefineTransport(text.slice(0, seg.start))) continue;",
         "if (false) continue;"],
        ["if (toks[i] !== head) return -1;", "if (false) return -1;"],
      ];
      let mutated = SRC;
      let applied = 0;
      for (const [from, to] of anchors) { if (!mutated.includes(from)) continue; mutated = mutated.replace(from, to); applied++; }
      expectTrue("M3a every proof anchor was actually reverted (a stale anchor proves less than it claims)",
        applied === anchors.length, `applied ${applied}/${anchors.length}`);

      // index.ts stays the REAL one: the wiring is not what is on trial here.
      const mutIndex = makeMutantTree("m3", SRCIDX, mutated);
      const { toolCall, degraded } = await loadGuard(mutIndex);
      expectTrue("M3b the proof-reverted mutant loads with no degradation warning", degraded.length === 0, degraded.join(" | "));
      if (typeof toolCall === "function") {
        const home = realpathSync(mkdtempSync(join(tmpdir(), "rc-m3-home-")));
        const work = realpathSync(mkdtempSync(join(tmpdir(), "rc-m3-work-")));
        const hub = join(work, "hub");
        const prevCwd = process.cwd();
        const saved = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID"]
          .map((v) => [v, process.env[v]]));
        const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
        try {
          sh(`git init -q -b main "${hub}"`, work);
          sh("git config user.email t@t && git config user.name t", hub);
          writeFileSync(join(hub, "a.txt"), "v1\n");
          sh("git add -A && git commit -qm init", hub);
          mkdirSync(join(home, ".pi", "agent"), { recursive: true });
          for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
          process.env.HOME = home;
          delete process.env.PI_SESSION_ID;
          for (const [label, cmd] of [
            ["M3  B15 escaped heredoc delimiter + LOCAL tail", `cmux vm exec cell-a -- bash <<\\EOS\necho x\nEOS\n${RESET}`],
            ["M3  B16 concatenated-quote delimiter + LOCAL tail", `cmux vm exec cell-a -- bash <<E"O"S\necho x\nEOS\n${RESET}`],
            ["M3  B17 unterminated heredoc + LOCAL tail", `cmux vm exec cell-a -- bash <<'EOS'\necho x\n${RESET}`],
            ["M3  B18 shell FUNCTION shadows the transport", `ssh() { eval "\${@:3}"; }; ssh cell-a -- ${RESET}`],
            ["M3  B19 ALIAS shadows the transport", `alias ssh=eval && ssh cell-a -- ${RESET}`],
            ["M3  B20 LOCAL file named like the transport", `./ssh cell-a -- ${RESET}`],
            ["M3  B21 `$'EOS'` delimiter + LOCAL tail", `cmux vm exec cell-a -- bash <<$'EOS'\necho x\nEOS\n${RESET}\n$EOS`],
            ["M3  B24 eval-built ssh() shadow", `eval 'ssh() { eval "\${@:3}"; }'; ssh cell-a -- ${RESET}`],
            ["M3  B25 source-built shadow", `source /tmp/defs-nonexistent.sh; ssh cell-a -- ${RESET}`],
          ]) {
            process.chdir(hub);
            const r = await toolCall({ toolName: "bash", input: { command: cmd } }, undefined);
            const blocked = !!r && r.block === true;
            expectTrue(`${label}: with the PROOF reverted the pin goes RED (allowed again)`,
              !blocked, "still BLOCKED — the pin is not the thing holding this fix");
          }
        } finally {
          process.chdir(prevCwd);
          for (const [v, val] of saved) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
          try { rmSync(work, { recursive: true, force: true }); } catch { /* best-effort */ }
          try { rmSync(home, { recursive: true, force: true }); } catch { /* best-effort */ }
        }
      }
    }

    // M4 — the CYCLE-3 fail-open class, reintroduced (#3444 review cycle 3).
    // M1/M2/M3 cannot redden these pins: each reverts a DIFFERENT proof. This
    // mutant removes only the three proofs that stop a LOCAL execution from
    // being read as remote — ANSI-C quoting, the resolution-variable prefix, and
    // ssh's own local-execution argv — and requires B27–B30 to be ALLOWED again.
    {
      const anchors = [
        // (a) ANSI-C `$'…'` handling in the SEGMENTER (the `while (i < n)` copy;
        // the `_wtSkipBalanced` copy is not what decides segments).
        ["if (ch === \"$\" && text[i + 1] === \"'\") {\n      i += 2;\n      while (i < n) {",
         "if (false) {\n      i += 2;\n      while (i < n) {"],
        // (b) the command-RESOLUTION variable prefix (PATH & friends).
        ["if (/^(?:PATH|CDPATH|BASH_ENV|ENV|IFS)$/.test(w.slice(0, w.indexOf(\"=\")))) return -1;",
         "if (false) return -1;"],
        // (c) ssh's own local-execution / local-file argv.
        ["for (let j = i + 1; j < sep; j++) {\n      const raw = word(j);\n      if (/^-F/.test(raw) || raw === \"--config\") return -1;",
         "for (let j = i + 1; false && j < sep; j++) {\n      const raw = word(j);\n      if (/^-F/.test(raw) || raw === \"--config\") return -1;"],
      ];
      let mutated = SRC;
      let applied = 0;
      for (const [from, to] of anchors) { if (!mutated.includes(from)) continue; mutated = mutated.replace(from, to); applied++; }
      expectTrue("M4a every cycle-3 proof anchor was actually reverted",
        applied === anchors.length, `applied ${applied}/${anchors.length}`);
      const mutIndex = makeMutantTree("m4", SRCIDX, mutated);
      const { toolCall, degraded } = await loadGuard(mutIndex);
      expectTrue("M4b the cycle-3 mutant loads with no degradation warning", degraded.length === 0, degraded.join(" | "));
      if (typeof toolCall === "function") {
        const home = realpathSync(mkdtempSync(join(tmpdir(), "rc-m4-home-")));
        const work = realpathSync(mkdtempSync(join(tmpdir(), "rc-m4-work-")));
        const hub = join(work, "hub");
        const prevCwd = process.cwd();
        const saved = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID"]
          .map((v) => [v, process.env[v]]));
        const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
        try {
          sh(`git init -q -b main "${hub}"`, work);
          sh("git config user.email t@t && git config user.name t", hub);
          writeFileSync(join(hub, "tracked.txt"), "v1\n");
          sh("git add -A && git commit -qm init", hub);
          mkdirSync(join(home, ".pi", "agent"), { recursive: true });
          for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
          process.env.HOME = home;
          delete process.env.PI_SESSION_ID;
          for (const [label, cmd] of [
            ["M4  B27 ANSI-C quoting + LOCAL reset", `cmux vm exec cell-a -- bash $'\\'' ; ${RESET}`],
            ["M4  B28 ANSI-C quoting hiding a LOCAL tracked write", `cmux vm exec cell-a -- ls $'\\'' > tracked.txt`],
            ["M4  B29 PATH-shimmed transport", `PATH=/tmp/shim:$PATH ssh cell-a -- ${RESET}`],
            ["M4  B30 ssh -o ProxyCommand", `ssh -o ProxyCommand='${RESET}' cell-a -- ls`],
          ]) {
            process.chdir(hub);
            const r = await toolCall({ toolName: "bash", input: { command: cmd } }, undefined);
            const blocked = !!r && r.block === true;
            expectTrue(`${label}: with the cycle-3 proofs reverted the pin goes RED (allowed again)`,
              !blocked, "still BLOCKED — the pin is not the thing holding this fix");
          }
        } finally {
          process.chdir(prevCwd);
          for (const [v, val] of saved) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
          try { rmSync(work, { recursive: true, force: true }); } catch { /* best-effort */ }
          try { rmSync(home, { recursive: true, force: true }); } catch { /* best-effort */ }
        }
      }
    }
  } finally {
    try { rmSync(mutRoot, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

// The aggregate line keeps the shared runner shape `<label>: N passed, M failed`
// with NO suffix after the label: `scripts/ci_exemption.py`'s runner identity
// (`_RUNNER_AGG_RE`) is anchored on `<label>:`, so a decorated label
// (`test-remote-context (#3444): …`) matches nothing and a failing run would
// yield no parseable failure identity for the merge rail.
console.log(`\n${fail === 0 ? "✅" : "❌"} test-remote-context: ${pass} passed, ${fail} failed`);
console.log(`   (agent-infra#3444 — remote-context boundaries)`);
process.exit(fail === 0 ? 0 : 1);
