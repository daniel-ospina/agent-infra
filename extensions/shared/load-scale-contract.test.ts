/**
 * load-scale-contract.test.ts — #1073
 *
 * Pins the load-scale contract so that a documented env var with no reader, a
 * doc-named callable that does not exist, a doc band that disagrees with the
 * code's literals, or a skill that restates the bands all go RED. It pins the
 * wiring, not every property of the doc — see LIMITS for what it does not.
 *
 * WHY THIS EXISTS: §2/§3 once documented `TASK_LOAD_SCALE_START` / `_MAX` as the
 * watchdog's scale knobs while nothing in the repo read them — an operator could
 * set either one and get nothing, with no warning (the "inert control" /
 * no-op-gate class, AGENTS.md §Product Over Process). The root cause was a
 * rebase that merged one #209 implementation's CODE with another's DOC, and no
 * gate compared a documented env var against an actual reader. This suite is
 * that gate.
 *
 * PINS
 *  1. DOC ⇒ CODE READER. Every env var the doc names must be read by non-test
 *     source, or be an EXPORTED, non-namespaced identifier (that is how the
 *     constant `DEFAULT_TOOL_STALL_MS` legitimately appears in §6). A doc token
 *     in a fleet env namespace (`TASK_`/`LOAD_`/`GIT_`/`TREE_`/`PROCESS_`/…) can
 *     NEVER be exempted by a declaration — otherwise `const TASK_LOAD_SCALE_MAX
 *     = 3` would silently shield the exact knob this guard exists to catch.
 *  2. DOC ⇒ CODE SYMBOL. Every callable the doc names as `name()` must be
 *     declared somewhere in the scan set — the same rebase left the doc naming
 *     a seam that never existed (`__setGetLoad1` for `setLoad1Override`), and a
 *     doc that names a nonexistent symbol is the same defect one level up.
 *  3. DOC BANDS ⇔ CODE LITERALS. §6's band sentence is the declared contract;
 *     the thresholds asserted here are parsed FROM THE DOC, never hardcoded — a
 *     test that hardcodes both sides is a tautology and would accept a
 *     doc-only edit.
 *  4. ONE DECLARATION OF THE BAND VOCABULARY. No `skills/**\/*.md` may restate
 *     the numeric bands; the doc is the single source (a skill that restates
 *     them goes stale the moment #1116 recalibrates, with nothing red).
 *  5. THE TWO COPIES AGREE. `loadScaledBound` (extensions/builtin-tools) and
 *     `loadScaledTimeoutMs` (extensions/slack-bridge) are a keep-in-sync
 *     duplicate held together by a comment; they were the one such pair with no
 *     parity test. Their bodies must be identical and must read exactly
 *     `TASK_LOAD_SCALE_OFF`.
 *
 * NON-VACUITY — the dominant failure mode of a doc-parsing guard is a parse that
 * silently matches nothing and therefore asserts nothing (renamed section, moved
 * table → green). This suite FAILS, never skips, when the doc or a section
 * heading is missing, when the doc yields fewer than TOKEN_FLOOR tokens, when
 * §6's band sentence does not match exactly once, or when a function body cannot
 * be extracted. Mutation controls prove the predicates fire AND that mentions
 * inside comments, string literals, single-quoted shell segments and heredocs
 * are NOT reads, while every real read form (dot, bracket, bracket-by-constant,
 * injected `env.` parameter, template interpolation, `${VAR}`/`$VAR`, python's
 * `os.getenv`/`os.environ`) IS recognised.
 *
 * KIND SPLIT for the reader scan: JS/TS string literals are DATA — a name in a
 * log message is not a read, so their bodies are skipped (template `${…}`
 * interpolations are expressions and ARE scanned). Shell single quotes are DATA
 * and are skipped; shell DOUBLE quotes are EXPANSIONS, so `${NAME:-10}` inside
 * them counts. Python's quotes are both data.
 *
 * LIMITS (stated, not implied — a pin that over-states its reach is the failure
 * mode this suite exists to prevent):
 *  - The reader census is ONE-DIRECTIONAL (doc ⇒ reader). A new env knob added
 *    to code without a doc row is not caught here; the only reverse pins are
 *    the scale-function read set (pin 5) and the skill-surface pin (pin 4).
 *    `unreadEnvTokens` is a pure predicate so a reverse check can be added later.
 *  - Pin 5 scans the EXTRACTED body of each scale function. Extracting a helper
 *    that reads a knob out of that body would evade it — the compensating pin is
 *    the behavioural inertness test in `extensions/builtin-tools/builtin-tools.test.ts`
 *    (#1073), which fails if a retired knob changes any band.
 *  - Pin 2 covers `name()` callables only; a bare identifier in prose is not
 *    asserted (the doc's prose also names locals and parameters, which have no
 *    declarations to match).
 *  - The census asserts that SOME non-test reader exists in the scan set; it does
 *    NOT assert that the §3 `Consumer` column names that reader. A knob read by
 *    the wrong component would pass (a per-row consumer check is a possible
 *    further hardening, deliberately not added here to keep the parser's
 *    false-block surface small).
 *  - ADVISORY, NOT FOLDED IN: the duplication/architecture review recommended
 *    unifying the two scale copies (and both `getSystemLoad` copies) into
 *    `extensions/shared/`. Deliberately deferred: #1073's acceptance is doc↔code
 *    agreement, pin 5 removes the silent-divergence failure mode that made the
 *    duplication dangerous, and unification is a refactor with its own blast
 *    radius (both extensions' imports, their suites, the slack-bridge
 *    no-cross-extension-import policy). Recorded here rather than dropped.
 *    NOTE for whoever does it: `extractFunctionBody(builtinSrc, "loadScaledBound")`
 *    below THROWS if the function leaves `extensions/builtin-tools/index.ts`, and
 *    `builtin-tools.test.ts` pins the literal wiring line — a behaviour-preserving
 *    move/rename must update this suite in the same commit (clear red, not silent).
 *  - READ FORMS NOT RECOGNISED (a false BLOCK, i.e. a future correct wiring can
 *    red here): `const { NAME } = process.env`, `process.env?.NAME`, and a TS
 *    annotation before the string (`const K: string = "NAME"` then
 *    `process.env[K]`) are all missed. So are writes — `process.env.NAME = "1"`
 *    counts as a read — and `env.NAME` on ANY object (`config.env.NAME`), not
 *    just an injected `env` parameter. Every one is false-OPEN (more reads
 *    credited) except the misses, which are false-BLOCK. If a new doc'd knob
 *    uses one of the missed forms, fix the scanner (or the wiring) rather than
 *    adding an exemption — the failure message names the token.
 *    RECOGNISED helper idioms: `numEnv("NAME", …)` / `getEnv("NAME")` /
 *    `env("NAME")` — the callee must CONTAIN `env` (any position, dots allowed)
 *    and the literal must be the WHOLE argument (a concatenation like
 *    `numEnv("NAME" + suffix, …)` is NOT credited, deliberately: that shape can
 *    name a different env var at runtime), plus `process.env[\`NAME\`]`. A
 *    differently named helper (`readCfg("NAME")`, `cfg("NAME")`) is therefore
 *    still a false BLOCK.
 *  - PIN 4 COVERS THE BAND VOCABULARY, NOT EVERY PROSE RESTATEMENT. The
 *    restatement scan runs over `skills/**` only, and the band parser reads
 *    §6's sentence in `docs/ops/load-policy.md` only. Prose restatements
 *    elsewhere — §7's ratio form, `docs/research/*` (e.g. the #279 note), the
 *    #209 plan banners — are NOT pinned, so when #1116 recalibrates they can go
 *    stale with the suite green. §7 was reworded in #1073 to avoid adding a
 *    third restatement; the other docs are out of this PR's scope and left as a
 *    known gap. Pin 4 itself is a heuristic: a line that co-locates a band word,
 *    a `Nx` multiplier and 8/16 without being a restatement ("concurrency 3x,
 *    load 8") still false-blocks — the failure message names the file, and the
 *    fix is a reword.
 *  - UNCLOSED QUOTES ARE NOT STRINGS: a quote that does not close on its own
 *    line is treated as ordinary code, so an apostrophe or a quote inside a
 *    regex literal (`/don't/`, `/^https?:\/\//`) cannot swallow the rest of the
 *    file — that desync silently hid 13 real reads in
 *    `extensions/builtin-tools/index.ts` (e.g. `TASK_HEARTBEAT_TIMEOUT_MS`,
 *    `AGENT_ALLOW_MAIN_EDITS`) the first time this suite ran, and the same class
 *    of false BLOCK is why `TASK_HEARTBEAT_TIMEOUT_MS` is pinned in §3.
 *    Consequence: the TEXT of a multi-line template literal is scanned as code,
 *    so an env-looking name written only inside such a literal counts as a read
 *    (false-OPEN, narrow).
 *  - PER-ROW DEFAULTS are pinned for exactly ONE row —
 *    `TASK_FIRST_OUTPUT_TIMEOUT_MS`, the knob this issue wired, whose §3 default
 *    must be a literal of its getter. The other rows' documented defaults are
 *    not compared against their code constants.
 *
 * Run: npx tsx extensions/shared/load-scale-contract.test.ts
 */

import { readFileSync, readdirSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ok, equal, deepEqual } from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..", "..");
const DOC_REL = "docs/ops/load-policy.md";
const THIS_FILE = basename(fileURLToPath(import.meta.url));

/** Below this many env-looking tokens the doc parse is treated as broken. */
const TOKEN_FLOOR = 8;
/** Below this many distinct reads the source scan is treated as broken. */
const READ_FLOOR = 10;

/** The fleet's env namespaces. A doc token in one of these can NEVER be
 * exempted by an identifier declaration (see pin 1). */
const ENV_NAMESPACE = /^(?:TASK|LOAD|GIT|TREE|PROCESS|PI|AGENT|ELDATO)_/;

const SCAN_ROOTS = [
  "extensions",
  "scripts",
  "bin",
  "pi-bootstrap",
  "connectors",
  "enforcement",
  "templates",
  "sync",
];
const SCAN_EXTS = new Set([".ts", ".mjs", ".js", ".cjs", ".sh", ".bash", ".zsh", ".py"]);
/** Trees that never hold a CONSUMER (prose, tests, CI plumbing, VCS, deps). */
const SKIP_DIRS = new Set([
  "node_modules",
  ".git",
  ".worktrees",
  ".husky",
  "docs",
  "skills",
  "tests",
  "dist",
  "build",
  "coverage",
]);
/** A test file must never satisfy a read on its own (it would make the census vacuous). */
const TEST_FILE = /(^|[._-])test[._-]|_test\.|\.spec\.|\.test\./i;

// ── source scan: comments, strings, reads ─────────────────────────────────

type Kind = "js" | "sh" | "py";

function extOf(name: string): string {
  const i = name.lastIndexOf(".");
  return i <= 0 ? "" : name.slice(i);
}

function kindFor(name: string): Kind {
  const ext = extOf(name);
  if (ext === ".py") return "py";
  if (ext === ".ts" || ext === ".mjs" || ext === ".js" || ext === ".cjs") return "js";
  return "sh";
}

/** Cut a `//` comment, ignoring `//` inside a string/template literal. */
function stripJsLineComment(line: string): string {
  let quote: string | null = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === "\\") i++;
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "/" && line[i + 1] === "/") return line.slice(0, i);
  }
  return line;
}

/** Cut a shell/python `#` comment (line start or whitespace-preceded only, so
 * `${VAR#suffix}` survives), ignoring `#` inside quotes. */
function stripHashComment(line: string): string {
  let quote: string | null = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === "\\" && quote === '"') i++;
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'") quote = c;
    else if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
  }
  return line;
}

export function stripComments(text: string, kind: Kind): string {
  const body = kind === "js" ? text.replace(/\/\*[\s\S]*?\*\//g, " ") : text;
  return body.split("\n").map(kind === "js" ? stripJsLineComment : stripHashComment).join("\n");
}

/** `const NAME = "VALUE"` / `NAME="VALUE"` — env names held in a constant and
 * read as `process.env[CONST]`. */
function collectConsts(text: string, kind: Kind): Map<string, string> {
  const src = stripComments(text, kind);
  const out = new Map<string, string>();
  const re =
    kind === "js"
      ? /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*"([A-Z][A-Z0-9_]+)"/g
      : /^([A-Za-z_][\w]*)=["']([A-Z][A-Z0-9_]+)["']/gm;
  for (const m of src.matchAll(re)) out.set(m[1], m[2]);
  return out;
}

/** ALL-CAPS identifiers DECLARED **with `export`** — the only form that may
 * exempt a doc token (and never one in the fleet's env namespaces). */
function collectExportedIdentifiers(text: string, kind: Kind): Set<string> {
  const src = stripComments(text, kind);
  const out = new Set<string>();
  const re = /export\s+(?:const|let|var|function|class|interface|type|enum)\s+([A-Z][A-Z0-9_]+)\b/g;
  for (const m of src.matchAll(re)) out.add(m[1]);
  return out;
}

/** Every callable declared in source (`function name(` / an arrow assigned to a
 * `const`), for pin 2 (a doc `name()` must exist). The `=` arm requires an arrow
 * tail so that `const x = (1 + 2) * 3` is not registered as a callable. */
function collectCallables(text: string, kind: Kind): Set<string> {
  const src = stripComments(text, kind);
  const out = new Set<string>();
  for (const m of src.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g)) out.add(m[1]);
  const ARROW =
    /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\s*\(|\([^()]*\)\s*(?::[^=]*?)?=>|[A-Za-z_$][\w$]*\s*=>)/g;
  for (const m of src.matchAll(ARROW)) out.add(m[1]);
  return out;
}

function atWordStart(src: string, i: number): boolean {
  return i === 0 || !/[A-Za-z0-9_$]/.test(src[i - 1]);
}

/** Match a read construction anchored at `i`. The scanner only calls this at
 * CODE level — it has already skipped every string literal it is not standing
 * inside — so a read written inside a string can never satisfy the census. */
function matchReadAt(
  src: string,
  i: number,
  kind: Kind,
  consts: Map<string, string>
): { name: string; len: number } | null {
  const rest = src.slice(i);
  if (!atWordStart(src, i)) return null;

  // Quoted bracket forms: process.env["X"], env["X"], os.environ["X"].
  if (kind === "js" || kind === "py") {
    const m = /^(?:process\s*\.\s*env|\benv|os\s*\.\s*environ)\s*\[\s*(["'])([A-Z][A-Z0-9_]+)\1\s*\]/.exec(rest);
    if (m) return { name: m[2], len: m[0].length };
  }
  // python calls: os.getenv("X") / os.environ.get("X").
  if (kind === "py") {
    const g = /^(?:os\s*\.\s*)?getenv\s*\(\s*(["'])([A-Z][A-Z0-9_]+)\1/.exec(rest);
    if (g) return { name: g[2], len: g[0].length };
    const e = /^(?:os\s*\.\s*environ|environ)\s*\.\s*get\s*\(\s*(["'])([A-Z][A-Z0-9_]+)\1/.exec(rest);
    if (e) return { name: e[2], len: e[0].length };
  }
  // Bracket-by-constant: process.env[KILL_SWITCH] with KILL_SWITCH = "X".
  if (kind === "js") {
    const t = /^(?:process\s*\.\s*env|\benv)\s*\[\s*`([A-Z][A-Z0-9_]+)`\s*\]/.exec(rest);
    if (t) return { name: t[1], len: t[0].length };
    const b = /^(?:process\s*\.\s*env|\benv)\s*\[\s*([A-Za-z_$][\w$]*)\s*\]/.exec(rest);
    if (b) {
      const resolved = consts.get(b[1]);
      return resolved ? { name: resolved, len: b[0].length } : null;
    }
    const d = /^(?:process\s*\.\s*env|\benv)\s*\.\s*([A-Z][A-Z0-9_]+)/.exec(rest);
    if (d) return { name: d[1], len: d[0].length };
    // The repo's own env-helper idiom: `numEnv("NAME", default)` / `getEnv(...)`
    // (extensions/session-checks.ts, extensions/slack-bridge/socket-mode.ts).
    // The literal must be the WHOLE argument and the callee must look like an
    // env reader, so `console.log("TASK_X")` stays a mention, not a read.
    const h =
      /^([A-Za-z_$.]*?[Ee][Nn][Vv][A-Za-z0-9_$]*)\s*\(\s*(["'])([A-Z][A-Z0-9_]+)\2(?=\s*[,)])/.exec(rest);
    if (h) return { name: h[3], len: h[0].length };
  }
  // Shell expansions.
  if (kind === "sh") {
    const b = /^\$\{([A-Z][A-Z0-9_]+)/.exec(rest);
    if (b) return { name: b[1], len: b[0].length };
    const p = /^\$([A-Z][A-Z0-9_]+)\b/.exec(rest);
    if (p) return { name: p[1], len: p[0].length };
  }
  return null;
}

/** Shell here-documents. A QUOTED delimiter (`<<'EOF'`) makes the body data and
 * it is skipped; an unquoted one expands, so its body is scanned. Returns the
 * index just past the terminator, or null when this is not a heredoc. */
function tryHeredoc(src: string, i: number, out: Set<string>, consts: Map<string, string>): number | null {
  const m = /^<<-?\s*(?:(["'])([A-Za-z_][\w]*)\1|([A-Za-z_][\w]*))/.exec(src.slice(i));
  if (!m) return null;
  const quoted = m[1] !== undefined;
  const delim = m[2] ?? m[3];
  const lineEnd = src.indexOf("\n", i);
  if (lineEnd < 0) return null;
  let consumed = lineEnd + 1;
  for (const line of src.slice(lineEnd + 1).split("\n")) {
    consumed += line.length + 1;
    if (line.trim() === delim) break;
    if (!quoted) scanCode(line, out, "sh", consts);
  }
  return consumed;
}

/** Scan a text at code level. String handling is kind-specific: JS/py string
 * bodies are DATA and skipped (a JS template literal still exposes its `${…}`
 * expressions); shell double quotes are EXPANSIONS and are scanned; a quoted
 * shell heredoc is data and is skipped. */
function scanCode(
  src: string,
  out: Set<string>,
  kind: Kind,
  consts: Map<string, string>
): void {
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (kind === "sh" && c === "<") {
      const afterHeredoc = tryHeredoc(src, i, out, consts);
      if (afterHeredoc !== null) {
        i = afterHeredoc;
        continue;
      }
    }
    if (c === '"' || c === "'" || (kind === "js" && c === "`")) {
      // A string must CLOSE ON ITS OWN LINE. A quote that does not is not a
      // string at all — it is an apostrophe or a slash-quote inside a regex
      // literal the stripper cannot see (`/don't/`, `/^https?:\/\//`), and
      // treating it as one would swallow every later read in the file.
      const lineEnd = src.indexOf("\n", i);
      const stop = lineEnd < 0 ? src.length : lineEnd;
      let j = i + 1;
      let closed = false;
      while (j < stop) {
        const cj = src[j];
        if (cj === "\\") {
          j += 2;
          continue;
        }
        if (cj === c) {
          closed = true;
          break;
        }
        j++;
      }
      if (!closed) {
        i++;
        continue;
      }
      const body = src.slice(i + 1, j);
      if (kind === "sh" && c === '"') {
        scanCode(body, out, kind, consts); // shell: "$VAR" and "${VAR}" expand
      } else if (kind === "js" && c === "`") {
        scanTemplateExpressions(body, out, consts);
      }
      i = j + 1;
      continue;
    }
    const m = matchReadAt(src, i, kind, consts);
    if (m) {
      out.add(m.name);
      i += m.len;
      continue;
    }
    i++;
  }
}

/** JS template literals: the literal text is DATA, but `${…}` holds real code. */
function scanTemplateExpressions(body: string, out: Set<string>, consts: Map<string, string>): void {
  let i = 0;
  while (i < body.length) {
    if (body[i] === "\\") {
      i += 2;
      continue;
    }
    if (body[i] === "$" && body[i + 1] === "{") {
      let depth = 1;
      let j = i + 2;
      while (j < body.length && depth > 0) {
        if (body[j] === "{") depth++;
        else if (body[j] === "}") depth--;
        j++;
      }
      scanCode(body.slice(i + 2, Math.max(i + 2, j - 1)), out, "js", consts);
      i = j;
      continue;
    }
    i++;
  }
}

/** Env reads in one source text (comments stripped, strings skipped per kind). */
export function collectReads(text: string, kind: Kind): Set<string> {
  const consts = collectConsts(text, kind);
  const out = new Set<string>();
  scanCode(stripComments(text, kind), out, kind, consts);
  return out;
}

// ── doc parse ──────────────────────────────────────────────────────────────

/** Every env var the doc names: every ALL-CAPS token in a backticked span that
 * carries this doc's namespace shape (an underscore — non-env process/log
 * markers such as `BGSAVE`/`WARN` have none), PLUS env-prefixed names anywhere
 * in prose so a prose mention cannot dodge the census. `TASK_LOAD_SCALE_OFF=1`
 * splits on `=`. */
export function docEnvTokens(markdown: string): string[] {
  const out = new Set<string>();
  for (const m of markdown.matchAll(/`([^`\n]+)`/g)) {
    for (const part of m[1].split(/[=,:()\s]+/)) {
      if (/^[A-Z][A-Z0-9]*_[A-Z0-9_]+$/.test(part)) out.add(part);
    }
  }
  for (const m of markdown.matchAll(/\b(?:TASK|LOAD|GIT|TREE|PROCESS|PI|AGENT|ELDATO)_[A-Z0-9_]+\b/g)) {
    out.add(m[0]);
  }
  return [...out].sort();
}

/** The cells of the §3 table row whose first cell is `` `NAME` ``. */
export function docRow(markdown: string, name: string): string[] | null {
  const line = markdown
    .split("\n")
    .find((l) => new RegExp("^\\|\\s*`" + name + "`\\s*\\|").test(l));
  if (!line) return null;
  return line
    .split("|")
    .slice(1, -1)
    .map((c) => c.trim());
}

/** Every callable the doc names as exactly `name()` (pin 2). */
export function docCallables(markdown: string): string[] {
  const out = new Set<string>();
  for (const m of markdown.matchAll(/`([A-Za-z_$][A-Za-z0-9_$]*)\(\)`/g)) out.add(m[1]);
  return [...out].sort();
}

export interface Bands {
  /** scale (1x) below this load */
  t1: number;
  /** 2x from t1 up to below t2; 3x at and above t2 */
  t2: number;
  /** the top-band multiplier (the doc's `3x`, the code's `baseMs * 3`) */
  multiplier: number;
}

const BAND_SENTENCE =
  /`(\d)x` below load `(\d+)`, `(\d)x` at `(\d+) ≤ load1 < (\d+)`, `(\d)x` at `load1 ≥ (\d+)`/g;

/** Parse §6's band sentence. Throws (fail-closed) unless it matches EXACTLY
 * once — a reworded/moved sentence must be a loud red, not an empty parse. */
export function parseDocBands(markdown: string): Bands {
  const text = markdown.replace(/\s+/g, " ");
  const matches = [...text.matchAll(BAND_SENTENCE)];
  if (matches.length !== 1) {
    throw new Error(
      `§6's band sentence matched ${matches.length} time(s), expected exactly 1 — the sentence that ` +
        "declares the scale contract was reworded, moved or duplicated. Fix the sentence (and this " +
        "parser, deliberately) rather than letting the pin go vacuous."
    );
  }
  const [, m1, first, m2, midLower, midUpper, m3, thirdThreshold] = matches[0];
  if (Number(m1) !== 1 || Number(m2) !== 2 || Number(m3) !== 3) {
    throw new Error(`§6's band multipliers must be 1x/2x/3x, got ${m1}x/${m2}x/${m3}x`);
  }
  if (Number(first) !== Number(midLower) || Number(midUpper) !== Number(thirdThreshold)) {
    throw new Error(
      `§6's band sentence is self-contradictory: ${m1}x<${first} but ${m2}x at ${midLower} ≤ load1 < ` +
        `${midUpper} and ${m3}x at ${thirdThreshold}`
    );
  }
  return { t1: Number(first), t2: Number(midUpper), multiplier: Number(m3) };
}

/** Extract a function body with a brace matcher (these bodies hold no braces in
 * strings). Throws if the function is gone — fail-closed, never a silent skip. */
export function extractFunctionBody(source: string, name: string): string {
  const start = source.search(new RegExp(`function\\s+${name}\\s*\\(`));
  if (start < 0) throw new Error(`function ${name}() not found — the pinned surface was renamed or removed`);
  const open = source.indexOf("{", start);
  if (open < 0) throw new Error(`function ${name}() has no body`);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) return source.slice(open + 1, i);
    }
  }
  throw new Error(`function ${name}() has unbalanced braces`);
}

/** The band literals the code actually implements, read out of the body. */
export function codeBands(body: string): Bands {
  const t1 = body.match(/if\s*\(\s*load\s*<\s*(\d+)\s*\)\s*return\s+baseMs\s*;/);
  const t2 = body.match(/if\s*\(\s*load\s*<\s*(\d+)\s*\)\s*return\s+baseMs\s*\*\s*(\d+)\s*;/);
  const cap = [...body.matchAll(/return\s+baseMs\s*\*\s*(\d+)\s*;/g)].pop();
  if (!t1 || !t2 || !cap) {
    throw new Error("could not read the 1x/2x/3x band literals out of the scale-function body");
  }
  if (Number(t2[2]) !== 2) throw new Error(`mid band multiplier is ${t2[2]}x, expected 2x`);
  return { t1: Number(t1[1]), t2: Number(t2[1]), multiplier: Number(cap[1]) };
}

/** Doc tokens with neither a reader nor a legitimate CONSTANT exemption: an
 * exported identifier, never a fleet-env-namespaced name. */
export function unreadEnvTokens(
  tokens: string[],
  reads: Set<string>,
  exportedIdentifiers: Set<string>
): string[] {
  return tokens.filter((t) => {
    if (reads.has(t)) return false;
    // A fleet-env-namespaced token is never exempted by a declaration: the
    // exemption is for constants the doc names as such (`DEFAULT_TOOL_STALL_MS`),
    // not for a `const TASK_…` that would silently shield a knob.
    if (ENV_NAMESPACE.test(t)) return true;
    return !exportedIdentifiers.has(t);
  });
}

// ── scan the repo ──────────────────────────────────────────────────────────

function isScannable(absPath: string, name: string): boolean {
  if (TEST_FILE.test(name)) return false;
  if (SCAN_EXTS.has(extOf(name))) return true;
  if (extOf(name) === "") {
    // Extensionless executables (repo-root `sync`, `sync-all`): a shebang is
    // the only signal. Skipping them would make the stated coverage a lie.
    try {
      return readFileSync(absPath, "utf-8").startsWith("#!");
    } catch {
      return false;
    }
  }
  return false;
}

function walk(absDir: string, out: string[] = []): string[] {
  let entries;
  try {
    entries = readdirSync(absDir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (e.isSymbolicLink()) continue; // never follow a link out of the tree
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name) || e.name.startsWith(".")) continue;
      walk(join(absDir, e.name), out);
      continue;
    }
    if (!e.isFile()) continue;
    const abs = join(absDir, e.name);
    if (isScannable(abs, e.name)) out.push(abs);
  }
  return out;
}

function scannedFiles(): string[] {
  const files: string[] = [];
  for (const r of SCAN_ROOTS) walk(join(REPO_ROOT, r), files);
  // Root-level code files (sync.sh, sync, sync-all and friends).
  for (const e of readdirSync(REPO_ROOT, { withFileTypes: true })) {
    if (!e.isFile()) continue;
    const abs = join(REPO_ROOT, e.name);
    if (isScannable(abs, e.name)) files.push(abs);
  }
  return [...new Set(files)];
}

/** `skills/**\/*.md` — prose surfaces that must NOT restate the numeric bands. */
function skillMarkdownFiles(): string[] {
  return walk(join(REPO_ROOT, "skills")).filter((f) => f.endsWith(".md"));
}

/** A restatement of the numeric load bands (what the skill must not carry). */
const BAND_RESTATEMENT =
  /(?:\d+x\s*[<≥]|≤\s*load1|load1?\s*[<≥]\s*\d)|(?=.*\b(?:band|bands|load|scale)\b)(?=.*\b[123]x\b)(?=.*\b(?:8|16)\b)/;

// ── harness ────────────────────────────────────────────────────────────────

let passed = 0;
const failures: string[] = [];

function test(name: string, fn: () => void): void {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    failures.push(`${name}: ${msg}`);
    console.log(`  ❌ ${name}\n     ${msg}`);
  }
}

console.log("\n#1073 — load-scale doc↔code contract\n");

const docText = readFileSync(join(REPO_ROOT, DOC_REL), "utf-8");
const files = scannedFiles();
const reads = new Set<string>();
const exportedIdentifiers = new Set<string>();
const callables = new Set<string>();
for (const f of files) {
  const kind = kindFor(f);
  const text = readFileSync(f, "utf-8");
  for (const r of collectReads(text, kind)) reads.add(r);
  for (const id of collectExportedIdentifiers(text, kind)) exportedIdentifiers.add(id);
  for (const c of collectCallables(text, kind)) callables.add(c);
}
const tokens = docEnvTokens(docText);

// ── 1. doc ⇒ reader ────────────────────────────────────────────────────────

test("the census is non-vacuous (doc sections, token floor, read floor)", () => {
  for (const heading of ["## 2. Thresholds", "## 3. Env var table", "## 6. Watchdog side"]) {
    ok(docText.includes(heading), `${DOC_REL} is missing the "${heading}" heading`);
  }
  ok(
    tokens.length >= TOKEN_FLOOR,
    `doc yields only ${tokens.length} env-looking tokens (floor ${TOKEN_FLOOR}) — the parse is broken`
  );
  ok(
    reads.size >= READ_FLOOR,
    `source scan found only ${reads.size} distinct env reads (floor ${READ_FLOOR}) over ${files.length} files — the scan is broken`
  );
  ok(files.length >= 40, `source scan covered only ${files.length} files — the scan set is broken`);
});

test("every env var docs/ops/load-policy.md names is read by non-test source", () => {
  const unread = unreadEnvTokens(tokens, reads, exportedIdentifiers);
  deepEqual(
    unread,
    [],
    `documented but read by nothing: ${unread.join(", ")} — wire the knob or drop it from the contract (#1073)`
  );
});

test("positive control: a known-live knob is found by the scan", () => {
  ok(reads.has("TASK_HEARTBEAT_CUT_GAP_MS"), "TASK_HEARTBEAT_CUT_GAP_MS has no reader");
  ok(reads.has("TASK_LOAD_SCALE_OFF"), "TASK_LOAD_SCALE_OFF has no reader");
  ok(
    exportedIdentifiers.has("DEFAULT_TOOL_STALL_MS"),
    "DEFAULT_TOOL_STALL_MS is not an exported identifier (the §6 constant exemption)"
  );
});

test("negative control: the predicate fires on an unread name", () => {
  deepEqual(unreadEnvTokens(["TASK_FAKE_KNOB_XYZ"], reads, exportedIdentifiers), ["TASK_FAKE_KNOB_XYZ"]);
  // an exported, non-namespaced constant is legitimately exempt
  deepEqual(unreadEnvTokens(["DEFAULT_TOOL_STALL_MS"], reads, exportedIdentifiers), []);
});

test("negative control: a declaration can NEVER exempt an env-namespaced doc token", () => {
  // `const TASK_LOAD_SCALE_MAX = 3;` (exported or not) must not shield the knob —
  // that one-line bypass would re-admit exactly what #1073 removed.
  const faked = new Set(["TASK_LOAD_SCALE_MAX"]);
  deepEqual(
    unreadEnvTokens(["TASK_LOAD_SCALE_MAX"], new Set(), faked),
    ["TASK_LOAD_SCALE_MAX"],
    "a declaration shielded a namespaced env name"
  );
});

test("mutation control: a comment, a string literal or a heredoc MENTION is not a read", () => {
  deepEqual([...collectReads("// process.env.TASK_FAKE_KNOB_XYZ\n", "js")], []);
  deepEqual([...collectReads("/* env.TASK_FAKE_KNOB_XYZ */\n", "js")], []);
  deepEqual([...collectReads('const msg = "set TASK_FAKE_KNOB_XYZ to tune";\n', "js")], []);
  // the read SYNTAX inside a literal is data too — the bracket form most of all
  deepEqual([...collectReads("const h = 'use process.env[\"TASK_FAKE_KNOB_XYZ\"]';\n", "js")], []);
  deepEqual([...collectReads('log.info(`tune ${"TASK_FAKE_KNOB_XYZ"}`);\n', "js")], []);
  deepEqual([...collectReads("# ${TASK_FAKE_KNOB_XYZ:-1}\n", "sh")], []);
  deepEqual([...collectReads("echo '${TASK_FAKE_KNOB_XYZ:-1}' > x\n", "sh")], []);
  deepEqual([...collectReads("cat <<'EOF'\n${TASK_FAKE_KNOB_XYZ}\nEOF\n", "sh")], []);
  deepEqual([...collectReads("msg = 'os.getenv(\"TASK_FAKE_KNOB_XYZ\")'\n", "py")], []);
});

test("mutation control: every real read form IS recognised", () => {
  deepEqual([...collectReads("process.env.TASK_FAKE_KNOB_XYZ = '1';\n", "js")], ["TASK_FAKE_KNOB_XYZ"]);
  deepEqual([...collectReads('process.env["TASK_FAKE_KNOB_XYZ"];\n', "js")], ["TASK_FAKE_KNOB_XYZ"]);
  deepEqual([...collectReads('const K = "TASK_FAKE_KNOB_XYZ";\nprocess.env[K] = "1";\n', "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  // the repo's env-helper idiom + a template bracket, both in live use
  deepEqual([...collectReads('const v = numEnv("TASK_FAKE_KNOB_XYZ", 60_000);\n', "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  deepEqual([...collectReads('const v = getEnv("TASK_FAKE_KNOB_XYZ");\n', "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  // a callee that STARTS with `env`, and the method form
  deepEqual([...collectReads('const v = env("TASK_FAKE_KNOB_XYZ");\n', "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  deepEqual([...collectReads('const v = envReader("TASK_FAKE_KNOB_XYZ");\n', "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  deepEqual([...collectReads('const v = cfg.env("TASK_FAKE_KNOB_XYZ");\n', "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  deepEqual([...collectReads("const v = process.env[`TASK_FAKE_KNOB_XYZ`];\n", "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  // …but a concatenated / computed argument is NOT the whole argument — the
  // exact "a doc-named token looks read while a different var is read" shape
  deepEqual([...collectReads('const v = numEnv("TASK_FAKE_KNOB_XYZ" + suffix, 1);\n', "js")], []);
  deepEqual([...collectReads('const s = "set TASK_FAKE_KNOB_XYZ to 1";\n', "js")], []);
  deepEqual([...collectReads("function f(env = process.env) { return env.TASK_FAKE_KNOB_XYZ; }\n", "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  // a template interpolation is CODE, not literal text
  deepEqual([...collectReads("console.error(`bound ${process.env.TASK_FAKE_KNOB_XYZ}`);\n", "js")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  deepEqual([...collectReads('X="${TASK_FAKE_KNOB_XYZ:-10}"\n', "sh")], ["TASK_FAKE_KNOB_XYZ"]);
  deepEqual([...collectReads("X=${TASK_FAKE_KNOB_XYZ}\n", "sh")], ["TASK_FAKE_KNOB_XYZ"]);
  deepEqual([...collectReads('import os\nv = os.getenv("TASK_FAKE_KNOB_XYZ")\n', "py")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
  deepEqual([...collectReads('import os\nv = os.environ["TASK_FAKE_KNOB_XYZ"]\n', "py")], [
    "TASK_FAKE_KNOB_XYZ",
  ]);
});

test("mutation control: the doc parser keeps non-env ALL-CAPS markers out of the census", () => {
  deepEqual(docEnvTokens("the `BGSAVE` should not `WARN`"), []);
  deepEqual(docEnvTokens("counted: TASK_FAKE_KNOB_XYZ"), ["TASK_FAKE_KNOB_XYZ"]);
});

// ── 1b. doc ⇒ symbol (pin 2) ────────────────────────────────────────────────

test("every callable the doc names as name() exists in source", () => {
  const named = docCallables(docText);
  ok(named.length >= 3, `the doc named only ${named.length} callables — the parse is broken`);
  const missing = named.filter((n) => !callables.has(n));
  deepEqual(missing, [], `docs/ops/load-policy.md names callables that do not exist: ${missing.join(", ")}`);
});

test("mutation control: the symbol predicate fires on a nonexistent seam", () => {
  const missing = docCallables("seam `__setGetLoad1()`").filter((n) => !callables.has(n));
  deepEqual(missing, ["__setGetLoad1"]);
});

test("the doc names the suite that pins it (a renamed pin must not leave the doc lying)", () => {
  ok(
    docText.includes(THIS_FILE),
    `${DOC_REL} no longer names ${THIS_FILE} — if the suite was renamed, update the doc in the same commit`
  );
});

// ── 1c. one declaration of the band vocabulary (pin 4) ─────────────────────

test("no skill restates the numeric load bands — the doc is the only declaration", () => {
  const restating = skillMarkdownFiles().filter((f) => BAND_RESTATEMENT.test(readFileSync(f, "utf-8")));
  deepEqual(
    restating.map((f) => f.slice(REPO_ROOT.length + 1)),
    [],
    "a skill restates the band numbers; point at docs/ops/load-policy.md §6 instead (#1073)"
  );
});

test("mutation control: the band-restatement predicate fires on the old wording", () => {
  ok(BAND_RESTATEMENT.test("(loadScaledBound: 1x <8, 2x 8–15, 3x ≥16; TASK_LOAD_SCALE_OFF=1 bypasses)"));
  ok(BAND_RESTATEMENT.test("2x at `8 ≤ load1 < 16`"));
  // prose restatements that carry no operator (the false-PASS class)
  ok(BAND_RESTATEMENT.test("the load bands are 1x/2x/3x at 8/16"));
  ok(BAND_RESTATEMENT.test("scale at load 8 and again at 16, 2x then 3x"));
  ok(!BAND_RESTATEMENT.test("through the fixed bands declared in `docs/ops/load-policy.md` §6"));
  // counter-controls: ordinary prose that merely co-locates a multiplier and a
  // number must NOT false-block (see LIMITS for the residual case)
  ok(!BAND_RESTATEMENT.test("retry 2x after 8 seconds, and keep concurrency at 3"));
  ok(!BAND_RESTATEMENT.test("V2 ships 8 files with 3x latency"));
});

// ── 2. doc bands ⇔ code bands ──────────────────────────────────────────────

const builtinSrc = readFileSync(join(REPO_ROOT, "extensions/builtin-tools/index.ts"), "utf-8");
const slackSrc = readFileSync(join(REPO_ROOT, "extensions/slack-bridge/socket-mode.ts"), "utf-8");
const builtinBody = extractFunctionBody(builtinSrc, "loadScaledBound");
const slackBody = extractFunctionBody(slackSrc, "loadScaledTimeoutMs");

test("§6's band sentence parses and is internally consistent", () => {
  const doc = parseDocBands(docText);
  ok(doc.t1 > 0 && doc.t2 > doc.t1, `bands must increase: got ${doc.t1} then ${doc.t2}`);
  equal(doc.multiplier, 3, "the declared top-band multiplier must be 3");
});

test("the code implements exactly the bands the doc declares", () => {
  const doc = parseDocBands(docText);
  deepEqual(codeBands(builtinBody), doc, "loadScaledBound's literals differ from §6's declared bands");
  deepEqual(codeBands(slackBody), doc, "loadScaledTimeoutMs's literals differ from §6's declared bands");
});

test("mutation control: the band pin tracks a changed threshold on both sides", () => {
  // Move the 1x boundary AND the 2x lower bound together (a consistent edit) so
  // the assertion is that the PARSER tracked the doc, not that a literal is
  // hardcoded here.
  const shifted = docText.replace(
    "`1x` below load `8`, `2x` at `8 ≤ load1 < 16`",
    "`1x` below load `9`, `2x` at `9 ≤ load1 < 16`"
  );
  equal(parseDocBands(shifted).t1, 9, "the doc parser ignored a changed threshold");
  deepEqual(codeBands(builtinBody.replace("load < 8", "load < 9")), { t1: 9, t2: 16, multiplier: 3 });
  ok(
    JSON.stringify(codeBands(builtinBody.replace("load < 8", "load < 9"))) !==
      JSON.stringify(parseDocBands(docText)),
    "a code-side band change must differ from the doc's bands"
  );
  // fail-closed: a reworded sentence must throw, not silently parse nothing
  let threw = false;
  try {
    parseDocBands(docText.replace("`1x` below load `8`", "1x below load 8"));
  } catch {
    threw = true;
  }
  ok(threw, "a reworded band sentence must throw (fail-closed), not parse to nothing");
});

// ── 3. the two copies agree ────────────────────────────────────────────────

test("the duplicated scale functions are byte-identical once comments are stripped", () => {
  const norm = (s: string) => stripComments(s, "js").replace(/\s+/g, " ").trim();
  equal(
    norm(builtinBody),
    norm(slackBody),
    "loadScaledBound (builtin-tools) and loadScaledTimeoutMs (slack-bridge) have drifted — keep-in-sync"
  );
});

test("the scale functions read exactly TASK_LOAD_SCALE_OFF — no scale knobs", () => {
  for (const [name, body] of [
    ["loadScaledBound", builtinBody],
    ["loadScaledTimeoutMs", slackBody],
  ] as const) {
    deepEqual([...collectReads(body, "js")].sort(), ["TASK_LOAD_SCALE_OFF"], `${name} read set`);
  }
});

test("the two duplicated getSystemLoad probes read the same OS sources", () => {
  for (const [name, src] of [
    ["builtin-tools", builtinSrc],
    ["slack-bridge", slackSrc],
  ] as const) {
    const body = extractFunctionBody(src, "getSystemLoad");
    ok(body.includes('"/proc/loadavg"'), `${name}'s getSystemLoad no longer reads /proc/loadavg`);
    ok(body.includes("sysctl -n vm.loadavg"), `${name}'s getSystemLoad no longer reads sysctl vm.loadavg`);
  }
});

test("the §3 default for TASK_FIRST_OUTPUT_TIMEOUT_MS is the code's own default", () => {
  // The one per-row default pin (see LIMITS): this issue made the override live,
  // so the number the doc publishes to an operator must be the getter's number.
  const row = docRow(docText, "TASK_FIRST_OUTPUT_TIMEOUT_MS");
  ok(row, "the §3 row for TASK_FIRST_OUTPUT_TIMEOUT_MS is gone — the wiring this suite pins was removed");
  const docNums = new Set(row![1].match(/\d[\d_]*/g) ?? []);
  ok(docNums.size > 0, `the §3 default cell names no number: "${row![1]}"`);
  const body = extractFunctionBody(
    readFileSync(join(REPO_ROOT, "extensions/builtin-tools/index.ts"), "utf-8"),
    "getFirstOutputTimeoutMs"
  );
  const codeNums = new Set(body.match(/\d[\d_]*/g) ?? []);
  for (const n of docNums) {
    ok(
      codeNums.has(n),
      `the doc's default ${n} is not a literal of getFirstOutputTimeoutMs() — one side was changed alone ` +
        `(§3 default cell: "${row![1]}"; code literals: ${[...codeNums].join(", ")})`
    );
  }
  // mutation control: run the SAME predicate over a synthetic bumped doc cell
  const bumped = new Set(
    (row![1].replace(/\d[\d_]*/g, "120_000").match(/\d[\d_]*/g) ?? [])
  );
  ok(
    [...bumped].some((n) => !codeNums.has(n)),
    "mutation control: the doc-default predicate must reject a value the getter does not have"
  );
});

test("mutation control: a quote inside a regex literal cannot swallow later reads", () => {
  // Live defect caught by this suite's first run: an unpaired quote in a regex
  // literal put the scanner into a string that never closed, hiding 13 real
  // reads in extensions/builtin-tools/index.ts (TASK_HEARTBEAT_TIMEOUT_MS,
  // AGENT_ALLOW_MAIN_EDITS, TASK_FALLBACK_DISABLE, …) and false-BLOCKING any doc
  // that named one of them.
  const src = [
    "const re = /don't/;",
    "const url = /^https?:\\/\\//;",
    'const a = process.env["TASK_FAKE_KNOB_XYZ"];',
    "const b = env.TASK_OTHER_KNOB_ABC;",
  ].join("\n");
  const got = collectReads(src, "js");
  for (const n of ["TASK_FAKE_KNOB_XYZ", "TASK_OTHER_KNOB_ABC"]) {
    ok(got.has(n), `a quote inside a regex literal swallowed the read of ${n}`);
  }
});

// ── result ─────────────────────────────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failures.length} failed ===`);
if (failures.length > 0) {
  console.log("❌ FAILURES:");
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
