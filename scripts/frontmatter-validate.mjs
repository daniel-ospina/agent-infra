#!/usr/bin/env node
/**
 * frontmatter-validate.mjs — dep-free SKILL.md frontmatter validator (#254)
 *
 * Replaces check-skill-lint.mjs's regex-presence fallback with a tokenizer +
 * stateless rule engine that mirrors pi's loader grammar (pi v0.84.3,
 * yaml 2.9.0 — see docs/plans/2026-08-28-issue-254-skill-lint-yaml.md §2 for
 * the probe-derived fact table; reproducible via
 * scripts/probe-frontmatter-fixtures.mjs).
 *
 * Layering (plan §3.2 D2):
 *   extractFrontmatter  — mirrors pi's dist/utils/frontmatter.js exactly
 *                         (stripBom → CRLF normalize → startsWith('---') gate
 *                          → indexOf('\n---', 3) → slice(4, endIndex), no trim)
 *   tokenizeFrontmatter — the single stateful pass (quotes/flow/block scalars/
 *                         indentation/list generations/anchors); emits the
 *                         §5.1 token vocabulary. NEVER throws on unknown
 *                         constructs — unknown plain-scalar content passes.
 *   evaluateTokens      — stateless rule table, one entry per enumerated
 *                         error class (D7 unknown-construct policy).
 *   validateFrontmatter — composition + data derivation + extraction-level
 *                         P0s (missing opening/closing/empty/BOM, D1/D11) +
 *                         the body-`---` truncate warning (R3).
 *
 * Severity + exit contract (D3): THROW-classes and the string-type gate are
 * P0 (pi DROPS the skill → dead). TRUNCATE-classes are P1 (pi loads but
 * silently corrupts the value). A validator internal error is P0
 * (validator-internal-error — fail-closed: a validator bug turns CI red,
 * never silently green). Any finding (P0 or P1) fails the lint (exit 1).
 *
 * Acknowledged-drift register (§5.4):
 *   R1 missing opening/closing/empty frontmatter → P0 where pi silently
 *      returns {} (same net verdict, better message)
 *   R2 name non-string/empty/absent → P0 where pi falls back to the dir name
 *   R3 body `---` continuation → P1 authoring warning where pi ignores it
 *   R4 resolved alias into description resolving to non-string/empty → P0
 *      gate-description-nonstring (pi drops — safe direction)
 *   R5 BOM-prefixed SKILL.md → P0 bom-prefixed-frontmatter (pi strips BOM and
 *      loads; flagged as authoring strictness, NOT a guaranteed pi drop)
 *
 * Dep-free: pure Node stdlib. Node ≥ 18. No npm dependencies (O/I (3)).
 */

// ── Token vocabulary (§5.1 — bounded, the complete list) ───────────────────
export const TOKEN = {
  DOC_MARKER: 'DOC_MARKER',
  KEY: 'KEY',
  KEY_ONLY: 'KEY_ONLY',
  VALUE_PLAIN: 'VALUE_PLAIN',
  VALUE_QUOTED: 'VALUE_QUOTED',
  VALUE_BLOCK_HEADER: 'VALUE_BLOCK_HEADER',
  VALUE_BLOCK_BODY: 'VALUE_BLOCK_BODY',
  VALUE_FLOW: 'VALUE_FLOW',
  VALUE_ALIAS: 'VALUE_ALIAS',
  VALUE_EMPTY: 'VALUE_EMPTY',
  VALUE_NESTED: 'VALUE_NESTED',
  LIST_ITEM: 'LIST_ITEM',
  ANCHOR: 'ANCHOR',
  COMMENT: 'COMMENT',
  BLANK: 'BLANK',
  TOKENIZE_ERROR: 'TOKENIZE_ERROR',
};

/** Every enumerable finding class the validator can emit (for tests). */
export const ERROR_CLASSES = [
  // throw classes (P0 — pi drops the skill)
  'throw-unquoted-colon-value',
  'throw-colon-at-eol-value',
  'throw-unbalanced-quote',
  'throw-unclosed-flow',
  'throw-tab-indent',
  'throw-reserved-char-start',
  'throw-bare-key',
  'throw-multi-doc',
  'throw-block-seq-inline',
  'throw-seq-state-persists',
  'throw-root-seq-before-keys',
  'throw-unresolved-alias',
  'throw-flow-map-mid-scalar',
  'throw-multiple-tokens',
  'dup-key',
  // truncate classes (P1 — pi loads but corrupts the value)
  'truncate-unquoted-hash',
  'truncate-fm-continuation',
  // string-type gate (P0 — pi drops description-less/non-string skills)
  'gate-description-nonstring',
  'gate-name-nonstring',
  'gate-name-empty',
  'gate-name-absent',
  // extraction-level (P0 — safe-direction strictness, R1/R5)
  'extract-missing-opening',
  'extract-missing-closing',
  'extract-empty',
  'bom-prefixed-frontmatter',
  // fail-closed (P0 — validator bug turns CI red, never silently green)
  'validator-internal-error',
];

const P0 = 'P0';
const P1 = 'P1';

// ── Extraction mirror (plan §5.3 — normative, matches pi) ─────────────────
const normalizeNewlines = (v) => v.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
const stripBom = (v) => (v.charCodeAt(0) === 0xfeff ? v.slice(1) : v);

/**
 * Mirrors pi's dist/utils/frontmatter.js extractFrontmatter exactly.
 * Note: yamlString is NOT trimmed (pi does not trim).
 */
export function extractFrontmatter(content) {
  const normalized = normalizeNewlines(stripBom(content));
  if (!normalized.startsWith('---')) {
    return { yamlString: null, body: normalized, normalized };
  }
  const endIndex = normalized.indexOf('\n---', 3);
  if (endIndex === -1) {
    return { yamlString: null, body: normalized, normalized };
  }
  return {
    yamlString: normalized.slice(4, endIndex),
    body: normalized.slice(endIndex + 4).trim(),
    normalized,
  };
}

// ── Mini core-schema resolver (§5.2 — yaml-2.9.0 core schema scalars) ─────
/**
 * Classifies a plain scalar the way yaml 2.9.0's core schema does, for the
 * key-scoped string-type gate (D4). Probe-confirmed (pi v0.84.3):
 *   - `1_000`, `190:20:30`, `0b101`, `1,000,000` are STRINGS
 *   - `yes`/`on` are STRINGS (YAML 1.2 core schema — no 1.1 bool spellings)
 *   - `0123` → int 123, `1e3` → float, `.inf`/`.nan` → float, `0x1A`/`0o17` → int
 *   - `2026-08-28` → string (core schema has no timestamp resolution)
 */
export function resolvePlainScalar(text) {
  const t = String(text).trim();
  if (t === '' || /^(?:null|Null|NULL|~)$/.test(t)) return { type: 'null', value: null };
  if (/^(?:true|True|TRUE|false|False|FALSE)$/.test(t)) return { type: 'bool', value: /^(?:true|True|TRUE)$/.test(t) };
  if (/^0x[0-9a-fA-F]+$/.test(t)) return { type: 'int', value: parseInt(t, 16) };
  if (/^0o[0-7]+$/.test(t)) return { type: 'int', value: parseInt(t.slice(2), 8) };
  if (/^[+-]?(?:0|[1-9][0-9]*)$/.test(t)) return { type: 'int', value: parseInt(t, 10) };
  if (/^[+-]?0[0-9]+$/.test(t)) return { type: 'int', value: parseInt(t, 10) }; // 0123 → 123
  if (/^[+-]?(?:\.[0-9]+|[0-9]+\.[0-9]*)(?:[eE][+-]?[0-9]+)?$/.test(t)) return { type: 'float', value: parseFloat(t) };
  if (/^[+-]?[0-9]+[eE][+-]?[0-9]+$/.test(t)) return { type: 'float', value: parseFloat(t) };
  if (/^[+-]?\.(?:inf|Inf|INF)$/.test(t)) return { type: 'float', value: Infinity };
  if (/^[+-]?\.(?:nan|NaN|NAN)$/.test(t)) return { type: 'float', value: NaN };
  return { type: 'string', value: t };
}

// ── Tokenizer (the single stateful pass) ───────────────────────────────────
function splitLines(yamlString) {
  return yamlString.split('\n').map((raw, idx) => {
    const m = /^[ \t]*/.exec(raw);
    const indentStr = m[0];
    const content = raw.slice(indentStr.length);
    const indent = indentStr.replace(/\t/g, '  ').length;
    return {
      raw,
      content,
      indent,
      no: idx + 1,
      tabIndent: indentStr.includes('\t'),
      isBlank: content.trim() === '',
    };
  });
}

/** Index of a '#' that starts a comment (whitespace-preceded) — else -1. */
const findCommentHash = (s) => {
  const m = /(?:^|\s)#/.exec(s);
  return m ? m.index + m[0].length - 1 : -1;
};

/** Balanced `{...}` region containing ':' → flow-map mid-scalar (probe). */
function hasFlowMapMidScalar(text) {
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== '{') continue;
    let depth = 1;
    let hasColon = false;
    let j = i + 1;
    for (; j < text.length; j++) {
      const ch = text[j];
      if (ch === '"' || ch === "'") {
        const q = ch;
        let k = j + 1;
        for (; k < text.length; k++) {
          if (q === '"' && text[k] === '\\') { k++; continue; }
          if (q === "'" && text[k] === "'" && text[k + 1] === "'") { k++; continue; }
          if (text[k] === q) break;
        }
        j = k;
        continue;
      }
      if (ch === '{') depth++;
      else if (ch === '}') {
        depth--;
        if (depth === 0) break;
      } else if (ch === ':') hasColon = true;
    }
    if (depth === 0) return hasColon;
    // unclosed '{' — conservative: a colon appearing before EOL means yaml
    // throws (nested mappings / unclosed flow); a bare '{' passes.
    return hasColon;
  }
  return false;
}

function isBalancedFlow(s) {
  const stack = [];
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === '"' || ch === "'") {
      const q = ch;
      let k = i + 1;
      for (; k < s.length; k++) {
        if (q === '"' && s[k] === '\\') { k++; continue; }
        if (q === "'" && s[k] === "'" && s[k + 1] === "'") { k++; continue; }
        if (s[k] === q) break;
      }
      i = k;
      continue;
    }
    if (ch === '{' || ch === '[') stack.push(ch);
    else if (ch === '}' || ch === ']') {
      const open = stack.pop();
      if (!open || (open === '{' && ch !== '}') || (open === '[' && ch !== ']')) return false;
    }
  }
  return stack.length === 0;
}

/**
 * The single stateful pass. Emits the §5.1 token vocabulary. Rule-relevant
 * scan state is attached to tokens (flags), never re-derived in the rules
 * layer: VALUE_PLAIN carries {reservedStart, blockSeqInline, truncated,
 * colonViolation, eolColon, flowMapMid, multipleTokens}; LIST_ITEM carries
 * {inlineKeyHazard}; KEY carries {rootSeqHazard, rootIndentViolation};
 * VALUE_ALIAS carries {resolvedType}; ANCHOR registers into the anchor table.
 */
export function tokenizeFrontmatter(yamlString) {
  const lines = splitLines(yamlString);
  const tokens = [];
  const anchors = new Map(); // name → {type, value}
  const state = {
    blockScalar: null,    // {parentIndent, contentIndent, startLine}
    blockBody: [],
    inlineKey: null,      // {indent, gapSince} — last KEY with same-line value
    listGen: 0,
    seenRootKey: false,
    seenRootListItem: false,
    firstStructuralIndent: null,
  };

  const emit = (t) => tokens.push(t);

  const lastEmittedIsEmptyValue = () => {
    for (let i = tokens.length - 1; i >= 0; i--) {
      const t = tokens[i];
      if (t.t === TOKEN.VALUE_EMPTY) return true;
      if (t.t === TOKEN.KEY || t.t === TOKEN.ANCHOR) continue;
      return false;
    }
    return false;
  };

  const flushBlockBody = () => {
    if (state.blockBody.length > 0 && state.blockScalar) {
      emit({ t: TOKEN.VALUE_BLOCK_BODY, lines: state.blockBody, indent: state.blockScalar.contentIndent, line: state.blockScalar.startLine });
      state.blockBody = [];
    }
  };

  const nextNonBlankComment = (i) => {
    for (let j = i; j < lines.length; j++) {
      if (lines[j].isBlank || lines[j].content.startsWith('#')) continue;
      return lines[j];
    }
    return null;
  };

  const keySyntaxAt = (text) => {
    // `name:` / `"name":` at the start? Returns {name, quoted, rest} | null.
    const t = text;
    if (t[0] === '"' || t[0] === "'") {
      const q = t[0];
      let i = 1;
      let n = '';
      for (; i < t.length; i++) {
        if (q === '"' && t[i] === '\\') { i++; continue; }
        if (q === "'" && t[i + 1] === "'") { i++; continue; }
        if (t[i] === q) break;
        n += t[i];
      }
      if (i >= t.length) return null; // unclosed quoted key → not a key
      const colonM = /^[ \t]*:/.exec(t.slice(i + 1));
      if (!colonM) return null;
      return { name: n, quoted: true, rest: t.slice(i + 1 + colonM[0].length) };
    }
    // plain key: first ':' followed by space/tab/EOL
    for (let i = 0; i < t.length; i++) {
      if (t[i] !== ':') continue;
      const next = t[i + 1];
      if (next !== undefined && next !== ' ' && next !== '\t') continue;
      let keyName = t.slice(0, i);
      if (keyName.length === 0 || /^[ \t]/.test(keyName)) return null;
      keyName = keyName.trimEnd();
      if (/[{}\[\],]/.test(keyName)) {
        // flow keys are valid when balanced (`[key]: v` — probe: loads)
        if (!keyName.startsWith('[') && !keyName.startsWith('{')) return null;
        if (!isBalancedFlow(keyName)) return null;
      }
      return { name: keyName, quoted: false, rest: t.slice(i + 1) };
    }
    return null;
  };

  // ── value scanners ──────────────────────────────────────────────────────
  const scanQuoted = (text, lineNo, keyIndent, startI) => {
    // text begins at the opening quote. Returns {closed, content, rest, nextI}.
    let full = text;
    let curI = startI;
    const q = full[0];
    let content = '';
    let scanFrom = 1;
    while (true) {
      for (let i = scanFrom; i < full.length; i++) {
        const ch = full[i];
        if (q === '"' && ch === '\\') { content += full[i + 1] ?? ''; i++; continue; }
        if (q === "'" && ch === "'" && full[i + 1] === "'") { content += "'"; i++; continue; }
        if (ch === q) return { closed: true, content, rest: full.slice(i + 1), nextI: curI };
        content += ch;
      }
      // unclosed on this line — continuation?
      const next = lines[curI + 1];
      if (!next || next.isBlank || next.indent <= keyIndent) {
        // blank inside a quote / dedented continuation → yaml: "Missing
        // closing quote" (probe-confirmed)
        return { closed: false, content, rest: '', nextI: curI };
      }
      curI += 1;
      full = next.content;
      scanFrom = 0;
    }
  };

  const scanFlowAtValue = (text, lineNo) => {
    // text starts with '{' or '[' at VALUE position.
    const stack = [{ kind: text[0] }];
    const dupSeen = new Set();
    let j = 1;
    let closed = false;
    let flowDup = false;
    while (j < text.length) {
      const ch = text[j];
      if (ch === '"' || ch === "'") {
        const q = ch;
        let k = j + 1;
        for (; k < text.length; k++) {
          if (q === '"' && text[k] === '\\') { k++; continue; }
          if (q === "'" && text[k] === "'" && text[k + 1] === "'") { k++; continue; }
          if (text[k] === q) break;
        }
        j = k + 1;
        continue;
      }
      if (ch === '{' || ch === '[') { stack.push({ kind: ch }); j++; continue; }
      if (ch === '}' || ch === ']') {
        const open = stack.pop();
        if (!open || (open.kind === '{' && ch !== '}') || (open.kind === '[' && ch !== ']')) {
          return { closed: false, flowDup: false, kind: text[0], trailing: '', mismatch: true };
        }
        if (stack.length === 0) { closed = true; j++; break; }
        j++;
        continue;
      }
      if (ch === ':' && stack.length > 0 && stack[stack.length - 1].kind === '{' && text[j + 1] === ' ') {
        // dup detection at the current flow-map depth (`{a: 1, a: 2}` → yaml
        // "Map keys must be unique" — probe)
        const key = /[\w"'.-]+$/.exec(text.slice(0, j));
        if (key) {
          const id = `${stack.length}:${key[0]}`;
          if (dupSeen.has(id)) flowDup = true;
          else dupSeen.add(id);
        }
      }
      j++;
    }
    return { closed, flowDup, kind: text[0], trailing: closed ? text.slice(j).trim() : '', mismatch: false };
  };

  const scanPlain = (text, lineNo, keyIndent, startI) => {
    // Scans a plain value starting at `text` on line index startI; folds
    // deeper continuation lines. Returns {text, lines, truncated,
    // colonViolation, eolColon, blockSeqInline, flowMapMid, nextI}.
    const linesOut = [];
    let curText = text;
    let curI = startI;
    let truncated = false;
    let colonViolation = false;
    let eolColon = false;

    const blockSeqInline = curText === '-' || /^-[ \t]/.test(curText);

    while (true) {
      const hashIdx = findCommentHash(curText);
      if (hashIdx > 0) {
        curText = curText.slice(0, hashIdx).trimEnd();
        truncated = true;
      }
      linesOut.push(curText);

      // flow regions (for the colon check — a ':' inside `{a: b}` is the
      // flow-map-mid-scalar class, not the unquoted-colon class)
      const flowRegions = [];
      for (let k = 0; k < curText.length; k++) {
        if (curText[k] !== '{' && curText[k] !== '[') continue;
        const stack = [curText[k]];
        for (let kk = k + 1; kk < curText.length; kk++) {
          const c = curText[kk];
          if (c === '"' || c === "'") {
            const qq = c;
            let kkk = kk + 1;
            for (; kkk < curText.length; kkk++) {
              if (qq === '"' && curText[kkk] === '\\') { kkk++; continue; }
              if (qq === "'" && curText[kkk] === "'" && curText[kkk + 1] === "'") { kkk++; continue; }
              if (curText[kkk] === qq) break;
            }
            kk = kkk;
            continue;
          }
          if (c === '{' || c === '[') stack.push(c);
          else if (c === '}' || c === ']') {
            stack.pop();
            if (stack.length === 0) { flowRegions.push([k, kk]); break; }
          }
        }
      }
      const inRegion = (idx) => flowRegions.some(([a, b]) => idx > a && idx < b);

      const trimmedEnd = curText.trimEnd();
      if (trimmedEnd.endsWith(':')) eolColon = true;
      for (let k = 0; k < trimmedEnd.length; k++) {
        if (trimmedEnd[k] === ':' && (trimmedEnd[k + 1] === ' ' || trimmedEnd[k + 1] === '\t')) {
          if (!inRegion(k)) colonViolation = true;
        }
      }

      // continuation? (plain scalars fold across non-blank lines indented
      // deeper than the key; a key-colon continuation is the "Nested
      // mappings" throw — probe; a tab-indented line is a hard tab error)
      // The key-colon line is NOT folded: break without colonViolation and
      // let the main loop process it structurally — the compact-mapping
      // hazard (KEY at deeper indent) emits the single throw-unquoted-colon-
      // value finding (deduped).
      const next = lines[curI + 1];
      if (!next || next.isBlank || next.indent <= keyIndent || next.content.startsWith('#') || next.tabIndent) break;
      if (keySyntaxAt(next.content)) break;
      curI += 1;
      curText = next.content;
    }
    return {
      text: linesOut.join(' '),
      lines: linesOut,
      truncated,
      colonViolation,
      eolColon,
      blockSeqInline,
      flowMapMid: hasFlowMapMidScalar(text),
      nextI: curI,
    };
  };

  const scanValue = (text, lineNo, keyIndent, startI) => {
    // Emits VALUE_* tokens for the text after `key:` / `- `. Returns {nextI}
    // and optionally {blockScalarStart} for the main loop.
    const valueText = text.replace(/^[ \t]+/, '');

    if (valueText === '' || valueText.startsWith('#')) {
      emit({ t: TOKEN.VALUE_EMPTY, indent: keyIndent, line: lineNo });
      return { nextI: startI };
    }

    // block scalar header: | > with chomp/explicit-indent modifiers
    const bm = /^([>|])([+-]?)([1-9]?)(?:[ \t].*)?$/.exec(valueText);
    if (bm && bm[1]) {
      emit({ t: TOKEN.VALUE_BLOCK_HEADER, chomp: bm[2] || '', indent: keyIndent, line: lineNo });
      const explicit = bm[3] ? parseInt(bm[3], 10) : null;
      return {
        nextI: startI,
        blockScalarStart: {
          parentIndent: keyIndent,
          contentIndent: explicit !== null ? keyIndent + explicit : keyIndent + 1,
          startLine: lineNo,
        },
      };
    }

    // quoted value
    if (valueText[0] === '"' || valueText[0] === "'") {
      const q = scanQuoted(valueText, lineNo, keyIndent, startI);
      if (!q.closed) {
        emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'quote', line: lineNo, detail: 'unbalanced quote' });
        return { nextI: startI };
      }
      const trailing = q.rest.trim();
      if (trailing !== '' && !trailing.startsWith('#')) {
        // `"x" trailing` → yaml: "Unexpected scalar at node end" (probe)
        emit({ t: TOKEN.VALUE_PLAIN, text: '', lines: [], truncated: false, colonViolation: false, eolColon: false, blockSeqInline: false, multipleTokens: true, reservedStart: null, flowMapMid: false, line: lineNo });
        return { nextI: q.nextI };
      }
      emit({ t: TOKEN.VALUE_QUOTED, kind: valueText[0], content: q.content, line: lineNo });
      return { nextI: q.nextI };
    }

    // flow collection at value position
    if (valueText[0] === '{' || valueText[0] === '[') {
      const f = scanFlowAtValue(valueText, lineNo);
      if (f.mismatch || !f.closed) {
        emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'flow', line: lineNo, detail: 'unclosed flow collection' });
        return { nextI: startI };
      }
      if (f.flowDup) {
        emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'flow-dup', line: lineNo, detail: 'duplicate key inside flow mapping' });
      }
      const trailing = f.trailing;
      if (trailing !== '' && !trailing.startsWith('#')) {
        // `{a: b} trailing` → yaml: "Unexpected scalar at node end" (probe)
        emit({ t: TOKEN.VALUE_PLAIN, text: '', lines: [], truncated: false, colonViolation: false, eolColon: false, blockSeqInline: false, multipleTokens: true, reservedStart: null, flowMapMid: false, line: lineNo });
        return { nextI: startI };
      }
      emit({ t: TOKEN.VALUE_FLOW, kind: f.kind, line: lineNo });
      return { nextI: startI };
    }

    // alias
    if (valueText[0] === '*') {
      const am = /^\*([^\s]+)/.exec(valueText);
      const name = am ? am[1] : null;
      const anchor = name ? anchors.get(name) : null;
      if (name && !anchor) emit({ t: TOKEN.VALUE_ALIAS, name, resolvedType: 'unresolved', line: lineNo });
      else emit({ t: TOKEN.VALUE_ALIAS, name, resolvedType: anchor ? anchor.type : 'unresolved', line: lineNo });
      return { nextI: startI };
    }

    // anchor (with optional value after)
    if (valueText[0] === '&') {
      const am = /^&([^\s]+)(?:\s+(.*))?$/.exec(valueText);
      if (am) {
        const name = am[1];
        const after = am[2] ?? '';
        const resolved = after.trim() === '' ? { type: 'null', value: null } : resolvePlainScalar(after.trim());
        anchors.set(name, resolved);
        emit({ t: TOKEN.ANCHOR, name, line: lineNo });
        if (after.trim() === '') {
          emit({ t: TOKEN.VALUE_EMPTY, indent: keyIndent, line: lineNo });
          return { nextI: startI };
        }
        return scanValue(after, lineNo, keyIndent, startI);
      }
    }

    // reserved character at value start
    if (valueText[0] === '@' || valueText[0] === '`' || valueText[0] === '%') {
      emit({ t: TOKEN.VALUE_PLAIN, text: valueText, lines: [valueText], truncated: false, colonViolation: false, eolColon: false, blockSeqInline: false, multipleTokens: false, reservedStart: valueText[0], flowMapMid: false, line: lineNo });
      return { nextI: startI };
    }

    // plain scalar (may fold continuation lines)
    const p = scanPlain(valueText, lineNo, keyIndent, startI);
    emit({
      t: TOKEN.VALUE_PLAIN,
      text: p.text,
      lines: p.lines,
      truncated: p.truncated,
      colonViolation: p.colonViolation,
      eolColon: p.eolColon,
      blockSeqInline: p.blockSeqInline,
      multipleTokens: false,
      reservedStart: null,
      flowMapMid: p.flowMapMid,
      line: lineNo,
    });
    return { nextI: p.nextI };
  };

  // ── main scan loop ──────────────────────────────────────────────────────
  let i = 0;
  while (i < lines.length) {
    const L = lines[i];

    // block-scalar body consumption
    if (state.blockScalar) {
      if (L.isBlank || L.indent > state.blockScalar.contentIndent) {
        state.blockBody.push(L.raw);
        i++;
        continue;
      }
      flushBlockBody();
      state.blockScalar = null;
    }

    if (L.isBlank) {
      emit({ t: TOKEN.BLANK, line: L.no });
      if (state.inlineKey) state.inlineKey.gapSince = true;
      i++;
      continue;
    }

    if (L.tabIndent) {
      emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'tab', line: L.no, detail: 'tab used as indentation' });
      i++;
      continue;
    }

    if (L.content.startsWith('#')) {
      emit({ t: TOKEN.COMMENT, line: L.no });
      if (state.inlineKey) state.inlineKey.gapSince = true;
      i++;
      continue;
    }

    if (L.indent === 0 && /^%/.test(L.content)) {
      // a % line inside the frontmatter is a directive where yaml throws
      // "Missing directives-end/doc-start indicator line" (probe) — %YAML and
      // %TAG included (the frontmatter is not a directive context)
      emit({ t: TOKEN.KEY_ONLY, reservedStart: '%', line: L.no, indent: L.indent });
      i++;
      continue;
    }

    if (L.content === '...' || (L.indent === 0 && L.content === '---')) {
      emit({ t: TOKEN.DOC_MARKER, line: L.no });
      i++;
      continue;
    }

    // list item?
    const li = /^-(?:[ \t](.*))?$/.exec(L.content);
    if (li) {
      emit({ t: TOKEN.LIST_ITEM, indent: L.indent, line: L.no });
      state.listGen += 1;
      if (L.indent === 0) state.seenRootListItem = true;
      if (state.firstStructuralIndent === null) state.firstStructuralIndent = L.indent;
      if (state.firstStructuralIndent > 0 && L.indent === 0 && !state.seenRootKey) {
        // list item at column 0 after an indented start → yaml:
        // "Unexpected scalar at node end" (probe)
        emit({ t: TOKEN.KEY_ONLY, reservedStart: null, line: L.no, indent: L.indent, rootIndentViolation: true });
      }
      if (state.inlineKey && L.indent === state.inlineKey.indent) {
        // a block seq at the SAME column as a valued key is an implicit-key
        // error (yaml: "Implicit keys need to be on a single line" / "A
        // block sequence may not be used as an implicit map key"). A seq at
        // a DEEPER column is the value; a seq at a SHALLOWER column is a new
        // sibling structure. List items inside a list-of-maps (`steps:
        //   - name: x`) are legal — their indent differs from the nested
        // key's column (probe-verified against the live 121-tree).
        const hazard = state.inlineKey.gapSince ? 'gap' : 'direct';
        emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'seq-hazard', hazard, line: L.no, detail: 'block sequence after a valued key' });
        state.inlineKey = null;
      }
      const rest = li[1];
      if (rest !== undefined) {
        const itemIndent = L.indent + 2;
        // compact-mapping hazard: a block sequence item CONTAINING a mapping
        // entry, deeper than the most recent valued key → yaml: "Nested
        // mappings are not allowed in compact mappings" (probe: `a: 1\n
        //   - x: 42` throws; `a: 1\n  - x` with a bare scalar is fine).
        if (state.inlineKey && L.indent > state.inlineKey.indent && keySyntaxAt(rest)) {
          emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'nested-map', line: L.no, detail: 'block sequence with a mapping entry after a compact key' });
        }
        const kv = keySyntaxAt(rest);
        if (kv && kv.rest.trim() === '' ) {
          emit({ t: TOKEN.KEY, name: kv.name, indent: itemIndent, generation: state.listGen, quoted: kv.quoted, line: L.no });
          const nl = nextNonBlankComment(i + 1);
          if (nl && nl.indent > itemIndent) emit({ t: TOKEN.VALUE_NESTED, indent: itemIndent, line: L.no });
          else emit({ t: TOKEN.VALUE_EMPTY, indent: itemIndent, line: L.no });
          i++;
          continue;
        }
        if (kv) {
          emit({ t: TOKEN.KEY, name: kv.name, indent: itemIndent, generation: state.listGen, quoted: kv.quoted, line: L.no });
          const scan = scanValue(kv.rest, L.no, itemIndent, i);
          if (scan.blockScalarStart) { state.blockScalar = scan.blockScalarStart; state.blockBody = []; }
          // compact-mapping hazard: a valued key inside a list item also
          // creates the hazard at its own column (probe: `a: 1\n  - x: 42`
          // throws; `a: &e\n  - x: 42` with an empty anchored value is OK)
          if (kv.rest.trim() !== '' && !lastEmittedIsEmptyValue()) {
            state.inlineKey = { indent: itemIndent, gapSince: false };
          } else if (state.inlineKey && itemIndent === state.inlineKey.indent) {
            state.inlineKey = null;
          }
          i = scan.nextI + 1; // value consumed the current line
          continue;
        }
        // bare value after '- '
        const scan = scanValue(rest, L.no, itemIndent, i);
        if (scan.blockScalarStart) { state.blockScalar = scan.blockScalarStart; state.blockBody = []; }
        i = scan.nextI + 1;
        continue;
      }
      i++;
      continue;
    }

    // key line?
    const kv = keySyntaxAt(L.content);
    if (kv) {
      const rootViolation = state.firstStructuralIndent !== null && state.firstStructuralIndent > 0 && L.indent === 0 && !state.seenRootKey;
      const rootSeqHazard = state.seenRootListItem && !state.seenRootKey;
      if (L.indent === 0) state.seenRootKey = true;
      if (state.firstStructuralIndent === null) state.firstStructuralIndent = L.indent;
      // compact-mapping hazard (yaml: "Nested mappings are not allowed in
      // compact mappings" / "All mapping items must start at the same
      // column") — a valued key at indent k followed by a DEEPER mapping
      // entry throws, across blank/comment lines. A same-indent empty-valued
      // key resets the hazard (it opens a nested map: `a: 1\nb:\n  c: 3` is
      // legal). A same-indent valued key replaces it. Probe-verified.
      if (state.inlineKey && L.indent > state.inlineKey.indent) {
        emit({ t: TOKEN.TOKENIZE_ERROR, kind: 'nested-map', line: L.no, detail: 'nested mapping after a compact key' });
      }
      if (kv.rest.trim() === '') {
        if (state.inlineKey && L.indent === state.inlineKey.indent) state.inlineKey = null;
      } else {
        state.inlineKey = { indent: L.indent, gapSince: false };
      }
      // root keys always belong to generation 0 (a prior list item must not
      // split the root mapping's dup-key identity — probe: duplicate root key
      // after a list item → yaml "Map keys must be unique")
      const keyGen = L.indent === 0 ? 0 : state.listGen;
      emit({
        t: TOKEN.KEY, name: kv.name, indent: L.indent, generation: keyGen, quoted: kv.quoted, line: L.no,
        rootSeqHazard, rootIndentViolation: rootViolation,
      });
      if (kv.rest.trim() === '') {
        const nl = nextNonBlankComment(i + 1);
        if (nl && nl.indent > L.indent) emit({ t: TOKEN.VALUE_NESTED, indent: L.indent, line: L.no });
        else emit({ t: TOKEN.VALUE_EMPTY, indent: L.indent, line: L.no });
        i++;
        continue;
      }
      state.inlineKey = { indent: L.indent, gapSince: false };
      const scan = scanValue(kv.rest, L.no, L.indent, i);
      if (scan.blockScalarStart) { state.blockScalar = scan.blockScalarStart; state.blockBody = []; }
      // a value that resolves to null/empty (VALUE_EMPTY — incl. an empty
      // anchored value `a: &e`) makes the key empty-valued: reset the hazard
      // like `key:` (probe: `a: &e\n  - x: 42` parses fine)
      if (lastEmittedIsEmptyValue() && state.inlineKey && L.indent === state.inlineKey.indent) {
        state.inlineKey = null;
      }
      i = scan.nextI + 1; // value consumed the current line
      continue;
    }

    // bare scalar at structural position
    const reservedStart = L.content[0] === '@' || L.content[0] === '`' ? L.content[0] : null;
    emit({ t: TOKEN.KEY_ONLY, reservedStart, line: L.no, indent: L.indent });
    i++;
  }
  flushBlockBody();

  return { tokens, anchors };
}

// ── Rules layer (stateless pure consumers — one entry per class) ───────────
function finding(classId, field, line, message, severity = P0) {
  return { class: classId, field, line, message, severity };
}

const ruleThrowUnquotedColon = (tokens) => {
  const out = [];
  for (const tk of tokens) {
    if (tk.t === TOKEN.TOKENIZE_ERROR && tk.kind === 'nested-map') {
      out.push(finding('throw-unquoted-colon-value', null, tk.line, 'nested mapping after a compact key (yaml: nested mappings are not allowed in compact mappings)'));
      continue;
    }
    if (tk.t !== TOKEN.VALUE_PLAIN) continue;
    if (tk.multipleTokens) continue;
    if (tk.colonViolation) out.push(finding('throw-unquoted-colon-value', null, tk.line, "unquoted ': ' in a plain value (yaml: nested mappings are not allowed in compact mappings)"));
    else if (tk.eolColon) out.push(finding('throw-colon-at-eol-value', null, tk.line, "plain value ends with ':' (yaml: nested mappings are not allowed in compact mappings)"));
  }
  return out;
};

const ruleThrowQuote = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.TOKENIZE_ERROR && tk.kind === 'quote')
  .map((tk) => finding('throw-unbalanced-quote', null, tk.line, 'unbalanced quote (yaml: missing closing quote)'));

const ruleThrowFlow = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.TOKENIZE_ERROR && tk.kind === 'flow')
  .map((tk) => finding('throw-unclosed-flow', null, tk.line, 'unclosed flow collection at value position'));

const ruleThrowTab = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.TOKENIZE_ERROR && tk.kind === 'tab')
  .map((tk) => finding('throw-tab-indent', null, tk.line, 'tab used as indentation (yaml: tabs are not allowed as indentation)'));

const ruleThrowSeqHazard = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.TOKENIZE_ERROR && tk.kind === 'seq-hazard')
  .map((tk) => finding(tk.hazard === 'gap' ? 'throw-seq-state-persists' : 'throw-block-seq-inline', null, tk.line, tk.hazard === 'gap'
    ? 'block sequence after a valued key across blank/comment lines (yaml: block sequence may not be used as an implicit map key)'
    : 'block sequence after a valued key (yaml: implicit keys need to be on a single line)'));

const ruleThrowReserved = (tokens) => {
  const out = [];
  for (const tk of tokens) {
    if (tk.t === TOKEN.VALUE_PLAIN && tk.reservedStart) {
      out.push(finding('throw-reserved-char-start', null, tk.line, `plain value cannot start with reserved character '${tk.reservedStart}'`));
    } else if (tk.t === TOKEN.KEY_ONLY && tk.reservedStart) {
      out.push(finding('throw-reserved-char-start', null, tk.line, `line cannot start with reserved/directive character '${tk.reservedStart}'`));
    }
  }
  return out;
};

const ruleThrowBareKey = (tokens) => {
  const out = [];
  for (const tk of tokens) {
    if (tk.t === TOKEN.KEY_ONLY && !tk.reservedStart) {
      out.push(finding('throw-bare-key', null, tk.line, 'bare scalar at key position (yaml: implicit keys need to be on a single line)'));
    }
    if (tk.t === TOKEN.KEY_ONLY && tk.rootIndentViolation) {
      out.push(finding('throw-bare-key', null, tk.line, 'mapping/list item at column 0 after an indented start (yaml: unexpected scalar at node end)'));
    }
    if (tk.t === TOKEN.KEY && tk.rootIndentViolation) {
      out.push(finding('throw-bare-key', null, tk.line, 'mapping item at column 0 after an indented start (yaml: unexpected scalar at node end)'));
    }
  }
  return out;
};

const ruleThrowRootSeq = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.KEY && tk.rootSeqHazard)
  .map((tk) => finding('throw-root-seq-before-keys', null, tk.line, 'root block sequence followed by mapping keys (yaml: unexpected scalar at node end)'));

const ruleThrowMultiDoc = (tokens) => {
  const out = [];
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].t !== TOKEN.DOC_MARKER) continue;
    let j = i + 1;
    while (j < tokens.length && (tokens[j].t === TOKEN.BLANK || tokens[j].t === TOKEN.COMMENT)) j++;
    if (j < tokens.length) {
      out.push(finding('throw-multi-doc', null, tokens[i].line, 'document marker followed by content (yaml: source contains multiple documents)'));
    }
  }
  return out;
};

const ruleThrowAlias = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.VALUE_ALIAS && tk.resolvedType === 'unresolved')
  .map((tk) => finding('throw-unresolved-alias', null, tk.line, `unresolved alias '*${tk.name}' (the anchor must be set before the alias)`));

const ruleThrowFlowMapMid = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.VALUE_PLAIN && tk.flowMapMid && !tk.multipleTokens)
  .map((tk) => finding('throw-flow-map-mid-scalar', null, tk.line, 'flow mapping inside a plain scalar (yaml: nested mappings are not allowed in compact mappings)'));

const ruleThrowMultipleTokens = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.VALUE_PLAIN && tk.multipleTokens)
  .map((tk) => finding('throw-multiple-tokens', null, tk.line, 'unexpected scalar after a quoted/flow value (yaml: unexpected scalar at node end)'));

const ruleThrowBlockSeqInline = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.VALUE_PLAIN && tk.blockSeqInline)
  .map((tk) => finding('throw-block-seq-inline', null, tk.line, 'block sequence on the same line as a key value (yaml: unexpected block-seq-ind on same line with key)'));

const ruleDupKey = (tokens) => {
  const out = [];
  for (const tk of tokens) {
    if (tk.t === TOKEN.TOKENIZE_ERROR && tk.kind === 'flow-dup') {
      out.push(finding('dup-key', null, tk.line, 'duplicate key inside a flow mapping (yaml: map keys must be unique)'));
    }
  }
  const seen = new Map(); // `${indent}:${gen}` → Set<name>
  for (const tk of tokens) {
    if (tk.t !== TOKEN.KEY) continue;
    const id = `${tk.indent}:${tk.generation}`;
    if (!seen.has(id)) seen.set(id, new Set());
    if (seen.get(id).has(tk.name)) {
      out.push(finding('dup-key', tk.name, tk.line, `duplicate key '${tk.name}' in the same mapping (yaml: map keys must be unique)`));
    } else {
      seen.get(id).add(tk.name);
    }
  }
  return out;
};

const ruleTruncateHash = (tokens) => tokens
  .filter((tk) => tk.t === TOKEN.VALUE_PLAIN && tk.truncated && !tk.multipleTokens && !tk.reservedStart)
  .map((tk) => finding('truncate-unquoted-hash', null, tk.line, "unquoted ' #' in a plain value truncates the value (pi loads the truncated value silently)", P1));

// ── string-type gate (D4 — mirrors pi's hasDescription / name fallback) ───
function pairedKeyValues(tokens) {
  const pairs = [];
  let pending = null;
  for (const tk of tokens) {
    if (tk.t === TOKEN.KEY) { pending = tk; continue; }
    if (tk.t === TOKEN.ANCHOR) continue;
    if (tk.t === TOKEN.KEY_ONLY || tk.t === TOKEN.DOC_MARKER || tk.t === TOKEN.LIST_ITEM) { pending = null; continue; }
    if (pending && tk.t.startsWith('VALUE_')) {
      pairs.push({ key: pending, value: tk });
      pending = null;
    }
  }
  return pairs;
}

function valueTypeOf(valueTok, tokens) {
  switch (valueTok.t) {
    case TOKEN.VALUE_PLAIN: {
      const r = resolvePlainScalar(valueTok.text);
      if (r.type === 'string' && r.value.trim() === '') return 'empty-string';
      return r.type;
    }
    case TOKEN.VALUE_QUOTED: {
      return valueTok.content.trim() === '' ? 'empty-string' : 'string';
    }
    case TOKEN.VALUE_FLOW: return 'collection';
    case TOKEN.VALUE_NESTED: return 'collection';
    case TOKEN.VALUE_BLOCK_HEADER: {
      // body may follow as VALUE_BLOCK_BODY (opaque; non-empty → string)
      const idx = tokens.indexOf(valueTok);
      for (let j = idx + 1; j < tokens.length; j++) {
        if (tokens[j].t === TOKEN.VALUE_BLOCK_BODY) return 'string';
        if (tokens[j].t === TOKEN.KEY) break;
      }
      return 'empty-string';
    }
    case TOKEN.VALUE_ALIAS: {
      // unresolved aliases are owned by throw-unresolved-alias (P0) — the
      // gate does not double-report them
      return valueTok.resolvedType === 'unresolved' ? 'unresolved-alias' : valueTok.resolvedType;
    }
    case TOKEN.VALUE_EMPTY: return 'null';
    default: return 'unknown';
  }
}

const ruleStringGate = (tokens) => {
  const out = [];
  // the gate is key-scoped to name/description AND top-level only — pi reads
  // frontmatter.name / frontmatter.description from the document root; a
  // nested `name:` inside a steps list is a different object
  const pairs = pairedKeyValues(tokens).filter((p) => p.key.indent === 0);
  for (const { key, value } of pairs) {
    const vtype = valueTypeOf(value, tokens);
    if (vtype === 'unresolved-alias') continue;
    if (key.name === 'description' && vtype !== 'string') {
      out.push(finding('gate-description-nonstring', 'description', key.line, 'description must resolve to a non-empty string (pi drops the skill otherwise)'));
    }
    if (key.name === 'name') {
      if (vtype === 'empty-string') out.push(finding('gate-name-empty', 'name', key.line, 'name is an empty string (pi falls back to the directory name)'));
      else if (vtype !== 'string') out.push(finding('gate-name-nonstring', 'name', key.line, 'name must be a string (pi falls back to the directory name)'));
    }
  }
  const hasDescKey = tokens.some((tk) => tk.t === TOKEN.KEY && tk.name === 'description' && tk.indent === 0);
  const hasNameKey = tokens.some((tk) => tk.t === TOKEN.KEY && tk.name === 'name' && tk.indent === 0);
  if (!hasDescKey) out.push(finding('gate-description-nonstring', 'description', 0, 'missing description key (pi drops the skill: frontmatter.description === undefined)'));
  if (!hasNameKey) out.push(finding('gate-name-absent', 'name', 0, 'missing name key (pi falls back to the directory name)'));
  return out;
};

// ── rules table (flat, greppable — one entry per enumerated class) ────────
const RULES = [
  ruleThrowUnquotedColon,
  ruleThrowQuote,
  ruleThrowFlow,
  ruleThrowTab,
  ruleThrowSeqHazard,
  ruleThrowReserved,
  ruleThrowBareKey,
  ruleThrowRootSeq,
  ruleThrowMultiDoc,
  ruleThrowAlias,
  ruleThrowFlowMapMid,
  ruleThrowMultipleTokens,
  ruleThrowBlockSeqInline,
  ruleDupKey,
  ruleTruncateHash,
];

/** Rule layer: tokens → findings[] (stateless). */
export function evaluateTokens(tokens, anchors = new Map()) {
  const findings = [];
  for (const rule of RULES) findings.push(...rule(tokens));
  findings.push(...ruleStringGate(tokens));
  // deterministic order for tests
  findings.sort((a, b) => (a.line - b.line) || ERROR_CLASSES.indexOf(a.class) - ERROR_CLASSES.indexOf(b.class));
  return findings;
}

// ── data derivation (quote-aware, for the linter's schema checks) ─────────
function deriveData(tokens, anchors) {
  const data = {};
  const pairs = pairedKeyValues(tokens).filter((p) => p.key.indent === 0);
  for (const { key, value } of pairs) {
    switch (value.t) {
      case TOKEN.VALUE_PLAIN: {
        data[key.name] = resolvePlainScalar(value.text).value;
        break;
      }
      case TOKEN.VALUE_QUOTED: data[key.name] = value.content; break;
      case TOKEN.VALUE_FLOW: data[key.name] = value.kind === '{' ? {} : []; break;
      case TOKEN.VALUE_NESTED: data[key.name] = {}; break;
      case TOKEN.VALUE_BLOCK_HEADER: {
        const idx = tokens.indexOf(value);
        let body = '';
        for (let j = idx + 1; j < tokens.length; j++) {
          if (tokens[j].t === TOKEN.VALUE_BLOCK_BODY) { body = tokens[j].lines.join('\n'); break; }
          if (tokens[j].t === TOKEN.KEY) break;
        }
        data[key.name] = body;
        break;
      }
      case TOKEN.VALUE_ALIAS: {
        const anchor = anchors.get(value.name);
        data[key.name] = anchor ? anchor.value : null;
        break;
      }
      case TOKEN.VALUE_EMPTY: data[key.name] = null; break;
      default: data[key.name] = undefined;
    }
  }
  return data;
}

// ── composition ────────────────────────────────────────────────────────────
/**
 * validateFrontmatter(content) → {ok, findings, data, yamlString, body}
 *   ok: true means validation completed without an internal error and data is
 *       derivable (NOT "no findings"); P1 findings still fail the lint.
 */
export function validateFrontmatter(content) {
  const findings = [];
  let data = {};
  let yamlString = null;
  let body = '';
  let ok = true;

  try {
    const rawBom = content.charCodeAt(0) === 0xfeff;
    if (rawBom) {
      findings.push(finding('bom-prefixed-frontmatter', null, 0, 'file starts with a UTF-8 BOM (U+FEFF) — authoring error; save without BOM'));
    }
    const extracted = extractFrontmatter(content);
    yamlString = extracted.yamlString;
    body = extracted.body;

    if (yamlString === null) {
      if (!extracted.normalized.startsWith('---')) {
        findings.push(finding('extract-missing-opening', null, 0, 'missing opening ---'));
      } else {
        findings.push(finding('extract-missing-closing', null, 0, 'missing closing ---'));
      }
    } else if (yamlString === '') {
      findings.push(finding('extract-empty', null, 0, 'empty frontmatter'));
    } else {
      const { tokens, anchors } = tokenizeFrontmatter(yamlString);
      findings.push(...evaluateTokens(tokens, anchors));
      data = deriveData(tokens, anchors);

      // R3 — body `---` continuation → P1 authoring warning. Narrowed per the
      // plan's register-fallback clause (D8c): the live 121-tree bodies are
      // full of markdown horizontal-rule `---` lines (100+ occurrences) which
      // are inert for pi and would be false positives. The warning fires only
      // on the genuine "second frontmatter block" shape — a `---` line at the
      // START of the body, immediately after the closing delimiter (outside
      // code fences). Mid-body `---` lines are markdown and never flagged.
      const bodyNoFences = body.replace(/```[\s\S]*?```/g, '');
      if (bodyNoFences.trimStart().startsWith('---')) {
        findings.push(finding('truncate-fm-continuation', null, 0, "body starts with a '---' block (a second frontmatter block — pi ignores it; authoring warning)", P1));
      }
    }
  } catch (e) {
    ok = false;
    findings.push(finding('validator-internal-error', null, 0, `internal validation error: ${e.message}`));
  }

  return { ok, findings, data, yamlString, body };
}
