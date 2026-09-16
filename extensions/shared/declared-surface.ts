/**
 * declared-surface.ts — reusable zero-dep "declared surface" drift instrument (#1068).
 *
 * WHY THIS EXISTS (the failure mode it closes)
 * -------------------------------------------
 * A safety-relevant bound that is *declared* in more than one place, or declared
 * once and consumed by a second component that re-states the same knowledge, can
 * drift silently: nothing throws, nothing logs, and no test asserts the copies
 * agree. The repo already ships that instrument twice for single vocabularies
 * (`extensions/loop-enforcer/tier-config-parity.test.ts` for the
 * `stall_threshold` value across skill surfaces; `extensions/shared/
 * default-coverage.test.ts` for the shipped failover default). This module is
 * the instrument itself, extracted so a second vocabulary does not become a
 * third copy of the *checker*.
 *
 * TWO DIRECTIONS, ONE INVARIANT
 * -----------------------------
 *   forward  — every declared term must still be declared, with the declared
 *              value, in EACH of its owner files. Catches "the owner changed and
 *              the registry did not".
 *   reverse  — every in-family declaration found by the source scan must be
 *              registered, or exempted WITH a rationale. Catches "a new term was
 *              introduced and forgot the registry".
 *
 * FAIL-CLOSED
 * -----------
 * An empty or truncated scan is a VIOLATION, never a pass (`vacuityFindings`).
 * A silently-empty parse that reports "0 unregistered declarations" is the
 * no-op-gate failure this module exists to make impossible. The same floor
 * applies to the scan reading fewer files than the corpus declares.
 *
 * COMMENT HANDLING IS LANGUAGE-AWARE ON PURPOSE
 * ---------------------------------------------
 * Block comments are stripped for `ts`/`js` sources only. Shell sources are
 * NEVER block-comment stripped: shell globs and `case` patterns contain the
 * literal block-comment delimiters (a `case` branch whose pattern is a trailing
 * slash), so a naive block-comment pass deletes a whole region of a `.sh` file
 * and the scan silently loses every declaration in it. The failure is caught by
 * the non-vacuity floors, but the correct behaviour is not to create it.
 *
 * ZERO-DEPENDENCY IMPORT CONTRACT: `node:*` only. The per-PR `ci.yml` `verify`
 * job runs the shared suites with NO `npm ci`, so this file must not import
 * anything outside Node's stdlib.
 */

import * as fs from "node:fs";
import * as path from "node:path";

/** Source language — selects the comment grammar. */
export type SourceLang = "ts" | "sh";

/** One `const`/shell assignment found by the scan. */
export interface Declaration {
  /** Repo-relative path. */
  file: string;
  /** The declared identifier. */
  symbol: string;
  /** The trimmed declaration line, for violation messages. */
  raw: string;
}

/** What to scan and which identifiers count as in-family. */
export interface ScanSpec {
  /** Repo-relative files to scan (an explicit corpus, never a root walk). */
  files: readonly string[];
  /** Case-sensitive substrings in the identifier that make it in-family. */
  families: readonly string[];
  /**
   * Identifier suffixes that make an identifier in-family when it also carries
   * a family token — the BOUND SHAPE. Without this, a namespace prefix is
   * enough to drag a whole subsystem into the scan: the worktree reaper names
   * every subprocess limit `REAP_WT_*_TIMEOUT`, and a family token of `REAP`
   * would then demand a registry entry (or an exemption) for each one.
   */
  boundSuffixes: readonly string[];
  /**
   * Identifier suffixes that make an identifier in-family ON THEIR OWN. Covers
   * the age-shaped liveness bounds (`MAX_AGE`, `MAX_AGE_DAYS`, `STALE_AGE_MS`)
   * whose names carry no stall/silence/reap token at all.
   */
  ageSuffixes: readonly string[];
}

/**
 * A registered stall/liveness term. `owners` is a LIST because a term may be
 * legitimately declared in more than one file (e.g. the heartbeat interval
 * bounds exist in both the child and the parent) — a single-owner schema would
 * force a false record.
 */
export interface StallTerm {
  /** The identifier as declared in source. */
  name: string;
  /** Repo-relative owner files. Every one must declare the term. */
  owners: readonly string[];
  /**
   * A substring of the declaration line that must be present in EVERY owner
   * file (a distinctive fragment of the RHS, not the whole line, so formatting
   * is free but the bound is not). `null` means the term is a POINTER to
   * another guard (no local value is asserted here) or is derived from other
   * bounds.
   */
  value: string | null;
  /** Which axis the term answers to. */
  axis: string;
  /** Who actually pins this term's value today. */
  guardedBy: string;
  /** Optional human note. */
  note?: string;
}

/**
 * An independent implementation of "what counts as progress". Registered so the
 * declaration covers every driver, and so a driver that does NOT consume the
 * shared classification must say why.
 */
export interface ProgressDriver {
  id: string;
  /** Repo-relative file implementing the driver. */
  owner: string;
  /** The input shape it classifies. */
  mechanism: string;
  /** True when the driver consumes the shared edge classification. */
  sharesDeclaration: boolean;
  /** REQUIRED (≥20 non-space chars) when `sharesDeclaration` is false. */
  reason?: string;
}

/** An explicit, rationale-bearing carve-out from the reverse scan. */
export interface Exemption {
  /** Exact declared identifier to exempt. */
  symbol: string;
  /** Why it is not a stall/liveness bound. REQUIRED, and must be substantive. */
  rationale: string;
  /** Who owns the decision. */
  owner: string;
}

/** The minimum a non-vacuous scan must have observed. */
export interface VacuityFloors {
  minFiles: number;
  minDeclarations: number;
}

/** Result of a scan, plus the floors it must clear. */
export interface ScanResult {
  files: readonly string[];
  filesScanned: number;
  declarations: Declaration[];
}

/** A rationale is substantive when it has ≥20 non-space characters. */
export const MIN_RATIONALE_CHARS = 20;

/** Substantive-rationale predicate, shared by every rationale-bearing field. */
export function isSubstantive(reason: string | undefined): boolean {
  return typeof reason === "string" && reason.trim().replace(/\s+/g, " ").length >= MIN_RATIONALE_CHARS;
}

// ── extraction ──────────────────────────────────────────────────────────────

/** Pick the comment grammar from the file extension. */
export function langOf(file: string): SourceLang {
  return /\.(sh|bash)$/.test(file) ? "sh" : "ts";
}

/**
 * Remove comments so a DECLARATION is never fabricated out of prose (this
 * repo's source comments discuss stall bounds at length, and a scan that reads
 * comments is a scan that lies).
 *
 * Shell: `#` line comments only — NO block-comment pass (see the header).
 * TS/JS: block + `//` line comments. String/regex literals are not parsed; a
 * `//` inside a literal can only ever HIDE a declaration, which the non-vacuity
 * floor catches, never fabricate one.
 */
export function stripComments(src: string, lang: SourceLang = "ts"): string {
  if (lang === "sh") return src.replace(/(^|[ \t])#[^\n]*/g, "$1");
  return src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");
}

/** TS/JS `const|let|var NAME =` (also `export const`). */
const TS_DECL_RE = /(?:^|\n)[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*=/g;
/** Shell `NAME=`, `readonly NAME=`, `export NAME=`, `declare NAME=` at line start. */
const SH_DECL_RE = /(?:^|\n)[ \t]*(?:export[ \t]+|readonly[ \t]+|declare[ \t]+)?([A-Z_][A-Z0-9_]*)=/g;

/**
 * True when `symbol` belongs to a declared liveness/stall name family AND has
 * the shape of a bound — or is an age-shaped bound on its own.
 *
 * The two-part rule is deliberate: `REAP_WT_STATUS_TIMEOUT` carries the `REAP`
 * family token but is a worktree-reaper subprocess timeout, while
 * `MAX_AGE_DAYS` is a genuine staleness bound with no family token at all. A
 * single family-token rule cannot separate them; the shared predicate is
 * `token + bound shape` OR `age shape`.
 */
export function inFamily(
  symbol: string,
  families: readonly string[],
  ageSuffixes: readonly string[],
  boundSuffixes: readonly string[] = [],
): boolean {
  if (ageSuffixes.some((s) => symbol.endsWith(s))) return true;
  if (!families.some((f) => symbol.includes(f))) return false;
  return boundSuffixes.some((s) => symbol.endsWith(s));
}

/**
 * Every declaration line for `symbol` in `src` (comment-stripped), in source
 * order. Plural because a shell script legitimately declares the same symbol
 * twice (a default near the top, a CLI override later) — the forward check
 * needs to see all of them, not whichever the regex happens to hit first.
 */
export function declarationLines(src: string, symbol: string, lang: SourceLang = "ts"): string[] {
  const stripped = stripComments(src, lang);
  const re = new RegExp(
    `(?:^|\\n)[ \\t]*(?:export[ \\t]+|readonly[ \\t]+|declare[ \\t]+)?(?:const|let|var)?[ \\t]*${symbol}[ \\t]*=`,
    "g",
  );
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(stripped)) !== null) {
    const start = m.index + (m[0].startsWith("\n") ? 1 : 0);
    const nl = stripped.indexOf("\n", start);
    out.push((nl === -1 ? stripped.slice(start) : stripped.slice(start, nl)).trim());
    if (m.index === re.lastIndex) re.lastIndex++;
  }
  return out;
}

/** The first declaration line for `symbol`, or null. */
export function declarationLine(src: string, symbol: string, lang: SourceLang = "ts"): string | null {
  return declarationLines(src, symbol, lang)[0] ?? null;
}

/** Scan `spec.files` for in-family declarations. */
export function scanDeclarations(
  spec: ScanSpec,
  readFile: (file: string) => string,
): ScanResult {
  const declarations: Declaration[] = [];
  let filesScanned = 0;
  for (const file of spec.files) {
    let src: string;
    try {
      src = readFile(file);
    } catch {
      // A corpus file that vanished is a violation, not a silent skip.
      declarations.push({ file, symbol: "", raw: `UNREADABLE CORPUS FILE: ${file}` });
      continue;
    }
    filesScanned++;
    const lang = langOf(file);
    const stripped = stripComments(src, lang);
    const regexes = lang === "sh" ? [SH_DECL_RE] : [TS_DECL_RE, SH_DECL_RE];
    const seen = new Set<string>();
    for (const re of regexes) {
      re.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = re.exec(stripped)) !== null) {
        const symbol = m[1];
        if (!inFamily(symbol, spec.families, spec.ageSuffixes, spec.boundSuffixes)) continue;
        if (seen.has(symbol)) continue;
        seen.add(symbol);
        declarations.push({ file, symbol, raw: declarationLine(src, symbol, lang) ?? symbol });
      }
    }
  }
  return { files: spec.files, filesScanned, declarations };
}

// ── assertions ──────────────────────────────────────────────────────────────

/** forward: every term must be declared, with its declared value, in EVERY owner. */
export function forwardViolations(
  terms: readonly StallTerm[],
  readFile: (file: string) => string,
): string[] {
  const out: string[] = [];
  for (const term of terms) {
    if (!term.name) {
      out.push(`registry entry with an empty name (guardedBy: ${term.guardedBy})`);
      continue;
    }
    if (term.owners.length === 0) {
      out.push(`${term.name}: no owner file declared`);
      continue;
    }
    for (const owner of term.owners) {
      let src: string;
      try {
        src = readFile(owner);
      } catch {
        out.push(`${term.name}: owner file ${owner} does not exist`);
        continue;
      }
      const lines = declarationLines(src, term.name, langOf(owner));
      if (lines.length === 0) {
        // `value: null` terms may be FUNCTION-shaped (`getSubagentBackstopFreshMs`)
        // or derived expressions, not a `const NAME = …` — a plain presence check
        // is the honest assertion for them.
        if (term.value === null && new RegExp(`\\b${term.name}\\b`).test(src)) continue;
        out.push(`${term.name}: ${owner} no longer declares it (de-listed or renamed) — the registry says it does`);
        continue;
      }
      if (term.value !== null && !lines.some((l) => l.includes(term.value as string))) {
        out.push(
          `${term.name}: ${owner} declares ${JSON.stringify(lines[0])}, which does not carry the registered value ${JSON.stringify(term.value)} — the value changed without updating the registry (or vice versa)`,
        );
      }
    }
  }
  return out;
}

/** reverse: every scanned in-family declaration must be registered or exempted. */
export function reverseViolations(
  scan: ScanResult,
  terms: readonly StallTerm[],
  exemptions: readonly Exemption[],
): string[] {
  const registered = new Set(terms.map((t) => t.name));
  const exempt = new Map(exemptions.map((e) => [e.symbol, e]));
  const out: string[] = [];
  for (const d of scan.declarations) {
    if (d.symbol === "") {
      out.push(d.raw);
      continue;
    }
    if (registered.has(d.symbol)) continue;
    const ex = exempt.get(d.symbol);
    if (!ex) {
      out.push(
        `${d.file}: ${d.symbol} — ${JSON.stringify(d.raw)} is a stall/liveness-family declaration that is not in the registry and is not exempt. Register it (name + owners + value + axis + guardedBy) or add an exemption carrying a rationale.`,
      );
      continue;
    }
    if (!isSubstantive(ex.rationale)) {
      out.push(`${d.file}: ${d.symbol} — exemption rationale is empty or too short to be a reason (owner: ${ex.owner})`);
    }
  }
  for (const ex of exemptions) {
    if (ex.symbol === "") out.push(`exemption with an empty symbol (owner: ${ex.owner})`);
  }
  return out;
}

/**
 * A scan that observed less than the floors is a VIOLATION, never a pass — the
 * no-op-gate failure mode (a renamed corpus silently reports "everything is
 * registered" because it found nothing to register).
 */
export function vacuityFindings(scan: ScanResult, floors: VacuityFloors): string[] {
  const out: string[] = [];
  if (scan.filesScanned < floors.minFiles) {
    out.push(
      `VACUOUS SCAN: ${scan.filesScanned} of ${scan.files.length} corpus files were readable (floor ${floors.minFiles}) — the corpus moved, was renamed, or was emptied`,
    );
  }
  if (scan.declarations.length < floors.minDeclarations) {
    out.push(
      `VACUOUS SCAN: ${scan.declarations.length} in-family declarations found (floor ${floors.minDeclarations}) — the scanner or its name families stopped matching, so "no unregistered declarations" proves nothing`,
    );
  }
  return out;
}

/** Every registered driver must exist, and a non-sharing driver must say why. */
export function driverViolations(
  drivers: readonly ProgressDriver[],
  readFile: (file: string) => string,
): string[] {
  const out: string[] = [];
  for (const d of drivers) {
    try {
      readFile(d.owner);
    } catch {
      out.push(`${d.id}: driver file ${d.owner} does not exist — the registered driver set is stale`);
    }
    if (!d.sharesDeclaration && !isSubstantive(d.reason)) {
      out.push(`${d.id} (${d.owner}): sharesDeclaration=false requires a substantive reason (≥${MIN_RATIONALE_CHARS} non-space chars) — a driver that does not share the declaration must say why it is safe to leave separate`);
    }
  }
  return out;
}

/** Collect every file under `dirRel` whose basename passes `keep`, bounded + explicit. */
export function collectFiles(
  root: string,
  dirRel: string,
  keep: (name: string) => boolean,
  depth = 6,
): string[] {
  const out: string[] = [];
  const walk = (rel: string, d: number) => {
    if (d > depth) return;
    const abs = path.join(root, rel);
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const childRel = `${rel}/${e.name}`;
      // Explicit, bounded exclusions — never walk vendored or deprecated trees.
      if (e.isDirectory()) {
        if (e.name === "node_modules" || e.name === "_deprecated" || e.name.startsWith(".")) continue;
        walk(childRel, d + 1);
      } else if (e.isFile() && keep(e.name)) {
        out.push(childRel);
      }
    }
  };
  walk(dirRel, 0);
  return out.sort();
}
