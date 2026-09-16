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
 * applies to the scan reading fewer files than the corpus declares, and a
 * corpus WALK failure (an unreadable directory, which would silently drop a
 * subtree) is reported through the same channel as an unreadable file — never
 * swallowed.
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
  /**
   * Failures the corpus WALK hit (unreadable directory). Carried through so the
   * scan can report them: a dropped subtree is a violation, never a silent skip.
   */
  walkErrors?: readonly string[];
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
  /** Which axis the term answers to. Asserted against the owning module's declared axis set. */
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
 * TS/JS: `//` line comments and block comments, removed by ONE left-to-right
 * pass. That single pass is a CORRECTNESS property, not a style choice: two
 * ordered regex passes let a `/*` inside a `//` comment open a block that
 * swallowed real declarations (`extensions/repo-freshness.ts:5` carries the
 * glob `"./shared/*"` in a line comment, and stripping block comments first
 * deleted its two FRESH bounds) — a false PASS in the one direction this module
 * exists to close.
 *
 * The pass also tracks string literals AND regex literals. Regex awareness is
 * not optional: `extensions/builtin-tools/index.ts` holds
 * `/^Warning: No project session found with id '[^']*'/`, whose apostrophe would
 * otherwise open a bogus single-quote "string" that copied thousands of lines of
 * comments through verbatim — so every parent-side assertion would be scanning
 * prose. Both directions of that failure (a comment SURVIVING stripping, and a
 * `/[/*]/` char class being read as a block-comment opener and DELETING real
 * declarations) are pinned by fixtures below.
 */
export function stripComments(src: string, lang: SourceLang = "ts"): string {
  if (lang === "sh") return src.replace(/(^|[ \t])#[^\n]*/g, "$1");
  let out = "";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === "/" && src[i + 1] === "/") {
      const nl = src.indexOf("\n", i);
      i = nl === -1 ? src.length : nl;
      continue;
    }
    if (c === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      const stop = end === -1 ? src.length : end + 2;
      // Preserve the removed span's newlines so a declaration that FOLLOWS a
      // multi-line comment is still at the start of a line (the declaration
      // regexes are line-anchored).
      const span = src.slice(i, stop);
      out += "\n".repeat((span.match(/\n/g) ?? []).length);
      i = stop;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      // Copy the literal verbatim (honouring escapes) so a comment delimiter
      // inside it is never mistaken for a comment.
      let j = i + 1;
      while (j < src.length) {
        if (src[j] === "\\") j += 2;
        else if (src[j] === c) {
          j++;
          break;
        } else j++;
      }
      out += src.slice(i, j);
      i = j;
      continue;
    }
    if (c === "/" && couldStartRegex(src, i)) {
      // Copy the regex literal verbatim, but SKIP its contents: a quote inside
      // it must not open a bogus "string", and a `/*` inside a character class
      // must not open a bogus block comment.
      const j = endOfRegex(src, i);
      out += src.slice(i, j);
      i = j;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** Keywords after which a `/` starts a regex literal (`return /re/`). */
const REGEX_PRECEDING_KEYWORD =
  /(?:^|[^A-Za-z0-9_$.])(return|typeof|instanceof|in|of|new|delete|void|do|else|yield|await|case)$/;

/**
 * True when the `/` at `i` begins a regex literal. The heuristic is the standard
 * one: a regex cannot follow a VALUE, and `//` / `/*` are always comments (so
 * those cases are resolved before this runs).
 *
 * The previous-character-only version misread `a++ / b`, `x! / b` (postfix
 * non-null) and `obj.of / b` (property access) as regex starts; with a
 * `/`-containing string on the same line that desynchronized the scan and let a
 * comment fabricate a declaration. So the test is now on the previous TOKEN.
 */
function couldStartRegex(src: string, i: number): boolean {
  if (src[i + 1] === "/" || src[i + 1] === "*") return false;
  if (src[i + 1] === undefined) return false;
  if (!prevTokenIsValue(src, i)) return true;
  // A VALUE before the `/` means division — unless the value-token is a KEYWORD
  // (`return /re/`) or the keyword is a property NAME (`obj.of`), which the
  // lookbehind rejects by excluding a preceding `.`.
  return REGEX_PRECEDING_KEYWORD.test(src.slice(0, i).replace(/\s+$/, ""));
}

/** Chars that can END a value: literals and closing brackets. */
const VALUE_ENDERS = ")]}`\"'";

/** True when the token before index `i` is a VALUE (so a `/` divides). */
function prevTokenIsValue(src: string, i: number): boolean {
  let k = i - 1;
  while (k >= 0 && /\s/.test(src[k])) k--;
  if (k < 0) return false; // start of file — not a value
  const c = src[k];
  if (VALUE_ENDERS.includes(c)) return true;
  if (c === "+" || c === "-") {
    // Postfix `++` / `--` (a value) vs a binary operator (not one).
    let m = k - 1;
    while (m >= 0 && /\s/.test(src[m])) m--;
    return m >= 0 && src[m] === c;
  }
  if (c === "!") {
    // Postfix non-null assertion (`a! / 2`) vs prefix negation (`!/re/.test(x)`).
    let m = k - 1;
    while (m >= 0 && /\s/.test(src[m])) m--;
    return m >= 0 && /[A-Za-z0-9_$)\]}]/.test(src[m]);
  }
  return /[A-Za-z0-9_$]/.test(c);
}

/** Index just past the regex literal starting at `i` (flags included). */
function endOfRegex(src: string, i: number): number {
  let j = i + 1;
  let inClass = false;
  while (j < src.length) {
    const d = src[j];
    if (d === "\\") {
      j += 2;
      continue;
    }
    if (d === "\n") break; // an unterminated regex does not span lines
    if (d === "[") inClass = true;
    else if (d === "]") inClass = false;
    else if (d === "/" && !inClass) {
      j++;
      while (j < src.length && /[a-z]/.test(src[j])) j++;
      return j;
    }
    j++;
  }
  return j;
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

/**
 * True when `symbol` appears as a DECLARATION in `src` — on the comment-stripped
 * source, in a declaration SHAPE (`const`/`let`/`var`, `function`, or a shell
 * assignment).
 *
 * This is the assertion for `value: null` terms (pointers and derived
 * expressions, which have no literal to compare). A bare word-boundary test over
 * the RAW source is satisfied by a comment that merely NAMES the term, so
 * deleting such a declaration while leaving a comment mentioning it kept BOTH
 * scan directions green (#1068 review).
 */
export function declaresSymbol(src: string, symbol: string, lang: SourceLang = "ts"): boolean {
  const stripped = stripComments(src, lang);
  if (declarationLines(stripped, symbol, lang).length > 0) return true;
  const esc = symbol.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const shapes = [
    new RegExp(`(?:^|\\n)[ \\t]*(?:export[ \\t]+)?(?:async[ \\t]+)?function[ \\t*]+${esc}\\b`),
    new RegExp(`(?:^|\\n)[ \\t]*(?:const|let|var)[ \\t]+${esc}\\b`),
  ];
  if (lang === "sh") {
    shapes.push(new RegExp(`(?:^|\\n)[ \\t]*(?:export[ \\t]+|readonly[ \\t]+|declare[ \\t]+|function[ \\t]+)?${esc}\\b`));
  }
  return shapes.some((re) => re.test(stripped));
}

/** Scan `spec.files` for in-family declarations. */
export function scanDeclarations(
  spec: ScanSpec,
  readFile: (file: string) => string,
): ScanResult {
  const declarations: Declaration[] = [];
  let filesScanned = 0;
  // A walk failure is reported through the same channel as an unreadable file.
  for (const w of spec.walkErrors ?? []) {
    declarations.push({ file: "", symbol: "", raw: `CORPUS WALK ERROR: ${w}` });
  }
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
        // or derived expressions, not a `const NAME = …` — so the presence check
        // is declaration-SHAPED, on the comment-stripped source. A bare
        // word-boundary test over raw text is satisfied by a comment that names
        // the term, which made a deleted declaration invisible.
        if (term.value === null && declaresSymbol(src, term.name, langOf(owner))) continue;
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
  const registered = new Map(terms.map((t) => [t.name, t]));
  const exempt = new Map(exemptions.map((e) => [e.symbol, e]));
  const out: string[] = [];
  for (const d of scan.declarations) {
    if (d.symbol === "") {
      out.push(d.raw);
      continue;
    }
    const term = registered.get(d.symbol);
    if (term) {
      // A registered term re-declared in a file the registry does not list as an
      // owner is exactly the silent drift this registry exists to catch: a
      // second, conflicting copy of a bound. Keying on the NAME alone let it
      // pass both directions (#1068 review).
      if (!term.owners.includes(d.file)) {
        out.push(
          `${d.file}: ${d.symbol} — declares a REGISTERED term in a file the registry does not list as an owner (owners: ${term.owners.join(", ")}). Either add this file to the term's owners or delete the duplicate declaration.`,
        );
      }
      continue;
    }
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
  // Only REAL declarations count toward the floor. An unreadable file (or a
  // failed directory walk) contributes a sentinel with an empty symbol, and
  // counting those would let a largely-unreadable corpus clear the floor that
  // exists to prove the scan saw a real corpus (#1068 review).
  const found = scan.declarations.filter((d) => d.symbol !== "").length;
  if (found < floors.minDeclarations) {
    out.push(
      `VACUOUS SCAN: ${found} in-family declarations found (floor ${floors.minDeclarations}) — the scanner or its name families stopped matching, so "no unregistered declarations" proves nothing`,
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
  errors?: string[],
): string[] {
  const out: string[] = [];
  const walk = (rel: string, d: number) => {
    if (d > depth) {
      // A truncated subtree is a dropped subtree: report it.
      errors?.push(`${rel}: corpus walk hit the depth bound (${depth}) — this subtree was NOT scanned`);
      return;
    }
    const abs = path.join(root, rel);
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch (err) {
      // Report, never swallow: a dropped subtree can hide a new bound, and the
      // non-vacuity floor is too coarse to cover it (the real corpus is ~126
      // files against a floor of 100).
      errors?.push(`${rel}: unreadable directory during the corpus walk (${(err as Error).message})`);
      return;
    }
    for (const e of entries) {
      const childRel = `${rel}/${e.name}`;
      // Explicit, bounded exclusions — never walk vendored or deprecated trees.
      if (e.isDirectory()) {
        if (e.name === "node_modules" || e.name === "_deprecated" || e.name.startsWith(".")) continue;
        walk(childRel, d + 1);
      } else if (e.isSymbolicLink()) {
        // `isDirectory()` and `isFile()` are BOTH false for a symlink, so a
        // symlinked source file or subtree would vanish without a word. Report
        // it rather than silently shrinking the corpus.
        errors?.push(`${childRel}: symlinked entry during the corpus walk — not followed, so its contents are NOT in the scan`);
      } else if (e.isFile() && keep(e.name)) {
        out.push(childRel);
      }
    }
  };
  walk(dirRel, 0);
  return out.sort();
}
