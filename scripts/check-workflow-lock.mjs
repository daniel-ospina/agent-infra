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
    if (!fs.existsSync(abs)) {
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
 * Every `.github/workflows/*.yml` on disk must be CLASSIFIED: either one of the
 * three locked paths or an explicitly-listed intentionally-unlocked workflow.
 * Without this, adding `.github/workflows/extra.yml` was silently accepted, and
 * deleting `workflow-lock.yml` (the trusted structural leg) kept the suite green
 * because the reader-corpus floor was `>= 8` (#675 P2-d).
 * → [] when the directory is fully accounted for, else one message per gap.
 */
export function workflowCoverageFindings(root) {
  const dir = path.join(root, ".github", "workflows");
  let names;
  try {
    names = fs.readdirSync(dir).filter((name) => name.endsWith(".yml"));
  } catch (err) {
    return [`could not read .github/workflows under ${root}: ${err.message}`];
  }
  const present = new Set(names.map((name) => `.github/workflows/${name}`));
  const findings = [];
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
    return false;
  }
}

const IS_MAIN =
  process.argv[1] !== undefined && sameRealPath(process.argv[1], fileURLToPath(import.meta.url));
if (IS_MAIN) process.exit(main(process.argv));
