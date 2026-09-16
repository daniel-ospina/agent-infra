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
 * NO LEXER — COMMENT HANDLING IS LINE-LOCAL AND STATELESS
 * ------------------------------------------------------
 * A declaration scan must never read prose as code (FABRICATION) and must never
 * lose real code to a parser mistake (DELETION). The first version of this
 * module tried to get both from a hand-rolled single-pass scanner that tracked
 * line comments, block comments, string literals, template literals AND regex
 * literals. It was still wrong in BOTH directions, because the scanner carried
 * state ACROSS lines and a desynchronized scanner is a lying oracle:
 *   - DELETION: `/[/*]/` was read as a block opener and removed real
 *     declarations after it.
 *   - FABRICATION: `/^Warning: … '[^']*'/`'s apostrophe opened a bogus string
 *     that copied comments through verbatim, so the assertions scanned prose.
 *   - and each fix for one direction opened a case in the other (`if (x) /re/`
 *     in statement position, a property named `of`, a double `!`, a nested
 *     template) — an unbounded arms race.
 *
 * So there is no lexer here. `yieldCommentLines` is LINE-LOCAL and STATELESS: it
 * can only blank a line that ITSELF begins with a comment marker, so nothing on
 * a previous line can desynchronize it and no fragment of a code line can be
 * deleted. Comment-LINE blanking is enough for the two jobs that need it, and it
 * is the only transform any assertion depends on. Shell sources blank `#` lines
 * only — never a block-comment pass: shell globs and `case` patterns contain the
 * literal block-comment delimiters, and dropping a region of a `.sh` file would
 * silently lose every declaration in it.
 *
 * The accepted residual — and it is DISCLOSED, not covered: a block comment whose
 * body lines are NOT `*`-prefixed (flush-left prose) is indistinguishable from
 * code without cross-line state, so a declaration-SHAPED flush-left line inside
 * such a comment WOULD be read as a declaration. Nothing here can detect that
 * shape, so `declared-surface.test.ts` pins it as a known gap rather than
 * claiming coverage, and the corpus is required not to contain one.
 *
 * The same disclosure covers the whole TEXT-SHAPED class: extraction is a
 * line-shaped regex, not a parser, so (a) a `const`-shaped line inside a
 * MULTI-LINE string/template is read as code, and (b) the scan is not
 * scope-aware — a same-named declaration in a nested function body satisfies the
 * presence and forward checks even when the module-level one was deleted. Both
 * are limits of the mechanism, recorded here rather than implied away.
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
  /**
   * The fragments of the term's NON-default declaration lines, in source order
   * (a CLI override, a `10#` coercion — shell scripts legitimately re-assign a
   * bound more than once). When present, `forwardViolations` requires the owner
   * file to declare the term EXACTLY `1 + overrides.length` times, with each
   * line carrying its recorded fragment.
   *
   * This closes a false PASS the `some()` value check allowed: a second,
   * shadowing declaration (or a changed default further down) left the registry
   * green because only ONE of the declaration lines had to carry the value.
   */
  overrides?: readonly string[];
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
 * True when `line` (as written in source) is a COMMENT line.
 *
 * `*` followed by an IDENTIFIER is deliberately NOT a comment line: a generator
 * method (`*gen() {`) is real code. A lone `*`, or `*` followed by whitespace,
 * is a block-comment body line — which is how every JSDoc body in this repo is
 * written.
 */
export function isCommentLine(line: string, lang: SourceLang = "ts"): boolean {
  const t = line.replace(/^[ \t]+/, "");
  if (t === "") return false;
  if (lang === "sh") return t.startsWith("#");
  if (t.startsWith("//")) return true;
  if (t.startsWith("/*")) return true;
  if (t.startsWith("*/")) return true;
  return t === "*" || /^\*[ \t]/.test(t);
}

/**
 * Blank every comment LINE so a DECLARATION is never fabricated out of prose
 * (this repo's source comments discuss stall bounds at length, and a scan that
 * reads comments is a scan that lies), while keeping the line count identical so
 * every declaration stays line-anchored.
 *
 * LINE-LOCAL AND STATELESS BY CONSTRUCTION — see the header. Each line is
 * classified on its own; there is no state to desynchronize. A comment that only
 * PREFIXES a code line (an inline block comment followed by code, or a closing
 * delimiter followed by code) keeps its code: only the comment span is dropped,
 * and the strip REPEATS so a line carrying two prefixes still yields its code.
 */
export function yieldCommentLines(src: string, lang: SourceLang = "ts"): string {
  return src
    .split("\n")
    .map((line) => {
      let cur = line;
      // Bound the repeat: each pass removes at least one prefix, and 8 nested
      // inline comments on one line is already far past anything real.
      for (let i = 0; i < 8; i++) {
        const next = yieldOneLine(cur, lang);
        if (next === cur) return cur;
        cur = next;
      }
      return cur;
    })
    .join("\n");
}

/**
 * One pass of the transform. The rewrite branch is gated by `isCommentLine`,
 * so the module has exactly ONE definition of "this line is a comment" — the
 * no-deletion invariant asserted in the suite is this line, not a restatement
 * of it.
 */
function yieldOneLine(line: string, lang: SourceLang): string {
  const t = line.replace(/^[ \t]+/, "");
  if (t === "" || !isCommentLine(line, lang)) return line;
  // A `//` (or shell `#`) comment runs to end of line; a block-comment body
  // line holds no code at all.
  if (lang === "sh" || t.startsWith("//")) return "";
  if (t === "*" || /^\*[ \t]/.test(t)) return "";
  // `*/` closes at index 0; `/*` cannot close before index 2.
  const close = t.indexOf("*/", t.startsWith("*/") ? 0 : 2);
  // No closing `*/` on this line: the comment continues below.
  if (close === -1) return "";
  const rest = t.slice(close + 2).replace(/^[ \t]+/, "");
  return rest === "" ? "" : line.slice(0, line.length - t.length) + rest;
}

/** TS/JS `const|let|var NAME[: Type] =` (also `export const`). */
const TS_DECL_RE =
  /(?:^|\n)[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*(?::[^\n]*?)?[ \t]*=/g;
/**
 * Shell `NAME=` AT LINE START — the variant used for TS/JS sources, where a
 * `NAME=` in the middle of a line is a mention (a template literal, a string, an
 * object property), never a declaration.
 */
const SH_DECL_LINE_START = /(?:^|\n)[ \t]*(?:export[ \t]+|readonly[ \t]+|declare[ \t]+)?([A-Z_][A-Z0-9_]*)=/g;
/**
 * Shell `NAME=` after any NON-IDENTIFIER character — the variant used for `.sh`
 * sources, where a script legitimately assigns a bound inside a `case` arm
 * (`--idle-days) IDLE_DAYS="$2"; shift 2 ;;`, which is how two of the reaper
 * scripts take their CLI override). A line-start anchor missed those sites, which
 * made the exact-declaration-count rule blind to them.
 */
const SH_DECL_ANYWHERE = /(?:^|[^A-Za-z0-9_])(?:export[ \t]+|readonly[ \t]+|declare[ \t]+)?([A-Z_][A-Z0-9_]*)=/g;

/**
 * Remove a TRAILING comment from a declared line: a line-local, stateless
 * operation (quote-aware via `insideQuote`), so `... = 600_000; // was 1_200_000`
 * cannot satisfy the forward check for the OLD value while the real one changed.
 * A whole-line comment never reaches here (those are blanked).
 */
export function stripTrailingComment(line: string, lang: SourceLang = "ts"): string {
  if (lang === "sh") {
    // `#` opens a comment only at the start of a word (not inside `${…}`, `$#`).
    for (let i = 1; i < line.length; i++) {
      if (line[i] === "#" && /[ \t]/.test(line[i - 1]) && !insideQuote(line, i)) return line.slice(0, i).trimEnd();
    }
    return line;
  }
  // A `//` comment runs to end of line; a closed `/* … */` span is removed
  // wherever it sits. Both must be OUTSIDE a string literal.
  const cut = (s: string): number => {
    for (let i = 0; i < s.length - 1; i++) {
      if (!insideQuote(s, i) && s[i] === "/" && s[i + 1] === "/") return i;
    }
    return -1;
  };
  let out = line;
  for (let pass = 0; pass < 8; pass++) {
    const lineCut = cut(out);
    const open = out.indexOf("/*");
    if (open !== -1 && !insideQuote(out, open) && (lineCut === -1 || open < lineCut)) {
      const close = out.indexOf("*/", open + 2);
      if (close === -1) return out.slice(0, open).trimEnd();
      out = out.slice(0, open) + out.slice(close + 2);
      continue;
    }
    if (lineCut !== -1) return out.slice(0, lineCut).trimEnd();
    return out;
  }
  return out;
}

/**
 * True when `line` carries `fragment` as a WHOLE token that is not further
 * scaled or continued.
 *
 * A raw `includes()` let a registered fragment be extended into a DIFFERENT
 * bound: `|| 1_800_000` matched `|| 1_800_000 * 2` and `(... || 1_800_000) * 2`,
 * `=14` matched `=140`, `14.5` and `14e2` — a false PASS in the one direction
 * this module exists to close. The right-hand side is therefore examined: a token
 * continuation (digit, `.`, `_`, identifier, an `e`/`n` suffix) is refused, and so
 * is an arithmetic operator applied to the expression the fragment ends (after
 * any legitimate closers). A fragment that needs to describe an expression
 * records the WHOLE expression, as `WALL_CLOCK_STALL_MS` does.
 */
export function carriesValue(line: string, fragment: string): boolean {
  const esc = fragment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const left = /^[0-9]/.test(fragment) ? "(?<![0-9_])" : "";
  const re = new RegExp(left + esc, "g");
  let m: RegExpExecArray | null;
  while ((m = re.exec(line)) !== null) {
    if (re.lastIndex === m.index) re.lastIndex++;
    if (!continuedAfter(fragment, line.slice(m.index + m[0].length))) return true;
  }
  return false;
}

/** True when what FOLLOWS a fragment continues it or scales its expression. */
function continuedAfter(fragment: string, after: string): boolean {
  const numeric = /[0-9_]$/.test(fragment);
  if (numeric && /^[0-9_.]/.test(after)) return true; // 140, 14.5, 1_800_0000
  if (numeric && /^[eE][0-9]/.test(after)) return true; // 1_800_000e2
  if (numeric && /^n\b/.test(after)) return true; // BigInt literal
  if (/[A-Za-z0-9_$}]$/.test(fragment) && /^[A-Za-z0-9_$]/.test(after)) return true; // identifier / }0
  // A scale applied to the expression the fragment ends: step over legitimate
  // closers and spacing, then refuse an arithmetic operator. A trailing COMMENT
  // (`//`, `#`) is a terminator, not a division.
  const tail = after.replace(/^[)\]}"'`]+/, "").replace(/^[ \t]+/, "");
  if (/^(\/\/|#)/.test(tail)) return false;
  return /^[*/+%&|^<>-]/.test(tail);
}

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
 * True when position `at` in `src` sits inside a quoted string ON ITS OWN LINE.
 *
 * The shell extraction accepts a name= assignment after any non-identifier char
 * (so a `case` arm counts), which also matched the `NAME=` inside a log STRING
 * (`log "... MAX_AGE_DAYS=$MAX_AGE_DAYS ..."`) — a fabricated declaration. The
 * quote state is recomputed from the LINE START every time, so this stays
 * line-local and stateless (nothing carries across lines); a string that spans
 * lines would desynchronize it, which is the same disclosed class as the
 * flush-left block comment.
 */
function insideQuote(src: string, at: number): boolean {
  const lineStart = src.lastIndexOf("\n", at) + 1;
  let quote: string | null = null;
  for (let i = lineStart; i < at; i++) {
    const c = src[i];
    if (c === "\\") {
      i++;
      continue;
    }
    if (quote === null) {
      if (c === '"' || c === "'") quote = c;
    } else if (c === quote) {
      quote = null;
    }
  }
  return quote !== null;
}

/**
 * Every declaration line for `symbol` in `src` (comment LINES blanked), in source
 * order. Plural because a shell script legitimately declares the same symbol
 * more than once (a default near the top, a CLI override, a `10#` coercion) —
 * and `forwardViolations` checks EVERY one of them against the registry's
 * `value` + `overrides` fragments, not whichever the regex hits first.
 */
export function declarationLines(src: string, symbol: string, lang: SourceLang = "ts"): string[] {
  const stripped = yieldCommentLines(src, lang);
  const re = new RegExp(
    lang === "sh"
      ? `(?:^|[^A-Za-z0-9_])(?:export[ \\t]+|readonly[ \\t]+|declare[ \\t]+)?(?:const|let|var)?[ \\t]*${symbol}[ \\t]*=`
      : // TS/JS: the `const|let|var` keyword is REQUIRED, and the name must start
        // the line. Without the keyword, an annotated PARAMETER or an object
        // PROPERTY matched (`(SYMBOL: number) =>`, `{ SYMBOL: 1 }`) and a
        // `value: null` term passed the forward check with its real declaration
        // deleted.
        `(?:^|\\n)[ \\t]*(?:export[ \\t]+)?(?:const|let|var)[ \\t]+${symbol}[ \\t]*(?::[^\\n=;{}]*?)?[ \\t]*=(?!=)`,
    "g",
  );
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(stripped)) !== null) {
    // The match may include the character BEFORE the keyword/name (the shell
    // boundary rule accepts any non-identifier char), so the line is derived
    // from the SYMBOL's own position, never from m.index.
    const at = stripped.indexOf(symbol, m.index);
    if (at === -1 || insideQuote(stripped, at)) continue;
    const lineStart = stripped.lastIndexOf("\n", at) + 1;
    const lineEnd = stripped.indexOf("\n", at);
    // A trailing comment is removed: it must not be able to carry a value the
    // declaration no longer has.
    const lineText = stripTrailingComment(stripped.slice(lineStart, lineEnd === -1 ? stripped.length : lineEnd), lang);
    out.push(lineText.trim());
    if (m.index === re.lastIndex) re.lastIndex++;
  }
  return out;
}

/** The first declaration line for `symbol`, or null. */
export function declarationLine(src: string, symbol: string, lang: SourceLang = "ts"): string | null {
  return declarationLines(src, symbol, lang)[0] ?? null;
}

/**
 * True when `symbol` appears as a DECLARATION in `src` — on the source with
 * comment LINES blanked, in a declaration SHAPE (`const`/`let`/`var`,
 * `function`, or a shell assignment).
 *
 * This is the assertion for `value: null` terms (pointers and derived
 * expressions, which have no literal to compare). A bare word-boundary test over
 * the RAW source is satisfied by a comment that merely NAMES the term, so
 * deleting such a declaration while leaving a comment mentioning it kept BOTH
 * scan directions green (#1068 review).
 */
export function declaresSymbol(src: string, symbol: string, lang: SourceLang = "ts"): boolean {
  const stripped = yieldCommentLines(src, lang);
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
    const stripped = yieldCommentLines(src, lang);
    const regexes = lang === "sh" ? [SH_DECL_ANYWHERE] : [TS_DECL_RE, SH_DECL_LINE_START];
    const seen = new Set<string>();
    for (const re of regexes) {
      re.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = re.exec(stripped)) !== null) {
        const symbol = m[1];
        if (!inFamily(symbol, spec.families, spec.ageSuffixes, spec.boundSuffixes)) continue;
        // A name= inside a quoted string is not a declaration (a log line, or the
        // registry's own `overrides` string literals). Applied to BOTH extractors:
        // the shell shape also runs over TS/JS sources.
        if (insideQuote(stripped, m.index + m[0].lastIndexOf(symbol))) continue;
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
        // is declaration-SHAPED, on source with comment LINES blanked. A bare
        // word-boundary test over raw text is satisfied by a comment that names
        // the term, which made a deleted declaration invisible.
        if (term.value === null && declaresSymbol(src, term.name, langOf(owner))) continue;
        out.push(`${term.name}: ${owner} no longer declares it (de-listed or renamed) — the registry says it does`);
        continue;
      }
      // EVERY declaration line is checked, not just one: a second, shadowing
      // declaration of the same bound used to leave this green as long as ANY
      // line carried the registered fragment (a green gate over a wrong
      // effective value).
      const overrides = term.overrides ?? [];
      if (lines.length !== 1 + overrides.length) {
        out.push(
          `${term.name}: ${owner} declares it ${lines.length} time(s) but the registry models ${1 + overrides.length} (1 default${overrides.length ? ` + ${overrides.length} override(s)` : ""}) — a declaration was added or removed without recording it (lines: ${JSON.stringify(lines)})`,
        );
        continue;
      }
      if (term.value !== null && !carriesValue(lines[0], term.value)) {
        out.push(
          `${term.name}: ${owner} declares ${JSON.stringify(lines[0])}, which does not carry the registered value ${JSON.stringify(term.value)} — the value changed without updating the registry (or vice versa)`,
        );
      }
      for (let i = 0; i < overrides.length; i++) {
        if (!carriesValue(lines[i + 1], overrides[i])) {
          out.push(
            `${term.name}: ${owner} declaration #${i + 2} is ${JSON.stringify(lines[i + 1])}, which does not carry its registered override fragment ${JSON.stringify(overrides[i])} — record the override instead of letting it drift`,
          );
        }
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
      // The exclusion is by NAME and is applied BEFORE the type checks, because
      // `isDirectory()` is false for a symlink: excluding `node_modules` only in
      // the directory branch reported a symlinked `node_modules` (routine under
      // pnpm, npm workspaces, or a developer's `ln -s`) as a DROPPED SUBTREE and
      // failed the vacuity check on a perfectly healthy checkout.
      if (e.name === "node_modules" || e.name === "_deprecated" || e.name.startsWith(".")) continue;
      if (e.isDirectory()) {
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
