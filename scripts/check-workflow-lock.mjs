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
 * CLI
 * ---
 *   node scripts/check-workflow-lock.mjs                  # report; exit 1 on any mismatch
 *   node scripts/check-workflow-lock.mjs --update-lock    # rewrite scripts/workflow-lock.json
 *   node scripts/check-workflow-lock.mjs --root <dir>     # operate on <dir> instead of the repo root (tests)
 *
 * Exports `hashLockedFiles(root)` and `lockFindings(root, lock)` so the CI suite
 * can aggregate findings instead of throwing.
 */

import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const LOCK_REL = "scripts/workflow-lock.json";
export const LOCK_VERSION = 1;
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
  ".github/workflows/drift-check.yml",
  ".github/workflows/enforce-skills.yml",
  ".github/workflows/pipeline-compliance.yml",
  ".github/workflows/python-ci.yml",
  ".github/workflows/workflow-lock.yml",
]);
export const UPDATE_COMMAND = "node scripts/check-workflow-lock.mjs --update-lock";

/** Absolute path to the lock file under `root`. */
export function lockPath(root) {
  return path.join(root, LOCK_REL);
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
 * Hash every locked file under `root`.
 * → { "<repo-relative path>": "<sha256 hex>" } for exactly LOCKED_FILES.
 * Throws if a locked file is missing (the caller decides how to report that).
 */
export function hashLockedFiles(root) {
  const files = {};
  for (const rel of LOCKED_FILES) files[rel] = sha256File(path.join(root, rel));
  return files;
}

/** Read and parse `scripts/workflow-lock.json` under `root`. Throws if absent/invalid. */
export function readLock(root) {
  return JSON.parse(fs.readFileSync(lockPath(root), "utf8"));
}

/** Rewrite the lock under `root` from the current bytes. Returns the written lock object. */
export function writeLockFile(root) {
  const lock = { version: LOCK_VERSION, files: hashLockedFiles(root) };
  fs.mkdirSync(path.dirname(lockPath(root)), { recursive: true });
  fs.writeFileSync(lockPath(root), JSON.stringify(lock, null, 2) + "\n");
  return lock;
}

/**
 * Evaluate a lock against the files under `root`.
 * → [] when every locked file exists and matches its hash, else one message per
 * broken invariant. Returns findings (never throws) so the CI suite can aggregate.
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
    const actual = sha256File(abs);
    if (actual !== files[rel]) {
      findings.push(
        `the locked workflow file ${rel} changed (sha256 ${actual} != locked ${files[rel]}) — ` +
          "every edit to a locked workflow is a deliberate, reviewed act: re-run " +
          `\`${UPDATE_COMMAND}\` and commit the updated lock alongside the edit`
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
        `${path.relative(process.cwd(), lockPath(root)) || LOCK_REL}`
    );
    for (const rel of LOCKED_FILES) console.log(`   ${lock.files[rel]}  ${rel}`);
    return 0;
  }

  let lock;
  try {
    lock = readLock(root);
  } catch (err) {
    console.error(`❌ could not read ${path.relative(process.cwd(), lockPath(root))}: ${err.message}`);
    console.error(`   create it with \`${UPDATE_COMMAND}\``);
    return 1;
  }
  const findings = lockFindings(root, lock);
  // The coverage classification is a repo-root property (the fixture roots used
  // by `--root <dir>` hold only the three locked files on purpose).
  if (path.resolve(root) === REPO_ROOT) findings.push(...workflowCoverageFindings(root));
  if (findings.length > 0) {
    console.error(`❌ workflow content lock mismatch (${findings.length}):`);
    for (const msg of findings) console.error(`   - ${msg}`);
    return 1;
  }
  console.log(`✅ workflow content lock matches (${LOCKED_FILES.length} files)`);
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
