#!/usr/bin/env node
/**
 * probe-frontmatter-fixtures.mjs — probe runner for the #254 fixture matrix.
 *
 * Imports pi's REAL bundle (same PI resolution as the oracle test) and runs
 * every fixture content through `loadSkillsFromDir` on materialized tmp skill
 * trees — pi's real gate (hasDescription + name fallback + drop semantics),
 * never a locally reimplemented copy (plan D12). Records the net consequence
 * (loaded? name? description? diagnostics? parse error?).
 *
 * Usage:
 *   node scripts/probe-frontmatter-fixtures.mjs            # verify committed records
 *   node scripts/probe-frontmatter-fixtures.mjs --write    # regenerate frontmatter-fixtures.mjs
 *
 * `--write` writes FIXTURES (defs merged with pi's recorded consequence) and
 * PI_VERSION_PIN into scripts/frontmatter-fixtures.mjs. Without `--write`,
 * live pi results are compared against the committed records — zero
 * mismatches or exit 1 (drift).
 *
 * Dep-free (O/I (3)); pi required (dev machine / cron only).
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ── PI resolution (patch-pi-retry.sh precedent — node-v* glob layout) ──────
export function resolvePiBundle() {
  const nodeRoot = process.env.PI_NODE_ROOT || path.join(os.homedir(), '.local/share', 'pi-node');
  const candidates = [];
  if (fs.existsSync(nodeRoot)) {
    for (const entry of fs.readdirSync(nodeRoot)) {
      if (!/^node-v?/.test(entry)) continue;
      candidates.push(path.join(nodeRoot, entry, 'lib', 'node_modules', '@earendil-works', 'pi-coding-agent', 'dist', 'bundle', 'index.js'));
    }
  }
  if (process.env.PI_NODE_BIN) {
    candidates.push(path.join(path.dirname(process.env.PI_NODE_BIN), '..', 'lib', 'node_modules', '@earendil-works', 'pi-coding-agent', 'dist', 'bundle', 'index.js'));
  }
  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) return fs.realpathSync(c);
    } catch { /* keep probing */ }
  }
  throw new Error(
    'pi bundle not found (PI_NODE_ROOT glob node-v*/…/dist/bundle/index.js, PI_NODE_BIN, or command -v pi). ' +
    'The oracle and probe require a local pi install (dev machine / cron only).'
  );
}

// ── fixture matrix ──────────────────────────────────────────────────────────
// expected: the validator finding classes (plan §2 probe table). A fixture
// whose content omits name/description also legitimately triggers the
// gate-name-absent / gate-description-nonstring findings — listed explicitly.
// expectedRelation (D12): drop | load | load-with-truncation | ack-drift-flagged
const GA = 'gate-name-absent';
const GD = 'gate-description-nonstring';

const FIXTURE_DEFS = [
  // ── the O/I case (issue #254) ─────────────────────────────────────────────
  { id: 'oi-unquoted-colon', class: 'throw-unquoted-colon-value', expected: ['throw-unquoted-colon-value', GA], expectedRelation: 'drop', content: '---\ndescription: foo: bar\n---\nbody\n', note: 'exact O/I case — unquoted `: ` in a plain value; pi throws (Nested mappings)' },

  // ── THROW classes (P0 — pi drops) ─────────────────────────────────────────
  { id: 'throw-unquoted-colon-multiline', class: 'throw-unquoted-colon-value', expected: ['throw-unquoted-colon-value'], expectedRelation: 'drop', content: '---\nname: x\ndescription: foo\n  bar: baz\n---\nbody\n', note: 'key-colon on a plain continuation line' },
  { id: 'throw-unquoted-colon-inner', class: 'throw-unquoted-colon-value', expected: ['throw-unquoted-colon-value'], expectedRelation: 'drop', content: '---\nname: x\ndescription: a: b:c\n---\nbody\n' },
  { id: 'throw-colon-at-eol', class: 'throw-colon-at-eol-value', expected: ['throw-colon-at-eol-value'], expectedRelation: 'drop', content: '---\nname: x\ndescription: foo:\n---\nbody\n' },
  { id: 'throw-quote-single', class: 'throw-unbalanced-quote', expected: ['throw-unbalanced-quote'], expectedRelation: 'drop', content: "---\nname: x\ndescription: 'abc\n---\nbody\n" },
  { id: 'throw-quote-double', class: 'throw-unbalanced-quote', expected: ['throw-unbalanced-quote'], expectedRelation: 'drop', content: '---\nname: x\ndescription: "abc\n---\nbody\n' },
  { id: 'throw-quote-blank-inside', class: 'throw-unbalanced-quote', expected: ['throw-unbalanced-quote', 'throw-bare-key'], expectedRelation: 'drop', content: '---\nname: x\ndescription: "a\n\nb"\n---\nbody\n', note: 'blank line inside a double-quoted scalar' },
  { id: 'throw-quote-dedent', class: 'throw-unbalanced-quote', expected: ['throw-unbalanced-quote', 'throw-bare-key'], expectedRelation: 'drop', content: '---\nname: x\ndescription: "a\nb"\n---\nbody\n', note: 'dedented continuation — quote never closes' },
  { id: 'throw-flow-unclosed', class: 'throw-unclosed-flow', expected: ['throw-unclosed-flow'], expectedRelation: 'drop', content: '---\nname: x\ndescription: {a: b\n---\nbody\n' },
  { id: 'throw-tab-indent', class: 'throw-tab-indent', expected: ['throw-tab-indent'], expectedRelation: 'drop', content: '---\nname: x\ndescription: test\n\tbar: baz\n---\nbody\n' },
  { id: 'throw-reserved-at', class: 'throw-reserved-char-start', expected: ['throw-reserved-char-start'], expectedRelation: 'drop', content: '---\nname: x\ndescription: @x\n---\nbody\n' },
  { id: 'throw-reserved-backtick', class: 'throw-reserved-char-start', expected: ['throw-reserved-char-start'], expectedRelation: 'drop', content: '---\nname: x\ndescription: `x`\n---\nbody\n' },
  { id: 'throw-reserved-percent', class: 'throw-reserved-char-start', expected: ['throw-reserved-char-start'], expectedRelation: 'drop', content: '---\nname: x\ndescription: %foo\n---\nbody\n' },
  { id: 'throw-percent-line', class: 'throw-reserved-char-start', expected: ['throw-reserved-char-start'], expectedRelation: 'drop', content: '---\nname: x\n%foo\ndescription: z\n---\nbody\n', note: '% directive inside the frontmatter (yaml: Missing directives-end)' },
  { id: 'throw-bare-key', class: 'throw-bare-key', expected: ['throw-bare-key'], expectedRelation: 'drop', content: '---\nname: x\nabc\ndescription: z\n---\nbody\n' },
  { id: 'throw-bare-key-opener', class: 'throw-bare-key', expected: ['throw-bare-key', GD], expectedRelation: 'drop', content: '---abc\nname: x\n---\nbody\n', note: '---abc opener — "abc" lands inside the yamlString' },
  { id: 'throw-bare-scalar-only', class: 'throw-bare-key', expected: ['throw-bare-key', GD, GA], expectedRelation: 'drop', content: '---\njust text\n---\nbody\n' },
  { id: 'throw-indented-start', class: 'throw-bare-key', expected: ['throw-bare-key'], expectedRelation: 'drop', content: '---\n  a: 1\nname: x\ndescription: z\n---\nbody\n', note: 'mapping item at column 0 after an indented start' },
  { id: 'throw-multi-doc', class: 'throw-multi-doc', expected: ['throw-multi-doc', 'throw-bare-key'], expectedRelation: 'drop', content: '---\nname: x\ndescription: z\n...\nmore\n---\nbody\n', note: 'content after the doc marker is a new document and a bare scalar' },
  { id: 'throw-block-seq-inline', class: 'throw-block-seq-inline', expected: ['throw-block-seq-inline'], expectedRelation: 'drop', content: '---\nname: x\ndescription: foo\n- item\n---\nbody\n' },
  { id: 'throw-seq-inline-same-line', class: 'throw-block-seq-inline', expected: ['throw-block-seq-inline'], expectedRelation: 'drop', content: '---\nname: x\ndescription: - item\n---\nbody\n', note: 'block-seq-ind on the same line as a key' },
  { id: 'throw-seq-persists-blank', class: 'throw-seq-state-persists', expected: ['throw-seq-state-persists'], expectedRelation: 'drop', content: '---\nname: x\ndescription: foo\n\n- item\n---\nbody\n' },
  { id: 'throw-seq-persists-comment', class: 'throw-seq-state-persists', expected: ['throw-seq-state-persists'], expectedRelation: 'drop', content: '---\nname: x\ndescription: foo\n# c\n- item\n---\nbody\n' },
  { id: 'throw-root-seq-before-keys', class: 'throw-root-seq-before-keys', expected: ['throw-root-seq-before-keys'], expectedRelation: 'drop', content: '---\n- item\nname: test\ndescription: z\n---\nbody\n' },
  { id: 'throw-unresolved-alias', class: 'throw-unresolved-alias', expected: ['throw-unresolved-alias'], expectedRelation: 'drop', content: '---\nname: x\ndescription: *nope\n---\nbody\n' },
  { id: 'throw-flow-map-mid', class: 'throw-flow-map-mid-scalar', expected: ['throw-flow-map-mid-scalar'], expectedRelation: 'drop', content: '---\nname: x\ndescription: foo {a: b} bar\n---\nbody\n' },
  { id: 'throw-multiple-tokens-flow', class: 'throw-multiple-tokens', expected: ['throw-multiple-tokens', GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: {a: b} trailing\n---\nbody\n' },
  { id: 'throw-multiple-tokens-quote', class: 'throw-multiple-tokens', expected: ['throw-multiple-tokens', GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: "x" trailing\n---\nbody\n' },
  { id: 'throw-flow-dup', class: 'dup-key', expected: ['dup-key', GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: {a: 1, a: 2}\n---\nbody\n', note: 'yaml: Map keys must be unique in flow' },
  { id: 'throw-dup-key-block', class: 'dup-key', expected: ['dup-key'], expectedRelation: 'drop', content: '---\nname: x\nname: y\ndescription: z\n---\nbody\n' },
  { id: 'throw-dup-key-quoted', class: 'dup-key', expected: ['dup-key'], expectedRelation: 'drop', content: '---\nname: x\n"name": y\ndescription: z\n---\nbody\n', note: 'quoted key collides with plain key (probe)' },

  // ── TRUNCATE classes (P1 — pi loads with a corrupted value) ───────────────
  { id: 'truncate-hash', class: 'truncate-unquoted-hash', expected: ['truncate-unquoted-hash'], expectedRelation: 'load-with-truncation', content: '---\nname: x\ndescription: foo # bar\n---\nbody\n' },
  { id: 'truncate-hash-spacebefore', class: 'truncate-unquoted-hash', expected: ['truncate-unquoted-hash'], expectedRelation: 'load-with-truncation', content: '---\nname: x\ndescription: foo #bar\n---\nbody\n' },
  { id: 'truncate-hash-continuation', class: 'truncate-unquoted-hash', expected: ['truncate-unquoted-hash'], expectedRelation: 'load-with-truncation', content: '---\nname: x\ndescription: foo\n  bar # baz\n---\nbody\n', note: '# on a folded continuation line' },
  { id: 'truncate-fm-continuation', class: 'truncate-fm-continuation', expected: ['truncate-fm-continuation'], expectedRelation: 'ack-drift-flagged', content: '---\nname: x\ndescription: test\n---\n---\nsecond block\n', note: 'R3 — second frontmatter block at the top of the body; pi ignores it' },

  // ── string-type gate (P0 — pi drops via hasDescription) ───────────────────
  { id: 'gate-desc-absent', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\n---\nbody\n' },
  { id: 'gate-desc-null', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: null\n---\nbody\n' },
  { id: 'gate-desc-tilde', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: ~\n---\nbody\n' },
  { id: 'gate-desc-bool', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: TRUE\n---\nbody\n' },
  { id: 'gate-desc-int', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: 42\n---\nbody\n' },
  { id: 'gate-desc-neg-int', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: -42\n---\nbody\n' },
  { id: 'gate-desc-float', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: 1e3\n---\nbody\n' },
  { id: 'gate-desc-leading-zero', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: 0123\n---\nbody\n' },
  { id: 'gate-desc-hex', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: 0x1A\n---\nbody\n' },
  { id: 'gate-desc-octal', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: 0o17\n---\nbody\n' },
  { id: 'gate-desc-inf', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: .inf\n---\nbody\n' },
  { id: 'gate-desc-nan', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: .NaN\n---\nbody\n' },
  { id: 'gate-desc-flow-map', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: {a: b}\n---\nbody\n' },
  { id: 'gate-desc-flow-seq', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: [a, b]\n---\nbody\n' },
  { id: 'gate-desc-empty-quote', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: ""\n---\nbody\n' },
  { id: 'gate-desc-ws-quote', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: "   "\n---\nbody\n' },
  { id: 'gate-desc-empty-block', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: |\n---\nbody\n' },
  { id: 'gate-desc-nested-map', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription:\n  key: val\n---\nbody\n' },
  { id: 'gate-desc-block-seq', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription:\n  - a\n---\nbody\n' },
  { id: 'gate-desc-alias-int', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\na: &x 42\nname: x\ndescription: *x\n---\nbody\n', note: 'R4 — alias resolves to an int → non-string gate' },
  { id: 'gate-desc-alias-empty', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\na: &empty\nname: x\ndescription: *empty\n---\nbody\n', note: 'R4 — alias resolves to empty/null' },
  { id: 'gate-desc-alias-flow-map', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\na: &v {k: 1}\nname: x\ndescription: *v\n---\nbody\n', note: 'P1-2 — flow-map anchored value: alias must type as collection, not string (pi resolves the map → drops)' },
  { id: 'gate-desc-alias-flow-seq', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\na: &v [1, 2]\nname: x\ndescription: *v\n---\nbody\n', note: 'P1-2 — flow-seq anchored value → collection' },
  { id: 'gate-desc-alias-empty-quoted', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\na: &v ""\nname: x\ndescription: *v\n---\nbody\n', note: 'P1-2 — empty quoted anchored value → empty-string (pi loads "" and drops)' },
  { id: 'gate-desc-alias-comment', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\na: &v # comment\nname: x\ndescription: *v\n---\nbody\n', note: 'P1-2 — comment after the anchor name → null value' },
  { id: 'gate-desc-empty-block-blank', class: 'gate-description-nonstring', expected: [GD], expectedRelation: 'drop', content: '---\nname: x\ndescription: |\n\nother: y\n---\nbody\n', note: 'P1-1 — block scalar with only blank body resolves to "" → pi drops' },
  { id: 'gate-desc-root-seq', class: 'gate-description-nonstring', expected: [GD, GA], expectedRelation: 'drop', content: '---\n- item1\n- item2\n---\nbody\n', note: 'root seq parses to an array — no description key' },
  // name gates (R2 — pi loads with the dir-name fallback; linter stricter)
  { id: 'gate-name-nonstring', class: 'gate-name-nonstring', expected: ['gate-name-nonstring'], expectedRelation: 'ack-drift-flagged', content: '---\nname: 42\ndescription: test\n---\nbody\n' },
  { id: 'gate-name-empty', class: 'gate-name-empty', expected: ['gate-name-empty'], expectedRelation: 'ack-drift-flagged', content: '---\nname: ""\ndescription: test\n---\nbody\n' },
  { id: 'gate-name-absent', class: 'gate-name-absent', expected: ['gate-name-absent'], expectedRelation: 'ack-drift-flagged', content: '---\ndescription: test\n---\nbody\n' },

  // ── string forms that MUST stay strings (yaml core schema, probe) ─────────
  { id: 'str-underscore', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 1_000\n---\nbody\n' },
  { id: 'str-sexagesimal', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 190:20:30\n---\nbody\n' },
  { id: 'str-sexagesimal-float', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 1:20:30.5\n---\nbody\n' },
  { id: 'str-binary', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 0b101\n---\nbody\n' },
  { id: 'str-comma', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 1,000,000\n---\nbody\n' },
  { id: 'str-date', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 2026-08-28\n---\nbody\n' },
  { id: 'str-yes', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: yes\n---\nbody\n' },
  { id: 'str-on', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: on\n---\nbody\n' },
  { id: 'str-version', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: v1.2.3\n---\nbody\n' },
  { id: 'str-percent', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: 50% off\n---\nbody\n' },
  { id: 'str-colon-unspaced', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo:bar\n---\nbody\n' },
  { id: 'str-https', class: 'string', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: https://x.com/a\n---\nbody\n' },

  // ── OK / never-flag classes (zero findings, pi loads) ─────────────────────
  { id: 'ok-quoted-colon', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: "a: b # c"\n---\nbody\n' },
  { id: 'ok-single-quote', class: 'ok', expected: [], expectedRelation: 'load', content: "---\nname: x\ndescription: 'it''s fine'\n---\nbody\n" },
  { id: 'ok-quote-apostrophe-double', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: "don\'\'t"\n---\nbody\n' },
  { id: 'ok-block-content', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: |\n  line1\n  line2\n---\nbody\n' },
  { id: 'ok-block-minimal-indent', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: |\n line1\n line2\n---\nbody\n', note: 'P1-1 — body at the auto-detected contentIndent (1 space after a 0-indent key); pi loads' },
  { id: 'ok-block-minimal-folded', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: >\n folded\n text\n---\nbody\n', note: 'P1-1 — folded `>` with 1-space body' },
  { id: 'ok-block-explicit-indent-2', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: |2\n  line1\n  line2\n---\nbody\n', note: 'P1-1 — explicit indent indicator |2, body at exactly contentIndent' },
  { id: 'ok-block-explicit-keep-2', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: |+2\n  line1\n---\nbody\n', note: 'P1-1 — chomp+indent |+2' },
  { id: 'ok-block-folded-explicit-2', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: >2\n  folded\n  text\n---\nbody\n', note: 'P1-1 — folded with explicit indent >2' },
  { id: 'ok-block-dedent-content-indent', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: |2\n    line1\n  line2\n---\nbody\n', note: 'P1-1 — first line more-indented, later line dedents TO the explicit contentIndent; pi loads (extra spaces are content)' },
  { id: 'ok-block-folded', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: >\n  folded\n  text\n---\nbody\n' },
  { id: 'ok-flow-tags', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\ntags: [a, b]\n---\nbody\n' },
  { id: 'ok-nested-seq', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\nsteps:\n  - a\n  - b\n---\nbody\n' },
  { id: 'ok-list-maps', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\nsteps:\n  - name: a\n    type: skill\n  - name: b\n    type: skill\n---\nbody\n', note: 'live-corpus pattern (code-review et al.) — list of maps' },
  { id: 'ok-comment-line', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\n# comment\n---\nbody\n' },
  { id: 'ok-anchor-pair', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\nother: &a v\nother2: *a\n---\nbody\n' },
  { id: 'ok-alias-quoted-string', class: 'ok', expected: [], expectedRelation: 'load', content: '---\na: &v "x"\nname: x\ndescription: *v\n---\nbody\n', note: 'P1-2 — double-quoted anchored value → string (unquoted data "x")' },
  { id: 'ok-alias-single-quoted-string', class: 'ok', expected: [], expectedRelation: 'load', content: '---\na: &v \'y\'\nname: x\ndescription: *v\n---\nbody\n', note: 'P1-2 — single-quoted anchored value → string' },
  { id: 'ok-multiline-plain', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo\n  continued here\n---\nbody\n' },
  { id: 'ok-tab-mid-value', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo\tbar\n---\nbody\n' },
  { id: 'ok-brackets-mid', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo [a, b] bar\n---\nbody\n' },
  { id: 'ok-braces-nocolon', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo {bar} baz\n---\nbody\n' },
  { id: 'ok-dash-value', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: -item\n---\nbody\n' },
  { id: 'ok-apostrophe', class: 'ok', expected: [], expectedRelation: 'load', content: "---\nname: x\ndescription: l'intention\n---\nbody\n" },
  { id: 'ok-percent-mid', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo % bar\n---\nbody\n' },
  { id: 'ok-flow-key', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\n[key]: v\n---\nbody\n' },
  { id: 'ok-empty-value-key', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\nsteps:\n---\nbody\n' },
  { id: 'ok-dotted-key', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\nsubjects.team: org\n---\nbody\n' },
  { id: 'ok-quote-span', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: "a\n  b"\n---\nbody\n' },
  { id: 'ok-escaped-quote', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: "a\\"b"\n---\nbody\n' },
  { id: 'ok-quoted-comment', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: "foo" # comment\n---\nbody\n' },
  { id: 'ok-hash-nospace', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: foo#bar\n---\nbody\n' },
  { id: 'ok-doc-eof', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\n...\n---\nbody\n' },
  { id: 'ok-list-dup-keys', class: 'ok', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\nsteps:\n  - a: 1\n  - a: 2\n---\nbody\n', note: 'same key across list elements — fresh mapping per item' },

  // ── extraction edges ───────────────────────────────────────────────────────
  { id: 'extract-bom', class: 'extract', expected: ['bom-prefixed-frontmatter'], expectedRelation: 'ack-drift-flagged', content: '\ufeff---\nname: x\ndescription: test\n---\nbody\n', note: 'R5 — pi strips BOM and loads; linter flags as authoring strictness' },
  { id: 'extract-crlf', class: 'extract', expected: [], expectedRelation: 'load', content: '---\r\nname: x\r\ndescription: test\r\n---\r\nbody\r\n' },
  { id: 'extract-cr', class: 'extract', expected: [], expectedRelation: 'load', content: '---\rname: x\rdescription: test\r---\rbody\r' },
  { id: 'extract-opener-abc', class: 'extract', expected: ['throw-bare-key', GD], expectedRelation: 'drop', content: '---abc\nname: x\n---\nbody\n', note: '---abc opener — "abc" lands in the yamlString' },
  { id: 'extract-indented-dashes', class: 'extract', expected: ['throw-bare-key'], expectedRelation: 'drop', content: '---\nname: x\n  ---\nnot closing\ndescription: z\n---\nbody\n', note: 'indented --- folds into the plain scalar; not closing at col 0 → bare key' },
  { id: 'extract-missing-closing', class: 'extract', expected: ['extract-missing-closing'], expectedRelation: 'drop', content: '---\nname: x\ndescription: z' },
  { id: 'extract-empty', class: 'extract', expected: ['extract-empty'], expectedRelation: 'drop', content: '---\n---\nbody\n' },
  { id: 'extract-missing-opening', class: 'extract', expected: ['extract-missing-opening'], expectedRelation: 'drop', content: 'name: x\ndescription: z\n---\nbody\n' },
  { id: 'extract-second-dashes-mid-body', class: 'extract', expected: [], expectedRelation: 'load', content: '---\nname: x\ndescription: test\n---\nbody\n---\nmore\n', note: 'markdown horizontal rule in the body — inert for pi, not flagged (R3 narrowing)' },

  // ── deliberately-broken composites / multi-class ──────────────────────────
  { id: 'composite-broken', class: 'composite', expected: ['throw-unquoted-colon-value', 'gate-name-nonstring'], expectedRelation: 'drop', content: '---\nname: 42\ndescription: foo: bar\n---\nbody\n' },
  { id: 'composite-truncate', class: 'composite', expected: ['truncate-unquoted-hash'], expectedRelation: 'load-with-truncation', content: '---\nname: x\ndescription: foo # bar\nsteps:\n---\nbody\n' },
];

// ── probe runner ────────────────────────────────────────────────────────────
function recordPiConsequence(pi, content) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pi-fm-probe-'));
  const skillDir = path.join(dir, 'x');
  fs.mkdirSync(skillDir, { recursive: true });
  const full = content.endsWith('\n') ? content : `${content}\n`;
  fs.writeFileSync(path.join(skillDir, 'SKILL.md'), full);
  let parseErr = null;
  try {
    pi.parseFrontmatter(full);
  } catch (e) {
    parseErr = e.message.split('\n')[0];
  }
  const r = pi.loadSkillsFromDir({ dir, source: 'probe' });
  const skill = r.skills[0] ?? null;
  return {
    parseErr,
    loaded: !!skill,
    name: skill ? skill.name : null,
    description: skill ? skill.description : null,
    diagnostics: r.diagnostics.map((d) => d.message.split('\n')[0]),
  };
}

function fixtureModuleContent(records, piVersion) {
  const body = [
    '/**',
    ' * frontmatter-fixtures.mjs — probe-derived fixture matrix for #254.',
    ' *',
    ' * Generated by scripts/probe-frontmatter-fixtures.mjs --write against pi',
    ` * ${piVersion} (yaml ${records._yamlVersion ?? 'unknown'}). DO NOT hand-edit the`,
    ' * piConsequence records — re-run the probe (drift re-derivation is the',
    ' * intended workflow).',
    ' *',
    ' * Env-path BOM pin (D11): the oracle and probe exercise ONLY the node-fs',
    ' * loader path (loadSkillsFromDir, strips BOM). Env/session-path BOM',
    ' * behavior is bundle-version-dependent (conflicting evidence across probe',
    ' * sessions) — the R5 safe-direction rationale does not depend on it, and',
    ' * any future non-stripping parse variant is caught by the version-pin',
    ' * gate + re-probe precondition (Task 10).',
    ' */',
    '',
    `export const PI_VERSION_PIN = ${JSON.stringify(piVersion)};`,
    '',
    '// FUZZ_SEED — deterministic adversarial-fuzz leg (Task 10 d).',
    'export const FUZZ_SEED = 254;',
    '',
    `export const FIXTURES = ${JSON.stringify(records, null, 2)};`,
    '',
    '// ── fuzz-triage append region (--write-append; regenerate via probe --write) ──',
    'export const FUZZ_TRIAGE = [',
    '];',
    '',
  ].join('\n');
  return body;
}

async function main() {
  const write = process.argv.includes('--write');
  let pi;
  try {
    pi = await import(resolvePiBundle());
  } catch (e) {
    console.error(`❌ ${e.message}`);
    process.exit(2);
  }
  const piVersion = pi.VERSION ?? 'unknown';
  const yamlVersion = pi.YAML_VERSION ?? 'unknown';

  const records = FIXTURE_DEFS.map((def) => ({
    ...def,
    piConsequence: recordPiConsequence(pi, def.content),
  }));

  const outFile = path.join(path.dirname(fileURLToPath(import.meta.url)), 'frontmatter-fixtures.mjs');

  if (write) {
    const content = fixtureModuleContent(
      records.map(({ piConsequence, ...rest }) => ({ ...rest, piConsequence })),
      piVersion
    ).replace('records._yamlVersion', `'${yamlVersion}'`);
    fs.writeFileSync(outFile, content);
    console.log(`✅ wrote ${outFile} (${records.length} fixtures, pi ${piVersion}, yaml ${yamlVersion})`);
    process.exit(0);
  }

  // verify mode — compare live pi results against the committed records
  if (!fs.existsSync(outFile)) {
    console.error(`❌ ${outFile} not found — run with --write first`);
    process.exit(2);
  }
  const committed = (await import(outFile)).FIXTURES;
  const committedPin = (await import(outFile)).PI_VERSION_PIN;
  const byId = new Map(committed.map((c) => [c.id, c]));
  let mismatches = 0;
  for (const rec of records) {
    const old = byId.get(rec.id);
    if (!old) {
      console.error(`❌ ${rec.id}: missing from committed records`);
      mismatches++;
      continue;
    }
    const a = JSON.stringify({ loaded: rec.piConsequence.loaded, name: rec.piConsequence.name, description: rec.piConsequence.description, parseErr: rec.piConsequence.parseErr });
    const b = JSON.stringify({ loaded: old.piConsequence.loaded, name: old.piConsequence.name, description: old.piConsequence.description, parseErr: old.piConsequence.parseErr });
    if (a !== b) {
      console.error(`❌ ${rec.id}: pi consequence drift\n   live: ${a}\n   committed: ${b}`);
      mismatches++;
    }
  }
  if (piVersion !== committedPin) {
    console.error(`❌ pi version drift: live ${piVersion} vs committed pin ${committedPin} — re-probe deliberately`);
    mismatches++;
  }
  if (mismatches > 0) {
    console.error(`❌ ${mismatches} fixture(s) drifted from committed records — re-run with --write after review`);
    process.exit(1);
  }
  console.log(`✅ probe clean — ${records.length} fixtures match committed records (pi ${piVersion})`);
  process.exit(0);
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  await main();
}
