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
  const onRe = /^(?:"on"|'on'|on):/;
  const onStarts = lines.map((raw, i) => (onRe.test(raw) ? i : -1)).filter((i) => i >= 0);
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
  return region
    .filter((l) => l.indent === childIndent)
    .map((l) => keyOf(l))
    .filter((k) => k !== null)
    .map((k) => k.key);
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
  const nameOfJobHeader = (line) => {
    const m = KEY_RE.exec(line);
    if (!m || m[1].length !== 2) return null; // job headers sit at 2 spaces, one level under `jobs:`
    return (m[2] ?? m[3] ?? m[4] ?? "").trim();
  };
  const starts = lines
    .map((l, i) => ({ l, i }))
    .filter(({ l }) => nameOfJobHeader(l) === name)
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
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
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
function jobKeyIs(block, key, valueRe) {
  const lines = String(block ?? "").split("\n");
  const header = lines[0] ?? "";
  const keyIndent = " ".repeat(header.length - header.trimStart().length + 2);
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
  if (
    admitted.length &&
    !jobKeyIs(jobBlock(text, "pipeline-compliance"), "if", PC_COMMENT_GUARD)
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
  if (!items.includes("edited")) {
    findings.push(
      "pipeline-compliance.yml's `types:` LOST `edited`. That is the required context and its #513 binding depends on re-running after `record-review.sh` PATCHes the marker into the PR body; without `edited` a forged `verdict=clean-micro` marker rides a stale green check to merge. #3196 scopes this reduction to the ADVISORY guards precisely so this file is untouched."
    );
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
