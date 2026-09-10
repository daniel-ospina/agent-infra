// Git-freshness drift guard (#178/#179) — Branch Gate source assertions +
// real-git runtime fixtures.
//
// #626: the freshness guarantee MOVED. The Branch Gate no longer creates a
// branch in the hub at all — post-#615/#626 an in-hub flip is blocked, so the
// gate refuses and hands off to the worktree helper. The old owner of
// #178/#179 (origin/HEAD detection, fetch-before-branch, last-known-ref
// fallback, fail-closed abort) is now:
//   scripts/checkout-hygiene/hub-worktree.sh CREATE MODE
//     - fetches origin main, then `worktree add -b <branch> origin/main`
//       (never stale local main), under `set -euo pipefail` → a failed fetch
//       aborts with no worktree and no hub change (fail-closed).
// This file pins BOTH halves:
//   - skills/issue-workflow/SKILL.md's Branch Gate: no executable branch
//     creation, exit 1 + worktree guidance on the hub / detached / wrong-issue
//     paths;
//   - the helper: fetch → worktree-add-from-origin ordering + fail-closure,
//     plus runtime fixtures proving the fresh tip and the fail-closed abort.
//
// #181 APPENDS its assertion blocks (commit-workflow freshness + stale-merge
// recovery) to this file — do not restructure the module shape without #181.
//
// Run: node extensions/shared/test-git-freshness.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}

const TMP_DIRS = [];
function tmpRepo(name) {
  const dir = mkdtempSync(join(tmpdir(), `gf-${name}-`));
  TMP_DIRS.push(dir);
  return dir;
}
function sh(cmd, cwd) {
  return execSync(cmd, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] });
}
function runGate(cwd) {
  const scriptPath = join(cwd, ".gate.sh");
  writeFileSync(scriptPath, gateScript);
  try {
    const out = execSync(`bash .gate.sh`, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status ?? 1, out: `${e.stdout ?? ""}${e.stderr ?? ""}` };
  }
}
/**
 * Run the helper's extracted CREATE-MODE freshness sequence in `mainRepo`.
 * `set -euo pipefail` mirrors the helper — it is what makes a failed fetch
 * fail-closed instead of silently branching from a stale ref.
 */
function runCreatePath({ mainRepo, wtPath, branch }) {
  const scriptPath = join(mainRepo, ".create.sh");
  writeFileSync(scriptPath,
    `set -euo pipefail\nMAIN_REPO=${JSON.stringify(mainRepo)}\nWT_PATH=${JSON.stringify(wtPath)}\nBRANCH=${JSON.stringify(branch)}\n${createFreshScript}\n`);
  try {
    const out = execSync(`bash .create.sh`, { cwd: mainRepo, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status ?? 1, out: `${e.stdout ?? ""}${e.stderr ?? ""}` };
  }
}
/** bare origin + clone; returns {origin, clone}. Clone sits on `main`. */
function makeStaleFixture(name) {
  const base = tmpRepo(name);
  const origin = join(base, "origin.git");
  const clone = join(base, "clone");
  sh(`git init --bare -b main "${origin}"`, base);
  sh(`git clone "${origin}" clone`, base);
  sh("git config user.email t@t && git config user.name t", clone);
  writeFileSync(join(clone, "a.txt"), "base\n");
  sh("git add a.txt && git commit -qm base", clone);
  sh("git push -q origin main", clone);
  // advance origin from a second clone → first clone's local main is now STALE
  const other = join(base, "other");
  sh(`git clone "${origin}" other`, base);
  sh("git config user.email t@t && git config user.name t", other);
  writeFileSync(join(other, "b.txt"), "fresh\n");
  sh("git add b.txt && git commit -qm fresh && git push -q origin main", other);
  return { base, origin, clone, other };
}

// ── Source assertions (drift guard) ──────────────────────────────────────
const skill = readFileSync(join(PROJECT_ROOT, "skills/issue-workflow/SKILL.md"), "utf8");
// #626: the helper is now the owner of the #178/#179 freshness contract.
const hubWt = readFileSync(join(PROJECT_ROOT, "scripts/checkout-hygiene/hub-worktree.sh"), "utf8");

// Extract the Branch Gate bash block verbatim from the skill.
const gateMatch = skill.match(/### 1\. Branch Gate[\s\S]*?```bash\n([\s\S]*?)```/);
check("Branch Gate bash block extractable from SKILL.md", !!gateMatch);
const gateScript = gateMatch ? gateMatch[1] : "";

// Extract the helper's CREATE-MODE freshness sequence verbatim.
const CREATE_FRESHNESS_RE =
  /echo "hub-worktree: fetching origin main…"\ngit -C "\$MAIN_REPO" fetch origin main --quiet\n\necho "hub-worktree: creating \$WT_PATH[^\n]*\ngit -C "\$MAIN_REPO" worktree add "\$WT_PATH" -b "\$BRANCH" origin\/main/;
const createMatch = hubWt.match(CREATE_FRESHNESS_RE);
const createFreshScript = createMatch ? createMatch[0] : "";
check("helper create-mode freshness block extractable", !!createMatch);

// Gate side: NO executable branch creation may survive (#626 — in-hub is blocked).
check("gate has no executable `git checkout -b` / `git switch -c` line",
  !!gateScript && !/^\s*git\s+(checkout|switch)\s+[^\n]*(-[bBcC]|--create|--force-create|--orphan)/m.test(gateScript));
check("gate documents the in-hub block rather than performing it (#626)",
  gateScript.includes("#626") && /In-hub/i.test(gateScript));
check("gate hub path EXITS non-zero (never a false 'created' success)",
  /if \[ "\$CURRENT_BRANCH" = "main" \] \|\| \[ "\$CURRENT_BRANCH" = "master" \]; then[\s\S]*?exit 1/.test(gateScript));
check("gate hub advisory names the one-command worktree helper",
  gateScript.includes('bash scripts/checkout-hygiene/hub-worktree.sh "$EXPECTED_BRANCH"'));
check("gate no longer detects the default branch via origin/HEAD (helper owns it)",
  !gateScript.includes("symbolic-ref --short refs/remotes/origin/HEAD") && !gateScript.includes('DEFAULT_BRANCH="main"'));
check("gate detached-HEAD path points at the worktree helper",
  gateScript.includes("Detached HEAD") && gateScript.includes("hub-worktree.sh"));
check("gate different-issue path points at the worktree helper",
  gateScript.includes("belongs to a DIFFERENT issue") && gateScript.includes("hub-worktree.sh"));

// Helper side: fetch → worktree-from-origin, fail-closed.
check("helper fetches origin main before creating the worktree",
  hubWt.includes('git -C "$MAIN_REPO" fetch origin main --quiet'));
check("helper creates the worktree branch FROM origin/main (never HEAD/local main)",
  hubWt.includes('git -C "$MAIN_REPO" worktree add "$WT_PATH" -b "$BRANCH" origin/main'));
check("helper fetches BEFORE the worktree add (ordering pinned)",
  hubWt.indexOf('git -C "$MAIN_REPO" fetch origin main --quiet') < hubWt.indexOf('worktree add "$WT_PATH" -b "$BRANCH" origin/main'));
check("helper is fail-closed on fetch failure (`set -euo pipefail`)",
  hubWt.includes("set -euo pipefail"));

// F1: Branch Gate run in a stale hub → refuses, creates nothing, hub untouched
{
  const { clone } = makeStaleFixture("stale");
  const staleHead = sh("git rev-parse HEAD", clone).trim();
  const r = runGate(clone);
  const branch = sh("git branch --show-current", clone).trim();
  check("F1 gate REFUSES the hub run (exit 1)", r.code === 1, r.out);
  check("F1 advisory names the worktree helper", r.out.includes("hub-worktree.sh"), r.out);
  check("F1 no branch created, hub untouched",
    branch === "main" && sh("git rev-parse HEAD", clone).trim() === staleHead, branch);
}

// F2: helper create path on a stale hub → worktree branch at FRESH origin tip
{
  const { base, clone } = makeStaleFixture("fresh");
  const staleHead = sh("git rev-parse HEAD", clone).trim();
  const wt = join(base, "wt");
  const r = runCreatePath({ mainRepo: clone, wtPath: wt, branch: "feat/76-branch-isolation" });
  check("F2 helper create path exits 0 on a stale hub", r.code === 0, r.out);
  if (existsSync(wt)) {
    const tip = sh("git rev-parse HEAD", wt).trim();
    const originTip = sh("git rev-parse origin/main", clone).trim();
    check("F2 worktree branch sits at FRESH origin tip (not stale local main)",
      tip === originTip && tip !== staleHead);
  } else {
    check("F2 worktree branch sits at FRESH origin tip (not stale local main)", false, "worktree not created");
  }
  check("F2 hub left on main (never flipped)",
    sh("git branch --show-current", clone).trim() === "main");
}

// F3: fetch failure → fail-closed (non-zero, no worktree, hub unchanged)
{
  const { base, clone } = makeStaleFixture("offline");
  sh("git remote set-url origin /nonexistent/no-remote", clone);
  const wt = join(base, "wt");
  const r = runCreatePath({ mainRepo: clone, wtPath: wt, branch: "feat/76-branch-isolation" });
  check("F3 fetch failure is fail-closed (non-zero exit, no stale fallback)", r.code !== 0, r.out);
  check("F3 no worktree created on fetch failure", !existsSync(wt));
  check("F3 hub still on main (no partial state)",
    sh("git branch --show-current", clone).trim() === "main");
}

// F4: detached HEAD → gate aborts and names the worktree remedy
{
  const { clone } = makeStaleFixture("detached");
  sh("git checkout -q --detach", clone);
  const r = runGate(clone);
  check("F4 detached HEAD aborts (exit 1)", r.code === 1, r.out);
  check("F4 states the worktree remedy",
    r.out.includes("Detached HEAD") && r.out.includes("hub-worktree.sh"), r.out);
}

// F5: branch already exists → helper create path fails, no false success
{
  const { base, clone } = makeStaleFixture("exists");
  sh("git branch feat/76-branch-isolation", clone); // pre-create → worktree add -b fails
  const wt = join(base, "wt");
  const r = runCreatePath({ mainRepo: clone, wtPath: wt, branch: "feat/76-branch-isolation" });
  check("F5 exit non-zero when the branch already exists", r.code !== 0, r.out);
  check("F5 no worktree created on failure", !existsSync(wt));
  check("F5 hub still on main (no false success)",
    sh("git branch --show-current", clone).trim() === "main");
}

// ── #181 (L3): pre-PR freshness + stale-merge recovery assertions ─────
const preflight = readFileSync(join(PROJECT_ROOT, "skills/commit-workflow/workflow/01-preflight.md"), "utf8");
const mergedeploy = readFileSync(join(PROJECT_ROOT, "skills/commit-workflow/workflow/04-merge-deploy.md"), "utf8");

check("L3 preflight has the Pre-PR Freshness Check section",
  preflight.includes("## Pre-PR Freshness Check (#178/#181)"));
check("L3 freshness step placed AFTER Merged-Branch Guard, BEFORE Tier Detection",
  preflight.indexOf("### Merged-Branch Guard") < preflight.indexOf("## Pre-PR Freshness Check") &&
  preflight.indexOf("## Pre-PR Freshness Check") < preflight.indexOf("## Tier Detection"));
check("L3 computes behind-count vs origin/<default>",
  preflight.includes('git rev-list --count HEAD.."origin/$DEFAULT_BRANCH"'));
check("L3 clean-tree rebase uses gpgsign-off",
  preflight.includes('git -c commit.gpgsign=false pull --rebase origin "$DEFAULT_BRANCH"'));
check("L3 dirty tree → WARN, never autostash",
  preflight.includes("NEVER autostash"));
check("L3 rejected post-rebase push → force-with-lease",
  preflight.includes("git push --force-with-lease"));
check("L3 04-merge-deploy has Stale-Merge Recovery",
  mergedeploy.includes("## Stale-Merge Recovery (#178/#181"));
check("L3 recovery rebases with gpgsign-off",
  mergedeploy.includes('git -c commit.gpgsign=false rebase "origin/$DEFAULT_BRANCH"'));
check("L3 recovery pushes with --force-with-lease (never plain --force)",
  mergedeploy.includes("git push --force-with-lease") &&
  !/git push --force(?!-with-lease)/.test(mergedeploy));
check("L3 recovery bounded (max 2 attempts then escalate)",
  mergedeploy.includes("MAX 2 recovery attempts"));

// F6: runtime — behind+clean feature branch rebases onto fresh origin tip
{
  const { clone, other } = makeStaleFixture("l3rebase");
  sh("git checkout -qb feat/181-work", clone);
  writeFileSync(join(clone, "c.txt"), "feature\n");
  sh("git add c.txt && git commit -qm feature", clone);
  // origin/main advances AFTER the branch was cut
  writeFileSync(join(other, "d.txt"), "newmain\n");
  sh("git add d.txt && git commit -qm newmain && git push -q origin main", other);
  // the mandated command sequence (dirty-checked, gpgsign-off, rebase)
  sh("git fetch origin main --quiet", clone);
  const behind = Number(sh('git rev-list --count HEAD..origin/main', clone).trim());
  check("F6 behind-count detects drift", behind >= 1, `behind=${behind}`);
  sh("git -c commit.gpgsign=false pull --rebase origin main", clone);
  const tip = sh("git rev-parse origin/main", clone).trim();
  const hasTip = sh("git merge-base --is-ancestor origin/main HEAD && echo yes || echo no", clone).trim();
  check("F6 rebase landed the branch on the fresh origin tip", hasTip === "yes", tip);
  const kept = sh("git log --oneline | grep -c feature", clone).trim();
  check("F6 feature commit preserved through rebase", kept === "1");
}

// ── Cleanup + summary ────────────────────────────────────────────────────
for (const dir of TMP_DIRS) {
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
