#!/usr/bin/env node
/**
 * scripts/is-main.mjs — "am I the process entry point?", symlink-insensitive (#708).
 *
 * WHY THIS MODULE EXISTS
 * ----------------------
 * The idiom this replaces —
 *
 *     const isMain =
 *       process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
 *
 * — is symlink-SENSITIVE by construction. `pathToFileURL` is a pure string→URL
 * mapping: it does NO filesystem resolution. Node's ESM loader DOES realpath
 * `import.meta.url`. So whenever ANY component of the invocation path is a
 * symlink, the two sides differ and the `if (isMain)` body never runs — the
 * fail-CLOSED gate prints nothing and exits 0, which is byte-identical to a
 * clean run. Measured (#708): `node $T/real/scripts/check-skill-lint.mjs`
 * → 0 bytes stdout, exit 0; the same script at its realpath → 4 P0 issues,
 * exit 1.
 *
 * This is not hypothetical: macOS default temp dirs (`/var/folders/…` →
 * `/private/var/…`) and every bootstrapped consumer repo (whose `scripts/` is a
 * SYMLINK into agent-infra — see the `node-ci.yml` skip-input rationale, #387)
 * traverse symlinked ancestors routinely.
 *
 * FAIL-CLOSED CONTRACT (the point of the whole module)
 * ----------------------------------------------------
 * A guard that cannot prove it loaded must not silently allow (#744 / #709).
 * `isMain()` returns `true` — and warns LOUDLY on stderr — whenever it cannot
 * prove otherwise:
 *
 *   | verdict      | when                                                          | isMain() |
 *   |--------------|---------------------------------------------------------------|----------|
 *   | ENTRY        | literal match; realpath match (symlinked ancestor OR leaf);    | true     |
 *   |              | dirname-realpath + same basename                              |          |
 *   | IMPORTED     | no `argv[1]` at all (REPL / `node -e` / plain import);     | false    |
 *   |              | the two sides realpath to different files; or `self`          |          |
 *   |              | resolves while `argv[1]` does not (then `argv[1]` cannot name  |          |
 *   |              | this file — a file that resolves cannot live at a path that    |          |
 *   |              | does not)                                                     |          |
 *   | UNRESOLVED   | our OWN module path is unresolvable (or both sides are), so    | TRUE +   |
 *   |              | nothing about the invocation can be proven                     | warning  |
 *
 * `IMPORTED` is the quiet answer only when it is PROVEN — a false `IMPORTED`
 * would be the very silent no-op this module exists to prevent, so every branch
 * above is a proof, not a guess. `UNRESOLVED` is what is left when no proof
 * exists, and it is loud AND runs the guard body.
 *
 * WHY "argv[1] FAILED TO RESOLVE" IS NOT, BY ITSELF, AMBIGUITY:
 * a real direct invocation always has a resolvable `argv[1]` (Node just loaded
 * the file), so an unresolvable one means the module was IMPORTED — and in an
 * importing process the guard body is not a gate, it is a side effect
 * (`process.exit`, a `--write`, a latch `--clear`). Review cycle 1 measured
 * exactly that: `UNRESOLVED` for an importer killed the importer
 * (load-gate / check-skill-lint), regenerated fixtures (probe with `--write`),
 * and WIPED the exhaustion latch (provider-failover with `--clear`). Hence the
 * `dirname-realpath` proof and the `argv1-unresolvable-different` proof below;
 * only a genuinely unprovable residue still runs — loudly.
 *
 * `metaUrl` IS REQUIRED AND HAS NO DEFAULT, deliberately: a default of this
 * module's own `import.meta.url` would make the natural one-argument call
 * `isMain()` compare `argv[1]` against *this* file, return `IMPORTED`, and
 * silently disable the caller's gate — the #708 class reintroduced by an
 * omitted argument. An omitted `metaUrl` is instead an unresolvable self →
 * `UNRESOLVED` → loud, fail-closed.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** Definitely the process entry point. */
export const ENTRY = 'entry';
/** Definitely NOT the entry point (no argv[1], or provably a different file). */
export const IMPORTED = 'imported';
/** We cannot prove either way — callers must fail CLOSED (loud, not silent). */
export const UNRESOLVED = 'unresolved';

/** stderr prefix for the ambiguity warning — greppable, so a CI log shows it. */
export const WARN_PREFIX = '[is-main]';

/** `fs.realpathSync` or `null` — never throws. */
export function realpathOrNull(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return null;
  }
}

/** `fileURLToPath(metaUrl)` or `null` for a non-`file:` / malformed URL. */
export function selfPathFromUrl(metaUrl) {
  try {
    const p = fileURLToPath(metaUrl);
    return typeof p === 'string' && p.length > 0 ? p : null;
  } catch {
    return null;
  }
}

/**
 * Classify the relationship between `metaUrl` (the caller's own module URL) and
 * `argv1` (the path the process was invoked as).
 *
 * @param {string} metaUrl REQUIRED — the CALLER's `import.meta.url`. There is
 *   deliberately no default (see the module header).
 * @param {string|undefined} [argv1] `process.argv[1]`.
 * @returns {{verdict: 'entry'|'imported'|'unresolved', reason: string, self: string|null, argv1: string|null}}
 */
export function classifyEntry(metaUrl, argv1 = process.argv[1]) {
  const self = selfPathFromUrl(metaUrl);

  // No script path at all: REPL, `node -e`, `--input-type=module`, or a plain
  // `import`. Definitively NOT this module being run as the entry point — this
  // is the one case where a quiet `false` is correct, and it is the case a test
  // suite hits when it imports a CLI module.
  if (argv1 === undefined || argv1 === null || argv1 === '') {
    return { verdict: IMPORTED, reason: 'no-argv1', self, argv1: null };
  }

  const entry = path.resolve(String(argv1));

  // We cannot even resolve OUR OWN path. The guard cannot decide — #708 open
  // decision 4: fail loudly rather than no-op.
  if (self === null) {
    return { verdict: UNRESOLVED, reason: 'self-unresolvable', self: null, argv1: entry };
  }

  // Fast path — identical literal strings, the overwhelmingly common case.
  if (entry === self) {
    return { verdict: ENTRY, reason: 'literal', self, argv1: entry };
  }

  // Definitive: realpath on BOTH sides. Catches a symlinked ancestor AND a
  // symlinked leaf file, and gives the only trustworthy `IMPORTED`.
  const selfReal = realpathOrNull(self);
  const entryReal = realpathOrNull(entry);
  if (selfReal !== null && entryReal !== null) {
    return selfReal === entryReal
      ? { verdict: ENTRY, reason: 'realpath', self, argv1: entry }
      : { verdict: IMPORTED, reason: 'realpath-differ', self, argv1: entry };
  }

  // One side is unresolvable (deleted mid-run, EACCES, ELOOP). #675 P2-f: a
  // symlinked ANCESTOR still resolves via dirname, so compare
  // realpath(dirname) + basename before giving up.
  if (path.basename(self) === path.basename(entry)) {
    const selfDir = realpathOrNull(path.dirname(self));
    const entryDir = realpathOrNull(path.dirname(entry));
    if (selfDir !== null && entryDir !== null) {
      return selfDir === entryDir
        ? { verdict: ENTRY, reason: 'dirname-realpath', self, argv1: entry }
        : { verdict: IMPORTED, reason: 'dirname-differ', self, argv1: entry };
    }
  }

  // PROVABLE "not us" (#708 review cycle 1): `self` RESOLVED (so this file
  // exists on disk) while `argv[1]` did not — and a path that does not resolve
  // cannot name a file that does. This is the shape a bun-compiled pi presents
  // (`/$bunfs/root/pi.ts`, explicitly handled at
  // extensions/builtin-tools/index.ts:161 and extensions/subagent/index.ts:439)
  // while the module is IMPORTED — where a `true` would run the guard body
  // inside the host process (`process.exit`, `--write`, latch `--clear`). Quiet,
  // because it is proven: a warning here would fire in every bun-pi session.
  if (selfReal !== null && entryReal === null) {
    return { verdict: IMPORTED, reason: 'argv1-unresolvable-different', self, argv1: entry };
  }

  // Irreducible ambiguity: our OWN module path is unresolvable, so nothing is
  // provable — never answer "not main" here. (A real direct invocation reaches
  // this only via the #675 P2-f self-delete, where the dirname+basename proof
  // above normally already answers ENTRY.)
  return { verdict: UNRESOLVED, reason: 'unresolvable-ambiguous', self, argv1: entry };
}

/** Warn once per distinct (reason, self, argv1) — a loop must not spam. */
const warned = new Set();

function warnFailClosed(info) {
  const key = `${info.reason}\u0000${info.self}\u0000${info.argv1}`;
  if (warned.has(key)) return;
  warned.add(key);
  const detail =
    info.reason === 'self-unresolvable'
      ? `this module's own path could not be resolved (module root unknown — did the caller omit metaUrl?)`
      : `the invocation path could not be resolved unambiguously`;
  process.stderr.write(
    `${WARN_PREFIX} ⚠️  FAIL-CLOSED — ${detail}; treating this module as the ` +
      `entry point so a fail-closed gate RUNS instead of silently no-opping (#708).\n` +
      `${WARN_PREFIX}    argv[1]=${info.argv1 ?? '<none>'}  self=${info.self ?? '<unresolvable>'}\n`,
  );
}

/**
 * Symlink-insensitive entry-point guard.
 *
 * @param {string} metaUrl REQUIRED — the CALLER's `import.meta.url`. There is
 *   deliberately no default: a default would be THIS module's URL, which would
 *   make `isMain()` silently return `IMPORTED` (see the module header).
 * @param {string|undefined} [argv1] `process.argv[1]`.
 * @param {{warn?: boolean}} [opts] `warn: false` suppresses the stderr warning
 *   (tests only — it does NOT change the verdict).
 */
export function isMain(metaUrl, argv1 = process.argv[1], opts = {}) {
  const info = classifyEntry(metaUrl, argv1);
  if (info.verdict === ENTRY) return true;
  if (info.verdict === IMPORTED) return false;
  if (opts.warn !== false) warnFailClosed(info);
  return true; // UNRESOLVED — fail closed, never a silent `false`.
}
