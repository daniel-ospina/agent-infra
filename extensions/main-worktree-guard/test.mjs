// Regression test for main-worktree-guard path scoping (#5582)
// Run: node operations/pi-config/extensions/main-worktree-guard/test.mjs
// Must be run from the project root.
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";

const PROJECT_CWD = process.cwd();

function guardDecision(targetPath) {
  let mainTopLevel;
  try {
    mainTopLevel = resolve(execSync("git rev-parse --show-toplevel", {encoding:"utf-8",cwd:resolve(PROJECT_CWD),timeout:5000}).trim());
  } catch { return "BLOCK (Git unavailable)"; }
  const resolvedTarget = resolve(PROJECT_CWD, targetPath ?? "");
  const insideProject = resolvedTarget === mainTopLevel || resolvedTarget.startsWith(mainTopLevel + "/");
  if (!insideProject) return "ALLOW (outside project)";
  const targetCwd = targetPath ? dirname(resolvedTarget) : PROJECT_CWD;
  let resolvedCwd = targetCwd;
  try { if (existsSync(targetCwd)) resolvedCwd = realpathSync(targetCwd); } catch {}
  let topLevel;
  try {
    execSync("git rev-parse --git-common-dir", {encoding:"utf-8",cwd:resolvedCwd,timeout:5000}).trim();
    topLevel = execSync("git rev-parse --show-toplevel", {encoding:"utf-8",cwd:resolvedCwd,timeout:5000}).trim();
  } catch { return "BLOCK (Git unavailable)"; }
  if (topLevel === mainTopLevel) return "BLOCK (main checkout)";
  return "ALLOW (worktree)";
}

let pass=0, fail=0;
function check(name, path, expectedContains) {
  const got = guardDecision(path);
  const ok = got.includes(expectedContains);
  console.log(`${ok?"✅":"❌"} ${name}: ${got}`);
  ok ? pass++ : fail++;
}

const MAIN = resolve(execSync("git rev-parse --show-toplevel", {encoding:"utf-8"}).trim());

// main checkout must still be blocked
check("main checkout file", `${MAIN}/src/foo.ts`, "BLOCK (main checkout)");
check("AGENTS.md", `${MAIN}/AGENTS.md`, "BLOCK (main checkout)");

// worktrees allowed — provision a real temp worktree so git toplevel resolves
let wtPath = null;
try {
  const out = execSync(`git worktree add --detach -f "${MAIN}/.worktrees/_guard_test_tmp" HEAD 2>&1`, {encoding:"utf-8"}).trim();
  wtPath = `${MAIN}/.worktrees/_guard_test_tmp`;
  check("worktree file", `${wtPath}/operations/x.ts`, "ALLOW (worktree)");
} catch (e) {
  console.log(`⏭️  worktree case skipped (could not provision: ${String(e.message).slice(0,60)})`);
} finally {
  if (wtPath) {
    try { execSync(`git worktree remove --force "${wtPath}"`, {encoding:"utf-8"}); } catch {}
  }
}
// outside project allowed (the #5582 fix)
check("/tmp file", "/tmp/foo.md", "ALLOW (outside project)");
check("~/.mempalace", "/Users/home/.mempalace/foo.md", "ALLOW (outside project)");
check("~/.pi extension", "/Users/home/.pi/agent/extensions/x.ts", "ALLOW (outside project)");
check("sibling repo", "/Users/home/other/file.ts", "ALLOW (outside project)");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail>0?1:0);
