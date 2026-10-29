/**
 * shared/headless-lane.ts — DERIVE the lane contract from what the process can
 * observe, instead of requiring the launcher to have set it.
 *
 * ── THE DEFECT THIS EXISTS FOR (agent-infra#2965) ─────────────────────────
 * A guard should judge **what the process is**, not **who launched it**. The
 * fleet's harness (`scripts/orchestrator-harness/lane.sh`) exports the contract
 * its lanes need —
 *
 *     KIND=lane TAG=<issue> AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
 *     PI_MCP_SERVERS=none PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1
 *     LOOP_ENFORCER_DISABLED=1 …
 *
 * — so a lane started by that script acts, and the SAME work started by
 * anything else (a cloud-cell dispatch, a hand-run
 * `pi -p --provider … --no-session "<brief>"`, a worker script) does not.
 * Measured 2026-10-27: two cell lanes ran ~4 minutes inside linked worktrees and
 * produced ZERO commits — every `git commit` was refused by
 * `[skill-enforcer] 🚫 Blocked bash`, which is the gate `lane.sh` disables for
 * its own lanes. Nothing failed loudly; the lane simply could not act.
 *
 * Precedent, not invention: `extensions/builtin-tools/index.ts` already sets
 * exactly `SKILL_ENFORCER_DISABLED: "1"` / `LOOP_ENFORCER_DISABLED: "1"` for the
 * `task`/`subagent` children it spawns. This module is the same idea for the
 * process pi was started AS, derived from the environment pi can see, so that
 * nobody has to remember a variable.
 *
 * ── WHAT "A LANE" MEANS HERE ──────────────────────────────────────────────
 * Two observable facts, both read from the process itself:
 *   1. HEADLESS — print mode (`isPrintMode`, i.e. `-p`/`--print` on argv or
 *      `PI_MODE=print`). Delegated to the one helper that owns that rule, so a
 *      change there cannot leave this module behind.
 *   2. A LINKED WORKTREE — `git rev-parse --git-dir` and `--git-common-dir`
 *      resolve to DIFFERENT directories. In a repo's MAIN checkout both resolve
 *      to the same `<top>/.git`; in a linked worktree the git dir sits under
 *      `<common>/worktrees/<name>`.
 *
 * ⛔ The second test is STRUCTURAL, and it must stay that way. The obvious cheap
 * alternative — "the path contains `/worktrees/`" — is a measured FAIL-OPEN in
 * this repo: `extensions/main-worktree-guard/classify-git.mjs` records (#618/
 * #621) that a MAIN checkout whose own path carried a `worktrees` segment was
 * misread as a linked worktree, which lifted the hub-write gate for every target
 * under it. #1129 is the same class in the other direction (a symlinked path made
 * a hub look isolated). So the path is never consulted as evidence: it is used
 * only to *name* an inferred TAG (see `tagFromWorktree`), never to decide whether
 * this is a lane.
 *
 * ── THE HUB IS NOT WEAKENED, AND THAT IS THE WHOLE DISTINCTION ─────────────
 * The discriminator is **linked worktree vs hub**, NOT "headless vs
 * interactive": a headless `pi -p` whose cwd is the hub checkout derives NO lane
 * contract and stays guarded exactly as before — that is what
 * `extensions/main-worktree-guard` exists for. A non-git cwd, an unreadable git,
 * a git that is not installed, and a half of the structural test that will not
 * resolve all fail CLOSED (the guarded arm). A `task`/`subagent` CHILD changes
 * exactly ONE thing and the qualifier is load-bearing: **in a LINKED worktree**
 * it derives `lane: true` (the bypass must never depend on an ambient variable
 * being absent), but it is given NO inferred `KIND`/`TAG`, because relabelling
 * it `lane` would change the audience it is disclosed to. In the HUB it is
 * guarded like every other headless hub run — the supervision marker never
 * touches the `lane` predicate. See `isSupervisedChild`. Both directions, and
 * the child in the hub, are pinned in
 * `extensions/shared/headless-lane.test.ts` with a mutation per arm.
 *
 * ── ⛔ `GIT_*` MUST NOT BE ABLE TO RELOCATE THE ANSWER (T1, review cycle 1) ──
 * The structural test is only as good as the repository git was asked about, and
 * an EXPORTED `GIT_DIR` overrides the cwd. Measured with real git: from the hub
 * with `GIT_DIR=<hub>/.git/worktrees/wt1`,
 *
 *     git rev-parse --git-dir         → <hub>/.git/worktrees/wt1
 *     git rev-parse --git-common-dir  → <hub>/.git
 *     git rev-parse --show-toplevel  → <hub>
 *
 * — two different directories, so an unscrubbed read derives `lane: true` for a
 * process sitting IN THE HUB and lifts every skill gate there, while `why`
 * reports a worktree that is the hub. `scripts/orchestrator-harness/merge-reminder.py`
 * already keeps the same list (`GIT_ENV_DROP`) for the same reason: a git read
 * must not be relocatable by an inherited environment. The list below is kept
 * textually identical to it — two languages, so no shared constant is possible,
 * but ONE list to keep in step, and this comment names the other copy.
 *
 * ⛔ THE SCOPE OF THAT SCRUB IS THIS MODULE, NOT THE REPO — stated because the
 * paragraph above reads as if the vector were closed everywhere. The SAME
 * predicate is implemented a second time, UN-SCRUBBED, in
 * `extensions/main-worktree-guard/classify-git.mjs`'s `gitCheckoutIsLinkedWorktree`
 * (`:3965`): its two `rev-parse` probes pass no `env`, so they inherit
 * `process.env`. Measured: from the hub with `GIT_DIR=<hub>/.git/worktrees/<wt>`
 * the two spellings differ, that copy answers "linked worktree" for the HUB, and
 * `isWorktreeCwdWrite` returns true — i.e. the hub-write gate returns early. So
 * the scrub closes the relocation vector for skill-enforcer's derivation and does
 * NOT close it for the guard whose whole job is protecting the hub. The fix
 * belongs with that file (it carries 8+ un-scrubbed `rev-parse` reads and its own
 * 5326-line suite, so a one-call-site scrub here would leave it half-fixed and the
 * next reader falsely reassured); it is filed as **#2993**. `A14` in the sibling
 * suite pins the gap, so closing it flips the pin instead of letting this comment
 * drift.
 *
 * ── WHY IT WRITES `KIND`/`TAG` BACK INTO THE ENVIRONMENT ───────────────────
 * `KIND`/`TAG` are the harness's own vocabulary, and consumers read them from
 * the ENVIRONMENT rather than from a derivation. The write reaches exactly two
 * places: (a) CHILD PROCESSES, which exec with the mutated environment, and
 * (b) in-process consumers that read `process.env` LAZILY (after module load).
 * A derived lane that left them empty would keep working as a lane while every
 * child it spawned and every later reader described it as anonymous. So
 * `applyLaneContract` fills them in ONLY when absent (a launcher that set them
 * always wins) and only for a derived lane.
 *
 * ⛔ AND IT DOES **NOT** REACH THE REAPER FOR THIS PROCESS — a correction: the
 * first version of this paragraph claimed the launcher-ownership reapers would
 * see the inferred `TAG`, and `/proc/<pid>/environ` is fixed at EXEC, so a
 * post-load `process.env.TAG = …` can never appear there. Verified: the value is
 * in `process.env` and in a child's environ, and absent from this process's own
 * `/proc/self/environ`. Reaper ownership for a derived lane is therefore NOT
 * fixed by this write; that would be a reaper-side change (`pi-done-not-exited.py`
 * reads the exec-time block on purpose) and is deliberately not attempted here.
 *
 * ⛔ WHAT THE WRITE DOES **NOT** REACH — stated because the first version of this
 * comment claimed it did, and a fresh reviewer falsified it. `review-enforcer`
 * picks its disclosed AUDIENCE from `process.env.KIND` (#2148 — a `lane` is told
 * to push its final head and NOT to merge), but it resolves that role at
 * FACTORY-INVOKE time, and pi loads extensions in readdir order, importing and
 * invoking each one before the next (`review-enforcer/` sorts BEFORE
 * `skill-enforcer.ts` in the deployed farm, measured). The write therefore lands
 * too late for that one consumer, and a derived lane keeps the `self`-audience
 * line. Load order is NOT a contract — a fix that depended on this module loading
 * first would be an artifact of a directory listing — so the honest remedy is for
 * `reviewerRoleFor` to consult this derivation itself. That change belongs on
 * agent-infra#2966, not here: review-enforcer's suite needs `npm ci`, and this
 * change must not ship a call site it cannot exercise.
 */

import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename, resolve } from "node:path";
import { isPrintMode } from "./print-mode.js";

/** Everything the derivation concluded, plus the evidence it concluded it from. */
export interface LaneContract {
  /** print mode (`-p`/`--print`, or `PI_MODE=print`) */
  headless: boolean;
  /**
   * cwd is a LINKED worktree (structural git test — never a path substring).
   *
   * ⛔ MEASURED ONLY FOR A HEADLESS PROCESS. `deriveLaneContract` spawns NO git for
   * an interactive session (a hub session must not pay for this module), so it
   * returns `false` there WITHOUT probing — `false` means **not established**, not
   * "not a worktree". A consumer must gate on `headless`/`lane`; reading this field
   * on its own is the trap #2966's consumer must not fall into (review cycle 3, F3).
   */
  linkedWorktree: boolean;
  /** headless AND in a linked worktree — the predicate the gate bypasses use */
  lane: boolean;
  /** the process's own cwd, as it was measured */
  cwd: string;
  /** `git rev-parse --show-toplevel`, or null (also null for an interactive session — unmeasured) */
  topLevel: string | null;
  /** `git rev-parse --git-dir` (realpath'd), or null (also null for an interactive session — unmeasured) */
  gitDir: string | null;
  /** `git rev-parse --git-common-dir` (realpath'd), or null (also null for an interactive session — unmeasured) */
  commonDir: string | null;
  /** current branch, or null (also null for an interactive session — unmeasured) */
  branch: string | null;
  /** `KIND` as observed, or inferred ("lane") for a derived lane */
  kind: string | null;
  /** `TAG` as observed, or inferred from the worktree path / branch */
  tag: string | null;
  /** one line naming the derivation, for a log line an operator can check */
  why: string;
}

export interface LaneContractOptions {
  env?: Record<string, string | undefined>;
  argv?: string[];
  cwd?: string;
}

/**
 * A `task`/`subagent` child is NOT a lane for the AUDIENCE inference: it is
 * parent-supervised, it is told not to dispatch review, and `builtin-tools`
 * already disables the gates it needs disabled (`SKILL_ENFORCER_DISABLED`,
 * `LOOP_ENFORCER_DISABLED`). Marking it `KIND=lane` would flip its disclosed
 * audience to the harness line ("push your FINAL head") — advice for code a
 * supervised child must not merge. `TASK_HEARTBEAT=1` is the canonical marker
 * (`builtin-tools/index.ts` sets it UNCONDITIONALLY on every child spawn).
 *
 * ⛔ It does NOT gate the `lane` predicate itself. The bypass must not depend on
 * an ambient variable being absent: the measured failure WAS an inherited
 * environment, and a shell that happens to carry `TASK_HEARTBEAT=1` would
 * silently restore the block this module exists to remove. A child in a linked
 * worktree therefore still derives `lane: true` — which changes nothing for it,
 * because its launcher already set the bypass.
 */
function isSupervisedChild(env: Record<string, string | undefined>): boolean {
  return env.TASK_HEARTBEAT === "1" || env.AGENT_SKIP_REVIEW_GATE === "1";
}

/**
 * The `GIT_*` variables that can RELOCATE a git read away from the cwd, dropped
 * before any probe (see the header).
 *
 * ⛔ THERE ARE THREE COPIES OF THIS LIST, in three languages, and they must agree:
 * this one, `scripts/orchestrator-harness/merge-reminder.py`'s `GIT_ENV_DROP`, and
 * the `unset …` line in `scripts/orchestrator-harness/box-status.sh`. A shared
 * constant is impossible across TS/Python/shell, so `A13` in the sibling suite
 * parses all three and goes RED on drift — a comment naming the copies cannot. Add
 * a relocating variable to one and the measured fail-open returns: hub + an
 * exported `GIT_DIR` derives `lane: true` and lifts every gate in the hub.
 */
const GIT_ENV_DROP = [
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_INDEX_FILE",
  "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_COMMON_DIR",
] as const;

/**
 * The environment every `git` probe runs with: the caller's (or the process's),
 * minus anything that would answer about a repository other than the one at
 * `cwd`. Threading the CALLER's env here is what makes the derivation testable —
 * a probe that silently read `process.env` instead could not be pinned at all.
 */
function scrubbedGitEnv(env: Record<string, string | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (typeof v === "string") out[k] = v;
  for (const k of GIT_ENV_DROP) delete out[k];
  return out;
}

/** `git <args>` in `cwd`, with `env`, trimmed; null on any failure (absent git, not a repo, timeout). */
function git(args: string[], cwd: string, env: Record<string, string>): string | null {
  try {
    const out = execFileSync("git", args, {
      cwd,
      env,
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

function realpathOrNull(p: string | null): string | null {
  if (!p) return null;
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
}

/**
 * The structural linked-worktree test. Returns the resolved git dir, common dir
 * and the verdict, resolving BOTH git spellings against the cwd's realpath first:
 * git emits a RELATIVE `--git-common-dir` (`../.git`) when its own realpath'd cwd
 * sits under the gitdir's parent, while `--git-dir` is emitted absolute when the
 * SUPPLIED cwd spelling traverses a symlink — mixing the two bases lands them in
 * different repos (#1129).
 */
function classifyCheckout(
  cwd: string,
  env: Record<string, string>,
): {
  topLevel: string | null;
  gitDir: string | null;
  commonDir: string | null;
  linkedWorktree: boolean;
} {
  const topLevel = git(["rev-parse", "--show-toplevel"], cwd, env);
  const rawGitDir = git(["rev-parse", "--git-dir"], cwd, env);
  const rawCommonDir = git(["rev-parse", "--git-common-dir"], cwd, env);
  if (!rawGitDir || !rawCommonDir) {
    return { topLevel, gitDir: null, commonDir: null, linkedWorktree: false };
  }
  const base = realpathOrNull(cwd) ?? cwd;
  const gitDir = realpathOrNull(resolve(base, rawGitDir));
  const commonDir = realpathOrNull(resolve(base, rawCommonDir));
  if (!gitDir || !commonDir) {
    // An unresolvable half is an UNKNOWN checkout, not an isolated one. Fail
    // closed: the hub arm is the guarded one.
    return { topLevel, gitDir, commonDir, linkedWorktree: false };
  }
  return { topLevel, gitDir, commonDir, linkedWorktree: gitDir !== commonDir };
}

/**
 * Name the GUARDED arm by what was actually measured (review cycle 3, F1).
 *
 * ⛔ `HUB` is reserved for a MAIN checkout — the shape `A2` pins, where the git dir
 * IS `<top>/.git`. A submodule, a `--separate-git-dir` checkout and a
 * `core.worktree` checkout all fail the structural test too (their git dir lives
 * elsewhere), and calling each of them "the HUB checkout" asserted a fact that is
 * false. The VERDICT was always right; the operator-facing evidence was not — and
 * "linked worktree vs hub" is the one distinction this whole module exists to
 * make, so a line that misnames it is the misreport the file's own `A2` prose
 * argues against.
 *
 * The comparison is REALPATH'd on BOTH sides: `gitDir` is realpath'd (see
 * `classifyCheckout`), so comparing it against an unresolved `resolve(top, ".git")`
 * measured a real path against a LINK path — and named a MAIN checkout whose `.git`
 * is a SYMLINK a "non-worktree checkout", the same misreport in a narrower shape
 * (review cycle 4, F2; pinned by `A5d`). A `--separate-git-dir` checkout stays
 * correctly OUT: its `.git` is a FILE whose realpath is the file, never the git dir.
 */
function guardedWhy(checkout: {
  topLevel: string | null;
  gitDir: string | null;
  commonDir: string | null;
}): string {
  if (!checkout.topLevel) {
    // A bare repo (or a `git rev-parse` run with no working tree): git resolved,
    // there is simply no top level to name. Distinct from "not a git checkout".
    return checkout.gitDir
      ? `headless in a work-tree-less checkout ${checkout.gitDir} — there is no lane to derive (guarded)`
      : `headless outside any git checkout — there is no lane to derive (guarded)`;
  }
  const hubGitDir = realpathOrNull(resolve(checkout.topLevel, ".git")) ?? resolve(checkout.topLevel, ".git");
  if (checkout.gitDir && checkout.gitDir === hubGitDir) {
    return `headless in the HUB checkout ${checkout.topLevel} — the hub stays guarded`;
  }
  return (
    `headless in a non-worktree checkout ${checkout.topLevel} (its git dir ${checkout.gitDir} ` +
    `is not <top>/.git, and it has no separate common dir) — there is no lane to derive (guarded)`
  );
}

/**
 * A TAG from the worktree directory name — `w-10137`, `lane-10137`, `10137` —
 * which is how the fleet names them (`<repo>/.worktrees/w-<issue>`). Used only
 * to NAME the lane; it never decides whether this IS one.
 */
function tagFromWorktree(topLevel: string | null): string | null {
  if (!topLevel) return null;
  const m = /^(?:w-|lane-|fix-|wt-)?(\d+)$/.exec(basename(topLevel));
  return m ? m[1] : null;
}

/** A TAG from the branch — `fix/10137-thing`, `lane-10137`. Three digits minimum,
 *  so an ordinary word-with-a-number branch does not fabricate one. */
function tagFromBranch(branch: string | null): string | null {
  if (!branch || branch === "HEAD") return null;
  const m = /(?:^|[/_-])(\d{3,})(?:$|[/_-])/.exec(branch);
  return m ? m[1] : null;
}

/**
 * Derive the contract. Pure with respect to the process (it runs git, it never
 * writes anything), so tests can point it at a fixture hub/worktree by passing
 * `cwd` / `env` / `argv`.
 */
export function deriveLaneContract(options: LaneContractOptions = {}): LaneContract {
  const env = options.env ?? process.env;
  const argv = options.argv ?? process.argv;
  const cwd = options.cwd ?? process.cwd();
  const headless = isPrintMode(env, argv);

  const guarded = (why: string): LaneContract => ({
    headless,
    linkedWorktree: false,
    lane: false,
    cwd,
    topLevel: null,
    gitDir: null,
    commonDir: null,
    branch: null,
    kind: env.KIND ?? null,
    tag: env.TAG ?? null,
    why,
  });

  // No git is spawned for an interactive session: the distinction cannot change
  // its behaviour, and a hub session pays nothing for this module.
  if (!headless) return guarded("interactive session — not a lane");

  // ⛔ The probes run with the SCRUBBED env, never the raw one: an exported
  // `GIT_DIR` pointing at a linked worktree's gitdir would otherwise make the HUB
  // report two different git dirs and derive a lane there (see the header).
  const gitEnv = scrubbedGitEnv(env);
  const checkout = classifyCheckout(cwd, gitEnv);
  const branch = checkout.linkedWorktree ? git(["rev-parse", "--abbrev-ref", "HEAD"], cwd, gitEnv) : null;
  const inferredTag = tagFromWorktree(checkout.topLevel) ?? tagFromBranch(branch);
  // KIND/TAG are the harness's AUDIENCE vocabulary, so a supervised child is not
  // given an inferred one (see isSupervisedChild) — and it is not given the
  // DEFAULT one either: if this object reported `kind: "lane"` for a child whose
  // env it refuses to write, the contract would claim an inference it withholds,
  // and `why` (which an operator reads in the log) would contradict the field
  // beside it. Both stay exactly what the launcher set.
  const supervised = isSupervisedChild(env);
  const inferAudience = !supervised;

  if (!checkout.linkedWorktree) {
    return {
      headless,
      linkedWorktree: false,
      lane: false,
      cwd,
      topLevel: checkout.topLevel,
      gitDir: checkout.gitDir,
      commonDir: checkout.commonDir,
      branch,
      kind: env.KIND ?? null,
      tag: env.TAG ?? null,
      why: guardedWhy(checkout),
    };
  }

  // ⛔ `--show-toplevel` is NAMING-ONLY, never part of the structural test (the
  // test is git-dir ≠ common-dir, and both halves resolved to reach this arm). A
  // cwd INSIDE a linked worktree's git dir — `<hub>/.git/worktrees/<name>` — is a
  // lane by that test and can act on the worktree's branch, but git reports no
  // working tree, so there is no top level to name. Interpolating it raw printed
  // the literal `null` into the one line an operator reads as evidence (review
  // cycle 3, F2): the verdict was right, the line was not. Say where it is.
  const where = checkout.topLevel ?? `${checkout.gitDir} (a linked worktree's git dir — no working tree to name)`;

  return {
    headless,
    linkedWorktree: true,
    lane: true,
    cwd,
    topLevel: checkout.topLevel,
    gitDir: checkout.gitDir,
    commonDir: checkout.commonDir,
    branch,
    kind: env.KIND ?? (inferAudience ? "lane" : null),
    tag: env.TAG ?? (inferAudience ? inferredTag : null),
    why: supervised
      ? `headless in linked worktree ${where} (git-dir ${checkout.gitDir} ≠ common ${checkout.commonDir}) — lane; KIND/TAG NOT inferred (supervised child: its launcher owns the audience)`
      : `headless in linked worktree ${where} (git-dir ${checkout.gitDir} ≠ common ${checkout.commonDir})`,
  };
}

let cached: LaneContract | null = null;

/**
 * The process's contract, derived ONCE. The derivation shells out to git, and
 * the gate consults it on every tool call; a session does not change its cwd or
 * its mode, so memoising is correct and keeps the cost at zero per call.
 */
export function laneContract(): LaneContract {
  cached ??= deriveLaneContract();
  return cached;
}

/** Test seam: pin the contract (or `null` to forget a pinned one). */
export function _setLaneContractForTest(contract: LaneContract | null): void {
  cached = contract;
}

/** Test seam: forget the memoised contract so the next call re-derives it. */
export function _resetLaneContractForTest(): void {
  cached = null;
}

/**
 * Fill `KIND`/`TAG` in from the derivation when the launcher left them empty.
 * A launcher-set value ALWAYS wins (`lane.sh` exports `KIND=lane TAG=<issue>`),
 * and nothing is written for the guarded arm. Returns what it applied, for a log
 * line; the caller decides whether to print it.
 */
export function applyLaneContract(
  env: Record<string, string | undefined> = process.env,
  contract: LaneContract = laneContract(),
): { kind: string | null; tag: string | null } {
  if (!contract.lane) return { kind: null, tag: null };
  const applied: { kind: string | null; tag: string | null } = { kind: null, tag: null };
  // A supervised child is not given a lane AUDIENCE (see isSupervisedChild) —
  // even when its cwd derives one.
  if (isSupervisedChild(env)) return applied;
  if (!env.KIND && contract.kind) {
    env.KIND = contract.kind;
    applied.kind = contract.kind;
  }
  if (!env.TAG && contract.tag) {
    env.TAG = contract.tag;
    applied.tag = contract.tag;
  }
  return applied;
}
