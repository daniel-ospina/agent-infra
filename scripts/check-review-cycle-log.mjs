#!/usr/bin/env node
/**
 * check-review-cycle-log.mjs — validate the review-loop cycle log (#665)
 *
 * AGENTS.md §Review Loop Protocol defines the cycle log's shape and requires a
 * machine-readable cycle record so the LOOP-LEVEL budget is checkable:
 *
 *   ## Review Cycle Log
 *
 *   | Gate | Cycle | Result |
 *   |---|---|---|
 *   | code-review | 1 | ISSUES FOUND — see fix round — code-review cycle 1 |
 *   ...
 *
 *   <!-- review-cycles
 *   cap: 4
 *   code-review: 2
 *   plan-review: 3 capped
 *   -->
 *
 * The defect this check exists to close (#637): the log carried two different
 * cycles both numbered "5" (a code-review cycle and a parallel-review-gate
 * cycle) and a cross-reference to a fix round that had never been written, and
 * nothing recorded the cycle count, so the 10-cycle runaway could not be
 * detected by any machine.
 *
 * Validated, per document that carries a cycle log (or a `review-cycles`
 * record):
 *
 *   R0 structure   — record block AND `| Gate | Cycle | Result |` table
 *                    (a record with no table, or a table with no record, is RED)
 *   R1 record      — `cap: <int>` (default 4) and `<gate>: <int> [capped] [cap=<int>]`
 *                    lines (a per-gate `cap=` overrides the record default, e.g.
 *                    plan-review's risk tiers)
 *   R2 count       — recorded count == the gate's data-row count; every table
 *                    gate is recorded; gates recorded with 0 cycles may have no
 *                    rows (the loop has not run yet)
 *   R3 unique      — within one gate, no cycle number appears twice
 *   R4 monotonic   — within one gate, cycle numbers strictly increase down the
 *                    table (the log is read as one table, top to bottom)
 *   R5 budget      — no gate exceeds `cap`; `capped` requires count == cap AND
 *                    the `⚠️ capped at N cycles — M issues remain` line
 *   R6 cross-refs  — every `see fix round …` reference is gate-qualified and
 *                    resolves to a `### Fix round — <gate> cycle <n>` heading
 *   R7 headings    — every fix-round heading is gate-qualified and its cycle
 *                    exists as a row in the table
 *
 * Legacy documents that predate the convention are listed in
 * scripts/review-cycle-log-baseline.txt. The baseline is stale-detecting: a
 * baselined doc that no longer exists, no longer carries a cycle log, or now
 * passes fully is itself a failure (remove the entry).
 *
 * Scope note: a doc is in scope only when it carries the convention's shape
 * (the exact heading, the conforming table header, or a `review-cycles` block).
 * The many pre-existing "Review Cycle Log" sections with other shapes
 * (e.g. `| Gate | Cycles |`) are not the protocol's artifact and are not
 * retro-validated — see the follow-up issue noted in the plan doc.
 *
 * Usage:
 *   node scripts/check-review-cycle-log.mjs [--root <path>] [--dir docs]
 *                                          [--baseline <path>] [--quiet]
 *
 * Exit codes: 0 = all in-scope logs well-formed, 1 = at least one failure,
 *             2 = usage/IO error.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_CAP = 4;

function parseArgs(argv) {
  const args = {
    root: REPO_ROOT,
    dir: "docs",
    baseline: "scripts/review-cycle-log-baseline.txt",
    quiet: false,
  };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--root":
        args.root = path.resolve(argv[++i]);
        break;
      case "--dir":
        args.dir = argv[++i];
        break;
      case "--baseline":
        args.baseline = argv[++i];
        break;
      case "--quiet":
        args.quiet = true;
        break;
      case "--help":
      case "-h":
        console.log(
          "Usage: node scripts/check-review-cycle-log.mjs [--root <path>] [--dir docs] [--baseline <path>] [--quiet]"
        );
        process.exit(0);
        break;
      default:
        console.error(`check-review-cycle-log: unknown argument "${argv[i]}"`);
        process.exit(2);
    }
  }
  return args;
}

// ── markdown helpers ────────────────────────────────────────────────────────

/** Mask fenced code blocks so examples (including this convention's own
 *  example block) are never parsed as a real record/table/heading. */
function maskFences(lines) {
  let fence = null;
  return lines.map((line) => {
    const m = line.match(/^\s*(`{3,}|~{3,})/);
    if (m) {
      const marker = m[1][0];
      if (!fence) {
        fence = marker;
        return { fenced: true, line };
      }
      if (marker === fence) {
        fence = null;
        return { fenced: true, line };
      }
    }
    return { fenced: Boolean(fence), line };
  });
}

/** Normalize a gate label to its slug id: drop backticks, drop parentheticals,
 *  lowercase, collapse non-alphanumerics to `-`. `code-review (PR #640)` →
 *  `code-review`. */
function gateId(raw) {
  return String(raw)
    .replace(/`/g, "")
    .replace(/\([^)]*\)/g, " ")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function splitRow(line) {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split("|").map((c) => c.trim());
}

function isSeparatorRow(cells) {
  return cells.length > 0 && cells.every((c) => /^:?-{1,}:?$/.test(c.trim()));
}

/** Parse every markdown table on unmasked lines. Returns
 *  [{ header: [cells], rows: [[cells]], startLine }]. */
function parseTables(masked) {
  const tables = [];
  let i = 0;
  while (i < masked.length) {
    if (masked[i].fenced || !/^\s*\|/.test(masked[i].line)) {
      i++;
      continue;
    }
    const start = i;
    const block = [];
    while (i < masked.length && !masked[i].fenced && /^\s*\|/.test(masked[i].line)) {
      block.push(masked[i].line);
      i++;
    }
    if (block.length < 2) continue;
    const header = splitRow(block[0]);
    const rest = block.slice(1);
    const rows = isSeparatorRow(splitRow(rest[0])) ? rest.slice(1) : rest;
    tables.push({ header, rows: rows.map(splitRow), startLine: start + 1 });
  }
  return tables;
}

const CYCLE_LOG_HEADER = ["gate", "cycle", "result"];

function normHeaderCell(cell) {
  return cell.replace(/[*`\s]/g, "").toLowerCase();
}

function isCycleLogTable(table) {
  return (
    table.header.length >= 3 &&
    table.header.slice(0, 3).map(normHeaderCell).join("|") === CYCLE_LOG_HEADER.join("|")
  );
}

// ── record parsing ─────────────────────────────────────────────────────────

function parseRecord(text) {
  // A record is a BLOCK comment: `review-cycles` on the opening line, then one
  // directive per line. The newline requirement keeps an inline prose mention
  // (`<!-- review-cycles … -->` inside a rule description) from matching.
  const matches = [...text.matchAll(/<!--\s*review-cycles[ \t]*\r?\n([\s\S]*?)-->/g)];
  if (matches.length === 0) return { present: false, errors: [], cap: DEFAULT_CAP, gates: {} };
  const errors = [];
  if (matches.length > 1) {
    errors.push(`found ${matches.length} \`review-cycles\` record blocks — exactly one is required`);
  }
  const body = matches[0][1];
  let cap = DEFAULT_CAP;
  const gates = {};
  for (const rawLine of body.split("\n")) {
    const line = rawLine.replace(/#.*$/, "").trim();
    if (line === "") continue;
    const m = line.match(/^([A-Za-z0-9_ -]+?)\s*:\s*(.+)$/);
    if (!m) {
      errors.push(`unparseable \`review-cycles\` line: "${rawLine.trim()}"`);
      continue;
    }
    const key = m[1].trim().toLowerCase();
    const value = m[2].trim();
    if (key === "cap") {
      if (!/^\d+$/.test(value)) {
        errors.push(`\`cap:\` must be an integer, got "${value}"`);
        continue;
      }
      cap = Number(value);
      continue;
    }
    const vm = value.match(/^(\d+)\b\s*(.*)$/);
    if (!vm) {
      errors.push(`\`${key}:\` must be \`<int>\` (optionally suffixed \`capped\` and/or \`cap=<int>\`), got "${value}"`);
      continue;
    }
    const rest = vm[2] ?? "";
    const capped = /\bcapped\b/.test(rest);
    const capMatch = rest.match(/\bcap\s*[:=]\s*(\d+)\b/);
    const residue = rest
      .replace(/\bcapped\b/g, "")
      .replace(/\bcap\s*[:=]\s*\d+\b/g, "")
      .replace(/[()\s,]/g, "");
    if (residue !== "") {
      errors.push(
        `\`${key}:\` has an unparseable suffix "${rest.trim()}" — allowed suffixes are \`capped\` and \`cap=<int>\``
      );
      continue;
    }
    const id = gateId(key);
    if (id in gates) errors.push(`duplicate \`review-cycles\` entry for gate "${id}"`);
    gates[id] = {
      key,
      count: Number(vm[1]),
      capped,
      cap: capMatch ? Number(capMatch[1]) : null,
    };
  }
  return { present: true, errors, cap, gates };
}

// ── per-document validation ────────────────────────────────────────────────

const CAPPED_LINE_RE = /capped at\s+(\d+)\s+cycles?\s*[—–-]\s*(\d+)\s+issues?\s+remain/i;
const FIX_ROUND_HEADING_RE = /^#{2,4}\s+Fix[-\s]+round\b(.*)$/;
const CYCLE_IN_TEXT_RE = /\b([A-Za-z][A-Za-z0-9 _-]*?)\s+cycle\s+(\d+)(?:\s*[–—→-]\s*(\d+))?/i;
const HASH_CYCLE_RE = /\b([a-z0-9][a-z0-9-]*)#(\d+)\b/;

function analyzeDocument(text) {
  const lines = text.split("\n");
  const masked = maskFences(lines);
  const unmasked = masked.filter((m) => !m.fenced).map((m) => m.line);

  const headingRe = /^#{2,3}\s+Review Cycle Log\s*$/;
  const hasHeading = unmasked.some((l) => headingRe.test(l));
  const tables = parseTables(masked).filter(isCycleLogTable);
  // Multiple conforming tables: their rows are read as ONE log (the convention
  // says the log is read as one table). Ambiguity is a failure.
  const record = parseRecord(masked.filter((m) => !m.fenced).map((m) => m.line).join("\n"));
  const inScope = hasHeading || tables.length > 0 || record.present;
  return { inScope, hasHeading, tables, record, unmasked };
}

function validateDocument(relPath, doc) {
  const errors = [];
  const { tables, record } = doc;

  if (!record.present) {
    errors.push(
      "has a cycle log but no `<!-- review-cycles … -->` record — the loop budget is not machine-checkable " +
        "(AGENTS.md §Review Loop Protocol)"
    );
  }
  if (tables.length === 0) {
    errors.push(
      "has a `review-cycles` record (or Review Cycle Log heading) but no `| Gate | Cycle | Result |` table"
    );
  }
  errors.push(...record.errors);

  // Flatten rows, keyed by gate slug.
  const rowsByGate = new Map();
  for (const table of tables) {
    for (const row of table.rows) {
      if (row.length < 2) continue;
      const id = gateId(row[0]);
      if (id === "") continue;
      const cm = row[1].match(/^\s*(?:cycle\s*)?(\d+)\b/i);
      if (!cm) {
        errors.push(`row \`${row[0]} | ${row[1]}\`: Cycle cell has no integer`);
        continue;
      }
      if (!rowsByGate.has(id)) rowsByGate.set(id, []);
      rowsByGate.get(id).push({ gate: row[0].trim(), cycle: Number(cm[1]), cells: row });
    }
  }

  // R3 unique + R4 monotonic.
  for (const [id, rows] of rowsByGate) {
    const seen = new Map();
    for (const r of rows) {
      if (seen.has(r.cycle)) {
        errors.push(
          `duplicate cycle number \`${id}#${r.cycle}\` — cycle numbering is per gate and unique ` +
            "(two different cycles numbered the same is the #637 defect)"
        );
      } else {
        seen.set(r.cycle, r);
      }
    }
    for (let i = 1; i < rows.length; i++) {
      if (rows[i].cycle <= rows[i - 1].cycle) {
        errors.push(
          `\`${id}\` cycle numbers not strictly increasing (${rows[i - 1].cycle} then ${rows[i].cycle}) — ` +
            "the log is read as one table, top to bottom"
        );
      }
    }
  }

  // R2 count agreement.
  const presentGates = new Set(rowsByGate.keys());
  for (const [id, entry] of Object.entries(record.gates)) {
    if (entry.count === 0) continue;
    const rows = rowsByGate.get(id)?.length ?? 0;
    if (rows !== entry.count) {
      errors.push(
        `record says \`${id}: ${entry.count}\` but the table has ${rows} row(s) for that gate`
      );
    }
  }
  for (const id of presentGates) {
    if (!(id in record.gates)) {
      errors.push(
        `gate \`${id}\` appears in the table but not in the \`review-cycles\` record`
      );
    }
  }

  // R5 budget. A gate's effective budget is its own `cap=` (e.g. plan-review's
  // risk tier) or the record-level `cap:`.
  const cap = record.cap;
  for (const [id, entry] of Object.entries(record.gates)) {
    const gateCap = entry.cap ?? cap;
    if (entry.count > gateCap) {
      errors.push(
        `gate \`${id}\` ran ${entry.count} cycles — over the loop budget (cap: ${gateCap}). ` +
          "The budget is loop-level and NOT reset by dispatching a fresh reviewer (AGENTS.md §Loop Budget)"
      );
    }
    if (entry.capped) {
      if (entry.count !== gateCap) {
        errors.push(
          `gate \`${id}\` is marked \`capped\` but ran ${entry.count} of ${gateCap} cycles — ` +
            "`capped` means the loop ended at the budget"
        );
      }
      const cappedLine = (doc.unmasked.join("\n").match(CAPPED_LINE_RE) ?? [])[0];
      if (!cappedLine) {
        errors.push(
          `gate \`${id}\` is marked \`capped\` but the artifact has no ` +
            "`⚠️ capped at N cycles — M issues remain` line"
        );
      } else if (Number(cappedLine.match(CAPPED_LINE_RE)[1]) !== entry.count) {
        errors.push(
          `\`capped at\` line says ${cappedLine.match(CAPPED_LINE_RE)[1]} cycles but the record says ${entry.count}`
        );
      }
    }
  }

  // R7 fix-round headings + R6 cross-reference resolution.
  const headingKeys = new Set();
  for (const line of doc.unmasked) {
    const hm = line.match(FIX_ROUND_HEADING_RE);
    if (!hm) continue;
    const body = hm[1];
    const cm = body.match(CYCLE_IN_TEXT_RE) ?? body.match(HASH_CYCLE_RE);
    if (!cm) {
      errors.push(
        `fix-round heading is not gate-qualified: "${line.trim()}" — use ` +
          "`### Fix round — <gate> cycle <n>`"
      );
      continue;
    }
    const id = gateId(cm[1]);
    const start = Number(cm[2]);
    const end = cm[3] ? Number(cm[3]) : start;
    for (let n = start; n <= end; n++) {
      headingKeys.add(`${id}#${n}`);
      if (!(rowsByGate.get(id) ?? []).some((r) => r.cycle === n)) {
        errors.push(
          `fix-round heading "${line.trim()}" refers to \`${id}#${n}\`, which has no row in the cycle log ` +
            "(a cross-referenced fix round that was never written is the #637 defect)"
        );
      }
    }
  }

  for (const [id, rows] of rowsByGate) {
    for (const r of rows) {
      const resultCell = r.cells.slice(2).join(" | ");
      for (const m of resultCell.matchAll(/\bsee\s+fix[-\s]+round\s*([^|]*)/gi)) {
        const tail = m[1];
        if (/^\s*[—–:-]?\s*\d+\b/.test(tail)) {
          errors.push(
            `\`${id}#${r.cycle}\` cross-reference "see fix round ${tail.trim()}" is not gate-qualified — ` +
              "use `see fix round — <gate> cycle <n>` (a bare number does not resolve when the log is read as one table)"
          );
          continue;
        }
        const qm = tail.match(CYCLE_IN_TEXT_RE) ?? tail.match(HASH_CYCLE_RE);
        if (!qm) {
          errors.push(
            `\`${id}#${r.cycle}\` cross-reference "see fix round${tail}" does not resolve to a gate-qualified cycle reference`
          );
          continue;
        }
        const ref = `${gateId(qm[1])}#${Number(qm[2])}`;
        if (!headingKeys.has(ref)) {
          errors.push(
            `\`${id}#${r.cycle}\` cross-reference "${ref}" has no matching \`### Fix round — …\` heading`
          );
        }
      }
    }
  }

  return errors;
}

// ── baseline ───────────────────────────────────────────────────────────────

function readBaseline(baselinePath) {
  if (!fs.existsSync(baselinePath)) return [];
  return fs
    .readFileSync(baselinePath, "utf8")
    .split("\n")
    .map((l) => l.replace(/#.*$/, "").trim())
    .filter((l) => l !== "");
}

// ── walk ───────────────────────────────────────────────────────────────────

function walkMarkdown(root, dir) {
  const out = [];
  const base = path.join(root, dir);
  const stack = [base];
  while (stack.length) {
    const cur = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(cur, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.name === "node_modules" || e.name === ".git" || e.name.startsWith(".")) continue;
      const full = path.join(cur, e.name);
      if (e.isDirectory()) stack.push(full);
      else if (e.isFile() && e.name.endsWith(".md")) out.push(full);
    }
  }
  return out.sort();
}

// ── main ───────────────────────────────────────────────────────────────────

function main() {
  const args = parseArgs(process.argv.slice(2));
  const docsDir = path.join(args.root, args.dir);
  if (!fs.existsSync(docsDir)) {
    console.error(`check-review-cycle-log: directory not found: ${docsDir}`);
    process.exit(2);
  }
  const baseline = readBaseline(path.join(args.root, args.baseline));
  const baselineSet = new Set(baseline);
  const scanned = walkMarkdown(args.root, args.dir);

  const failures = [];
  const validated = [];
  const usedBaseline = new Set();

  for (const file of scanned) {
    const rel = path.relative(args.root, file).split(path.sep).join("/");
    const doc = analyzeDocument(fs.readFileSync(file, "utf8"));
    if (!doc.inScope) continue;

    if (baselineSet.has(rel)) {
      usedBaseline.add(rel);
      // Stale-entry detection: exempt only while it still needs the exemption.
      const errors = validateDocument(rel, doc);
      if (errors.length === 0) {
        failures.push(
          `${rel}: listed in ${args.baseline} but now passes — remove the stale baseline entry`
        );
      }
      continue;
    }

    const errors = validateDocument(rel, doc);
    if (errors.length) failures.push(`${rel}:\n    - ${errors.join("\n    - ")}`);
    else validated.push(rel);
  }

  for (const entry of baseline) {
    if (!usedBaseline.has(entry)) {
      if (!fs.existsSync(path.join(args.root, entry))) {
        failures.push(`${entry}: baseline entry points at a missing file — remove it from ${args.baseline}`);
      } else {
        failures.push(
          `${entry}: baseline entry no longer resolves to an in-scope cycle log — remove it from ${args.baseline}`
        );
      }
    }
  }

  if (!args.quiet) {
    console.log(
      `check-review-cycle-log: ${scanned.length} markdown file(s) scanned, ` +
        `${validated.length + usedBaseline.size} cycle log(s) in scope ` +
        `(${validated.length} validated, ${usedBaseline.size} baselined)`
    );
    for (const v of validated) console.log(`  ✅ ${v}`);
    for (const b of usedBaseline) console.log(`  ⏭️  ${b} (baseline — see follow-up issue)`);
  }

  if (failures.length) {
    console.error("");
    for (const f of failures) console.error(`❌ ${f}`);
    console.error(
      `\n❌ review cycle log check failed (${failures.length} document(s)) — see ` +
        "AGENTS.md §Review Loop Protocol §Cycle Log for the convention"
    );
    process.exit(1);
  }
  if (!args.quiet) console.log("✅ all review cycle logs are well-formed and within budget");
  process.exit(0);
}

// Only run when executed directly — the fixture suite imports the helpers.
const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) main();

export { analyzeDocument, validateDocument, parseRecord, gateId, DEFAULT_CAP };
