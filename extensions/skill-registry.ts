// skill-registry.ts — #1323: make the pi skill farm work everywhere, or say so.
//
// ── WHAT THIS EXTENSION IS FOR ───────────────────────────────────────────────
// pi discovers skills in exactly two default locations:
//   ~/.pi/agent/skills   (global, source "user")
//   <cwd>/.pi/skills     (project, source "project")
// (verified against the installed package: dist/core/skills.js `loadSkills`).
// Consumer repos keep skills in `operations/skills/` and agent-infra in
// `skills/` — neither is a default pi location. This extension closes that gap:
// on `session_start` it links the current project's skills into the global farm
// so pi advertises them.
//
// ── WHAT WAS WRONG (#1323) ──────────────────────────────────────────────────
// The registry was built by shelling out to
// `<project>/operations/tools/skill_registry.py` — a file that lives in eldato
// and has NEVER existed in agent-infra (no `operations/` directory here at all;
// `git log --all -- '*skill_registry*'` is empty; `scripts/check-skill-links.sh`
// even asserts "agent-infra has no operations/ directory"). Its
// `$AGENT_INFRA_PATH` fallback therefore named a path that could not exist for
// any repo, and every non-eldato session printed that warning. Meanwhile an
// empty registry cache returned `{}` and the handler `return`ed — a silent
// no-op. Two defects, one class: a missing input reported as "nothing to do"
// (AGENTS.md category A — a no-op gate that can never act).
//
// ── THE CONTRACT NOW ────────────────────────────────────────────────────────
// 1. LAYOUT-AWARE, IN-PROCESS. Sources are enumerated in TypeScript from the
//    shapes pi/consumers actually use — `skills/`, `operations/skills/`,
//    `.agents/skills/`, `.pi/skills/` — under the PROJECT root and under THIS
//    module's real repo root. The module root is derived from
//    `realpathSync(__filename)` (the #1321 discipline: pi loads extensions
//    through a symlink and jiti keeps the SYMLINK path in `__dirname`). No
//    Python, no cache file, no env-var path that may not exist.
// 2. ADDITIVE-ONLY WRITER. A farm entry is created only when the name is
//    absent, or when the existing entry is a SYMLINK whose target no longer
//    exists (a dangling link an earlier run of this extension left behind). A
//    real directory is never overwritten; a live symlink this extension did not
//    create is never removed. The farm is shared with
//    `pi-bootstrap/setup.sh` (the real-copy refresh) and with any other
//    installer, so clobbering it is not this extension's call.
// 3. NEVER WRITES THROUGH A SYMLINKED FARM. If `~/.pi/agent/skills` is itself a
//    symlink (a supported layout — setup.sh keeps one that points into this
//    repo) the farm is DELEGATED: pi already reads that directory, and a
//    per-skill link written through it would land inside a git work tree.
//    Source skills absent from the delegated directory are REPORTED instead.
// 4. A LINKED WORKTREE IS NOT THE MACHINE'S CONFIGURATION. A lane's worktree
//    skills are skipped, so tearing a worktree down can never leave the farm
//    pointing at a deleted path (the #1214b dangling-link class).
// 5. EMPTY IS NOT SUCCESS. `runSync` returns an explicit report. The handler
//    prints a success line only when it actually linked or repaired something,
//    and every failure (unreadable source root, unusable farm, link error) is an
//    ERROR line. An empty source set prints NOTHING — the invariant being that
//    nothing is ever reported as synced without evidence.
// 6. STALENESS IS REPORTED (#1323 indicator 3). When the farm holds a real COPY
//    of a source skill (setup.sh's copy layout) and the copy differs from the
//    source, the skill is named together with the remedy — otherwise drift is
//    invisible until setup.sh happens to run again.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  statSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

/** The file that makes a directory a skill (pi's discovery rule). */
export const SKILL_ENTRY = "SKILL.md";

/** Skill-root SHAPES, in precedence order. Same set `skill-enforcer` trusts. */
export const SKILL_ROOT_SHAPES: readonly (readonly string[])[] = [
  ["skills"], // <repo>/skills               (agent-infra)
  ["operations", "skills"], // <repo>/operations/skills    (eldato & consumers)
  [".agents", "skills"], // <repo>/.agents/skills       (hard-link farm)
  [".pi", "skills"], // <repo>/.pi/skills           (pi project skills)
];

/** Diagnostics limits — enough to act on, short enough not to flood a session. */
export const LIST_CAP = 5;
/** Files above this size are compared by size only (they are not skill text). */
export const HASH_MAX_BYTES = 2 * 1024 * 1024;

export interface SkillSource {
  name: string;
  /** Real path of the skill directory (symlinks resolved). */
  dir: string;
  /** The skill root it was found under. */
  root: string;
}

export interface SyncReport {
  /** true when nothing failed. NOT the same as "something was synced". */
  ok: boolean;
  farm: {
    path: string;
    mode: "missing" | "created" | "directory" | "symlink" | "unusable";
    /** The directory pi actually reads (`farm.path` with symlinks resolved). */
    realPath: string;
  };
  sources: SkillSource[];
  /** Names newly linked into the farm. */
  linked: string[];
  /** Names whose dangling link was re-pointed at the source. */
  repaired: string[];
  /** Names the farm holds as a real copy that DIFFERS from its source. */
  stale: string[];
  /** Names pi cannot reach through the farm's target and is not already reading
   *  as a project skill (delegated layout, rule 3). */
  missing: string[];
  /** Names occupied by a non-directory in the farm — left alone, reported. */
  conflicts: string[];
  errors: string[];
}

export interface SyncOptions {
  /** The pi skill farm. Defaults to `~/.pi/agent/skills`. */
  farm?: string;
  /** The project whose skills should be visible. Defaults to the git toplevel of cwd. */
  projectRoot?: string;
  /** This extension's repo root. Defaults to the real repo root of the module. */
  moduleRoot?: string;
  cwd?: string;
  home?: string;
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function realpathOr(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

/**
 * The REAL directory holding this module. pi loads global extensions from
 * `~/.pi/agent/extensions/*.ts` — symlinks into the repo — through jiti, which
 * keeps the SYMLINK path in `__dirname`, so `__dirname` is not the module's
 * location (#1321). `realpathSync` is loader-independent; the try/catch keeps a
 * deleted module from crashing the load.
 */
export function realModuleDir(): string {
  try {
    return dirname(realpathSync(__filename));
  } catch {
    return __dirname;
  }
}

export const MODULE_DIR = realModuleDir();
export const REPO_DIR = resolve(MODULE_DIR, "..");

/** The pi skill farm for a given home. */
export function defaultFarmDir(home: string = homedir()): string {
  return join(home, ".pi", "agent", "skills");
}

/** The git toplevel of `cwd`, or `cwd` itself when it is not a work tree. */
export function projectRoot(cwd: string = process.cwd()): string {
  try {
    const out = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      cwd,
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return out || resolve(cwd);
  } catch {
    return resolve(cwd);
  }
}

/**
 * A LINKED WORKTREE is a lane's sandbox, not the machine's configuration.
 * `--git-dir` is this checkout's gitdir; `--git-common-dir` is the shared one —
 * they differ exactly for linked worktrees and are equal in the main checkout.
 * An unreadable answer is treated as "main checkout": skipping a real repo
 * silently would be the worse failure of the two.
 */
export function isLinkedWorktree(dir: string): boolean {
  try {
    const lines = execFileSync(
      "git",
      ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
      { cwd: dir, encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] },
    )
      .trim()
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean);
    if (lines.length < 2) return false;
    return realpathOr(lines[0]) !== realpathOr(lines[1]);
  } catch {
    return false;
  }
}

const SIG_SKIP = new Set(["node_modules", ".git"]);
const SIG_MAX_DEPTH = 12;

/**
 * A content signature of a directory tree (relative path + size + content hash,
 * or a marker when a file is too big / unreadable). Used ONLY to answer "does
 * this farm copy still equal its source?" — a change to any file inside a skill
 * matters, not just to `SKILL.md`. `null` when the tree holds nothing at all.
 *
 * ⛔ SYMLINKS ARE NEVER DEREFERENCED. A skill directory is attacker-adjacent
 * content (any repo can carry one) and a single symlink to `..` would make this
 * walk unbounded — the #1051 class: `find <dir>/` dereferences a symlinked start
 * point and can turn a bounded in-checkout enumeration into a filesystem-wide
 * (or non-terminating) walk. A symlink is recorded as its LINK TARGET and the
 * walk does not descend. `SIG_MAX_DEPTH` is the second, independent bound, so a
 * pathological real tree cannot run away either.
 */
export function dirSignature(dir: string): string | null {
  const parts: string[] = [];
  const walk = (rel: string, depth: number): void => {
    if (depth > SIG_MAX_DEPTH) {
      parts.push(`${rel}:DEPTH-LIMIT`);
      return;
    }
    const abs = rel ? join(dir, rel) : dir;
    let entries;
    try {
      entries = readdirSync(abs, { withFileTypes: true });
    } catch (err) {
      parts.push(`${rel || "."}:UNREADABLE:${message(err)}`);
      return;
    }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (SIG_SKIP.has(entry.name)) continue;
      const childRel = rel ? `${rel}/${entry.name}` : entry.name;
      const childAbs = join(abs, entry.name);
      if (entry.isSymbolicLink()) {
        let target = "?";
        try {
          target = readlinkSync(childAbs);
        } catch {
          /* unreadable link — the marker below is still deterministic */
        }
        parts.push(`${childRel}:LINK:${target}`);
        continue;
      }
      if (entry.isDirectory()) {
        walk(childRel, depth + 1);
        continue;
      }
      if (!entry.isFile()) {
        parts.push(`${childRel}:OTHER`);
        continue;
      }
      try {
        const st = statSync(childAbs);
        if (st.size > HASH_MAX_BYTES) {
          parts.push(`${childRel}:${st.size}:BIG`);
          continue;
        }
        const hash = createHash("sha256").update(readFileSync(childAbs)).digest("hex");
        parts.push(`${childRel}:${st.size}:${hash}`);
      } catch (err) {
        parts.push(`${childRel}:UNREADABLE:${message(err)}`);
      }
    }
  };
  walk("", 1);
  return parts.length === 0 ? null : parts.join("\n");
}

/**
 * Every skill under one root, in shape order. A directory is a skill when it
 * holds a `SKILL.md`; non-directories and dot-entries are ignored. A root that
 * exists but cannot be read is an ERROR — never silently "no skills".
 */
export function enumerateSkills(root: string): { skills: SkillSource[]; errors: string[] } {
  const skills: SkillSource[] = [];
  const errors: string[] = [];
  for (const shape of SKILL_ROOT_SHAPES) {
    const dir = resolve(root, ...shape);
    if (!existsSync(dir)) continue;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      errors.push(`cannot read skill root ${dir}: ${message(err)}`);
      continue;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const child = join(dir, entry.name);
      let isDir = entry.isDirectory();
      if (entry.isSymbolicLink()) {
        try {
          isDir = statSync(child).isDirectory();
        } catch {
          continue; // a broken link is not a skill
        }
      }
      if (!isDir) continue;
      if (!existsSync(join(child, SKILL_ENTRY))) continue;
      skills.push({ name: entry.name, dir: realpathOr(child), root: dir });
    }
  }
  return { skills, errors };
}

/**
 * Resolve the source skills from the project root and this module's repo root.
 * Both guards are load-bearing:
 *   - a linked worktree root is SKIPPED (contract rule 4);
 *   - a source directory that IS the farm, or sits inside it, is SKIPPED — a
 *     project whose `.pi/skills` is the farm would otherwise offer the farm as
 *     its own source and link it to itself.
 */
export function collectSources(opts: {
  projectRoot: string;
  moduleRoot: string;
  farm: string;
}): { sources: SkillSource[]; errors: string[]; skippedRoots: string[] } {
  const errors: string[] = [];
  const skippedRoots: string[] = [];
  const farmReal = realpathOr(opts.farm);
  const roots: string[] = [];
  for (const root of [opts.projectRoot, opts.moduleRoot]) {
    if (!root) continue;
    if (roots.includes(root)) continue;
    if (isLinkedWorktree(root)) {
      skippedRoots.push(root);
      continue;
    }
    roots.push(root);
  }
  const byName = new Map<string, SkillSource>();
  for (const root of roots) {
    const found = enumerateSkills(root);
    errors.push(...found.errors);
    for (const skill of found.skills) {
      if (skill.dir === farmReal || skill.dir.startsWith(`${farmReal}/`)) continue;
      if (!byName.has(skill.name)) byName.set(skill.name, skill);
    }
  }
  return {
    sources: [...byName.values()].sort((a, b) => a.name.localeCompare(b.name)),
    errors,
    skippedRoots,
  };
}

/**
 * Bring the farm up to date, additively. Pure with respect to its inputs: every
 * path comes from `opts`, so a suite can drive it against temp fixtures without
 * touching the real `~/.pi`. Returns a report; never throws for an expected
 * filesystem condition.
 */
export function runSync(opts: SyncOptions = {}): SyncReport {
  const farm = opts.farm ?? defaultFarmDir(opts.home ?? homedir());
  const project = opts.projectRoot ?? projectRoot(opts.cwd ?? process.cwd());
  const moduleRoot = opts.moduleRoot ?? REPO_DIR;

  const report: SyncReport = {
    ok: true,
    farm: { path: farm, mode: "unusable", realPath: resolve(farm) },
    sources: [],
    linked: [],
    repaired: [],
    stale: [],
    missing: [],
    conflicts: [],
    errors: [],
  };

  // ── the farm's shape ───────────────────────────────────────────────────────
  let kind: "missing" | "symlink" | "directory" | "other";
  try {
    const st = lstatSync(farm);
    kind = st.isSymbolicLink() ? "symlink" : st.isDirectory() ? "directory" : "other";
  } catch {
    kind = "missing";
  }
  if (kind === "other") {
    report.errors.push(`${farm} exists and is not a directory — the skill farm is unusable`);
    report.ok = false;
    return report;
  }
  if (kind === "missing") {
    report.farm.mode = "missing";
    report.farm.realPath = resolve(farm);
  } else if (kind === "directory") {
    report.farm.mode = "directory";
    report.farm.realPath = realpathOr(farm);
  } else {
    report.farm.mode = "symlink";
    report.farm.realPath = realpathOr(farm);
    if (!existsSync(farm)) {
      // A dangling link: `realpathSync` cannot resolve the target, so read the
      // link itself — the operator needs to know WHERE it points.
      let target = report.farm.realPath;
      try {
        target = resolve(dirname(farm), readlinkSync(farm));
      } catch {
        /* keep the resolved link path */
      }
      report.errors.push(`${farm} is a dangling symlink to ${target} — the skill farm is unusable`);
      report.ok = false;
      return report;
    }
  }

  const collected = collectSources({ projectRoot: project, moduleRoot, farm });
  report.sources = collected.sources;
  report.errors.push(...collected.errors);

  // ── delegated farm: report, never write (contract rule 3) ──────────────────
  if (report.farm.mode === "symlink") {
    // A source pi reads DIRECTLY is not made invisible by a delegated farm. The
    // project's own `.pi/skills` is one of pi's two default locations (its
    // loader adds `<cwd>/.pi/skills` as a "project" source) and this module
    // enumerates that shape on purpose — so naming such a source "NOT visible to
    // pi BECAUSE the farm is a symlink" states a false cause and prints a
    // permanent false alarm in the delegated layout. Under-reported when the
    // session cwd is a SUBdirectory of the project root (pi's project dir is
    // `<cwd>/.pi/skills`; this module's is `<toplevel>/.pi/skills`): withholding a
    // warning whose stated cause cannot be honored is the safe direction.
    const piProjectSkills = resolve(project, ".pi", "skills");
    for (const src of report.sources) {
      if (src.root === piProjectSkills) continue;
      if (!existsSync(join(report.farm.realPath, src.name, SKILL_ENTRY))) {
        report.missing.push(src.name);
      }
    }
    report.ok = report.errors.length === 0;
    return report;
  }

  // Nothing to link: do not create a farm as a side effect of finding nothing.
  // "Empty is not success" cuts both ways — this path reports NO success line
  // because there is nothing it could honestly call synced.
  if (report.sources.length === 0) {
    report.ok = report.errors.length === 0;
    return report;
  }

  if (report.farm.mode === "missing") {
    try {
      mkdirSync(farm, { recursive: true });
      report.farm.mode = "created";
      report.farm.realPath = realpathOr(farm);
    } catch (err) {
      report.errors.push(`cannot create the skill farm ${farm}: ${message(err)}`);
      report.ok = false;
      return report;
    }
  }

  // ── owned farm: link what is absent, repair only our own dangling links ────
  const link = (target: string, src: SkillSource, repaired: boolean): void => {
    try {
      symlinkSync(src.dir, target, "dir");
      (repaired ? report.repaired : report.linked).push(src.name);
    } catch (err) {
      report.errors.push(`cannot link ${src.dir} -> ${target}: ${message(err)}`);
    }
  };

  for (const src of report.sources) {
    const target = join(farm, src.name);
    let entryKind: "missing" | "symlink" | "directory" | "other";
    try {
      const st = lstatSync(target);
      entryKind = st.isSymbolicLink() ? "symlink" : st.isDirectory() ? "directory" : "other";
    } catch {
      entryKind = "missing";
    }

    if (entryKind === "missing") {
      link(target, src, false);
      continue;
    }
    if (entryKind === "symlink") {
      // A LIVE link belongs to whoever made it (setup.sh's farm, an installer):
      // leave it alone. Only a link whose target is GONE is repaired — and
      // "gone" must be read from the ERROR CODE, not from `existsSync`: that
      // returns false for ANY stat failure, so EACCES/EPERM on an ancestor is
      // indistinguishable from ENOENT. Treating it as dangling unlinked a LIVE
      // foreign link and re-pointed it at this extension's source (the rule-2
      // violation) and then counted the name in `repaired`, reporting a repair
      // of a link that was never dangling. EACCES is not exotic: setup.sh
      // records exactly this under macOS TCC, and an unmounted volume or a
      // non-traversable ancestor reaches the same branch.
      let dangling = false;
      try {
        statSync(target);
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code;
        if (code === "ENOENT" || code === "ENOTDIR") {
          dangling = true;
        } else {
          report.errors.push(
            `cannot tell whether the farm entry ${target} is live (${message(err)}) — left alone, NOT re-pointed`,
          );
          continue;
        }
      }
      if (!dangling) continue;
      try {
        unlinkSync(target);
      } catch (err) {
        report.errors.push(`cannot remove the dangling link ${target}: ${message(err)}`);
        continue;
      }
      link(target, src, true);
      continue;
    }
    if (entryKind === "other") {
      report.conflicts.push(src.name);
      continue;
    }
    // A real directory: a COPY. Compare, never overwrite (#1323 indicator 3).
    if (dirSignature(src.dir) !== dirSignature(target)) report.stale.push(src.name);
  }

  report.ok = report.errors.length === 0;
  return report;
}

/**
 * The remedy clause for a stale-copy warning. The stale branch fires exactly in
 * setup.sh's COPY layout, where this extension is a real file under
 * `~/.pi/agent` — so its own root holds no `sync.sh`. The remedy is therefore
 * chosen by what EXISTS, never by where the source happens to be installed:
 * advertising `<root>/sync.sh` unconditionally sent the operator to a file that
 * cannot be there on the one layout this warning is about.
 */
export function staleRemedy(repoDir: string): string {
  const syncSh = join(repoDir, "sync.sh");
  return existsSync(syncSh)
    ? `refresh with "${syncSh}"`
    : `refresh by running sync.sh from an agent-infra checkout (this extension is installed as a COPY, so its own root — ${repoDir} — holds no sync.sh)`;
}

function list(names: string[]): string {
  if (names.length <= LIST_CAP) return names.join(", ");
  return `${names.slice(0, LIST_CAP).join(", ")} (+${names.length - LIST_CAP} more)`;
}

/** Render a report to the operator. Silent when there is nothing to say. */
export function reportSync(report: SyncReport): void {
  for (const err of report.errors) console.error(`[skill-registry] ❌ ${err}`);
  if (report.conflicts.length > 0) {
    console.warn(
      `[skill-registry] ⚠️  ${report.conflicts.length} name(s) in ${report.farm.path} are not directories, so they were left alone: ${list(report.conflicts)}`,
    );
  }
  if (report.stale.length > 0) {
    console.warn(
      `[skill-registry] ⚠️  ${report.stale.length} skill(s) in ${report.farm.path} are STALE COPIES of their source: ${list(report.stale)} — ${staleRemedy(REPO_DIR)}`,
    );
  }
  if (report.missing.length > 0) {
    console.warn(
      `[skill-registry] ⚠️  ${report.farm.path} is a symlink to ${report.farm.realPath}, so this extension does not write into it; ${report.missing.length} source skill(s) are NOT visible to pi: ${list(report.missing)}`,
    );
  }
  const changed = report.linked.length + report.repaired.length;
  if (changed > 0) {
    const parts = [`linked ${report.linked.length}`];
    if (report.repaired.length > 0) parts.push(`repaired ${report.repaired.length}`);
    console.log(
      `[skill-registry] ${parts.join(" and ")} of ${report.sources.length} source skill(s) into ${report.farm.path}`,
    );
  }
}

// Test seam: redirect the whole sync (farm + roots) so a suite can drive the
// handler without touching the real `~/.pi` (#1321's `_setManifestForTest`
// precedent). `null` restores the real paths.
let OPTIONS_OVERRIDE: SyncOptions | null = null;
export function _setSyncOptionsForTest(opts: SyncOptions | null): void {
  OPTIONS_OVERRIDE = opts;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    try {
      reportSync(runSync(OPTIONS_OVERRIDE ?? {}));
    } catch (err) {
      // Never let a farm problem take down session startup — but never swallow
      // it either: an unexpected throw is still reported, just not fatal.
      console.error(`[skill-registry] ❌ skill farm sync failed: ${message(err)}`);
    }
  });
}
