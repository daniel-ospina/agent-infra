#!/usr/bin/env node
// tests/ci-trigger-scope/check.mjs — the STRUCTURAL half of the pin for agent-infra#3196.
//
// WHAT THIS ANSWERS, and deliberately nothing more: "do these two workflow FILES still declare
// the trigger values the reduction was decided on?". It reads YAML, it does NOT model GitHub's
// glob semantics — path ADMISSION is answered by `scripts/ci-workflow-pr-evaluable.sh`, the one
// predicate the merge rail already uses, so there is no second implementation of `paths:`
// matching to drift from the first. `run.sh` drives both halves.
//
// ⛔ WHY EVERY ARGUMENT IS AN ENV VAR. The test's load-bearing arms are MUTATIONS: it copies a
// live workflow, breaks one thing, and re-runs THIS program. A mutation arm that ran a
// re-implementation of the check would prove that the re-implementation can fail, which is
// nothing. So the file paths are overridable and the mutant runs the same bytes.
//
// EXIT CODES — a reader that cannot answer must never spell the answer "passed":
//   0  every fact this program reads is as decided
//   1  at least one finding (each printed and named)
//   2  a file was missing/unreadable, or its `on:` region did not fit the shape this reader
//      models — i.e. CANNOT VERIFY, which is not a pass
//
// The reader is a strict line reader over a narrow slice of YAML (a top-level `on:` whose value
// is a block mapping of trigger names, each of whose values is a block mapping of filter keys
// with a flow list or a block sequence). Anything outside that returns exit 2 rather than a
// guess — the over-block direction, because a green over a shape this program did not read is
// the fail-open this file exists to prevent.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");

const WL_FILE = process.env.WL_FILE || path.join(ROOT, ".github/workflows/workflow-lock.yml");
const HSS_FILE =
  process.env.HSS_FILE || path.join(ROOT, ".github/workflows/harness-single-source.yml");
const PC_FILE =
  process.env.PC_FILE || path.join(ROOT, ".github/workflows/pipeline-compliance.yml");

// The decided `types:` for the base-branch checker. `edited` is the whole point (#3196): it is
// the body-edit activity `scripts/record-review.sh` fires on every record that APPENDS the marker
// (it PATCHes only while the marker is absent), and it cannot change the merge result this job
// validates.
const WL_EXPECTED_TYPES = ["opened", "synchronize", "reopened"];

const findings = [];

function refuse(msg) {
  process.stdout.write(`CANNOT-VERIFY: ${msg}\n`);
  process.exit(2);
}

function read(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (e) {
    refuse(`${file}: ${e.code || e.message}`);
  }
}

const blank = (raw) => /^[ \t]*$/.test(raw);
const comment = (raw) => /^[ \t]*#/.test(raw);
const indentOf = (raw) => /^([ \t]*)/.exec(raw)[1].length;
const unquote = (s) => {
  const t = s.trim();
  if (t.length >= 2 && t[0] === t[t.length - 1] && (t[0] === "'" || t[0] === '"')) {
    return t.slice(1, -1);
  }
  return t;
};

// onRegion(line, file) — the content lines strictly inside the top-level `on:` block.
// A top-level key at column 0 ends the region. The `on:` key itself may be quoted
// (YAML 1.1 parses a bare `on` as the boolean true, and some formatters quote it).
function onRegion(text, file) {
  const lines = text.split("\n");
  // ⛔ THE KEY NAME IS PARSED, NOT MATCHED AGAINST A LIST OF SPELLINGS. `/^(?:"on"|'on'|on):/` demanded
  // the colon abutting the name, so `on :` — the SAME key in YAML — slipped past the duplicate guard
  // below and the reader inspected the FIRST block: appending `on :` carrying `push:` read green with
  // an effective key set of `['push']` (measured), which is the surface the 7f pin exists for. KEY_RE
  // already tolerates `[ \t]*:` and every quoting, so the name is read out of the line.
  const topLevelKeyName = (raw) => {
    const m = KEY_RE.exec(raw);
    return m && m[1].length === 0 ? (m[2] ?? m[3] ?? m[4] ?? "").trim() : null;
  };
  const onStarts = lines.map((raw, i) => (topLevelKeyName(raw) === "on" ? i : -1)).filter((i) => i >= 0);
  // ⛔ AND A DUPLICATE TOP-LEVEL `jobs:` IS THE SAME ROOT AT THE LEVEL ABOVE THE JOB ID. YAML keeps the
  // LAST `jobs:` and discards the rest, so a second block redefines `pipeline-compliance` with no
  // `if:` at all — and every header in it sits at the same indent, so a reader that only counted job
  // ids inside the FIRST block found one header, skipped the guard, and read green over an effective
  // `if` of ABSENT (measured). Counting the container is what makes the job-id check meaningful.
  const jobsStarts = lines
    .map((raw, i) => (topLevelKeyName(raw) === "jobs" ? i : -1))
    .filter((i) => i >= 0);
  if (jobsStarts.length > 1) {
    refuse(
      `${file}: \`jobs:\` appears ${jobsStarts.length} times (lines ${jobsStarts
        .map((i) => i + 1)
        .join(", ")}). YAML keeps only the LAST, so no job block read below is the one in force — the guard is UNVERIFIED.`
    );
  }
  // ⛔ A DUPLICATE TOP-LEVEL `on:` IS LAST-WINS IN YAML, and a first-match reader reads the WRONG
  // block: appending a second `on:` carrying `push:` leaves this pin inspecting the first one and
  // reporting green (measured: rc=0 while the effective key set was ['push', 'pull_request']). Same
  // duplicate-key/last-wins root as the duplicate JOB id below, and the same answer — refuse, because
  // which block is in force is not something this reader can answer (rc 2).
  if (onStarts.length > 1) {
    refuse(
      `${file}: \`on:\` appears ${onStarts.length} times (lines ${onStarts
        .map((i) => i + 1)
        .join(", ")}). YAML keeps only the LAST, so which trigger set is in force is not something this reader can answer — the trigger scope is UNVERIFIED.`
    );
  }
  const start = onStarts.length === 1 ? onStarts[0] : -1;
  if (start < 0) refuse(`${file}: no top-level \`on:\` key — nothing to read`);
  const region = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    const raw = lines[i];
    if (blank(raw) || comment(raw)) continue;
    if (indentOf(raw) === 0) break;
    region.push({ raw, indent: indentOf(raw), no: i + 1 });
  }
  if (region.length === 0) refuse(`${file}: the \`on:\` block has no triggers — nothing to read`);
  const childIndent = Math.min(...region.map((l) => l.indent));
  return { region, childIndent };
}

const KEY_RE = /^([ \t]*)(?:"([^"]*)"|'([^']*)'|([A-Za-z0-9_.-]+))[ \t]*:(.*)$/;

// onKeys(region, childIndent) — the trigger NAMES declared under `on:`.
//
// ⛔ WHY THE `on:` KEY SET IS PINNED TOO (review of the last delta, P2). Pinning a trigger's own
// filter keys is not enough: a SECOND trigger added beside it re-opens everything the first one
// closes. Measured before this: adding `on.pull_request: types: [edited]` next to a correctly
// pinned `pull_request_target:` left every suite green (the pin suite 124/124, this shard 33/33,
// and the content lock untouched — `workflow-lock.yml` is not one of the three locked paths), so
// `edited` was silently re-addable one line away from the assertion that says it is gone. A
// `pull_request:` trigger on `workflow-lock.yml` would ALSO collapse its trust split.
function onKeys(region, childIndent) {
  const own = region.filter((l) => l.indent === childIndent);
  // ⛔ A LINE THE READER CANNOT CLASSIFY IS CANNOT-VERIFY, NEVER A SILENT DROP. `.filter((k) => k !==
  // null)` discarded every line KEY_RE did not match — and YAML's EXPLICIT-KEY syntax (`? push`) is
  // legal, so a trigger written that way was invisible while being effective (measured: PyYAML key set
  // `['workflow_call','pull_request','issue_comment','push']`, gate read green). Dropping an
  // unparsed line is how a gate reports "as decided" about a file it did not fully read.
  return own.map((l) => {
    const k = keyOf(l);
    if (k === null) {
      refuse(
        `${l.no === undefined ? "" : `line ${l.no}: `}cannot read the key on ${JSON.stringify(
          l.raw
        )} under \`on:\` (YAML explicit-key syntax and other shapes this reader does not model). The trigger set is therefore UNVERIFIED.`
      );
    }
    return k.key;
  });
}

function keyOf(line) {
  const m = KEY_RE.exec(line.raw);
  if (!m) return null;
  return { key: m[2] ?? m[3] ?? m[4], value: m[5] };
}

// subtree(region, startIdx, parentIndent) — the content lines owned by region[startIdx].
function subtree(region, startIdx, parentIndent) {
  const out = [];
  for (let i = startIdx + 1; i < region.length; i += 1) {
    if (region[i].indent <= parentIndent) break;
    out.push(region[i]);
  }
  return out;
}

// filterKeys(lines) — the depth-1 keys of a trigger's value, and their raw lines.
function filterKeys(lines) {
  if (lines.length === 0) return null;
  const childIndent = Math.min(...lines.map((l) => l.indent));
  const out = [];
  lines.forEach((l, i) => {
    if (l.indent !== childIndent) return;
    const k = keyOf(l);
    if (!k) refuse(`unparseable line ${l.no}: ${JSON.stringify(l.raw)}`);
    out.push({ ...k, line: l, idx: i, childIndent });
  });
  return out;
}

// valueLinesFor(entry, lines) — the lines that belong to ONE key's value.
//
// ⛔ TAKE-WHILE, NOT FILTER (review cycle 2, P2). The predecessor was
// `lines.slice(entry.idx + 1).filter(l => l.indent > entry.line.indent)`, and a SIBLING key's block
// sequence also sits deeper than the preceding key's line — so a `paths:` list appended after `types:`
// was attributed to `types:`, and the printed list was FABRICATED. It was a fail-open in the other
// direction too: a `types:` with no items followed by `branches: [- edited]` reported
// `types: … edited` and exited 0, i.e. the required context read GREEN while its `types:` declared
// nothing. A block sequence ENDS at the first line that is not deeper than its key.
function valueLinesFor(entry, lines) {
  const out = [];
  for (const l of lines.slice(entry.idx + 1)) {
    if (l.indent <= entry.line.indent) break;
    out.push(l);
  }
  return out;
}

// readList(entry, valueLines) — a flow list on the key's own line, or a block sequence below it.
// Returns string[]; refuses anything else (see the exit-2 note in the header).
function readList(entry, valueLines) {
  const value = entry.value.trim();
  if (value) {
    const m = /^\[(.*)\]$/.exec(value);
    if (!m) refuse(`line ${entry.line.no}: the value of \`${entry.key}:\` is ${JSON.stringify(value)} — not a flow list`);
    return m[1]
      .split(",")
      .map(unquote)
      .filter((s) => s.length > 0);
  }
  const items = [];
  for (const l of valueLines) {
    const m = /^[ \t]*-[ \t]+(.*)$/.exec(l.raw);
    if (!m) refuse(`line ${l.no}: expected a \`- item\` block-sequence entry, got ${JSON.stringify(l.raw)}`);
    const v = unquote(m[1]);
    if (v) items.push(v);
  }
  return items;
}

// trigger(region, childIndent, name, file) — the named trigger's filter keys, or a refusal.
function trigger(region, childIndent, name, file) {
  const idx = region.findIndex((l) => {
    if (l.indent !== childIndent) return false;
    const k = keyOf(l);
    return k !== null && k.key === name;
  });
  if (idx < 0) refuse(`${file}: declares no \`${name}:\` trigger under \`on:\``);
  const entry = { ...keyOf(region[idx]), line: region[idx] };
  const value = entry.value.trim();
  if (value) refuse(`${file}: \`${name}:\` carries the inline value ${JSON.stringify(value)} — this reader models only a block mapping there`);
  const lines = subtree(region, idx, childIndent);
  const keys = filterKeys(lines);
  return { lines, keys: keys || [] };
}

// extraFilters(keys, parent) — the filter keys a trigger declares that the caller does not allow.
// A `paths:`/`paths-ignore:` on a gate WIDENS nothing: it NARROWS what the gate observes, silently,
// while every assertion about the trigger still reads true (#1542's over-block class). On a required
// context it is worse than silent — GitHub keeps a path-filtered workflow's checks "Pending", so the
// context never reports and never merges.
function extraFilters(keys, allowed) {
  return keys.map((k) => k.key).filter((k) => !allowed.includes(k));
}

// extraSet(names, allowed) — the same difference for a plain list of trigger NAMES.
function extraSet(names, allowed) {
  return names.filter((n) => !allowed.includes(n));
}

// jobBlock(text, name) — the lines of ONE job under `jobs:`, from its `  <name>:` header up to the next
// job header (or end of file). Needed because this file asserts things about a SPECIFIC job, and a
// whole-file `includes()`/regex is satisfied by an identical line in a DIFFERENT job — measured here:
// `if: github.event_name != 'issue_comment'` appears on BOTH `pipeline-compliance` and
// `workflow-drift`, so a text-wide match would have reported the required job guarded while its own
// guard was gone. Scoping by job is what makes the guard assertion non-vacuous.
// jobsBounds(lines) — [start, end) of the single top-level `jobs:` block.
//
// ⛔ A 2-SPACE KEY IS NOT NECESSARILY A JOB. `permissions:` declares its children at two spaces too
// (`  contents: read`), so scanning the whole file for "a key at indent 2" read `contents`, `issues`
// and `pull-requests` as jobs — harmless while the check only compared names, but a refusal keyed on a
// job HEADER's shape fired on `contents: read` and red the live workflow (measured). Job headers are the
// indent-2 keys INSIDE `jobs:`, and nothing else.
function jobsBounds(lines) {
  let start = -1;
  for (let i = 0; i < lines.length; i += 1) {
    const m = KEY_RE.exec(lines[i]);
    if (m && m[1].length === 0 && (m[2] ?? m[3] ?? m[4]) === "jobs") {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i += 1) {
    const m = KEY_RE.exec(lines[i]);
    if (m && m[1].length === 0) {
      end = i;
      break;
    }
  }
  return { start, end };
}

function jobBlock(text, name) {
  const lines = String(text ?? "").split("\n");
  // ⛔ THE START IS FOUND BY THE SAME RULE AS THE TERMINATOR: the indent SHAPE, then the key NAME read
  // out of the line — never an enumerated list of header spellings. A spellings regex
  // (`  name:`, `  "name":`) is the exact anti-pattern the terminator comment below calls out, and it
  // reopened the duplicate-job-id fail-open ONE CHARACTER away: `  pipeline-compliance :` (space before
  // the colon), `  pipeline-compliance: &anchor` and `  pipeline-compliance: {name: x}` all matched the
  // TERMINATOR but not the start rule, so `starts` saw a single header, the duplicate guard was
  // skipped, and the reader answered about the FIRST (guarded) block while YAML's effective job was
  // the LAST one — with `if: true`, or with no `if:` at all. Measured: rc=0 over an effective `if` of
  // `True`. KEY_RE is the one key reader this file already uses; it tolerates quotes, whitespace
  // before the colon, and any value shape.
  const bounds = jobsBounds(lines);
  const inJobs = (i) => bounds !== null && i > bounds.start && i < bounds.end;
  const nameOfJobHeader = (line) => {
    const m = KEY_RE.exec(line);
    if (!m || m[1].length !== 2) return null; // job headers sit at 2 spaces, one level under `jobs:`
    return (m[2] ?? m[3] ?? m[4] ?? "").trim();
  };
  // ⛔ AND AN UNCLASSIFIABLE 2-SPACE LINE IS CANNOT-VERIFY, for the same reason as `onKeys`: YAML's
  // explicit-key form (`  ? pipeline-compliance` / `  : {if: true}`) is a legal job header this reader
  // does not model, and skipping it made a duplicate job id — and therefore an effective `if` of
  // `True` — invisible. Anything at a job header's own indent that is not a key we can read means the
  // job set is not fully understood, and a partially-read job set must not answer "green".
  lines.forEach((l, i) => {
    if (!inJobs(i)) return; // outside `jobs:` a 2-space key is some other block's child
    if (nameOfJobHeader(l) !== null) return;
    const m = KEY_RE.exec(l);
    if (m && m[1].length === 2) return; // a readable sibling key: fine
    // ⛔ NOT GATED ON THE HEADER INDENT. Gating on 2 spaces refused `  ? push` (a trigger) and
    // `  ? pipeline-compliance` (a job id) but left the JOB KEY indent (4) unguarded, so
    //     if: github.event_name != 'issue_comment'
    //     ? if
    //     : true
    // was neither matched by `ownRe` NOR refused — gate ok/rc=0 while YAML's effective `if` is `True`,
    // i.e. the required job runs on the comment event. That is the same fail-open one indent below the
    // shape that was already refused. Both indents that can hold a KEY, plus the step-item indent,
    // are refused here because an explicit key is never modelled anywhere in this reader.
    if (/^ {2,6}[?:](?:\s|$)/.test(l)) {
      refuse(
        `line ${i + 1}: cannot read the key ${JSON.stringify(
          l
        )} — YAML explicit-key syntax is not modelled, so the job is UNVERIFIED.`
      );
    }
  });
  const starts = lines
    .map((l, i) => ({ l, i }))
    .filter(({ l, i }) => inJobs(i) && nameOfJobHeader(l) === name)
    .map(({ i }) => i);
  // ⛔ A DUPLICATE JOB ID IS LAST-WINS in YAML, and a first-match reader answers about the WRONG job.
  // Measured: a second `  pipeline-compliance:` appended with no `if:` at all leaves the effective
  // `if` ABSENT — i.e. the job RUNS on the comment event — while this reader inspected the FIRST
  // block, found the guard, and reported ok/rc=0. The same class the duplicate-`if:` arms close one
  // level down; one level up it was open. A reader that cannot answer the question it was asked must
  // say so (rc 2), never answer "green".
  if (starts.length > 1) {
    refuse(
      `${PC_FILE}: \`${name}\` appears as a JOB ID ${starts.length} times (lines ${starts
        .map((i) => i + 1)
        .join(", ")}). YAML keeps only the LAST, so which block is in force is not something this reader can answer — the guard is UNVERIFIED.`
    );
  }
  const start = starts.length === 1 ? starts[0] : -1;
  // ⛔ Cannot-locate is NOT "the guard is missing". A reader that cannot find the job it was asked
  // about has to say so (rc 2), because reporting it as a guard FINDING sends the reader after a
  // fault that does not exist.
  if (start < 0) refuse(`${PC_FILE}: no \`${name}\` job found under \`jobs:\` — cannot verify its \`if:\``);
  let end = bounds ? Math.min(lines.length, bounds.end) : lines.length;
  for (let i = start + 1; i < end; i++) {
    // ⛔ ANY 2-space-indent YAML key ends the job — matched by INDENT, not by header SHAPE. An
    // enumerated-shape terminator (`bare`, `# comment`, `"quoted"`) is a list of the spellings someone
    // thought of, and every spelling it omits lets the block over-extend into a LATER job, where that
    // job's guard satisfies an assertion about THIS one — the fail-open direction. Measured: with the
    // guard deleted and the two intervening headers written as flow mappings
    // (`  revalidate-on-issue-comment: {name: r}`), an enumerated terminator matched neither, the block
    // ran on into `workflow-drift`'s guard, and the arm read ok/rc=0.
    // A job's own children live at 4 spaces, so a non-space, non-`#`, non-`-` character at column 2 is
    // a sibling key and nothing else.
    if (/^ {2}[^\s#-]/.test(lines[i])) { end = i; break; }
  }
  return lines.slice(start, end).join("\n");
}

// jobKeyIs(block, key, valueRe) — does THIS job's own `key:` line (at the job's key indent, i.e. one
// level deeper than the job header) match `valueRe`?
//
// ⛔ NOT a text search, and the difference is a fail-open rather than tidiness. `^\s*if:` matches a
// STEP's `if:` just as well as the job's, so a whole-block text match reports the required job guarded
// while the job itself carries no `if:` at all and therefore RUNS on the comment event. Measured: move
// `if: github.event_name != 'issue_comment'` from the job to its first step and a text-wide matcher
// returns ok/rc=0. The key indent is what distinguishes the two, so it is what is asserted.
// jobIfExprs(block) — the YAML-FOLDED value of each own-level `if:` in a job block, ONE entry per
// occurrence. A separate reader from `jobKeyIs` on purpose: that one refuses an `if: >-` BLOCK SCALAR
// for the REQUIRED job's guard (a `>-` body of `guard` + `|| true` folds to TRUE, and its arms pin the
// refusal), while the revalidation job's own `if:` IS a block scalar in the live file. Stripping a
// leading block indicator here does not weaken that refusal: it is applied to a DIFFERENT job, whose
// predicates are required as a conjunction and whose disjunctions are refused below.
function jobIfExprs(block) {
  const lines = String(block ?? "").split("\n");
  const headerIndent = (lines[0] ?? "").length - (lines[0] ?? "").trimStart().length;
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*)(?:"if"|'if'|if)\s*:(.*)$/.exec(lines[i]);
    if (!m) continue;
    const keyIndent = m[1].length;
    // A job's own `if:` is deeper than its header. Anything at or left of the header belongs to
    // `jobs:` or to the previous job, and must not be read as this job's.
    if (keyIndent <= headerIndent) continue;
    let v = m[2].trim();
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === "" || /^\s*#/.test(l)) continue;
      if (l.length - l.trimStart().length <= keyIndent) break;
      v += (v === "" ? "" : " ") + l.trim();
    }
    v = v.replace(/^(?:[>|][+-]?\d?)\s*/, "").trim();
    v = v.replace(/^(['"])([\s\S]*)\1$/, "$2").trim();
    out.push(v);
  }
  return out;
}

function jobKeyIs(block, key, valueRe) {
  const lines = String(block ?? "").split("\n");
  const header = lines[0] ?? "";
  // ⛔ DERIVED FROM THE FIRST KEY LINE, not `header indent + 2`: YAML requires only that a job's
  // children are DEEPER than the header, so a body indented to 6 spaces computed a 4-space key indent,
  // matched no `if:`, and reported a guarded job as unguarded (measured rc=1 on a correct tree).
  const firstKey = lines
    .slice(1)
    .map((l) => KEY_RE.exec(l))
    .find((m) => m && m[1].length > (header.length - header.trimStart().length));
  const keyIndent = " ".repeat(
    firstKey
      ? firstKey[1].length
      : header.length - header.trimStart().length + 2
  );
  // ⛔ The key is matched in EVERY quoting YAML permits (`if:`, `"if":`, `'if':`). Matching only the
  // bare spelling left a duplicate written `"if": true` invisible to `every()` — PyYAML confirms that
  // is the value the workflow evaluates — so the gate read green over an `if: true`.
  // ⛔ …AND YAML ALSO PERMITS WHITESPACE BEFORE THE COLON (`if :`), which is the SAME key. Requiring the
  // colon hard against the name left a duplicate `if : true` invisible to `every()` — one space away
  // from the quoted duplicate this list already closes — so the gate read ok/rc=0 over a job whose
  // effective `if` is `True` (measured, PyYAML confirms `True`).
  const ownRe = new RegExp(`^${keyIndent}(?:"${key}"|'${key}'|${key})\\s*:`);
  // ⛔ And the VALUE is the YAML-FOLDED scalar, not the first line. A plain scalar continues on any
  // following line indented deeper than the key, so
  //
  //     if: github.event_name != 'issue_comment'
  //       || true
  //
  // evaluates to `<guard> || true` and the job RUNS on the comment event — while a line-by-line
  // matcher sees only the first line, which is the guard verbatim, and reports green. Measured under
  // PyYAML: the folded value is "… != 'issue_comment' || true" and a line-wise match returned ok/rc=0.
  // Folding here means that continuation is examined by the SAME rule as the one-line form. Comment
  // lines are skipped because YAML excludes them from the scalar, and an indent at or left of the key
  // ends the value.
  const values = [];
  for (let i = 0; i < lines.length; i++) {
    const m = ownRe.exec(lines[i]);
    if (!m) continue;
    let value = lines[i].slice(m[0].length).trim();
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === "" || /^\s*#/.test(l)) continue;
      if (l.length - l.trimStart().length <= keyIndent.length) break;
      // No separator when the key's own line carried no value: a leading space can never match the
      // anchored `wholeRe` below, so `if:` with the guard on the NEXT line — YAML's value being exactly
      // the guard — was a FALSE BLOCK on a correctly guarded tree (measured: rc=1, YAML
      // `"… != 'issue_comment'"`).
      value += (value === "" ? "" : " ") + l.trim();
    }
    // ⛔ A WHOLE-SCALAR QUOTED value is the SAME value. `if: "!cancelled() && <guard>"` parses to
    // exactly the unquoted expression (PyYAML agrees), and quoting the whole scalar is how a
    // `!`-leading expression is made legal YAML — so refusing it was a false block on a tree that is
    // guarded. Peel one matching pair of quotes before matching; the inner text still has to match
    // the whole-expression rule, so this cannot admit anything the unquoted form would not.
    value = value.replace(/^(['"])([\s\S]*)\1$/, "$2").trim();
    values.push(value);
  }
  // `every()` on a NON-EMPTY list: a duplicate key is caught by requiring EVERY own occurrence to
  // match, and the `length > 0` half keeps "no such key at all" a FINDING rather than a vacuous pass
  // (`[].every()` is `true`).
  //
  // ⛔ AND THE WHOLE VALUE MUST MATCH — `^(?:…)$`, never a bare `.test()`. The guard pattern's own
  // shape is a PREFIX (the guard, then an optional `&&` tail), so an unanchored test accepts
  // `github.event_name != 'issue_comment' || true` by matching the prefix and ignoring the tail —
  // undoing the very fold above that exists to expose that tail. Measured: unanchored, the folded-`||`
  // mutant read ok/rc=0.
  const wholeRe = new RegExp(`^(?:${valueRe.source})\\s*$`);
  return values.length > 0 && values.every((v) => wholeRe.test(v));
}

// ── the two facts this file owns ─────────────────────────────────────────────────────────────

function checkWorkflowLock() {
  const text = read(WL_FILE);
  const { region, childIndent } = onRegion(text, WL_FILE);
  const t = trigger(region, childIndent, "pull_request_target", WL_FILE);

  const onSet = onKeys(region, childIndent);
  const extraOn = extraSet(onSet, ["pull_request_target"]);
  if (extraOn.length) {
    findings.push(
      `workflow-lock.yml's \`on:\` declares [${extraOn.join(", ")}] besides \`pull_request_target:\`. A SECOND trigger re-opens everything the first one closes — \`on.pull_request: types: [edited]\` would fire this leg on every body edit again, one line away from the assertion that says \`edited\` is gone, and it would also collapse this file's trust split (the definition must come from the base branch). The only trigger is \`pull_request_target:\`.`
    );
  }

  // ⛔ THIS TRIGGER CARRIES `types` AND NOTHING ELSE (review cycle 1, P2). `types` is a
  // `--head-ref`-style coverage knob; a `paths:`/`branches:` filter next to it is a NARROWING, and
  // this job validates EVERY workflow file in the merge result, so any diff it stops observing is a
  // structural guard that silently stopped guarding. The positive assertion is deliberate: adding a
  // filter here must be a visible edit to this test, not an invisible one to the workflow.
  const extraWl = extraFilters(t.keys, ["types"]);
  if (extraWl.length) {
    findings.push(
      `workflow-lock.yml's \`pull_request_target:\` declares [${extraWl.join(", ")}] besides \`types:\`. Any filter there NARROWS what this base-branch checker observes — it validates the merge result's workflow files for every PR, so a diff it stops seeing is a structural guard that silently stopped guarding, with every assertion about the trigger still green. The trigger's only filter is \`types:\`.`
    );
  }

  // The trigger must stay a pull_request_target: it is the reason the job runs from a copy the PR
  // cannot rewrite (see the workflow's own header). Losing it is not a narrowing, it is the gate
  // existing at all.
  const typesIdx = t.keys.findIndex((k) => k.key === "types");
  if (typesIdx < 0) {
    findings.push(
      "workflow-lock.yml declares no `types:` under `pull_request_target:`. GitHub's default set happens to be the same three types, but an implicit default carries no artifact: the decision recorded above the trigger stops being readable, and the next editor cannot tell a deliberate three-type set from an inherited one. Write `types: [opened, synchronize, reopened]`."
    );
    return;
  }
  const entry = t.keys[typesIdx];
  const valueLines = valueLinesFor(entry, t.lines);
  const items = readList(entry, valueLines);
  process.stdout.write(`workflow-lock pull_request_target types: ${items.join(", ") || "<none>"}\n`);

  const missing = WL_EXPECTED_TYPES.filter((x) => !items.includes(x));
  const extra = items.filter((x) => !WL_EXPECTED_TYPES.includes(x));
  if (missing.length) {
    findings.push(
      `workflow-lock.yml's \`types:\` has LOST [${missing.join(", ")}] — each of those is an event whose head or diff CAN change, so the merge result this job validates would go unvalidated for it.`
    );
  }
  if (extra.length) {
    const why = extra.includes("edited")
      ? "`edited` is the one this reduction exists to remove (#3196): `scripts/record-review.sh` writes the attestation into the PR BODY, so every record that APPENDS the marker buys a full run for a diff that did not change — a run that queues `pipeline-compliance`, the repo's only required context, behind it. The base-retarget coverage it also provided is a declared residual (see the workflow's trigger block); re-adding a per-edit trigger to recover it is the trade this decision rejected."
      : "an unexpected activity type widens the trigger set, and a widened set cannot be told from the decided one.";
    findings.push(
      `workflow-lock.yml's \`types:\` carries UNEXPECTED [${extra.join(", ")}]. ${why}`
    );
  }
}

function checkHarnessSingleSource() {
  const text = read(HSS_FILE);
  const { region, childIndent } = onRegion(text, HSS_FILE);
  const t = trigger(region, childIndent, "pull_request", HSS_FILE);

  const onSet = onKeys(region, childIndent);
  const extraOn = extraSet(onSet, ["pull_request"]);
  if (extraOn.length) {
    findings.push(
      `harness-single-source.yml's \`on:\` declares [${extraOn.join(", ")}] besides \`pull_request:\`. A second trigger runs this job on a surface the path filter does not scope — \`pull_request_target:\` would run it privileged, and \`push:\` would run it on main for a diff no PR measured. The only trigger is \`pull_request:\`.`
    );
  }

  // ⛔ THIS TRIGGER CARRIES `paths` AND NOTHING ELSE (review cycle 2, P1 — the mirror of the
  // `workflow-lock` arm cycle 1 added). `types:` narrows coverage exactly as a path filter does, and
  // `branches-ignore: [main]` disables the job for every PR in this repo — BOTH measured green over
  // the whole 28-arm suite before this refusal existed, because the arms only ever asked about
  // `paths`. An allow-list, so any future narrowing has to be a visible edit to this test.
  const extraHss = extraFilters(t.keys, ["paths"]);
  if (extraHss.length) {
    findings.push(
      `harness-single-source.yml's \`pull_request:\` declares [${extraHss.join(", ")}] besides \`paths:\`. Each of those is a COVERAGE NARROWING on a guard whose whole job is to red a reappearing fork or a drifting deployed copy: \`types: [opened]\` drops every \`synchronize\` (so no later head is ever measured), and \`branches-ignore: [main]\` stops the job firing on any PR in this repo at all — while the path arm stays true. The trigger's only filter is \`paths:\`.`
    );
  }
  const pathsIdx = t.keys.findIndex((k) => k.key === "paths");
  const ignoreIdx = t.keys.findIndex((k) => k.key === "paths-ignore");
  if (ignoreIdx >= 0) {
    findings.push(
      "harness-single-source.yml declares `paths-ignore:` — the two filters cannot both be used on one event, and an ignore list is scoped positively the wrong way: a NEW tree the doctor step starts reading is admitted by it silently. Use `paths:`."
    );
  }
  if (pathsIdx < 0) {
    findings.push(
      "harness-single-source.yml has no `paths:` key under `pull_request:`, so the job fires on EVERY PR again — the whole of #3196's second half (a 6.7 min median wall clock for a few seconds of work, on every diff, ahead of the only required context)."
    );
    return;
  }
  const entry = t.keys[pathsIdx];
  const valueLines = valueLinesFor(entry, t.lines);
  const items = readList(entry, valueLines);
  process.stdout.write(`harness-single-source pull_request paths: ${items.join(" | ") || "<none>"}\n`);

  if (items.length === 0) {
    findings.push(
      "harness-single-source.yml's `paths:` list is EMPTY. A `paths:` with no patterns is not a filter and not a documented shape — GitHub rejects it at load, so the workflow would not exist at all while this file looks like it filters."
    );
    return;
  }
  const noop = items.filter((p) => p === "**" || p === "*" || p === "**/*");
  if (noop.length) {
    findings.push(
      `harness-single-source.yml's \`paths:\` contains [${noop.join(", ")}] — that matches every path, so the filter is a no-op that reads like a reduction. Admission of the required trees is asserted separately (through the rail's own predicate, in run.sh); this arm refuses the shape that would make those assertions true for the wrong reason.`
    );
  }
}

// The required context's trigger is NOT this change's to narrow, and the asymmetry is the point:
// `pipeline-compliance` must keep `edited`, because its #513 verdict binding re-reads the PR body
// marker that `record-review.sh` writes AFTER the last push. Removing it there is the mistake this
// change most invites ("finish the job"), and it would be a silent fail-open: a forged
// `verdict=clean-micro` marker would ride a stale green check to merge.
// flowHeaderText(headerValue, lines, i) — the whole of a flow mapping that STARTS on line i.
//
// ⛔ A FLOW MAPPING IS NOT CONFINED TO ITS HEADER LINE. `shadow: {` … `}` may run over several lines, so
// inferring "no `name:` inside it" from the header line's own text is unsound exactly when the mapping
// continues: the appended block `shadow: {` / `name: pipeline-compliance,` / `}` puts the context name
// on a following line, the header text does not contain it, and skipping the job made a real second
// minter invisible — gate ok/rc=0 while a comment event could satisfy the required context (measured).
// So the header's flow mapping is read to its closing brace first, and `complete` records whether this
// reader could see the whole of it.
function flowHeaderText(headerValue, lines, i) {
  const depth = (s) => {
    let d = 0;
    let q = null;
    for (let k = 0; k < s.length; k += 1) {
      const ch = s[k];
      if (q) {
        if (ch === q) q = null;
        continue;
      }
      if (ch === '"' || ch === "'") q = ch;
      else if (ch === "{") d += 1;
      else if (ch === "}") d -= 1;
    }
    return d;
  };
  let text = String(headerValue ?? "");
  let d = depth(text);
  for (let j = i + 1; j < lines.length && d > 0; j += 1) {
    text += " " + lines[j];
    d = depth(text);
  }
  return { complete: d === 0, text };
}

// requiredContextJobId(text) — the JOB ID whose `name:` is the required status context.
//
// ⛔ BY NAME, AND IT MUST BE UNIQUE. The required context is a NAME (the workflow's header says main
// branch protection requires exactly `pipeline-compliance`), so the reader has to resolve the name to
// the job that mints it. Two jobs minting the same context — one guarded, one not — means the comment
// event satisfies the required context through the unguarded one while every assertion about the
// guarded job's own `if:` still passes. Measured: rc=0 with a shadow job `name: pipeline-compliance,
// if: True`. Zero or several matches is a refusal, never a guess.
// yamlScalar(raw) — the scalar a `key: <raw>` line evaluates to, or null when this reader does not
// model the shape.
//
// ⛔ "THE SAME STRING AS THE TEXT" IS NOT THE SAME AS "THE SAME VALUE". Reading `name:` out of the raw
// line made a trailing comment (`name: pipeline-compliance  # mints the context`) a DIFFERENT context,
// so that job became an invisible minter and a shadow declaring the required context went uncounted —
// rc=0 while the only job minting the context on a comment event was the unguarded one (measured). The
// mirror also fired: the required job's OWN `name:` carrying a comment read as "0 job(s) mint". YAML
// drops comments and one matching quote pair and ignores an anchor here, so this does too.
function yamlScalar(raw) {
  const s = String(raw ?? "");
  let out = "";
  let quote = null;
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (quote) {
      if (ch === quote) quote = null;
      out += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      out += ch;
      continue;
    }
    // A `#` only starts a comment at a token boundary; YAML requires whitespace before it.
    if (ch === "#" && (i === 0 || /\s/.test(s[i - 1]))) break;
    out += ch;
  }
  // An UNTERMINATED quote is not a scalar this reader can report a value for.
  if (quote !== null) return null;
  out = out.trim();
  if (out === "") return null;
  out = out.replace(/^&\S+\s*/, ""); // anchor — not part of the value
  const m = /^(['"])([\s\S]*)\1$/.exec(out);
  if (m) {
    // ⛔ A DOUBLE-QUOTED SCALAR IS NOT ITS SOURCE TEXT — YAML DECODES ESCAPES. `name:
    // "\x70ipeline-compliance"` evaluates to `pipeline-compliance` (pyyaml), yet peeling the quotes and
    // returning the literal made it a DIFFERENT context: the shadow stopped counting as a minter, the
    // "exactly one minter" check held, and the gate read ok/rc=0 while a second job minted the required
    // context with `if: true` (measured, three spellings: `\x70…`, `\u002D…`, and an escaped line
    // break). Decoding escapes is a YAML parser's job, so rather than half-implement one, any escape in
    // a double-quoted value is REFUSED — this file's contract is that an unmodelled shape exits 2 and
    // never guesses. Single-quoted scalars are literal text in YAML, so they need no decoding.
    if (m[1] === '"' && m[2].includes("\\")) return null;
    out = m[2];
  } else if (/^[|>{[]/.test(out) || /^[*&!]/.test(out)) return null; // block/flow/alias: not modelled
  return out;
}

function requiredContextJobId(text, contextName = "pipeline-compliance") {
  const lines = String(text ?? "").split("\n");
  const bounds = jobsBounds(lines);
  if (bounds === null) {
    refuse(`${PC_FILE}: no top-level \`jobs:\` key — the required context's job is UNVERIFIED.`);
  }
  const ids = [];
  for (let i = bounds.start + 1; i < bounds.end; i += 1) {
    const m = KEY_RE.exec(lines[i]);
    if (!m || m[1].length !== 2) continue;
    const id = (m[2] ?? m[3] ?? m[4] ?? "").trim();
    if (!id) continue;
    // ⛔ A JOB HEADER MUST BE A PLAIN BLOCK MAPPING. A flow-mapped header
    // (`shadow: {name: pipeline-compliance, if: true}`) declares a `name:` this reader never sees, so a
    // minter could hide inside it — refuse rather than read a job whose shape is not modelled.
    // A flow mapping may also BEGIN on the next line: `shadow:` then `{name: …, if: true}`. The header
    // line is then empty, so it was read as a BLOCK mapping, its `name:` (inside the braces) was never
    // matched at a key indent, and the job was counted as minting its id — a real second minter went
    // invisible (measured rc=0 with pyyaml showing two). The first deeper non-blank, non-comment line
    // decides which shape this is.
    // ⛔ A HEADER VALUE THE READER CANNOT CLASSIFY IS REFUSED — never silently treated as an empty block
    // mapping. `^\s*\{` recognises a flow mapping only when the brace LEADS, so `shadow: &a {name:
    // pipeline-compliance, if: true}`, `shadow: !!map {…}` and an ALIAS value (`shadow: *shared`) all fell
    // through to the block path, where no `name:` key line exists — `ctx` stayed the job id, the shadow
    // was counted as a NON-minter, and a real second minter with `if: true` went invisible (measured:
    // gate ok/rc=0 with pyyaml showing two jobs named `pipeline-compliance`, on a workflow that admits
    // `issue_comment`). Three outcomes only: an EMPTY value is a block mapping, a value leading with `{`
    // is a flow mapping (read to its close), and ANYTHING ELSE — anchor, tag, alias, or a shape not
    // considered here — is refused, because this reader cannot say whether that job declares a `name:`.
    const headerValue = (m[5] ?? "").replace(/\s+#.*$/, "").trim();
    let flowSource = null;
    if (headerValue.startsWith("{")) {
      flowSource = { value: m[5], at: i };
    } else if (headerValue !== "") {
      refuse(
        `line ${i + 1}: the \`${id}\` job header carries ${JSON.stringify(
          headerValue
        )}, which this reader cannot classify (an anchor, tag, alias or other shape). Whether that job declares a \`name:\` is UNVERIFIED, so the set of jobs minting the required context is too.`
      );
    }
    if (!flowSource) {
      for (let j = i + 1; j < lines.length; j += 1) {
        const raw = lines[j];
        if (raw.trim() === "" || /^\s*#/.test(raw)) continue;
        if (raw.length - raw.trimStart().length <= 2) break; // next job / top-level key
        // The body's FIRST line decides the shape too: a flow mapping may open here, and an anchor /
        // alias / tag here is equally unclassifiable.
        if (/^\s*\{/.test(raw)) flowSource = { value: raw, at: j };
        else if (/^\s*[&*!]/.test(raw)) {
          refuse(
            `line ${j + 1}: the \`${id}\` job body opens with ${JSON.stringify(
              raw.trim()
            )}, which this reader cannot classify (an anchor, tag or alias). Whether that job declares a \`name:\` is UNVERIFIED.`
          );
        }
        break;
      }
    }
    if (flowSource) {
      const flow = flowHeaderText(flowSource.value, lines, flowSource.at);
      // ⛔ BUT ONLY WHEN IT COULD MINT THE CONTEXT — and the WHOLE mapping decides that, never the
      // header line alone (see flowHeaderText). An INCOMPLETE one is refused because this reader
      // cannot see the `name:` it may contain.
      // A blanket refusal over every flow-mapped job header
      // turns a NON-minting sibling (`workflow-drift: {name: …}`) into CANNOT-VERIFY, which both
      // over-blocks a correct tree and destroys the ability of the block-terminator arms to distinguish
      // "the block ended here" from "the reader gave up" — measured: the terminator arm read rc=2
      // instead of rc=1 with the blanket rule. The header text is all a line reader has, so if the
      // CONTEXT NAME does not appear in it, no `name:` inside can equal the context and the job cannot
      // mint it; if it does appear, the reader genuinely cannot tell and refuses.
      // ⛔ AND AN ALIAS OR ANCHOR INSIDE THE MAPPING IS UNREADABLE TOO: `{name: *ctx, if: true}` mints
      // whatever `*ctx` was bound to, and a line reader cannot resolve it. Refusing `*`/`&`/`!` in the
      // flow text keeps this the same rule as everywhere else — what cannot be resolved is not green.
      if (!flow.complete || flow.text.includes(contextName) || /[*&!]/.test(flow.text)) {
        refuse(
          `line ${flowSource.at + 1}: the \`${id}\` job${
            flow.complete ? ` carrying ${JSON.stringify(contextName)}` : " this reader cannot read to its close"
          } is a FLOW MAPPING, and flow mappings are not modelled — the set of jobs minting the required context is UNVERIFIED.`
        );
      }
      continue; // a COMPLETE flow mapping that cannot name the context, so it cannot mint it
    }
    // GitHub uses `name:` when the job declares one, otherwise the id itself.
    let ctx = id;
    const nameLines = [];
    // ⛔ THE KEY INDENT IS DERIVED, NOT ASSUMED TO BE 4. YAML only requires a job's children to be
    // DEEPER than the header, so hardcoding four spaces read no `name:` at all when a job's children sat
    // at six — a shadow minting the context became invisible (measured rc=0 with pyyaml showing two
    // minters), and the correctly guarded required job re-indented the same way read as a lost guard.
    // The first key line inside the job defines its key indent, exactly as `jobKeyIs` derives it.
    let keyIndent = null;
    for (let j = i + 1; j < lines.length; j += 1) {
      const nm = KEY_RE.exec(lines[j]);
      if (!nm) continue;
      const ind = nm[1].length;
      if (ind <= 2) break; // next job header or a top-level key
      if (keyIndent === null) keyIndent = ind;
      if (ind === keyIndent && (nm[2] ?? nm[3] ?? nm[4]) === "name") nameLines.push(nm);
    }
    if (nameLines.length > 1) {
      refuse(
        `line ${i + 1}: the \`${id}\` job declares \`name:\` ${nameLines.length} times. YAML keeps the LAST, so which context it mints is not something this reader can answer — UNVERIFIED.`
      );
    }
    if (nameLines.length === 1) {
      const raw = nameLines[0][5] ?? "";
      const v = yamlScalar(raw);
      if (v === null) {
        refuse(
          `line ${i + 1}: cannot read the \`name:\` value ${JSON.stringify(
            raw.trim()
          )} of job \`${id}\` — the context it mints is UNVERIFIED.`
        );
      }
      ctx = v;
    }
    ids.push({ id, ctx });
  }
  const matching = ids.filter((x) => x.ctx === contextName).map((x) => x.id);
  if (matching.length !== 1) {
    refuse(
      `${PC_FILE}: ${matching.length} job(s) mint the required status context ${JSON.stringify(
        contextName
      )}${matching.length ? ` (${matching.join(", ")})` : ""}. Exactly one must, and the guard is asserted on THAT job — with zero or several, which job the merge is gated on is not something this reader can answer.`
    );
  }
  return matching[0];
}

function checkPipelineComplianceUnchanged() {
  const text = read(PC_FILE);
  const { region, childIndent } = onRegion(text, PC_FILE);
  const t = trigger(region, childIndent, "pull_request", PC_FILE);

  // `workflow_call` is legitimate here (consumers reuse this file); anything else is a new run site
  // on the repo's only required context, and a `push:` arm would attach its verdict to main.
  //
  // ⛔ `issue_comment` IS ADMITTED, AND ONLY AS A GUARDED PAIR. The comment-triggered revalidation job
  // exists to re-read a gate verdict after a body edit, and the file's header states at length that it
  // posts no marker, cannot turn a red green and holds no `contents: write`. But admitting the trigger
  // by NAME alone would be the fail-open this whole file exists to prevent: the repo's ONLY required
  // status context is `pipeline-compliance`, and if that JOB ever lost its own guard, a comment event
  // would produce the verdict a PR head is gated on — a surface no PR head controls. So the widening is
  // bound to the EVIDENCE that makes it safe (`PC_COMMENT_GUARD` below), and dropping the guard from
  // the job is refused exactly like an unreviewed new trigger. A genuinely NEW trigger still lands in
  // `extraOn` and is reported by name, so the arm that says "a new dispatch path must declare itself"
  // keeps firing.
  const PC_ALLOWED_ON = ["workflow_call", "pull_request"];
  const PC_ADMITTED_EXTRA = ["issue_comment"];
  // ⛔ THE GUARD MUST BE THE WHOLE EXPRESSION, OR THE GUARD **AND** SOMETHING — never "anything then
  // the guard text". A leading `.*` tolerates a COMPOUND `if:`, but it tolerates it in the WRONG
  // DIRECTION: `if: true || github.event_name != 'issue_comment'` contains the guard text and
  // evaluates to TRUE, so the required job DOES run on the comment event while this gate reads green —
  // the exact fail-open the admission exists to prevent (measured: ok/rc=0 under a leading `.*`).
  // Conversely a NARROWING suffix (`… && github.event.action != 'deleted'`) is safe by construction —
  // ANDing with the guard can only exclude more events — yet a leading `.*` refused it (measured:
  // rc=1). So the shape is `<guard>` optionally followed by `&& …`, optionally wrapped in `${{ }}`
  // (GitHub documents the wrapper as equivalent, and refusing it is a false block on a guarded tree),
  // with the event name quotable either way — YAML permits both, and a formatter may switch them.
  // The `&&` tail excludes `|` ON PURPOSE: `&&` binds tighter than `||`, so `… && x || true`
  // evaluates to TRUE and the job runs on the comment event — a tail that merely "came after the
  // guard" is NOT safe (measured: ok/rc=0 with `[^}]*`). A top-level `||` is a disjunction AROUND the
  // guard, so any `||` in the tail is refused; that also refuses a nested `(a || b)`, which is safe in
  // itself, and over-blocking is the direction this gate must err in.
  const PC_COMMENT_GUARD =
    /(?:\$\{\{\s*)?(?:!cancelled\(\)\s*&&\s*)?github\.event_name\s*!=\s*['"]issue_comment['"](?:\s*&&[^|}]*)?(?:\s*\}\})?(?:\s+#.*)?/;
  const onNames = onKeys(region, childIndent);
  const extraOn = extraSet(onNames, [...PC_ALLOWED_ON, ...PC_ADMITTED_EXTRA]);
  const admitted = extraSet(onNames, PC_ALLOWED_ON).filter((n) => PC_ADMITTED_EXTRA.includes(n));
  // ⛔ THE REQUIRED CONTEXT IS THE JOB **NAME**, NOT THE JOB ID. The workflow's own header says main
  // branch protection requires EXACTLY the check context `pipeline-compliance`, and GitHub derives that
  // context from `jobs.<id>.name` when it is present. Asserting the guard on the ID therefore asserts it
  // on an identifier that need not be the context: a second job carrying `name: pipeline-compliance`
  // with `if: true` mints the required context ON A COMMENT EVENT while the guarded `pipeline-compliance`
  // job still satisfies every assertion about its own `if:` (measured: rc=0, effective shadow job
  // `name: pipeline-compliance, if: True`). So the job that mints the context is located BY NAME, and
  // exactly one job may do it.
  const pcJobId = requiredContextJobId(text);
  if (
    admitted.length &&
    !jobKeyIs(jobBlock(text, pcJobId), "if", PC_COMMENT_GUARD)
  ) {
    findings.push(
      // ⛔ AND IT MUST NOT CLAIM THE GUARD IS *ABSENT*. This reader models a ONE-LINE plain scalar
      // (optionally `&&`-narrowed, `${{ }}`-wrapped, `!cancelled()`-prefixed, trailing comment
      // allowed) — NOT a `if: >-` block scalar. Saying "no longer carries" about a job whose guard is
      // present in a spelling this reader does not model sends the reader after the wrong fault, and
      // the natural repair for a wrong diagnosis is to loosen this regex, which is how a fail-open is
      // born. So the message names both possibilities.
      `pipeline-compliance.yml declares \`${admitted.join(", ")}:\` but its \`pipeline-compliance\` JOB does not carry \`if: github.event_name != 'issue_comment'\` as a WHOLE-EXPRESSION job-level \`if:\` (either the guard is missing, or it is written in a spelling this reader does not model — a plain scalar is understood, on one line or FOLDED across lines, optionally \`&&\`-narrowed, \`\${{ }}\`-wrapped, \`!cancelled()\`-prefixed or carrying a trailing comment; a \`>-\`/\`|\` BLOCK SCALAR is not). The comment trigger is admitted ONLY as a guarded pair: without that guard on the REQUIRED job the COMMENT event satisfies the repo's only required status context, so a comment — not a PR head — produces the verdict a merge is gated on. (A guard on any OTHER job does not satisfy this: \`workflow-drift\` carries its own for its own reasons.)`
    );
  }
  if (extraOn.length) {
    findings.push(
      // The allow-list is BUILT from the constants, never spelled out in prose: prose drifts, and a
      // FINDING that names an allow-list the file no longer has leaves the reader unable to tell
      // whether the admitted trigger is admitted or an unreported extra.
      `pipeline-compliance.yml's \`on:\` declares [${extraOn.join(", ")}] besides ${[...PC_ALLOWED_ON, ...PC_ADMITTED_EXTRA].map((n) => `\`${n}:\``).join(", ")}. A new trigger on the only required status context is a new surface this gate's evidence was never checked against (and a \`push:\` arm would attach its verdict to main, not to a PR head).`
    );
  }

  // ⛔ THE ADMISSION IS A PAIR *AND* AN OWNED ACTIVITY SET — NOT A NAME. Admitting `issue_comment` to
  // the allow-list and pinning only the required job's guard leaves the OTHER half of #2467's
  // justification unpinned, and it is the half that makes the trigger safe: the comment event is
  // harmless because `revalidate-on-issue-comment` OWNS it and re-runs the EXISTING run. Each of the
  // four facts below was measured GREEN on this reader before it existed (the mutation and its result
  // are re-driven, one arm each, in `run.sh` 7o–7r):
  //   * the `issue_comment:` trigger deleted            → green, so the trigger could vanish silently
  //   * `issue_comment: types:` reduced to `[created]`    → green, so the retraction edit stopped
  //     re-reading (retracting a scoping marker is an `edited` activity — the file's own header says
  //     the arm is BIDIRECTIONAL and a one-sided read leaves the previous GREEN standing)
  //   * the revalidation job re-pointed at another event, or its body given `&& false` → green, so the
  //     event had no owner at all while every assertion about the required job still held
  if (!onNames.includes("issue_comment")) {
    findings.push(
      `pipeline-compliance.yml no longer declares \`issue_comment:\`. That trigger is the ADMITTED one (${PC_ADMITTED_EXTRA.map((n) => `\`${n}:\``).join(", ")}): #2467 added it because checks (b) and (d) read the LINKED ISSUE, which fires no \`pull_request\` event, so without it the repo's only required context is non-deterministic in time (measured on PR #3122: two runs of the same check on the same commit disagreed, and only queue latency decided the difference). Removing it silently reopens that window. To remove it, remove it from \`PC_ADMITTED_EXTRA\` in this file AND record the decision it reverses — the allow-list is derived from those constants, never spelled out in prose, so the two cannot drift apart here.`
    );
  } else {
    // ⛔ AND THE ACTIVITY SET IS PART OF THE PAIR. An absent `types:` is ADMISSIBLE here — GitHub's
    // default for `issue_comment:` is `created`, `edited`, `deleted`, which already covers both
    // activities this decision needs — but a DECLARED set that lost one of them is a refusal. So the
    // rule is "the effective set contains both", not "the key is present": refusing an absent key
    // would be a false block on a workflow that is correct.
    const ic = trigger(region, childIndent, "issue_comment", PC_FILE);
    const icIdx = ic.keys.findIndex((k) => k.key === "types");
    const icTypes =
      icIdx < 0 ? ["created", "edited", "deleted"] : readList(ic.keys[icIdx], valueLinesFor(ic.keys[icIdx], ic.lines));
    const icMissing = ["created", "edited"].filter((a) => !icTypes.includes(a));
    if (icMissing.length) {
      findings.push(
        `pipeline-compliance.yml's \`issue_comment:\` no longer carries the ${icMissing.length > 1 ? "activities" : "activity"} [${icMissing.join(", ")}] (declared: [${icTypes.join(", ")}]). \`created\` is what re-runs the gate for an open PR that cross-references a newly-scoped issue; \`edited\` is what re-reads it after a body edit, and the retraction direction (a scoping marker REMOVED from a comment) is why the file's header calls that arm bidirectional. Without it a retracted marker leaves the previous GREEN standing indefinitely. GitHub's default set for this trigger is \`created, edited, deleted\`, so an ABSENT \`types:\` key is admissible; a declared set missing either activity is not.`
      );
    }
    // ⛔ AND THE EVENT MUST HAVE AN OWNER. `revalidate-on-issue-comment` is what makes the comment
    // event safe: it re-runs the EXISTING run for each open PR cross-referencing the issue, posts no
    // marker, holds no `contents: write` and cannot turn a red green. This is asserted on that job BY
    // NAME, because a guard on any other job says nothing about who owns the event. Its `if:` is a
    // `>-` BLOCK SCALAR in the live file, which the required job's guard reader deliberately does not
    // model (a `>-` body of `guard` + `|| true` folds to TRUE) — so it is read here with the block
    // indicator stripped and both predicates required as a CONJUNCTION, with any `||` or bare
    // `true`/`false` literal refused. That is the safe direction: ANDing can only exclude more events.
    const rv = jobBlock(text, "revalidate-on-issue-comment");
    const rvExprs = jobIfExprs(rv);
    if (!String(rv ?? "").trim()) {
      findings.push(
        "pipeline-compliance.yml no longer declares the `revalidate-on-issue-comment` job. It OWNS the `issue_comment:` event that the allow-list admits: on a scoping comment it re-runs the EXISTING gate run for each open PR cross-referencing the issue (it posts no marker, holds no `contents: write` and cannot turn a red green). With the trigger admitted and this job gone, the comment event re-runs nothing — checks (b)/(d) stay non-deterministic in time, which is the #2467 window itself."
      );
    } else if (rvExprs.length === 0) {
      findings.push(
        "pipeline-compliance.yml's `revalidate-on-issue-comment` job carries no job-level `if:`, so it runs on EVERY event the workflow fires — including `pull_request`, where it would re-run the gate run it is already inside. The job exists to own the `issue_comment` event and nothing else."
      );
    } else {
      for (const expr of rvExprs) {
        const keysEvent = /github\.event_name\s*==\s*['"]issue_comment['"]/.test(expr);
        const keysIssue = /github\.event\.issue\.pull_request\s*==\s*null/.test(expr);
        const escape = /\|\||\bfalse\b|(?<![=!<>])\btrue\b/.test(expr);
        if (!keysEvent || !keysIssue || escape) {
          findings.push(
            `pipeline-compliance.yml's \`revalidate-on-issue-comment\` job \`if:\` is ${JSON.stringify(expr)}, which does not both (i) key on \`github.event_name == 'issue_comment'\` and (ii) require \`github.event.issue.pull_request == null\`, with no \`||\` disjunction and no bare \`true\`/\`false\` literal. That conjunction is what confines the job to comments on ISSUES (a comment on a PR must never re-run that PR's gate) — and it is the whole reason admitting the trigger is safe: the event is owned by a job that re-runs the EXISTING run and can neither post a marker nor turn a red green. A disjunction or an \`&& false\` body makes the owner unable to run while every assertion about the required job still reads true.`
          );
        }
      }
    }
  }

  // ⛔ AND NO PATH FILTER UNDER IT (review cycle 1, P1). This is the change the current sweep most
  // invites — "finish the job, filter the required check too" — and it is the one that hurts most:
  // GitHub documents that "if a workflow is skipped due to path filtering … then checks associated
  // with that workflow will remain in a 'Pending' state. A pull request that requires those checks
  // to be successful will be blocked from merging." So `pipeline-compliance` is the ONE workflow in
  // this repo that must never carry `paths:`/`paths-ignore:`, and this arm is where that is said.
  const extraPc = extraFilters(t.keys, ["branches", "types"]);
  if (extraPc.length) {
    findings.push(
      `pipeline-compliance.yml's \`pull_request:\` declares [${extraPc.join(", ")}]. It is the repo's ONLY required status context, so a path filter here does not narrow a check — it makes the required context UNSATISFIABLE on every head whose diff does not match: GitHub keeps a path-filtered workflow's checks "Pending", and a PR that requires them cannot merge. Allowed filter keys on this trigger are \`branches\` and \`types\` only.`
    );
  }
  const idx = t.keys.findIndex((k) => k.key === "types");
  if (idx < 0) {
    findings.push(
      "pipeline-compliance.yml no longer declares `types:`. Its #513 verdict binding needs the `edited` activity — `record-review.sh` writes the review marker into the PR body after the last push — so the default set would never re-run the gate post-marker."
    );
    return;
  }
  const entry = t.keys[idx];
  const valueLines = valueLinesFor(entry, t.lines);
  const items = readList(entry, valueLines);
  process.stdout.write(`pipeline-compliance pull_request types: ${items.join(", ") || "<none>"}\n`);
  // ⛔ THE ACTIVITY SET IS A SET, NOT A MEMBERSHIP TEST. The decision is `opened, synchronize,
  // reopened, edited` — all four, and nothing else:
  //   * losing `edited` lets a forged `verdict=clean-micro` marker ride a stale green check to merge
  //     (the marker is written to the PR body AFTER the last push, which is an `edited` activity);
  //   * losing `synchronize` is the MIRROR fail-open and was measured GREEN on the membership test that
  //     used to stand here: a new push never re-runs the gate, so the previous head's GREEN keeps
  //     standing on a body of evidence nobody re-read — the exact staleness `edited` exists to prevent,
  //     arriving from the other side;
  //   * losing `opened` means the first commit of a PR is never gated at all;
  //   * an EXTRA activity is a new run site on the repo's only required context, reported here rather
  //     than silently admitted.
  const PC_REQUIRED_TYPES = ["opened", "synchronize", "reopened", "edited"];
  const lostTypes = PC_REQUIRED_TYPES.filter((a) => !items.includes(a));
  const extraTypes = items.filter((a) => !PC_REQUIRED_TYPES.includes(a));
  if (lostTypes.length || extraTypes.length) {
    const parts = [];
    if (lostTypes.length) {
      parts.push(
        `LOST [${lostTypes.join(", ")}]${
          lostTypes.includes("edited")
            ? " — `edited` is the #513 binding: `record-review.sh` PATCHes the marker into the PR body after the last push, so without it a forged `verdict=clean-micro` marker rides a stale green check to merge"
            : ""
        }${
          lostTypes.includes("synchronize")
            ? " — without `synchronize` a NEW PUSH never re-runs the gate, so the previous head's green keeps standing on evidence nobody re-read"
            : ""
        }`
      );
    }
    if (extraTypes.length) parts.push(`ADDS [${extraTypes.join(", ")}], a new run site on the required context`);
    findings.push(
      `pipeline-compliance.yml's required-context \`types:\` is [${items.join(", ") || "<none>"}], not the decided set [${PC_REQUIRED_TYPES.join(", ")}]. ${parts.join("; ")}. #3196 scopes a reduction to the ADVISORY guards precisely so this file is untouched.`
    );
  }
  // ⛔ AND ITS BRANCH FILTER MUST STILL ADMIT main. An absent `branches:` key is ADMISSIBLE — the
  // trigger then fires for every target branch, which still includes `main`, so the required context is
  // still satisfiable and no false block is owed. A DECLARED filter that no longer lists `main` is the
  // dangerous direction and was measured GREEN before this check existed: `pipeline-compliance` would
  // never run on a PR to `main`, GitHub keeps a non-triggered required check "Pending", and every PR to
  // `main` becomes unmergeable — the same unsatisfiable-context class as a `paths:` filter here.
  const brIdx = t.keys.findIndex((k) => k.key === "branches");
  if (brIdx >= 0) {
    const branches = readList(t.keys[brIdx], valueLinesFor(t.keys[brIdx], t.lines));
    if (!branches.includes("main")) {
      findings.push(
        `pipeline-compliance.yml's \`pull_request: branches:\` is [${branches.join(", ") || "<none>"}], which no longer admits \`main\`. This is the repo's ONLY required status context: on a PR to \`main\` the workflow would never trigger, GitHub keeps an untriggered required check "Pending", and that PR can never merge. (An ABSENT \`branches:\` key is admissible — it fires for every target branch and therefore still includes \`main\`.)`
      );
    }
  }
}

checkWorkflowLock();
checkHarnessSingleSource();
checkPipelineComplianceUnchanged();

if (findings.length) {
  for (const f of findings) process.stdout.write(`FINDING: ${f}\n`);
  process.exit(1);
}
process.stdout.write("ok\n");
