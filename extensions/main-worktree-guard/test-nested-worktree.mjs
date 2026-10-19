// test-nested-worktree.mjs — #1919: a worktree nested INSIDE the repo root.
//
// The failure this suite pins: a lane ran `git worktree add 8779-optA` with a
// RELATIVE path, so a registered worktree landed inside the repo root. git
// reports it as an untracked directory, the shared hub therefore read DIRTY, and
// the M4 hub-state gate then refused EVERY verb that could fix it — `worktree
// move` is not on the recovery allowlist, `prune` cannot remove a LIVE worktree,
// and the sanctioned checkout/pull does not delete an untracked directory. A gate
// closed against its own repair; every push in the session was blocked while it
// held.
//
// Two halves, and BOTH directions are pinned:
//   (a) a REGISTERED worktree is not hub dirt (classify-git
//       porcelainWithoutRegisteredWorktrees / readHubDisorder), while a genuine
//       untracked file and a tracked modification STILL make the hub dirty and
//       STILL block — the safety the gate exists for;
//   (b) a `worktree add|move` whose target lands inside a checkout where git
//       does not ignore it is REFUSED at creation, so the state is never born —
//       while the fleet's own `<hub>/.worktrees/<name>` (gitignored) and any
//       path outside the repo keep working.
//
// Two parts, same split as test-discard-gate.mjs:
//   Part A — pure classification/decision (classify-git.mjs, zero-dep)
//   Part B — behavioral: the REAL index.ts is loaded through
//            ./module-load-hooks.mjs and its registered tool_call handler is
//            driven against a hermetic hub.
//
// Run: node extensions/main-worktree-guard/test-nested-worktree.mjs
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
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

const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
const out = (cmd, cwd) => execSync(cmd, { cwd, encoding: "utf8" });

// ─────────────────────────────────────────────────────────────────────────
// Part A — classifier level (classify-git.mjs)
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: registered-worktree exclusion + creation refusal ──");

const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const {
  readHubDisorder, porcelainWithoutRegisteredWorktrees, nestedWorktreeTargetViolation,
  nestedWorktreeTargetReason, evaluateHubGateWithTargets, isHubRecoveryInvocation,
} = cg;

// Hermetic fixture (realpath: macOS /var → /private/var).
const tmp = realpathSync(mkdtempSync(join(tmpdir(), "nested-wt-")));
const hub = join(tmp, "hub");
const outside = join(tmp, "outside-wt");
try {
  mkdirSync(hub, { recursive: true });
  gg("init -q -b main", hub);
  gg("config user.email t@t && git config user.name t", hub);
  // The fleet's own layout is gitignored — `hub-worktree.sh` creates
  // <hub>/.worktrees/<branch>, and that must keep working.
  writeFileSync(join(hub, ".gitignore"), ".worktrees/\n");
  writeFileSync(join(hub, "a.txt"), "v1\n");
  gg("add -A && git commit -qm init", hub);

  // A1: the hub is clean BEFORE the nested worktree exists.
  expect("A1: clean hub → no disorder", readHubDisorder(hub).disorder, null);

  // A2: the incident's exact shape — a RELATIVE path, created the way a lane did
  // it (raw git: the guard is not in the loop for this fixture creation).
  gg("worktree add -q nested-wt -b nested-br", hub);
  const rawPorcelain = out("git status --porcelain", hub);
  expectTrue("A2: git DOES report the nested worktree as an untracked dir (the false positive's source)",
    rawPorcelain.trim() === "?? nested-wt/", JSON.stringify(rawPorcelain));
  expect("A2: …but it is NOT hub dirt (readHubDisorder)", readHubDisorder(hub).disorder, null);
  expect("A2: …and the porcelain filter drops exactly that entry",
    porcelainWithoutRegisteredWorktrees(rawPorcelain, hub).trim(), "");

  // A3: THE SAFETY HALF — a genuine untracked file still makes the hub dirty,
  // and the filter keeps it.
  writeFileSync(join(hub, "genuine-untracked.txt"), "wip\n");
  const withGenuine = out("git status --porcelain", hub);
  expect("A3: nested worktree + genuine untracked → DIRTY", readHubDisorder(hub).disorder, "dirty");
  expect("A3: …the filter keeps the genuine entry and drops only the worktree",
    porcelainWithoutRegisteredWorktrees(withGenuine, hub).trim(), "?? genuine-untracked.txt");
  rmSync(join(hub, "genuine-untracked.txt"));

  // A4: …and so does TRACKED dirt. Only `?? ` entries are ever excluded, so a
  // modified tracked file is untouchable by this rule.
  writeFileSync(join(hub, "a.txt"), "v2\n");
  const withTracked = out("git status --porcelain", hub);
  expect("A4: nested worktree + tracked modification → DIRTY", readHubDisorder(hub).disorder, "dirty");
  expect("A4: …the filter leaves tracked entries alone",
    porcelainWithoutRegisteredWorktrees(withTracked, hub).trim(), "M a.txt");
  gg("checkout -- a.txt", hub);

  // A5: the M4 verdict, both directions, for the verb the issue was refused on.
  // (a) nested-worktree-only: M4's precondition (disorder) is FALSE, so the gate
  //     is never consulted and `worktree move` out is reachable — the repair the
  //     issue could not perform. (Part B B6 drives the real handler, so this is
  //     the pure decision that must hold for it.)
  expect("A5: nested-worktree-only hub → M4's precondition is FALSE (no disorder)",
    (readHubDisorder(hub).disorder ?? null) !== null, false);
  // (b) genuine untracked dirt present: M4 blocks its own sanctioned-looking ops
  //     exactly as before — the gate was not weakened, only corrected. This is
  //     the half that proves the fix is not "delete the dirty check".
  writeFileSync(join(hub, "genuine-untracked.txt"), "wip\n");
  const blocked = evaluateHubGateWithTargets("git worktree move nested-wt /tmp/nope", "main", hub);
  expect("A5: …genuinely dirty hub → the same command IS blocked", blocked.verdict, "block");
  expectTrue("A5: …with the hub-state gate's own reason",
    String(blocked.reason ?? "").includes("Hub-state gate (M4)"), String(blocked.reason ?? "").slice(0, 80));
  rmSync(join(hub, "genuine-untracked.txt"));

  // A6: the worktree-op refusal is NOT dropped as a shortcut. `worktree move` is
  // still off the recovery allowlist, so a hub that is dirty for any OTHER reason
  // cannot be talked into relocating a worktree.
  expect("A6: `worktree move` is still NOT a sanctioned recovery op",
    isHubRecoveryInvocation("worktree", ["move", "nested-wt", "/tmp/x"], "main"), "block");
  expect("A6: `worktree remove` remains sanctioned (unchanged by this fix)",
    isHubRecoveryInvocation("worktree", ["remove", "nested-wt"], "main"), "recovery");

  // A7: creation refusal — the shape the incident was born from.
  for (const [cmd, label] of [
    ["git worktree add nested-wt2", "relative path (the incident verb)"],
    ["git worktree add ./nested-wt3 -b b3", "explicit ./-relative path"],
    [`git worktree add ${join(hub, "nested-abs")} -b b4`, "absolute path inside the checkout"],
  ]) {
    const reason = nestedWorktreeTargetViolation(cmd, hub);
    expectTrue(`A7: REFUSED — ${label}`, typeof reason === "string" && reason.includes("#1919"), String(reason));
  }

  // A8: a flag's VALUE is not the path (value-aware parse) — `-b <branch>` must
  // not be mistaken for the target, and the target is judged.
  expectTrue("A8: `-b <branch>` is parsed as a flag, not as the path",
    typeof nestedWorktreeTargetViolation("git worktree add -b feat-ok nested-wt4", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add -b feat-ok nested-wt4", hub)));
  expect("A8: `git worktree add -b feat-ok .worktrees/wt-ok` (IGNORED path) is ALLOWED",
    nestedWorktreeTargetViolation("git worktree add -b feat-ok .worktrees/wt-ok", hub), null);
  expect("A8: `git worktree add --reason x --lock nested-wt5` refuses on the PATH, not on `x`",
    typeof nestedWorktreeTargetViolation("git worktree add --lock --reason because nested-wt5", hub), "string");
  expect("A8: a target OUTSIDE the checkout is ALLOWED",
    nestedWorktreeTargetViolation(`git worktree add ${outside} -b feat-out`, hub), null);
  expect("A8: `..`-relative out of the checkout is ALLOWED",
    nestedWorktreeTargetViolation("git worktree add ../outside-2 -b feat-out2", hub), null);

  // A9: `worktree add|move` only — every other worktree form is untouched.
  for (const cmd of ["git worktree list", "git worktree prune", "git status", "git log --oneline -1",
    "echo \"git worktree add nested-wt\""]) {
    expect(`A9: not refused — \`${cmd}\``, nestedWorktreeTargetViolation(cmd, hub), null);
  }
  // A9c (#1919 review cycle 2 P1): a target that is ONLY an unassigned variable
  // is REFUSED, not silently waved through. Nothing proves it lands outside every
  // checkout, and treating "cannot resolve" as "not judged" is what let
  // `git worktree add ./wt-$UNSET` create the deadlock inside the hub. The
  // sanctioned route never spells it this way (hub-worktree.sh resolves the path
  // in the script, where this command-level gate does not look).
  expectTrue("A9c: a bare `$VAR` target is REFUSED (cannot be proven outside)",
    typeof nestedWorktreeTargetViolation('git worktree add "$WT" -b feat-var', hub) === "string",
    String(nestedWorktreeTargetViolation('git worktree add "$WT" -b feat-var', hub)));
  // A9b: `move`'s target is the SECOND positional.
  expectTrue("A9b: `worktree move <wt> <inside-path>` is REFUSED",
    typeof nestedWorktreeTargetViolation("git worktree move nested-wt relocated-inside", hub) === "string");
  expect("A9b: `worktree move <wt> <outside-path>` is ALLOWED",
    nestedWorktreeTargetViolation(`git worktree move nested-wt ${join(tmp, "moved-out")}`, hub), null);

  // A10: each invocation is judged in its OWN frame (`cd` chain + `-C`).
  expectTrue("A10: `cd <hub> && git worktree add nested` is judged at the hub",
    typeof nestedWorktreeTargetViolation(`cd ${hub} && git worktree add cd-nested`, tmp) === "string");
  expectTrue("A10: `git -C <hub> worktree add nested` is judged at the hub",
    typeof nestedWorktreeTargetViolation(`git -C ${hub} worktree add c-nested`, tmp) === "string");
  expect("A10: the same command run elsewhere is ALLOWED",
    nestedWorktreeTargetViolation(`cd ${tmp} && git worktree add outside-3 -b feat-3`, tmp), null);

  // A11: the refusal is a REASON, not a silent no-op — it names the target, the
  // checkout, and a route that works.
  const reason = nestedWorktreeTargetReason("worktree", ["add", "nested-wt9"], hub) ?? "";
  expectTrue("A11: the reason names the resolved target", reason.includes(join(hub, "nested-wt9")), reason.slice(0, 120));
  expectTrue("A11: …the checkout it would land in", reason.includes(hub), reason.slice(0, 120));
  expectTrue("A11: …and the sanctioned route", reason.includes("hub-worktree.sh"), reason.slice(0, 120));
  expectTrue("A11: …and the escape hatch", reason.includes("AGENT_ALLOW_MAIN_EDITS=1"), reason.slice(0, 120));

  // A12 (#1919 review P2): an untracked SYMLINK that points AT a registered
  // worktree is ordinary hub dirt. The exclusion compares the entry as SPELLED
  // and realpaths only its PARENT; resolving the leaf made the link
  // indistinguishable from the worktree, so the hub read CLEAN while
  // `git status` still reported it (a false PASS of the gate under repair).
  execSync("ln -s nested-wt link-to-nested", { cwd: hub });
  const porcelain12 = out("git status --porcelain", hub);
  expectTrue("A12: git reports the symlink as its own untracked entry",
    porcelain12.split("\n").includes("?? link-to-nested"), JSON.stringify(porcelain12));
  expect("A12: …and it IS hub dirt (a link is not a worktree)", readHubDisorder(hub).disorder, "dirty");
  expect("A12: …while the registered worktree BESIDE it is still not counted",
    porcelainWithoutRegisteredWorktrees(porcelain12, hub).split("\n").filter((l) => l.length > 0).join("|"),
    "?? link-to-nested");
  rmSync(join(hub, "link-to-nested"));
  expect("A12: …and the hub reads clean again once the link is gone", readHubDisorder(hub).disorder, null);

  // A13 (#1919 review P2): a PRUNABLE record is NOT a worktree. Writing a hand-
  // built registration (a `.git` link removed) leaves git listing it as
  // `worktree …` + `prunable gitdir file points to non-existent location`, and
  // its files become ordinary untracked content the hub COULD commit. Excluding
  // it made a genuine untracked directory read CLEAN.
  mkdirSync(join(hub, "prunable-wt"), { recursive: true });
  writeFileSync(join(hub, "prunable-wt", "precious.txt"), "wip\n");
  writeFileSync(join(hub, "prunable-wt", ".git"), `gitdir: ${join(hub, ".git", "worktrees", "prunable-wt")}\n`);
  mkdirSync(join(hub, ".git", "worktrees", "prunable-wt"), { recursive: true });
  writeFileSync(join(hub, ".git", "worktrees", "prunable-wt", "gitdir"), `${join(hub, "prunable-wt", ".git")}\n`);
  rmSync(join(hub, "prunable-wt", ".git"));   // the link is GONE → prunable
  expectTrue("A13: git reports the record as PRUNABLE",
    out("git worktree list --porcelain", hub).includes("prunable"), out("git worktree list --porcelain", hub));
  expect("A13: …so its directory is real untracked content → DIRTY", readHubDisorder(hub).disorder, "dirty");
  expect("A13: …and the filter keeps the entry",
    porcelainWithoutRegisteredWorktrees(out("git status --porcelain", hub), hub).includes("?? prunable-wt/"),
    true);
  gg("worktree prune", hub);
  rmSync(join(hub, "prunable-wt"), { recursive: true, force: true });
  expect("A13: …and the hub is clean again after the prune", readHubDisorder(hub).disorder, null);

  // A14 (#1919 review P1): a SHELL-VARIABLE target is expanded from the command's
  // own assignment — `D=q7; git worktree add "$D/wt"` used to be ALLOWED and
  // re-created the deadlock — while a variable nothing assigns is still NOT
  // guessed (A9 pins that direction: a false block is not the remedy).
  const varAssign = 'D=q7; git worktree add "$D/wt" -b q7';
  expectTrue("A14: an assignment-spelled `$VAR` target is REFUSED",
    typeof nestedWorktreeTargetViolation(varAssign, hub) === "string", String(nestedWorktreeTargetViolation(varAssign, hub)));
  expectTrue("A14: …`$PWD`-relative target is REFUSED",
    typeof nestedWorktreeTargetViolation('git worktree add "$PWD/v6" -b v6', hub) === "string",
    String(nestedWorktreeTargetViolation('git worktree add "$PWD/v6" -b v6', hub)));
  expect("A14: …and a var-assigned target OUTSIDE the checkout is still ALLOWED",
    nestedWorktreeTargetViolation(`D=${outside}; git worktree add "$D/wt" -b ok`, hub), null);

  // A15 (#1919 review P2): the target is judged PHYSICALLY. A path spelled through
  // a symlinked prefix that points INTO the hub compared as "outside" lexically
  // while landing inside — the same mistake the exclusion side fixed.
  const linkPrefix = join(tmp, "link-into-hub");
  execSync(`ln -s ${hub} ${linkPrefix}`);
  expectTrue("A15: a target through a symlinked prefix INTO the hub is REFUSED",
    typeof nestedWorktreeTargetViolation(`git worktree add ${linkPrefix}/sneaky -b s1`, hub) === "string",
    String(nestedWorktreeTargetViolation(`git worktree add ${linkPrefix}/sneaky -b s1`, hub)));
  rmSync(linkPrefix);

  // A16 (#1919 review cycle 2 P1): an UNEXPANDABLE variable in the TARGET is
  // judged by its literal prefix. `./wt-$UNSET` can land inside the hub and is
  // REFUSED (it was ALLOWED and created `?? wt-/`, which is the issue's state),
  // while the sanctioned IGNORED layout and an absolute outside path still pass.
  expectTrue("A16: `git worktree add ./wt-$UNSET` is REFUSED",
    typeof nestedWorktreeTargetViolation("git worktree add ./wt-$UNSET_1941 -b a1", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add ./wt-$UNSET_1941 -b a1", hub)));
  expectTrue("A16: …`${UNSET}deep/inner` (the TWO-LEVEL deadlock) is REFUSED",
    typeof nestedWorktreeTargetViolation("git worktree add ${UNSET_1941}deep/inner -b a2", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add ${UNSET_1941}deep/inner -b a2", hub)));
  expect("A16: …while `.worktrees/wt-$UNSET` (IGNORED layout) is ALLOWED",
    nestedWorktreeTargetViolation("git worktree add .worktrees/wt-$UNSET_1941 -b a3", hub), null);
  expect("A16: …and an absolute target outside every checkout is ALLOWED",
    nestedWorktreeTargetViolation(`git worktree add ${outside}/wt-$UNSET_1941 -b a4`, hub), null);

  // A17 (#1919 review cycle 2 P2): an unplaceable frame must NOT blanket-refuse
  // the sanctioned IGNORED layout — `cd $UNSET && git worktree add .worktrees/x`
  // would really run in the hub, and `.worktrees/` is where the fleet puts them.
  expect("A17: unplaceable frame + `.worktrees/<name>` is ALLOWED",
    nestedWorktreeTargetViolation("cd $UNSET_1941 && git worktree add .worktrees/br9 -b br9", hub), null);
  expect("A17: unplaceable frame + an absolute OUTSIDE target is ALLOWED",
    nestedWorktreeTargetViolation(`cd $UNSET_1941 && git worktree add ${outside}/br10 -b br10`, hub), null);

  // A18 (#1919 review cycle 3 P1): porcelain v1 paths are ROOT-relative, so the
  // exclusion must never try a CWD base. From a hub SUBDIRECTORY the CWD base
  // mapped a genuine entry into the registered worktree's path and dropped it:
  // `readHubDisorder` reported CLEAN on a dirty hub.
  mkdirSync(join(hub, "sub"), { recursive: true });
  writeFileSync(join(hub, "sub", "s.txt"), "s\n");
  // NOTE: stage the file explicitly, never `add -A` — the hub holds a nested
  // worktree here and `add -A` would record it as a gitlink and end the fixture.
  gg("add sub/s.txt", hub);
  gg("commit -qm sub", hub);
  gg("worktree add -q sub/x -b subx-br", hub);
  mkdirSync(join(hub, "x"), { recursive: true });
  writeFileSync(join(hub, "x", "GENUINE-WIP.txt"), "wip\n");
  const porcelain18 = out("git status --porcelain", hub);
  expectTrue("A18: fixture has BOTH the worktree and genuine dirt at root level",
    porcelain18.includes("?? sub/x/") && porcelain18.includes("?? x/"), JSON.stringify(porcelain18));
  expect("A18: from the hub ROOT → DIRTY (genuine dirt counted)", readHubDisorder(hub).disorder, "dirty");
  expect("A18: from the hub SUBDIRECTORY → DIRTY too (root-relative porcelain)",
    readHubDisorder(join(hub, "sub")).disorder, "dirty");
  expect("A18: …and the filter drops ONLY the worktree entry, from either frame",
    porcelainWithoutRegisteredWorktrees(porcelain18, join(hub, "sub")).split("\n").filter((l) => l.length > 0).join("|"),
    "?? x/");
  rmSync(join(hub, "x"), { recursive: true, force: true });
  gg("worktree remove --force sub/x", hub);
  gg("branch -D subx-br", hub);

  // A19 (#1919 review cycle 3 P1): a QUOTED `~` target is not shell-expanded, so
  // git creates a literal `<cwd>/~/wt` INSIDE the checkout. Treating every tilde
  // target as unjudged let that through; the unquoted spelling lands in $HOME and
  // must stay allowed.
  expectTrue("A19: `git worktree add '~/wt'` (literal tilde dir) is REFUSED",
    typeof nestedWorktreeTargetViolation("git worktree add '~/wt' -b t1", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add '~/wt' -b t1", hub)));
  // The UNQUOTED spelling is the same token after quote-stripping, so it is
  // refused too (declare the accepted false block: the two readings cannot be
  // told apart). `$HOME/wt` — the spelling a lane can actually rely on — is
  // expanded and judged for what it is, so the outside-home case stays open.
  expectTrue("A19: the same token unquoted is refused as well (readings indistinguishable)",
    typeof nestedWorktreeTargetViolation("git worktree add ~/wt -b t2", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add ~/wt -b t2", hub)));
  expect("A19: …while `$HOME/wt` is expanded and ALLOWED when it is outside",
    nestedWorktreeTargetViolation('git worktree add "$HOME/wt" -b t3', hub), null);

  // A20 (#1919 review cycle 3 P1): git accepts any UNAMBIGUOUS long-option
  // prefix. `--reaso /tmp/decoy nested` made the DECOY the judged target (the
  // real one, `nested`, was created inside the hub).
  expectTrue("A20: `--reaso <decoy> nested` is REFUSED on the REAL target",
    typeof nestedWorktreeTargetViolation("git worktree add --lock --reaso /tmp/decoy nested -b t3", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add --lock --reaso /tmp/decoy nested -b t3", hub)));
  expect("A20: …and the exact spelling `--reason <x> <outside>` is ALLOWED",
    nestedWorktreeTargetViolation(`git worktree add --lock --reason x ${outside}/t4 -b t4`, hub), null);

  // A21 (#1919 review cycle 3 P2): a non-ASCII worktree name is C-QUOTED by git
  // unless `core.quotepath=false`, and a quoted spelling never matches a record —
  // so the hub read DIRTY forever (the #1919 deadlock for those names).
  gg("worktree add -q café-wt -b cafe-br", hub);
  expectTrue("A21: git reports the non-ASCII worktree (quoted or not)",
    out("git -c core.quotepath=false status --porcelain", hub).includes("caf"), out("git status --porcelain", hub));
  expect("A21: …and it is NOT hub dirt", readHubDisorder(hub).disorder, null);
  gg("worktree remove --force café-wt", hub);
  gg("branch -D cafe-br", hub);

  // A22 (#1919 review cycle 4 P2): a `worktree add` whose path arrives at RUN
  // TIME has no static target to judge — `printf 'e\n' | xargs git -C <hub>
  // worktree add -b e` was ALLOWED and created the worktree inside the hub.
  // git errors on a genuinely targetless `add`, so refusing costs nothing real.
  expectTrue("A22: `xargs git worktree add` (no static target) is REFUSED",
    typeof nestedWorktreeTargetViolation(`printf 'e\\n' | xargs git -C ${hub} worktree add -b e`, hub) === "string",
    String(nestedWorktreeTargetViolation(`printf 'e\\n' | xargs git -C ${hub} worktree add -b e`, hub)));
  expect("A22: …while a VAR-less `worktree list` through xargs is untouched",
    nestedWorktreeTargetViolation("printf 'x' | xargs git worktree list", hub), null);

  // A23 (#1919 final review P1): a `cd` into a directory the command CREATES is
  // judged in the TRUNCATED frame by walker cd semantics, so the real target went
  // unchecked: `mkdir -p <hub>/area && cd <hub>/area && git worktree add
  // ../cont/inner` was ALLOWED and re-created the deadlock. BOTH readings are
  // judged now.
  expectTrue("A23: mkdir-then-cd-then-add (container target) is REFUSED",
    typeof nestedWorktreeTargetViolation(`mkdir -p ${hub}/area && cd ${hub}/area && git worktree add ../cont/inner -b iw`, hub) === "string",
    String(nestedWorktreeTargetViolation(`mkdir -p ${hub}/area && cd ${hub}/area && git worktree add ../cont/inner -b iw`, hub)));
  expectTrue("A23: …and the plain single-level spelling is refused too",
    typeof nestedWorktreeTargetViolation("mkdir -p .worktrees && cd .worktrees && git worktree add ../wt-x -b wx", hub) === "string",
    String(nestedWorktreeTargetViolation("mkdir -p .worktrees && cd .worktrees && git worktree add ../wt-x -b wx", hub)));
  expect("A23: …an EXISTING cd frame behaves as before (ignored layout stays allowed)",
    nestedWorktreeTargetViolation(`cd ${hub} && git worktree add .worktrees/ok-cd -b okcd`, hub), null);

  // ───────────────────────────────────────────────────────────────────────
  // Part B — real index.ts load + handler-driven gate
  // ───────────────────────────────────────────────────────────────────────
  console.log("\n── Part B: real index.ts load + handler-driven gates ──");

  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("B: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  } else {
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
    expect("B1: index.ts loads with no degradation warning", degradation.length, 0);
    expectTrue("B2: default export is a factory", typeof mod.default === "function", typeof mod.default);

    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    expectTrue("B3: factory registered a tool_call handler", typeof toolCall === "function", "none");

    const home = join(tmp, "home");
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    const envKeys = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"];
    const savedEnv = new Map(envKeys.map((v) => [v, process.env[v]]));
    for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
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
    const reasonOf = (r) => String(r?.reason ?? "");

    try {
      // B4: the creation refusal at the HANDLER (not just the classifier).
      const r4 = await bash("git worktree add nested-wt2 -b nested-br2", hub);
      expectTrue("B4: `git worktree add <relative path>` in a clean hub → BLOCKED", blocked(r4), JSON.stringify(r4?.reason?.slice(0, 90)));
      expectTrue("B4: …the reason is the #1919 refusal", reasonOf(r4).includes("#1919"), reasonOf(r4).slice(0, 90));

      // B5: the sanctioned forms still pass — the fleet's own layout AND a path
      // outside the repo. Without these, the refusal would be a false block on
      // the workflow this repo depends on.
      const r5a = await bash("git worktree add -b feat-ok .worktrees/wt-ok", hub);
      expectTrue("B5: `git worktree add .worktrees/<name>` (gitignored) → ALLOWED", allowed(r5a), reasonOf(r5a).slice(0, 120));
      // …and it really works: run it and the hub must stay CLEAN (that is the
      // property the sanctioned layout exists for).
      gg("worktree add -q -b feat-ok2 .worktrees/wt-ok2", hub);
      expect("B5: …an ignored nested worktree leaves the hub CLEAN", readHubDisorder(hub).disorder, null);
      gg("worktree remove --force .worktrees/wt-ok2", hub);
      const r5b = await bash(`git worktree add ${outside} -b feat-out`, hub);
      expectTrue("B5: `git worktree add <path outside the repo>` → ALLOWED", allowed(r5b), reasonOf(r5b).slice(0, 120));

      // B6: the incident state, end to end. `nested-wt` exists (created in Part A
      // by raw git, exactly as the lane did it) and is the ONLY thing git reports.
      expectTrue("B6: git still reports the nested worktree",
        out("git status --porcelain", hub).includes("?? nested-wt/"), JSON.stringify(out("git status --porcelain", hub)));
      const moveCmd = `git worktree move nested-wt ${join(tmp, "nested-wt-moved")}`;
      const r6 = await bash(moveCmd, hub);
      expectTrue("B6: …the hub is not DIRTY for it, so `git worktree move` out is ALLOWED", allowed(r6), reasonOf(r6).slice(0, 120));

      // B7: THE SAFETY HALF at the handler — a genuine untracked file puts the
      // same command back under M4.
      writeFileSync(join(hub, "genuine-untracked.txt"), "wip\n");
      const r7 = await bash(moveCmd, hub);
      expectTrue("B7: genuine untracked file → the SAME command BLOCKED", blocked(r7), JSON.stringify(r7));
      expectTrue("B7: …by the hub-state gate, naming M4",
        reasonOf(r7).includes("Hub-state gate (M4)"), reasonOf(r7).slice(0, 120));
      rmSync(join(hub, "genuine-untracked.txt"));

      // B8: …and tracked dirt counts too (only `?? ` entries are ever excluded).
      writeFileSync(join(hub, "a.txt"), "v3\n");
      const r8 = await bash(moveCmd, hub);
      expectTrue("B8: tracked modification → the SAME command BLOCKED", blocked(r8), JSON.stringify(r8));
      gg("checkout -- a.txt", hub);

      // B11 (#1919 review P1): the refusal cannot be SPELLED around. The
      // handler's cheap pre-filter was a literal `command.includes("worktree")`;
      // shell quoting (`work"tree"`) reaches git as the same verb and slipped
      // past it, so the nested worktree was created and the hub deadlocked —
      // exactly the issue's state. The pre-filter is gone; the classifier decides.
      const r11 = await bash('git work"tree" add nested-quoted -b nested-quoted', hub);
      expectTrue("B11: `git work\"tree\" add <relative path>` → BLOCKED", blocked(r11), JSON.stringify(r11?.reason?.slice(0, 90)));
      expectTrue("B11: …with the #1919 refusal", reasonOf(r11).includes("#1919"), reasonOf(r11).slice(0, 90));
      expectTrue("B11: …and the state was never created", !existsSync(join(hub, "nested-quoted")), "created");

      // B12 (#1919 review P1): an invocation whose frame cannot be placed is no
      // longer skipped when its target is RELATIVE. `cd $UNRESOLVABLE && git
      // worktree add v1` starts in an undeterminable directory and this session
      // is inside a checkout, so the target can land inside it.
      const r12 = await bash("cd $NOPE_UNSET_1941 && git worktree add v1 -b v1", hub);
      expectTrue("B12: `cd $UNASSIGNED && git worktree add <rel>` → BLOCKED", blocked(r12), JSON.stringify(r12?.reason?.slice(0, 90)));
      expectTrue("B12: …saying the frame could not be placed", reasonOf(r12).includes("cannot be resolved (execution directory)"), reasonOf(r12).slice(0, 120));

      // B13 (#1919 review P1): a shell-variable target the command ASSIGNS.
      const r13 = await bash('D=q7; git worktree add "$D/wt" -b q7', hub);
      expectTrue("B13: assignment-spelled `$VAR` target → BLOCKED", blocked(r13), JSON.stringify(r13?.reason?.slice(0, 90)));
      expectTrue("B13: …with the #1919 refusal", reasonOf(r13).includes("#1919"), reasonOf(r13).slice(0, 90));

      // B14: the env-spelled frame is RESOLVED, not skipped — `cd $HUBX` with HUBX
      // exported must be judged at the hub and refused (it was a one-env-var bypass).
      process.env.HUBX_1941 = hub;
      const r14 = await bash("cd $HUBX_1941 && git worktree add v3 -b v3", hub);
      expectTrue("B14: `cd $EXPORTED && git worktree add <rel>` → BLOCKED", blocked(r14), JSON.stringify(r14?.reason?.slice(0, 90)));
      const r14b = await bash("git -C $HUBX_1941 worktree add v4 -b v4", hub);
      expectTrue("B14: `git -C $EXPORTED worktree add <rel>` → BLOCKED", blocked(r14b), JSON.stringify(r14b?.reason?.slice(0, 90)));
      delete process.env.HUBX_1941;

      // B15 (#1919 review cycle 4 P1): `$PWD` must be the INVOCATION's frame, not
      // the session's. `vars` is seeded from the process env, so the env PWD
      // overrode the frame and `cd <hub> && git worktree add "$PWD/x"` was
      // ALLOWED, creating the worktree inside the hub.
      const r15 = await bash(`cd ${hub} && git worktree add "$PWD/esc-pwd" -b escp`, hub);
      expectTrue("B15: `cd <hub> && git worktree add \"$PWD/x\"` → BLOCKED", blocked(r15), JSON.stringify(r15?.reason?.slice(0, 90)));

      // B16 (#1919 final review P2): a DOCUMENT that merely QUOTES the incident's
      // line is not an attempt to run it. Writing a note/README/plan containing
      // `git worktree add 8779-optA` was BLOCKED and named a worktree that does
      // not exist; heredoc BODIES are masked now. A real command AFTER the
      // heredoc is still judged.
      const doc = `cat > ${join(hub, "note.md")} <<'EOF'\nNever run: git worktree add 8779-optA\nEOF`;
      const r16 = await bash(doc, hub);
      expectTrue("B16: a heredoc BODY quoting the command → ALLOWED (it is data)", allowed(r16), reasonOf(r16).slice(0, 120));
      const r16b = await bash(`cat > ${join(hub, "n2.md")} <<'EOF'\nprose\nEOF\ngit worktree add nested-after-doc -b nad`, hub);
      expectTrue("B16: …but a REAL invocation after the heredoc is still BLOCKED", blocked(r16b), JSON.stringify(r16b?.reason?.slice(0, 90)));

      // B9: the env hatch still bypasses the new gate (documented in its reason).
      process.env.AGENT_ALLOW_MAIN_EDITS = "1";
      const r9 = await bash("git worktree add nested-hatched -b nested-hatched", hub);
      expectTrue("B9: AGENT_ALLOW_MAIN_EDITS=1 bypasses the refusal (escape hatch intact)", allowed(r9), reasonOf(r9).slice(0, 120));
      delete process.env.AGENT_ALLOW_MAIN_EDITS;

      // B10: the fix touched no git state — the worktree is still registered and
      // usable, and the nested branches are untouched.
      expectTrue("B10: the nested worktree is still registered",
        out("git worktree list --porcelain", hub).includes(join(hub, "nested-wt")), out("git worktree list", hub));
    } finally {
      for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
      rmSync(tmp, { recursive: true, force: true });
    }
  }
} catch (e) {
  // A thrown fixture/git error must be a FAILURE, never a silent skip.
  console.log(`❌ unexpected error: ${e && e.stack ? e.stack : String(e)}`);
  fail++;
  try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best effort */ }
}

console.log(`\ntest-nested-worktree: ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""}`);
process.exit(fail === 0 ? 0 : 1);
