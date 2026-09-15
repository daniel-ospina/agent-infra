/**
 * git-command-parse.ts — THE single copy of the git/gh command-parsing helpers
 * shared by `verification-gate` and `review-enforcer` (#966).
 *
 * ── WHY THIS MODULE EXISTS ───────────────────────────────────────────────
 * Both extensions used to carry private copies of `extractCdPath`,
 * `extractRepoFlag`, `extractGhRepoEnv` and `extractPrNumber`. The copies
 * existed to avoid coupling the two extensions' independent load graphs
 * (pi compiles each extension as its own module, #5611) under a stated
 * rule-of-two: "promote to extensions/shared/ when a third consumer appears".
 * The rule was misread — verification-gate and review-enforcer were already two
 * consumers of ONE behaviour, so every parser fix had to be applied twice and
 * silently rotted when it wasn't. It rotted: by 2026-09 the copies disagreed on
 * SEVEN input classes, their test suites asserted OPPOSITE answers for
 * `cd /a && cd /b && <op>`, and verification-gate's stale copy carried the
 * fail-open root mis-resolution of #960. This module is the promotion; the
 * per-extension definitions are DELETED, not re-declared (see the drift-pin in
 * each extension's suite).
 *
 * ── FIRST-vs-LAST `cd`: LAST WINS (evidence, not preference) ─────────────
 * `cd` is sequential and mutating: `cd /a && cd /b && <op>` runs `<op>` in /b.
 * BOTH call sites resolve this path as *the cwd the op actually runs in* —
 * verification-gate feeds it to `resolveGitRoot(cdPath ?? inputCwd)` as the
 * tree whose files are hashed/registered, and review-enforcer passes it as the
 * `cwd` of its own `gh` subprocesses (`runGh(..., { cwd })`). Neither wants
 * "the first directory the chain ever entered"; both want the effective cwd.
 * review-enforcer had last-wins from its first commit (#139, 2026-08-10, "takes
 * the LAST cd in a chain … that is the effective cwd"); verification-gate's
 * copy inherited first-wins from a non-global `.match` in #204 (2026-08-12,
 * no rationale in the commit body). The first-wins pin was wrong and is
 * deleted — see the truth table in git-command-parse.test.ts.
 *
 * ── PER-HELPER PROVENANCE (which copy won, and why) ──────────────────────
 *  • extractCdPath / parseCdChains / expandCdTarget — review-enforcer's (#426):
 *    quote-aware segment scan, newline terminators (the #960 gap),
 *    `~` expansion, and a distinct `unattributable` state for `$VAR`/`$(…)`/
 *    subshell cds instead of fabricating a path. On promotion, THREE further
 *    #960 fixes were folded in: bash line continuations (`\` + newline) are
 *    stripped before the segment scan (`cd /wt \` ⏎ `&& op` → /wt, not the
 *    fabricated `/wt \`); `cd -- <path>` resolves its operand; and a target
 *    the parser cannot model (`&`, `-`, `(`/`)`, `<`/`>`, a backslash escape)
 *    is reported unattributable rather than fabricated — the last closes a
 *    fail-open for `cd X & op`, where bash runs the op in the ORIGINAL cwd.
 *  • The same no-fabrication rule covers `cd`'s own option words (`cd -P /a`),
 *    a residual leading `-` (`cd -`, `cd --help`), an inline `#` comment, and a
 *    `cd` inside a pipeline element (`cd /a | cat && op` — the piped cd runs in
 *    a subshell, so the op sees the ORIGINAL cwd).
 *  • extractRepoFlag / extractGhRepoEnv — verification-gate's (#230):
 *    `normalizeRepoCapture` strips a `[HOST/]OWNER/REPO` prefix (gh accepts
 *    `GH_REPO=github.com/owner/repo`) and fails closed on a 4+-segment garbage
 *    identity. review-enforcer's copy returned `github.com/owner` for that
 *    input and `a/b` for `GH_REPO=a/b/c/d` — both wrong identities. Adopting it
 *    verbatim was NOT a pure win: it required a separator after the short flag,
 *    so review-enforcer's supported ATTACHED spelling (`-Rowner/repo`, #931,
 *    pinned by #993 P2) was silently dropped and `resolveRepoContext` fell back
 *    to the session-cwd repo while gh merged the `-R` target (#426 class). The
 *    attached form is restored here in both the helper and GH_PR_MERGE_VERB.
 *  • extractPrNumber — review-enforcer's STRICT masked read (#1007/#1021),
 *    adopted over verification-gate's flags-tolerant token scan on evidence:
 *    a token scan takes the first pure-integer token after the verb, so
 *    `gh pr merge --body 999 42` read the BODY VALUE 999 while gh merges 42 —
 *    a wrong-PR evidence read (a foreign PR's certificate certifies a merge it
 *    was never computed for), the same fail-open class #1021 fixed inside
 *    review-enforcer. Requiring the digits IMMEDIATELY after the unquoted verb
 *    cannot read a flag value; the flags-before-positional spellings then
 *    decline (null) and both callers fail CLOSED — review-enforcer falls back
 *    to its positional selector (`extractMergeSelector` / `extractMergePrNumber`),
 *    which accepts them because it knows which flags take a value, and
 *    verification-gate resolves no PR head, which its decision table maps to
 *    `verify: true` (`same_repo_head_unknown`), never to a skip.
 *  • unquotedMask — review-enforcer's quote model, promoted here for the same
 *    reason (its `matchUnquoted` / `countUnquotedMergeVerbs` and this module's
 *    masked PR scan must not become two disagreeing text models).
 *
 * Pure Node stdlib only — no pi import, so this module stays loadable from a
 * zero-dependency suite (CI runs `extensions/shared/*.test.ts` BEFORE the
 * extensions' `npm ci`).
 */

import * as os from "node:os";
import * as fs from "node:fs";
import { resolve as resolvePath } from "node:path";

// ── gh merge verb grammar ────────────────────────────────────────────────

/**
 * gh's merge verb, with the optional global `-R`/`--repo` flag between `gh`
 * and `pr` — `gh -R owner/name pr merge 123` is a valid spelling and must be
 * recognised like the post-verb flag form (#204 review P2-1). Consumed here by
 * `extractPrNumber`, and by verification-gate's `mergeCommandWindow`.
 *
 * The left boundary admits a shell opener (`(`, backtick) as well as whitespace
 * and start-of-string: `(cd X && gh pr merge 7)` and `$(gh pr merge 7)` are
 * real merge invocations, and a miss there falls back to review-enforcer's
 * positional selector rather than skipping the gate, but a WRONG number is
 * worse than a miss (the `--body 999 42` class), so the matcher errs WIDE. It
 * deliberately does NOT admit a QUOTE, so a `gh pr merge
 * N` inside quoted prose stays unmatched for the shapes the suite pins.
 * (The general quoted-prose false positive remains #960's separate issue.)
 */
export const GH_PR_MERGE_VERB =
  /(?:^|[\s(`])gh(?:\s+(?:--repo(?:=|\s+)|-R(?:=|\s*))[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+merge(?=\s|$)/;

// ── repo identity (--repo / GH_REPO=) ────────────────────────────────────

/** Normalize a raw repo capture to exactly OWNER/REPO: strip a leading
 * [HOST/] segment (gh accepts GH_REPO=[HOST/]OWNER/REPO; --repo is
 * OWNER/REPO only). A value with >2 segments after host-stripping, or an
 * empty/garbage identity, yields null — fail-closed (review #230 P2-2: the
 * unanchored capture turned "github.com/owner/repo" into the garbage
 * identity "github.com/owner" and flipped same-repo merges into wrong
 * cross-repo skips). */
function normalizeRepoCapture(raw: string): string | null {
  const parts = raw.split("/").filter(Boolean);
  if (parts.length === 2) return parts.join("/");
  if (parts.length === 3) return `${parts[1]}/${parts[2]}`; // host/owner/repo
  return null; // 4+ segments — garbage identity, fail-closed
}

/**
 * Priority 1: explicit `--repo owner/name` / `--repo=owner/name` / `-R` flag.
 *
 * The whole flag must be a TOKEN (`(?:^|\s)` — `--body=see--repo x/y` cannot
 * masquerade as one), and the short form's value may be ATTACHED: gh's pflag
 * parsing accepts `-Rowner/repo`, review-enforcer's deleted copy supported it
 * explicitly (#931, pinned by #993 P2 as an accepted spelling that otherwise
 * "skipped both gates"), and `scripts/gh-shim/gh` parses it. Adopting
 * verification-gate's separator-required copy silently dropped it, which sent
 * review-enforcer's `resolveRepoContext` to the session-cwd repo while gh merged
 * the `-R` target — the #426 wrong-repo evidence read. Do not tighten this back.
 */
export function extractRepoFlag(command: string): string | null {
  // 2-3 segments: a HOST/ prefix must reach normalizeRepoCapture (a two-segment
  // capture would turn "github.com/owner/repo" into "github.com/owner").
  const m = command.match(/(?:^|\s)(?:--repo(?:=|\s+)|-R(?:=|\s*))([A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+){1,3})/);
  return m ? normalizeRepoCapture(m[1]) : null;
}

/** Priority 2: GH_REPO=owner/name env assignment prefix in the command. */
export function extractGhRepoEnv(command: string): string | null {
  const m = command.match(/(?:^|\s)GH_REPO=([A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+){1,3})/);
  return m ? normalizeRepoCapture(m[1]) : null;
}

// ── quote model ──────────────────────────────────────────────────────────

/**
 * Which characters of `command` sit OUTSIDE a quoted region?
 *
 * Needed because a quote-split COMMAND NAME (`g"h" pr merge …`, `''gh pr merge …`,
 * `\gh pr merge …`) is bash-re-joined to `gh` while the raw text contains no
 * contiguous `gh`, and a quoted MENTION (`echo "gh pr merge 1 --admin=true"`) is
 * the opposite: it DOES contain `gh`, but inside the quotes, so it is not a
 * command at all. The two are indistinguishable from the normalized text — both
 * normalize to `gh pr merge` — so the distinction has to come from quote state.
 *
 * Tracks `'…'` and `"…"` (with `\` escapes outside single quotes). Promoted
 * from review-enforcer on unification (#966) so its `matchUnquoted` /
 * `countUnquotedMergeVerbs` and this module's `maskQuoted` share ONE model.
 */
export function unquotedMask(command: string): boolean[] {
  const mask = new Array<boolean>(command.length).fill(true);
  let quote: string | null = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote === null) {
      if (ch === "\\") {
        if (i + 1 < command.length) i++;
        continue;
      }
      if (ch === "'" || ch === '"') {
        quote = ch;
        mask[i] = false;
        continue;
      }
      mask[i] = true;
    } else {
      mask[i] = false;
      if (ch === quote) quote = null;
      else if (quote === '"' && ch === "\\" && i + 1 < command.length) mask[++i] = false;
    }
  }
  return mask;
}

/**
 * The command with every quoted region replaced by SPACES — same length, same
 * offsets, so a match index still addresses the original text. A text regex run
 * on this cannot see a QUOTED mention as one of the command's own tokens.
 * Reuses `unquotedMask`, the module's single quote model, so the two cannot drift.
 */
function maskQuoted(command: string): string {
  const mask = unquotedMask(command);
  let out = "";
  for (let i = 0; i < command.length; i++) out += mask[i] ? command[i] : " ";
  return out;
}

// ── PR number ────────────────────────────────────────────────────────────

/**
 * Extract the PR number from a `gh pr merge <n>` invocation — the digits
 * written IMMEDIATELY after the unquoted merge verb (`gh pr merge 138`,
 * `gh pr merge 138 --squash`, `(cd X && gh pr merge 7)`).
 *
 * STRICT BY EVIDENCE, not by preference. The token scan this replaced took the
 * first pure-integer token after the verb, so a flag VALUE could stand in for
 * the positional: `gh pr merge --body 999 42` resolved to 999 while gh merges
 * 42, and the merge-registry path consults this function FIRST
 * (`extractPrNumber(command) ?? extractMergePrNumber`) — so the gate read a
 * DIFFERENT PR's review evidence (the wrong-PR class #1007/#1021 fixed inside
 * review-enforcer, where a quoted mention shadowed the real positional).
 * Reading the digits AT the verb cannot see a flag value at all.
 *
 * The cost is the flags-before-number spelling, which this function DECLINES
 * (null — it is not silently resolved to some other number):
 *   `gh pr merge --squash 123` → null
 * Both callers fail CLOSED on null, not open: review-enforcer falls back to its
 * positional selector (`extractMergeSelector`/`extractMergePrNumber`, which
 * carries the value-taking-flag table), and verification-gate resolves no PR
 * head, which `evaluateMergeScope` maps to `verify: true`
 * (`same_repo_head_unknown`) — a skip (`head_mismatch`) is only ever taken on a
 * head it actually resolved. The old verification-gate token scan was adopted on
 * the compatibility claim alone; no test pinned it against a numeric flag value.
 *
 * Masking (not a raw regex) is load-bearing on both sides: a QUOTED verb or a
 * quoted mention is not this command's merge (`git log -S "gh pr merge 42"`,
 * `x="say gh pr merge 1"; gh pr merge <url> --admin` → null), and a token
 * ADJACENT to a quoted region is quote-SPLICED — bash concatenates `"1"38` into
 * `138`, so the digits the mask leaves visible are a FRAGMENT of the real
 * argument. Refused rather than guessed, in either splice direction.
 *
 * STATED LIMIT (pre-existing, filed with the dequote follow-up #1021): the
 * adjacency guard covers `'` and `"` only. The ANSI-C family splices with a `$`
 * in front (`1$'38'` is `138` to bash) and a digit-adjacent `$` is not caught
 * here, so `1$'38'` still reads `1` — NO WORSE than before masking (the raw
 * regex read `1` too), and the dequote-aware positional in #1021 is what closes
 * it.
 *
 * `GH_PR_MERGE_VERB`'s banner keeps gh's real spellings working: a global
 * `-R`/`--repo` between `gh` and `pr` (`gh -R owner/name pr merge 123`), a
 * shell opener (`(cd X && gh pr merge 7)`, `$(gh pr merge 8)`), and a trailing
 * bracket/brace glued to the number (`gh pr merge 9}`) all still resolve.
 */
export function extractPrNumber(command: string): number | null {
  const masked = maskQuoted(command);
  const m = masked.match(GH_PR_MERGE_VERB);
  if (m === null) return null;
  // The digits must follow the verb with only whitespace between — and in the
  // MASKED text a blanked quoted region is whitespace, which is exactly how a
  // quote-splice (`"1"38`) gets far enough to be caught by the guard below.
  const rest = masked.slice((m.index ?? 0) + m[0].length);
  const gap = rest.match(/^(\s+)(\d+)/);
  if (gap === null) return null;
  const dStart = (m.index ?? 0) + m[0].length + gap[1].length;
  const before = command[dStart - 1];
  const after = command[dStart + gap[2].length];
  if (before === '"' || before === "'" || after === '"' || after === "'") return null;
  return parseInt(gap[2], 10);
}

// ── cd chain → effective cwd ─────────────────────────────────────────────

/** bash's `cd` is LOGICAL by default: it keeps `$PWD` as the path you typed,
 * so `cd ..` climbs the SYMLINK prefix (`cd ../..` from /tmp/x is `/`), while
 * Node's `process.cwd()` is the PHYSICAL path (on macOS `/tmp` → `/private/tmp`).
 * Resolving relative cd operands against the physical cwd returns a different
 * (still-existing) directory than bash enters. Use `$PWD` when it names the
 * same directory as the physical cwd (dev+ino), else fall back to it. */
function logicalCwd(): string {
  const pwd = process.env.PWD;
  if (pwd && pwd.startsWith("/")) {
    try {
      const a = fs.statSync(pwd);
      const b = fs.statSync(process.cwd());
      if (a.dev === b.dev && a.ino === b.ino) return pwd;
    } catch {
      // $PWD vanished or is unreadable — the physical cwd is the only truth.
    }
  }
  return process.cwd();
}

/** Expand a cd target the way bash would when statically resolvable.
 * `~`/`~/…` → home; a path still containing $/backtick is unresolvable
 * statically → null (bash WOULD expand it, so callers treat the cwd as
 * unattributable rather than guessing). `base` is the cwd the operand resolves
 * against — the INVOCATION cwd for a leading cd, the previous cd's directory
 * for the next one, so a relative operand composes with the chain. */
export function expandCdTarget(path: string, base: string = logicalCwd()): string | null {
  // The `$`/backtick guard MUST precede the `~/` expansion. `cd ~/$X` used to
  // return the literal `<home>/$X` with `unattributable: false` — a fabricated
  // root carrying an unexpanded variable, i.e. a path no op ever ran in,
  // hashed and registered as verified (bash expands the variable and cds
  // somewhere else entirely). Same class as the #960 garbage-path forms.
  if (/[$`]/.test(path)) return null;
  if (path === "~") return os.homedir();
  if (path.startsWith("~/")) return resolvePath(os.homedir(), path.slice(2));
  return resolvePath(base, path);
}

export interface CdChainInfo {
  last: string | null; // resolved path of the last parseable `cd <path>`
  unattributable: boolean; // a cd bash WILL run but we can't resolve its target
}

/**
 * A `cd` target is statically resolvable only when it is a plain path. A target
 * still carrying a shell metacharacter we cannot model — `&` (backgrounds the
 * cd into a subshell, so the op runs in the ORIGINAL cwd), `(`/`)` (subshell),
 * `<`/`>` (redirect), a backtick, or a backslash escape we cannot faithfully
 * unquote — is reported as "a cd ran but I cannot resolve it" (`null` +
 * `unattributable`) rather than FABRICATED into a path rooted at the session
 * cwd. `-` (bash goes to `$OLDPWD`) is the same. This is the #960 garbage-path
 * class: a fabricated root is the WRONG tree to hash/register, and for
 * `cd X & op` the fabricated target is actively fail-open (the op really runs
 * in the original cwd). Conservative by design: a rejected form is extra work
 * for a caller that honours `unattributable`, never a wrong root attested as
 * verified.
 */
function isStaticallyResolvableCd(target: string): boolean {
  if (target === "-") return false; // $OLDPWD — bash state, not a path we can read
  if (target.includes("\\")) return false; // an escape we cannot unquote without re-parsing quotes
  if (/[&(){}<>`*?\[\]]/.test(target)) return false; // background/subshell/redirect/glob
  // `~` and `~/…` ARE resolvable (expandCdTarget); `~user` is another user's
  // home directory, which we cannot read statically — never guess it.
  if (target.startsWith("~") && target !== "~" && !target.startsWith("~/")) return false;
  return true;
}

/**
 * Parse the OPERAND of a `cd` segment — everything after the verb. bash's `cd`
 * takes its own option words (`-L`, `-P`, `-e`, `-@`, and the `--`
 * end-of-options marker) followed by exactly ONE operand. This resolves that
 * one operand, and otherwise says "do not guess" — because after the segment
 * text has been split on separators, the quotes are the ONLY thing that tells a
 * single quoted argument (`cd "/a b"`) apart from two arguments (`cd /a b`,
 * which makes bash's `cd` FAIL and leave the cwd unchanged), and interior
 * quoting (`cd /path/"my project"`, `cd "/a""/b"`) is concatenation this
 * parser cannot faithfully unquote. Every `unresolvable` verdict is a
 * conservative class-(ii) result: the caller does extra work, and never
 * attests a fabricated root.
 */
function parseCdOperand(raw: string):
  | { kind: "path"; path: string; quoted: boolean }
  | { kind: "none" }
  | { kind: "unresolvable" } {
  // bash's IFS is space/tab/newline only: another control character (CR from a
  // CRLF-authored command, vertical tab, form feed) stays IN the word, so the
  // cd target is not the directory a `.trim()` would leave behind.
  if (/[\r\v\f]/.test(raw)) return { kind: "unresolvable" };
  let s = raw.replace(/^[ \t]+|[ \t]+$/g, "");
  // (1) cd's own option words may repeat. (2) `--` ends option parsing EXACTLY
  // ONCE — a later `--` is the OPERAND (`cd -- -- /a` makes bash's cd fail on
  // the literal directory `--`), so it must not be stripped again.
  for (;;) {
    const opt = s.match(/^(?:-[LPe@])(?:\s+|$)/);
    if (!opt) break;
    s = s.slice(opt[0].length).trim();
  }
  if (/^--(?:\s+|$)/.test(s)) s = s.slice(2).trim();
  if (s === "") return { kind: "none" }; // `cd`, `cd -P`, `cd --` → HOME
  const q = s[0];
  if (q === "'" || q === '"') {
    if (s.length < 2 || s[s.length - 1] !== q) return { kind: "unresolvable" };
    const inner = s.slice(1, -1);
    if (/['"]/.test(inner)) return { kind: "unresolvable" }; // concatenation / partial quoting
    return { kind: "path", path: inner, quoted: true };
  }
  // Unquoted: exactly one word, carrying no quote anywhere (two operands make
  // `cd` fail; a quoted fragment is concatenation we cannot unquote).
  if (/[\s'"]/.test(s)) return { kind: "unresolvable" };
  return { kind: "path", path: s, quoted: false };
}

/**
 * Remove bash line continuations (`\` + newline) the way the shell does
 * BEFORE tokenization: `cd /wt \` ⏎ `&& git push` runs the push in /wt.
 * Without this the cd target captured the trailing `\` and callers resolved a
 * FABRICATED path (`/wt \`) — one of the garbage-path forms in #960's scope.
 * Quote-and-comment aware: unquoted and double-quoted backslash-newline is a
 * continuation, but bash keeps the backslash LITERAL inside single quotes, and
 * inside an inline `#` comment it is literal comment text too — the comment ends
 * at the newline regardless. Both carve-outs matter:
 *   `cd /a && true # note \` ⏎ `cd /b && op`
 * runs the op in /b (the second cd is real), so joining the comment line onto
 * the next one hid the real cd and reported the WRONG root attributably. A
 * model that tracks only single quotes also desynchronises on an apostrophe
 * inside a double-quoted argument (`-m "don't"`), which is why both quote kinds
 * are tracked here.
 */
function stripLineContinuations(command: string): string {
  let out = "";
  let quote: "'" | '"' | null = null;
  let inComment = false;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (inComment) {
      out += c;
      if (c === "\n") inComment = false; // comment ends at the newline; `\` ⏎ inside it is literal
      continue;
    }
    if (quote === "'") {
      out += c;
      if (c === "'") quote = null;
      continue;
    }
    if (c === "\\") {
      const j = command[i + 1] === "\r" && command[i + 2] === "\n" ? i + 2 : i + 1;
      if (command[j] === "\n") { i = j; continue; } // `\` ⏎ → both removed
      // An escape inside double quotes stays in the text (it may protect a
      // `"` we would otherwise read as the closing quote); outside quotes the
      // next character is examined normally, so `\#` never opens a comment.
      out += c;
      if (quote === '"' && i + 1 < command.length) { out += command[i + 1]; i++; }
      continue;
    }
    if (quote === '"') {
      out += c;
      if (c === '"') quote = null;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; out += c; continue; }
    if (c === "#" && (i === 0 || /[\s;&|(\n]/.test(command[i - 1]))) {
      inComment = true;
      out += c;
      continue;
    }
    out += c;
  }
  return out;
}

export function parseCdChains(command: string): CdChainInfo {
  command = stripLineContinuations(command);
  // Quote-aware scan splitting on &&/;\n OUTSIDE quotes — prose like
  // `--comment "see; cd /tmp && …"` must never parse as a cd chain (#230
  // class). Counts standalone `cd` words outside quotes so unparseable forms
  // (subshell `(cd …`, `cd $VAR`, `cd "$(…)"`) are detected, not silently
  // mis-attributed to the session cwd (cycle 3 P2-1).
  const segments: string[] = [];
  // The separator that TERMINATED each segment (null = end of string). A cd
  // segment adjacent to a single `|` is a PIPELINE element — bash runs it in a
  // subshell, so its cd does not affect any later command (claiming the piped
  // cwd would be a fail-open). `&&`/`||`/`;`/newline are ordinary separators.
  const seps: Array<string | null> = [];
  let cur = "", q: string | null = null, esc = false;
  let cdWords = 0;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (esc) { cur += c; esc = false; continue; }
    if (q) {
      cur += c;
      if (c === "\\") esc = true;
      else if (c === q) q = null;
      continue;
    }
    if (c === '"' || c === "'") { q = c; cur += c; continue; }
    if (c === "#" && (i === 0 || /[\s;&|(\n]/.test(command[i - 1]))) {
      // bash inline comment: the rest of the LINE is not command text, so a
      // `# note` after a path is not part of the target (`cd /a # c` cds /a).
      while (i < command.length && command[i] !== "\n") i++;
      segments.push(cur); cur = "";
      seps.push(i < command.length ? "\n" : null);
      continue;
    }
    if (c === "&" && command[i + 1] === "&") { segments.push(cur); seps.push("&&"); cur = ""; i++; continue; }
    if (c === "&") {
      // A LONE `&` is a command separator too: it BACKGROUNDS the whole
      // preceding AND-OR list, so a cd inside that list never reaches a later
      // command (`cd /a && true & op` runs op in the pre-cd cwd). `&&` is
      // handled above; `&>` / `2>&1` are redirections, not separators.
      if (command[i + 1] !== ">" && command[i - 1] !== ">") {
        segments.push(cur); seps.push("&"); cur = ""; continue;
      }
    }
    if (c === ";" || c === "\n" || c === "|") {
      // `|` (incl. `||`) splits too — the real `cd /x || exit 1` idiom must
      // not capture `|| exit 1` into the cd target (cycle 4 P3).
      let sep: string = c;
      if (c === "|" && command[i + 1] === "|") { sep = "||"; i++; }
      segments.push(cur); seps.push(sep); cur = ""; continue;
    }
    if (c === "c" && command.startsWith("cd", i)) {
      const after = command[i + 2];
      const before = command[i - 1];
      if (
        (after === undefined || /[\s;&|()]/.test(after)) &&
        // A BACKTICK opener counts: the cd in `` `cd /a && op` `` runs in a
        // command SUBSTITUTION (its own subshell), so it is a cd we cannot
        // attribute — without it the segment scan finds no parseable cd and
        // reports "no cd at all", letting the consumers fall back to the
        // session root for an op that really ran in /a.
        (before === undefined || /[\s;&|(\n`]/.test(before))
      ) {
        cdWords++;
      }
    }
    cur += c;
  }
  segments.push(cur); seps.push(null);
  // LAST parseable cd wins: `cd` mutates the shell's cwd, so the final cd
  // before the op decides where the op runs (see the module header).
  const occs: Array<{ idx: number; raw: string | null }> = [];
  for (let i = 0; i < segments.length; i++) {
    // Capture the RAW operand (quotes included) — parseCdOperand needs the
    // quotes to tell one quoted argument from two, and from concatenation.
    // `\r` is deliberately NOT trailing whitespace: it is not an IFS char, so
    // in a CRLF command bash keeps it in the word and the cd fails. The
    // leading/separating whitespace is `[ \t]` (not `\s`) for the same reason —
    // a vertical tab does not separate commands in bash.
    const withArg = segments[i].match(/^[ \t]*cd[ \t]+(.+?)[ \t]*$/);
    if (withArg) { occs.push({ idx: i, raw: withArg[1] }); continue; }
    if (/^[ \t]*cd[ \t]*$/.test(segments[i])) occs.push({ idx: i, raw: null }); // bare cd → HOME
  }
  const parsedCds = occs.filter((o) => o.raw !== null).length;
  const bareCount = occs.length - parsedCds;
  if (occs.length === 0) {
    // Any unparsed cd word (subshell `(cd …`, `$(cd …`, `command cd …`) means a
    // cd bash WILL run that we cannot attribute — say so. #960 defers full
    // nesting awareness to a separate issue.
    return { last: null, unattributable: cdWords > 0 };
  }
  // A cd word the segment scan could NOT attribute makes the effective cwd
  // ambiguous — never return the outer cd's root for an op inside the nesting
  // (`cd /a && (cd /b && git commit)` commits in /b).
  if (cdWords > parsedCds + bareCount) return { last: null, unattributable: true };
  // A cd that is a PIPELINE element runs in a subshell and never changes the
  // PARENT shell's cwd, so drop it from the chain instead of composing a
  // directory no later op entered (`cd /a | cat && cd b && op` runs op in
  // <invocation>/b, not /a/b). Dropping it also means a piped LATER cd leaves
  // the earlier, effective one in charge (`cd /a && cd /b | cat && op` → /a).
  const isPiped = (i: number) => seps[i] === "|" || (i > 0 && seps[i - 1] === "|");
  const cds = occs.filter((o) => !isPiped(o.idx));
  if (cds.length === 0) return { last: null, unattributable: cdWords > 0 };
  // A cd whose immediately-preceding separator is `||` is CONDITIONAL: bash
  // runs it only in the alternate branch, so it is not the cwd of the op we
  // are attributing (`true || cd /a && op` runs op in the invocation cwd).
  // Checked per occurrence, so a `||` BEFORE the first cd is caught too.
  if (cds.some((o) => o.idx > 0 && seps[o.idx - 1] === "||")) {
    return { last: null, unattributable: true };
  }
  // A lone `&` backgrounds everything before it, so a cd above it is void for
  // the op that follows (`cd /a && true & op` runs op in the pre-cd cwd).
  if (seps.slice(cds[0].idx).some((s) => s === "&")) {
    return { last: null, unattributable: true };
  }
  const lastOcc = cds[cds.length - 1];
  // `cd X || <op>`: the op runs only when the cd FAILED — in the pre-cd cwd —
  // so X is never its cwd. X still governs when the alternate ABORTS the shell
  // (`exit`/`return`): then the op can only run at all when the cd succeeded, so
  // `cd X || exit 1 && op` and `cd X || exit 1 ; op` both resolve to X. A
  // non-aborting alternate (`cd X || true && op`) leaves the op in the pre-cd
  // cwd when the cd fails — decline instead of attesting X.
  if (seps[lastOcc.idx] === "||") {
    const alt = (segments[lastOcc.idx + 1] ?? "").trim();
    if (!/^(?:exit|return)\b/.test(alt)) return { last: null, unattributable: true };
  }
  // A `cd` that is the LAST command with something else earlier never sets the
  // cwd of a following op (`git commit && cd /a` → the commit ran in the
  // invocation cwd, NOT /a). Never return a root where no op ran. "Follows"
  // means a non-empty segment: a trailing separator (`;`, `&&`, `;;`, a
  // newline) or a stripped inline comment leaves an EMPTY final segment that
  // must not defeat this guard.
  const beforeNonEmpty = segments.slice(0, lastOcc.idx).some((s) => s.trim() !== "");
  const afterNonEmpty = segments.slice(lastOcc.idx + 1).some((s) => s.trim() !== "");
  if (beforeNonEmpty && !afterNonEmpty) return { last: null, unattributable: true };
  // Compose the chain: each cd resolves against the cwd the PREVIOUS one set
  // (`cd /tmp/wt && cd extensions && <op>` runs in /tmp/wt/extensions —
  // resolving the second operand against the process cwd would fabricate
  // <cwd>/extensions).
  let root = logicalCwd();
  for (const occ of cds) {
    if (occ.raw === null) { root = os.homedir(); continue; } // bare `cd` → HOME
    const operand = parseCdOperand(occ.raw);
    if (operand.kind === "none") { root = os.homedir(); continue; }
    if (operand.kind === "unresolvable") return { last: null, unattributable: true };
    const raw = operand.path;
    // A remaining leading `-` is $OLDPWD (`cd -`) or an unknown option
    // (`cd --help`) — bash state we cannot read, never a path.
    if (raw.startsWith("-")) return { last: null, unattributable: true };
    // bash does NOT tilde-expand a QUOTED `~` (`cd '~/a'` looks for a literal
    // `~/a` directory and normally fails) — never turn it into $HOME.
    if (operand.quoted && raw.startsWith("~")) return { last: null, unattributable: true };
    if (!isStaticallyResolvableCd(raw)) return { last: null, unattributable: true };
    const resolved = expandCdTarget(raw, root);
    if (resolved === null) return { last: null, unattributable: true };
    root = resolved;
  }
  return { last: root, unattributable: false };
}

/**
 * The effective cwd of a command chain: the LAST `cd <path>` in it, expanded
 * the way bash would, or null when there is no statically-resolvable cd.
 *
 * #960: a newline is a command separator in bash, so `cd <wt>\n<op>` MUST
 * resolve to `<wt>`. The old verification-gate regex required a `&&`/`;`
 * terminator, returned null for the newline form, and callers fell back to the
 * session repo root — blocking valid pushes from a linked worktree and, when
 * the session root happened to hash to verified values, silently attesting the
 * WRONG tree (fail-open). `parseCdChains` treats `\n` as a separator, so the
 * form resolves correctly. Callers that need to distinguish "no cd" from
 * "a cd I cannot resolve" must use `parseCdChains().unattributable`.
 */
export function extractCdPath(command: string): string | null {
  return parseCdChains(command).last;
}
