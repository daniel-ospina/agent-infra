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
  const start = lines.findIndex((raw) => /^(?:"on"|'on'|on):[ \t]*(?:#.*)?$/.test(raw));
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

// jobBlock(text, name, file) — the lines owned by `jobs.<name>`, or a refusal.
//
// ⛔ THIS READER EXISTS FOR ONE FACT THE `on:` REGION CANNOT CARRY (2026-11-06): whether the REQUIRED
// job is kept OFF a trigger that is legitimate for the FILE. The `on:` reader stops at the first
// column-0 key, so it never sees `jobs:`, and the guard lives there. A trigger pinned only by its
// name would accept `issue_comment:` on a file whose required job no longer excludes it — a
// `pull_request`-shaped verdict attached to an event that has no PR head at all.
//
// The block runs from `  <name>:` to the next non-blank, non-comment line at indent <= 2 (the next job
// under `jobs:`). Absent job: refusal (exit 2), never a silent "no guard found → pass".
function jobBlock(text, name, file) {
  const lines = text.split("\n");
  const start = lines.findIndex((raw) => {
    const m = /^([ \t]+)(?:"([^"]*)"|'([^']*)'|([A-Za-z0-9_.-]+))[ \t]*:[ \t]*(?:#.*)?$/.exec(raw);
    if (!m) return false;
    return m[1].length === 2 && (m[2] ?? m[3] ?? m[4]) === name;
  });
  if (start < 0)
    refuse(`${file}: no \`${name}:\` job at the two-space indent under \`jobs:\` — the trigger's guard cannot be read`);
  const out = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    const raw = lines[i];
    if (!blank(raw) && !comment(raw) && indentOf(raw) <= 2) break;
    out.push({ raw, indent: indentOf(raw), no: i + 1 });
  }
  return out;
}

// guardKeepsJobOff(lines, token) — is there an `if:` in this job block that EXCLUDES `token`?
//
// Two accepted spellings, both read from the expression itself rather than from the line's position:
// an expression that NAMES the token (`github.event_name != 'issue_comment'`, the shipped form) and a
// positive allow-list of PR-shaped events (`== 'pull_request'`). Anything else is a finding — a
// one-line `if:` this reader cannot attribute is a guard it cannot vouch for, and the over-block
// direction is the deliberate one here.
//
// STATED LIMIT: a FOLDED `if: >-` puts the expression on following lines, so the token would not be
// seen and this reads as "no guard" (RED). That is a visible false block, not a silent pass — and
// the shipped file uses the one-line form.
function guardKeepsJobOff(lines, token) {
  return lines.some((l) => {
    const m = /^[ \t]*if:[ \t]*(.+)$/.exec(l.raw);
    if (!m) return false;
    const expr = m[1];
    if (new RegExp(`(^|[^A-Za-z0-9_])${token}([^A-Za-z0-9_]|$)`).test(expr)) return true;
    return /github\.event_name[ \t]*==[ \t]*['"](pull_request|workflow_run)['"]/.test(expr);
  });
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
  // ⛔ `issue_comment` IS THE SANCTIONED THIRD TRIGGER (#2467) — AND IT IS SANCTIONED WITH A GUARD, NOT
  // BY NAME ALONE (2026-11-06). #3196 pinned this key set to `workflow_call` + `pull_request`; three
  // days later #2467 added an `issue_comment:` arm so a scoping comment landing on the linked ISSUE —
  // which fires no `pull_request` event — can re-run the EXISTING gate run instead of leaving a red
  // minted before that comment standing. It is a RE-RUN SITE, not a second verdict site: the
  // `pipeline-compliance` job carries `if: github.event_name != 'issue_comment'`, and every other job
  // that would mis-attach is guarded the same way. The pin was simply never taught about it, so the
  // live tree read RED (`declares [issue_comment] besides workflow_call: and pull_request:`) against a
  // deliberate, documented trigger — a false block, which is how a gate stops being read.
  //
  // So the name is admitted HERE and the property it depends on is pinned BELOW: the required job must
  // keep saying, in its own `if:`, that a comment event is not its business. Dropping the guard is the
  // edit that would turn this trigger into a way to attach the repo's only required status context to
  // an event with no PR head — and it is now a RED rather than an invisible one.
  const onSet = onKeys(region, childIndent);
  const extraOn = extraSet(onSet, ["workflow_call", "pull_request", "issue_comment"]);
  if (extraOn.length) {
    findings.push(
      `pipeline-compliance.yml's \`on:\` declares [${extraOn.join(", ")}] besides \`workflow_call:\`, \`pull_request:\` and \`issue_comment:\`. A new trigger on the only required status context is a new surface this gate's evidence was never checked against (and a \`push:\` arm would attach its verdict to main, not to a PR head).`
    );
  }
  if (onSet.includes("issue_comment") && !guardKeepsJobOff(jobBlock(text, "pipeline-compliance", PC_FILE), "issue_comment")) {
    findings.push(
      "pipeline-compliance.yml declares `issue_comment:` on `on:`, but its `pipeline-compliance` JOB carries no `if:` that keeps the required context off that event. The trigger is only a re-run site (#2467) BECAUSE the job refuses a comment event (`if: github.event_name != 'issue_comment'`); without that guard the repo's ONLY required status context can report a verdict against an event that has no pull-request head, which is the fail-open the trigger's own header says the job guard prevents."
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
