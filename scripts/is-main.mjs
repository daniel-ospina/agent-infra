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
 *   | IMPORTED     | no `argv[1]` at all (REPL / `node -e` / plain import), or the | false    |
 *   |              | two sides realpath DEFINITIVELY to different files            |          |
 *   | UNRESOLVED   | own module path unresolvable, or `argv[1]` unresolvable and   | TRUE +   |
 *   |              | unprovable                                                     | warning  |
 *
 * `UNRESOLVED → true` is the fail-closed direction: at every call site the
 * guard body IS the gate, so running it is the safe answer. A wrong `true` is
 * visible (the gate's own output plus the `[is-main]` warning); a wrong
 * `false` is silent — which is the bug.
 *
 * `IMPORTED` is deliberately narrow: it requires a definitive answer. That is
 * what makes this module safe to import from a suite (the tests do) without
 * accidentally running somebody's CLI.
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
 * @param {string} [metaUrl]  the CALLER's `import.meta.url` — not this module's.
 * @param {string|undefined} [argv1] `process.argv[1]`.
 * @returns {{verdict: 'entry'|'imported'|'unresolved', reason: string, self: string|null, argv1: string|null}}
 */
export function classifyEntry(metaUrl = import.meta.url, argv1 = process.argv[1]) {
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

  // Cannot prove we are NOT the entry point. Never answer "not main" here.
  return { verdict: UNRESOLVED, reason: 'unresolvable', self, argv1: entry };
}

/** Warn once per distinct (reason, self, argv1) — a loop must not spam. */
const warned = new Set();

function warnFailClosed(info) {
  const key = `${info.reason}\u0000${info.self}\u0000${info.argv1}`;
  if (warned.has(key)) return;
  warned.add(key);
  const detail =
    info.reason === 'self-unresolvable'
      ? `this module's own path could not be resolved (module root unknown)`
      : `the invocation path could not be resolved`;
  process.stderr.write(
    `${WARN_PREFIX} ⚠️  FAIL-CLOSED — ${detail}; treating this module as the ` +
      `entry point so a fail-closed gate RUNS instead of silently no-opping (#708).\n` +
      `${WARN_PREFIX}    argv[1]=${info.argv1 ?? '<none>'}  self=${info.self ?? '<unresolvable>'}\n`,
  );
}

/**
 * Symlink-insensitive entry-point guard.
 *
 * @param {string} [metaUrl] the CALLER's `import.meta.url`.
 * @param {string|undefined} [argv1] `process.argv[1]`.
 * @param {{warn?: boolean}} [opts] `warn: false` suppresses the stderr warning
 *   (tests only — it does NOT change the verdict).
 */
export function isMain(metaUrl = import.meta.url, argv1 = process.argv[1], opts = {}) {
  const info = classifyEntry(metaUrl, argv1);
  if (info.verdict === ENTRY) return true;
  if (info.verdict === IMPORTED) return false;
  if (opts.warn !== false) warnFailClosed(info);
  return true; // UNRESOLVED — fail closed, never a silent `false`.
}
