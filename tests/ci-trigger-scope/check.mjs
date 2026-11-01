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
// the body-edit activity `scripts/record-review.sh` fires on every recorded review, and it
// cannot change the merge result this job validates.
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

// content(raw) — a line's {raw, indent, no} when it is a real content line, else null.
function contentLines(text) {
  const out = [];
  text.split("\n").forEach((raw, i) => {
    if (blank(raw) || comment(raw)) return;
    out.push({ raw, indent: indentOf(raw), no: i + 1 });
  });
  return out;
}

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

// ── the two facts this file owns ─────────────────────────────────────────────────────────────

function checkWorkflowLock() {
  const text = read(WL_FILE);
  const { region, childIndent } = onRegion(text, WL_FILE);
  const t = trigger(region, childIndent, "pull_request_target", WL_FILE);

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
  const valueLines = t.lines.slice(entry.idx + 1).filter((l) => l.indent > entry.line.indent);
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
      ? "`edited` is the one this reduction exists to remove (#3196): `scripts/record-review.sh` writes the attestation into the PR BODY, so every recorded review buys a full run for a diff that did not change — a run that queues `pipeline-compliance`, the repo's only required context, behind it. The base-retarget coverage it also provided is a declared residual (see the workflow's trigger block); re-adding a per-edit trigger to recover it is the trade this decision rejected."
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
  const valueLines = t.lines.slice(entry.idx + 1).filter((l) => l.indent > entry.line.indent);
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
  const valueLines = t.lines.slice(entry.idx + 1).filter((l) => l.indent > entry.line.indent);
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
