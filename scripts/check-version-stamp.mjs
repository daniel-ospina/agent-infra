#!/usr/bin/env node
/**
 * check-version-stamp.mjs — every install surface records the agent-infra version it
 * installed, and this check says per surface whether that install is still faithful
 * and still on `main`'s line (agent-infra#1760, keystone of #1759).
 *
 * WHY THIS EXISTS (the measured failure)
 * -------------------------------------
 * Nothing recorded what a surface actually installed. The one version artifact that
 * existed, `.agent-infra-version`, holds a RELEASE STRING ("0.1.0") that is byte-identical
 * on every box whatever was really copied — measured 2026-10-14: 21/22 extensions identical
 * but `cmux-session.ts` deployed at 74,220 B against the then-repo's 55,408 B (+18.8 KB the
 * repo did not have; re-synced by #1793), 4 stale scripts, and 79 installed scripts that exist
 * in no repo file. A string
 * cannot see any of that, and no commit was recorded at all.
 *
 * A commit COUNT cannot replace it either, and that is measured too: on this machine
 * `git merge-base --is-ancestor e8d5ce29 origin/main` → NO while
 * `git rev-list --count e8d5ce29..origin/main` → 1 (measured 2026-10-14 against origin/main
 * `db720aeb`; the COUNT moves as main advances — it read 3 two commits later — which is the point:
 * a number that changes without the tree changing cannot be the test). A "N commits behind" check
 * calls a tree
 * that is not on main's line at all "1 behind". So the comparison here is **hash equality OR
 * `git merge-base --is-ancestor`**, never a count.
 *
 * WHAT A STAMP CONTAINS AND WHY
 * -----------------------------
 * `<surface>/.agent-infra-stamp.json` pins the COMMIT the installer came from and a
 * PAYLOAD HASH of the operational files it installed. The commit alone cannot distinguish a
 * hand-copied or hand-edited install (the +18.8 KB divergence above); the hash alone cannot say whether
 * the install is on main's line (the `e8d5ce29` cell). Together they answer the question.
 *
 * VERDICTS — exactly three, and no fourth hiding in the output
 * ------------------------------------------------------------
 *   unstamped  no stamp file, or a stamp that cannot answer the question it exists to
 *              answer (unparseable, wrong `version`, missing/ill-formed commit or hash,
 *              `commit: null` because the surface was installed from a tarball with no git
 *              identity, a stamped commit that is not present in this checkout, a payload
 *              root that cannot be read, a `payload.roots` that is not the fixed root set, or
 *              an `agentInfra.dirty` that is neither `true` nor `false` — a stamp that does
 *              not say whether its source checkout was clean cannot answer whether the
 *              recorded commit describes the payload).
 *              A hand-installed surface lands here BY CONSTRUCTION — absence is never read as
 *              "current". Fail-closed, never fail-open.
 *   in-sync    BOTH hold: the surface's recomputed payload hash equals the hash recorded in
 *              ITS OWN stamp (nobody edited the install after it was stamped), AND the stamped
 *              commit is an ancestor of (or equal to) the target ref — i.e. the install is a
 *              version that really is on main's line.
 *   drift      a stamp exists and one of those fails:
 *                reason `payload`  — the installed files changed after stamping
 *                                    (hand-edit, partial copy, a file added or removed)
 *                reason `dirty`    — the stamp was written from a checkout whose PAYLOAD ROOTS
 *                                    had uncommitted changes, so its recorded commit does not
 *                                    describe the installed bytes
 *                reason `diverged` — the stamped commit is NOT an ancestor of the target ref:
 *                                    a tree off main's line (the `e8d5ce29` case)
 *
 * HONEST SCOPE — what this deliberately does NOT answer
 * ----------------------------------------------------
 *   - It does not report staleness BY DISTANCE. A faithful install of an older commit that is
 *     still an ancestor of main reads `in-sync`; the commit and its relation are printed so a
 *     reader can see it, but "N commits behind" is the number this check exists to stop
 *     trusting. Deciding what to DO about a stale-but-faithful surface is #1552's convergence
 *     problem, not this keystone's.
 *   - It does not compare the surface's payload against the payload `main` WOULD install.
 *     That is a different question (propagation completeness) and it is what the drift-check
 *     suite answers at the repo level; folding it in here would make the verdict depend on
 *     which files a given installer version happened to ship.
 *   - It is not a content lock. A stamp records what was installed — it does not assert the
 *     install is correct, and a PR that edits a payload AND re-runs `--write` still passes.
 *     That same-commit bound is the accepted one for this guard. The ONE exception is the source
 *     checkout being dirty AT STAMP TIME: the stamp's own `agentInfra.dirty` is consulted (scoped
 *     to the payload roots), and such a stamp reads `drift` — its recorded commit does not
 *     describe the installed bytes. The stamp is still written (so the state is recorded and
 *     loud), but it can never certify `in-sync`.
 *   - `node_modules/` is excluded from the payload digest. It is machine-specific, huge and
 *     churns independently of the install; including it would make every surface drift on
 *     every dependency resolution (see #1069 for what that class costs). Named here so the
 *     exclusion is a stated limit, not a silent hole.
 *   - It does NOT see file MODE. The digest is content-only, so a `chmod` that drops (or adds) an
 *     exec bit on an installed `scripts/*.sh` — or any other permission change — leaves the hash
 *     identical and the surface `in-sync`. Modes are not part of "what was installed" here.
 *   - A payload root that RESOLVES (via symlink) outside the surface is followed, and the walk
 *     under it is UNBOUNDED (see the symlinked-root convention above). That is deliberate for a
 *     linked consumer, and it is stated so the containment this does NOT provide is a known
 *     limit rather than an assumed one.
 *
 * CLI
 * ---
 *   node scripts/check-version-stamp.mjs                      # report every surface; exit 1 on any drift/unstamped
 *   node scripts/check-version-stamp.mjs --surface <dir> ...  # explicit surfaces instead of the defaults
 *   node scripts/check-version-stamp.mjs --no-repos           # only the pi surface
 *   node scripts/check-version-stamp.mjs --write              # stamp the surface(s); mirrors `--update-lock`
 *   node scripts/check-version-stamp.mjs --ref <git-ref>      # target ref (default origin/main, else main)
 *   node scripts/check-version-stamp.mjs --repo <checkout>    # where the target ref resolves (default AGENT_INFRA_PATH)
 *   node scripts/check-version-stamp.mjs --no-fetch           # do not refresh the target ref first
 *   node scripts/check-version-stamp.mjs --json               # machine-readable report on stdout
 *   node scripts/check-version-stamp.mjs --quiet              # one line per surface, no preamble
 *
 * Exit: 0 = every surface in-sync · 1 = at least one drift/unstamped · 2 = cannot verify
 * (bad usage, git missing, an unresolvable ref, or NO surface found — an empty set is not a
 * green set). The 0/1/2 split mirrors `scripts/orchestrator-harness/check-port-drift.sh`.
 *
 * Exports the pure pieces so the suite can drive them directly instead of shelling out.
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MODULE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const STAMP_BASENAME = ".agent-infra-stamp.json";
export const LEGACY_VERSION_BASENAME = ".agent-infra-version";
export const STAMP_VERSION = 1;
export const PAYLOAD_ALGO = "sha256";

/**
 * The operational sub-trees a stamp covers, in digest order. Closed and spelled out —
 * "the payload" is a decision, not whatever a directory listing happened to contain.
 */
export const PAYLOAD_ROOTS = Object.freeze(["extensions", "skills", "scripts"]);

/** Directories that must never enter the digest. `node_modules` for the reason in the header. */
const PAYLOAD_EXCLUDE_DIRS = Object.freeze(new Set(["node_modules", ".git"]));

const REF_DEFAULT = "origin/main";

// ─────────────────────────────────────────────────────────────── payload digest ──

/**
 * Walk one payload root PHYSICALLY and return `{ "<relpath>": "<digest-fragment>" }` for every
 * entry under it, sorted by relative path.
 *
 * Conventions that matter, each with a reason:
 *   - A SYMLINKED ROOT IS RESOLVED (`realpath`) and then walked. For a linked consumer repo
 *     `skills/` and `scripts/` are symlinks into the agent-infra checkout (measured), and that
 *     resolved tree IS what the surface runs — hashing the link text instead would make a
 *     symlinked surface read as unchanged forever.
 *   - A symlink INSIDE the payload is DIGESTED AS ITS TARGET STRING, never followed. Following
 *     would let a link escape the surface, pull in an unbounded tree, or form a cycle; recording
 *     the target makes a re-pointed link a real, visible change.
 *   - Directories are recursed; `node_modules`/`.git` are pruned; everything else — dotfiles
 *     included — counts. A disabled extension directory or a stray lock file IS part of the
 *     installed surface, and excluding it would be a hole with no upside.
 *   - Missing root → no entries (not an error): a surface legitimately lacks a root when the
 *     consumer exempts it (`manifest.json` `check.exemptions`).
 */
/**
 * A payload read that failed for a reason OTHER than absence. Absence is a legitimate state (a
 * consumer may exempt a root); `EACCES`/`EPERM`/`ELOOP`/`EIO` are not — they mean the digest would
 * be a statement about bytes nobody read. Raising it is what keeps an unreadable directory from
 * being read as an empty one and a changed surface from reporting `in-sync`.
 */
export class PayloadReadError extends Error {
  constructor(abs, err) {
    super(`cannot read ${abs}: ${err?.code ?? err?.message ?? String(err)}`);
    this.name = "PayloadReadError";
    this.path = abs;
    this.code = err?.code ?? null;
  }
}

/** `ENOENT` is "absent". Every other errno is a cannot-verify. */
function absent(err) {
  return err?.code === "ENOENT";
}

export function payloadEntries(rootDir, relRoot) {
  // ⛔ A NULL-PROTOTYPE map, never `{}`. With a normal object, a payload file named `__proto__` at
  // the top of a root hits the prototype SETTER, and assigning a STRING to it is silently ignored —
  // so the own key is never created, `Object.keys()` omits the file, and the digest never covers it.
  // It could then be added, edited or re-pointed on any surface without the check noticing: a
  // fail-open in the one thing this tool promises to notice.
  const out = Object.create(null);
  const start = path.join(rootDir, relRoot);
  let real;
  try {
    real = fs.realpathSync(start);
  } catch (err) {
    // ENOENT means "absent" ONLY when the path itself is absent. A DANGLING SYMLINK also raises
    // ENOENT here while the path plainly exists: reading that as an absent root records "no
    // payload", and re-pointing the link elsewhere then stays invisible — the same false "the
    // install did not change" this fix class exists to close.
    if (absent(err)) {
      let lst = null;
      try {
        lst = fs.lstatSync(start);
      } catch {
        lst = null;
      }
      if (lst === null) return out; // genuinely absent — a consumer may exempt a root
    }
    throw new PayloadReadError(start, err);
  }
  const walk = (absDir, relDir) => {
    let names;
    try {
      names = fs.readdirSync(absDir);
    } catch (err) {
      if (absent(err)) return;
      throw new PayloadReadError(absDir, err);
    }
    for (const name of names.sort()) {
      const abs = path.join(absDir, name);
      // The stamp is this tool's OWN artifact, never installed payload. A payload root that
      // resolves to a directory CONTAINING it (e.g. `scripts -> .`) would otherwise fold the stamp
      // into the digest — and since `buildStamp` hashes before that file is written, every write
      // would be stale the moment it landed and write/verify could never agree.
      // Match the RESOLVED PATH, never the basename: matching the name at every depth made a
      // legitimately installed file that happens to carry that name invisible to the digest — a
      // fail-open in a tool whose whole job is to notice that an install changed.
      const lowerName = name.toLowerCase();
      const lowerBase = STAMP_BASENAME.toLowerCase();
      // ⛔ Only the SURFACE's OWN stamp and its own temp siblings may be excluded, and the gate is
      // the PATH, never the name: matching the name at any depth made an installed file called
      // `<stamp>.tmp-x` — or a DIRECTORY of that name, hiding a whole subtree — invisible to the
      // digest, so a tampered payload reported in-sync. Anchoring the parent also settles a
      // hardlink: a link to the stamp under a payload root has a different path, so it stays
      // payload and `--write` converges instead of invalidating the equality it just hashed.
      if (lowerName.startsWith(lowerBase)) {
        // Is this entry in the SURFACE's own directory? Compared by the parent's IDENTITY, not as a
        // path STRING: `realpathSync` echoes the case it was asked about, and a symlink target (or a
        // bind mount) that SPELLS the surface differently is still the same directory. A string
        // compare then digests the real stamp — permanent false drift that no `--write` can clear.
        let inSurfaceRoot = false;
        try {
          const parent = fs.statSync(path.dirname(abs));
          // Identity is UNAVAILABLE when the filesystem cannot identify files: `0 === 0` would then
          // be true for every pair, so the test would claim "this is the surface's own directory"
          // everywhere and exclude every stamp-named file at any depth — a fail-open WIDER than the
          // path comparison it replaced. Fall back to the path comparison in that case.
          inSurfaceRoot =
            identUsable(parent) && identUsable(surfaceStat)
              ? parent.dev === surfaceStat.dev && parent.ino === surfaceStat.ino
              : path.dirname(abs) === surfaceReal;
        } catch {
          inSurfaceRoot = false;
        }
        if (inSurfaceRoot) {
          const suffix = lowerName.slice(lowerBase.length);
          let same = false;
          let entryIsDir = false;
          try {
            entryIsDir = fs.statSync(abs).isDirectory();
          } catch {
            entryIsDir = false;
          }
          // This tool's temp is a FILE created next to the stamp. A DIRECTORY of that name is
          // somebody else's data and must stay payload — excluding it hid its whole subtree.
          if (suffix.startsWith(".tmp-") && !entryIsDir) same = true;
          if (!same && suffix === "") {
            // Same FILE, whatever the spelling. A case-INSENSITIVE filesystem lets the same stamp be
            // reached as `.AGENT-INFRA-STAMP.JSON`, and a path-string comparison cannot recognise it
            // — so the stamp got digested and write/verify diverged forever. Compare IDENTITY
            // (dev+ino), right on both filesystem kinds: on a case-SENSITIVE one a differently-cased
            // name really is a different file and stays payload.
            try {
              const a = fs.statSync(abs);
              const b = fs.statSync(ownStamp);
              same =
                identUsable(a) && identUsable(b) ? a.dev === b.dev && a.ino === b.ino : abs === ownStamp;
            } catch {
              // The stamp may not exist yet (`--write` hashes BEFORE writing it).
              same = abs === ownStamp;
            }
          }
          if (same) continue;
        }
      }
      const rel = relDir === "" ? name : `${relDir}/${name}`;
      let st;
      try {
        st = fs.lstatSync(abs);
      } catch (err) {
        if (absent(err)) continue; // vanished between readdir and lstat
        throw new PayloadReadError(abs, err);
      }
      if (st.isSymbolicLink()) {
        let target;
        try {
          target = fs.readlinkSync(abs);
        } catch (err) {
          if (!absent(err)) throw new PayloadReadError(abs, err);
          target = "<unreadable-link>";
        }
        out[rel] = `link:${target}`;
        continue;
      }
      if (st.isDirectory()) {
        if (PAYLOAD_EXCLUDE_DIRS.has(name)) continue;
        walk(abs, rel);
        continue;
      }
      if (!st.isFile()) continue; // FIFO/socket/device: not an installed payload file
      try {
        out[rel] = createHash(PAYLOAD_ALGO).update(fs.readFileSync(abs)).digest("hex");
      } catch (err) {
        if (absent(err)) continue; // vanished between lstat and read
        throw new PayloadReadError(abs, err);
      }
    }
  };
  // The surface's OWN stamp, resolved — the one path the digest must never include. Anchored to the
  // SURFACE, not to the payload root: a root that resolves to an ANCESTOR (`extensions -> ..`) walks
  // the stamp in when the anchor is `path.join(real, …)`, and write/verify then never converge.
  let surfaceReal = rootDir;
  try {
    surfaceReal = fs.realpathSync(rootDir);
  } catch {
    surfaceReal = path.resolve(rootDir);
  }
  const ownStamp = path.join(surfaceReal, STAMP_BASENAME);
  // The surface directory's identity, for the parent comparison below.
  let surfaceStat = { dev: 0, ino: 0 };
  try {
    surfaceStat = fs.statSync(surfaceReal);
  } catch {
    surfaceStat = { dev: 0, ino: 0 };
  }
  walk(real, "");
  return out;
}

/**
 * Digest a whole payload: one line per (root, relpath) pair, `"<root>/<relpath>\0<fragment>\n"`,
 * roots in PAYLOAD_ROOTS order and entries sorted — so the digest is a pure function of the
 * installed bytes and their names.
 *
 * The line format deliberately includes the ROOT: a file that moved from `scripts/` to
 * `extensions/` is a different install, and a root-less digest would have to collide with itself.
 * → `{ hash, files }`
 */
export function hashPayload(surfaceDir, roots = PAYLOAD_ROOTS) {
  const digest = createHash(PAYLOAD_ALGO);
  let files = 0;
  for (const root of roots) {
    const entries = payloadEntries(surfaceDir, root);
    for (const rel of Object.keys(entries).sort()) {
      digest.update(`${root}/${rel}\0${entries[rel]}\n`);
      files += 1;
    }
  }
  return { hash: digest.digest("hex"), files };
}

// ──────────────────────────────────────────────────────────────── stamp read/write ──

/** Absolute path to the stamp under `surfaceDir`. */
export function stampPath(surfaceDir) {
  return path.join(surfaceDir, STAMP_BASENAME);
}

/**
 * `git -C <repo> ...` → trimmed stdout, or null when the command fails.
 * Never throws: every caller has to decide what "cannot answer" means, and an exception here
 * would turn a verification gap into a crash.
 */
function git(repo, args) {
  try {
    return execFileSync("git", ["-C", repo, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

/**
 * Is the `git` BINARY runnable at all? `git()` collapses every failure to null, so without this a
 * container with no git installed is told its perfectly healthy checkout "is not a git checkout" —
 * a false statement about the named repo that sends an operator to inspect the wrong thing.
 */
function gitAvailable() {
  try {
    execFileSync("git", ["--version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/** The agent-infra checkout this run reads `manifest.json` and the target ref from. */
export function resolveRepo(explicit) {
  // An EXPLICIT `--repo` must NOT fall through to a fallback. The caller named a checkout; if that
  // checkout cannot answer, the honest answer is "cannot verify" — not a verdict computed against
  // whatever checkout this script happens to live in. Silently substituting one repo for another is
  // the fail-open this whole check exists to refuse (a check that answers a question nobody asked).
  // ANY string means the caller named a repo — including "" (see the --repo guard in parseArgs).
  // An empty value must NOT fall through to a fallback: the verdict would then be computed against
  // a checkout the operator never named, which is the fail-open this function's own docstring
  // refuses.
  const named = typeof explicit === "string";
  const candidates = named ? [explicit] : [process.env.AGENT_INFRA_PATH, MODULE_ROOT];
  for (const c of candidates) {
    if (typeof c !== "string" || c === "") continue;
    const abs = path.resolve(c);
    if (fs.existsSync(path.join(abs, "manifest.json"))) return abs;
  }
  return null;
}

/** The manifest version, or null. Informational metadata on the stamp — never a verdict input. */
function manifestVersion(repo) {
  try {
    return JSON.parse(fs.readFileSync(path.join(repo, "manifest.json"), "utf8")).version ?? null;
  } catch {
    return null;
  }
}

/** `{ commit, dirty }` for the checkout the install came from. `commit` may be null. */
export function installIdentity(repo) {
  const commit = git(repo, ["rev-parse", "HEAD"]);
  // `dirty` is scoped to the PAYLOAD ROOTS, not the whole checkout. The question the stamp has to
  // answer is "does the recorded commit describe the installed payload?" — a change to `docs/`, or
  // to the stamp file itself, does not touch that payload. A whole-repo `git status` answered a
  // different question and flagged every surface stamped while an unrelated file was being edited
  // (and, for a surface that IS the checkout, the stamp file it had just written). A path that does
  // not exist is not an error for `git status --porcelain -- <path>`.
  const porcelain = git(repo, ["status", "--porcelain", "--", ...PAYLOAD_ROOTS]);
  return {
    commit: commit !== null && /^[0-9a-f]{40}$/.test(commit) ? commit : null,
    dirty: porcelain === null ? null : porcelain !== "",
  };
}

/** Build the stamp object for `surfaceDir` without writing it. */
export function buildStamp(surfaceDir, repo) {
  // ⛔ ALL roots, unconditionally — never `PAYLOAD_ROOTS.filter(existsSync)`.
  // A root that was ABSENT at stamp time contributed nothing to the digest, so if the stamp also
  // recorded only the roots it saw, the later appearance of that root could not change the hash and
  // the surface verified `in-sync` forever. Reproduced (VGATE, 2026-10-14): a surface stamped with
  // only `scripts/` present stayed `in-sync` after `extensions/sneaky.ts` was added, while adding a
  // file INSIDE an existing root was correctly `drift`. The universe of roots must be fixed at
  // build time, not inferred from what happened to exist.
  const roots = PAYLOAD_ROOTS;
  const payload = hashPayload(surfaceDir, roots);
  const id = installIdentity(repo);
  const surface = path.resolve(surfaceDir);
  const root = path.resolve(repo);
  return {
    version: STAMP_VERSION,
    // The checkout itself IS a valid surface (agent-infra checked against agent-infra), and it must
    // not read as `installed-surface` merely because `root + sep` is not a prefix of `root`.
    kind: surface === root || surface.startsWith(root + path.sep) ? "agent-infra-checkout" : "installed-surface",
    installedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    agentInfra: {
      version: manifestVersion(repo),
      commit: id.commit,
      dirty: id.dirty,
    },
    payload: {
      algo: PAYLOAD_ALGO,
      roots,
      files: payload.files,
      hash: payload.hash,
    },
  };
}

/**
 * Write the stamp for `surfaceDir`. → the stamp object. Throws only on a genuine IO failure.
 *
 * Write-temp-then-rename, never in place. An in-place `writeFileSync` truncates the real stamp
 * first, so a failure in the window (ENOSPC/EFBIG/EIO) leaves the surface with a DESTROYED stamp
 * where a valid one used to be — data loss on the one artifact that makes the surface checkable.
 * The rename is atomic, and it also replaces a symlinked stamp PATH rather than writing through it.
 */
export function writeStamp(surfaceDir, repo) {
  const stamp = buildStamp(surfaceDir, repo);
  fs.mkdirSync(surfaceDir, { recursive: true });
  const target = stampPath(surfaceDir);
  const tmp = `${target}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(stamp, null, 2) + "\n");
    fs.renameSync(tmp, target);
  } finally {
    fs.rmSync(tmp, { force: true }); // no-op after a successful rename; the failure path cleans up
  }
  return stamp;
}

const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;

/**
 * Parse + structurally validate a stamp. → `{ ok: true, stamp }` or `{ ok: false, reason }`.
 *
 * This is the fail-closed gate: every shape that would leave the ancestry or the hash
 * UNASKABLE is an `unstamped`, not a pass. `commit: null` is included on purpose — a surface
 * installed without a git identity cannot be compared to main's line at all, and quietly
 * reporting it `in-sync` on the strength of its hash alone is precisely the false green this
 * check exists to remove.
 */
export function validateStamp(raw) {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, reason: "not a JSON object" };
  }
  if (raw.version !== STAMP_VERSION) {
    return { ok: false, reason: `version ${JSON.stringify(raw.version ?? null)} != ${STAMP_VERSION}` };
  }
  const ai = raw.agentInfra;
  if (ai === null || typeof ai !== "object" || Array.isArray(ai)) {
    return { ok: false, reason: "no agentInfra block" };
  }
  if (typeof ai.commit !== "string" || !HEX40.test(ai.commit)) {
    return {
      ok: false,
      reason:
        ai.commit === null || ai.commit === undefined
          ? "no commit identity (installed without git) — ancestry is unanswerable"
          : `agentInfra.commit is not a 40-hex sha (${JSON.stringify(ai.commit)})`,
    };
  }
  const pl = raw.payload;
  if (pl === null || typeof pl !== "object" || Array.isArray(pl)) {
    return { ok: false, reason: "no payload block" };
  }
  if (pl.algo !== PAYLOAD_ALGO) {
    return { ok: false, reason: `payload.algo ${JSON.stringify(pl.algo ?? null)} != ${PAYLOAD_ALGO}` };
  }
  if (typeof pl.hash !== "string" || !HEX64.test(pl.hash)) {
    return { ok: false, reason: "payload.hash is not a sha256 hex digest" };
  }
  if (!Array.isArray(pl.roots) || pl.roots.some((r) => typeof r !== "string")) {
    return { ok: false, reason: "payload.roots is not an array of strings" };
  }
  // The recorded roots must be EXACTLY the fixed root set. An older, hand-written or foreign stamp
  // can otherwise declare a narrower universe than the reader recomputes over (or the same universe
  // in a different order/duplication) and the two would silently diverge. Comparing the serialized
  // form makes the reader's universe unable to differ from the writer's.
  if (JSON.stringify(pl.roots) !== JSON.stringify(PAYLOAD_ROOTS)) {
    return {
      // The roots are echoed into a message, so clip them: an unbounded array here is a second
      // channel by which a hostile stamp inflates the report.
      ok: false,
      reason: `payload.roots ${clip(JSON.stringify(pl.roots))} != the fixed payload roots ${JSON.stringify(PAYLOAD_ROOTS)}`,
    };
  }
  return { ok: true, stamp: raw };
}

/** Read + validate the stamp under `surfaceDir`. */
export function readStamp(surfaceDir) {
  let text;
  try {
    text = fs.readFileSync(stampPath(surfaceDir), "utf8");
  } catch (err) {
    return { ok: false, reason: err.code === "ENOENT" ? "no stamp file" : `unreadable: ${err.message}` };
  }
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (err) {
    return { ok: false, reason: `stamp is not valid JSON: ${err.message}` };
  }
  const verdict = validateStamp(raw);
  // Carry a BOUNDED projection even on refusal: a stamp can be structurally sound and rejected on
  // one field (a narrowed `payload.roots`), and reporting "(no commit)" for a stamp that plainly
  // names one is a false statement about the reader's own artifact.
  // ⛔ A PROJECTION, never the raw object. Passing `raw` through made `--json` stringify arbitrary
  // input: a deeply nested stamp crashed the run with `RangeError: Maximum call stack size
  // exceeded` and an EMPTY report (measured: 48 KB in at depth 8000), and a non-string commit made
  // the human line throw. Only these fields are ever read, and each is type-guarded here.
  // Project in BOTH branches. A VALID stamp carrying one unexpected deep key still reached
  // `JSON.stringify` through this path and crashed `--json` with an empty report, so "project only
  // on refusal" closed half the hole. The projection carries every field any consumer reads.
  return { ...verdict, stamp: stampProjection(raw) };
}

/**
 * A bounded, type-guarded view of a stamp, for the report. Every field is optional in unvalidated
 * input, so each is narrowed explicitly — this object is what `--json` prints and what the human
 * line reads a commit from. Bounded in SIZE as well as type: the whole object is serialized, so an
 * unbounded `roots` array or string measured a 48 KB stamp into a 10 MB report.
 */
const PROJECTION_MAX_STRING = 64;
const PROJECTION_MAX_ROOTS = 16;

/** Truncate any string the report echoes back, so a hostile stamp cannot inflate the output. */
function clip(v) {
  return typeof v === "string" && v.length > PROJECTION_MAX_STRING ? `${v.slice(0, PROJECTION_MAX_STRING)}…` : v;
}

/** A `dev`/`ino` of 0 means this filesystem cannot identify files (some SMB/FUSE mounts) — see the
 * exclusion in `payloadEntries`, where `0 === 0` would otherwise match everything. */
export function identUsable(st) {
  return !(st.dev === 0 && st.ino === 0);
}

function stampProjection(raw) {
  const obj = raw !== null && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const ai =
    obj.agentInfra !== null && typeof obj.agentInfra === "object" && !Array.isArray(obj.agentInfra)
      ? obj.agentInfra
      : {};
  const pl =
    obj.payload !== null && typeof obj.payload === "object" && !Array.isArray(obj.payload)
      ? obj.payload
      : {};
  return {
    version: typeof obj.version === "number" ? obj.version : null,
    agentInfra: {
      version: clip(typeof ai.version === "string" ? ai.version : null),
      commit: clip(typeof ai.commit === "string" ? ai.commit : null),
      dirty: typeof ai.dirty === "boolean" ? ai.dirty : null,
    },
    payload: {
      algo: clip(typeof pl.algo === "string" ? pl.algo : null),
      roots: Array.isArray(pl.roots)
        ? pl.roots.slice(0, PROJECTION_MAX_ROOTS).filter((r) => typeof r === "string").map(clip)
        : null,
      files: typeof pl.files === "number" ? pl.files : null,
      hash: clip(typeof pl.hash === "string" ? pl.hash : null),
    },
  };
}

// ──────────────────────────────────────────────────────────── ancestry / verdicts ──

/**
 * Resolve the target ref in `repo`. → `{ ref, sha }` or `{ error }`.
 * `--fetch` refresh is the caller's job (see `refreshRef`), because a stale ref is exactly the
 * false pass `check-port-drift.sh` was bitten by, and a fetch that silently does nothing would
 * reintroduce it here.
 */
export function resolveRef(repo, ref) {
  const sha = git(repo, ["rev-parse", "--verify", "-q", `${ref}^{commit}`]);
  if (sha === null || !HEX40.test(sha)) return { error: `cannot resolve ref '${ref}' in ${repo}` };
  return { ref, sha };
}

/** A conservative remote-branch name: no leading '-', no whitespace, no shell/refspec metacharacters. */
const SAFE_BRANCH = /^[A-Za-z0-9._\/-]+$/;

/**
 * Refresh the target ref. → `{ fetched, warning, error }`.
 * A failed FETCH is LOUD and non-fatal: the check continues against the local ref and says so.
 * A bad REF NAME is fatal (exit 2): it is a refusal to run the fetch at all, not a stale ref.
 * Silently continuing would report "in-sync" from a ref that may have moved — the stale-flag
 * false pass, in the one place it costs the most.
 */
export function refreshRef(repo, ref) {
  if (!ref.startsWith("origin/")) return { fetched: false, warning: null };
  const branch = ref.slice("origin/".length);
  if (branch === "" || branch.startsWith("-") || !SAFE_BRANCH.test(branch)) {
    return { fetched: false, warning: null, error: `bad ref '${ref}' — refusing to fetch a branch name that is not safe` };
  }
  // `--` terminates option parsing. Without it a ref such as `origin/--upload-pack=<cmd>` is taken
  // by git AS an option and `<cmd>` runs; the leading-dash and charset checks above are a second
  // layer, and `--` is the one that holds even if that layer is ever loosened.
  const ok = git(repo, ["fetch", "--quiet", "origin", "--", branch]) !== null;
  return {
    fetched: ok,
    warning: ok ? null : `could not fetch ${ref} — comparing the LOCAL ref, which may be stale`,
  };
}

/**
 * Classify `surfaceDir` against `target` (a resolved `{ ref, sha }`).
 * → `{ surface, verdict: "in-sync"|"drift"|"unstamped", reason, stamp, payload }`
 *
 * Ordering matters and is deliberate: an unanswerable stamp is `unstamped` BEFORE any hash or
 * ancestry work, so a surface can never be carried by half the evidence.
 */
export function classifySurface(surfaceDir, repo, target) {
  const abs = path.resolve(surfaceDir);
  const found = readStamp(abs);
  if (!found.ok) {
    return { surface: abs, verdict: "unstamped", reason: found.reason, stamp: found.stamp ?? null, payload: null };
  }
  const stamp = found.stamp;
  // Verify over the FULL root universe, not the stamp's recorded subset: a stamp written before a
  // root existed must not be able to narrow what the recomputation looks at (see buildStamp).
  let payload;
  try {
    payload = hashPayload(abs, PAYLOAD_ROOTS);
  } catch (err) {
    if (err instanceof PayloadReadError) {
      return { surface: abs, verdict: "unstamped", reason: `cannot read the payload — ${err.message}`, stamp, payload: null };
    }
    throw err;
  }
  if (payload.hash !== stamp.payload.hash) {
    return {
      surface: abs,
      verdict: "drift",
      reason: `payload hash ${payload.hash.slice(0, 12)}… != stamped ${stamp.payload.hash.slice(0, 12)}… (the install changed after it was stamped)`,
      stamp,
      payload,
    };
  }
  // A stamp written from a DIRTY source checkout cannot certify `in-sync`: the recorded commit does
  // not describe the installed bytes, so "a version that really is on main's line" is false about
  // this payload. The stamp records the fact (`agentInfra.dirty`) precisely so it can be consulted
  // here instead of being dead metadata — measured: origin's `extensions/alpha.ts` edited and
  // uncommitted, the surface holding those bytes, and the surface reading `in-sync`.
  if (stamp.agentInfra.dirty === true) {
    return {
      surface: abs,
      verdict: "drift",
      reason:
        `stamped from a DIRTY source checkout — commit ${stamp.agentInfra.commit.slice(0, 9)} does not ` +
        "describe the installed payload (uncommitted changes were present under the payload roots when " +
        "it was stamped); re-stamp from a clean checkout",
      stamp,
      payload,
    };
  }
  // `dirty` must be a definite `false` to certify. `null` (the status probe failed) and an absent
  // field are the same class of unanswerable as `commit: null`: the stamp does not say whether its
  // commit describes the payload, so it is `unstamped`, never a pass.
  if (stamp.agentInfra.dirty !== false) {
    return {
      surface: abs,
      verdict: "unstamped",
      reason:
        `agentInfra.dirty is ${JSON.stringify(stamp.agentInfra.dirty ?? null)} — the stamp does not say ` +
        "whether its source checkout was clean, so whether the recorded commit describes the installed " +
        "payload is unanswerable",
      stamp,
      payload,
    };
  }
  if (stamp.agentInfra.commit === target.sha) {
    return { surface: abs, verdict: "in-sync", reason: "payload matches its stamp; commit == target", stamp, payload };
  }
  // Resolve the stamped commit FIRST. `git merge-base --is-ancestor` exits 1 for "not an ancestor"
  // and 128 for "no such object", and `git()` collapses both to null — so without this an install
  // whose commit is absent (GC'd, shallow clone, a foreign stamp) reads as a DEFINITE divergence
  // instead of the unanswerable question it is.
  // `cat-file -e <sha>^{commit}` PEELS, so an annotated TAG object satisfies it and would be
  // presented as a commit. `rev-parse --verify` returns the PEELED sha instead, and a commit peels
  // to ITSELF — requiring equality is what makes "present" also mean "is a commit".
  const peeled = git(repo, ["rev-parse", "--verify", "-q", `${stamp.agentInfra.commit}^{commit}`]);
  if (peeled === null || peeled !== stamp.agentInfra.commit) {
    return {
      surface: abs,
      verdict: "unstamped",
      reason: `stamped commit ${stamp.agentInfra.commit.slice(0, 9)} is not present in ${repo} as a commit object — ancestry is unanswerable (GC'd, shallow, a tag object, or a stamp from another checkout)`,
      stamp,
      payload,
    };
  }
  // A COUNT IS NEVER CONSULTED HERE. `git merge-base --is-ancestor` is the only test.
  const isAncestor =
    git(repo, ["merge-base", "--is-ancestor", stamp.agentInfra.commit, target.sha]) !== null;
  if (!isAncestor) {
    // Three cases, three statements. If the TARGET is an ancestor of the stamp, the stamp is a
    // DESCENDANT of it (a rollback comparison) — reporting that as "off main's line" was false.
    // It is still `drift` (an install of a descendant is not an install of the target), but the
    // reason must say which case it is.
    const targetIsAncestor =
      git(repo, ["merge-base", "--is-ancestor", target.sha, stamp.agentInfra.commit]) !== null;
    return {
      surface: abs,
      verdict: "drift",
      reason: targetIsAncestor
        ? `stamped commit ${stamp.agentInfra.commit.slice(0, 9)} is AHEAD of ${target.ref} (${target.sha.slice(0, 9)}) — a rollback comparison, not an ancestor`
        : `stamped commit ${stamp.agentInfra.commit.slice(0, 9)} is NOT an ancestor of ${target.ref} (${target.sha.slice(0, 9)}) — this install is off main's line`,
      stamp,
      payload,
    };
  }
  return {
    surface: abs,
    verdict: "in-sync",
    reason: `payload matches its stamp; commit ${stamp.agentInfra.commit.slice(0, 9)} is an ancestor of ${target.ref}`,
    stamp,
    payload,
  };
}

// ───────────────────────────────────────────────────────────────────── surfaces ──

/** The pi surface: `$AGENT_INFRA_PI_HOME`, else `~/.pi/agent`. */
export function piSurface() {
  const override = process.env.AGENT_INFRA_PI_HOME;
  return override && override !== "" ? path.resolve(override) : path.join(os.homedir(), ".pi", "agent");
}

/**
 * Linked surfaces under `$AGENT_INFRA_REPOS_ROOT` (default `~/Documents/GitHub`): a direct child
 * directory carrying EITHER stamp artifact. `.agent-infra-version` counts because that is how
 * `sync` already discovers linked repos — a repo the fleet calls "linked" must be stampable, and
 * discovering only stamped repos would make a freshly-unstamped surface invisible instead of
 * `unstamped`. Depth-2, no recursion beyond it, mirroring `sync`'s own `find -maxdepth 2`.
 */
export function linkedSurfaces(reposRoot) {
  // Argument wins, then $AGENT_INFRA_REPOS_ROOT, then the default. The three sites (this default,
  // the header and --help) must agree; before this the env var was promised in two of them and
  // read in none, so an operator who scoped the scan silently got an unscoped one.
  const env = process.env.AGENT_INFRA_REPOS_ROOT;
  const namedRoot = Boolean((reposRoot && reposRoot !== "") || (env && env !== ""));
  const root =
    reposRoot && reposRoot !== ""
      ? path.resolve(reposRoot)
      : env && env !== ""
        ? path.resolve(env)
        : path.join(os.homedir(), "Documents", "GitHub");
  let names;
  try {
    names = fs.readdirSync(root);
  } catch (err) {
    // Absence is legitimate ONLY for the built-in default. Any other failure — and ANY failure at
    // all on a root the operator NAMED (--repos-root or $AGENT_INFRA_REPOS_ROOT), absence included
    // — is a cannot-verify: returning [] reports a green over a scope nobody read. The unread
    // DEFAULT root had this hole after the named root was fixed, so the fleet's ~20 linked repos
    // silently left the scan and the run still said in-sync / exit 0.
    if (err.code !== "ENOENT" || namedRoot) throw new PayloadReadError(root, err);
    return [];
  }
  const out = [];
  for (const name of names.sort()) {
    const dir = path.join(root, name);
    let st;
    try {
      st = fs.statSync(dir);
    } catch {
      continue;
    }
    if (!st.isDirectory()) continue;
    const linked =
      fs.existsSync(path.join(dir, STAMP_BASENAME)) || fs.existsSync(path.join(dir, LEGACY_VERSION_BASENAME));
    if (linked) out.push(dir);
  }
  return out;
}

// ───────────────────────────────────────────────────────────────────────── CLI ──

/** A refusal under `--json` must still put JSON on stdout: an empty stdout with exit 2 is
 * unparseable, so a caller iterating ~20 repos cannot tell a clean refusal from a crash, nor which
 * entry failed. Returns 2, so call sites read `return refuseJson(opts, why)`. */
function refuseJson(opts, message) {
  if (opts.json) console.log(JSON.stringify({ error: message }, null, 2));
  return 2;
}

function usage() {
  return [
    "Usage: node scripts/check-version-stamp.mjs [options]",
    "",
    "  --surface <dir>     check/stamp <dir> (repeatable); default = the pi surface + linked repos",
    "  --no-repos          default surfaces only: the pi surface",
    "  --repos-root <dir>  where linked repos live (default $AGENT_INFRA_REPOS_ROOT, else ~/Documents/GitHub)",
    "  --write             stamp the surface(s) instead of verifying them (mirrors --update-lock);",
    "                      RE-BASELINES: whatever is on disk is accepted, so any existing drift is erased",
    "  --ref <git-ref>     target ref to compare ancestry against (default origin/main, else main)",
    "  --repo <checkout>   agent-infra checkout the ref resolves in (default AGENT_INFRA_PATH)",
    "  --no-fetch          do not refresh the target ref first",
    "  --json              machine-readable report on stdout",
    "  --quiet             no preamble/summary, one line per surface",
    "  -h, --help          this text",
    "",
    "Verdicts: in-sync | drift | unstamped.  Exit: 0 all in-sync; 1 any drift/unstamped; 2 cannot verify.",
  ].join("\n");
}

function parseArgs(argv) {
  const opts = {
    surfaces: [],
    write: false,
    json: false,
    quiet: false,
    fetch: true,
    noRepos: false,
    ref: null,
    repo: null,
    reposRoot: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const need = (name) => {
      if (i + 1 >= argv.length) throw new Error(`${name} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case "--surface": {
        const value = need(a);
        // `path.resolve("")` is the CWD, so an empty value would stamp the directory the command
        // happened to run in — a write OUTSIDE the named surface. Refuse it (exit 2).
        if (value === "") throw new Error("--surface needs a non-empty value");
        opts.surfaces.push(value);
        break;
      }
      case "--write": opts.write = true; break;
      case "--json":
        opts.json = true;
        break;
      case "--quiet": opts.quiet = true; break;
      case "--no-fetch": opts.fetch = false; break;
      case "--no-repos": opts.noRepos = true; break;
      case "--ref": opts.ref = need(a); break;
      case "--repo": {
        const value = need(a);
        // An explicit `--repo` names a checkout. An EMPTY value names nothing, and `resolveRepo`
        // treats `""` as unnamed — so it would silently fall through to $AGENT_INFRA_PATH or this
        // script's own module root and answer about a repo nobody named. Same class as the
        // `--surface ""` refusal above; refused here as bad usage (exit 2).
        if (value === "") throw new Error("--repo needs a non-empty value");
        opts.repo = value;
        break;
      }
      case "--repos-root": {
        const value = need(a);
        // Same class as --surface/--repo: an empty value is treated as UNNAMED by linkedSurfaces
        // and silently falls through to the env var, then to the built-in default — a scan of a
        // scope the operator did not name.
        if (value === "") throw new Error("--repos-root needs a non-empty value");
        opts.reposRoot = value;
        break;
      }
      case "-h":
      case "--help": opts.help = true; break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  return opts;
}

/**
 * The DEFAULT surface set: the pi surface (always) plus the linked repos unless `--no-repos`.
 *
 * A surface that is not a readable directory is dropped — but ONLY when it is the built-in default
 * (an absent `~/.pi/agent` is legitimate). A surface the operator NAMED via $AGENT_INFRA_PI_HOME
 * that cannot be read is a cannot-verify: dropping it and reporting the remaining surfaces green
 * is a pass computed over a scope nobody read — the vacuous pass this file refuses for the EMPTY
 * set, reached through the PARTIAL one.
 */
function defaultSurfaces(opts) {
  const out = [];
  const pi = piSurface();
  const namedPi = Boolean(process.env.AGENT_INFRA_PI_HOME && process.env.AGENT_INFRA_PI_HOME !== "");
  let piIsDir = false;
  let piErr = null;
  try {
    piIsDir = fs.statSync(pi).isDirectory();
  } catch (err) {
    piErr = err;
  }
  if (piIsDir) out.push(pi);
  else if (namedPi) {
    // Keep the REAL errno. Hard-coding ENOENT told an operator that a permission-denied path "did
    // not exist", and the exists-but-is-a-file case has no ENOENT at all — a false statement about
    // a named path, which is the class this refusal exists to make honest.
    throw new PayloadReadError(pi, piErr ?? { code: "ENOTDIR", message: "not a directory" });
  }
  if (!opts.noRepos) {
    for (const dir of linkedSurfaces(opts.reposRoot)) {
      try {
        if (fs.statSync(dir).isDirectory()) out.push(dir);
      } catch {
        // Vanished between discovery and the check — simply gone.
      }
    }
  }
  return out;
}

/** The value-taking options, so a scan can tell a flag from a VALUE that merely looks like one. */
const VALUE_OPTS = Object.freeze(["--surface", "--ref", "--repo", "--repos-root"]);

/** Did the caller ask for JSON? Scans the WHOLE argv, value-aware: `--repo --json --bogus` consumed
 * the literal token `--json` as a value and must not count (over-report), while `--repo "" --json`
 * —which throws at the first token— still must (under-report). Reading the flag only when `parseArgs`
 * reaches its `case` got the first right and the second wrong; a bare `argv.includes` got them the
 * other way round. */
function jsonRequested(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--json") return true;
    if (VALUE_OPTS.includes(argv[i])) i += 1;
  }
  return false;
}

function main(argv) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (err) {
    console.error(`❌ check-version-stamp: ${err.message}`);
    console.error(usage());
    // `opts` does not exist on this path by construction, so the flag is read straight off argv.
    return refuseJson({ json: jsonRequested(argv) }, err.message);
  }
  if (opts.help) {
    // `--json` promises stdout is machine-readable, and a usage text is not JSON. A consumer that
    // piped us through `jq` got a parse error on a successful run.
    console.log(opts.json ? JSON.stringify({ usage: usage() }, null, 2) : usage());
    return 0;
  }

  const repo = resolveRepo(opts.repo);
  if (repo === null) {
    const why =
      "no agent-infra checkout (no manifest.json) — pass --repo or set AGENT_INFRA_PATH";
    console.error(`❌ check-version-stamp: ${why}`);
    return refuseJson(opts, why);
  }
  if (!gitAvailable()) {
    const why = "git is not available on PATH — ancestry cannot be established";
    console.error(`❌ check-version-stamp: ${why}`);
    return refuseJson(opts, why);
  }
  if (git(repo, ["rev-parse", "--git-dir"]) === null) {
    // Worded to what the probe actually supports. `git --version` can succeed while real commands
    // fail (a broken wrapper on PATH) and a stale worktree `.git` can point nowhere, so asserting
    // "not a git checkout" about a healthy repo sends an operator to inspect the wrong thing —
    // exactly the class `gitAvailable()` exists to close.
    const why = `${repo} cannot be read as a git checkout (\`git rev-parse --git-dir\` failed) — ancestry cannot be established`;
    console.error(`❌ check-version-stamp: ${why}`);
    return refuseJson(opts, why);
  }

  let surfaces;
  try {
    surfaces =
      opts.surfaces.length > 0
        ? opts.surfaces.map((s) => path.resolve(s))
        // The pi surface is a DEFAULT surface and is checked UNCONDITIONALLY; `--no-repos` disables
        // only the linked-repo scan. Testing `opts.noRepos` on the pi branch too made the flag whose
        // documented meaning is "only the pi surface" hand back an EMPTY set — the tool then refused
        // to check anything, the exact opposite of the documented behaviour.
        : defaultSurfaces(opts);
  } catch (err) {
    // A repos root the operator NAMED that cannot be read is a cannot-verify, never "no linked
    // repos": the latter reports a green over a scope nobody read (see linkedSurfaces).
    if (err instanceof PayloadReadError) {
      console.error(`❌ check-version-stamp: ${err.message}`);
      return refuseJson(opts, err.message);
    }
    throw err;
  }

  // AN EMPTY SURFACE SET IS NOT A GREEN ONE. Reporting "✅ in-sync" over nothing is the vacuous
  // pass this whole check exists to refuse, so it is exit 2 ("cannot verify"), matching
  // check-port-drift.sh's own 0/1/2 split.
  if (surfaces.length === 0) {
    const why = "no surfaces found — nothing was verified (an empty set is not a pass)";
    console.error(`❌ check-version-stamp: ${why}`);
    return refuseJson(opts, why);
  }

  // ── --write: stamp, then stop. Mirrors `check-workflow-lock.mjs --update-lock`. ──
  if (opts.write) {
    // `--json` must mean "stdout is JSON" on EVERY path that prints to stdout: the write path used
    // to print its human line regardless, so `--write --json | jq` failed to parse a run that had
    // succeeded, with no signal that the flag was dropped.
    const written = [];
    for (const dir of surfaces) {
      try {
        // Never CONJURE a surface. `--write` on a mistyped path created the tree and reported a
        // 0-file stamp as success, on a tool whose whole doctrine is "an empty set is not a pass".
        let st = null;
        try {
          st = fs.statSync(dir);
        } catch {
          st = null;
        }
        if (st === null || !st.isDirectory()) {
          console.error(
            `❌ check-version-stamp: ${dir} does not exist as a directory — refusing to create a surface in order to stamp it`
          );
          // ...and `--json` promises stdout is machine-readable on EVERY path, including this
          // refusal: it returned 2 with an EMPTY stdout, so a consumer scanning a repo list could
          // not tell which entries were written before the bad one.
          if (opts.json) console.log(JSON.stringify({ written, error: `${dir} is not a directory` }, null, 2));
          return 2;
        }
        const prior = readStamp(dir);
        const stamp = writeStamp(dir, repo);
        // A write ACCEPTS whatever is on disk now, so say it when one erased a difference:
        // otherwise an operator cannot tell a first stamp from a drift being laundered into a green
        // baseline, on the one command that can hide drift. PAYLOAD is not the only way to drift —
        // a re-stamp from a different commit, or from a dirty checkout, erases an ancestry drift
        // just as silently.
        let note = "";
        if (prior.ok) {
          const was = [];
          if (prior.stamp.payload.hash !== stamp.payload.hash) {
            was.push(`payload ${prior.stamp.payload.hash.slice(0, 12)}… → ${stamp.payload.hash.slice(0, 12)}…`);
          }
          if (prior.stamp.agentInfra.commit !== stamp.agentInfra.commit) {
            was.push(
              `commit ${String(prior.stamp.agentInfra.commit).slice(0, 9)} → ${String(stamp.agentInfra.commit).slice(0, 9)}`
            );
          }
          if (prior.stamp.agentInfra.dirty === true) was.push("the previous stamp came from a dirty checkout");
          if (was.length > 0) note = ` — RE-BASELINED (was drift: ${was.join("; ")})`;
        } else if (prior.reason !== "no stamp file") {
          note = ` — WARNING: replaced a stamp that was not valid (${prior.reason})`;
        }
        // The stamp is written either way — the state is recorded — but a dirty source is said
        // LOUDLY, because this stamp can never certify `in-sync` (verification reads it as drift).
        if (stamp.agentInfra.dirty === true) {
          console.error(
            `⚠️  ${dir} was stamped from a DIRTY source checkout — its commit does not describe the ` +
              "payload, so verification will read this surface as drift until it is re-stamped from a clean checkout"
          );
        }
        // A stamp that can NEVER certify is worth saying out loud: `validateStamp` refuses a null
        // commit, so every future verify of this surface fails. An EMPTY payload is a DIFFERENT
        // case — its digest is stable (sha256 of nothing) and it does certify — so it gets a
        // factual note, not a claim of impossibility that the next verify would contradict.
        if (stamp.agentInfra.commit === null) {
          console.error(
            `⚠️  ${dir} was stamped with NO COMMIT IDENTITY — verification will never report this surface in-sync`
          );
        } else if (stamp.payload.files === 0) {
          console.error(`ℹ️  ${dir} was stamped with an EMPTY payload — no files under ${PAYLOAD_ROOTS.join(", ")}`);
        }
        const entry = {
          surface: dir,
          version: stamp.version ?? null,
          commit: stamp.agentInfra.commit,
          dirty: stamp.agentInfra.dirty,
          files: stamp.payload.files,
          hash: stamp.payload.hash,
          note: note === "" ? null : note,
        };
        if (opts.json) written.push(entry);
        else {
          console.log(
            `✅ stamped ${dir} — commit ${(stamp.agentInfra.commit ?? "none").slice(0, 9)}, ` +
              `${stamp.payload.files} files, ${stamp.payload.hash.slice(0, 12)}…${note}`
          );
        }
      } catch (err) {
        console.error(`❌ could not stamp ${dir}: ${err.message}`);
        // A `--json` consumer must always get JSON on stdout, including on the failure path — an
        // empty stdout with exit 2 is unparseable, and the caller cannot tell a crash from a refusal.
        if (opts.json) console.log(JSON.stringify({ written, error: err.message }, null, 2));
        return 2;
      }
    }
    if (opts.json) console.log(JSON.stringify({ written, counts: { written: written.length } }, null, 2));
    return 0;
  }

  // ── verify ──
  const ref = opts.ref ?? (git(repo, ["rev-parse", "--verify", "-q", `${REF_DEFAULT}^{commit}`]) !== null ? REF_DEFAULT : "main");
  let warning = null;
  if (opts.fetch) {
    const r = refreshRef(repo, ref);
    if (r.error !== undefined) {
      console.error(`❌ check-version-stamp: ${r.error}`);
      return refuseJson(opts, r.error);
    }
    warning = r.warning;
  }
  const target = resolveRef(repo, ref);
  if (target.error !== undefined) {
    console.error(`❌ check-version-stamp: ${target.error}`);
    return refuseJson(opts, target.error);
  }

  const results = surfaces.map((dir) => classifySurface(dir, repo, target));
  const counts = { "in-sync": 0, drift: 0, unstamped: 0 };
  for (const r of results) counts[r.verdict] += 1;

  if (opts.json) {
    console.log(JSON.stringify({ ref: target.ref, sha: target.sha, warning, counts, results }, null, 2));
  } else {
    // A stale ref is a WARNING, not report chrome: `--quiet` suppresses the preamble/summary,
    // never the fact that the comparison may be against a ref that did not move. The exit code is
    // unchanged — an offline machine can still answer the payload question.
    if (warning !== null) console.error(`⚠️  ${warning}`);
    for (const r of results) {
      const icon = r.verdict === "in-sync" ? "✅" : r.verdict === "drift" ? "❌" : "⚠️ ";
      // Type-guarded: `stamp` on a refused surface is a projection of UNVALIDATED input, so
      // `commit` is not guaranteed to be a string even now.
      const sha = r.stamp?.agentInfra?.commit;
      const who = typeof sha === "string" ? `commit ${sha.slice(0, 9)}` : "no commit";
      console.log(`${icon} ${r.verdict.padEnd(9)} ${r.surface}  (${who})`);
      // Printed for EVERY verdict, `in-sync` included. HONEST SCOPE promises the commit and its
      // relation are shown to the reader, and the relation lives in `reason` — suppressing it for
      // the one verdict the promise is about told the reader that the thing the check deliberately
      // does not report is being reported ("in-sync" read as "up to date").
      console.log(`     ${r.reason}`);
    }
    if (!opts.quiet) {
      console.log(
        `\n${surfaces.length} surface(s) vs ${target.ref} (${target.sha.slice(0, 9)}): ` +
          `in-sync ${counts["in-sync"]} · drift ${counts.drift} · unstamped ${counts.unstamped}`
      );
    }
  }

  return counts.drift > 0 || counts.unstamped > 0 ? 1 : 0;
}

// `process.argv[1]` is the path the CLI was invoked AS; `import.meta.url` is the module's realpath.
// Comparing them raw made `main()` a no-op (print nothing, exit 0 — a silent pass) whenever an
// ancestor is a symlink, which is the exact defect check-workflow-lock.mjs closed for itself
// (#708). Compare realpaths, and fall back to a resolved-path comparison rather than to "different".
function sameRealPath(a, b) {
  try {
    return fs.realpathSync(a) === fs.realpathSync(b);
  } catch {
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
if (IS_MAIN) {
  // ⛔ exitCode, never `process.exit()`: writing to a PIPE is asynchronous in Node, and exiting
  // discards whatever is still queued. Measured: `--json | jq` truncated the report at the 64 KiB
  // pipe buffer on 10/10 runs — a silent loss, with the exit code still looking correct. Setting
  // `exitCode` lets the event loop drain the writes before the process ends.
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    // An uncaught throw would exit 1 — the code this tool DOCUMENTS as `drift`. A crash is not a
    // verdict, it is a cannot-verify, so it must not be read as "your install changed".
    console.error(`❌ check-version-stamp: unexpected failure — ${err && err.stack ? err.stack : String(err)}`);
    process.exitCode = 2;
  }
}
