#!/usr/bin/env node
/**
 * workflow-yaml.mjs — dep-free YAML-subset reader for the pin-gate wiring guard
 * (#666). Node stdlib ONLY — no `yaml`/`js-yaml` import, because this repo has no
 * root node_modules and the per-PR job runs the caller's `test-command` with no
 * `npm ci` (the #254 constraint, verified again for #666:
 * `node -e "import('yaml')"` → ERR_MODULE_NOT_FOUND).
 *
 * WHY THIS FILE EXISTS
 * `scripts/check-pi-pin-lockstep.mjs` guard (j) must decide "is the per-PR pin
 * gate still wired?" from parsed STRUCTURE, not from normalized text. Three
 * generations of text matching were defeated by YAML's own syntax (quoted keys,
 * `key :` spacing, block-scalar bodies, decoy comment lines, an injected fake
 * job inside a scalar), and the hand-maintained normalizer those generations
 * needed was itself unreviewed surface. Reading nodes removes that whole class:
 * a decoy line inside a scalar is not a node, so it cannot satisfy an assertion.
 *
 * SUPPORTED SUBSET (deliberate, bounded — this is a workflow reader, not a YAML
 * implementation):
 *   - block mappings (`key: value`, `key:`, quoted keys, `key :` spacing)
 *   - block sequences (`- item`, `- key: value` compact mappings, `-` + nested
 *     block), including a sequence indented at its parent key's column
 *   - flow sequences/mappings at value position (`[a, b]`, `{a: b}`), nested
 *   - single-line plain and single/double-quoted scalars, with the FULL YAML
 *     double-quote escape set decoded (`\0 \a \b \t \n \v \f \r \e \" \/ \\
 *     \N \_ \L \P \xXX \uXXXX \UXXXXXXXX`); any other escape THROWS. Decoding
 *     is load-bearing, not cosmetic — `"paths\u002dignore"` is the key
 *     `paths-ignore` to GitHub, so copying the escaped character through
 *     verbatim (the pre-#675 behaviour) was a silent guard bypass (#675 P1-1)
 *   - block scalars (`key: |`, `key: >`, `+`/`-`/digit chomping indicators) —
 *     the body is read as raw text and NEVER interpreted as structure. The
 *     block indentation is taken from the FIRST non-empty body line (or the
 *     explicit digit indicator, when present); a later non-blank line that
 *     dedents below it THROWS, because YAML itself rejects that (#675 P2-4)
 *   - full-line and trailing `#` comments (quote-aware)
 *   - an optional leading `---` document start
 *
 * FAIL-CLOSED BY DESIGN: anything outside the subset throws WorkflowYamlError
 * instead of being guessed at. That is the honest failure direction — the guard
 * is a tripwire, so a loud red that says "extend the reader deliberately" is
 * correct, while a silently mis-read workflow is exactly the bug class (#637's
 * decoy bypasses) this file exists to kill.
 *
 * COST BOUND: every scan is single-pass over its input (no backtracking regex on
 * unbounded newline runs) — the guard reads PR-controlled files, so a quadratic
 * path is a CI DoS, even though it stays fail-closed (#675 P2-3).
 *
 * KNOWN NON-GOALS (documented, not silently fudged):
 *   - scalar TYPES are not resolved: every scalar is a string, so `on` is always
 *     the key `on` (no YAML-1.1 `on`→boolean trap) and `continue-on-error: false`
 *     is the string "false".
 *   - block-scalar chomping/folding is not modelled: `|` and `>` bodies are the
 *     raw lines joined with "\n", common indentation stripped, leading/trailing
 *     blank lines dropped. Good enough for "does this value equal the expected
 *     single-line command", NOT good enough for general text semantics.
 *   - multi-line plain scalars, anchors/aliases, tags, merge keys, nested inline
 *     sequences (`- - x`), multi-document streams, and block scalars in
 *     non-`key:` positions all throw.
 *
 * Run: nothing to run — library module, exercised by
 * `scripts/check-pi-pin-lockstep.mjs`.
 */

export class WorkflowYamlError extends Error {
  constructor(message, line) {
    super(line ? `${message} (line ${line})` : message);
    this.name = "WorkflowYamlError";
    this.line = line ?? null;
  }
}

// ── lexing helpers ─────────────────────────────────────────────────────────

/**
 * Drop a trailing `# …` comment. YAML starts a comment only at a `#` preceded by
 * whitespace (or at line start) AND outside a quoted scalar — both conditions
 * matter here: `run: echo "#1"` must keep its `#`, and `if: inputs.test-command
 * != ''` must not be truncated.
 */
function stripComment(s) {
  let q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q === '"') {
      if (c === "\\") { i++; continue; }
      if (c === '"') q = null;
    } else if (q === "'") {
      if (c === "'" && s[i + 1] === "'") { i++; continue; }
      if (c === "'") q = null;
    } else if (c === '"' || c === "'") {
      q = c;
    } else if (c === "#" && (i === 0 || /[ \t]/.test(s[i - 1]))) {
      return s.slice(0, i);
    }
  }
  return s;
}

/**
 * Scan a quoted scalar starting at text[start] (the opening quote).
 * → {value, end} on success, null when the quote is not closed on this line.
 */
function scanQuoted(text, start = 0, line) {
  const q = text[start];
  let out = "";
  for (let i = start + 1; i < text.length; i++) {
    const c = text[i];
    if (q === '"' && c === "\\") {
      const esc = decodeEscape(text, i, line);
      out += esc.value;
      i = esc.next - 1;
      continue;
    }
    if (q === "'" && c === "'" && text[i + 1] === "'") { out += "'"; i++; continue; }
    if (c === q) return { value: out, end: i + 1 };
    out += c;
  }
  return null;
}

// The YAML double-quote escape set (YAML 1.2 §5.7, ns-esc-char). The guard reads
// KEYS out of quoted scalars, so decoding these faithfully is a correctness
// requirement, not a nicety: `"paths\u002dignore"` IS the key `paths-ignore` to
// GitHub. An escape outside the set is REJECTED, never passed through and never
// guessed at — same fail-closed direction as the rest of the reader.
const SIMPLE_ESCAPES = new Map([
  ["0", "\0"], ["a", "\x07"], ["b", "\b"], ["t", "\t"], ["\t", "\t"], ["n", "\n"],
  ["v", "\v"], ["f", "\f"], ["r", "\r"], ["e", "\x1b"], [" ", " "], ['"', '"'],
  ["/", "/"], ["\\", "\\"], ["N", "\u0085"], ["_", "\u00a0"], ["L", "\u2028"], ["P", "\u2029"],
]);

/**
 * Decode the escape that starts at `text[i]` (which must be `\`).
 * → { value, next } where `next` is the index just past the escape sequence.
 *
 * @throws {WorkflowYamlError} on a truncated, malformed or unmodelled escape.
 */
function decodeEscape(text, i, line) {
  const c = text[i + 1];
  if (c === undefined) {
    throw new WorkflowYamlError("a double-quoted scalar ends with a dangling `\\`", line);
  }
  if (SIMPLE_ESCAPES.has(c)) return { value: SIMPLE_ESCAPES.get(c), next: i + 2 };
  if (c === "x" || c === "u" || c === "U") {
    const width = c === "x" ? 2 : c === "u" ? 4 : 8;
    const hex = text.slice(i + 2, i + 2 + width);
    if (hex.length !== width || !/^[0-9A-Fa-f]+$/.test(hex)) {
      throw new WorkflowYamlError(`malformed \\${c} escape in a double-quoted scalar`, line);
    }
    const cp = parseInt(hex, 16);
    if (cp > 0x10ffff) throw new WorkflowYamlError(`\\${c} escape is above the Unicode range`, line);
    return { value: String.fromCodePoint(cp), next: i + 2 + width };
  }
  throw new WorkflowYamlError(
    `unsupported escape \\${c} in a double-quoted scalar — this reader models the YAML ` +
      "double-quote escape set (\\0 \\a \\b \\t \\n \\v \\f \\r \\e \\\" \\/ \\\\ \\N \\_ \\L \\P \\xXX \\uXXXX \\UXXXXXXXX)",
    line
  );
}

// Plain keys this reader accepts. Deliberately excludes quotes and flow/comment
// indicators, so a scalar that merely CONTAINS `: ` (e.g. `echo "a: b"`) is never
// mistaken for a mapping entry.
const PLAIN_KEY_RE = /^[A-Za-z0-9_][A-Za-z0-9_.\/-]*$/;

/**
 * Parse `key: rest` (or `key :   rest`). → {name, rest} | null.
 * Quoted keys are dequoted, so `"paths-ignore":` and `paths-ignore:` are the
 * same key — the generation-2 bypass that quoted keys defeated.
 */
function parseKey(text, line) {
  const first = text[0];
  if (first === '"' || first === "'") {
    const scanned = scanQuoted(text, 0, line);
    if (!scanned) return null;
    const tail = text.slice(scanned.end);
    const m = /^[ \t]*:/.exec(tail);
    if (!m) return null;
    return { name: scanned.value, rest: tail.slice(m[0].length) };
  }
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== ":") continue;
    const next = text[i + 1];
    if (next !== undefined && next !== " " && next !== "\t") continue;
    const name = text.slice(0, i).trimEnd();
    if (!PLAIN_KEY_RE.test(name)) return null;
    return { name, rest: text.slice(i + 1) };
  }
  return null;
}

// ── flow collections ───────────────────────────────────────────────────────

/** Index of the character closing the flow collection opened at text[0], or -1. */
function flowEnd(text) {
  const open = text[0];
  const close = open === "[" ? "]" : "}";
  let depth = 0;
  let q = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (q === '"' && c === "\\") { i++; continue; }
      if (q === "'" && c === "'" && text[i + 1] === "'") { i++; continue; }
      if (c === q) q = null;
      continue;
    }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === "[" || c === "{") { depth++; continue; }
    if (c === "]" || c === "}") {
      depth--;
      if (depth === 0) return c === close ? i : -1;
    }
  }
  return -1;
}

/** Split flow-collection inner text on top-level commas (quote/nesting aware). */
function splitFlowItems(inner, line) {
  const items = [];
  let depth = 0;
  let buf = "";
  let q = null;
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (q) {
      if (q === '"' && c === "\\") {
        // Validate (and skip) the escape without decoding it: the raw text is
        // kept so `scanQuoted` decodes it exactly once. An escape this reader
        // does not model is rejected here too — it must not be able to smuggle
        // a `,`/quote past the splitter (#675 P1-1).
        const esc = decodeEscape(inner, i, line);
        buf += inner.slice(i, esc.next);
        i = esc.next - 1;
        continue;
      }
      buf += c;
      if (q === "'" && c === "'" && inner[i + 1] === "'") { buf += "'"; i++; continue; }
      if (c === q) q = null;
      continue;
    }
    if (c === '"' || c === "'") { q = c; buf += c; continue; }
    if (c === "[" || c === "{") { depth++; buf += c; continue; }
    if (c === "]" || c === "}") { depth--; buf += c; continue; }
    if (c === "," && depth === 0) { items.push(buf); buf = ""; continue; }
    buf += c;
  }
  items.push(buf);
  return items;
}

/** One flow entry: nested collection | quoted scalar | plain scalar. */
function parseFlowEntry(text, line) {
  const t = text.trim();
  if (t === "") return null;
  if (t[0] === '"' || t[0] === "'") {
    const s = scanQuoted(t, 0, line);
    if (!s || t.slice(s.end).trim() !== "") {
      throw new WorkflowYamlError("flow entry is not a single-line quoted scalar", line);
    }
    return s.value;
  }
  if (t[0] === "[" || t[0] === "{") return parseFlow(t, line).value;
  return parseScalarText(t, line);
}

/** Parse the flow collection that starts at text[0]. → {value, end}. */
function parseFlow(text, line) {
  const end = flowEnd(text);
  if (end === -1) throw new WorkflowYamlError("unbalanced flow collection", line);
  const open = text[0];
  const inner = text.slice(1, end);
  const rawItems = splitFlowItems(inner, line).map((s) => s.trim()).filter((s) => s !== "");
  if (open === "[") {
    return { value: rawItems.map((s) => parseFlowEntry(s, line)), end: end + 1 };
  }
  const entries = [];
  for (const item of rawItems) {
    const key = parseKey(item, line);
    if (!key) throw new WorkflowYamlError(`flow mapping entry is not a \`key: value\` pair: ${JSON.stringify(item)}`, line);
    entries.push([key.name, key.rest.trim() === "" ? null : parseFlowEntry(key.rest, line)]);
  }
  return { value: Object.fromEntries(entries), end: end + 1 };
}

/** A scalar already isolated from its key (flow entry, sequence item, value). */
function parseScalarText(text, line) {
  const t = text.trim();
  if (t === "") return null;
  if (t[0] === '"' || t[0] === "'") {
    const s = scanQuoted(t, 0, line);
    if (!s) throw new WorkflowYamlError("unterminated quoted scalar (multi-line quoted scalars are outside the supported subset)", line);
    if (t.slice(s.end).trim() !== "") throw new WorkflowYamlError("unexpected content after a quoted scalar", line);
    return s.value;
  }
  if (t[0] === "[" || t[0] === "{") {
    const f = parseFlow(t, line);
    if (t.slice(f.end).trim() !== "") throw new WorkflowYamlError("unexpected content after a flow collection", line);
    return f.value;
  }
  if (/^[|>]/.test(t)) {
    throw new WorkflowYamlError("block scalar in a position the reader does not model (only `key: <header>` is supported)", line);
  }
  if (t[0] === "&" || t[0] === "*") throw new WorkflowYamlError("anchors and aliases are outside the supported subset", line);
  if (t[0] === "!") throw new WorkflowYamlError("tags are outside the supported subset", line);
  if (t[0] === "@" || t[0] === "`") throw new WorkflowYamlError(`reserved indicator ${JSON.stringify(t[0])} at the start of a scalar`, line);
  return t;
}

// ── tokenizer ──────────────────────────────────────────────────────────────

function splitLines(src) {
  return src.replace(/\r\n?/g, "\n").split("\n").map((raw, idx) => {
    const lead = /^[ \t]*/.exec(raw)[0];
    return {
      no: idx + 1,
      indent: lead.length,
      hasTab: lead.includes("\t"),
      content: raw.slice(lead.length),
    };
  });
}

/**
 * Consume a block scalar body: every following line until a non-blank line dedents
 * to (or past) the parent key's column. Body lines are NEVER tokenized — that is
 * what makes a decoy `test-command:`/`jobs:` inside a scalar inert.
 */
function consumeBlockBody(lines, start, parentIndent, explicitIndent = null) {
  let j = start;
  let lastContent = start - 1;
  // YAML takes the block's indentation from the FIRST non-empty line (or an
  // explicit digit indicator). Stripping the MINIMUM indent instead (#675 P2-4)
  // silently accepted a later line dedented below the first — valid YAML rejects
  // that, so a document this reader cannot model must throw, not be guessed at.
  let indent = explicitIndent;
  while (j < lines.length) {
    const l = lines[j];
    if (l.content.trim() === "") { j++; continue; }
    if (l.indent <= parentIndent) break;
    if (indent === null) {
      indent = l.indent;
    } else if (l.indent < indent) {
      throw new WorkflowYamlError(
        "a block-scalar body line is indented less than the block's first content line — YAML " +
          "derives the block indentation from that first non-empty line, so this document is not " +
          "valid YAML (extend this reader deliberately if an exotic indentation form is needed)",
        l.no
      );
    }
    lastContent = j;
    j++;
  }
  const base = indent ?? 0;
  const joined = lines
    .slice(start, lastContent + 1)
    .map((l) => (l.content.trim() === "" ? "" : " ".repeat(Math.max(0, l.indent - base)) + l.content.trimEnd()))
    .join("\n");
  // Linear trims. This was a quadratic regex on a body with a long interior
  // blank-line run — a crafted ~120 KB workflow file burned minutes of CI in the pre-fix reader
  // (measured 212 s; #675 P2-3).
  let from = 0;
  while (from < joined.length && joined[from] === "\n") from++;
  let to = joined.length;
  while (to > from && joined[to - 1] === "\n") to--;
  return { text: joined.slice(from, to), next: lastContent + 1 };
}

/** `key: <value>` at column keyCol → token + the index to continue from. */
function tokenizeKeyValue(key, keyCol, lineNo, lines, next) {
  const valueText = key.rest.trim();
  if (/^[|>]/.test(valueText)) {
    if (!/^[|>][+-]?[0-9]?$/.test(valueText)) {
      throw new WorkflowYamlError(`invalid block scalar header ${JSON.stringify(valueText)}`, lineNo);
    }
    // An explicit digit indicator gives the content indentation as an offset
    // from the parent node; honour it so `|2` is not spuriously rejected.
    const digit = /[0-9]/.exec(valueText);
    const body = consumeBlockBody(lines, next, keyCol, digit ? keyCol + Number(digit[0]) : null);
    return { token: { kind: "key", name: key.name, indent: keyCol, no: lineNo, value: { kind: "block", text: body.text } }, next: body.next };
  }
  if (valueText === "") {
    return { token: { kind: "key", name: key.name, indent: keyCol, no: lineNo, value: { kind: "empty" } }, next };
  }
  return {
    token: { kind: "key", name: key.name, indent: keyCol, no: lineNo, value: { kind: "scalar", value: parseScalarText(valueText, lineNo) } },
    next,
  };
}

function tokenize(lines) {
  const tokens = [];
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (l.content.trim() === "" || l.content.trimStart().startsWith("#")) { i++; continue; }
    if (l.hasTab) throw new WorkflowYamlError("tab indentation — YAML requires spaces", l.no);
    const text = stripComment(l.content).trimEnd();
    if (text === "") { i++; continue; }
    if (text === "---") {
      if (tokens.length === 0) { i++; continue; }
      throw new WorkflowYamlError("multi-document streams are outside the supported subset", l.no);
    }
    if (text === "...") throw new WorkflowYamlError("document-end markers are outside the supported subset", l.no);

    if (text === "-" || text.startsWith("- ")) {
      const spaces = /^-([ ]*)/.exec(text)[1];
      const contentCol = l.indent + 1 + spaces.length;
      const rest = text.slice(1 + spaces.length);
      tokens.push({ kind: "seq", indent: l.indent, no: l.no });
      i++;
      if (rest === "") continue;
      if (rest === "-" || rest.startsWith("- ")) {
        throw new WorkflowYamlError("an inline nested sequence (`- - …`) is outside the supported subset", l.no);
      }
      const key = parseKey(rest, l.no);
      if (key) {
        const r = tokenizeKeyValue(key, contentCol, l.no, lines, i);
        tokens.push(r.token);
        i = r.next;
        continue;
      }
      tokens.push({ kind: "item", indent: contentCol, no: l.no, value: parseScalarText(rest, l.no) });
      continue;
    }

    const key = parseKey(text, l.no);
    if (!key) throw new WorkflowYamlError(`line is neither a mapping key nor a sequence item: ${JSON.stringify(text)}`, l.no);
    const r = tokenizeKeyValue(key, l.indent, l.no, lines, i + 1);
    tokens.push(r.token);
    i = r.next;
  }
  return tokens;
}

// ── structural parser ──────────────────────────────────────────────────────

function parseMap(tokens, pos, indent) {
  const entries = [];
  const seen = new Set();
  while (pos < tokens.length && tokens[pos].kind === "key" && tokens[pos].indent === indent) {
    const t = tokens[pos];
    if (seen.has(t.name)) throw new WorkflowYamlError(`duplicate key \`${t.name}\``, t.no);
    seen.add(t.name);
    if (t.value.kind === "block") {
      entries.push([t.name, t.value.text]);
      pos++;
      continue;
    }
    if (t.value.kind === "scalar") {
      entries.push([t.name, t.value.value]);
      pos++;
      if (pos < tokens.length && tokens[pos].indent > indent) {
        throw new WorkflowYamlError(
          "a scalar value is followed by more-indented content — multi-line plain scalars and nested content under a scalar are outside the supported subset",
          tokens[pos].no
        );
      }
      continue;
    }
    // empty value → nested block at a deeper column, or a sequence at this column
    pos++;
    if (pos < tokens.length && tokens[pos].indent > indent) {
      const r = parseNode(tokens, pos, tokens[pos].indent);
      entries.push([t.name, r.value]);
      pos = r.next;
      continue;
    }
    if (pos < tokens.length && tokens[pos].indent === indent && tokens[pos].kind === "seq") {
      const r = parseSeq(tokens, pos, indent);
      entries.push([t.name, r.value]);
      pos = r.next;
      continue;
    }
    entries.push([t.name, null]);
  }
  return { value: Object.fromEntries(entries), next: pos };
}

function parseSeq(tokens, pos, indent) {
  const items = [];
  while (pos < tokens.length && tokens[pos].kind === "seq" && tokens[pos].indent === indent) {
    pos++;
    if (pos < tokens.length && tokens[pos].indent > indent) {
      const r = parseNode(tokens, pos, tokens[pos].indent);
      items.push(r.value);
      pos = r.next;
    } else {
      items.push(null);
    }
  }
  return { value: items, next: pos };
}

function parseNode(tokens, pos, indent) {
  if (tokens[pos].kind === "item") return { value: tokens[pos].value, next: pos + 1 };
  if (tokens[pos].kind === "seq") return parseSeq(tokens, pos, indent);
  return parseMap(tokens, pos, indent);
}

/**
 * Read a YAML document from the supported subset into plain JS values
 * (objects / arrays / strings / null).
 *
 * @throws {WorkflowYamlError} when the input uses a construct outside the subset.
 */
export function parseWorkflowYaml(src) {
  const tokens = tokenize(splitLines(src));
  if (tokens.length === 0) return null;
  const r = parseNode(tokens, 0, tokens[0].indent);
  if (r.next !== tokens.length) {
    const t = tokens[r.next];
    throw new WorkflowYamlError(`unexpected structure — the document is not a single block mapping or sequence`, t.no);
  }
  return r.value;
}
