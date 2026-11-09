#!/usr/bin/env node
/**
 * check-workflow-lock.mjs — byte-level content lock for the three pin-gate
 * workflow files (#666; architecture decision posted on the issue, 2026-09-10).
 *
 * WHY A CONTENT LOCK, NOT A SEMANTICS MODEL
 * -----------------------------------------
 * The wiring guard used to answer "will GitHub actually run the pin suite when
 * this workflow runs?" by reading GitHub Actions *execution semantics* out of a
 * hand-written YAML parser with a DENYLIST of things that can neutralise a step.
 * Two review rounds found six working bypasses, and the second round's were
 * created by the first round's fixes (`shell:` on the step, job/workflow-level
 * `defaults.run.shell`, `env:` with `NODE_OPTIONS`/`BASH_ENV`/`PATH`,
 * `container:`/`services:`, `matrix.exclude` covering every combination, YAML
 * escape sequences in quoted keys). Every one of those requires EDITING one of
 * the three workflow files.
 *
 * That is the property we actually want: a CONTENT property, not a semantics
 * property — "these workflow files still say what we agreed they say." So this
 * module hashes the bytes and compares them to `scripts/workflow-lock.json`.
 * There is no YAML parsing, no shell modelling, and nothing left to enumerate.
 *
 * WHAT IT IS NOT
 * --------------
 * A lock asserts *unchanged*, not *correct*. A pinned workflow can still be
 * wrong; the lock only means "nobody edited it since the hash was recorded." A
 * PR that edits a locked workflow AND the lock together still passes — that is
 * the accepted same-commit bound recorded for this guard, made conspicuous by
 * the lock's name and the visible hash change. The deliberate-update tax (any
 * legitimate edit to a locked workflow must re-run `--update-lock`) is intended
 * loud behaviour.
 *
 * WHY ONE LOCK FILE PER REGION, NOT ONE HASH PER FILE (agent-infra#1955)
 * --------------------------------------------------------------------
 * The lock used to be ONE file holding ONE hash per workflow. Every edit to a
 * locked workflow rewrote a line of that file, so two branches that both edited
 * a locked workflow ALWAYS conflicted on it — even when their actual edits were
 * in different jobs. That conflict cannot be resolved by choosing a side (both
 * recorded values are wrong for the merged tree), so resolving it meant a
 * regenerate, which moves the head and discards the green check-run evidence.
 * Measured on this repo (2026-11: 14 open PRs, of which 2 touched a locked
 * workflow, 0 conflicted on the lock; the October measurement was 17 of 54 open
 * PRs, and the last 60 commits touching `ci.yml` ALL also touched
 * `ci-main.yml`) — the contention is *same-file*, always.
 *
 * So the recording is partitioned by REGION: one top-level file region, and one
 * region per job under `jobs:`. Each region hash is stored in its own file under
 * `scripts/workflow-lock.d/<workflow path>/<region>.sha256`. Two consequences,
 * and both are the point:
 *
 *   1. Two branches editing DIFFERENT regions touch DIFFERENT files, so the lock
 *      cannot conflict at all — the merge is a clean union of independent
 *      equality constraints, and the merged tree is GREEN with no re-lock.
 *   2. Two branches editing the SAME region still conflict — but that is the
 *      region their real edits collide in, i.e. the lock no longer amplifies an
 *      ordinary "main moved" into a conflict of its own.
 *
 * The partition cannot weaken the guard, by construction: the regions are a
 * PARTITION of the same bytes (every byte belongs to exactly one region), the
 * region NAME SET is closed (a renamed/added/removed region is RED), and the
 * check is per-region equality. So an edit anywhere is RED unless re-locked,
 * exactly as with the whole-file hash — this is a granularity change, not a
 * semantic one. #666's decision (a CONTENT property, not an execution-semantics
 * model) is untouched.
 *
 * WHAT NO DESIGN CAN FIX (the bound, stated so nobody re-derives it): the lock
 * records content that only exists AFTER the merge. Any per-branch record of
 * current content is therefore wrong at the merge result whenever both sides
 * changed the same region, so that case is irreducible while the lock stays a
 * committed equality record. The alternatives all trade the guard away: a
 * content-addressed (append-only) ledger leaves `main` unverifiable or green by
 * vacuity, a merge-time recompute needs a writer that can commit to `main`
 * (this repo merges server-side, squash-only, with no bot pushing to main), and
 * dropping the record reverses #666. Region granularity is the part that IS
 * removable, and it is what removes the amplification.
 *
 * CLI
 * ---
 *   node scripts/check-workflow-lock.mjs                  # report; exit 1 on any mismatch
 *   node scripts/check-workflow-lock.mjs --update-lock    # rewrite scripts/workflow-lock.d/
 *   node scripts/check-workflow-lock.mjs --root <dir>     # operate on <dir> instead of the repo root (tests)
 *
 * Exports `hashLockedFiles(root)`, `hashLockedRegions(root)` and
 * `lockFindings(root, lock)` so the CI suite can aggregate findings instead of
 * throwing.
 */

import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
/** The lock DIRECTORY: one subdirectory per locked workflow, one file per region. */
export const LOCK_DIR_REL = "scripts/workflow-lock.d";
/** The single-file lock this replaced (#1955). Only referenced by the migration hint. */
export const LEGACY_LOCK_REL = "scripts/workflow-lock.json";
export const LOCK_VERSION = 2;
/** A regionless file whose content is a bare sha256 — the shape of every lock entry. */
const SHA256_RE = /^[0-9a-f]{64}$/;
const REGION_FILE_RE = /\.sha256$/;
/** Region names are derived from YAML keys, so this is a guard against path tricks, not a style rule. */
const REGION_NAME_RE = /^[A-Za-z0-9_.~-]+$/;
/** The exact, closed set of locked paths. Not derived — spelling it out is the point. */
export const LOCKED_FILES = Object.freeze([
  ".github/workflows/ci.yml",
  ".github/workflows/node-ci.yml",
  ".github/workflows/ci-main.yml",
]);
/**
 * Workflows that are DELIBERATELY not byte-locked, listed explicitly so that a
 * workflow appearing on disk without appearing in either list is RED instead of
 * silently accepted (#675 P2-d) — and so that deleting one of these (notably
 * `workflow-lock.yml`, the trusted structural leg) is also RED.
 */
export const UNLOCKED_WORKFLOWS = Object.freeze([
  ".github/workflows/docs-ci.yml",
  ".github/workflows/admin-merge-detector.yml",
  ".github/workflows/drift-check.yml",
  ".github/workflows/enforce-skills.yml",
  ".github/workflows/pipeline-compliance.yml",
  ".github/workflows/python-ci.yml",
  ".github/workflows/workflow-lock.yml",
  // agent-infra#2160 — the harness single-source gate. Its own workflow on purpose: it would
  // otherwise live in the BYTE-LOCKED ci.yml, forcing every branch that touches the harness to also
  // re-cut the lock for `ci.yml`'s `jobs.ci` region — so two concurrent PRs contend on it every time
  // one of them re-locks. Unlocked and classified, per this file's own rule that a workflow must be
  // in one list or the other. (#1955 later made that contention region-scoped rather than per-file,
  // which narrows this reason but does not remove it: a harness PR that edits `ci.yml` still edits
  // `jobs.ci`.)
  ".github/workflows/harness-single-source.yml",
]);
export const UPDATE_COMMAND = "node scripts/check-workflow-lock.mjs --update-lock";

/** Absolute path to the lock DIRECTORY under `root`. */
export function lockPath(root) {
  return path.join(root, LOCK_DIR_REL);
}

/** Absolute path to one workflow's region directory under `root`. */
function regionDir(root, rel) {
  return path.join(lockPath(root), rel);
}

/** Absolute path to one region's lock file under `root`. */
export function regionPath(root, rel, region) {
  return path.join(regionDir(root, rel), `${region}.sha256`);
}

function isPlainMap(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

/**
 * Human label for a non-regular filesystem entry, from `lstatSync` (which does
 * NOT follow symlinks). Shared by the lock check and the coverage sweep so both
 * reject the same class with the same wording.
 */
function nonRegularKind(st) {
  if (st.isSymbolicLink()) return "a symlink";
  if (st.isDirectory()) return "a directory";
  if (st.isFIFO()) return "a FIFO";
  if (st.isSocket()) return "a socket";
  if (st.isBlockDevice()) return "a block device";
  if (st.isCharacterDevice()) return "a character device";
  return "not a regular file";
}

/**
 * `lstat` a path without dereferencing it. → the stat, or null when it is
 * missing. Used instead of `existsSync` (which follows symlinks — a dangling
 * symlink would read as "missing" and a live one as "present") because the whole
 * point of the symlink guard is to see the LINK, not its target.
 */
function lstatNoFollow(absPath) {
  try {
    return fs.lstatSync(absPath);
  } catch {
    return null;
  }
}

/**
 * The first non-directory component of `rel` under `root`, as a finding-ready
 * label, or null when every component is a real directory.
 *
 * #675 third revision (P2) — a symlinked `.github/workflows` DIRECTORY was not
 * caught: `fs.readdirSync` follows the directory link and `lstatNoFollow` only
 * refuses to follow the LAST component, so `.github/workflows` → `real-workflows`
 * left both local legs GREEN while GitHub — which does not follow a symlinked
 * workflow directory either — ran 0 jobs. Every ancestor is `lstat`ed here, so a
 * link anywhere on the path from `root` down to the file's parent is RED.
 *
 * `root` itself is deliberately NOT checked: temp fixture roots live under
 * `/tmp`, which is itself a symlink on macOS (`/tmp` → `/private/tmp`), and the
 * question is what is linked INSIDE the repo, not how the repo is reached.
 */
function symlinkedAncestor(root, rel) {
  const parts = rel.split("/");
  let current = root;
  for (let i = 0; i < parts.length - 1; i++) {
    current = path.join(current, parts[i]);
    const st = lstatNoFollow(current);
    if (st !== null && st.isSymbolicLink()) return parts.slice(0, i + 1).join("/");
  }
  return null;
}

/**
 * A `lstat`-based refusal shared by `lockFindings` and `workflowCoverageFindings`:
 * a symlinked ancestor DIRECTORY under `root`, or a symlinked final component.
 * → a finding message, or null when the path is reached through real directories.
 */
function symlinkFinding(root, rel) {
  const ancestor = symlinkedAncestor(root, rel);
  if (ancestor !== null) {
    return (
      `${ancestor} is a symlink — a workflow path must be reached through real directories: ` +
      "GitHub does not follow a symlinked directory under .github/, so every workflow inside it " +
      "is a broken entry that runs 0 jobs; replace the link with the real directory"
    );
  }
  const st = lstatNoFollow(path.join(root, rel));
  if (st !== null && !st.isFile()) {
    return (
      `${rel} is ${nonRegularKind(st)} — a workflow under .github/workflows must be a regular ` +
      "file: GitHub does not follow a symlinked workflow entry (it is a broken workflow that " +
      "runs 0 jobs), so a non-regular entry cannot stand in for a workflow"
    );
  }
  return null;
}

/**
 * The workflow filenames under `root/.github/workflows`, or a finding.
 *
 * #675 third revision (P2) — `.yml` only meant a `.yaml` workflow was NEVER
 * classified, never symlink-checked, and never reported: adding
 * `.github/workflows/evil.yaml` (or symlinking to it) left the lock GREEN, while
 * GitHub runs `.yaml` workflow files. GitHub documents both extensions, so both
 * are enumerated.
 */
const WORKFLOW_FILE_RE = /\.ya?ml$/;
function workflowNames(root) {
  const dir = path.join(root, ".github", "workflows");
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (err) {
    return { findings: [`could not read ${path.relative(root, dir) || dir} under ${root}: ${err.message}`] };
  }
  return { names: names.filter((name) => WORKFLOW_FILE_RE.test(name)) };
}

/** sha256 of a file's bytes (no normalisation, no line-ending coercion). */
export function sha256File(absPath) {
  return createHash("sha256").update(fs.readFileSync(absPath)).digest("hex");
}

/**
 * Split a workflow's bytes into addressable REGIONS — a PARTITION, not a parse.
 * → Map<region name, exact bytes of that region>.
 *
 * The split is deliberately dumb, and it is safe *because* it is dumb:
 *
 *   - A top-level key (`^key:` at column 0) starts a region named `top.<key>`.
 *     Everything before the first top-level key (file-level comments) is `top`.
 *   - A key at two-space indent starts `jobs.<key>` — but only while we are
 *     inside the `jobs:` region, so `on.pull_request:` and `concurrency.group:`
 *     stay in their `top.*` region instead of inventing job regions.
 *   - Every other line belongs to the region it is in, so the union of the
 *     regions is EXACTLY the file's bytes: nothing is dropped, nothing overlaps.
 *
 * No YAML structure is modelled beyond those two line shapes, and that is the
 * point: the partition carries no security decision. A mis-split (a `run: |`
 * body containing a line that looks like a job key) can only change GRANULARITY,
 * because every byte still lands in exactly one region and the check compares
 * the region NAME SET as well as the hashes. A weak writer is fine; a weak
 * partition is impossible.
 *
 * Region names are made unique by a `~<n>` suffix if the same key appears twice
 * (invalid YAML — which is precisely why it cannot be a way to hide a region).
 */
export function lockRegions(text) {
  const lines = text.split("\n");
  const regions = new Map();
  let name = "top";
  let body = [];
  const seen = new Map();

  const flush = () => {
    // The initial `top` region holds nothing when the file starts with a key;
    // recording it as an empty region would emit a phantom lock entry AND break
    // the reassembly invariant (`join("\n")` of the regions === the file).
    if (body.length === 0 && name === "top") return;
    const count = (seen.get(name) ?? 0) + 1;
    seen.set(name, count);
    regions.set(count === 1 ? name : `${name}~${count}`, body.join("\n"));
  };

  let inJobs = false;
  for (const line of lines) {
    const topKey = /^([A-Za-z_][A-Za-z0-9_.-]*):(?:\s|$)/.exec(line);
    const jobKey = /^ {2}([A-Za-z0-9_.-]+):(?:\s|$)/.exec(line);
    if (topKey !== null) {
      flush();
      name = `top.${topKey[1]}`;
      body = [line];
      inJobs = topKey[1] === "jobs";
      continue;
    }
    if (inJobs && jobKey !== null) {
      flush();
      name = `jobs.${jobKey[1]}`;
      body = [line];
      continue;
    }
    body.push(line);
  }
  flush();
  // A lone `top` region can only exist before the first `top.*` key and is kept:
  // dropping it would leave those bytes unrecorded.
  return regions;
}

/**
 * Hash every locked file under `root`, whole-file.
 * → { "<repo-relative path>": "<sha256 hex>" } for exactly LOCKED_FILES.
 * Throws if a locked file is missing (the caller decides how to report that).
 *
 * NOT what the lock stores any more (#1955 — the lock is region-keyed, see
 * `hashLockedRegions`). Kept because "is this byte-identical to main's copy?" is
 * a different, still-useful question for a caller that only wants a digest.
 */
export function hashLockedFiles(root) {
  const files = {};
  for (const rel of LOCKED_FILES) files[rel] = sha256File(path.join(root, rel));
  return files;
}

/**
 * → { "<repo-relative path>": { "<region>": "<sha256 hex>" } }
 * Throws if a locked file is missing (the caller decides how to report that).
 */
export function hashLockedRegions(root) {
  const files = {};
  for (const rel of LOCKED_FILES) {
    const text = fs.readFileSync(path.join(root, rel), "utf8");
    const regions = {};
    for (const [region, bytes] of lockRegions(text)) {
      regions[region] = createHash("sha256").update(bytes).digest("hex");
    }
    files[rel] = regions;
  }
  return files;
}

/**
 * Read the lock DIRECTORY under `root` into the same object shape the check
 * consumes: `{ version, files: { rel: { region: sha256 } } }`.
 *
 * A missing directory is NOT an error here — it reads as an empty lock, so
 * `lockFindings` reports the ordinary "does not cover <rel>" finding (with the
 * `--update-lock` remedy) instead of this function throwing and the whole check
 * dying with a stack trace.
 */
export function readLock(root) {
  const lock = { version: LOCK_VERSION, files: {} };
  const dir = lockPath(root);

  // Walk the lock directory for the directories that hold `<region>.sha256`
  // files. The workflow path is the directory's path RELATIVE to the lock dir
  // (`.github/workflows/ci.yml`), so the layout mirrors the repo and a nested
  // path cannot be mistaken for a region name.
  const walk = (abs, rel) => {
    let entries;
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch {
      return;
    }
    const files = entries.filter((e) => e.isFile());
    const dirs = entries.filter((e) => e.isDirectory());
    if (files.some((e) => REGION_FILE_RE.test(e.name))) {
      const regions = {};
      for (const entry of entries) {
        if (entry.isDirectory()) {
          // A nested directory inside a region directory is never an entry.
          regions[`!${entry.name}`] = "";
          continue;
        }
        if (!REGION_FILE_RE.test(entry.name)) {
          regions[`!${entry.name}`] = "";
          continue;
        }
        const region = entry.name.replace(REGION_FILE_RE, "");
        let raw;
        try {
          raw = fs.readFileSync(path.join(abs, entry.name), "utf8").trim();
        } catch {
          raw = "";
        }
        regions[region] = raw;
      }
      lock.files[rel] = regions;
      return;
    }
    // A plain FILE directly under the lock root is not a lock entry — recorded
    // with a null mapping so `lockFindings` refuses it rather than ignores it.
    for (const entry of files) lock.files[`${rel}/${entry.name}`] = null;
    for (const entry of dirs) walk(path.join(abs, entry.name), `${rel}/${entry.name}`);
  };
  walk(dir, "");
  // The walk starts at "", so top-level entries carry a leading slash.
  for (const key of Object.keys(lock.files)) {
    if (key.startsWith("/")) {
      lock.files[key.slice(1)] = lock.files[key];
      delete lock.files[key];
    }
  }
  return lock;
}

/**
 * Rewrite the lock DIRECTORY under `root` from the current bytes, and prune what
 * no longer exists (a removed region, a renamed job). Returns the written lock
 * object.
 *
 * Pruning is why the directory is self-limiting: a rename leaves ONE stale entry
 * until the next `--update-lock`, instead of accumulating forever. The prune is
 * also why `lockFindings` reports an unknown region as RED rather than ignoring
 * it — an entry nobody prunes is an entry nobody notices.
 */
export function writeLockFile(root) {
  const lock = { version: LOCK_VERSION, files: hashLockedRegions(root) };
  for (const rel of LOCKED_FILES) {
    const abs = regionDir(root, rel);
    fs.mkdirSync(abs, { recursive: true });
    const want = lock.files[rel];
    for (const [region, hash] of Object.entries(want)) {
      const file = regionPath(root, rel, region);
      let current = null;
      try {
        current = fs.readFileSync(file, "utf8").trim();
      } catch {
        current = null;
      }
      if (current !== hash) fs.writeFileSync(file, `${hash}\n`);
    }
    for (const entry of fs.readdirSync(abs)) {
      const region = REGION_FILE_RE.test(entry) ? entry.replace(REGION_FILE_RE, "") : null;
      if (region !== null && Object.hasOwn(want, region)) continue;
      fs.rmSync(path.join(abs, entry), { force: true });
    }
  }
  return lock;
}

/**
 * Evaluate a lock against the files under `root`.
 * → [] when every locked file exists and every REGION matches its hash, else one
 * message per broken invariant. Returns findings (never throws) so the CI suite
 * can aggregate.
 *
 * Region-level, not file-level (#1955): the finding names the region, so a
 * reader learns WHICH part of the workflow moved, and two branches editing
 * different regions never touch the same lock file.
 */
export function lockFindings(root, lock) {
  const findings = [];
  if (!isPlainMap(lock)) {
    return [`the workflow lock is not a JSON object — re-lock with \`${UPDATE_COMMAND}\``];
  }
  if (lock.version !== LOCK_VERSION) {
    findings.push(
      `the workflow lock version is ${JSON.stringify(lock.version ?? null)}, expected ` +
        `${LOCK_VERSION} — re-lock with \`${UPDATE_COMMAND}\``
    );
  }
  const files = lock.files;
  if (!isPlainMap(files)) {
    findings.push(`the workflow lock has no \`files\` mapping — re-lock with \`${UPDATE_COMMAND}\``);
    return findings;
  }
  for (const rel of LOCKED_FILES) {
    if (!Object.hasOwn(files, rel)) {
      findings.push(
        `the workflow lock does not cover ${rel} — the locked set is closed; re-lock with ` +
          `\`${UPDATE_COMMAND}\``
      );
    }
  }
  for (const rel of Object.keys(files)) {
    if (!LOCKED_FILES.includes(rel)) {
      findings.push(
        `the workflow lock covers an unexpected path ${rel} — the locked set must be exactly ` +
          `${JSON.stringify([...LOCKED_FILES])}; re-lock with \`${UPDATE_COMMAND}\` after removing it`
      );
    }
  }
  for (const rel of LOCKED_FILES) {
    if (!Object.hasOwn(files, rel)) continue;
    const abs = path.join(root, rel);
    // #675 P1-2 / third revision (P2) — a symlink must NOT satisfy the lock by
    // hashing its target, and a symlinked `.github` / `.github/workflows`
    // ANCESTOR directory is also called out: the file's own `lstat` cannot see an
    // ancestor link, and a linked directory means GitHub runs 0 jobs for every
    // workflow inside it. `symlinkFinding` covers both, and returns null for a
    // plain missing file so the MISSING wording below is used for that.
    const linked = symlinkFinding(root, rel);
    if (linked !== null) {
      findings.push(`${linked} (locked path ${rel})`);
      continue;
    }
    if (lstatNoFollow(abs) === null) {
      findings.push(
        `the locked workflow file ${rel} is MISSING — a locked file must exist; restore it, or ` +
          `re-lock with \`${UPDATE_COMMAND}\` if the removal is deliberate`
      );
      continue;
    }
    const recorded = files[rel];
    if (!isPlainMap(recorded)) {
      findings.push(
        `the workflow lock entry for ${rel} is not a region mapping — re-lock with ` +
          `\`${UPDATE_COMMAND}\``
      );
      continue;
    }
    const actualRegions = lockRegions(fs.readFileSync(abs, "utf8"));
    for (const [region, bytes] of actualRegions) {
      if (!Object.hasOwn(recorded, region)) {
        findings.push(
          `the locked workflow file ${rel} has a region \`${region}\` the lock does not cover — ` +
            "every edit to a locked workflow is a deliberate, reviewed act: re-run " +
            `\`${UPDATE_COMMAND}\` and commit the updated lock alongside the edit`
        );
        continue;
      }
      const actual = createHash("sha256").update(bytes).digest("hex");
      const locked = recorded[region];
      if (actual !== locked) {
        findings.push(
          `the locked workflow file ${rel} changed in region \`${region}\` ` +
            `(sha256 ${actual} != locked ${locked}) — every edit to a locked workflow is a ` +
            "deliberate, reviewed act: re-run " +
            `\`${UPDATE_COMMAND}\` and commit the updated lock alongside the edit`
        );
      }
    }
    for (const region of Object.keys(recorded)) {
      if (actualRegions.has(region)) continue;
      findings.push(
        `the workflow lock records region \`${region}\` of ${rel}, which no longer exists ` +
          `— prune it with \`${UPDATE_COMMAND}\``
      );
    }
  }
  return findings;
}

/**
 * Every workflow file on disk must be CLASSIFIED: either one of the three locked
 * paths or an explicitly-listed intentionally-unlocked workflow. Without this,
 * adding `.github/workflows/extra.yml` was silently accepted, and deleting
 * `workflow-lock.yml` (the trusted structural leg) kept the suite green because
 * the reader-corpus floor was `>= 8` (#675 P2-d).
 * → [] when the directory is fully accounted for, else one message per gap.
 */
export function workflowCoverageFindings(root) {
  const { names, findings: readFindings } = workflowNames(root);
  if (readFindings !== undefined) return readFindings;
  const present = new Set(names.map((name) => `.github/workflows/${name}`));
  const findings = [];
  // #675 third revision (P2) — a symlinked `.github/workflows` DIRECTORY must be
  // rejected in its own right: `readdirSync` follows it, and every file inside
  // classifies normally, so the whole workflow set could be reached through a link
  // GitHub does not follow.
  for (const rel of [".github", ".github/workflows"]) {
    const st = lstatNoFollow(path.join(root, rel));
    if (st !== null && st.isSymbolicLink()) {
      findings.push(
        `${rel} is a symlink — GitHub does not follow a symlinked directory under .github/, so ` +
          "every workflow inside it is a broken entry that runs 0 jobs; replace the link with " +
          "the real directory"
      );
    }
  }
  // #675 P1-2 — classification alone is not enough: a symlink named `ci.yml`
  // classifies as the locked path while GitHub runs 0 jobs for it. Reject any
  // non-regular entry under .github/workflows, classified or not. (`.yaml`
  // included: `WORKFLOW_FILE_RE` covers both extensions, #675 third revision P2.)
  for (const rel of present) {
    const finding = symlinkFinding(root, rel);
    if (finding !== null) findings.push(finding);
  }
  for (const rel of present) {
    if (LOCKED_FILES.includes(rel) || UNLOCKED_WORKFLOWS.includes(rel)) continue;
    findings.push(
      `${rel} is a workflow that is neither locked nor on the explicit unlocked allowlist — ` +
        "classify it deliberately (add it to LOCKED_FILES and re-lock, or to UNLOCKED_WORKFLOWS) " +
        "so a new workflow cannot be added silently"
    );
  }
  for (const rel of [...LOCKED_FILES, ...UNLOCKED_WORKFLOWS]) {
    if (present.has(rel)) continue;
    findings.push(
      `${rel} is missing — a workflow in the locked/unlocked allowlist was deleted ` +
        "(for .github/workflows/workflow-lock.yml that also removes the trusted structural leg)"
    );
  }
  return findings;
}

function main(argv) {
  const args = argv.slice(2);
  const rootIdx = args.indexOf("--root");
  const root = rootIdx >= 0 ? path.resolve(args[rootIdx + 1] ?? ".") : REPO_ROOT;

  if (args.includes("--update-lock")) {
    // #675 third revision (P2) — self-consistency. `writeLockFile` hashes through
    // whatever the path resolves to, so a SYMLINKED locked file used to print
    // `✅ workflow lock updated` while the very next verify run was RED (the hash
    // belonged to the link target). Refuse instead: no banner, exit 1, same
    // rejection `lockFindings` applies.
    const symlinked = LOCKED_FILES.map((rel) => symlinkFinding(root, rel)).filter(Boolean);
    if (symlinked.length > 0) {
      console.error(`❌ refusing to re-lock — ${symlinked.length} locked path(s) are not regular files:`);
      for (const msg of symlinked) console.error(`   - ${msg}`);
      return 1;
    }
    const lock = writeLockFile(root);
    console.log(
      `✅ workflow lock updated — ${LOCKED_FILES.length} files hashed into ` +
        `${path.relative(process.cwd(), lockPath(root)) || LOCK_DIR_REL}`
    );
    for (const rel of LOCKED_FILES) {
      const regions = lock.files[rel];
      const count = Object.keys(regions).length;
      console.log(`   ${rel} — ${count} region${count === 1 ? "" : "s"}`);
    }
    return 0;
  }

  let lock;
  try {
    lock = readLock(root);
  } catch (err) {
    console.error(`❌ could not read ${path.relative(process.cwd(), lockPath(root))}: ${err.message}`);
    console.error(`   create it with \`${UPDATE_COMMAND}\``);
    return 1;
  }  const findings = lockFindings(root, lock);
  // The coverage classification is a repo-root property (the fixture roots used
  // by `--root <dir>` hold only the three locked files on purpose).
  if (path.resolve(root) === REPO_ROOT) findings.push(...workflowCoverageFindings(root));
  if (findings.length > 0) {
    console.error(`❌ workflow content lock mismatch (${findings.length}):`);
    for (const msg of findings) console.error(`   - ${msg}`);
    return 1;
  }
  console.log(`✅ workflow content lock matches (${LOCKED_FILES.length} files, region-keyed)`);
  return 0;
}

/**
 * `process.argv[1]` is the path the CLI was INVOKED as; `import.meta.url` is the
 * module's realpath (Node resolves symlinks). Comparing a resolved-but-not-real
 * argv path against the realpath made this false whenever an ancestor is a
 * symlink (`/tmp` → `/private/tmp` on macOS), so `main()` never ran, nothing was
 * printed and the process exited 0 — verify mode silently "passed" and
 * `--update-lock` silently refused to rewrite while exiting 0 (a fresh instance
 * of issue #708). Compare realpaths on BOTH sides.
 */
function sameRealPath(a, b) {
  try {
    return fs.realpathSync(a) === fs.realpathSync(b);
  } catch {
    // #675 P2-f — "cannot resolve" is not "a different file". Returning false
    // here made IS_MAIN false whenever `process.argv[1]` no longer existed (e.g.
    // it was deleted mid-run), so `main()` never ran, nothing printed and the
    // process exited 0 — the exact silent no-op this comparison was introduced to
    // close (#708).
    //
    // Fall back to a literal comparison first. When that differs only because an
    // ANCESTOR is a symlink (`/tmp` → `/private/tmp`, `/var` → `/private/var` on
    // macOS) while `import.meta.url` is realpath-resolved, compare the RESOLVED
    // parent directory plus the basename — the link target's directory usually
    // still exists even when the file itself is gone. A genuinely different file
    // (different basename, or a different resolved directory) stays false.
    if (path.resolve(a) === path.resolve(b)) return true;
    try {
      return (
        path.basename(a) === path.basename(b) &&
        fs.realpathSync(path.dirname(a)) === fs.realpathSync(path.dirname(b))
      );
    } catch {
      return false;
    }
  }
}

const IS_MAIN =
  process.argv[1] !== undefined && sameRealPath(process.argv[1], fileURLToPath(import.meta.url));
if (IS_MAIN) process.exit(main(process.argv));
