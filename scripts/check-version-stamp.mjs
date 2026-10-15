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
 * but `cmux-session.ts` deployed at 74,220 B against the repo's 55,408 B (+18.8 KB main does
 * not have), 4 stale scripts, and 79 installed scripts that exist in no repo file. A string
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
 * hand-copied or hand-edited install (the +18.8 KB above); the hash alone cannot say whether
 * the install is on main's line (the `e8d5ce29` cell). Together they answer the question.
 *
 * VERDICTS — exactly three, and no fourth hiding in the output
 * ------------------------------------------------------------
 *   unstamped  no stamp file, or a stamp that cannot answer the question it exists to
 *              answer (unparseable, wrong `version`, missing/ill-formed commit or hash, or
 *              `commit: null` because the surface was installed from a tarball with no git
 *              identity). A hand-installed surface lands here BY CONSTRUCTION — absence is
 *              never read as "current". Fail-closed, never fail-open.
 *   in-sync    BOTH hold: the surface's recomputed payload hash equals the hash recorded in
 *              ITS OWN stamp (nobody edited the install after it was stamped), AND the stamped
 *              commit is an ancestor of (or equal to) the target ref — i.e. the install is a
 *              version that really is on main's line.
 *   drift      a stamp exists and one of those fails:
 *                reason `payload`  — the installed files changed after stamping
 *                                    (hand-edit, partial copy, a file added or removed)
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
 *     That same-commit bound is the accepted one for this guard.
 *   - `node_modules/` is excluded from the payload digest. It is machine-specific, huge and
 *     churns independently of the install; including it would make every surface drift on
 *     every dependency resolution (see #1069 for what that class costs). Named here so the
 *     exclusion is a stated limit, not a silent hole.
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
export function payloadEntries(rootDir, relRoot) {
  const out = {};
  const start = path.join(rootDir, relRoot);
  let real;
  try {
    real = fs.realpathSync(start);
  } catch {
    return out; // absent or dangling root — nothing under it to digest
  }
  const walk = (absDir, relDir) => {
    let names;
    try {
      names = fs.readdirSync(absDir);
    } catch {
      return;
    }
    for (const name of names.sort()) {
      const abs = path.join(absDir, name);
      const rel = relDir === "" ? name : `${relDir}/${name}`;
      let st;
      try {
        st = fs.lstatSync(abs);
      } catch {
        continue;
      }
      if (st.isSymbolicLink()) {
        let target;
        try {
          target = fs.readlinkSync(abs);
        } catch {
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
      } catch {
        out[rel] = "<unreadable>";
      }
    }
  };
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

/** The agent-infra checkout this run reads `manifest.json` and the target ref from. */
export function resolveRepo(explicit) {
  // An EXPLICIT `--repo` must NOT fall through to a fallback. The caller named a checkout; if that
  // checkout cannot answer, the honest answer is "cannot verify" — not a verdict computed against
  // whatever checkout this script happens to live in. Silently substituting one repo for another is
  // the fail-open this whole check exists to refuse (a check that answers a question nobody asked).
  const named = typeof explicit === "string" && explicit !== "";
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
  const porcelain = git(repo, ["status", "--porcelain"]);
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
  return {
    version: STAMP_VERSION,
    kind: path.resolve(surfaceDir).startsWith(path.resolve(repo) + path.sep)
      ? "agent-infra-checkout"
      : "installed-surface",
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

/** Write the stamp for `surfaceDir`. → the stamp object. Throws only on a genuine IO failure. */
export function writeStamp(surfaceDir, repo) {
  const stamp = buildStamp(surfaceDir, repo);
  fs.mkdirSync(surfaceDir, { recursive: true });
  fs.writeFileSync(stampPath(surfaceDir), JSON.stringify(stamp, null, 2) + "\n");
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
  return validateStamp(raw);
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

/**
 * Refresh the target ref. → `{ fetched: bool, warning: string|null }`.
 * A failed fetch is LOUD and non-fatal: the check continues against the local ref and says so.
 * Silently continuing would report "in-sync" from a ref that may have moved — the stale-flag
 * false pass, in the one place it costs the most.
 */
export function refreshRef(repo, ref) {
  if (!ref.startsWith("origin/")) return { fetched: false, warning: null };
  const branch = ref.slice("origin/".length);
  const ok = git(repo, ["fetch", "--quiet", "origin", branch]) !== null;
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
    return { surface: abs, verdict: "unstamped", reason: found.reason, stamp: null, payload: null };
  }
  const stamp = found.stamp;
  // Verify over the FULL root universe, not the stamp's recorded subset: a stamp written before a
  // root existed must not be able to narrow what the recomputation looks at (see buildStamp).
  const payload = hashPayload(abs, PAYLOAD_ROOTS);
  if (payload.hash !== stamp.payload.hash) {
    return {
      surface: abs,
      verdict: "drift",
      reason: `payload hash ${payload.hash.slice(0, 12)}… != stamped ${stamp.payload.hash.slice(0, 12)}… (the install changed after it was stamped)`,
      stamp,
      payload,
    };
  }
  if (stamp.agentInfra.commit === target.sha) {
    return { surface: abs, verdict: "in-sync", reason: "payload matches its stamp; commit == target", stamp, payload };
  }
  // A COUNT IS NEVER CONSULTED HERE. `git merge-base --is-ancestor` is the only test.
  const isAncestor =
    git(repo, ["merge-base", "--is-ancestor", stamp.agentInfra.commit, target.sha]) !== null;
  if (!isAncestor) {
    return {
      surface: abs,
      verdict: "drift",
      reason: `stamped commit ${stamp.agentInfra.commit.slice(0, 9)} is NOT an ancestor of ${target.ref} (${target.sha.slice(0, 9)}) — this install is off main's line`,
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
  const root = reposRoot && reposRoot !== "" ? path.resolve(reposRoot) : path.join(os.homedir(), "Documents", "GitHub");
  let names;
  try {
    names = fs.readdirSync(root);
  } catch {
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

function usage() {
  return [
    "Usage: node scripts/check-version-stamp.mjs [options]",
    "",
    "  --surface <dir>     check/stamp <dir> (repeatable); default = the pi surface + linked repos",
    "  --no-repos          default surfaces only: the pi surface",
    "  --repos-root <dir>  where linked repos live (default $AGENT_INFRA_REPOS_ROOT, else ~/Documents/GitHub)",
    "  --write             stamp the surface(s) instead of verifying them (mirrors --update-lock)",
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
      case "--surface": opts.surfaces.push(need(a)); break;
      case "--write": opts.write = true; break;
      case "--json": opts.json = true; break;
      case "--quiet": opts.quiet = true; break;
      case "--no-fetch": opts.fetch = false; break;
      case "--no-repos": opts.noRepos = true; break;
      case "--ref": opts.ref = need(a); break;
      case "--repo": opts.repo = need(a); break;
      case "--repos-root": opts.reposRoot = need(a); break;
      case "-h":
      case "--help": opts.help = true; break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  return opts;
}

function main(argv) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (err) {
    console.error(`❌ check-version-stamp: ${err.message}`);
    console.error(usage());
    return 2;
  }
  if (opts.help) {
    console.log(usage());
    return 0;
  }

  const repo = resolveRepo(opts.repo);
  if (repo === null) {
    console.error("❌ check-version-stamp: no agent-infra checkout (no manifest.json) — pass --repo or set AGENT_INFRA_PATH");
    return 2;
  }
  if (git(repo, ["rev-parse", "--git-dir"]) === null) {
    console.error(`❌ check-version-stamp: ${repo} is not a git checkout — ancestry cannot be established`);
    return 2;
  }

  const surfaces =
    opts.surfaces.length > 0
      ? opts.surfaces.map((s) => path.resolve(s))
      : [...(opts.noRepos ? [] : [piSurface()]), ...(opts.noRepos ? [] : linkedSurfaces(opts.reposRoot))]
          .filter((dir) => {
            try {
              return fs.statSync(dir).isDirectory();
            } catch {
              return false;
            }
          });

  // AN EMPTY SURFACE SET IS NOT A GREEN ONE. Reporting "✅ in-sync" over nothing is the vacuous
  // pass this whole check exists to refuse, so it is exit 2 ("cannot verify"), matching
  // check-port-drift.sh's own 0/1/2 split.
  if (surfaces.length === 0) {
    console.error("❌ check-version-stamp: no surfaces found — nothing was verified (an empty set is not a pass)");
    return 2;
  }

  // ── --write: stamp, then stop. Mirrors `check-workflow-lock.mjs --update-lock`. ──
  if (opts.write) {
    for (const dir of surfaces) {
      try {
        const stamp = writeStamp(dir, repo);
        console.log(
          `✅ stamped ${dir} — commit ${(stamp.agentInfra.commit ?? "none").slice(0, 9)}, ` +
            `${stamp.payload.files} files, ${stamp.payload.hash.slice(0, 12)}…`
        );
      } catch (err) {
        console.error(`❌ could not stamp ${dir}: ${err.message}`);
        return 2;
      }
    }
    return 0;
  }

  // ── verify ──
  const ref = opts.ref ?? (git(repo, ["rev-parse", "--verify", "-q", `${REF_DEFAULT}^{commit}`]) !== null ? REF_DEFAULT : "main");
  let warning = null;
  if (opts.fetch) {
    const r = refreshRef(repo, ref);
    warning = r.warning;
  }
  const target = resolveRef(repo, ref);
  if (target.error !== undefined) {
    console.error(`❌ check-version-stamp: ${target.error}`);
    return 2;
  }

  const results = surfaces.map((dir) => classifySurface(dir, repo, target));
  const counts = { "in-sync": 0, drift: 0, unstamped: 0 };
  for (const r of results) counts[r.verdict] += 1;

  if (opts.json) {
    console.log(JSON.stringify({ ref: target.ref, sha: target.sha, warning, counts, results }, null, 2));
  } else {
    if (!opts.quiet && warning !== null) console.error(`⚠️  ${warning}`);
    for (const r of results) {
      const icon = r.verdict === "in-sync" ? "✅" : r.verdict === "drift" ? "❌" : "⚠️ ";
      const who = r.stamp?.agentInfra?.commit ? `commit ${r.stamp.agentInfra.commit.slice(0, 9)}` : "no commit";
      console.log(`${icon} ${r.verdict.padEnd(9)} ${r.surface}  (${who})`);
      if (r.verdict !== "in-sync") console.log(`     ${r.reason}`);
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
if (IS_MAIN) process.exit(main(process.argv.slice(2)));
