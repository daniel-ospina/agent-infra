/**
 * search-guard — refuses an unbounded recursive search over a tree that carries
 * vendored/parallel trees (`node_modules`, `.worktrees`), and names a bounded
 * replacement. Last line of defence for #1069: the fleet's most expensive habit
 * is an ignore-blind walk started at a repo root, which descends into
 * `.worktrees/* /node_modules` (169 GB in one checkout) and held three sessions
 * at load ~18 on 10 CPUs for 80 minutes.
 *
 * The contract, in one line: THE CORPUS TEACHES ONLY PRIMITIVES THE GUARD
 * ALLOWS; THE GUARD REFUSES ONLY THE SHAPE THE CORPUS NO LONGER TEACHES. The
 * corpus half is the `## Search` section in AGENTS.md (+ the rewrite of the
 * taught `grep -r` sites); the harness in `tests/search-cost/run.sh` asserts
 * both directions through this module's real classifier.
 *
 * Design rules (see docs/plans/2026-09-15-issue-1069-search-cost.md, Rev 8):
 *   R0  command-word location — the watched binary must head a command segment,
 *       preceded at most by prefix-like words (`sudo`, `env`, `!`, `timeout`…).
 *   R1  system/home root — a recursive search rooted at `/`, a home directory, a
 *       top-level system prefix, or a direct child of one is refused, always.
 *   R2  unbounded recursive `grep -r*` with a vendored/parallel root.
 *   R3  unbounded `find` with a vendored/parallel root.
 *   R3p the bounding-shape exemption (`-maxdepth`, or a `-prune` guarded by a
 *       genuinely directory-blocking predicate) — R1 is never exempted.
 *   R4  ignore-defeat flags for `rg`/`fd`.
 *   R5  the exclusion carve-out for `grep -r*` carrying both required
 *       `--exclude-dir` values (applies only where R1 does not).
 *   R6  `SEARCH_GUARD_DISABLED=1` escape hatch.
 *
 * The command model (quote mask, `cd` chains, `~`/`$VAR` expansion, `.js` → `.ts`
 * module mapping) is NOT re-implemented here: it is imported from
 * `../shared/git-command-parse.js`, "THE single copy of the git/gh
 * command-parsing helpers" (#966), whose header records what a second copy
 * costs — two copies disagreed on seven input classes and shipped a fail-open
 * root mis-resolution (#960).
 */

import { existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { expandCdTarget, parseCdChains, unquotedMask } from "../shared/git-command-parse.js";

/** The binaries whose recursive use can amplify into a tree walk. */
const WATCHED = new Set(["grep", "find", "rg", "fd"]);

/**
 * R0 prefix-like words. Only `stdbuf` and `timeout` consume their own
 * arguments (and only their DECLARED value-taking options); everything else is
 * word-only, so e.g. `sudo -u root find /` is an accepted residual rather than
 * a hook that pretends to parse `sudo`'s grammar. Shell grouping and
 * control-flow are likewise out of scope — see the README's declaration.
 */
const PREFIXES = new Set([
  "!", "time", "sudo", "doas", "nohup", "command", "env",
  "nice", "ionice", "stdbuf", "timeout",
]);

/** Shell grouping / control-flow words sit where a command word would; skip them. */
const TRANSPARENT = new Set(["{", "}", "(", ")", "then", "do", "done", "fi", "else", "elif"]);

/** R1: top-level system prefixes. A DIRECT CHILD of one is a root too. */
const SYSTEM_PREFIXES = [
  "/Users", "/home", "/Volumes", "/System", "/Applications", "/private",
  "/etc", "/usr", "/var", "/opt", "/tmp", "/bin", "/sbin", "/Library",
];

/** R2/R3: the trees whose presence makes a walk expensive. */
const VENDORED = ["node_modules", ".worktrees"];

/** Bounded child scan so the hook stays O(1)-ish per command. */
const MAX_CHILDREN = 200;

const KILL_SWITCH = "SEARCH_GUARD_DISABLED";

export interface SearchVerdict {
  block: true;
  reason: string;
}

export interface Token {
  /** The token with quote characters removed and escapes resolved. */
  value: string;
  /** True when the token carried any quoting (so `"$VAR"` is still a variable). */
  quoted: boolean;
}

type Warn = (message: string) => void;
const defaultWarn: Warn = (m) => console.warn(`[search-guard] ${m}`);

// ── tokenization ────────────────────────────────────────────────────────────

/**
 * Split a command into tokens using the shared module's ONE quote model
 * (`unquotedMask`), so a quoted mention cannot be mistaken for a command word.
 * The mask is indexed by character, so splitting here cannot disagree with
 * `parseCdChains` about where the quotes are.
 */
export function tokenize(command: string): Token[] {
  const mask = unquotedMask(command);
  const out: Token[] = [];
  let cur = "";
  let started = false;
  let quoted = false;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    const unquoted = mask[i];
    if (unquoted && /\s/.test(ch)) {
      if (started) out.push({ value: cur, quoted });
      cur = "";
      started = false;
      quoted = false;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quoted = true;
      started = true;
      continue;
    }
    if (unquoted && ch === "\\" && i + 1 < command.length) {
      cur += command[i + 1];
      i++;
      started = true;
      continue;
    }
    cur += ch;
    started = true;
  }
  if (started) out.push({ value: cur, quoted });
  return out;
}

/**
 * Split a command into command segments on unquoted `&&`, `||`, `;`, `|`, `&`
 * and newlines — character-wise, so `cd /a&&grep -rn p` (no spaces) splits too.
 * Quotes are respected via the shared `unquotedMask`; `$(pwd)` and `2>&1`-style
 * redirections inside a word are not separators.
 */
export function splitSegments(command: string): string[] {
  const mask = unquotedMask(command);
  const out: string[] = [];
  let cur = "";
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    const unq = mask[i];
    if (unq && (ch === "\n" || ch === ";")) {
      out.push(cur);
      cur = "";
      continue;
    }
    if (unq && ch === "&") {
      out.push(cur);
      cur = "";
      if (command[i + 1] === "&") i++;
      continue;
    }
    if (unq && ch === "|") {
      out.push(cur);
      cur = "";
      if (command[i + 1] === "|") i++;
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

// ── R0: skip prefix-like words (and the declared argument consumers) ─────────

function skipPrefixes(toks: Token[], start: number): number {
  let i = start;
  while (i < toks.length) {
    const v = toks[i].value;
    if (!toks[i].quoted && /^[A-Za-z_][A-Za-z0-9_]*=/.test(v)) {
      i++;
      continue;
    }
    if (!PREFIXES.has(v)) return TRANSPARENT.has(v) ? skipPrefixes(toks, i + 1) : i;
    const p = v;
    i++;
    if (p === "timeout") {
      while (i < toks.length && toks[i].value.startsWith("-")) {
        const o = toks[i].value;
        if (o === "--") {
          i++;
          break;
        }
        if (/^-[sk]$/.test(o) || o === "--signal" || o === "--kill-after") {
          i += 2; // separate value
        } else if (/^-[sk].+/.test(o) || /^--(signal|kill-after)=/.test(o)) {
          i += 1; // attached or =VALUE
        } else {
          i += 1; // flag-only option (-v/--verbose/--foreground/--preserve-status)
        }
      }
      if (i < toks.length) i++; // the duration word
    } else if (p === "stdbuf") {
      while (i < toks.length && toks[i].value.startsWith("-")) {
        const o = toks[i].value;
        i += /^-[ioe]$/.test(o) ? 2 : 1;
      }
    } else if (p === "time") {
      while (i < toks.length && toks[i].value.startsWith("-")) i++;
    }
  }
  return i;
}

// ── R1: root classification ────────────────────────────────────────────────

function hasMetacharacter(s: string): boolean {
  return /[*?[{]/.test(s);
}

/** R1's depth-2 boundary: `/`, a home dir, a top-level prefix, or its direct child. */
export function isSystemOrHomeRoot(dir: string): boolean {
  // realpath FIRST: a lexical resolve() let a symlinked root defeat R1 entirely —
  // `link-root -> /` normalised to a path under the fixture, so
  // `find link-root -name x` walked the whole filesystem and ALLOWed. A path that
  // does not exist yet keeps the lexical form (realpathSync throws on ENOENT).
  let norm = resolve(dir);
  try {
    norm = realpathSync(norm);
  } catch {
    /* nonexistent path — the lexical form is the only answer available */
  }
  if (norm === sep) return true;
  if (norm === resolve(homedir())) return true;
  for (const p of SYSTEM_PREFIXES) {
    if (norm === p) return true;
    if (norm.startsWith(p + sep)) {
      const rest = norm.slice(p.length + 1);
      if (!rest.includes(sep)) return true; // direct child of a system prefix
    }
  }
  return false;
}

/**
 * R2/R3's root predicate. A readdir failure is a DECLARED FAIL-OPEN TO ALLOW: a
 * category-B cost guard must never abort a tool call (#879 class).
 */
export function carriesVendoredTrees(root: string, warn: Warn = defaultWarn): boolean {
  try {
    for (const name of VENDORED) {
      if (existsSync(join(root, name))) return true;
    }
    const entries = readdirSync(root, { withFileTypes: true }).slice(0, MAX_CHILDREN);
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      for (const name of VENDORED) {
        if (existsSync(join(root, e.name, name))) return true;
      }
    }
    return false;
  } catch (e) {
    warn(`could not probe ${root} (${String(e)}) — allowing (declared fail-open)`);
    return false;
  }
}

type OperandKind =
  | { kind: "unresolvable"; raw: string }
  | { kind: "path"; raw: string; path: string; file: boolean }
  | { kind: "glob"; raw: string; prefix: string | null };

/**
 * Resolve one operand. Unresolvable and glob inputs never fall through to
 * ALLOW: `null` is the honest "I cannot attest this root" and the caller blocks.
 * A glob is bounded only when the literal prefix BEFORE the first metacharacter
 * is a real, non-root directory — the shell expands such a glob inside a bounded
 * directory, whereas `*` alone (or `src/../*`, which normalizes back to the
 * root) expands over the whole tree.
 */
export function resolveOperand(raw: string, cwd: string): OperandKind {
  const expanded = expandCdTarget(raw, cwd);
  if (expanded === null) return { kind: "unresolvable", raw };
  if (hasMetacharacter(raw)) {
    const parts = raw.split("/");
    const literal: string[] = [];
    for (const part of parts) {
      if (hasMetacharacter(part)) break;
      if (/[{}`]/.test(part) || /\$/.test(part)) return { kind: "unresolvable", raw };
      literal.push(part);
    }
    const joined = literal.join("/") || ".";
    const prefix = expandCdTarget(joined, cwd);
    if (prefix === null) return { kind: "unresolvable", raw };
    return { kind: "glob", raw, prefix };
  }
  let file = false;
  try {
    file = statSync(expanded).isFile();
  } catch {
    file = false; // missing paths stay subject to the predicate (conservative)
  }
  return { kind: "path", raw, path: expanded, file };
}

// ── per-rule evaluation ────────────────────────────────────────────────────

interface ArgScan {
  flags: string[];
  operands: string[];
  excludeDirs: string[];
  /** true when the pattern came from `-e`/`-f` (so no bare pattern word). */
  patternFromFlag: boolean;
}

/**
 * Collect flags and operands. `firstBareIsPattern` (grep) drops the first
 * non-flag word — `grep -rn PATTERN [PATH…]` — which otherwise looks exactly
 * like an operand and would be resolved as the search root.
 */
function scanArgs(
  toks: Token[],
  valueTaking: Set<string>,
  longValue: Set<string>,
  firstBareIsPattern: boolean,
): ArgScan {
  const flags: string[] = [];
  const operands: string[] = [];
  const excludeDirs: string[] = [];
  let patternFromFlag = false;
  let patternSeen = !firstBareIsPattern;
  let i = 0;
  let endOfOptions = false;
  while (i < toks.length) {
    const v = toks[i].value;
    if (v === "--") {
      endOfOptions = true;
      i++;
      continue;
    }
    // Shell redirections are NOT operands. The shell strips `2>/dev/null` before
    // grep ever sees argv, so `grep -rn p 2>/dev/null` passes no file operand and
    // searches `.` — but the token was collected as one, which made
    // `scan.operands` non-empty and skipped the implicit-root classification
    // entirely (`grep -rn p` BLOCKed while `grep -rn p 2>/dev/null` ALLOWed).
    // A redirect with no attached target (`> out.txt`) also consumes its word.
    const redirect = /^(?:\d*)?(?:&>>|&>|>>|<<<|<<|<>|>\||>|<)(.*)$/.exec(v);
    if (redirect) {
      if (redirect[1] === "") i++; // `> file` — the target is a separate word
      i++;
      continue;
    }
    if (!endOfOptions && v.startsWith("--")) {
      flags.push(v);
      const eq = v.indexOf("=");
      // `--directories recurse` ≡ `--directories=recurse` ≡ `-r`: normalise the
      // joined value into ONE flag shape (so isRecursiveGrep cannot miss it) and
      // consume the value word, which would otherwise be read as the pattern.
      if (v === "--directories") {
        const val = i + 1 < toks.length ? toks[i + 1].value : "";
        flags.push(`--directories=${val}`);
        i += 2;
        continue;
      }
      if (eq > 0) {
        if (v.slice(0, eq) === "--exclude-dir") excludeDirs.push(v.slice(eq + 1));
        if (["--regexp", "--file"].includes(v.slice(0, eq))) patternFromFlag = true;
        if (["--exclude-dir", "--exclude", "--include", "--exclude-from", "--regexp", "--file", "--max-count"].includes(v.slice(0, eq))) {
          i++;
          continue;
        }
      } else {
        if (longValue.has(v)) {
          if (v === "--regexp" || v === "--file") patternFromFlag = true;
          i++;
        }
      }
      i++;
      continue;
    }
    if (!endOfOptions && v.startsWith("-") && v !== "-") {
      flags.push(v);
      if (v === "--exclude-dir") {
        if (i + 1 < toks.length) excludeDirs.push(toks[i + 1].value);
        i += 2;
        continue;
      }
      if (/^-[efm]$/.test(v)) {
        if (v === "-e" || v === "-f") patternFromFlag = true;
        i += 2;
        continue;
      }
      // `-d ACTION` (directories: read|skip|recurse). The value must travel WITH
      // the flag: read as a separate word it becomes the pattern, and `-d` alone
      // would otherwise be read as "recursive" unconditionally (`-d skip` is the
      // very opposite). Normalised to the same shape as `--directories=…`.
      if (v === "-d") {
        const val = i + 1 < toks.length ? toks[i + 1].value : "";
        flags.push(`--directories=${val}`);
        i += 2;
        continue;
      }
      if (/^-[ABC]$/.test(v) || valueTaking.has(v)) {
        i += 2;
        continue;
      }
      i++;
      continue;
    }
    if (!patternSeen) {
      patternSeen = true; // the bare pattern word
      i++;
      continue;
    }
    operands.push(v);
    i++;
  }
  return { flags, operands, excludeDirs, patternFromFlag };
}

const GREP_LONG_VALUE = new Set([
  "--include", "--exclude", "--exclude-dir", "--regexp", "--file",
  "--exclude-from", "--max-count", "--after-context", "--before-context", "--context",
]);
const FIND_VALUE = new Set(["-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth", "-newer", "-mtime", "-perm", "-size", "-user", "-group", "-printf", "-exec"]);

const GREP_SHORT_VALUE = new Set(["-e", "-f", "-m", "-A", "-B", "-C"]);

function isRecursiveGrep(flags: string[]): boolean {
  for (const f of flags) {
    // Every spelling of grep's recursion is the same walk: `-r`/`-R`, the long
    // forms, and `--directories=ACTION` with a recursing ACTION. Recognizing only
    // `-r`-shaped and `--recursive` left `--dereference-recursive` and
    // `--directories=recurse` ALLOWing an unbounded walk.
    if (f === "--recursive" || f === "--dereference-recursive") return true;
    if (/^--directories=(recurse|r)$/.test(f)) return true;
    if (/^-d(recurse|r)$/.test(f)) return true;
    if (/^-[A-Za-z]*[rR]/.test(f)) return true;
  }
  return false;
}

/**
 * R3p's guard test: the predicate IMMEDIATELY before `-prune` must name a
 * directory-blocking target — `-name X -prune` / `-path X -prune`, or a
 * `\( … \)` group ending right before it. A LOOKBACK WINDOW is unsound: in
 * `find . -name node_modules -o -name '*.ts' -prune` the vendored name belongs to
 * a different `-o` branch, so the expression is
 * `( -name node_modules -o ( -name '*.ts' -a -prune ) )` — nothing is pruned for
 * the node_modules directory and the walk descends, yet the window read that as a
 * bound and ALLOWed it. Symmetrically the reversed order
 * (`-name node_modules -print -o -name '*.ts' -prune`) is not a bound either.
 */
function pruneGuardIsVendored(words: string[], i: number): boolean {
  const VENDORED_NAME = /(node_modules|\.worktrees|\.git|\.\*|_\*)/;
  const isNameOp = (w: string) => /^-(i?name|i?path)$/.test(w);
  if (words[i - 1] === ")") {
    // The group is the immediately-preceding atom: walking back to its matching
    // `(` is exact, and every `-name` inside that group genuinely gates the prune
    // (`\( -name node_modules -o -name .git \) -prune` is the standard idiom).
    let depth = 0;
    for (let j = i - 1; j >= 0; j--) {
      if (words[j] === ")") depth++;
      else if (words[j] === "(") {
        depth--;
        if (depth === 0) {
          for (let k = j; k + 1 < i; k++) {
            if (isNameOp(words[k]) && VENDORED_NAME.test(words[k + 1])) return true;
          }
          return false;
        }
      }
    }
    return false;
  }
  const op = words[i - 2];
  const val = words[i - 1];
  return Boolean(op !== undefined && val !== undefined && isNameOp(op) && VENDORED_NAME.test(val));
}

/** R3p: does this `find` carry a genuine bound? */
function findBound(args: Token[]): { bounded: boolean; maxdepth: boolean } {
  const words = args.map((t) => t.value);
  // `-maxdepth N` bounds the walk. `-depth` does NOT: it is the depth-first
  // traversal ORDER (GNU/POSIX) or a result-depth PREDICATE (BSD) and the walk
  // still descends — `find . -depth -name '*.ts'` walked the whole tree. Nothing
  // in the corpus uses `-depth`, so nothing depended on the old arm.
  const maxdepth = words.some((w) => w.startsWith("-maxdepth"));
  let pruneBlocking = false;
  for (let i = 0; i < words.length; i++) {
    if (words[i] !== "-prune") continue;
    if (pruneGuardIsVendored(words, i)) pruneBlocking = true;
  }
  return { bounded: maxdepth || pruneBlocking, maxdepth };
}

const IGNORE_DEFEAT_LONG = /^--no-ignore/;

/** R4: ignore-defeat flags. */
function ignoreDefeat(toks: Token[], from: number, binary: string): string | null {
  for (const t of toks.slice(from)) {
    const v = t.value;
    if (IGNORE_DEFEAT_LONG.test(v)) return v;
    if (binary === "rg") {
      if (v === "--unrestricted" || /^-[A-Za-z]*u+[A-Za-z]*$/.test(v)) return v;
    } else if (v === "--unrestricted" || /^-[A-Za-z]*[Iu][A-Za-z]*$/.test(v)) {
      return v;
    }
  }
  return null;
}


// ── the block reason (always names a runnable replacement) ──────────────────

let cachedRg: boolean | null = null;
function rgAvailable(): boolean {
  if (cachedRg !== null) return cachedRg;
  const candidates = [
    join(homedir(), ".pi", "agent", "bin", "rg"),
    ...(process.env.PATH ?? "").split(":").filter(Boolean).map((d) => join(d, "rg")),
  ];
  cachedRg = candidates.some((p) => existsSync(p));
  return cachedRg;
}

function blockReason(root: string, rule: string, binary: string): string {
  const lines = [
    `🛑 search-guard (${rule}): refusing an unbounded recursive \`${binary}\` search rooted at ${root}.`,
    "   That root carries vendored/parallel trees (node_modules, .worktrees) — the walk that costs",
    "   169 GB per checkout and 80 minutes of load (#1069).",
    "   Use an index-bounded primitive instead:",
  ];
  if (rgAvailable()) {
    lines.push("     rg -n 'PATTERN' -g '*.py'          # honours .gitignore and skips hidden paths");
  }
  lines.push("     git grep -n -e 'PATTERN' -- '*.py' # reads the repo index (tracked files only)");
  lines.push(
    "   Or bound the walk explicitly: --exclude-dir=.worktrees --exclude-dir=node_modules,",
    "   an `-maxdepth N`, a directory-blocking `-prune`, or an explicit non-root start point.",
    `   Escape hatch (rare, say why in the transcript): ${KILL_SWITCH}=1`,
  );
  return lines.join("\n");
}

// ── the classifier ─────────────────────────────────────────────────────────

/**
 * Classify one bash command string. Pure: the only inputs are the command and
 * the execution cwd (the caller passes `process.cwd()` in production and a
 * fixture path in tests). Returns `null` to allow.
 */
export function classifySearchCommand(
  command: string,
  execCwd: string,
  warn: Warn = defaultWarn,
): SearchVerdict | null {
  if (!command || !command.trim()) return null;
  if (process.env[KILL_SWITCH] === "1") return null;

  const toks = tokenize(command);
  // R6: the kill switch may also be written as a command prefix.
  for (const t of toks.slice(0, 6)) {
    if (t.value === `${KILL_SWITCH}=1`) return null;
  }

  const chain = parseCdChains(command);
  let cwd = execCwd;
  const cwdUnattributable = chain.unattributable;
  if (chain.last) cwd = chain.last;

  for (const raw of splitSegments(command)) {
    const seg = tokenize(raw);
    const head = skipPrefixes(seg, 0);
    if (head >= seg.length) continue;
    const binary = seg[head].value;
    // R4b: `git grep` is the corpus's recommended primitive BECAUSE it reads the
    // index — that IS its bound. `--no-index`/`--untracked` gives the bound up
    // and re-walks ignore-blind (`.gitignore` is not consulted), which is the
    // same class as `rg --no-ignore`. `--exclude-standard` restores the excludes,
    // so it is accepted. Only the `grep` subcommand is inspected; every other
    // `git` invocation is untouched. This branch sits BEFORE the WATCHED gate:
    // `git` is not a walker binary, so after it the branch was dead code and
    // `git grep --no-index` strolled past (caught by the cycle-2 probe).
    if (binary === "git") {
      if (seg[head + 1]?.value === "grep") {
        const gwords = seg.slice(head + 2).map((t) => t.value);
        const defeat = gwords.find((w) => w === "--no-index" || w === "--untracked");
        if (defeat && !gwords.includes("--exclude-standard")) {
          return { block: true, reason: ignoreDefeatReason("git grep", defeat) };
        }
      }
      continue;
    }
    if (!WATCHED.has(binary)) continue;

    const args = seg.slice(head + 1);
    if (binary === "grep") {
      const scan = scanArgs(args, GREP_SHORT_VALUE, GREP_LONG_VALUE, true);
      if (!isRecursiveGrep(scan.flags)) continue; // non-recursive grep never walks
      // `cd $X && grep -rn p [root]`: bash cds somewhere we cannot read, so every
      // cwd-DEPENDENT operand is unattestable — the implicit `.` root is the
      // operand list being empty, a relative operand is the same failure one step
      // later. Absolute operands are attestable and proceed.
      const operands = scan.operands.length ? scan.operands : ["."];
      if (cwdUnattributable && operands.some(isCwdDependentOperand)) {
        return { block: true, reason: unattributableReason() };
      }
      // R1 first — it is never softened by R5's exclusion carve-out.
      const roots = operands.map((op) => resolveOperand(op, cwd));
      for (const r of roots) {
        if (r.kind === "unresolvable") return { block: true, reason: unresolvableReason(scan.operands, "R2") };
        if (r.kind === "glob") {
          if (r.prefix === null || isSystemOrHomeRoot(r.prefix) || carriesVendoredTrees(r.prefix, warn)) {
            return { block: true, reason: blockReason(r.prefix ?? r.raw, "R2", "grep") };
          }
          continue;
        }
        if (!r.file && isSystemOrHomeRoot(r.path)) {
          return { block: true, reason: blockReason(r.path, "R1", "grep") };
        }
      }
      if (scan.excludeDirs.includes(".worktrees") && scan.excludeDirs.includes("node_modules")) {
        continue; // R5 carve-out (checked after R1, so R1 can never be softened)
      }
      for (const r of roots) {
        if (r.kind === "path" && !r.file && carriesVendoredTrees(r.path, warn)) {
          return { block: true, reason: blockReason(r.path, "R2", "grep") };
        }
      }
      continue;
    }

    if (binary === "find") {
      const start = findStartPoints(args);
      const { bounded } = findBound(args);
      // R3 classifies EVERY start point. `find a b -name x` searches BOTH a and
      // b; resolving only start[0] made the verdict depend on argument order
      // (`find src/ <hub> -name x` BLOCKed while `find <hub> src/ -name x`
      // ALLOWed). The implicit root is `.` when no start point is given.
      const starts = start.length ? start : ["."];
      if (cwdUnattributable && starts.some(isCwdDependentOperand)) {
        return { block: true, reason: unattributableReason() };
      }
      for (const s of starts) {
        const root = resolveOperand(s, cwd);
        if (root.kind === "unresolvable") {
          if (bounded) continue; // R3p exempts operand resolution when the shape is bounded
          return { block: true, reason: unresolvableReason(start, "R3") };
        }
        if (root.kind === "glob") {
          if (root.prefix === null || isSystemOrHomeRoot(root.prefix) || carriesVendoredTrees(root.prefix, warn)) {
            return { block: true, reason: blockReason(root.prefix ?? s, "R3", "find") };
          }
          continue;
        }
        if (!root.file && isSystemOrHomeRoot(root.path)) {
          return { block: true, reason: blockReason(root.path, "R1", "find") };
        }
        if (bounded) continue; // R3p: `-maxdepth` / a directory-blocking `-prune`
        if (!root.file && carriesVendoredTrees(root.path, warn)) {
          return { block: true, reason: blockReason(root.path, "R3", "find") };
        }
      }
      continue;
    }

    const defeat = ignoreDefeat(args, 0, binary);
    if (defeat) {
      return { block: true, reason: ignoreDefeatReason(binary, defeat) };
    }
  }

  return null;
}

function unattributableReason(): string {
  return [
    "🛑 search-guard (cwd): a `cd` ran whose target cannot be resolved statically, so the",
    "   search root is unknown. An unattestable root is treated as unsafe (fail closed) —",
    "   the same command would otherwise walk wherever the unexpanded value happens to point.",
    "   Name the root explicitly, or use an index-bounded primitive:",
    "     rg -n 'PATTERN' -g '*.py' / git grep -n -e 'PATTERN' -- '*.py'",
    `   Escape hatch (rare): ${KILL_SWITCH}=1`,
  ].join("\n");
}

/** GNU `find` start points: an option prefix (`-L`/`-H`/`-P`, `-O…`, `-D …`)
 *  precedes them; the first expression token (a `-xxx`, `!`, `(`, `)`) ends them. */
/**
 * R2/R3: does this operand's meaning depend on the (possibly unattributable)
 * cwd? `cd $X && grep -rn p src/` resolves `src/` against a directory bash will
 * never enter, so the operand cannot be attested — the R2/R3 predicate would be
 * evaluated against the wrong root and ALLOW a walk the command never performs.
 * Absolute paths (and `~…`, expanded before resolution) carry their own root.
 */
function isCwdDependentOperand(op: string): boolean {
  return !isAbsolute(op) && !op.startsWith("~");
}

function findStartPoints(args: Token[]): string[] {
  let i = 0;
  while (i < args.length) {
    const v = args[i].value;
    if (/^-[LHP]$/.test(v)) {
      i++;
      continue;
    }
    if (/^-O\d?$/.test(v)) {
      i++;
      continue;
    }
    if (v === "-D") {
      i += 2;
      continue;
    }
    break;
  }
  const out: string[] = [];
  for (; i < args.length; i++) {
    const v = args[i].value;
    if (v.startsWith("-") || v === "!" || v === "(" || v === ")") break;
    out.push(v);
  }
  return out;
}

function unresolvableReason(operands: string[], rule: string): string {
  const shown = operands.length ? operands.join(" ") : "(implicit root)";
  return [
    `🛑 search-guard (${rule}): the search root cannot be resolved statically — ${shown}`,
    "   A root that cannot be attested is treated as unsafe (fail closed), because the same",
    "   command would otherwise walk whatever the unexpanded value happens to be.",
    "   Say where you mean: an explicit path, or an index-bounded primitive:",
    "     rg -n 'PATTERN' -g '*.py' / git grep -n -e 'PATTERN' -- '*.py'",
    `   Escape hatch (rare): ${KILL_SWITCH}=1`,
  ].join("\n");
}

function ignoreDefeatReason(binary: string, flag: string): string {
  return [
    `🛑 search-guard (R4): \`${binary} ${flag}\` defeats the ignore rules the search depends on.`,
    "   Ignore-defeat modes re-expose .worktrees/*/node_modules to the walk (#1069).",
    "   Search the index instead:  git grep -n -e 'PATTERN' -- '*.py'",
    "   Find untracked files with: git ls-files --others --exclude-standard",
    `   Escape hatch (rare): ${KILL_SWITCH}=1`,
  ].join("\n");
}

// ── registration ───────────────────────────────────────────────────────────

export default function searchGuard(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("bash", event)) return undefined;
    const command = (event.input as { command?: string }).command ?? "";
    return classifySearchCommand(command, process.cwd()) ?? undefined;
  });
}
