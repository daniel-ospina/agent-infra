#!/usr/bin/env node
/**
 * validate-script.cjs — agent-infra
 *
 * L1 structural gate for carousel scripts (carousel-b2b-strategy Step 3.4).
 * Checks script.yaml against brief.yaml BEFORE storyboarding/images so copy
 * errors don't propagate downstream.
 *
 * Checks (L1 — deterministic structural):
 *   P0 (blocking)  — slide count matches brief.slide_count
 *   P0 (blocking)  — required fields per slide type:
 *                     photo-hero   → copy.headline + copy.subtitle
 *                     text-slide   → at least one of copy.headline / copy.body
 *   P0 (blocking)  — no placeholder text anywhere (TODO, TKTK, [placeholder])
 *   P0 (blocking)  — emphasis strings are short keywords (≤6 words, no
 *                     sentence-ending punctuation) — not full sentences
 *   P1 (warning)   — image_template missing on a needs_image: true slide
 *                     (warn, not block — storyboard can still assign it)
 *
 * Zero-dependency by design: agent-infra has no npm install in CI, so a
 * minimal YAML-subset parser is embedded. js-yaml/yaml are used dynamically
 * when available for full-fidelity parsing.
 *
 * Usage:
 *   node scripts/validate-script.cjs <script.yaml> <brief.yaml>
 *   node scripts/validate-script.cjs --script <path> --brief <path>
 *
 * Exit codes:
 *   0 — clean (no P0 violations; P1 warnings allowed)
 *   1 — P0 violations found
 *   2 — script error (missing args, unreadable/parse-unparseable input)
 */

const fs = require('fs');

// ── Minimal YAML-subset parser ─────────────────────────────────────────────
// Supports the shapes used by carousel brief.yaml / script.yaml:
// scalars (int, bool, quoted/unquoted strings, inline [a, b] lists),
// nested block mappings (indentation), and block lists of mappings or scalars.
// Comments (#) and document markers (---) are skipped. Not a general YAML
// parser — fails loudly on constructs it can't handle rather than guessing.
function parseYaml(text) {
  const lines = text.split('\n');
  let i = 0;

  function error(msg, lineNo) {
    throw new Error(`YAML parse error at line ${lineNo}: ${msg}`);
  }

  function indentOf(line) {
    const m = line.match(/^[ \t]*/);
    return (m ? m[0].replace(/\t/g, '  ') : '').length;
  }

  function stripComment(line) {
    // Remove trailing comments, but not '#' inside quotes.
    let inS = false, inD = false;
    for (let c = 0; c < line.length; c++) {
      const ch = line[c];
      if (ch === "'" && !inD) inS = !inS;
      else if (ch === '"' && !inS) inD = !inD;
      else if (ch === '#' && !inS && !inD) return line.slice(0, c);
    }
    return line;
  }

  function parseScalar(raw) {
    let v = raw.trim();
    if (v === 'null' || v === '~') return null;
    if (v === 'true') return true;
    if (v === 'false') return false;
    if (/^-?\d+$/.test(v)) return parseInt(v, 10);
    if (/^-?\d+\.\d+$/.test(v)) return parseFloat(v);
    if (/^\[.*\]$/.test(v)) {
      const inner = v.slice(1, -1).trim();
      if (!inner) return [];
      return inner.split(',').map((s) => parseScalar(s));
    }
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    return v;
  }

  // Parse the block starting at line `i` with the given parent indent.
  // Returns [value, nextIndex].
  function parseBlock(parentIndent) {
    const result = {};          // mapping
    const list = [];            // used if this block is a list
    let isList = null;          // null=unknown, true=list, false=mapping
    let listIsScalars = true;

    while (i < lines.length) {
      const rawLine = lines[i];
      const trimmed = rawLine.trim();
      if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('---') || trimmed.startsWith('...')) {
        i++;
        continue;
      }
      const indent = indentOf(rawLine);
      if (indent <= parentIndent) break; // dedent — block ended

      const content = stripComment(rawLine).trim();
      i++;

      if (/^-\s/.test(content)) {
        // List element: `- key: value`, `- key:` (nested block), or `- scalar`
        isList = true;
        const rest = content.slice(1).trim();
        const m = rest.match(/^([A-Za-z0-9_][A-Za-z0-9_-]*)\s*:\s*(.*)$/);
        if (m && m[2] !== '') {
          listIsScalars = false;
          const item = { [m[1]]: parseScalar(m[2]) };
          // Possible nested block under the item (deeper indent)
          if (i < lines.length) {
            const ni = indentOf(lines[i]);
            if (ni > indent) {
              const [nested] = parseBlock(indent);
              Object.assign(item, nested);
            }
          }
          list.push(item);
        } else if (m && m[2] === '') {
          listIsScalars = false;
          const item = {};
          if (i < lines.length && indentOf(lines[i]) > indent) {
            const [nested] = parseBlock(indent);
            Object.assign(item, nested);
          }
          list.push(item);
        } else {
          list.push(parseScalar(rest));
        }
        continue;
      }

      // Mapping entry: key: value | key: (nested block)
      const m = content.match(/^([A-Za-z0-9_][A-Za-z0-9_-]*)\s*:\s*(.*)$/);
      if (!m) {
        if (isList === true) {
          // A bare scalar in a list context (block scalars unsupported — bail)
          error(`unsupported construct in list context: "${content}"`, i);
        }
        error(`expected "key: value" but got "${content}"`, i);
      }
      isList = false;
      const key = m[1];
      const valuePart = m[2].trim();

      if (valuePart === '' || valuePart === '|' || valuePart === '>') {
        // Nested block (or block scalar — only nested blocks supported)
        if (valuePart !== '' && (i >= lines.length || indentOf(lines[i]) <= indent)) {
          // `key: |`-style block scalar without content — treat as empty
          result[key] = '';
          continue;
        }
        if (i < lines.length && indentOf(lines[i]) > indent) {
          const [nested] = parseBlock(indent);
          result[key] = nested;
        } else {
          result[key] = null;
        }
      } else if (/^[\[{]/.test(valuePart)) {
        result[key] = parseScalar(valuePart);
      } else {
        // Could still be a nested block if value is a bare key on next line —
        // not in this schema; treat as scalar.
        result[key] = parseScalar(valuePart);
        // Inline `key: value` followed by deeper-indent block is a YAML
        // construct we don't model — only when value looks like a map start.
      }
    }

    if (isList === true) return [list, i];
    return [result, i];
  }

  const [root] = parseBlock(-1);
  return root;
}

function loadYamlFile(path) {
  const text = fs.readFileSync(path, 'utf-8');
  // Prefer a real YAML library when installed (full fidelity); fall back to
  // the embedded subset parser.
  for (const mod of ['yaml', 'js-yaml']) {
    try {
      const lib = require(mod);
      const parsed = typeof lib.parse === 'function' ? lib.parse(text) : lib.load(text);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch { /* not installed — try next */ }
  }
  return parseYaml(text);
}

// ── L1 checks ──────────────────────────────────────────────────────────────
function collectStrings(node, out) {
  if (node === null || node === undefined) return;
  if (typeof node === 'string') out.push(node);
  else if (Array.isArray(node)) node.forEach((n) => collectStrings(n, out));
  else if (typeof node === 'object') Object.values(node).forEach((n) => collectStrings(n, out));
}

const EMPHASIS_MAX_WORDS = 6;

function validate(script, brief, scriptPath, briefPath) {
  const errors = [];   // P0 — block
  const warnings = []; // P1 — warn

  // 1. Slide count vs brief
  const briefCount = brief && typeof brief.slide_count === 'number' ? brief.slide_count : null;
  const slides = Array.isArray(script.slides) ? script.slides : [];
  if (briefCount !== null && slides.length !== briefCount) {
    errors.push(
      `slide-count: script.yaml has ${slides.length} slide(s), brief.yaml expects ${briefCount}`
    );
  } else if (briefCount === null) {
    errors.push(`brief: brief.yaml is missing numeric 'slide_count' (${briefPath})`);
  }
  if (slides.length === 0) {
    errors.push(`slides: script.yaml has no 'slides' list (${scriptPath})`);
  }

  // 2+3. Per-slide required fields + image_template
  slides.forEach((slide, idx) => {
    const n = idx + 1;
    const type = (slide.type || 'unknown').toLowerCase();
    const copy = slide.copy && typeof slide.copy === 'object' ? slide.copy : {};
    const headline = typeof copy.headline === 'string' ? copy.headline.trim() : '';
    const subtitle = typeof copy.subtitle === 'string' ? copy.subtitle.trim() : '';
    const body = typeof copy.body === 'string' ? copy.body.trim() : '';

    if (type === 'photo-hero') {
      if (!headline) errors.push(`slide ${n} (photo-hero): missing copy.headline (P0 — required)`);
      if (!subtitle) errors.push(`slide ${n} (photo-hero): missing copy.subtitle (P0 — required)`);
    } else if (type === 'text-slide') {
      if (!headline && !body) {
        errors.push(`slide ${n} (text-slide): needs at least one of copy.headline / copy.body (P0 — required)`);
      }
    }
    // Other slide types (cta, pilar, bento, …): at least one copy field
    if (!['photo-hero', 'text-slide'].includes(type) && !headline && !body && !(copy.eyebrow || '').trim()) {
      errors.push(`slide ${n} (${type}): no copy content (headline/body/eyebrow all empty)`);
    }

    if (slide.needs_image === true) {
      if (!slide.image_template) {
        warnings.push(`slide ${n} (${type}): needs_image: true but no image_template (P1 — assign in storyboard)`);
      }
    } else if (slide.image_template && !slide.needs_image) {
      warnings.push(`slide ${n} (${type}): image_template set but needs_image missing/false — set needs_image: true`);
    }
  });

  // 4. Placeholder text
  const allStrings = [];
  collectStrings(script, allStrings);
  const placeholder = allStrings.filter((s) => /\b(TODO|TKTK|PLACEHOLDER|LOREM IPSUM)\b/i.test(s) || /\[placeholder\]/i.test(s));
  if (placeholder.length > 0) {
    errors.push(`placeholders: found placeholder text — ${[...new Set(placeholder)].map((p) => JSON.stringify(p)).join(', ')}`);
  }

  // 5. Emphasis = short keywords
  slides.forEach((slide, idx) => {
    const n = idx + 1;
    const copy = slide.copy && typeof slide.copy === 'object' ? slide.copy : {};
    const em = copy.emphasis;
    const items = Array.isArray(em) ? em : em ? [em] : [];
    for (const e of items) {
      if (typeof e !== 'string') continue;
      const words = e.trim().split(/\s+/).filter(Boolean);
      if (words.length > EMPHASIS_MAX_WORDS) {
        errors.push(
          `slide ${n}: emphasis is a full sentence (${words.length} words) — must be a short keyword: "${e}"`
        );
      }
      if (/[.!?]["']?\s*$/.test(e.trim())) {
        errors.push(`slide ${n}: emphasis ends with sentence punctuation — keywords, not sentences: "${e}"`);
      }
    }
  });

  return { errors, warnings };
}

// ── CLI ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = { script: null, brief: null, help: false };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--script': args.script = argv[++i] || ''; break;
      case '--brief': args.brief = argv[++i] || ''; break;
      case '-h': case '--help': args.help = true; break;
      default:
        if (!args.script) args.script = argv[i];
        else if (!args.brief) args.brief = argv[i];
        else { console.error(`Error: unexpected argument "${argv[i]}"`); process.exit(2); }
    }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(`validate-script.cjs — L1 structural gate for carousel scripts

Usage:
  node scripts/validate-script.cjs <script.yaml> <brief.yaml>
  node scripts/validate-script.cjs --script <path> --brief <path>

P0 checks (exit 1 on failure): slide count vs brief, required fields per slide
type, placeholder text, emphasis-as-sentence.
P1 checks (warn only): image_template missing on needs_image: true slides.

Exit codes: 0 clean, 1 P0 violations, 2 script error.`);
    process.exit(0);
  }
  if (!args.script || !args.brief) {
    console.error('Error: validate-script.cjs requires <script.yaml> and <brief.yaml> paths.');
    process.exit(2);
  }
  if (!fs.existsSync(args.script)) { console.error(`Error: script file not found: ${args.script}`); process.exit(2); }
  if (!fs.existsSync(args.brief)) { console.error(`Error: brief file not found: ${args.brief}`); process.exit(2); }

  let script, brief;
  try {
    script = loadYamlFile(args.script);
    brief = loadYamlFile(args.brief);
  } catch (e) {
    console.error(`Error: cannot parse YAML — ${e.message}`);
    process.exit(2);
  }

  const { errors, warnings } = validate(script, brief, args.script, args.brief);

  console.log(`=== validate-script.cjs — ${args.script} vs ${args.brief} ===`);
  console.log(`Slides: ${Array.isArray(script.slides) ? script.slides.length : 0} | Brief slide_count: ${brief && brief.slide_count !== undefined ? brief.slide_count : 'MISSING'}`);

  for (const w of warnings) console.log(`⚠️  P1 ${w}`);
  if (errors.length > 0) {
    for (const e of errors) console.log(`❌ P0 ${e}`);
    console.log(`\n${errors.length} P0 error(s), ${warnings.length} P1 warning(s). BLOCKED — feed back to copy skill (max 2 retries).`);
    process.exit(1);
  }
  console.log(`${warnings.length} P1 warning(s).`);
  console.log('✅ L1 structural validation passed.');
  process.exit(0);
}

main();
