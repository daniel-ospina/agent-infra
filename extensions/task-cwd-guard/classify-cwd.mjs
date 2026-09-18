/**
 * classify-cwd.mjs — the pure "is this `task` dispatch target a SHARED MAIN
 * checkout?" decision for `task-cwd-guard` (#1240).
 *
 * WHY THIS MODULE EXISTS
 * ----------------------
 * pi's `task` tool spawns the child in the PARENT's cwd unless the caller passes
 * `cwd` (#1071). Sessions root in repo checkouts, so a child dispatched without
 * an explicit `cwd` lands in a SHARED MAIN checkout — where every branch move is
 * unsafe and one lane's unpushed commit makes the guard gate git writes for
 * every session rooted there (measured on the tortoise hub: 63 processes, 24
 * live pi sessions, ~124 dispatches/hour inheriting the hub). The hub is an
 * attractor. This module answers the only question the gate needs: *does the
 * child's resolved spawn directory live in a repo's MAIN checkout?*
 *
 * HOW "MAIN CHECKOUT" IS DECIDED (structural, not path-string)
 * ------------------------------------------------------------
 * `git rev-parse --git-dir` vs `--git-common-dir`, both realpath'd:
 *   main checkout : both name the SAME directory (`<top>/.git`)
 *   linked worktree: `--git-dir` is `<common>/worktrees/<name>` — a strict
 *                    subdirectory of the common dir, hence a DIFFERENT realpath
 * A path-substring test (`gitDir.includes("/worktrees/")`) is deliberately NOT
 * used: it fails OPEN for a main checkout whose own path contains a `worktrees`
 * segment (the #618/#621 defect documented in main-worktree-guard's
 * classify-git.mjs). Structural equality has no such false negative.
 *
 * Both git spellings are resolved against the TARGET's realpath, because git
 * prints relative paths when its cwd sits under the gitdir's parent and absolute
 * paths otherwise (#1129's probe: a symlinked `scripts/` made the two halves
 * diverge and the checkout was misread). resolve() alone normalizes neither half
 * against the other.
 *
 * FAIL-OPEN ON UNKNOWNS, DELIBERATELY
 * -----------------------------------
 * A non-repo target, a missing git binary, and an unresolvable path are all
 * "not a shared main checkout" → ALLOW. The gate's failure mode is `over-block`
 * (category B friction), not a false PASS on something dangerous: a child in
 * /tmp or in a fresh directory has no shared branch state to damage. A child in
 * a nonexistent directory is reported asynchronously by the spawn itself
 * (#1071's `taskCwdRefusal` comment) — this gate must not become a second,
 * differently-worded refusal for that case.
 *
 * DERIVED BY CONSTRUCTION, NOT BY DRIFT
 * -------------------------------------
 * `resolveDispatchCwd` mirrors #1071's `resolveTaskCwd` exactly (trim → resolve
 * → realpath, lexical fallback). `task-cwd-guard/test-cwd-guard.mjs` pins the
 * parity, and the extension's index.ts feeds `process.cwd()` as the parent frame
 * — the same frame builtin-tools uses.
 */

import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

/** Extension name, for the one-time degradation warning and message prefix. */
export const GUARD_NAME = "task-cwd-guard";

/**
 * Escape-hatch env var.
 *   unset / "" / "1" / "true" / anything else → **block** (the shipped default;
 *     the gate exists to enforce an explicit spawn cwd)
 *   "warn"                                    → log + `ctx.ui.notify`, allow
 *   "0" / "false" / "no" / "off"              → disabled
 * Only these three postures exist; unknown values are NOT silently a kill
 * switch (an operator typo must not disable enforcement).
 */
export const GUARD_ENV = "TASK_CWD_GUARD";

const OFF_VALUES = new Set(["0", "false", "no", "off", "disabled", "disable"]);
const WARN_VALUES = new Set(["warn", "warning"]);

/** Resolve `TASK_CWD_GUARD` into "block" | "warn" | "off". */
export function guardMode(env = {}) {
  const raw = String(env[GUARD_ENV] ?? "").trim().toLowerCase();
  if (OFF_VALUES.has(raw)) return "off";
  if (WARN_VALUES.has(raw)) return "warn";
  return "block";
}

/** Physical path when it exists, else a lexically-normalized absolute path. */
export function normalizeDir(p) {
  const absolute = resolve(p);
  try {
    return realpathSync(absolute);
  } catch {
    return absolute;
  }
}

/**
 * #1071 parity: the child's target spawn directory for one dispatch.
 * An explicit `cwd` is trimmed, resolved against the parent frame, and
 * canonicalized (realpath) so it matches the child's own `getcwd()`; a missing
 * target keeps the lexical absolute path. Omitted / blank → the parent frame.
 */
export function resolveDispatchCwd(cwd, parentCwd = process.cwd()) {
  const trimmed = typeof cwd === "string" ? cwd.trim() : "";
  if (!trimmed) return normalizeDir(parentCwd);
  const absolute = resolve(parentCwd, trimmed);
  try {
    return realpathSync(absolute);
  } catch {
    return absolute;
  }
}

/** Default git runner: `git -C <dir> <args...>` → stdout. Throws on failure. */
export function defaultRunGit(args, dir) {
  return execFileSync("git", ["-C", dir, ...args], {
    encoding: "utf-8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "ignore"],
  });
}

/** git itself is not installed (as opposed to "this is not a repo"). */
function isGitUnavailable(err) {
  return err?.code === "ENOENT" || /ENOENT/.test(String(err?.message ?? ""));
}

/**
 * Read the structural checkout facts for `targetDir`.
 *
 * @returns {{
 *   kind: "main"|"worktree"|"non-repo",
 *   base: string,          // the realpath'd target used as git's cwd
 *   topLevel: string|null, // `git rev-parse --show-toplevel` (realpath'd)
 *   gitDir: string|null,
 *   commonDir: string|null,
 *   gitError: string|null,     // message when git ran and failed
 *   gitUnavailable: boolean,   // true only when git could not be executed
 * }}
 */
export function classifyTargetCwd(targetDir, deps = {}) {
  const runGit = deps.runGit ?? defaultRunGit;
  const base = normalizeDir(targetDir);
  let out;
  try {
    out = runGit(["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"], base);
  } catch (err) {
    return {
      kind: "non-repo",
      base,
      topLevel: null,
      gitDir: null,
      commonDir: null,
      gitError: err instanceof Error ? err.message : String(err),
      gitUnavailable: isGitUnavailable(err),
    };
  }
  // One rev-parse, three output lines (order matches the flag order).
  const [topRaw = "", gitDirRaw = "", commonDirRaw = ""] = String(out).split("\n");
  if (!gitDirRaw.trim() || !commonDirRaw.trim()) {
    return {
      kind: "non-repo",
      base,
      topLevel: null,
      gitDir: null,
      commonDir: null,
      gitError: "git rev-parse returned no git-dir/common-dir",
      gitUnavailable: false,
    };
  }
  // #1129: resolve BOTH spellings against the TARGET's realpath (git mixes
  // relative and absolute output depending on where its cwd sits).
  const gitDir = normalizeDir(resolve(base, gitDirRaw.trim()));
  const commonDir = normalizeDir(resolve(base, commonDirRaw.trim()));
  const topLevel = topRaw.trim() ? normalizeDir(resolve(base, topRaw.trim())) : null;
  return {
    kind: gitDir === commonDir ? "main" : "worktree",
    base,
    topLevel,
    gitDir,
    commonDir,
    gitError: null,
    gitUnavailable: false,
  };
}

/** Best-effort current branch of `dir` (`symbolic-ref` → null on detached HEAD). */
export function readBranch(dir, deps = {}) {
  const runGit = deps.runGit ?? defaultRunGit;
  try {
    return runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], dir).trim() || null;
  } catch {
    return null;
  }
}

/** The refusal / warning text. Names the checkout, the source, and the remedy. */
export function renderMainCheckoutMessage({ target, checkout, branch, explicit }) {
  const branchLine = branch ? `branch   : ${branch}` : "branch   : (detached HEAD)";
  const source = explicit
    ? "`cwd` argument (an explicit target)"
    : "inherited from the parent — no `cwd` was passed (#1071)";
  return [
    `🛑 ${GUARD_NAME} (#1240): this \`task\` dispatch would run in a SHARED MAIN checkout.`,
    "",
    `  checkout : ${checkout}`,
    `  ${branchLine}`,
    `  target   : ${target}`,
    `  source   : ${source}`,
    "",
    "  In a shared main checkout every branch move is unsafe, and one lane's unpushed",
    "  commit makes the guard gate git writes for EVERY session rooted there — one lane",
    "  blocks all of them. A child spawned here also runs its extension stack against the",
    "  shared tree, and the parent's `Alive state` / wedge report names the wrong checkout.",
    "",
    "  Remedy — dispatch into an isolated linked worktree and pass its path as `cwd`:",
    `    git -C ${checkout} worktree add .worktrees/<name> -b <branch>`,
    "    task({ prompt: …, cwd: \"" + checkout + "/.worktrees/<name>\" })",
    "  (agent-infra helper: `bash scripts/checkout-hygiene/hub-worktree.sh <branch>`;",
    "   skill: `using-git-worktrees`. A NON-main worktree — or a non-repo directory — is",
    "   allowed unchanged, so a dispatch already targeting a worktree needs no change.)",
    "",
    `  Escape hatch: ${GUARD_ENV}=warn (log + notify only) · ${GUARD_ENV}=off`,
  ].join("\n");
}

/**
 * The whole decision for one dispatch.
 *
 * @param {{cwd?: unknown, parentCwd?: string, env?: Record<string,string|undefined>, runGit?: Function}} input
 * @returns {{
 *   action: "allow"|"warn"|"block",
 *   mode: "block"|"warn"|"off",
 *   target: string,
 *   kind: "main"|"worktree"|"non-repo"|null,
 *   checkout: string|null,
 *   branch: string|null,
 *   explicit: boolean,
 *   gitUnavailable: boolean,
 *   message: string|null,
 * }}
 */
export function decideTaskCwd(input = {}) {
  const env = input.env ?? {};
  const mode = guardMode(env);
  const explicit = typeof input.cwd === "string" && input.cwd.trim() !== "";
  const target = resolveDispatchCwd(input.cwd, input.parentCwd ?? process.cwd());
  const base = {
    mode,
    target,
    kind: null,
    checkout: null,
    branch: null,
    explicit,
    gitUnavailable: false,
    message: null,
  };
  // Disabled: do not even spawn git (the kill switch is observable as zero cost).
  if (mode === "off") return { ...base, action: "allow" };

  const facts = classifyTargetCwd(target, input.runGit ? { runGit: input.runGit } : {});
  if (facts.kind !== "main") {
    return { ...base, action: "allow", kind: facts.kind, gitUnavailable: facts.gitUnavailable };
  }
  const checkout = facts.topLevel ?? facts.base;
  const branch = readBranch(target, input.runGit ? { runGit: input.runGit } : {});
  const message = renderMainCheckoutMessage({ target, checkout, branch, explicit });
  return {
    ...base,
    action: mode === "warn" ? "warn" : "block",
    kind: "main",
    checkout,
    branch,
    message,
  };
}
