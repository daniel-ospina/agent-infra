// Git-freshness drift guard (#178/#179) — Branch Gate source assertions +
// real-git runtime fixtures.
//
// Verifies skills/issue-workflow/SKILL.md's Branch Gate:
//   - detects the default branch via origin/HEAD (fallback main)
//   - fetches before branching; fetch failure → WARN + last-known-ref
//     fallback, or ABORT when no origin ref exists
//   - branches from origin/<default> (never stale local main), fail-closed
//   - abort-guidance lines carry fetch-first instructions
//
// #181 APPENDS its assertion blocks (commit-workflow freshness + stale-merge
// recovery) to this file — do not restructure the module shape without #181.
//
// Run: node extensions/shared/test-git-freshness.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}

// ── Source assertions (drift guard) ──────────────────────────────────────
const skill = readFileSync(join(PROJECT_ROOT, "skills/issue-workflow/SKILL.md"), "utf8");

check("gate detects default branch via origin/HEAD",
  skill.includes('git symbolic-ref --short refs/remotes/origin/HEAD'));
check("gate falls back to main when origin/HEAD is unset",
  skill.includes('DEFAULT_BRANCH="main"'));
check("gate fetches the default branch before branching",
  skill.includes('git fetch origin "$DEFAULT_BRANCH" --quiet'));
check("gate branches from origin/<default>, not local main",
  skill.includes('git checkout -b "$EXPECTED_BRANCH" "origin/$DEFAULT_BRANCH"'));
check("gate checkout is fail-closed (no false success)",
  /git checkout -b "\$EXPECTED_BRANCH" "origin\/\$DEFAULT_BRANCH" \|\| \{/.test(skill));
check("fetch failure falls back to last-known origin ref with WARN",
  skill.includes("LAST KNOWN origin/$DEFAULT_BRANCH"));
check("fetch failure without local ref aborts",
  skill.includes("fetch failed and no origin/$DEFAULT_BRANCH ref exists"));
check("detached-HEAD guidance is fetch-first",
  skill.includes("git fetch origin main --quiet && git checkout -b $EXPECTED_BRANCH origin/main"));
check("different-issue guidance is fetch-first (both paths covered)",
  (skill.match(/git fetch origin main --quiet && git checkout -b \$EXPECTED_BRANCH origin\/main/g) || []).length >= 2);

// ── Runtime fixtures — execute the extracted gate block in real repos ────
// Extract the Branch Gate bash block verbatim from the skill.
const gateMatch = skill.match(/### 1\. Branch Gate[\s\S]*?```bash\n([\s\S]*?)```/);
check("Branch Gate bash block extractable from SKILL.md", !!gateMatch);
const gateScript = gateMatch ? gateMatch[1] : "";

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

// F1: stale local main → branch at ORIGIN tip; local main untouched
{
  const { clone } = makeStaleFixture("stale");
  const staleHead = sh("git rev-parse HEAD", clone).trim();
  const r = runGate(clone);
  const branch = sh("git branch --show-current", clone).trim();
  const tip = sh("git rev-parse HEAD", clone).trim();
  const originTip = sh("git rev-parse origin/main", clone).trim();
  const localMain = sh("git rev-parse main", clone).trim();
  check("F1 exit 0 on stale-main gate run", r.code === 0, r.out);
  check("F1 created feat/76-branch-isolation", branch === "feat/76-branch-isolation", branch);
  check("F1 branch sits at FRESH origin tip (not stale local main)", tip === originTip && tip !== staleHead);
  check("F1 local main untouched", localMain === staleHead);
}

// F2: origin/HEAD unset → fallback default (main) still branches fresh
{
  const { clone } = makeStaleFixture("nohead");
  sh("git remote set-head origin -d", clone); // delete refs/remotes/origin/HEAD
  const r = runGate(clone);
  const tip = sh("git rev-parse HEAD", clone).trim();
  const originTip = sh("git rev-parse origin/main", clone).trim();
  check("F2 exit 0 with origin/HEAD unset (fallback main)", r.code === 0, r.out);
  check("F2 branch at origin/main tip via fallback", tip === originTip);
}

// F3: fetch fails but local origin ref exists → WARN + last-known-ref, exit 0
{
  const { clone } = makeStaleFixture("offline");
  const originTip = sh("git rev-parse origin/main", clone).trim();
  sh("git remote set-url origin /nonexistent/no-remote", clone);
  const r = runGate(clone);
  const tip = sh("git rev-parse HEAD", clone).trim();
  check("F3 exit 0 offline with last-known origin ref", r.code === 0, r.out);
  check("F3 warns about LAST KNOWN ref", r.out.includes("LAST KNOWN"), r.out);
  check("F3 branched from last-known origin tip", tip === originTip);
}

// F4: fetch fails AND no origin ref → ABORT exit 1
{
  const dir = tmpRepo("noref");
  sh("git init -b main .", dir);
  sh("git config user.email t@t && git config user.name t", dir);
  sh("git remote add origin /nonexistent/no-remote", dir);
  writeFileSync(join(dir, "a.txt"), "x\n");
  sh("git add a.txt && git commit -qm x", dir);
  const r = runGate(dir);
  check("F4 aborts (exit 1) when fetch fails and no origin ref", r.code === 1, r.out);
  check("F4 states the reason", r.out.includes("fetch failed and no origin/"), r.out);
}

// F5: checkout failure → fail-closed exit 1 (never false success)
{
  const { clone } = makeStaleFixture("exists");
  sh("git branch feat/76-branch-isolation", clone); // pre-create → checkout -b fails
  const r = runGate(clone);
  const branch = sh("git branch --show-current", clone).trim();
  check("F5 exit 1 when branch creation fails", r.code === 1, r.out);
  check("F5 still on main (no false success)", branch === "main", branch);
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
