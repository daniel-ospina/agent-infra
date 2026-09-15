// Bounded-scan regression guard for the infra-verify skill (#1051).
//
// The defect: `find <dir>/` (trailing slash) dereferences a symlinked START
// POINT, and `-P` cannot undo it — the trailing slash is resolved on the
// command line, before `find` ever sees a symlink. A repo that commits
// `templates` (or a skills dir) as a symlink to `/` or `$HOME` therefore turned
// the check's bounded in-checkout enumeration into a filesystem-wide walk that
// could report green over a tree that is not the checkout's `templates/`.
//
// The fix pins the property "the scan stayed inside its boundary": each block
// resolves its start point once through `bounded_root` (physical `pwd -P`) and
// admits it only inside the checkout or `${AGENT_INFRA_PATH}`; an out-of-
// boundary start point is an OFFERED check that FAILS CLOSED, never a silent
// omission and never an unbounded walk.
//
// This suite is BOTH directions, deliberately:
//   * NEGATIVE TWIN — the vulnerable form (`find <dir>/`, and `find -L`) is
//     executed against a sentinel tree outside the fixture and asserted to
//     LEAK. Without this half the fixed-form assertions could pass vacuously
//     (e.g. on a platform where the symlink trap did not exist).
//   * FIXED FORM — the same fixture against the skill's own extracted blocks,
//     asserted to refuse and to emit no path from the sentinel tree.
// The sentinel is a tiny temp tree, never `/`: a test for an unbounded scan
// must not itself be able to trigger the catastrophe it guards (which is also
// why the issue's literal `templates -> /` is modelled as `templates -> <tiny
// fake root>` — a regression in the fixed form would otherwise walk the host).
//
// The blocks are EXTRACTED FROM the shipped SKILL.md and executed in a
// hermetic temp fixture — the same pattern extensions/shared/test-git-freshness.mjs
// uses for the Branch Gate block. Most assertions are on objective path leakage
// and exit status; a few also match the block's own refusal wording, which is
// acceptable only because the refusal is corroborated by a leakage assertion in
// the same case (the wording alone is not load-bearing anywhere).
//
// Runs per-PR via the explicit step in .github/workflows/ci.yml's `verify` job,
// and again post-merge via the `extensions/*/test*.mjs` glob in ci-main.yml
// (that glob alone is post-merge only — the same #708/#744/#709 pattern).
// Plain node, zero deps.
//
// Run: node extensions/shared/test-infra-verify-scan.mjs
import { readFileSync, mkdtempSync, mkdirSync, symlinkSync, writeFileSync, copyFileSync, rmSync, existsSync, renameSync } from "node:fs";
import { join, resolve, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SKILL_PATH = join(PROJECT_ROOT, "skills/post-deploy-verify/infra-verify/SKILL.md");

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}

// ── Extraction ──────────────────────────────────────────────────────────────
const skill = readFileSync(SKILL_PATH, "utf8");
const fences = [...skill.matchAll(/```bash\n([\s\S]*?)```/g)].map((m) => m[1]);
const anchor = (tok) => fences.find((f) => f.includes(tok));

const step1 = anchor("NO_CHECKS_AVAILABLE");
const tvBlock = anchor("template-validity: validated");
const slBlock = anchor("skill-lint: validated");

check("#1051 Step 1 block extractable from SKILL.md", !!step1);
check("#1051 Step 2 template-validity block extractable", !!tvBlock);
check("#1051 Step 2 skill-lint block extractable", !!slBlock);
if (!step1 || !tvBlock || !slBlock) {
  console.log("\ncannot run the behavioural cases without the blocks");
  console.log(`${pass} passed, ${fail} failed`);
  process.exit(1);
}

// ── Harness ─────────────────────────────────────────────────────────────────
const root = mkdtempSync(join(tmpdir(), "infra-verify-scan.")); // physical (macOS /var -> /private/var)
const OUTSIDE = join(root, "outside");     // the sentinel tree the scanner must never reach
const ALLOWED = join(root, "agent-infra"); // stands in for the shared agent-infra checkout

mkdirSync(join(OUTSIDE, "secret"), { recursive: true });
mkdirSync(join(OUTSIDE, "skills", "leaked", "nested"), { recursive: true });
writeFileSync(join(OUTSIDE, "secret.json"), '{"leaked": true}\n');
writeFileSync(join(OUTSIDE, "secret", "inner.json"), '{"leaked": true}\n');
writeFileSync(join(OUTSIDE, "skills", "leaked", "SKILL.md"), "# leaked\n");
mkdirSync(join(ALLOWED, "templates"), { recursive: true });
writeFileSync(join(ALLOWED, "templates", "allowed.json"), '{"ok": true}\n');
mkdirSync(join(ALLOWED, "skills", "infra-verify"), { recursive: true });
copyFileSync(SKILL_PATH, join(ALLOWED, "skills", "infra-verify", "SKILL.md"));

// A deterministic env: AGENT_INFRA_PATH is removed unless a case sets it, so a
// developer's ambient value cannot turn an out-of-boundary case into a pass.
function baseEnv(over = {}) {
  const env = { ...process.env };
  delete env.AGENT_INFRA_PATH;
  return { ...env, ...over };
}

function bash(script, cwd, over) {
  const r = spawnSync("bash", ["-c", script], {
    cwd,
    env: baseEnv(over),
    encoding: "utf8",
    timeout: 60_000,
  });
  return { rc: r.status, out: (r.stdout || "") + (r.stderr || "") };
}

function runBlock(block, cwd, over, extra = "") {
  return bash(block.replace(/<REPO_ROOT>/g, cwd) + (extra ? "\n" + extra : ""), cwd, over);
}

// A fresh fixture repo per case (cheap; avoids cross-case symlink pollution).
let n = 0;
function fixture(setup) {
  const dir = join(root, `case-${n++}`);
  mkdirSync(dir, { recursive: true });
  setup(dir);
  return dir;
}
const isTemplateValidityOffered = (out) => /\btemplate-validity\b/.test(out);
const isSkillLintOffered = (out) => /\bskill-lint\b/.test(out);
const leaksOutside = (out) => out.includes(OUTSIDE) || /\bsecret\.json\b/.test(out) || /\bleaked\b/.test(out);

// ── Negative twin 1: the platform exhibits the trap ─────────────────────────
{
  const dir = fixture((d) => {
    mkdirSync(join(d, "real", "inner"), { recursive: true });
    writeFileSync(join(d, "real", "inner", "a.txt"), "x\n");
    symlinkSync(join(d, "real"), join(d, "link"));
  });
  const withSlash = bash(`find "${dir}/link/" -type f`, dir).out;
  const withoutSlash = bash(`find "${dir}/link" -type f`, dir).out;
  const withH = bash(`find -H "${dir}/link" -type f`, dir).out;
  check("#1051 twin: `find <symlink>/` dereferences the start point (the defect is reproducible here)",
    withSlash.includes("inner/a.txt"), `got ${JSON.stringify(withSlash.trim())}`);
  check("#1051 twin: plain `find <symlink>` does NOT dereference it (the two forms differ)",
    !withoutSlash.includes("inner/a.txt"), `got ${JSON.stringify(withoutSlash.trim())}`);
  check("#1051 twin: `find -H <symlink>` also dereferences it (why `-P` + a physical path, not `-H`)",
    withH.includes("inner/a.txt"), `got ${JSON.stringify(withH.trim())}`);
}

// ── Negative twin 2: the vulnerable template enumeration leaks the sentinel ─
{
  const dir = fixture((d) => symlinkSync(OUTSIDE, join(d, "templates")));
  const vulnerable = bash(`find "${dir}/templates/" -type f`, dir).out;
  check("#1051 twin: the vulnerable `find templates/` reaches files outside the checkout",
    vulnerable.includes("secret.json"), `got ${JSON.stringify(vulnerable.trim())}`);
}

// ── Case A: templates -> out-of-boundary symlink → fails closed ────────────
{
  const dir = fixture((d) => symlinkSync(OUTSIDE, join(d, "templates")));
  const s1 = runBlock(step1, dir);
  check("#1051 A: an out-of-boundary templates/ is OFFERED (never a silent not-offered)",
    s1.rc === 0 && isTemplateValidityOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const tv = runBlock(tvBlock, dir);
  check("#1051 A: template-validity FAILS CLOSED on an out-of-boundary start point",
    tv.rc !== 0, `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
  check("#1051 A: the refusal is explicit (names the boundary)",
    /refusing to scan|outside the checkout/i.test(tv.out), JSON.stringify(tv.out.trim()));
  check("#1051 A: no green is reported over the out-of-boundary tree",
    !/✅/.test(tv.out) && !/validated \d/.test(tv.out), JSON.stringify(tv.out.trim()));
  check("#1051 A: no sentinel path is enumerated or read",
    !leaksOutside(tv.out), JSON.stringify(tv.out.trim()));
}

// ── Case B: templates -> AGENT_INFRA_PATH → the intended symlink case works ─
{
  const dir = fixture((d) => symlinkSync(join(ALLOWED, "templates"), join(d, "templates")));
  const over = { AGENT_INFRA_PATH: ALLOWED };
  const s1 = runBlock(step1, dir, over);
  check("#1051 B: a symlinked templates/ under $AGENT_INFRA_PATH is offered",
    s1.rc === 0 && isTemplateValidityOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const tv = runBlock(tvBlock, dir, over);
  check("#1051 B: the legitimate symlinked templates tree still validates (intended case unaffected)",
    tv.rc === 0 && /validated 1\/1 schema template/.test(tv.out), `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
  const tvSlash = runBlock(tvBlock, dir, { AGENT_INFRA_PATH: ALLOWED + "/" });
  check("#1051 B: a trailing slash on AGENT_INFRA_PATH still resolves the matching subtree",
    tvSlash.rc === 0 && /validated 1\/1 schema template/.test(tvSlash.out),
    `rc=${tvSlash.rc} out=${JSON.stringify(tvSlash.out.trim())}`);
}

// ── Case B2: templates -> a DIFFERENT subtree of the shared tree → refused ─
// The shared-tree allowance is bounded to the matching subtree
// (${AGENT_INFRA_PATH}/templates), not the whole shared checkout: otherwise a
// `templates -> $AGENT_INFRA_PATH` redirect would scan the shared repo's
// unrelated trees (its docs, its .git, …).
{
  const dir = fixture((d) => symlinkSync(join(ALLOWED, "skills"), join(d, "templates")));
  const over = { AGENT_INFRA_PATH: ALLOWED };
  const tv = runBlock(tvBlock, dir, over);
  check("#1051 B2: a start point redirected at a non-matching shared subtree is refused",
    tv.rc !== 0 && !/✅/.test(tv.out) && /refusing to scan/i.test(tv.out),
    `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
}

// ── Case C: real templates dir → unchanged happy path ──────────────────────
{
  const dir = fixture((d) => {
    mkdirSync(join(d, "templates"));
    writeFileSync(join(d, "templates", "ok.json"), '{"a": 1}\n');
  });
  const tv = runBlock(tvBlock, dir);
  check("#1051 C: a real templates/ still validates (physical-path enumeration is equivalent)",
    tv.rc === 0 && /validated 1\/1 schema template/.test(tv.out), `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
}

// ── Case D: symlinked skills dir under AGENT_INFRA_PATH → still offered ────
// #1035 verification case (i): "a symlinked resolved skills dir -> skill-lint
// still offered and lints its target".
{
  const dir = fixture((d) => {
    symlinkSync(join(ALLOWED, "skills"), join(d, "skills"));
    symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
  });
  const over = { AGENT_INFRA_PATH: ALLOWED };
  const s1 = runBlock(step1, dir, over);
  check("#1051 D: a symlinked resolved skills dir still offers skill-lint",
    s1.rc === 0 && isSkillLintOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const sl = runBlock(slBlock, dir, over);
  check("#1051 D: the linter still lints the symlinked target",
    sl.rc === 0 && /validated 1 SKILL\.md file/.test(sl.out), `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
}

// ── Case E: skills -> out-of-boundary symlink → fails closed ───────────────
// `scripts/` is symlinked in, as in D/F/M: without it the delegated linter dies
// with MODULE_NOT_FOUND and the block exits 1 for a reason UNRELATED to the
// guard, which would make these assertions pass with the guard deleted
// (review-4 P1-1, mutation-verified).
{
  const dir = fixture((d) => {
    symlinkSync(join(OUTSIDE, "skills"), join(d, "skills"));
    symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
  });
  const s1 = runBlock(step1, dir);
  check("#1051 E: an out-of-boundary skills dir is OFFERED (so its run can fail)",
    s1.rc === 0 && isSkillLintOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const sl = runBlock(slBlock, dir);
  check("#1051 E: skill-lint FAILS CLOSED on an out-of-boundary skills dir",
    sl.rc !== 0 && !sl.out.includes("validated"), `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
  check("#1051 E: the refusal is the boundary refusal, not an incidental linter failure",
    /refusing to scan/i.test(sl.out) && /outside the checkout/i.test(sl.out),
    JSON.stringify(sl.out.trim()));
  check("#1051 E: no green is reported over the out-of-boundary tree",
    !/✅/.test(sl.out), JSON.stringify(sl.out.trim()));
  check("#1051 E: no sentinel path is linted", !leaksOutside(sl.out), JSON.stringify(sl.out.trim()));
}

// ── Case E2: skills -> a DIFFERENT subtree of the shared tree → refused ────
// The skills twin of B2: the allowance is ${AGENT_INFRA_PATH}/skills, not the
// whole shared checkout.
{
  const dir = fixture((d) => {
    symlinkSync(join(ALLOWED, "templates"), join(d, "skills"));
    symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
  });
  const sl = runBlock(slBlock, dir, { AGENT_INFRA_PATH: ALLOWED });
  check("#1051 E2: a skills dir redirected at a non-matching shared subtree is refused",
    sl.rc !== 0 && /refusing to scan/i.test(sl.out) && !/✅/.test(sl.out),
    `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
}

// ── Case F: an intermediate path component is the symlink ──────────────────
// `operations -> OUTSIDE` with a real `skills` underneath. `-L`-style start
// checks that only look at the last component miss this; the full physical
// resolution does not.
{
  const dir = fixture((d) => symlinkSync(OUTSIDE, join(d, "operations")));
  const s1 = runBlock(step1, dir);
  check("#1051 F: a symlink in an intermediate component is detected (offered, not silently skipped)",
    s1.rc === 0 && isSkillLintOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const sl = runBlock(slBlock, dir);
  check("#1051 F: skill-lint refuses through an intermediate symlinked component",
    sl.rc !== 0 && /refusing to scan|outside the checkout/i.test(sl.out),
    `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
}

// ── Case G: a symlinked DESCENDANT is not followed (`-P` preserved) ────────
{
  const dir = fixture((d) => {
    mkdirSync(join(d, "templates"));
    writeFileSync(join(d, "templates", "ok.json"), '{"a": 1}\n');
    symlinkSync(OUTSIDE, join(d, "templates", "nested"));
  });
  const tv = runBlock(tvBlock, dir);
  check("#1051 G: a symlinked descendant is not traversed (validates only the real file)",
    tv.rc === 0 && /validated 1\/1 schema template/.test(tv.out) && !leaksOutside(tv.out),
    `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
  const followTwin = bash(`find -L "${dir}/templates/" -type f`, dir).out;
  check("#1051 G twin: `find -L` WOULD traverse the descendant (so the `-P` choice is load-bearing)",
    followTwin.includes("secret.json"), `got ${JSON.stringify(followTwin.trim())}`);
}

// ── Case H: an unresolvable start point is PRESENT → offered, then fail closed
// A dangling symlink and a symlink loop both EXIST as entries (`-L` true) but do
// not resolve (`-e` false). They must not be folded into "absent": a check that
// vanishes over a present surface is a false green (review-4 P0-1).
{
  for (const [label, target] of [["dangling", join(root, "does-not-exist")], ["self-loop", null]]) {
    const dir = fixture((d) => symlinkSync(target ?? join(d, "templates"), join(d, "templates")));
    const s1 = runBlock(step1, dir);
    check(`#1051 H: a ${label} templates/ symlink is OFFERED (present, just unresolvable)`,
      s1.rc === 0 && isTemplateValidityOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
    const tv = runBlock(tvBlock, dir);
    check(`#1051 H: ...then someone-verifiable fails closed on a ${label} symlink`,
      tv.rc !== 0 && /no verifiable templates dir/.test(tv.out) && !/✅/.test(tv.out) && !leaksOutside(tv.out),
      `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
  }
  // Twin: only a truly ABSENT entry (no entry at all) is an empty target set.
  const empty = fixture(() => {});
  check("#1051 H twin: an absent templates/ is genuinely not offered (empty target set)",
    !isTemplateValidityOffered(runBlock(step1, empty).out), "a non-existent surface was offered");
}

// ── Case J: no boundary basis → refuse (never a `/*` wildcard admission) ───
// `case "$physical" in "$repo_real"|"$repo_real"/*)` degenerates to `""|"/*"`
// when repo_real is empty, which would admit EVERY absolute path. repo_real is
// empty when `pwd -P` cannot resolve (a deleted cwd), so the guard must refuse.
{
  const dir = fixture((d) => {
    mkdirSync(join(d, "templates"));
    writeFileSync(join(d, "templates", "ok.json"), '{"a": 1}\n');
  });
  const r = runBlock(step1, dir, {}, 'repo_real=""; bounded_root /etc; echo "RC=$?"');
  check("#1051 J: with no boundary basis an absolute start point is REFUSED (no '/*' admission)",
    /RC=2\b/.test(r.out) && !/^\/etc$/m.test(r.out), JSON.stringify(r.out.trim()));
}

// ── Case K: a sibling sharing a name PREFIX must not be admitted ────────────
// The containment pattern must be "$repo_real" | "$repo_real"/* — a bare
// prefix match would admit /…/pf-evil for a repo at /…/pf.
{
  const repo = join(root, "pf");
  mkdirSync(repo, { recursive: true });
  const evil = join(root, "pf-evil");
  mkdirSync(join(evil, "templates"), { recursive: true });
  writeFileSync(join(evil, "templates", "evil.json"), '{"a": 1}\n');
  symlinkSync(join(evil, "templates"), join(repo, "templates"));
  const tv = runBlock(tvBlock, repo);
  check("#1051 K: a sibling directory sharing a name prefix is refused (separator is load-bearing)",
    tv.rc !== 0 && !/✅/.test(tv.out) && /refusing to scan/i.test(tv.out),
    `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
}

// ── Case L: a checkout path containing spaces round-trips ───────────────────
{
  const dir = join(root, "dir with spaces");
  mkdirSync(join(dir, "templates"), { recursive: true });
  writeFileSync(join(dir, "templates", "ok.json"), '{"a": 1}\n');
  const tv = runBlock(tvBlock, dir);
  check("#1051 L: a checkout path containing spaces still validates",
    tv.rc === 0 && /validated 1\/1 schema template/.test(tv.out), `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
}

// ── Case M: a symlinked SKILL.md FILE (the delegated linter follows it) ────
// `find -P` (and the skill's own step) do not follow a symlinked SKILL.md, but
// scripts/check-skill-lint.mjs does: readdirSync reports isDirectory() false for
// a symlink, so it is not skipped, and readFileSync resolves the link. Without
// the refusal this is an out-of-boundary read reported as a clean lint.
{
  const dir = fixture((d) => {
    mkdirSync(join(d, "skills", "infra-verify"), { recursive: true });
    symlinkSync(SKILL_PATH, join(d, "skills", "infra-verify", "SKILL.md"));
    symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
  });
  const lint = bash(`node scripts/check-skill-lint.mjs --skills-dir "${dir}/skills"`, dir);
  check("#1051 M twin: the delegated linter FOLLOWS a symlinked SKILL.md and reports it Clean",
    lint.rc === 0 && /1 SKILL\.md files checked/.test(lint.out),
    `rc=${lint.rc} out=${JSON.stringify(lint.out.trim())}`);
  const s1 = runBlock(step1, dir);
  check("#1051 M: a symlinked SKILL.md entry is offered (the linter would lint it)",
    s1.rc === 0 && isSkillLintOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const sl = runBlock(slBlock, dir);
  check("#1051 M: skill-lint REFUSES a symlinked SKILL.md entry rather than following it",
    sl.rc !== 0 && /symlinked SKILL\.md/i.test(sl.out) && !/✅/.test(sl.out) && !/checked/.test(sl.out),
    `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
}

// ── Case M2: the refusal covers the lINTER'S follow set, not a superset ────
// check-skill-lint.mjs prunes any entry starting with `_` or `.`, so a symlinked
// SKILL.md under such a name is never read by it — refusing it would be a false
// red justified by a false claim (review-1 P2-1).
{
  const dir = fixture((d) => {
    mkdirSync(join(d, "skills", "infra-verify"), { recursive: true });
    copyFileSync(SKILL_PATH, join(d, "skills", "infra-verify", "SKILL.md"));
    mkdirSync(join(d, "skills", "_archive"), { recursive: true });
    symlinkSync(SKILL_PATH, join(d, "skills", "_archive", "SKILL.md"));
    symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
  });
  const lint = bash(`node scripts/check-skill-lint.mjs --skills-dir "${dir}/skills"`, dir);
  check("#1051 M2 twin: the linter prunes a `_`-prefixed dir, so it reads only the real skill",
    lint.rc === 0 && /1 SKILL\.md files checked/.test(lint.out), `rc=${lint.rc} out=${JSON.stringify(lint.out.trim())}`);
  const sl = runBlock(slBlock, dir);
  check("#1051 M2: a symlinked SKILL.md under a PRUNED name is not refused (no false red)",
    sl.rc === 0 && /validated 1/.test(sl.out), `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
}

// ── Case N: a misconfigured AGENT_INFRA_PATH (declared threat class C8) ────
{
  const dir = fixture((d) => symlinkSync(join(ALLOWED, "templates"), join(d, "templates")));
  for (const [label, value] of [["a regular file", join(OUTSIDE, "secret.json")], ["the filesystem root", "/"], ["a dangling path", join(root, "nope")]]) {
    const tv = runBlock(tvBlock, dir, { AGENT_INFRA_PATH: value });
    check(`#1051 N: AGENT_INFRA_PATH = ${label} does not admit a symlinked tree`,
      tv.rc !== 0 && !/✅/.test(tv.out), `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
  }
  const link = join(root, "agent-infra-link");
  if (!existsSync(link)) symlinkSync(ALLOWED, link);
  const tvLink = runBlock(tvBlock, dir, { AGENT_INFRA_PATH: link });
  check("#1051 N: AGENT_INFRA_PATH as a symlink to the shared checkout still resolves the subtree",
    tvLink.rc === 0 && /validated 1\/1 schema template/.test(tvLink.out),
    `rc=${tvLink.rc} out=${JSON.stringify(tvLink.out.trim())}`);
  const tvRel = runBlock(tvBlock, dir, { AGENT_INFRA_PATH: relative(dir, ALLOWED) });
  check("#1051 N: a relative AGENT_INFRA_PATH resolves against the checkout",
    tvRel.rc === 0 && /validated 1\/1 schema template/.test(tvRel.out),
    `rc=${tvRel.rc} out=${JSON.stringify(tvRel.out.trim())}`);
}

// ── Case P: the SKILLS half of C4 — a present-but-unresolvable candidate ───
// The `[ -d ]`-only candidate resolution short-circuits BEFORE bounded_root, so
// a dangling/looping `skills` entry was classified "no skills dir" and the check
// was silently un-offered — the exact false-green class this issue removes, and
// a live consumer layout (2 of 7 `*/skills` symlinks are dangling). Also pins
// directory PRECEDENCE: a present non-directory must not shadow a real dir.
{
  for (const [label, setup] of [
    ["dangling", (d) => symlinkSync(join(root, "nope"), join(d, "skills"))],
    ["self-loop", (d) => symlinkSync(join(d, "skills"), join(d, "skills"))],
    ["plain file", (d) => writeFileSync(join(d, "skills"), "not a dir\n")],
  ]) {
    const dir = fixture((d) => {
      setup(d);
      symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
    });
    const s1 = runBlock(step1, dir);
    check(`#1051 P: a ${label} \`skills\` entry is OFFERED (present, just unverifiable)`,
      s1.rc === 0 && isSkillLintOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
    const sl = runBlock(slBlock, dir);
    check(`#1051 P: ...then skill-lint fails closed on a ${label} \`skills\` entry`,
      sl.rc !== 0 && /no verifiable skills dir/.test(sl.out) && !/✅/.test(sl.out) && !leaksOutside(sl.out),
      `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
  }
  // Precedence twin: `operations/skills` present-but-unresolvable must not stop a
  // real `skills/` directory from being linted (no false red).
  const dir = fixture((d) => {
    mkdirSync(join(d, "operations"), { recursive: true });
    symlinkSync(join(root, "nope"), join(d, "operations", "skills"));
    mkdirSync(join(d, "skills", "infra-verify"), { recursive: true });
    copyFileSync(SKILL_PATH, join(d, "skills", "infra-verify", "SKILL.md"));
    symlinkSync(join(PROJECT_ROOT, "scripts"), join(d, "scripts"));
  });
  const sl = runBlock(slBlock, dir);
  check("#1051 P twin: a broken `operations/skills` does not shadow a real `skills/` dir",
    sl.rc === 0 && /validated 1/.test(sl.out), `rc=${sl.rc} out=${JSON.stringify(sl.out.trim())}`);
  // Absent twin: with no candidate present at all, skill-lint stays un-offered.
  const empty = fixture(() => {});
  check("#1051 P twin: no skills candidate present at all → still not offered",
    !isSkillLintOffered(runBlock(step1, empty).out), "a non-existent surface was offered");
}

// ── Case O: present but UNVERIFIABLE start point → offered, then fail closed ─
// rc 3, not rc 1: `templates` exists but is not a directory. Folding it into
// "absent" would silently un-offer a surface that is present.
{
  const dir = fixture((d) => writeFileSync(join(d, "templates"), "not a directory\n"));
  const s1 = runBlock(step1, dir);
  check("#1051 O: a present-but-not-a-directory templates is OFFERED (so its run can fail)",
    s1.rc === 0 && isTemplateValidityOffered(s1.out), `rc=${s1.rc} out=${JSON.stringify(s1.out.trim())}`);
  const tv = runBlock(tvBlock, dir);
  check("#1051 O: ...then fails closed with an explicit 'no verifiable templates dir'",
    tv.rc !== 0 && /no verifiable templates dir/.test(tv.out) && !/✅/.test(tv.out),
    `rc=${tv.rc} out=${JSON.stringify(tv.out.trim())}`);
}

// ── Source tripwire: the vulnerable start-point forms are gone ─────────────
// Cheap, non-executed backstop: the exact shipped forms that caused #1051.
// Scope is the BASH FENCES only — the surrounding prose deliberately shows
// `find templates/` as the anti-pattern being documented.
{
  const allBash = fences.join("\n");
  check("#1051 I: no `find templates/` start point survives in any bash block",
    !allBash.includes("find templates/"), "found a trailing-slash templates start point");
  check('#1051 I: no `find "$SKILLS_DIR/"` start point survives in any bash block',
    !allBash.includes('find "$SKILLS_DIR/"'), "found a trailing-slash skills start point");
  check("#1051 I: no `find -H` / `find -L` start-point-following form survives in any bash block",
    !/find\s+-(H|L)\b/.test(allBash), "found a start-point-following find mode");
  check("#1051 I: no variable start point carries a trailing slash",
    !/find\s+(-[A-Za-z]+\s+)*"\$[A-Za-z_][A-Za-z0-9_]*"\s*\//.test(allBash),
    "found a trailing slash on a variable start point");
  check("#1051 I: Step 1 resolves its start point through bounded_root + find -P",
    step1.includes("bounded_root") && /find -P "\$/.test(step1), "missing bounded_root / find -P");
  check("#1051 I: template-validity resolves its start point through bounded_root + find -P",
    tvBlock.includes("bounded_root") && /find -P "\$/.test(tvBlock), "missing bounded_root / find -P");
  check("#1051 I: skill-lint resolves its start point through bounded_root before delegating",
    slBlock.includes("bounded_root") && /--skills-dir "\$skills_phys"/.test(slBlock),
    "missing bounded_root / physical --skills-dir");
  // The guard is copy-pasted into each self-contained block (a fresh shell
  // cannot source a helper). Pin the WHOLE preamble — repo_real/agent_real
  // derivation AND the function — byte-identical, so a one-sided edit to the
  // boundary basis cannot pass while the function text stays equal
  // (#966/#1040 drift class).
  // Extract the preamble with a BRACE-COUNTING scan, not a lazy `[\s\S]*?\n\}`
  // regex: a stray column-0 `}` inside the function truncates the match, and a
  // divergence after it would pass while the pin reported green (review-4 P2-1).
  const preambleOf = (block) => {
    const start = block.indexOf("repo_real=$(pwd -P)");
    const open = start < 0 ? -1 : block.indexOf("bounded_root() {", start);
    if (open < 0) return "";
    let depth = 0;
    for (let i = open + "bounded_root()".length; i < block.length; i++) {
      if (block[i] === "{") depth++;
      else if (block[i] === "}") { depth--; if (depth === 0) return block.slice(start, i + 1); }
    }
    return "";
  };
  const defs = [step1, tvBlock, slBlock].map(preambleOf).filter(Boolean);
  check("#1051 I: the three bounded_root preambles are byte-identical",
    defs.length === 3 && new Set(defs).size === 1,
    `found ${defs.length} preamble(s), ${new Set(defs).size} distinct`);
  check("#1051 I: no block resolves its boundary basis from an unchecked `cd`",
    !/^cd (?!")/m.test(allBash) && !/^cd "[^"]*"\s*$/m.test(allBash),
    "found an unquoted or unchecked `cd <REPO_ROOT>`");
}

rmSync(root, { recursive: true, force: true });

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
