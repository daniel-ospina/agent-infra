/**
 * review-enforcer.test.ts — unit tests for the merge registry gate (#138)
 *
 * Covers: PR number extraction, repo context resolution priority
 * (--repo flag > GH_REPO env > cd-prefix > record.repo > fallback), and the
 * fail-open-on-unresolvable behavior (gh failure never blocks a merge).
 *
 * Run: npx tsx extensions/review-enforcer/index.test.ts
 */

// The gh-runner test seam (_setRunGhOverride) is honored only under
// NODE_ENV=test (#212 review pass) — set it before importing the module.
process.env.NODE_ENV = "test";

// #285 isolation: the parent launch env may carry the task-sub-agent markers
// (TASK_HEARTBEAT=1 / PI_MODE=print — this suite's own scenarios set them
// explicitly). Delete inherited markers at load so the INTERACTIVE tests run
// interactive regardless of a polluting parent env (mirrors the
// verification-gate e2e harness's load-time isolation: the polluted-parent
// class is exactly what #285 fixes).
delete process.env.TASK_HEARTBEAT;
delete process.env.PI_MODE;

import {
  extractPrNumber,
  extractRepoFlag,
  extractGhRepoEnv,
  extractCdPath,
  resolveRepoContext,
  repoFromGitRemote,
  parseCdChains,
  expandCdTarget,
  evaluateMergeGate,
  readReviewRecord,
  reviewRecordFile,
  logGateEvent,
  logMergeGateDecision,
  mergeGateBlockReason,
  isGraphQLRateLimitError,
  rateLimitMaxWaitMs,
  getPrHeadShaViaRest,
  getPrMergeBaseSha,
  getPrHeadSha,
  hasAdminMergeFlag,
  isGhPrMergeCommand,
  isAdminMergeCommand,
  countMergeVerbs,
  isGitOp,
  extractMergePrNumber,
  extractMergeSelector,
  evidenceBodyIsCertifying,
  evaluateAdminMergeGate,
  getPrComments,
  ACCEPTED_VERDICTS,
  isAcceptedVerdict,
  _setRunGhOverride,
  BLOCK_MESSAGE,
  MICRO_BLOCK_MESSAGE,
  TIER_RULE,
  default as reviewEnforcerFactory,
  resolveGhShimDir,
  materializeGhShim,
  NEUTRAL_GH_SHIM_DIR,
  withGhShim,
  type ReviewRecord,
} from "./index.js";
// #966: the shared parser module — the drift-pin below asserts this extension's
// exported helpers ARE these functions (one copy, not a lookalike).
import * as sharedParse from "../shared/git-command-parse.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { execSync } from "node:child_process";
import { resolve as resolvePath } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import * as fs from "node:fs";
import * as os from "node:os";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

// #1348: every audit-temp dir created by this suite, removed at exit. Declared
// up here because tests run at module-evaluation time — a declaration further
// down the file would be in its temporal dead zone when the first test runs.
const AUDIT_TMP_DIRS: string[] = [];
process.on("exit", () => {
  for (const d of AUDIT_TMP_DIRS) {
    try {
      fs.rmSync(d, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }
});

// ── #192: gh runner override ───────────────────────────
// index.ts routes gh calls through runGh(), which honors _setRunGhOverride().
// Tests swap in a fake runner (returns stdout or throws) and restore with null
// in finally — deterministic failure-path tests without real gh invocations.
function ghError(message: string): Error & { stderr?: string } {
  const e = new Error(message) as Error & { stderr?: string };
  e.stderr = message;
  return e;
}

// Async variant for extension-factory tests (pi handlers are async fns).
// Tests are stored as THUNKS and run strictly sequentially at the end (via
// top-level await) — they mutate process.env (HOME, skip vars), so concurrent
// execution would race. tsx executes this file as ESM.
const pending: Array<() => Promise<void>> = [];
function testAsync(name: string, fn: () => Promise<void>) {
  pending.push(async () => {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}`);
    }
  });
}

const cleanRecord: ReviewRecord = {
  pr: 138,
  head_sha: "a".repeat(40),
  verdict: "clean",
  reviewed_at: "2026-01-01T00:00:00Z",
  repo: "owner/repo",
};

// #1348 — a clean-low record carries the MERGE BASE its guard certified (the
// commit the three-dot diff is taken from), NOT the base branch's tip: the tip
// moves on every unrelated merge into the base branch while the certified diff is
// unchanged. Distinct from the head, so a swap is detectable.
const MERGE_BASE = "c".repeat(40);
const cleanLowRecord: ReviewRecord = { ...cleanRecord, verdict: "clean-low", merge_base_sha: MERGE_BASE };

// ── Drift-pin: ONE copy of the command parsers (#966) ─
//
// The behavioural truth table for the four helpers (incl. the corrected
// last-`cd`-wins rule and the #960 newline-terminated cd) now lives in
// extensions/shared/git-command-parse.test.ts. What is pinned HERE is that
// this extension has no private copy to drift again: its exported helpers ARE
// the shared module's functions. The source-shape half of the pin (neither
// index.ts declares the helpers locally) lives in verification-gate's suite.
// A reference identity in BOTH suites means the two extensions cannot
// disagree on any input — the state that produced the #966 contradiction.

section("drift-pin — shared command parsers (#966)");

test("the exported helpers ARE the shared module's functions (no per-extension copy)", () => {
  equal(extractCdPath, sharedParse.extractCdPath, "extractCdPath");
  equal(extractRepoFlag, sharedParse.extractRepoFlag, "extractRepoFlag");
  equal(extractGhRepoEnv, sharedParse.extractGhRepoEnv, "extractGhRepoEnv");
  equal(extractPrNumber, sharedParse.extractPrNumber, "extractPrNumber");
  equal(parseCdChains, sharedParse.parseCdChains, "parseCdChains");
  // expandCdTarget is re-exported by this extension too — pin it before the
  // source-shape half has to be the only guard against a private copy.
  equal(expandCdTarget, sharedParse.expandCdTarget, "expandCdTarget");
});

// ── resolveRepoContext priority ───────────────────────

section("resolveRepoContext — resolution priority (url > --repo > GH_REPO > cd > record > fallback)");

test("priority 1: --repo flag beats GH_REPO env", () => {
  const ctx = resolveRepoContext("GH_REPO=env/repo gh pr merge 138 --repo flag/repo", cleanRecord);
  equal(ctx.repo, "flag/repo");
  equal(ctx.source, "flag");
});

test("priority 1: a real --repo beats a repo MENTION in quoted prose", () => {
  // The safe half of the quote-unaware-flag gap (shared suite): the scan takes
  // its FIRST match, so a real flag before the prose still wins. Held even
  // though a mention with NO real flag is captured today (reported residual).
  const ctx = resolveRepoContext('gh pr merge 138 --repo acme/widget --body "see --repo evil/repo"', cleanRecord);
  equal(ctx.repo, "acme/widget");
  equal(ctx.source, "flag");
});

test("priority 2: GH_REPO env beats cd prefix", () => {
  const ctx = resolveRepoContext("cd /tmp && GH_REPO=env/repo gh pr merge 138", cleanRecord);
  equal(ctx.repo, "env/repo");
  equal(ctx.source, "env");
});

test("priority 3: cd prefix beats record.repo", () => {
  const ctx = resolveRepoContext("cd /tmp/foo && gh pr merge 138", cleanRecord);
  equal(ctx.cwd, resolvePath("/tmp/foo"));
  equal(ctx.source, "cd");
});

test("priority 4: record.repo used when command has no repo info", () => {
  const ctx = resolveRepoContext("gh pr merge 138", cleanRecord);
  equal(ctx.repo, "owner/repo");
  equal(ctx.source, "record");
});

test("priority 5: fallback (pi cwd) when nothing resolves", () => {
  const ctx = resolveRepoContext("gh pr merge 138", null);
  equal(ctx.repo, undefined);
  equal(ctx.cwd, undefined);
  equal(ctx.source, "fallback");
});

test("record.repo ignored when cd present even without record", () => {
  const ctx = resolveRepoContext("cd /tmp/foo && gh pr merge 138", null);
  equal(ctx.cwd, resolvePath("/tmp/foo"));
  equal(ctx.source, "cd");
});

// ── evaluateMergeGate ─────────────────────────────────

section("evaluateMergeGate — registry gate decisions");

test("block: no review record", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  equal(r.status, "block");
  ok((r as any).reason.includes("No review record"));
});

test("block: non-clean verdict", () => {
  const rec = { ...cleanRecord, verdict: "fail" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  ok((r as any).reason.includes('verdict "fail"'));
});

test("block: head mismatch (branch advanced since review)", () => {
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  ok((r as any).reason.includes("advanced"));
});

test("allow: clean verdict with matching head", () => {
  const r = evaluateMergeGate(138, cleanRecord, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
});

test("allow: clean-micro verdict with matching head", () => {
  const rec = { ...cleanRecord, verdict: "clean-micro" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
});

// ── #1348: the clean-low verdict (C7 head binding + C8 content binding) ──
// The local merge gate accepts clean-low when, and only when, the record is
// HEAD-bound AND its certified MERGE BASE is still the PR's merge base — the
// attestation is the three-dot diff, whose content that commit identifies. It
// does NOT re-derive the content shape: the record IS the attestation, and the
// only place the shape can be read is the producer's guard in record-review.sh.
// The tip-vs-merge-base distinction is observable only in getPrMergeBaseSha — the
// gate never receives a base tip — so the benign-ADVANCE invariance is pinned
// there, in the reader's section, not here.
test("allow: clean-low verdict with matching head AND merge base", () => {
  const r = evaluateMergeGate(
    138, cleanLowRecord, "a".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
  );
  equal(r.status, "allow");
  ok((r as any).message.includes("clean-low"), "pass message names the verdict it acted on");
});

test("block: clean-low with a REPOINTED base (gh pr edit --base) — same head, different merged diff", () => {
  // The exploit this closes: record clean-low on a docs-only diff off a base
  // that does not contain the unreviewed code, then re-point the PR at main.
  // A base edit does NOT change the head sha, so the head pin alone allows it.
  const r = evaluateMergeGate(
    138, cleanLowRecord, "a".repeat(40), { source: "record", repo: "owner/repo" }, false, "d".repeat(40)
  );
  equal(r.status, "block");
  equal((r as any).reasonTag, "base_advanced");
  ok((r as any).reason.includes("DIFFERENT merge base"), "refusal names the cause");
  // The remediation must name the verdict: position 3 of record-review.sh IS the
  // verdict, so `record-review.sh <PR> <sha> <owner/repo>` would treat the repo as
  // a verdict (exit 2), and omitting it would DEFAULT to `clean` — minting
  // exactly the false attestation this verdict exists to remove.
  ok((r as any).reason.includes("clean-low [owner/repo]"), "advice names the clean-low verdict");
  ok((r as any).reason.includes("clean [owner/repo]"), "advice names the clean fallback");
});

test("block: clean-low whose record carries NO usable merge base", () => {
  for (const rec of [
    { ...cleanRecord, verdict: "clean-low" },
    { ...cleanRecord, verdict: "clean-low", merge_base_sha: "not-a-sha" },
    { ...cleanRecord, verdict: "clean-low", merge_base_sha: "" },
    { ...cleanRecord, verdict: "clean-low", merge_base_sha: "C".repeat(40) },
  ]) {
    const r = evaluateMergeGate(
      138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
    );
    equal(r.status, "block", `merge base ${JSON.stringify(rec.merge_base_sha)} blocks`);
    equal((r as any).reasonTag, "base_unverifiable", "absence is UNVERIFIABLE, not ADVANCED");
  }
});

test("block: clean-low with an UNREADABLE merge base (gh failure) — fail-closed, not #138 fail-open", () => {
  const r = evaluateMergeGate(
    138, cleanLowRecord, "a".repeat(40), { source: "record", repo: "owner/repo" }, false, null
  );
  equal(r.status, "block");
  equal((r as any).reasonTag, "base_unverifiable");
  ok((r as any).reason.includes("unreadable"), "refusal says the merge base could not be read");
});

test("audit: base_advanced and base_unverifiable are DISTINCT from each other and from head_advanced", () => {
  // The machine tag is what reconstructs block rates by reason, so "the
  // attestation was invalidated" must not look like "we could not read it".
  const cases: Array<[string | null, string]> = [
    ["d".repeat(40), "base_advanced"],
    [null, "base_unverifiable"],
  ];
  for (const [current, want] of cases) {
    const file = tempAuditFile();
    const r = evaluateMergeGate(
      138, cleanLowRecord, "a".repeat(40), { source: "record", repo: "owner/repo" }, false, current
    );
    logMergeGateDecision(138, r as any, cleanLowRecord, file);
    equal(readAuditLines(file)[0].reason, want, `tag for current=${current}`);
  }
  // A moved head keeps its own tag (the head is checked first).
  const f2 = tempAuditFile();
  const headR = evaluateMergeGate(
    138, cleanLowRecord, "b".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
  );
  logMergeGateDecision(138, headR as any, cleanLowRecord, f2);
  equal(readAuditLines(f2)[0].reason, "head_advanced");
});

test("scope: clean/clean-micro records stay merge-base-BLIND (shape unchanged, #1362)", () => {
  // Deliberate: their record carries no merge_base_sha at all, so the C8 branch is
  // clean-low-scoped. Widening it here would change a record schema and a gate
  // decision for the two pre-existing verdicts — filed as agent-infra #1362.
  for (const v of ["clean", "clean-micro"]) {
    const r = evaluateMergeGate(
      138, { ...cleanRecord, verdict: v }, "a".repeat(40),
      { source: "record", repo: "owner/repo" }, false, "d".repeat(40)
    );
    equal(r.status, "allow", `${v} is not merge-base-bound`);
  }
});

test("block: clean-low with an advanced head (same binding as clean)", () => {
  const r = evaluateMergeGate(
    138, cleanLowRecord, "b".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
  );
  equal(r.status, "block");
  ok((r as any).reason.includes("advanced"));
});

test("block: clean-low with an advanced head → reason head_advanced, not verdict_not_clean", () => {
  equal(mergeGateBlockReason(cleanLowRecord), "head_advanced");
  const file = tempAuditFile();
  const r = evaluateMergeGate(
    138, cleanLowRecord, "b".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
  );
  logMergeGateDecision(138, r as any, cleanLowRecord, file);
  equal(readAuditLines(file)[0].reason, "head_advanced");
});

test("clean-low head-advanced advice RE-DERIVES the shape instead of prescribing the same verdict", () => {
  // A moved head that brought code is refused by the producer's guard (exit 4),
  // so "re-record at the same verdict: … clean-low" would be unsatisfiable in
  // exactly the case that fires it. clean-low's claim is about the diff's SHAPE,
  // not about reaching a tier through a flow.
  const r = evaluateMergeGate(
    138, cleanLowRecord, "b".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
  );
  const reason = (r as any).reason as string;
  ok(reason.includes("content-only"), "advice names the shape re-check");
  ok(reason.includes("clean-low [owner/repo]"), "advice names the verdict in the clean-low branch");
  ok(reason.includes("clean [owner/repo]"), "advice names the clean fallback");
  // The SAME-verdict advice must survive for the tier-bearing verdicts (#513).
  for (const v of ["clean", "clean-micro"]) {
    const rr = evaluateMergeGate(
      138, { ...cleanRecord, verdict: v }, "b".repeat(40), { source: "record", repo: "owner/repo" }
    );
    ok((rr as any).reason.includes(v), `${v} keeps the same-verdict re-record advice`);
  }
});

test("block: clean-low with an unverifiable head does NOT fail open for a task sub-agent", () => {
  const r = evaluateMergeGate(138, cleanLowRecord, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
});

test("vocabulary is CLOSED: an out-of-vocabulary verdict still blocks", () => {
  // Widening the accepted set to `clean-low` must not become `verdict=.*` —
  // a near-miss token (clean-high, clean-lowx, CLEAN-LOW) stays refused.
  for (const v of ["clean-high", "clean-lowx", "CLEAN-LOW", "clean-microx", "", "fail"]) {
    const rec = { ...cleanRecord, verdict: v };
    equal(isAcceptedVerdict(v), false, `isAcceptedVerdict(${JSON.stringify(v)}) is false`);
    equal(mergeGateBlockReason(rec), "verdict_not_clean");
    const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
    equal(r.status, "block", `verdict ${JSON.stringify(v)} blocks`);
    ok((r as any).reason.includes("clean-low"), "refusal names the full accepted vocabulary");
  }
});

test("vocabulary: ACCEPTED_VERDICTS is exactly the three verdicts (single source of truth)", () => {
  // Asserted against a LITERAL, not by iterating the list under test: the
  // earlier form (`for (const v of ACCEPTED_VERDICTS) ok(isAcceptedVerdict(v))`)
  // could not fail — isAcceptedVerdict IS `ACCEPTED_VERDICTS.includes`, so the
  // loop only ever asserted the list contains itself.
  equal(ACCEPTED_VERDICTS.join(","), "clean,clean-micro,clean-low");
  ok(isAcceptedVerdict("clean") && isAcceptedVerdict("clean-micro") && isAcceptedVerdict("clean-low"));
});

test("declared boundary: the local gate does NOT re-derive the content shape", () => {
  // #1348 declares this out of scope deliberately: a local shape re-check would
  // be a second, weaker writer of the Low class. Pinned as OBSERVABLES, not as
  // another `status === "allow"` on an already-allowed record (which a later
  // shape re-check that happened to allow this diff would leave green):
  //   (a) the pure gate decision issues no gh/API call of its own;
  //   (b) the extension never reads the file LIST (`pulls/N/files`) — the input
  //       any local shape re-check would need;
  //   (c) the merge base it does read is the ONLY revision read added for it.
  // It does NOT prove the hook's call site adds no other read; the call-site
  // fetch set is asserted in the C8 tests above (the fetch happens only for a
  // clean-low record whose head already matched).
  const cmds: string[] = [];
  _setRunGhOverride((cmd) => { cmds.push(cmd); return "a".repeat(40); });
  try {
    const r = evaluateMergeGate(
      138, cleanLowRecord, "a".repeat(40), { source: "record", repo: "owner/repo" }, false, MERGE_BASE
    );
    equal(r.status, "allow");
  } finally {
    _setRunGhOverride(null);
  }
  equal(cmds.length, 0, "the pure gate decision issues no gh/API call of its own");
  const src = fs.readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  // (An assertion that a bash identifier from record-review.sh is absent here
  // would be unconditionally true — the reviewer reproduced that tautology. So
  // would a BARE `src.includes(".merge_base_commit.sha")`, which the module's own
  // COMMENTS satisfy: it stayed green when the jq filter was mutated back to
  // `.base.sha`. Both assertions below are pinned to the EXPRESSION, not to a
  // substring that prose can supply.)
  ok(
    !/pulls\/[^\s"'`]*\/files|--json\s+[^\s"']*files/.test(src),
    "no file-list read (REST `pulls/N/files` or `--json files`) — a local shape re-check would need one"
  );
  ok(
    /compare\/[^\s"'`]*\s--jq\s\.merge_base_commit\.sha/.test(src),
    "the compare read's jq filter is merge_base_commit.sha, not the base tip"
  );
});

test("C7 drift pin: the verdict vocabulary is CONSULTED, never re-literalised", () => {
  // The pre-change code expressed the vocabulary ad hoc, twice, as
  // `record.verdict !== "clean" && record.verdict !== "clean-micro"`. That is
  // exactly what this change replaced, and exactly what must not come back —
  // a re-introduced literal comparison would silently exclude clean-low at one
  // site. A source-shape pin (the repo's drift-pin idiom) is the durable form
  // of the RED claim: the pre-change expression is asserted ABSENT.
  const src = fs.readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  ok(!/record\.verdict !== "clean"/.test(src), "no ad-hoc `record.verdict !== \"clean\"` comparison");
  ok(!/record\.verdict === "clean"/.test(src), "no ad-hoc `record.verdict === \"clean\"` comparison");
  // Both acceptance sites must route through the shared predicate — asserted
  // STRUCTURALLY (by the surrounding expression), not by counting occurrences of
  // a substring, which a COMMENT satisfied while the real call was replaced.
  const declLine = src.split("\n").find((l) => l.includes("export const ACCEPTED_VERDICTS")) ?? "";
  ok(declLine.includes("clean-low"), "the declaration lists clean-low");
  ok(
    /if \(!isAcceptedVerdict\(record\.verdict\)\) \{/.test(src),
    "the allowlist consults isAcceptedVerdict as its predicate"
  );
  const blockFn = src.slice(src.indexOf("export function mergeGateBlockReason"));
  const blockBody = blockFn.slice(0, blockFn.indexOf("\n}"));
  ok(
    blockBody.includes("isAcceptedVerdict(record.verdict)"),
    "mergeGateBlockReason consults isAcceptedVerdict IN ITS BODY"
  );
  // The refusal message must be DERIVED from the vocabulary, not re-listed. The
  // earlier attempt pinned "no line outside the declaration names 2+ verdicts",
  // which is unsatisfiable (the remediation lines must NAME the verdict to use)
  // and which a differently-ordered/multi-line re-listing evaded. Pin the
  // mechanism instead: the message site must reference the list, and the message
  // ITSELF must name every member of the list — so a 4th verdict added to
  // ACCEPTED_VERDICTS without updating the message fails the behavioural test.
  const msgLine = src.split("\n").find((l) => l.includes("unlocks a merge")) ?? "";
  ok(
    msgLine.includes("ACCEPTED_VERDICTS"),
    `the refusal message is DERIVED from the vocabulary (found: ${msgLine.trim()})`
  );
  ok(!/"clean"\s*,\s*"clean-micro"/.test(msgLine), "the refusal message does not hard-code the list");
});

test("the out-of-vocabulary refusal NAMES every accepted verdict (derivation, not a literal)", () => {
  // Iterating the LIVE list is the point: if a verdict is added to
  // ACCEPTED_VERDICTS and the message keeps its own copy of the old set, this
  // fails. That is the drift the single-source-of-truth claim is about.
  const r = evaluateMergeGate(
    138, { ...cleanRecord, verdict: "bogus" }, "a".repeat(40),
    { source: "record", repo: "owner/repo" }
  );
  equal(r.status, "block");
  for (const v of ACCEPTED_VERDICTS) {
    ok((r as any).reason.includes(`"${v}"`), `refusal names the accepted verdict ${v}`);
  }
  equal(
    ((r as any).reason.match(/"clean(-micro|-low)?"/g) ?? []).length,
    ACCEPTED_VERDICTS.length,
    "refusal names exactly the accepted vocabulary — no more, no less"
  );
});

test("fail-open: unresolvable repo (fallback) → warning with repo advice, not block", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "fallback" });
  equal(r.status, "failopen");
  ok((r as any).warning.includes("--repo owner/repo"));
  ok((r as any).warning.includes("fallback") || (r as any).warning.includes("fell back"));
});

test("fail-open: gh error even with resolved repo → warning, not block", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" });
  equal(r.status, "failopen");
  ok((r as any).warning.includes("WITHOUT head verification"));
});

// ── readReviewRecord (read-only smoke) ────────────────

section("readReviewRecord — record I/O");

test("null for a non-existent PR record (no files touched)", () => {
  equal(readReviewRecord(99999999), null);
});

// ── #426 repo-qualified registry (cross-repo PR-number collisions) ───
// Every FS-touching test runs under withTempHome (temp $HOME): both the
// reviews dir AND the audit log (~/.pi/agent/audit/gate-events.jsonl, written
// by readReviewRecord's collision audit) resolve from $HOME per call — real
// agent state is never touched (review P2-2). Unique PR numbers, cleanups in
// finally inside the temp home (the dir itself is removed by withTempHome).
const PR_CLEAN = 900201;
const PR_MIGRATE = 900202;
const PR_COLLIDE = 900203;
const PR_NOREPO = 900204;
const PR_FOREIGN_NOARG = 900205;

function writeReviewFile(file: string, body: Record<string, unknown>): void {
  fs.mkdirSync(resolvePath(os.homedir(), ".pi", "agent", "reviews"), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(body));
}

function tempAuditLines(): Record<string, any>[] {
  const audit = resolvePath(os.homedir(), ".pi", "agent", "audit", "gate-events.jsonl");
  if (!fs.existsSync(audit)) return [];
  return fs
    .readFileSync(audit, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

section("#426 readReviewRecord — repo-qualified keying");

test("qualified file for THIS repo is read", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    const rec = readReviewRecord(PR_CLEAN, "daniel-ospina/agent-infra");
    ok(rec !== null, "record found via qualified key");
    equal(rec?.repo, "daniel-ospina/agent-infra", "repo field intact");
  });
});

test("ANOTHER repo's qualified file does not satisfy this repo's gate", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/DMeer", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/DMeer" });
    equal(readReviewRecord(PR_CLEAN, "daniel-ospina/agent-infra"), null, "DMeer record invisible to agent-infra gate");
  });
});

test("qualified file whose EMBEDDED repo disagrees with the slug → null (P2-1 identical-slug defense)", async () => {
  await withTempHome(async () => {
    // Same physical slug path, content claims a DIFFERENT repo (identical-slug
    // overwrite across owners a-b/c vs a/b-c, or tampering).
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "premise-labs/other" });
    equal(readReviewRecord(PR_CLEAN, "daniel-ospina/agent-infra"), null, "embedded-repo mismatch fails closed");
    const last = tempAuditLines().filter((l) => l.event === "review_record_collision" && l.pr === PR_CLEAN).at(-1);
    ok(!!last && last.recordRepo === "premise-labs/other", "mismatch audited");
  });
});

test("slug parity: TS slug matches the bash ${REPO%%/*}-${REPO#*/} contract", () => {
  // record-review.sh derives the filename the same way; a drift (e.g. one side
  // using "_") would break every repo'd flow with no other test catching it.
  equal(reviewRecordFile("premise-labs/agent-infra", PR_CLEAN).endsWith("premise-labs-agent-infra-" + PR_CLEAN + ".json"), true);
  equal(reviewRecordFile("daniel-ospina/DMeer", PR_CLEAN).endsWith("daniel-ospina-DMeer-" + PR_CLEAN + ".json"), true);
  equal(reviewRecordFile("a-b/c", PR_CLEAN).endsWith("a-b-c-" + PR_CLEAN + ".json"), true, "dash owner+repo single-separator contract");
  equal(reviewRecordFile("a/b-c", PR_CLEAN).endsWith("a-b-c-" + PR_CLEAN + ".json"), true, "identical slug for the cross-owner collision class");
});

test("legacy <pr>.json migration fallback: matching repo still read (pre-#426 records)", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_MIGRATE), {
      pr: PR_MIGRATE, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    ok(readReviewRecord(PR_MIGRATE, "daniel-ospina/agent-infra") !== null, "legacy record with matching repo read (migration)");
  });
});

test("legacy record from ANOTHER repo → null (the real #426 collision) + audited", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_COLLIDE), {
      pr: PR_COLLIDE, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/DMeer" });
    equal(readReviewRecord(PR_COLLIDE, "daniel-ospina/agent-infra"), null, "foreign legacy record fails closed");
    const last = tempAuditLines().filter((l) => l.event === "review_record_collision" && l.pr === PR_COLLIDE).at(-1);
    ok(!!last && last.recordRepo === "daniel-ospina/DMeer" && last.gateRepo === "daniel-ospina/agent-infra",
      "collision audited with both repos (temp home)");
  });
});

test("repo-less legacy record (predates repo field) still read via repo'd fallback", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_NOREPO), { pr: PR_NOREPO, head_sha: "a".repeat(40), verdict: "clean" });
    ok(readReviewRecord(PR_NOREPO, "daniel-ospina/agent-infra") !== null,
      "pre-repo-field record readable (can't prove repo — trusted legacy)");
  });
});

test("NO repo context: repo-less legacy still read (cannot be foreign)", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_NOREPO), { pr: PR_NOREPO, head_sha: "a".repeat(40), verdict: "clean" });
    ok(readReviewRecord(PR_NOREPO) !== null, "repo-less legacy readable with no repo context");
  });
});

test("NO repo context: repo'd legacy from another repo REJECTED (review P0-2 false-allow)", async () => {
  await withTempHome(async () => {
    // The exact #426 shape: DMeer#<pr>'s record sits at <pr>.json; the gate has
    // no repo signal (no flag/env/cd/remote). It must NOT satisfy the merge —
    // nor drive the head lookup for DMeer's PR — so it fails closed + audits.
    writeReviewFile(reviewRecordFile(undefined, PR_FOREIGN_NOARG), {
      pr: PR_FOREIGN_NOARG, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/DMeer" });
    equal(readReviewRecord(PR_FOREIGN_NOARG), null, "foreign repo'd legacy rejected with no repo context");
    const last = tempAuditLines().filter((l) => l.event === "review_record_collision" && l.pr === PR_FOREIGN_NOARG).at(-1);
    ok(!!last && last.recordRepo === "daniel-ospina/DMeer", "rejection audited (gateRepo null = no repo signal)");
  });
});

test("NO repo context: single matching qualified file is its own repo proof", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    const rec = readReviewRecord(PR_CLEAN);
    ok(rec !== null, "unique qualified file resolves its own repo");
    equal(rec?.repo, "daniel-ospina/agent-infra", "repo derived from filename");
  });
});

test("NO repo context: ambiguous multi-owner qualified files → null (cannot pick)", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    writeReviewFile(reviewRecordFile("premise-labs/foo", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "premise-labs/foo" });
    equal(readReviewRecord(PR_CLEAN), null, "ambiguous qualified set fails closed");
  });
});

section("#426 repoFromGitRemote — merge-environment repo resolution (P0-1)");

test("origin remote (ssh form) resolves owner/name", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    execSync(`git init -q "${dir}"`, { stdio: "ignore" });
    execSync(`git -C "${dir}" remote add origin git@github.com:daniel-ospina/agent-infra.git`, { stdio: "ignore" });
    equal(repoFromGitRemote(dir), "daniel-ospina/agent-infra", "ssh remote parsed");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("origin remote (https form, no .git) resolves owner/name", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    execSync(`git init -q "${dir}"`, { stdio: "ignore" });
    execSync(`git -C "${dir}" remote add origin https://github.com/premise-labs/agent-infra`, { stdio: "ignore" });
    equal(repoFromGitRemote(dir), "premise-labs/agent-infra", "https remote parsed");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("non-git dir → null", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    equal(repoFromGitRemote(dir), null, "no origin → null (caller falls back)");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("non-GitHub origin → null", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    execSync(`git init -q "${dir}"`, { stdio: "ignore" });
    execSync(`git -C "${dir}" remote add origin git@gitlab.com:other/thing.git`, { stdio: "ignore" });
    equal(repoFromGitRemote(dir), null, "gitlab origin → null (gate only knows GitHub repos)");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});


// ── Durable audit trail (#60) — log helpers ───────────

section("logGateEvent — durable JSONL audit append (#60)");

function tempAuditFile(): string {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-audit-"));
  // These used to accumulate one directory per call (413 were observed in
  // $TMPDIR). Register the dir for removal at process exit so every suite run
  // cleans up after itself.
  AUDIT_TMP_DIRS.push(dir);
  return resolvePath(dir, "gate-events.jsonl");
}

function readAuditLines(file: string): Record<string, any>[] {
  return fs
    .readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function auditLogPath(): string {
  return resolvePath(os.homedir(), ".pi", "agent", "audit", "gate-events.jsonl");
}

test("writes one JSONL entry with schema {ts, event, extension, reason?, session_cwd}", () => {
  const file = tempAuditFile();
  logGateEvent("gate_bypass", { reason: "escape_hatch" }, file);
  const [e] = readAuditLines(file);
  ok(typeof e.ts === "string" && !isNaN(Date.parse(e.ts)), "ts is an ISO timestamp");
  equal(e.event, "gate_bypass");
  equal(e.extension, "review-enforcer");
  equal(e.reason, "escape_hatch");
  equal(e.session_cwd, process.cwd());
});

test("appends append-only, one JSONL line per event", () => {
  const file = tempAuditFile();
  logGateEvent("review_dispatch", { dispatch_count: 1 }, file);
  logGateEvent("review_dispatch", { dispatch_count: 2 }, file);
  const lines = readAuditLines(file);
  equal(lines.length, 2);
  equal(lines[0].dispatch_count, 1);
  equal(lines[1].dispatch_count, 2);
});

// ── logMergeGateDecision / mergeGateBlockReason ──────

section("logMergeGateDecision — block/pass audit entries");

test("block with no record → merge_gate_block reason no_review_record", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, null, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_block");
  equal(e.pr, 138);
  equal(e.reason, "no_review_record");
});

test("block with non-clean verdict → reason verdict_not_clean", () => {
  const file = tempAuditFile();
  const rec = { ...cleanRecord, verdict: "fail" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, rec, file);
  equal(readAuditLines(file)[0].reason, "verdict_not_clean");
});

test("block with head mismatch → reason head_advanced", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  equal(readAuditLines(file)[0].reason, "head_advanced");
});

test("allow → merge_gate_pass with pr, no reason", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, "a".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "allow");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_pass");
  equal(e.pr, 138);
  equal(e.reason, undefined);
});

test("fail-open → merge_gate_pass with reason failopen (auditable allow-without-verification)", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "fallback" });
  ok(r.status === "failopen");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_pass");
  equal(e.reason, "failopen");
  equal(e.verdict, "clean", "#513: failopen entry carries the verdict (only allow-without-verification site)");
});

test("mergeGateBlockReason tags mirror evaluateMergeGate block branches", () => {
  equal(mergeGateBlockReason(null), "no_review_record");
  equal(mergeGateBlockReason({ ...cleanRecord, verdict: "fail" }), "verdict_not_clean");
  equal(mergeGateBlockReason(cleanRecord), "head_advanced");
});

// ── #192: GraphQL rate-limit resilience ────────────────
section("isGraphQLRateLimitError — GraphQL pool exhaustion signature");
test("matches gh's GraphQL exhaustion message", () => {
  ok(isGraphQLRateLimitError("GraphQL: API rate limit already exceeded for user ID 81560491"), "full gh message");
  ok(isGraphQLRateLimitError("API rate limit already exceeded"), "bare exhausted message");
  ok(isGraphQLRateLimitError("api rate limit exceeded while calling graphql"), "case-insensitive graphql mention");
});
test("does not match unrelated gh errors", () => {
  ok(!isGraphQLRateLimitError("HTTP 404: Not Found"), "404");
  ok(!isGraphQLRateLimitError("gh: command not found"), "missing gh");
  ok(!isGraphQLRateLimitError(""), "empty string");
  ok(!isGraphQLRateLimitError("Could not resolve to a PullRequest"), "GraphQL resolution error, not rate limit");
});

section("rateLimitMaxWaitMs — #192 cap (env-overridable)");
test("defaults to 600000 (10 min)", () => {
  const prev = process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  try { equal(rateLimitMaxWaitMs(), 600000); }
  finally { if (prev === undefined) delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS; else process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = prev; }
});
test("respects env override; invalid values fall back to default", () => {
  const prev = process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  try {
    process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "120000";
    equal(rateLimitMaxWaitMs(), 120000);
    process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "abc";
    equal(rateLimitMaxWaitMs(), 600000);
    process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "0";
    equal(rateLimitMaxWaitMs(), 600000);
  } finally {
    if (prev === undefined) delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS; else process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = prev;
  }
});

// ── #192: REST fallback for GraphQL pool exhaustion ───
section("getPrMergeBaseSha — content binding for clean-low (#1348)");

test("resolves the merge base and builds the compare URL from the BASE and the head", () => {
  const cmds: string[] = [];
  let env: any = null;
  _setRunGhOverride((cmd, opts) => {
    cmds.push(cmd);
    env = opts;
    return cmd.includes("compare/")
      ? "c".repeat(40)
      : "b".repeat(40);
  });
  try {
    equal(
      getPrMergeBaseSha(138, "a".repeat(40), { source: "flag", repo: "owner/repo" }),
      "c".repeat(40)
    );
  } finally {
    _setRunGhOverride(null);
  }
  equal(cmds.length, 2, "two reads: the base sha, then the merge base");
  ok(cmds[0].includes("pulls/138"), `first read targets the PR: ${cmds[0]}`);
  ok(
    cmds[1].includes(`compare/${"b".repeat(40)}...${"a".repeat(40)}`),
    `the compare is BASE...HEAD, the exact diff the producer certified: ${cmds[1]}`
  );
  // The FIELD is the token that distinguishes this binding from the rejected
  // tip binding, and every stub matches on `compare/` rather than on the jq
  // filter — so without this assertion a one-token rewrite back to `.base.sha`
  // (which would re-point every clean-low record at the moving tip) stays green.
  ok(
    cmds[1].includes(".merge_base_commit.sha"),
    `the compare reads merge_base_commit, never base.sha: ${cmds[1]}`
  );
  // `gh api` does NOT accept --repo — the repo comes via GH_REPO env.
  ok(!cmds[1].includes("--repo") && !cmds[1].includes("-R "), `no --repo flag: ${cmds[1]}`);
  ok(env?.env?.GH_REPO === "owner/repo", "repo injected via GH_REPO env");
});

test("the binding is the MERGE BASE, not the base branch's tip — a benign ADVANCE is invisible", () => {
  // The false block that binding `.base.sha` (the base branch's TIP) would
  // produce: main advances with unrelated commits, the merge base of an
  // unchanged head is the SAME commit, the certified diff is identical — so the
  // gate must see the same value and allow. This is the only place the tip is
  // observable: `evaluateMergeGate` never receives it, so a gate-level case with
  // the tip moved would pass for the same reason the matching-merge-base test
  // above passes and would pin nothing (the reviewer reproduced exactly that).
  const tips = ["b".repeat(40), "e".repeat(40)];
  const seen: string[] = [];
  _setRunGhOverride((cmd) => {
    if (cmd.includes("compare/")) return "c".repeat(40); // merge base: unchanged
    const tip = tips.shift() ?? "e".repeat(40);
    seen.push(tip); // the base branch TIP: advanced between the two reads
    return tip;
  });
  try {
    equal(getPrMergeBaseSha(138, "a".repeat(40), { source: "flag", repo: "owner/repo" }), "c".repeat(40));
    equal(
      getPrMergeBaseSha(138, "a".repeat(40), { source: "flag", repo: "owner/repo" }),
      "c".repeat(40),
      "the base tip advancing must not change what the reader binds to"
    );
    ok(seen[0] !== seen[1], `the two reads really saw different tips, else this pins nothing (${seen.join(", ")})`);
  } finally {
    _setRunGhOverride(null);
  }
});

test("null when the COMPARE call throws after a good base sha (a throw must never reach the hook)", () => {
  // The wrapper's contract is "null on ANY failure", and the merge hook relies
  // on it never throwing. The first call succeeding is what makes this the
  // compare arm: a throw on the first call returns before the compare is built.
  let calls = 0;
  _setRunGhOverride((cmd) => {
    calls += 1;
    if (cmd.includes("compare/")) throw new Error("connection reset by peer");
    return "b".repeat(40);
  });
  try {
    equal(getPrMergeBaseSha(138, "a".repeat(40), { source: "record", repo: "owner/repo" }), null);
    equal(calls, 2, "the compare WAS attempted and its throw swallowed");
  } finally {
    _setRunGhOverride(null);
  }
});

test("null when the base sha is unreadable or not a full sha (no compare call is made)", () => {
  for (const bad of ["", "branch-name", "b".repeat(39), "b".repeat(41), "B".repeat(40)]) {
    const cmds: string[] = [];
    _setRunGhOverride((cmd) => { cmds.push(cmd); return bad; });
    try {
      equal(
        getPrMergeBaseSha(138, "a".repeat(40), { source: "record", repo: "owner/repo" }),
        null,
        `base ${JSON.stringify(bad)} → null`
      );
    } finally {
      _setRunGhOverride(null);
    }
    equal(cmds.length, 1, "an invalid base sha short-circuits before the compare call");
  }
});

test("null when the compare response carries no usable merge base", () => {
  for (const bad of ["", "not-a-sha", "c".repeat(39), "C".repeat(40)]) {
    _setRunGhOverride((cmd) => (cmd.includes("compare/") ? bad : "b".repeat(40)));
    try {
      equal(
        getPrMergeBaseSha(138, "a".repeat(40), { source: "record", repo: "owner/repo" }),
        null,
        `merge base ${JSON.stringify(bad)} → null`
      );
    } finally {
      _setRunGhOverride(null);
    }
  }
});

test("null when gh throws (fail-closed input to the gate, never a partial value)", () => {
  _setRunGhOverride(() => { throw new Error("connection refused"); });
  try {
    equal(
      getPrMergeBaseSha(138, "a".repeat(40), { source: "record", repo: "owner/repo" }),
      null
    );
  } finally {
    _setRunGhOverride(null);
  }
});

test("null without any gh call when the head is null or not a full sha", () => {
  const cmds: string[] = [];
  _setRunGhOverride((cmd) => { cmds.push(cmd); return "c".repeat(40); });
  try {
    equal(getPrMergeBaseSha(138, null, { source: "record", repo: "owner/repo" }), null);
    equal(getPrMergeBaseSha(138, "a".repeat(39), { source: "record", repo: "owner/repo" }), null);
  } finally {
    _setRunGhOverride(null);
  }
  equal(cmds.length, 0, "an unusable head issues no API call at all");
});

section("getPrHeadShaViaRest — REST-pool head lookup (#192)");

test("resolves the head SHA via the REST pulls endpoint", () => {
  _setRunGhOverride(() => "a".repeat(40));
  try {
    equal(getPrHeadShaViaRest(138, { source: "record", repo: "owner/repo" }), "a".repeat(40));
  } finally {
    _setRunGhOverride(null);
  }
});

test("null when the REST call fails (REST pool also down / network)", () => {
  _setRunGhOverride(() => { throw new Error("connection refused"); });
  try {
    equal(getPrHeadShaViaRest(138, { source: "record", repo: "owner/repo" }), null);
  } finally {
    _setRunGhOverride(null);
  }
});

test("builds the pulls URL and injects the repo via GH_REPO env when ctx.repo is set", () => {
  let captured = "";
  let capturedEnv: any = null;
  _setRunGhOverride((cmd, opts) => { captured = cmd; capturedEnv = opts; return "a".repeat(40); });
  try {
    getPrHeadShaViaRest(138, { source: "flag", repo: "owner/repo" });
    ok(captured.includes("pulls/138"), `command targets the PR: ${captured}`);
    // `gh api` does NOT accept --repo (gh 2.97.0: "unknown flag") — the repo
    // must come via GH_REPO env (the documented placeholder source).
    ok(!captured.includes("--repo") && !captured.includes("-R "), `no --repo flag: ${captured}`);
    equal((capturedEnv as any)?.env?.GH_REPO, "owner/repo", "GH_REPO env injected for placeholder resolution");
  } finally {
    _setRunGhOverride(null);
  }
});

test("record.repo with shell metacharacters → record rejected (fail-closed, security)", () => {
  // readReviewRecord must reject a malicious repo field (interpolated into
  // shell strings by the gate) — treated as absent. Uses a PR number that
  // cannot collide with a real record; cleanup in finally.
  const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
  const f = resolvePath(reviews, "999.json");
  fs.mkdirSync(reviews, { recursive: true });
  try {
    fs.writeFileSync(f, JSON.stringify({ pr: 999, head_sha: "a".repeat(40), verdict: "clean", repo: "owner/x; echo pwned" }));
    equal(readReviewRecord(999), null, "malicious record.repo → null (fail-closed)");
  } finally {
    fs.rmSync(f, { force: true });
  }
});

section("getPrHeadSha — GraphQL exhaustion → REST fallback before waiting (#192)");

testAsync("gh pr view rate-limited → head resolved via REST without waiting (regression)", async () => {
  let viewCalls = 0;
  _setRunGhOverride((cmd) => {
    if (cmd.startsWith("gh pr view")) {
      viewCalls++;
      throw ghError("GraphQL: API rate limit already exceeded for user ID 81560491");
    }
    if (cmd.startsWith("gh api repos/{owner}/{repo}/pulls/")) return "b".repeat(40);
    throw new Error("unexpected command: " + cmd);
  });
  try {
    const sha = await getPrHeadSha(138, { source: "record", repo: "owner/repo" });
    equal(sha, "b".repeat(40));
    ok(viewCalls === 1, `gh pr view attempted once (${viewCalls}) before REST fallback`);
  } finally {
    _setRunGhOverride(null);
  }
});

testAsync("non-rate-limit gh failure → null (fail-open #138), REST fallback NOT attempted", async () => {
  let restCalls = 0;
  _setRunGhOverride((cmd) => {
    if (cmd.startsWith("gh pr view")) throw ghError("HTTP 404: Not Found");
    if (cmd.startsWith("gh api")) restCalls++;
    return "";
  });
  try {
    const sha = await getPrHeadSha(138, { source: "record", repo: "owner/repo" });
    equal(sha, null);
    equal(restCalls, 0, "REST fallback is only for GraphQL rate-limit errors");
  } finally {
    _setRunGhOverride(null);
  }
});

testAsync("GraphQL rate-limited AND REST down → waits for reset, then retries gh pr view", async () => {
  // Cap the wait so the test finishes fast: env override → 150ms total budget.
  const prevCap = process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "150";
  let viewCalls = 0;
  let rateLimitCalls = 0;
  _setRunGhOverride((cmd) => {
    if (cmd.startsWith("gh pr view")) {
      viewCalls++;
      throw ghError("GraphQL: API rate limit already exceeded for user ID 81560491");
    }
    if (cmd.startsWith("gh api repos/{owner}/{repo}/pulls/")) {
      throw new Error("REST pool also exhausted"); // both pools down
    }
    if (cmd.startsWith("gh api rate_limit")) {
      rateLimitCalls++;
      return Math.floor(Date.now() / 1000).toString(); // reset "now" → short wait
    }
    return "";
  });
  try {
    // Exhausts the tiny budget → fails open (null) after retry attempts.
    const sha = await getPrHeadSha(138, { source: "record", repo: "owner/repo" });
    equal(sha, null);
    ok(viewCalls >= 2, `retried gh pr view after the wait (${viewCalls} attempts)`);
    ok(rateLimitCalls >= 1, `polled gh api rate_limit for the reset window (${rateLimitCalls})`);
  } finally {
    _setRunGhOverride(null);
    if (prevCap === undefined) delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS; else process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = prevCap;
  }
});



// ── Extension factory — audited gate behavior (#60) ──
// The handlers registered by the factory are async functions with NO awaits
// in the exercised paths, so invoking them executes the body synchronously —
// assertions after fire() are safe without awaiting.

section("extension factory — audited gate behavior (#60)");

function mockPi() {
  const handlers = new Map<string, Function[]>();
  const pi = {
    on: (ev: string, fn: Function) => {
      const arr = handlers.get(ev) ?? [];
      arr.push(fn);
      handlers.set(ev, arr);
    },
  };
  return {
    pi,
    fire: (ev: string, event?: any): any => {
      const arr = handlers.get(ev) ?? [];
      let last: any;
      for (const fn of arr) last = fn(event ?? {}, {});
      return last;
    },
  };
}

// os.homedir() honors $HOME on POSIX — temp HOME redirects BOTH the audit log
// and the reviews dir without touching the real agent state. Async-aware:
// env is restored only AFTER the async body settles (a sync finally would
// restore HOME before the post-await continuations read it).
async function withTempHome(fn: () => Promise<void>): Promise<void> {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-home-"));
  const prevHome = process.env.HOME;
  process.env.HOME = dir;
  try {
    await fn();
  } finally {
    process.env.HOME = prevHome;
    fs.rmSync(dir, { recursive: true, force: true }); // no re-home-* leaks (P3-1)
  }
}

// The 0-dispatch block path reads /tmp/agent-issue-complexity — since #485 the
// marker selects ONLY the remediation message (micro → MICRO_BLOCK_MESSAGE,
// which must not reference the skipped code-review gate; every tier blocks).
// Save/restore so a stale real-session marker cannot flip expectations — and
// remove the marker the test body wrote when none pre-existed (bidirectional,
// mirroring withTempHome: a leaked "micro" file would misdirect a REAL session's
// subsequent 0-dispatch git op into the micro remediation message).
async function withMarkerIsolated(fn: () => Promise<void>): Promise<void> {
  const marker = "/tmp/agent-issue-complexity";
  const had = fs.existsSync(marker);
  const saved = had ? fs.readFileSync(marker) : null;
  if (had) fs.unlinkSync(marker);
  try {
    await fn();
  } finally {
    if (had && saved !== null) fs.writeFileSync(marker, saved);
    else if (fs.existsSync(marker)) fs.unlinkSync(marker);
  }
}

testAsync("session_start with SKIP_REVIEW_GATE=1 → durable gate_bypass (escape_hatch), gates stay off", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print"; // suppress startup banners / bare JSON in test output
    const { pi, fire } = mockPi();
    (reviewEnforcerFactory as any)(pi);
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      await fire("session_start");
      const lines = readAuditLines(auditLogPath());
      equal(lines.length, 1);
      const [e] = lines;
      equal(e.event, "gate_bypass");
      equal(e.extension, "review-enforcer");
      equal(e.reason, "escape_hatch");
      equal(e.session_cwd, process.cwd());
      // escape hatch still functions: git op not blocked with gates disabled
      const result = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
      equal(result, undefined);
    } finally {
      delete process.env.AGENT_SKIP_REVIEW_GATE;
      process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("task dispatches are audited per-event and the count survives across git-op checks", async () => {
  await withTempHome(async () => {
    await withMarkerIsolated(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      try {
        await fire("session_start"); // no skip env → gate enabled

        // 0 dispatches → git op blocked (existing behavior preserved)
        const blocked = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        ok(blocked && blocked.block === true, "blocked without dispatches");

        // two reviewer dispatches
        await fire("tool_result", { toolName: "task" });
        await fire("tool_result", { toolName: "task" });

        // dispatch count survived across the per-git-op checks → now allowed
        const allowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(allowed, undefined);

        // audit trail: two review_dispatch entries with the running totals
        const dispatchLines = readAuditLines(auditLogPath()).filter((l) => l.event === "review_dispatch");
        equal(dispatchLines.length, 2);
        equal(dispatchLines[0].dispatch_count, 1);
        equal(dispatchLines[1].dispatch_count, 2);
        equal(dispatchLines[0].extension, "review-enforcer");
      } finally {
        process.env.PI_MODE = prevMode;
      }
    });
  });
});

testAsync("gh pr merge with no review record → blocked AND merge_gate_block audited with PR", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const { pi, fire } = mockPi();
    (reviewEnforcerFactory as any)(pi);
    try {
      await fire("session_start");
      // real gh call (fails fast: unresolvable repo) → currentHead null → block
      const res = await fire("tool_call", {
        toolName: "bash",
        input: { command: "gh pr merge 99999999 --repo nonexistent/repo" },
      });
      ok(res && res.block === true, "merge blocked without review record");
      const blockLines = readAuditLines(auditLogPath()).filter((l) => l.event === "merge_gate_block");
      equal(blockLines.length, 1);
      equal(blockLines[0].pr, 99999999);
      equal(blockLines[0].reason, "no_review_record");
    } finally {
      process.env.PI_MODE = prevMode;
    }
  });
});

// ── #285: task sub-agents — merge-registry gate ACTIVE, truthful audit ──

section("#285 — evaluateMergeGate shape-aware no-record message (Fix C)");

test("task-sub-agent shape drops the false emergency-bypass line", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" }, true);
  ok(r.status === "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("does NOT unlock sub-agent merges (#285)"), "task-sub-agent shape must carry the #285 line");
  ok(!reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "no false emergency-bypass line for task sub-agents");
});

test("interactive shape keeps the emergency escape-hatch line (unchanged)", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  ok((r as any).reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "interactive shape unchanged");
});

test("task-sub-agent + unverifiable head → BLOCK with return-to-parent message (fail-closed)", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("Return to the parent session"), "block reason must direct the sub-agent back to the parent session for the merge ceremony");
  ok(reason.includes("fail-closed (#285)"), "block reason must mark sub-agent merges fail-closed");
  ok(!reason.includes("WITHOUT head verification"), "no fail-open warning for task sub-agents");
});

test("interactive + unverifiable head → failopen (unchanged, #138)", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" });
  equal(r.status, "failopen");
  ok((r as any).warning.includes("WITHOUT head verification"), "interactive fail-open behavior unchanged");
});

test("#285 drift guard: isTaskSubAgent reads the marker pair the dispatchers force", () => {
  const src = fs.readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  ok(
    src.includes('env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print"'),
    "review-enforcer isTaskSubAgent must read TASK_HEARTBEAT=1 ∧ PI_MODE=print (same pair as verification-gate / task-heartbeat)"
  );
});

testAsync("task sub-agent session_start audit is review_gate_parent_enforced, not gate_bypass (P2-a)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const lines = readAuditLines(auditLogPath());
      equal(lines.length, 1, "exactly one audit entry");
      equal(lines[0].event, "review_gate_parent_enforced");
      equal(lines[0].extension, "review-enforcer");
      ok(lines[0].subagent === true, "subagent flag set");
      ok(!lines.some((l) => l.event === "gate_bypass"), "no gate_bypass/escape_hatch record for a task sub-agent");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("task sub-agent: git commit ungated, gh pr merge WITHOUT record blocked (P1-2b)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      // DISPATCH-count gate skipped for task sub-agents (P1-2b): no dispatch
      // needed for commit/push/create.
      const commit = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
      equal(commit, undefined, "dispatch-count gate must be skipped for task sub-agents");
      // ...but the MERGE-registry gate stays ACTIVE: no record → fail-closed.
      const res = await fire("tool_call", {
        toolName: "bash",
        input: { command: "gh pr merge 99999997 --repo nonexistent/repo" },
      });
      ok(res && res.block === true, "task sub-agent merge must be blocked without a review record");
      ok((res.reason as string).includes("does NOT unlock sub-agent merges"), "block reason must be the #285 shape");
      const blockLines = readAuditLines(auditLogPath()).filter((l) => l.event === "merge_gate_block");
      equal(blockLines.length, 1);
      equal(blockLines[0].reason, "no_review_record");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("task sub-agent gh pr merge WITH clean record + matching head → allowed (P1-2b)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999996;
    const head = "b".repeat(40);
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    fs.writeFileSync(resolvePath(reviews, `${pr}.json`), JSON.stringify({ pr, head_sha: head, verdict: "clean" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${pr}` } });
      equal(res, undefined, "clean record + matching head → merge allowed in the task sub-agent");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("clean-low merge with an ADVANCED head pays for no merge-base read (the fetch is head-gated)", async () => {
  // The hook fetched the merge base for ANY clean-low record, before the head
  // was compared — two synchronous reads (15s timeout each) whose result no
  // branch reads, because a head-mismatched record blocks at the head branch.
  // Observed at the CALL SITE, which is where the cost is (the pure gate takes
  // currentMergeBase as an argument and cannot show it).
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999995;
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    fs.writeFileSync(
      resolvePath(reviews, `${pr}.json`),
      JSON.stringify({ pr, head_sha: "b".repeat(40), verdict: "clean-low", merge_base_sha: "c".repeat(40) })
    );
    const cmds: string[] = [];
    _setRunGhOverride((cmd) => { cmds.push(cmd); return "d".repeat(40); }); // the head ADVANCED
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${pr}` } });
      ok(res && (res as any).block === true, "an advanced head is blocked");
      ok(String((res as any).reason).includes("head has advanced"), `blocked by the HEAD binding: ${JSON.stringify((res as any).reason).slice(0, 120)}`);
      equal(cmds.filter((c) => c.includes("compare/")).length, 0, "a merge that will block on the head must not pay for the merge-base reads");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("clean-low merge with a MATCHING head does read the merge base (the laziness is not a skip)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999994;
    const head = "b".repeat(40);
    const mb = "c".repeat(40);
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    fs.writeFileSync(
      resolvePath(reviews, `${pr}.json`),
      JSON.stringify({ pr, head_sha: head, verdict: "clean-low", merge_base_sha: mb })
    );
    const cmds: string[] = [];
    _setRunGhOverride((cmd) => { cmds.push(cmd); return cmd.includes("compare/") ? mb : head; });
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${pr}` } });
      equal(res, undefined, "matching head AND matching merge base → allowed");
      ok(
        cmds.some((c) => c.includes("compare/") && c.includes(".merge_base_commit.sha")),
        `the clean-low path really reads the merge base: ${cmds.join(" || ")}`
      );
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("cd-chain merge resolves envRepo from the cd target's git remote → qualified record allows (P0-1 regression)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999993;
    const head = "c".repeat(40);
    const gitDir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-envrepo-"));
    execSync(`git init -q "${gitDir}"`, { stdio: "ignore" });
    execSync(`git -C "${gitDir}" remote add origin git@github.com:daniel-ospina/agent-infra.git`, { stdio: "ignore" });
    // THE record for this PR is repo-qualified (post-#426 write shape) —
    // only reachable when the gate resolves agent-infra from the environment.
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    const qualified = resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`);
    fs.writeFileSync(qualified, JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `cd "${gitDir}" && gh pr merge ${pr}` } });
      equal(res, undefined, "qualified record read via cd-target envRepo → merge allowed");
    } finally {
      _setRunGhOverride(null);
      fs.rmSync(gitDir, { recursive: true, force: true });
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("cd ~/… merge into ANOTHER repo is NOT authorized by the session-cwd repo's record (cycle 3 P2-1 regression)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999992;
    const head = "e".repeat(40);
    // The merge target: a ~-cd'd git worktree whose origin is DMeer. The test
    // process's real cwd is an agent-infra worktree — the WRONG repo.
    const dmeerWt = resolvePath(os.homedir(), "dmeer-wt"); // under the temp HOME
    fs.mkdirSync(dmeerWt, { recursive: true });
    execSync(`git init -q "${dmeerWt}"`, { stdio: "ignore" });
    execSync(`git -C "${dmeerWt}" remote add origin git@github.com:daniel-ospina/DMeer.git`, { stdio: "ignore" });
    // A CLEAN agent-infra record exists for the same PR number (the wrong
    // repo's evidence — exactly what a cwd fallback would wrongly consume).
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    const wrongRecord = resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`);
    fs.writeFileSync(wrongRecord, JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `cd ~/dmeer-wt && gh pr merge ${pr}` } });
      ok(res && res.block === true, "cross-repo ~-cd merge must be BLOCKED, not authorized by agent-infra's record");
      ok((res.reason as string).includes("No review record"), "block says no record for the DMeer PR");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("unattributable cd ($VAR form) is NEVER attributed to the session repo (cycle 4 P1 regression)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999991;
    const head = "f".repeat(40);
    // Session cwd is an agent-infra worktree. A DMeer worktree exists under the
    // temp HOME, reached via an UNPARSEABLE cd ($HOME expansion). A clean
    // agent-infra record for the same PR number exists (the wrong repo's
    // evidence — a cwd/no-repo attribution would consume it and silently allow
    // an unreviewed DMeer merge).
    const dmeerWt = resolvePath(os.homedir(), "dmeer-wt");
    fs.mkdirSync(dmeerWt, { recursive: true });
    execSync(`git init -q "${dmeerWt}"`, { stdio: "ignore" });
    execSync(`git -C "${dmeerWt}" remote add origin git@github.com:daniel-ospina/DMeer.git`, { stdio: "ignore" });
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    fs.writeFileSync(resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`), JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      // Sub-agent shape: must fail CLOSED with the resolvable-cd remediation.
      const res = await fire("tool_call", { toolName: "bash", input: { command: `cd "$HOME/dmeer-wt" && gh pr merge ${pr}` } });
      ok(res && res.block === true, "unattributable-cd sub-agent merge must BLOCK, not silently allow");
      ok((res.reason as string).includes("not statically resolvable"), "block explains the cd target cannot be resolved");
      ok(!(res.reason as string).includes("No review record found"), "reason is cd-attribution advice, not a misleading no-record message");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("unattributable cd, interactive session → visible fail-open, never a silent clean allow (cycle 4)", async () => {
  await withTempHome(async () => {
    const pr = 99999990;
    const head = "g".repeat(40);
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    // Clean record for the SESSION repo at the same PR number — the wrong
    // repo's evidence that a silent attribution would consume.
    fs.writeFileSync(resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`), JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    const logged: string[] = [];
    const origLog = console.log;
    console.log = (...args: any[]) => { logged.push(args.map(String).join(" ")); };
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `(cd "$HOME/dmeer-wt" && gh pr merge ${pr})` } });
      equal(res, undefined, "interactive: not a hard block (fail-open path)");
      ok(logged.some((l) => l.includes("not statically resolvable")), "interactive fail-open is VISIBLE (warning logged)");
      ok(!logged.some((l) => l.includes("Merge registry gate passed")), "never logged as a clean gate pass");
    } finally {
      _setRunGhOverride(null);
      console.log = origLog;
    }
  });
});

testAsync("task sub-agent: gh head-lookup failure → merge BLOCKED with return-to-parent reason (fail-closed wiring)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999994;
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    // Clean record exists — the ONLY thing missing is head verification
    // (gh fails), which must now block the task sub-agent (was failopen).
    fs.writeFileSync(resolvePath(reviews, `${pr}.json`), JSON.stringify({ pr, head_sha: "d".repeat(40), verdict: "clean" }));
    _setRunGhOverride(() => { throw ghError("gh: could not resolve host github.com"); });
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${pr}` } });
      ok(res && res.block === true, "task sub-agent merge must be BLOCKED when the head cannot be verified (fail-closed)");
      ok((res.reason as string).includes("Return to the parent session"), "block reason must direct the sub-agent back to the parent session");
      const blockLines = readAuditLines(auditLogPath()).filter((l) => l.event === "merge_gate_block");
      equal(blockLines.length, 1, "one merge_gate_block audit entry");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("task sub-agent in-band [VGATE] dispatch produces NO review_dispatch record (P2 tool_result noise)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const captured: string[] = [];
      const origLog = console.log;
      console.log = ((msg: string, ...rest: unknown[]) => { captured.push(String(msg)); origLog(msg, ...rest); }) as typeof console.log;
      try {
        await fire("tool_result", { toolName: "task" });
        await fire("tool_result", { toolName: "task" });
      } finally {
        console.log = origLog;
      }
      ok(!captured.some((l) => l.includes("Reviewer dispatch counted")), "no dispatch-counted line for the task sub-agent");
      ok(!readAuditLines(auditLogPath()).some((l) => l.event === "review_dispatch"), "no review_dispatch audit record");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("interactive bypass unchanged — gh pr merge also ungated (escape hatch preserved)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const lines = readAuditLines(auditLogPath());
      equal(lines[0].event, "gate_bypass", "interactive bypass still audits gate_bypass/escape_hatch");
      const commit = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
      equal(commit, undefined);
      const merge = await fire("tool_call", { toolName: "bash", input: { command: "gh pr merge 99999995" } });
      equal(merge, undefined, "interactive escape hatch must bypass the merge gate too (full bypass unchanged)");
    } finally {
      delete process.env.AGENT_SKIP_REVIEW_GATE;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

// ── #513 — clean-micro merge verdict: two-path remediation, verdict       ──
// interpolation, audit-verdict field, and the contract-doc presence pins.

section("#513 — evaluateMergeGate message honesty (two-path remediation + verdict interpolation)");

const CM_RECORD: ReviewRecord = { ...cleanRecord, verdict: "clean-micro" };

function assertHasDisambiguatedPair(reason: string): void {
  // Never prefix-collide: `clean [owner/repo]` is NOT a prefix of
  // `clean-micro [owner/repo]` when the bracket form is asserted.
  ok(reason.includes("record-review.sh <PR> <head_sha> clean-micro [owner/repo]"), "two-path remediation names the clean-micro invocation");
  ok(reason.includes("record-review.sh <PR> <head_sha> clean [owner/repo]"), "two-path remediation names the clean invocation");
}

test("#513: task-sub-agent no-record reason is two-path (micro + standard) with no emergency line", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" }, true);
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  assertHasDisambiguatedPair(reason);
  ok(reason.includes("does NOT unlock sub-agent merges (#285)"), "#285 line preserved");
  ok(reason.includes("The parent session must record the review"), "parent-records shape preserved");
  ok(!reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "no false emergency-bypass line for task sub-agents");
});

test("#513: interactive no-record reason is two-path + keeps the escape hatch", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  assertHasDisambiguatedPair(reason);
  ok(reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "interactive escape-hatch line preserved");
});

test("#513: verdict-not-clean reason interpolates the actual verdict + two-path remediation", () => {
  const rec = { ...cleanRecord, verdict: "fail" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes('verdict "fail"'), "failure line interpolates the recorded verdict");
  assertHasDisambiguatedPair(reason);
});

test("#513: head-advanced reason re-records at the RECORDED verdict (clean-micro → clean-micro, never clean)", () => {
  const r = evaluateMergeGate(138, CM_RECORD, "b".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("record-review.sh <PR> <head_sha> clean-micro [owner/repo]"), "clean-micro record re-records clean-micro");
  ok(!reason.includes("head_sha> clean [owner/repo]"), "never instructs re-recording clean over a clean-micro record");
});

test("#513: head-advanced reason re-records at the RECORDED verdict (clean → clean)", () => {
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("record-review.sh <PR> <head_sha> clean [owner/repo]"), "clean record re-records clean");
  ok(!reason.includes("clean-micro [owner/repo]"), "never re-records clean-micro over a clean record");
});

test("#513: allow message names the ACTUAL verdict (clean-micro ≠ hardcoded clean review)", () => {
  const r = evaluateMergeGate(138, CM_RECORD, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
  ok((r as any).message.includes("(clean-micro review, head"), "allow message renders the clean-micro verdict");
});

test("#513: allow message names the ACTUAL verdict (clean)", () => {
  const r = evaluateMergeGate(138, cleanRecord, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
  ok((r as any).message.includes("(clean review, head"), "allow message renders the clean verdict");
});

test("#513: head-unverifiable sub-agent block re-records at the recorded verdict", () => {
  const r = evaluateMergeGate(138, CM_RECORD, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
  ok((r as any).reason.includes("record-review.sh <PR> <head_sha> clean-micro [owner/repo]"), "sub-agent re-record line uses the recorded verdict");
});

test("#513: head-unverifiable sub-agent CLEAN cell — re-records clean, never clean-micro (downgrade guard)", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("record-review.sh <PR> <head_sha> clean [owner/repo]"), "clean record re-records clean");
  ok(!reason.includes("clean-micro [owner/repo]"), "never re-records clean-micro over a clean record");
});

test("#513: interactive fail-open warning interpolates the verdict — fallback ctx variant (bracketless form)", () => {
  const r = evaluateMergeGate(138, CM_RECORD, null, { source: "fallback" });
  equal(r.status, "failopen");
  const w = (r as any).warning as string;
  ok(w.includes("record-review.sh <PR> <head_sha> clean-micro owner/repo"), "fail-open advice names the recorded clean-micro verdict");
  ok(!w.includes("<head_sha> clean owner/repo"), "never advises re-recording clean over a clean-micro record");
});

test("#513: interactive fail-open warning interpolates the verdict — resolved-repo ctx variant + clean cell", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" });
  equal(r.status, "failopen");
  const w = (r as any).warning as string;
  ok(w.includes("record-review.sh <PR> <head_sha> clean owner/repo"), "fail-open advice names the recorded clean verdict");
  const r2 = evaluateMergeGate(138, CM_RECORD, null, { source: "record", repo: "owner/repo" });
  equal(r2.status, "failopen");
  ok(((r2 as any).warning as string).includes("record-review.sh <PR> <head_sha> clean-micro owner/repo"), "resolved-repo variant interpolates clean-micro too");
});

test("#513: merge_gate_pass audit entry carries the record verdict (joinable trail)", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, CM_RECORD, "a".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "allow");
  logMergeGateDecision(138, r as any, CM_RECORD, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_pass");
  equal(e.pr, 138);
  equal(e.verdict, "clean-micro", "pass entry carries which verdict unlocked the merge");
});

test("#513: merge_gate_block audit entry carries the record verdict; no-record block omits it (null-safe)", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  equal(readAuditLines(file)[0].verdict, "clean", "block entry carries the verdict");
  const file2 = tempAuditFile();
  const r2 = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  ok(r2.status === "block");
  logMergeGateDecision(138, r2 as any, null, file2);
  equal(readAuditLines(file2)[0].verdict, undefined, "no-record block omits verdict (null-safe)");
});

// ── #513 contract-doc presence pins (Task 6) ──

section("#513 — clean-micro contract docs presence pins (source-checkout guarded)");

// The clean-micro contract is PROSE in three docs; these pins assert the
// required sentences exist so the definition cannot silently re-drift (a
// machine fence has no code export to compare against — the #485
// REVIEW-ENFORCER-TIER-RULE fence pins TIER_RULE, which clean-micro prose has
// no analogue of). Case-INSENSITIVE scan (the appendix prose renders REFUSES
// uppercase). Soft-skips on deployed copies (isSourceCheckout), vacuous-pass
// guarded (existsSync) per the #485 T2 pattern. Negation tokens carry the
// operative definitional claim ("NOT multi-agent") so an editor deleting it
// while keeping the tier tokens fails CI.
const CONTRACT_DOC_PINS: Array<{
  rel: string;
  regionFrom: string;
  regionTo: string;
  tierTokens: string[];
  negationTokens: string[];
}> = [
  {
    rel: "skills/code-review/SKILL.md",
    // Plan Task 5.6 anchored region: the Step 10a block only — a token
    // relocated to a wrong section must not vacuously satisfy the pin.
    regionFrom: "### Step 10a",
    regionTo: "## Standard-Tier Review",
    tierTokens: ["clean-micro", "complexity:micro", "exit 4"],
    negationTokens: ["not multi-agent"],
  },
  {
    rel: "skills/commit-workflow/workflow/04-merge-deploy.md",
    // Condition-6 block: numbered list item 6 through the Merge Ceremony
    // heading (the list has no item 7).
    regionFrom: "6. **Review record at the final head",
    regionTo: "## Merge Ceremony",
    tierTokens: ["clean-micro", "03-code-review.md Step 2", "refuses"],
    negationTokens: ["never refused at any tier"],
  },
  {
    rel: "skills/commit-workflow/workflow/03-code-review.md",
    // Step-2 micro paragraph (up to the next step heading).
    regionFrom: "## Step 2 — Code-Review Gate",
    regionTo: "## Step 2.5 — Migration Review Gate",
    tierTokens: ["clean-micro", "record-review.sh"],
    negationTokens: ["not a multi-agent"],
  },
];

test("#513: contract docs carry the clean-micro definition + negation tokens", () => {
  if (!isSourceCheckout()) {
    console.log("#513 docs-presence pins: soft-skip — not a source checkout (deployed extension copy)");
    return;
  }
  for (const { rel, regionFrom, regionTo, tierTokens, negationTokens } of CONTRACT_DOC_PINS) {
    const url = new URL(`../../${rel}`, import.meta.url);
    ok(existsSync(url), `doc reachable: ${rel} (vacuous-pass guard)`);
    const normalized = fs.readFileSync(url, "utf8").replace(/\s+/g, " ").toLowerCase();
    const fromIdx = normalized.indexOf(regionFrom.toLowerCase());
    const toIdx = normalized.indexOf(regionTo.toLowerCase());
    ok(fromIdx !== -1 && toIdx !== -1 && toIdx > fromIdx, `#513 region anchors found in order: ${rel} (from "${regionFrom}" → to "${regionTo}")`);
    const text = normalized.slice(fromIdx, toIdx);
    // whitespace-normalized: the appendix prose is re-wrapped at ~78 cols, so a
    // negation token may legally straddle a newline ("NOT\nmulti-agent") — a
    // line-break move must not red the pin. Region-bound: tokens must sit in
    // the anchored block, not anywhere in the file.
    for (const t of tierTokens) {
      ok(text.includes(t.toLowerCase()), `#513 doc pin: ${rel} [${regionFrom}…${regionTo}] contains "${t}"`);
    }
    ok(
      negationTokens.some((n) => text.includes(n.toLowerCase())),
      `#513 negation pin: ${rel} [${regionFrom}…${regionTo}] contains one of ${negationTokens.join(" | ")}`
    );
  }
});

// ── #485 — micro-tier dispatch policy: uniform ≥1-dispatch block ──

section("extension factory — micro tier blocks at 0 dispatches (#485)");

// T1: marker = micro → BLOCK with the micro-specific remediation message. The
// pre-#485 arm logged a warning and allowed the op; the marker read now exists
// ONLY for message selection. The marker is written in the real producer's
// format (01-preflight Tier Detection echoes the capitalized TIER via
// `echo "$TIER" > /tmp/agent-issue-complexity` → "Micro\n") so the code's
// .trim().toLowerCase() normalization is pinned against removal.
testAsync("#485 T1: micro marker + 0 dispatches → blocked with MICRO_BLOCK_MESSAGE", async () => {
  await withTempHome(async () => {
    await withMarkerIsolated(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      try {
        await fire("session_start"); // no skip env → gate enabled
        fs.writeFileSync("/tmp/agent-issue-complexity", "Micro\n");
        const blocked = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        ok(blocked && blocked.block === true, "micro at 0 dispatches must block (#485)");
        equal(blocked.reason, MICRO_BLOCK_MESSAGE, "micro block must carry the micro-specific remediation");
        // Positive remediation-outcome pins (not just self-referential equality
        // to the exported const): the blocked micro agent must be told docs-only
        // sets need a lightweight [REVIEW] dispatch and that it must NOT go read
        // the skipped multi-agent code-review skill.
        ok(
          blocked.reason.includes("[REVIEW]") && blocked.reason.includes("docs-only"),
          "micro remediation must direct docs-only sets to a lightweight [REVIEW] dispatch"
        );
        ok(
          !blocked.reason.includes("code-review/SKILL.md"),
          "micro remediation must NOT point at the skipped multi-agent code-review gate"
        );
        // #516: the block must be DURABLE — a gate_block audit entry (reason
        // no_reviewers_dispatch, tier micro) lands in gate-events.jsonl, not
        // just console output (mirrors logMergeGateDecision's merge_gate_block
        // trail; the pre-#485 micro branch emitted console only). Exactly one:
        // no earlier event in this temp-HOME test writes gate_block.
        const microBlockAudits = readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block");
        equal(microBlockAudits.length, 1, "micro block must emit exactly one gate_block audit entry");
        equal(microBlockAudits[0].reason, "no_reviewers_dispatch", "micro gate_block audit pins reason no_reviewers_dispatch");
        equal(microBlockAudits[0].tier, "micro", "micro gate_block audit carries tier micro (TIER_RULE vocabulary)");
        equal(microBlockAudits[0].extension, "review-enforcer", "micro gate_block audit carries the extension name");
        // Complement cell: micro marker + ≥1 dispatch → ALLOWED (the #485
        // uniform policy is ≥1-dispatch, not "micro always blocks"). The
        // dispatch-count early return must precede the marker read — a reorder
        // that reads the tier first, or an over-broad unconditional micro arm,
        // would silently block every dispatched micro session (the core #485
        // workflow: code sets satisfy the dispatch via VGATE's own [VGATE]
        // dispatch). Marker still present — only the dispatch state changed.
        await fire("tool_result", { toolName: "task" });
        const allowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(allowed, undefined, "micro + ≥1 dispatch must allow the git op (dispatch supersedes the marker)");
        // Second-model gate P2 (2026-09-06): the counter must ALSO count the
        // pi `subagent` tool (extensions/subagent) — a docs-only micro change
        // reviewed via a subagent dispatch must not false-block post-flip
        // (micro relies on this counter as its only gate). Reset via
        // session_start, keep the marker, dispatch ONE subagent-tool result →
        // the git op must allow.
        await fire("session_start"); // resets dispatchCount to 0
        await fire("tool_result", { toolName: "subagent" });
        const subagentAllowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(subagentAllowed, undefined, "micro + 1 subagent-tool dispatch must allow the git op (any sub-agent dispatch counts)");
      } finally {
        if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      }
    });
  });
});

// T1b: standard/complex/unknown markers → BLOCK with the generic BLOCK_MESSAGE,
// plus the unlabeled (no-marker) key's reason pinned directly, plus the full
// policy-matrix allow complement (≥1 dispatch → allowed at every marker value).
// Markers mirror the producer format (01-preflight Tier Detection via
// echo "$TIER" — capitalized Micro/Standard/Complex and lowercase unknown,
// matching each emitted literal's exact case). The direction pins anchor on the
// path TAIL "code-review/SKILL.md" — not the full "operations/skills/…" prefix,
// which is the stale consumer-repo layout tracked by follow-up #517: the tail
// survives that fix in both repo and installed forms and still discriminates
// (MICRO_BLOCK_MESSAGE references only 03-code-review.md, never
// "code-review/SKILL.md").
testAsync("#485 T1b: standard + complex + unknown + unlabeled × {0, ≥1} dispatches", async () => {
  await withTempHome(async () => {
    await withMarkerIsolated(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      try {
        await fire("session_start");
        const producerValues = ["Standard\n", "Complex\n", "unknown\n"];
        // Pass A — 0 dispatches: every non-micro marker blocks with the generic
        // message + direction pins (all asserted while dispatchCount is still
        // 0 — the allow pass below must not precede these).
        for (const producerValue of producerValues) {
          fs.writeFileSync("/tmp/agent-issue-complexity", producerValue);
          const blocked = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
          ok(blocked && blocked.block === true, `${producerValue.trim()} at 0 dispatches must block (#485)`);
          equal(blocked.reason, BLOCK_MESSAGE, `${producerValue.trim()} block must carry the generic BLOCK_MESSAGE`);
          ok(
            blocked.reason.includes("code-review/SKILL.md"),
            "generic remediation must direct the agent to the code-review dispatch protocol"
          );
          ok(
            !blocked.reason.includes("micro tier") && !blocked.reason.includes("03-code-review.md"),
            "generic remediation must not carry micro-specific content"
          );
          // #516: every dispatch-count block audits durably — a gate_block
          // entry (reason no_reviewers_dispatch + the marker tier) per blocked
          // op, so blocked-op frequency/attribution is reconstructible from
          // gate-events.jsonl (micro cell pinned in T1).
          const blockAudit = readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block").at(-1);
          ok(blockAudit, `${producerValue.trim()} block must emit a gate_block audit entry`);
          equal(blockAudit?.reason, "no_reviewers_dispatch", `${producerValue.trim()} gate_block audit pins reason no_reviewers_dispatch`);
          equal(
            blockAudit?.tier,
            producerValue.trim().toLowerCase(),
            `${producerValue.trim()} gate_block audit carries the marker tier (same normalization as the production read)`
          );
        }
        // unlabeled key: marker ABSENT → same generic block + message (the
        // pre-existing no-marker test pins block===true; this pins the reason).
        fs.unlinkSync("/tmp/agent-issue-complexity");
        const unlabeled = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        ok(unlabeled && unlabeled.block === true, "unlabeled (no marker) at 0 dispatches must block");
        equal(unlabeled.reason, BLOCK_MESSAGE, "unlabeled (no marker) block must carry the generic BLOCK_MESSAGE");
        // #516 (cont.): the marker-ABSENT block audits tier "unlabeled" (the
        // TIER_RULE vocabulary key for no-marker sessions) so attribution stays
        // reconstructible when no marker file exists; Pass A blocked four ops
        // (standard/complex/unknown/unlabeled) → exactly four gate_block lines.
        const unlabeledAudit = readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block").at(-1);
        ok(unlabeledAudit, "unlabeled block must emit a gate_block audit entry");
        equal(unlabeledAudit?.reason, "no_reviewers_dispatch", "unlabeled gate_block audit pins reason no_reviewers_dispatch");
        equal(unlabeledAudit?.tier, "unlabeled", "unlabeled (no marker) gate_block audit carries tier unlabeled");
        equal(
          readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block").length,
          4,
          "all four Pass-A blocked ops audited (one gate_block per op)"
        );
        // Pass B — ≥1 dispatch: dispatch supersedes the marker at every tier
        // (closes the standard/complex/unknown × ≥1 matrix cells; micro × ≥1 is
        // pinned in T1).
        for (const producerValue of producerValues) {
          fs.writeFileSync("/tmp/agent-issue-complexity", producerValue);
          await fire("tool_result", { toolName: "task" });
          const allowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
          equal(allowed, undefined, `${producerValue.trim()} + ≥1 dispatch must allow the git op`);
        }
        // unlabeled × ≥1: marker ABSENT + a dispatch → still allowed (pins that
        // the ≥1 allow is marker-INDEPENDENT — a regression making the allow
        // condition require marker presence fails here; the pre-existing
        // no-marker allow test covers the same cell, this keeps the full matrix
        // self-contained in the #485 test).
        fs.unlinkSync("/tmp/agent-issue-complexity");
        await fire("tool_result", { toolName: "task" });
        const unlabeledAllowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(unlabeledAllowed, undefined, "unlabeled (no marker) + ≥1 dispatch must allow the git op");
      } finally {
        if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      }
    });
  });
});

// ── #517 — BLOCK_MESSAGE repo-layout pin ─────────────

section("message content pin — BLOCK_MESSAGE repo-agnostic layout (#517)");

test("#517: BLOCK_MESSAGE points at the agent-infra skills/ path and notes the consumer operations/skills layout", () => {
  // #517: agent-infra keeps skills at skills/code-review/SKILL.md; consumer
  // repos sync them to operations/skills/code-review/SKILL.md (hardlink
  // location). The OLD message led with the consumer-repo prefix alone — an
  // agent-infra session hitting the 0-dispatch block was directed to a
  // nonexistent path. The message is repo-agnostic (the extension runs in
  // both layouts and in deployed copies), so it must name BOTH forms: the
  // agent-infra repo-relative path first, the consumer layout parenthetically.
  ok(
    BLOCK_MESSAGE.includes("Read skills/code-review/SKILL.md"),
    "generic remediation must lead with the repo-relative skills/ path (agent-infra layout)"
  );
  ok(
    BLOCK_MESSAGE.includes("operations/skills/code-review/SKILL.md in consumer repos"),
    "generic remediation must note the consumer-repo operations/skills layout"
  );
  // Anti-regression: the stale form (consumer prefix as the ONLY pointer) must
  // not come back — anchored on the exact lead phrase so a re-drift fails
  // loudly. The parenthetical above legitimately contains the operations/skills
  // prefix, so this pins the LEAD (Read …) only.
  ok(
    !BLOCK_MESSAGE.includes("Read operations/skills/code-review/SKILL.md"),
    "generic remediation must not lead with the stale consumer-repo prefix (#517)"
  );
});

// ── #485 T2 — drift pin: REVIEW-ENFORCER-TIER-RULE fence ↔ TIER_RULE export ──

section("drift pin — 01-preflight REVIEW-ENFORCER-TIER-RULE fence ↔ TIER_RULE");

// Enforcement target: the agent-infra SOURCE CHECKOUT (mirrors the
// verification-gate VGATE-SHAPE-RULE drift test). A deployed extension copy
// (~/.pi/agent/extensions/…) has no .git marker above it and its sibling
// skills/ doc is an independently-synced artifact — comparing that pair would
// be a spurious red, not drift detection.
function isSourceCheckout(): boolean {
  return existsSync(new URL("../../.git", import.meta.url)); // dir in a clone, file in a worktree
}

// The one-time acceptance grep ("no review-enforcer micro 'warn' claim may
// remain in 01/02/03") must never silently re-drift (#486/#493 class): these
// tokens make it a CI-enforced pin that runs in ci-main's post-merge
// extension-tests job. The scan is CASE-INSENSITIVE (a re-drift may use
// "WARN-ONLY"/"Warn-only"/"WARN only" — the pre-#485 docs used both lowercase
// "warn-only" and all-caps "WARN-ONLY", so case-mutants are in the historical
// vocabulary), and the one-time acceptance grep is the FLOOR: this list is
// deliberately broader (it adds the space-form "warn only" and the inflected
// "warns …" forms) so CI can never green a claim the grep would have caught.
//
// SCOPE (#745). The tokens are ordinary English warn-phrases, so a blanket
// whole-file scan put four forbidden phrases, in any case, over three files for
// EVERY gate — with nothing surfacing the constraint at the point of writing.
// It fired for real on 2026-09-10: #691 documented the UNRELATED
// `.husky/commit-msg` hook as "warn-only by default" and red-mained CI twice
// (3e73be7, 03bdb24); #717 paid the reword tax. The invariant this pin actually
// protects is narrower — "no WARN-ALLOW claim ABOUT THE REVIEW-ENFORCER" — so
// an anti-token is now scored as a claim at two widths: its own SENTENCE
// (strong — the sentence names the review-enforcer or its tier/dispatch floor)
// or its enclosing markdown SECTION (contextual — a bare warn-allow sentence
// inside a review-enforcer topic is that topic's claim, which closes the
// anaphoric hole: "…unless a reviewer was dispatched this session." / "The gate
// is warn-only."). A sentence that names a DIFFERENT gate is escaped when it
// carries no review-enforcer vocabulary of its own. Every historical pre-#485
// re-drift sentence carries review-enforcer vocabulary (proven by the #745 T2b
// fixtures, which are drawn from the real pre-flip corpus), so protective power
// is preserved for the claim class this pin exists to catch, while "the husky
// hook is warn-only" — which names no review-enforcer vocabulary and sits in a
// section that names none either — passes.
//
// Residuals, accepted deliberately and documented here so they are never
// mistaken for the intended scope:
//   1. A SENTENCE that names the review-enforcer AND another gate's warn behavior
//      ("unlike the review-enforcer, the husky hook is warn-only") still reds.
//      Separating those two claims needs semantic parsing, and for a drift
//      backstop the conservative direction is to red.
//   2. A warn-allow sentence in a DIFFERENT section from any review-enforcer
//      content is out of scope even if anaphorically about it: the section is the
//      topic unit, and that IS the boundary that removes the #745 failure mode.
//      The pre-#745 whole-file scan "covered" this case only because it had no
//      notion of topic at all — the defect being fixed.
//   3. Conservative reds on shapes that need semantic parsing, and only when the
//      sentence sits in a review-enforcer section: a negated claim ("the micro
//      tier is no longer warn-only — it blocks") and an other-gate subject split
//      from its copula by an inserted phrase ("the husky hook, by default, is
//      warn-only" — the trailing form "the husky hook is warn-only, by default"
//      passes). The pre-#745 pin reddened on negations too, so (3) is not a
//      regression; it is the same fail-safe direction.
//   4. False negative, bounded: in a scoped section, a re-drift whose other-gate
//      name sits in an UNPUNCTUATED leading subordinate clause — "because the
//      husky hook is unrelated the gate is warn-only" — passes, because finding
//      the subordinate clause's end needs parsing. The inverse heuristic (cut at
//      the subordinate clause's verb) false-reds the equally legitimate "since
//      the husky hook is warn-only, the gate blocks", so the pin does not guess;
//      the punctuated comma form IS caught (see the T2b fixture). The same
//      bounded family covers a RELATIVE-clause INVERSION — "the gate that the
//      husky hook replaced is warn-only" passes, because the relative clause
//      opens with its own noun phrase and is indistinguishable from a
//      complementizer clause without parsing which verb is finite.
// There is no whole-file carve-out line any more — the former
// LEGIT_ON_DEMAND_LINE special case became unnecessary because the on-demand
// quality-gates sentence in 01-preflight.md carries no scope token and sits in a
// section that carries none either, so it passes structurally (pinned by a T2b
// fixture).
const MICRO_WARN_ANTI_TOKENS = [
  "warn-only",
  "warn only",
  "warn but do not block",
  "warn but does not block",
  "warns but do not block",
  "warns but does not block",
  "warn instead of block",
  "warns instead of block",
  "micro tier allows bypass",
] as const;

// Inflected forms that CANNOT be plain tokens without a false positive: the bare
// phrase is ordinary English ("the fixture warns only when the marker is
// absent"), so a trailing continuation exempts it. A bare "…micro tier warns
// only." is a re-drift and still reds. (#745 review round 4 — the string list's
// inflected entries cover only the "but does not block"/"instead of block"
// family.)
const MICRO_WARN_ANTI_PATTERNS: RegExp[] = [
  /\bwarns only\b(?!\s+(?:when|if|after|before|until|while|because|unless|where|once|as)\b)/i,
  /\bonly warns\b(?!\s+(?:when|if|after|before|until|while|because|unless|where|once|as)\b)/i,
];

// Review-enforcer scope vocabulary. Evidence is gathered at two widths:
//   • SENTENCE — the claim names the review-enforcer itself (`review-enforcer` /
//     `review enforcer` / `tier_rule` / `agent-issue-complexity`) or its tier
//     and dispatch floor (`micro`, zero-dispatch vocabulary). This is the
//     strong signal and is sufficient on its own, wherever the sentence sits.
//   • SECTION — the enclosing markdown section is ABOUT the review-enforcer, so
//     a bare warn-allow sentence inside it is a review-enforcer claim even when
//     the scope vocabulary sits in a neighbouring sentence or parent bullet
//     (the anaphoric case: "…unless a reviewer was dispatched. … The gate is
//     warn-only."). Sections are the docs' own topic unit.
// The regex forms keep the dispatch-floor token precise: a bare `dispatch`
// would drag unrelated prose ("the mutation gate dispatches a nightly run") in.
// `micro tier allows bypass` is self-scoping — it contains `micro` — so it is
// caught even as a standalone sentence in an unscoped section.
const REVIEW_ENFORCER_SCOPE_PATTERNS: RegExp[] = [
  /review-enforcer/i,
  /review enforcer/i,
  /agent-issue-complexity/i,
  /tier_rule/i,
  /\bmicro\b(?!-)/i,
  /\bmicro-tier\b/i,
  /\b0[- ](reviewer )?dispatch(es)?\b/i,
  /\bno (reviewer )?dispatch(es)?\b/i,
  /\bno reviewers? (was|were|is|are) dispatched\b/i,
  /\bno reviewers? dispatched\b/i,
  /\bzero dispatches\b/i,
  /\bdispatch(es)? (count|floor)\b/i,
  /\bdispatched this session\b/i,
  /\bmicro tier allows bypass\b/i,
];

// Claim-subject escape: inside a review-enforcer-scoped SECTION, a warning whose
// CLAUSE names a DIFFERENT gate or mechanism before the phrase is that gate's
// prose, not a review-enforcer re-drift — the class #745 exists to stop (the
// #691 hook sentence is the original case; it also sits in an unscoped section
// and so passes twice over). Applied ONLY when the sentence carries no
// review-enforcer scope token of its own, so naming another gate can never
// excuse a claim that also names the review-enforcer — "unlike the
// review-enforcer, the husky hook is warn-only" still reds (documented
// residual).
//
// The rule is POSITIONAL — an other-gate name anywhere in the claim's clause
// before the phrase — which approximates the claim's subject without parsing
// it; the comment deliberately does not over-claim grammatical subjecthood.
// See claimNamesAnotherGate for the clause and bare-anaphor rules.
//
// The clause is isolated at `,`/`;`/`:`/dash AND coordinating/subordinating
// boundaries with parentheticals blanked, and the other-gate name must sit at
// the HEAD of that clause (first three words) BEFORE the phrase ("the husky hook
// is warn-only"). `:` separates only when it is not part of a name, so the
// docs' own bold label form (`**Note:**`) separates while `arch:changed` does
// not. A relative `that` clause is not a subject of its own (the `that` is),
// so a name inside it cannot escape; a complementizer `that` clause can. A bare
// pronoun
// clause head ("…gate dispatches a nightly run; it is warn-only") borrows the
// previous clause, which is pronoun resolution by recency. This is what keeps a
// parenthetical ("the gate (like the husky hook) is warn-only"), a subordinate,
// coordinated or negated leading clause ("although the husky hook is unrelated,
// the gate is warn-only"; "no hook is needed; the gate is warn-only"; "the
// husky hook is unrelated but the gate is warn-only"), a reported clause ("the
// husky hook documentation states that the gate is warn-only"), a label
// ("hook: the gate is warn-only", bold or plain), a post-modifier naming
// another gate ("the extension gate coexisting with the husky hook is
// warn-only") and a later incidental word ("the gate is
// warn-only for the multi-agent flow") from excusing a real re-drift — all were
// live bypasses of a plain substring test.
//
// The list only ever LOOSENS the pin, so it imposes no constraint on future
// authors; adding a gate name here is the cheap extension point if a legitimate
// other-gate sentence reds (never a doc rewording). A colon-bearing name works
// (`arch:changed`, #745 review round 7) because `:` counts as a clause boundary
// only when it separates. The name must HEAD the clause (within its first three
// words): a name buried in a post-modifier is part of a claim about the
// review-enforcer gate, not an escape. Word boundaries are
// deliberate — `\bhooks?\b` must not match "Hooked on the idea". NOTE:
// "merge-registry" is deliberately absent: the merge-registry gate is part of
// the review-enforcer extension, so a warn claim about IT is in scope.
const OTHER_GATE_SUBJECT_PATTERNS: RegExp[] = [
  /\bhusky\b/,
  /\bcommit-msg\b/,
  /\bhooks?\b/,
  /\bvgate\b/,
  /\bverification[- ]gate\b/,
  /\bpipeline-compliance\b/,
  /\bpre-?flight\b/,
  /\btest-review\b/,
  /\bcode-review\b/,
  /\bon-demand\b/,
  /\bmutation\b/,
  /\bcoverage-pruning\b/,
  /\barch:changed\b/,
  /\bpgtap\b/,
  /\btypecheck\b/,
  /\bmulti-agent\b/,
];

// Bare pronouns that resolve to the clause subject on their left. A determiner
// use ("this gate", "that check") is NOT bare — it names its own subject — so
// the pronoun path additionally requires the clause head to be nothing but the
// anaphor plus copulas/adverbs (see BARE_ANAPHOR_CLAUSE).
const BARE_ANAPHOR_CLAUSE =
  /^(it|they|this|that|these|those)(\s+(is|are|was|were|be|been|being|merely|only|also|still|always|never|not|simply|no longer))*$/;
const CLAUSE_BOUNDARY_CHARS = ";:—–,";
// Conjunctions and subordinators are clause boundaries too: "the husky hook is
// unrelated but the gate is warn-only" and "…states that the gate is warn-only"
// have no punctuation, and without this the earlier other-gate name would
// launder the claim (#745 review rounds 5-6).
const CLAUSE_BOUNDARY_WORDS = /\b(but|and|yet|so|while|whereas|although|though|because|since|unless|or|if|when|after|before|until|as|that)\b/g;
// Heads that can open a clause's own noun phrase ("…states that the gate is
// warn-only" / "…explain that the husky hook is warn-only"). Anything else right
// after a `that` boundary is a RELATIVE pronoun ("the extension gate that
// replaced the husky hook is warn-only"), where `that` is that clause's subject
// and the matrix subject — the review-enforcer gate — still governs the claim.
const CLAUSE_NOUN_HEAD = /^(the|a|an|this|that|these|those|each|every|any|some|no|all|both|its|their|his|her|our|your|my|it|they|he|she|we|you|i)\b/i;

// Starts of every clause that ends at `hitAt`, ascending (0 always first).
function clauseStartsBefore(sentence: string, hitAt: number): number[] {
  const marks = new Set<number>([0]);
  for (let i = 0; i < hitAt; i++) {
    if (!CLAUSE_BOUNDARY_CHARS.includes(sentence[i])) continue;
    // `:` is a boundary only when it SEPARATES (`hook: the gate is warn-only`,
    // including the docs' bold/backtick label form `**Note:**` / `` `hook:` ``),
    // never when it is part of a name (`arch:changed`, `complexity:micro`,
    // `check:arch:changed`) — otherwise the band starts after the colon and the
    // escape entry for that gate can never match, or conversely a bold label
    // stops separating (#745 review rounds 7-8). Name characters are ASCII
    // alphanumerics; punctuation after the colon (space, `*`, `` ` ``, `)`) ends
    // the clause.
    if (sentence[i] === ":" && /[A-Za-z0-9]/.test(sentence[i + 1] ?? "")) continue;
    marks.add(i + 1);
  }
  for (const match of sentence.slice(0, hitAt).matchAll(CLAUSE_BOUNDARY_WORDS)) {
    marks.add((match.index ?? 0) + match[0].length);
  }
  marks.add(hitAt);
  return [...marks].sort((a, b) => a - b);
}

// True when the sentence's SOURCE CLAUSE (the clause holding the warning phrase
// at `hitAt`) names a different gate as its subject.
function claimNamesAnotherGate(sentence: string, hitAt: number): boolean {
  // Blank parentheticals IN PLACE (spaces, not removal) so every index below is
  // still the original offset.
  const text = sentence.replace(/\([^)]*\)/g, (m) => " ".repeat(m.length));
  const starts = clauseStartsBefore(text, hitAt);
  const clauseStart = starts[starts.length - 2];
  const clauseHead = text.slice(clauseStart, hitAt).trim().replace(/^[>\-*`_\s]+/, "");
  let subjectStart = clauseStart;
  if (BARE_ANAPHOR_CLAUSE.test(clauseHead.toLowerCase())) {
    // "… gate dispatches a nightly run; it is warn-only" — the bare pronoun takes
    // the previous clause's subject, so widen the subject band to that clause.
    subjectStart = starts[starts.length - 3] ?? 0;
  }
  const subjectBand = text.slice(subjectStart, hitAt);
  // A `that` boundary immediately before the claim's clause is a RELATIVE
  // pronoun when the clause does not open with its own noun phrase. The band is
  // then the relative clause's own predicate and must NOT escape, or
  // "the extension gate that replaced the husky hook is warn-only" would pass as
  // a husky-hook claim (#745 review round 8). A complementizer `that`
  // (noun phrase follows) is unaffected: the band is that clause's subject.
  if (/\bthat\s*$/.test(text.slice(0, clauseStart))) {
    const head = text.slice(clauseStart, hitAt).trim().replace(/^[>\-*`_]+/, "");
    if (!CLAUSE_NOUN_HEAD.test(head)) return false;
  }
  // SUBJECT-HEAD rule: the other-gate name must be at the HEAD of the subject
  // band (within its first three words), not anywhere inside it. Without this a
  // POST-MODIFIER naming another gate launders a claim that is grammatically
  // about the (anaphoric) review-enforcer gate — "the extension gate coexisting
  // with the husky hook is warn-only", "the gate for the code-review flow is
  // warn-only", "the gate handling the typecheck step is warn-only" (#745
  // review round 7). Legitimate other-gate prose puts the gate first ("the
  // husky hook is warn-only", "the on-demand mutation gate dispatches a nightly
  // run; it is warn-only") and still passes.
  return OTHER_GATE_SUBJECT_PATTERNS.some((pattern) => {
    const match = pattern.exec(subjectBand);
    if (!match) return false;
    const before = subjectBand.slice(0, match.index).replace(/^[>\-*`_\s]+/, "").trim();
    const wordsBefore = before.length === 0 ? 0 : before.split(/\s+/).length;
    return wordsBefore <= 2;
  });
}

// TERMINATED HTML comments are BLANKED (spaces, newlines preserved) before any
// structural parse, so a comment body can neither scope a section nor inject
// escape words into the claim beside it — same-line, inline-opener, multi-line,
// and multi-line-with-a-fence-inside all alike. Blanking is FENCE-AWARE in the
// other direction: a literal `<!--` inside a fenced code block (e.g. the
// `contains("<!-- issue-scoping:")` string in 03-code-review.md) is code, not a
// comment, and must not be paired with a later real comment's `-->` (that would
// blank everything between). An OPEN comment, however, outranks fence state —
// CommonMark terminates it at the first `-->`, so fence delimiters inside a
// comment body are comment text and must not toggle fence tracking.
//
// An UNTERMINATED comment outside a fence blanks from its opener TO END OF
// INPUT (blank-to-EOF is markdown's own reading of an unclosed comment) and
// reports `unterminated`, which T2 asserts against: a stray opener would
// otherwise silence the anti-token pin for the rest of every swept doc while CI
// stayed green, and `existsSync`-style vacuity guards cannot see it (#745
// review round 7).
interface BlankedComments {
  text: string;
  unterminated: boolean;
}

function blankHtmlComments(text: string): BlankedComments {
  const out: string[] = [];
  let fence: FenceState | null = null;
  let inComment = false;
  let unterminated = false;
  for (const rawLine of text.split("\n")) {
    let line = rawLine;
    if (inComment) {
      // An open comment OUTRANKS fence tracking: CommonMark ends the comment at
      // the first `-->` wherever it is, so a fence delimiter inside a comment
      // body is comment text. Testing the fence first would emit that body into
      // the section scope (a comment body scoping a section) and, when the
      // closing `-->` shared a line with the delimiter, leave `inComment` set
      // and report a CLOSED comment as unterminated (#745 review round 9).
      const close = line.indexOf("-->");
      if (close === -1) {
        out.push(line.replace(/[^\n]/g, " "));
        continue;
      }
      line = " ".repeat(close + 3) + line.slice(close + 3);
      inComment = false;
    } else {
      const nextFence = nextFenceState(line, fence);
      if (/^\s*(`{3,}|~{3,})/.test(line)) {
        fence = nextFence;
        out.push(line);
        continue;
      }
      if (fence) {
        out.push(line);
        continue;
      }
    }
    for (;;) {
      const open = line.indexOf("<!--");
      if (open === -1) break;
      const close = line.indexOf("-->", open + 4);
      if (close === -1) {
        inComment = true;
        line = `${line.slice(0, open)}${' '.repeat(line.length - open)}`;
        break;
      }
      line = `${line.slice(0, open)}${' '.repeat(close + 3 - open)}${line.slice(close + 3)}`;
    }
    out.push(line);
  }
  if (inComment) unterminated = true;
  return { text: out.join("\n"), unterminated };
}

const SWEPT_DOC_RELS = [
  "../../skills/commit-workflow/workflow/01-preflight.md",
  "../../skills/commit-workflow/workflow/02-commit-pr.md",
  "../../skills/commit-workflow/workflow/03-code-review.md",
] as const;

// ── #745 — claim-scoped anti-token scan ──
//
// The scan is a three-stage parse:
//   1. SECTIONS. Markdown headings delimit the topic unit. Fenced code blocks
//      are tracked so a `# comment` inside a bash block is not mistaken for a
//      heading (that would silently shrink a section). The heading line itself
//      is part of its section — a section titled "Micro Tier" IS review-enforcer
//      scope.
//   2. SENTENCE UNITS inside each section. Hard wraps at ~78 cols are JOINED (a
//      claim may straddle a newline), while markdown table rows, list items,
//      comment fences and blockquote starts are structural boundaries and must
//      NOT absorb a neighbour (otherwise a review-enforcer bullet and the next
//      bullet — about another gate — collapse into one "sentence"). A
//      blockquote continuation line (leading `>`) is joined onto the open
//      blockquote.
//   3. SENTENCE SPLIT on `.`/`!`/`?` followed by whitespace OR a markdown
//      closer (`*`/`_`/`)`/`]`/`}`/quote). The closer matters: in
//      "**warn-only.** The next claim" the period is followed by `*`, and a
//      whitespace-only boundary test would merge two independent claims into one
//      (donating the second's scope token to the first).
// Case folding is applied to each unit (the re-drift vocabulary historically
// included all-caps). There is deliberately NO verb stemming: a global
// `warns`→`warn` fold would drag ordinary English ("warns only when …") into
// the `warn only` token, so the inflected re-drift forms are spelled out in
// MICRO_WARN_ANTI_TOKENS instead (an explicit coverage GAIN: the pre-#745 list
// missed every inflected form, including "warns but does not block").
// Fence state for a markdown code fence. Fences close only on a delimiter of
// the SAME character and at least the same length, so a ```` block containing a
// ``` line does not toggle state and promote the following code comment to a
// heading (which would silently shrink the enclosing section — a re-drift
// hiding place; #745 review round 6).
interface FenceState {
  char: string;
  len: number;
}
function nextFenceState(line: string, fence: FenceState | null): FenceState | null {
  const match = /^\s*(`{3,}|~{3,})/.exec(line);
  if (!match) return fence;
  const char = match[1][0];
  const len = match[1].length;
  if (!fence) return { char, len };
  if (char === fence.char && len >= fence.len) return null;
  return fence;
}

function markdownSections(text: string): Array<{ heading: string; text: string }> {
  const sections: Array<{ heading: string; text: string }> = [];
  let heading = "(preamble)";
  let lines: string[] = [];
  let fence: FenceState | null = null;
  const flush = () => sections.push({ heading, text: [heading, ...lines].join("\n") });
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trimEnd();
    const nextFence = nextFenceState(line, fence);
    if (nextFence !== fence || /^\s*(`{3,}|~{3,})/.test(line)) {
      fence = nextFence;
      lines.push(line);
      continue;
    }
    if (!fence && /^#{1,6} \S/.test(line)) {
      flush();
      heading = line.trim();
      lines = [];
      continue;
    }
    lines.push(line);
  }
  flush();
  return sections;
}

// Sentence units within one section, normalized to lowercase.
//
// HTML comments are already blanked by `blankHtmlComments` (the caller), so a
// comment body can never appear here. SELF-CONTAINED LINES (markdown headings
// and code-fence delimiters) are emitted as their OWN unit and never absorb the
// next line. Without that, a heading or a fenced `# comment` would concatenate
// with the following prose and donate its scope vocabulary to it — a
// one-blank-line formatting difference would flip a legitimate other-gate
// sentence ("### Micro Tier\nThe VGATE check is warn-only.") from pass to red,
// i.e. the #745 failure mode.
function sectionSentenceUnits(sectionText: string): string[] {
  const blocks: string[] = [];
  let buf = "";
  for (const rawLine of sectionText.split("\n")) {
    const line = rawLine.trim();
    const selfContained =
      line !== "" && (/^#{1,6}\s/.test(line) || /^\s*(```|~~~)/.test(line));
    if (selfContained) {
      if (buf) blocks.push(buf);
      buf = "";
      blocks.push(line);
      continue;
    }
    const startsBlock =
      line === "" ||
      /^([-*+|]|\d+[.)])\s/.test(line) ||
      (line.startsWith(">") && !buf.startsWith(">"));
    if (startsBlock) {
      if (buf) blocks.push(buf);
      buf = line;
    } else {
      buf = buf ? `${buf} ${line}` : line;
    }
  }
  if (buf) blocks.push(buf);
  return blocks
    .flatMap((block) => block.split(/(?<=[.!?])(?=[\s)\]}"'»*_`]|$)/))
    .map((sentence) => sentence.toLowerCase().trim())
    .filter((sentence) => sentence.length > 0);
}

const isReviewEnforcerScoped = (text: string): boolean =>
  REVIEW_ENFORCER_SCOPE_PATTERNS.some((pattern) => pattern.test(text));

// EVERY anti-token occurrence in a sentence, each with its own offset, so each
// is judged on its OWN clause/pronoun subject. A set of unique tokens with a
// single `indexOf` would amnesty a repeated spelling: "the husky hook is
// warn-only; the gate is also warn-only" must red on the second occurrence even
// though the first is legitimately escaped (#745 review round 4).
function findAntiTokenHits(sentence: string): Array<{ token: string; at: number }> {
  const hits: Array<{ token: string; at: number }> = [];
  for (const token of MICRO_WARN_ANTI_TOKENS) {
    let from = 0;
    for (;;) {
      const at = sentence.indexOf(token, from);
      if (at === -1) break;
      hits.push({ token, at });
      from = at + token.length;
    }
  }
  for (const pattern of MICRO_WARN_ANTI_PATTERNS) {
    // Fresh global clone per call: a shared regex would keep `lastIndex` state.
    const global = new RegExp(pattern.source, pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`);
    for (const match of sentence.matchAll(global)) hits.push({ token: match[0], at: match.index ?? 0 });
  }
  return hits;
}

// Every anti-token occurrence that IS a review-enforcer claim: it carries scope
// vocabulary in its own sentence, or sits in a review-enforcer-scoped section
// and does not name a different gate before the warning phrase. An empty array
// ⇔ the text carries no review-enforcer warn-allow claim, whatever it says
// about other gates.
function findMicroWarnClaims(
  text: string
): Array<{ token: string; sentence: string; section: string }> {
  const claims: Array<{ token: string; sentence: string; section: string }> = [];
  // Blank HTML comments FIRST, so comment bodies can neither scope a section nor
  // inject escape words into the claim beside them — same-line and multi-line
  // alike (#745 review round 5).
  for (const section of markdownSections(blankHtmlComments(text).text)) {
    const sectionScoped = isReviewEnforcerScoped(section.text);
    for (const sentence of sectionSentenceUnits(section.text)) {
      const hits = findAntiTokenHits(sentence);
      if (hits.length === 0) continue;
      // Sentence-scoped: the claim names the review-enforcer itself — always a
      // violation. Otherwise the section supplies the topic, and each hit is
      // judged on ITS OWN clause/pronoun subject (a single escape decision for
      // the whole sentence would amnesty a second claim: "the husky hook is
      // warn-only; the gate is also warn only").
      if (!sectionScoped && !isReviewEnforcerScoped(sentence)) continue;
      const sentenceScoped = isReviewEnforcerScoped(sentence);
      for (const { token, at } of hits) {
        if (!sentenceScoped && claimNamesAnotherGate(sentence, at)) continue;
        claims.push({ token, sentence, section: section.heading });
      }
    }
  }
  return claims;
}

test("#485 T2: REVIEW-ENFORCER-TIER-RULE fence == TIER_RULE + no micro-warn claim in 01/02/03", () => {
  if (!isSourceCheckout()) {
    console.log("  ↪ skip (deployed copy — not an agent-infra source checkout)");
    return;
  }
  // Fence parse (01-preflight). Anchor the separator row by POSITION so a
  // cosmetic header reword cannot break the parse; every data row must be
  // exactly 2 populated cells or the test FAILS loudly (prose never silently
  // ignored inside a machine-read fence).
  const docText = readFileSync(
    new URL("../../skills/commit-workflow/workflow/01-preflight.md", import.meta.url),
    "utf8"
  );
  const open = docText.indexOf("<!-- REVIEW-ENFORCER-TIER-RULE");
  const close = docText.indexOf("<!-- /REVIEW-ENFORCER-TIER-RULE", open);
  ok(open !== -1, "01-preflight.md must contain the REVIEW-ENFORCER-TIER-RULE opener comment");
  ok(close !== -1 && close > open, "01-preflight.md must contain the REVIEW-ENFORCER-TIER-RULE closer comment");

  const rows = docText
    .slice(open, close)
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("|"));
  ok(rows.length === 7, `fence must have header + separator + 5 data rows, found ${rows.length}`);
  ok(/^\|[\s:|-]+\|$/.test(rows[1]), `row 1 must be the --- separator: ${rows[1]}`);
  const cellSplit = (rawLine: string): string[] =>
    rawLine.split("|").map((c) => c.trim()).filter((c) => c.length > 0);
  const fencePairs: Array<[string, string]> = [];
  for (const rawLine of rows.slice(2)) {
    const cells = cellSplit(rawLine);
    ok(cells.length === 2, `malformed data row (must be exactly 2 populated cells): ${rawLine}`);
    fencePairs.push([cells[0], cells[1]]);
  }
  // Order-insensitive symmetric compare: a cosmetic reorder of fence rows or
  // TIER_RULE keys must not fail CI (mirrors the VGATE precedent's sort-based
  // robustness).
  const sortPairs = (pairs: Array<[string, string]>) => pairs.sort((a, b) => a[0].localeCompare(b[0]));
  deepEqual(
    sortPairs(fencePairs),
    sortPairs(Object.entries(TIER_RULE) as Array<[string, string]>),
    "01-preflight.md REVIEW-ENFORCER-TIER-RULE fence drifted from TIER_RULE — every tier must map to block (#485)"
  );

  // Producer-vocabulary pin (closes the writer→reader coupling the T1/T1b
  // marker strings mirror): a literal rename in 01-preflight Tier Detection
  // that leaves the fence/TIER_RULE untouched would silently send real micro
  // sessions the generic BLOCK_MESSAGE (losing the micro docs-only [REVIEW]
  // remediation) with CI green — these asserts red on that class. Anchored on
  // SEMANTIC content (markup-tolerant: `TIER = Micro` must survive a de-bold /
  // table conversion — a literal rename changes the text either way, so
  // format-insensitive checks catch every rename without cosmetic-noise reds).
  const preflightLines = docText.split("\n");
  ok(
    preflightLines.some((l) => l.includes("echo") && l.includes("$TIER") && l.includes("agent-issue-complexity")),
    "01-preflight.md must contain the marker emission line the T1/T1b marker strings mirror"
  );
  for (const [label, literal] of [
    ["micro", "Micro"],
    ["standard", "Standard"],
    ["complex", "Complex"],
  ] as Array<[string, string]>) {
    ok(
      preflightLines.some((l) => l.includes(`complexity:${label}`) && l.includes(`TIER = ${literal}`)),
      `01-preflight.md Tier Detection must map complexity:${label} to TIER literal ${JSON.stringify(literal)} (mirrored by the T1/T1b producer-format markers)`
    );
  }
  ok(
    preflightLines.some((l) => l.includes("TIER = unknown")),
    "01-preflight.md Tier Detection must emit the lowercase unknown literal (no-label bullet; mirrored by T1b's producer-format marker)"
  );

  // Anti-token pin across the three swept docs (vacuous-pass guard: a missing
  // doc fails loudly instead of silently passing). CLAIM-SCOPED since #745: an
  // anti-token reds only when it reads as a review-enforcer claim (its own
  // sentence names review-enforcer vocabulary, or its enclosing section is
  // about the review-enforcer and the sentence names no other gate), so
  // unrelated-gate prose is structurally exempt and no carve-out line remains.
  for (const rel of SWEPT_DOC_RELS) {
    const url = new URL(rel, import.meta.url);
    if (!existsSync(url)) {
      ok(false, `${rel} unreachable from the agent-infra source tree — anti-token pin would pass vacuously; restore the doc or fix the resolution`);
      return;
    }
    const blanked = blankHtmlComments(readFileSync(url, "utf8"));
    ok(
      !blanked.unterminated,
      `${rel} opens an HTML comment that is never closed — comment blanking would continue to EOF, the anti-token pin would be BLIND from that point on and every claim after it would pass vacuously; close the comment`
    );
    const claims = findMicroWarnClaims(blanked.text);
    equal(
      claims.length,
      0,
      `${rel} carries ${claims.length} review-enforcer warn-allow claim(s) — a #485 micro warn re-drift: ` +
        claims.map((c) => `${JSON.stringify(c.token)} in ${JSON.stringify(c.sentence)} [${c.section}]`).join(" | ") +
        ` (case-insensitive; a claim is scoped by review-enforcer vocabulary in its own sentence OR by its enclosing section per #745 — a warn phrase about ANOTHER gate in an unscoped section is not this claim)`
    );
  }
});

// ── #745 — the scoped pin's two-sided proof ──

test("#485 T2b: warn-vocabulary pin flags review-enforcer re-drift, ignores other gates", () => {
  // AC1 — a genuine re-drift still FAILS. Every entry is a whole synthetic DOC
  // so the section-scope path is exercised, not just the sentence path.
  const REDRIFT_DOCS: Array<[string, string]> = [
    // The REAL pre-#485 corpus (git show e097b38^:{01-preflight,02-commit-pr,
    // 03-code-review}.md) — the exact sentences the #485 flip had to remove —
    // placed under a review-enforcer section as they were in the real docs.
    [
      "01-preflight micro-tier table row",
      "### Micro Tier Auto-Detection & Gate Behavior\n| Gate | Micro Behavior |\n| Review-enforcer | **WARN-ONLY** at micro — 0 reviewer dispatches warn but do not block (extension reads /tmp/agent-issue-complexity = micro); Standard+/unset block |\n",
    ],
    [
      "01-preflight mechanism-separation prose",
      "### Gate Scoping\nMechanism separation: the VGATE content-shape skip is extension-side and shape-based (applies at ANY tier; code sets never skip); the review-enforcer micro warn-only is marker-based (extension reads `/tmp/agent-issue-complexity` = micro); a docs-only commit on an UNLABELED issue is VGATE shape-exempt but still review-enforcer-blocked at 0 dispatches.\n",
    ],
    [
      "01-preflight rationale prose",
      "### Rationale\n**Rationale:** Micro-tier CODE commits keep full VGATE (shape-gated — the extension skips only docs/CSS/static sets, never code); the reviewer dispatch (review-enforcer, warn-only at micro) plus VGATE-on-code is the net.\n",
    ],
    [
      "01-preflight extension-gates prose",
      "### Extension Gates\nThese checks are enforced by Pi extensions — each with per-gate scoping rather than a blanket tier rule: the review-enforcer is tier-gated (micro warn-only via marker; Standard+/unset block); VGATE is content-shape gated (docs/CSS/static-only sets exempt, code never).\n",
    ],
    [
      "01-preflight session-shape prose",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless at least one `task` sub-agent was dispatched this session — Micro tier is warn-only (extension reads `/tmp/agent-issue-complexity` = micro; 0 dispatches warn but do not block); Standard+/unset block.\n",
    ],
    [
      "03-code-review micro paragraph",
      "### Step 2 — Code-Review Gate\n**Micro tier: skip entirely.** No code-review agents are dispatched for Micro — consistent with the review-enforcer extension being **WARN-ONLY at Micro** (tier read from the `/tmp/agent-issue-complexity` marker; 0 reviewer dispatches warn but do not block — `extensions/review-enforcer/index.ts` micro branch; Standard+/unset block).\n",
    ],
    // Minimal synthetic mutants, including the AC's "warns but does not block".
    ["minimal re-drift", "The review-enforcer micro tier is warn-only.\n"],
    ["inflected re-drift", "The review-enforcer micro tier warns but does not block.\n"],
    ["inflected re-drift (micro only)", "The micro tier warns instead of blocking.\n"],
    ["tier_rule re-drift", "A 0-dispatch docs-only session is warn only under TIER_RULE.\n"],
    ["self-scoping bypass token", "Micro tier allows bypass at 0 dispatches.\n"],
    // Anaphoric continuation — the scope vocabulary is in a NEIGHBOURING
    // sentence, not the claim's own (reviewer scenario A). The old whole-file
    // pin caught this; the section window preserves that coverage.
    [
      "cross-sentence anaphora in a scoped section",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless a reviewer was dispatched this session.\n\nThe gate is warn-only.\n",
    ],
    // Nested-bullet anaphora (reviewer scenario B): scope in the parent bullet.
    [
      "nested-bullet anaphora in a scoped section",
      "### Extension Gates\n- **Review-enforcer** — the git-operation gate:\n  - Standard+/unlabeled: blocks\n  - the tier check is warn-only\n",
    ],
    // An incidental LATER mention of another gate must not excuse an anaphoric
    // re-drift: the escape names the claim's SUBJECT, which is the slot before
    // the warning phrase (reviewer round-2 P1).
    [
      "anaphoric re-drift with an incidental later other-gate word",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless a reviewer was dispatched this session.\n\nThe gate is warn-only for the multi-agent flow.\n",
    ],
    // Round-3 P1: an other-gate name that is NOT the subject must not excuse the
    // claim — parenthetical, subordinate/negated mention, label, or inflected
    // substring, all before the warning phrase.
    [
      "parenthetical other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe gate (like the husky hook) is warn-only.\n",
    ],
    [
      "negated other-gate mention in a leading clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nNo hook is needed; the gate is warn-only.\n",
    ],
    [
      "subordinate other-gate mention in a leading clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nAlthough the husky hook is unrelated, the gate is warn-only.\n",
    ],
    [
      "label-style other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nhook: the gate is warn-only.\n",
    ],
    [
      "inflected escape-word substring",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nHooked on the idea, the gate is warn-only.\n",
    ],
    // Round-3 P2: a first-clause escape must not amnesty a second claim in the
    // same sentence.
    [
      "second claim after an escaped first clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is warn-only; the gate is also warn only.\n",
    ],
    // Round-3 P2 (multi-line HTML comment): comment bodies must not donate escape
    // words to the claim on their right — line-start OR inline opener.
    [
      "multi-line HTML comment must not inject escape words",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n<!--\nsee the husky hook docs\n-->\nThe gate is warn-only.\n",
    ],
    [
      "inline-HTML-comment body must not inject escape words",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nSee the docs <!--\nhusky hook note\n-->\nThe gate is warn-only.\n",
    ],
    // Round-4 P1: a repeated spelling must be judged per OCCURRENCE, not once
    // per unique token.
    [
      "second occurrence of the same token after an escaped first clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is warn-only; the gate is also warn-only.\n",
    ],
    // Round-4 P2: inflected `warns only` / `only warns` in a scoped sentence.
    ["inflected 'warns only' re-drift", "The review-enforcer micro tier warns only.\n"],
    ["inflected 'only warns' re-drift", "The review-enforcer micro tier only warns.\n"],
    ["inflected 'warns only to …' re-drift", "The review-enforcer micro tier warns only to avoid blocking.\n"],
    // Round-5: a same-line HTML comment must not immunize the claim beside it.
    [
      "same-line HTML comment before the claim",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n<!-- husky hook note --> The gate is warn-only.\n",
    ],
    [
      "multi-line comment closing on the claim's line",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n<!--\nhusky hook note --> The gate is warn-only.\n",
    ],
    // Round-5: coordinating conjunctions are clause boundaries.
    [
      "coordinating-conjunction laundering (but)",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is unrelated but the gate is warn-only.\n",
    ],
    [
      "coordinating-conjunction laundering (and)",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is unrelated and the gate is warn-only.\n",
    ],
    // Round-5: a determiner use ('this gate') is a subject, not a bare anaphor.
    [
      "determiner subject after an escaped clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is warn-only; this gate is warn-only.\n",
    ],
    // Round-6: a reported clause after `that` must not be laundered by the
    // reporting subject's other-gate name.
    [
      "reported clause after 'that'",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe husky hook documentation states that the gate is warn-only.\n",
    ],
    [
      "reported clause after 'explains that'",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe typecheck note explains that the gate is warn-only.\n",
    ],
    // Round-6 P1: a longer fence containing a shorter fence delimiter must not
    // toggle fence state and promote the following code comment to a heading.
    [
      "longer fence containing a shorter delimiter",
      "### Extension Gates\n````\nThe `review-enforcer` blocks at 0 dispatches.\n```\n# note\nThe gate is warn-only.\n````\n",
    ],
    // Round-7 P1: an other-gate name buried in a POST-MODIFIER is not the claim's
    // subject — the claim is still about the (anaphoric) review-enforcer gate.
    [
      "participial post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe extension gate coexisting with the husky hook is warn-only.\n",
    ],
    [
      "relative-clause post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe extension gate that replaced the husky hook is warn-only.\n",
    ],
    [
      "prepositional post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe gate for the code-review flow is warn-only.\n",
    ],
    [
      "gerund post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe gate handling the typecheck step is warn-only.\n",
    ],
    // Round-7 P2: the dispatch floor's natural passive/plural phrasings must
    // still scope the section (they were absent from the vocabulary).
    [
      "passive plural dispatch-floor phrasing",
      "### Extension Gates\nNo reviewers were dispatched for this change.\nThe gate is warn-only.\n",
    ],
    [
      "passive singular dispatch-floor phrasing",
      "### Extension Gates\nNo reviewer was dispatched for this change.\nThe gate is warn-only.\n",
    ],
    [
      "zero-dispatch phrasing",
      "### Extension Gates\nZero dispatches were recorded.\nThe gate is warn-only.\n",
    ],
    // Round-8: a BOLD/BACKTICK label is still a label — the docs' own voice is
    // `**Rationale:**`, so the bold form must separate exactly like the plain one.
    [
      "bold label-style other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\n**hook:** the gate is warn-only.\n",
    ],
    [
      "backtick label-style other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\n`hook:` the gate is warn-only.\n",
    ],
    [
      "bold multiword label naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\n**Husky hook:** the gate is warn-only.\n",
    ],
    // Round-8: a RELATIVE `that` clause is that clause's own subject — the claim
    // is still about the matrix (review-enforcer) subject.
    [
      "relative 'that' clause naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe gate that coexists with the husky hook is warn-only.\n",
    ],
  ];
  for (const [label, doc] of REDRIFT_DOCS) {
    ok(findMicroWarnClaims(doc).length > 0, `#745 scope pin: re-drift must FAIL (${label}) — ${JSON.stringify(doc)}`);
  }

  // AC2 — an unrelated gate using the SAME vocabulary PASSES, including when it
  // sits INSIDE a review-enforcer-scoped section (where the named-other-gate
  // escape is what keeps it passing — reviewer scenario C).
  const UNRELATED_DOCS: Array<[string, string]> = [
    [
      "literal #691 hook sentence in its own section",
      "### Mangled commit message — repair\nThe `.husky/commit-msg` hook warns when it sees the signature of a lost shell substitution. It is **warn-only** by default — both signatures have realistic false positives, so a warning is a prompt to look, not a failure.\n",
    ],
    [
      "01-preflight on-demand-gates line (AC3 strip target)",
      "### TypeScript / Supabase Stack (default)\n> **Quality gates available on-demand (WARN only, do not block):** `npm run check:coverage-pruning`, `npm run check:arch:changed`, `npm run check:mutation` (nightly). See #6460-#6463.\n",
    ],
    [
      "other-gate warn phrase merged into a sentence with review-enforcer scope vocabulary in the section",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless a reviewer was dispatched this session.\n\nThe on-demand mutation gate dispatches a nightly run; it is warn-only.\n",
    ],
    [
      "other-gate sentence after a terminal period inside emphasis (splitter regression)",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nThe husky hook is **warn-only.** The on-demand gate is warn only.\n",
    ],
    [
      "ordinary-English inflected 'warns only' inside a scoped section",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nAt micro, the fixture warns only when the marker file is absent.\n",
    ],
    // A heading must be its own SENTENCE UNIT. It still scopes its SECTION
    // (deliberately — see markdownSections), but it must not merge into the next
    // sentence, or the other-gate escape could never fire for a legitimate
    // sentence under a scope-bearing heading.
    [
      "other-gate sentence directly under a scope-bearing heading",
      "### Micro Tier Behavior\nThe VGATE content-shape check is warn-only for docs-only sets.\n",
    ],
    // A fenced code comment must not merge into the sentence after the fence.
    // (Fenced content DOES scope its section, deliberately: the section's topic
    // includes its code examples — that is what catches an anaphoric re-drift
    // appended to a section whose only micro reference is a code comment.)
    [
      "other-gate sentence after a fenced code comment mentioning micro",
      "### TypeScript Stack\n```bash\n# micro tier\n```\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
    // Round-3 P2: HTML comment bodies are blanked entirely, so they can neither
    // scope a SECTION nor merge into the claim beside them.
    [
      "other-gate sentence after a multi-line HTML comment mentioning micro",
      "### Mangled commit message — repair\n<!--\nmicro tier note\n-->\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
    // The other-gate escape works for a trailing appositive even though the
    // inserted-phrase-before-copula form is a documented conservative red.
    [
      "other-gate sentence with a trailing appositive",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nThe husky hook is warn-only, by default.\n",
    ],
    // Round-4: same for an inline-opener comment.
    [
      "other-gate sentence after an inline-opener HTML comment mentioning micro",
      "### Mangled commit message — repair\nSee the docs <!--\nmicro tier note\n-->\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
    // Round-4: a hyphenated non-tier `micro-…` compound must not scope a section.
    [
      "hyphenated non-tier micro compound",
      "### Hardware\nThe micro-USB port is warn-only on old boards.\n",
    ],
    // The inflected-form patterns must not fire on the ordinary-English
    // continuation — this is why they are patterns, not plain tokens.
    [
      "ordinary-English inflected 'warns only when' inside a scoped section",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nAt micro, the fixture warns only when the marker file is absent.\n",
    ],
    [
      "ordinary-English inflected 'only warns when' inside a scoped section",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nAt micro, the fixture only warns when the marker file is absent.\n",
    ],
    // Round-5: same for a same-line comment.
    [
      "other-gate sentence after a same-line HTML comment mentioning micro",
      "### Mangled commit message — repair\n<!-- micro tier note --> The `.husky/commit-msg` hook is warn-only.\n",
    ],
    // Round-7 P1: a COLON-BEARING other-gate name must still escape — `:` is a
    // clause boundary only when it separates. Before the fix this legitimate
    // sentence red (the band started after the `:` inside `arch:changed`).
    [
      "colon-bearing other-gate name",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe arch:changed check is warn-only.\n",
    ],
    // Round-7 boundary: the other-gate name at the HEAD of the subject is the
    // legitimate form even when the gate is related to it (the subject is that
    // gate, not the review-enforcer).
    [
      "other gate named at the subject head with a possessive modifier",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe husky hook's successor gate is warn-only.\n",
    ],
    // The punctuated leading subordinate clause is the PASSING form of the
    // documented residual R4 (the inverse heuristic must not red it).
    [
      "punctuated leading subordinate clause about another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nSince the husky hook is warn-only, the gate blocks.\n",
    ],
    // Round-8: the SAME label in BOLD must not turn a legitimate other-gate
    // sentence into a false red (the docs write `**Rationale:**`).
    [
      "bold label before a legitimate other-gate sentence",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n**Rationale:** the husky hook is warn-only by default.\n",
    ],
    [
      "bold one-word label before a legitimate other-gate sentence",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n**Note:** the VGATE check is warn-only for docs-only sets.\n",
    ],
    // Round-8: the subject-head window is the first THREE words (the comment's
    // stated rule) — a discourse-marker prefix is still the other gate's head.
    [
      "other-gate name at the third word of the subject",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nNote the husky hook is warn-only.\n",
    ],
    // Round-8: a COMPLEMENTIZER `that` (its own noun phrase follows) is not a
    // relative pronoun, so the clause's own other-gate subject still escapes.
    [
      "complementizer 'that' clause with the other gate as its subject",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe docs explain that the husky hook is warn-only.\n",
    ],
    [
      "complementizer 'that' clause with an imperative-mood lead",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nNote that the VGATE check is warn-only for docs-only sets.\n",
    ],
    // Round-9: a fence INSIDE a comment body is comment text — the body must not
    // scope the section (the open comment outranks fence tracking).
    [
      "fenced code inside a comment body must not scope a section",
      "### Mangled commit message — repair\n<!--\n```bash\n# micro tier note\n```\n-->\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
  ];
  for (const [label, doc] of UNRELATED_DOCS) {
    equal(findMicroWarnClaims(doc).length, 0, `#745 scope pin: unrelated-gate prose must PASS (${label}) — ${JSON.stringify(doc)}`);
  }

  // Round-7 P2: an UNTERMINATED HTML comment is REPORTED (T2 asserts this on
  // the real swept docs). Blank-to-EOF is markdown's reading of an unclosed
  // comment, so a stray opener would silence the pin for the rest of the doc
  // with CI green — the flag is what makes that loud instead.
  ok(
    blankHtmlComments("### X\n<!-- stray\n\nThe gate is warn-only.\n").unterminated,
    "#745 scope pin: an unterminated HTML comment must be reported (blank-to-EOF would blind the pin)"
  );
  ok(
    !blankHtmlComments("### X\n<!-- note -->\nThe husky hook is warn-only.\n").unterminated,
    "#745 scope pin: a terminated HTML comment must not be reported as unterminated"
  );
  // Round-9: a fence delimiter inside a comment body must not park the fence
  // state nor leave the comment reported as open — the comment still closes at
  // its `-->`.
  const commentWithFence = "### X\n<!--\n```bash\n# micro tier note\n```\n-->\nThe gate is warn-only.\n";
  ok(
    !blankHtmlComments(commentWithFence).unterminated,
    "#745 scope pin: a fence inside a comment body must not be reported as an unterminated comment"
  );
  equal(
    findMicroWarnClaims(commentWithFence).length,
    0,
    "#745 scope pin: a comment body containing a fence must be blanked, not leaked into section scope"
  );

  // Splitter regression pin: both halves of the emphasized-period case must
  // appear as SEPARATE sentence units, or the first sentence's scope token would
  // be donated to the second (making the T2b pass case above pass for the wrong
  // reason). Pinned directly on the unit split.
  const splitUnits = sectionSentenceUnits("### Extension Gates\nThe review-enforcer blocks at 0 dispatches. The husky hook is **warn-only.** The on-demand gate is warn only.\n");
  ok(
    splitUnits.some((u) => u.includes("warn-only") && !u.includes("0 dispatches")) &&
      splitUnits.some((u) => u.includes("the review-enforcer blocks") && !u.includes("warn-only")),
    `#745: a terminal period inside emphasis must split sentences (got ${JSON.stringify(splitUnits)})`
  );

  // Fenced-code headings must not open a section: a `# comment` inside a bash
  // block would silently shrink the enclosing section and lose the section-scope
  // evidence (the real 01-preflight.md carries several). The section list always
  // opens with the "(preamble)" bucket, so assert on the section itself.
  const fenced = "### Extension Gates\n```bash\n# micro tier note\n```\nThe gate is warn-only.\n";
  const fencedSections = markdownSections(fenced);
  ok(
    !fencedSections.some((s) => s.heading.includes("micro tier note")) &&
      fencedSections.find((s) => s.heading === "### Extension Gates")?.text.includes("# micro tier note") === true &&
      findMicroWarnClaims(fenced).length > 0,
    `#745: a \`# comment\` inside a fenced code block must not split the section (section-scope evidence must survive) — got ${JSON.stringify(fencedSections.map((s) => s.heading))}`
  );

  // Self-contained lines (headings, fence delimiters) must be their own SENTENCE
  // UNIT, or the prose unit would inherit their scope as SENTENCE scope and be
  // scored before the other-gate escape is consulted. (Section scope is separate
  // and deliberate.)
  const headUnits = sectionSentenceUnits("### Micro Tier Behavior\nThe VGATE content-shape check is warn-only for docs-only sets.");
  ok(
    !headUnits.some((u) => u.includes("micro tier behavior") && u.includes("warn-only")),
    `#745: a heading must be its own sentence unit (got ${JSON.stringify(headUnits)})`
  );
  const fenceUnits = sectionSentenceUnits("### TypeScript Stack\n```bash\n# micro tier\n```\nThe \`.husky/commit-msg\` hook is warn-only.");
  ok(
    !fenceUnits.some((u) => u.includes("micro tier") && u.includes("warn-only")),
    `#745: fenced code content must be its own sentence unit (got ${JSON.stringify(fenceUnits)})`
  );

  // End-to-end shape: the scope is a FILTER on claims, not a mute — a doc that
  // carries both the #691 unrelated-gate sentence and a re-drift still reds, and
  // only on the re-drift (the fence row carries two anti-tokens, so it reports
  // two claims — both FROM the re-drift row).
  const mixed = [
    "### Mangled commit message — repair",
    "The `.husky/commit-msg` hook is **warn-only** by default.",
    "",
    "### Extension Gates",
    "| Review-enforcer | **WARN-ONLY** at micro — 0 reviewer dispatches warn but do not block |",
  ].join("\n");
  const mixedClaims = findMicroWarnClaims(mixed);
  ok(mixedClaims.length > 0, "#745: a mixed doc still reds on the re-drift row");
  ok(
    mixedClaims.every((c) => c.section === "### Extension Gates" && !c.sentence.includes("husky")),
    "#745: every surviving claim is the review-enforcer fence row — the unrelated-gate sentence is filtered out"
  );
});

// ── #485 T3 — source-shape pin: the flip is anchored in code, not just docs ──

test("#485 T3: micro arm implements block (index.ts shape guard + region no-allow check)", () => {
  // Source-checkout-only, mirroring T2: a deployed extension copy is the synced
  // artifact; pinning ITS shape adds no drift signal (and its index.ts lives
  // beside an independently-synced skills/ tree).
  if (!isSourceCheckout()) {
    console.log("  ↪ skip (deployed copy — not an agent-infra source checkout)");
    return;
  }
  const src = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  // Discriminator tokens anchor the uniform-block implementation. Each one is
  // absent from the pre-#485 HEAD (verified: the old micro arm logged a warning
  // and returned undefined; MICRO_BLOCK_MESSAGE, TIER_RULE, and the #485
  // comments did not exist), so ANY functional revert removes ≥1 token — the
  // test fails the moment the flip is undone, even if the docs were reworded to
  // match. The all-5-keys "block" literals also pin the declared policy
  // independent of T2's symmetric fence compare (a coordinated fence+export
  // co-drift to "warn" fails here even though T2 compares like-with-like).
  const tokens = [
    "// #485: uniform ≥1-dispatch block",
    "reason: MICRO_BLOCK_MESSAGE",
    "export const TIER_RULE",
    'micro: "block"',
    'standard: "block"',
    'complex: "block"',
    'unknown: "block"',
    'unlabeled: "block"',
  ];
  for (const t of tokens) {
    ok(src.includes(t), `index.ts must contain ${JSON.stringify(t)} — the #485 uniform-block implementation drifted`);
  }
  // Ordering invariant: the #285 task-sub-agent carve-out and the
  // dispatch-count early return must sit ABOVE the micro tier block — a revert
  // that hoists the micro block above them would block dispatched micro
  // sessions. Anchored on a string UNIQUE to the early-return region (its
  // allow-path log, line ~812) — NOT the generic "parent-enforced" word, which
  // also appears in the session_start handler ~150 lines earlier and would make
  // this assertion vacuous. The behavioral complement (T1: micro marker + ≥1
  // dispatch → allowed) independently pins the same invariant.
  const earlyReturn = src.indexOf("the merge-registry gate protects merges");
  const microCheck = src.indexOf('if (tier === "micro")');
  ok(earlyReturn !== -1 && earlyReturn < microCheck, "the dispatch-count / task-sub-agent early return must precede the micro tier block");
  // Region slice: between the micro check and the generic block return there
  // must be NO `return undefined` (the pre-#485 warn-allow) — the only exits
  // are the micro block return and the generic block return below it.
  // The generic return is the file's FINAL `return { block: true, reason:
  // BLOCK_MESSAGE }` (merge-gate paths return mergeGateBlockReason, not the
  // BLOCK_MESSAGE constant): if a revert collapses the micro arm onto the
  // generic return, a first-occurrence-after-microCheck anchor would bind to
  // the micro arm's own copy and empty the region vacuously — the full-file
  // lastIndexOf keeps the slice meaningful.
  ok(microCheck !== -1, "micro arm must exist");
  const genericReturn = src.lastIndexOf("return { block: true, reason: BLOCK_MESSAGE }");
  ok(genericReturn !== -1 && genericReturn > microCheck, "generic block return must follow the micro arm");
  const region = src.slice(microCheck, genericReturn);
  ok(!region.includes("return undefined"), "micro arm region must not contain a warn-allow return undefined (#485)");
  // Absence scan (closes the code-side re-drift hole the plan's Task 3 step 6
  // specifies): a future micro CODE commit re-labeling the branch
  // 'warn-only'/'proportional'/'micro tier allows bypass' in comments or prose
  // fails CI even if the block logic is untouched. Case-insensitive on the
  // full source (the swept section header is "uniform ≥1-dispatch, all tiers"
  // — no legit 'proportional' remains anywhere in index.ts).
  const srcLower = src.toLowerCase();
  // Code-side absence set DERIVED from the T2 docs pin's shared vocabulary so
  // the two re-drift backstops can never silently diverge, plus the two
  // code-only tokens. "proportional" is code-only because the docs corpus
  // LEGITIMATELY carries it (01-preflight.md L41 "Pre-flight Verification
  // (proportional — from proportional-gates v1.0.0)") — adding it to the
  // shared MICRO_WARN_ANTI_TOKENS would false-positive T2's docs scan on that
  // product-version header; index.ts is its only re-drift surface. "allows
  // bypass" is genuinely absent from the docs corpus and is kept code-only for
  // symmetry with "proportional". The lookahead-guarded inflected PATTERNS
  // (MICRO_WARN_ANTI_PATTERNS) are scanned here too — they are not substrings of
  // any shared token, so omitting them would let the two backstops diverge on
  // exactly the forms #745 added (#745 review round 5). Case-insensitive
  // (WARN-ONLY is covered via "warn-only").
  const codeAntiTokens = [...MICRO_WARN_ANTI_TOKENS, "allows bypass", "proportional"];
  for (const token of codeAntiTokens) {
    ok(!srcLower.includes(token), `index.ts must not contain ${JSON.stringify(token)} — a micro warn/proportional re-label re-drifted (#486/#493 class)`);
  }
  for (const pattern of MICRO_WARN_ANTI_PATTERNS) {
    ok(
      !new RegExp(pattern.source, pattern.flags).test(src),
      `index.ts must not contain ${pattern} — a micro warn re-label re-drifted in inflected form (#745)`
    );
  }
});

// ── #930 admin-merge evidence gate ─────────────────────────────────────────
// The adversarial declaration (issue #930 scoping comment) names five in-scope
// threat classes. Each has a test here that FAILS without the fix:
//   1. stale evidence           — marker at head X accepted at head Y
//   2. forgery/vacuity          — marker present but computed over an empty/
//                                 unparsed failing set
//   3. flake escape             — re-run classification laundering a real
//                                 failure into "flaky" (tests/admin-merge/run.sh)
//   4. arg-order evasion        — `--admin` before the PR number, `--admin=true`
//   5. parity drift             — pre-merge gate vs post-merge detector
//                                 (tests/admin-merge/run.sh §9: one `comm -23`)

section("#930 admin-merge — flag detection and arg-order-proof PR extraction");

test("hasAdminMergeFlag: every --admin shape a bypass can take", () => {
  ok(hasAdminMergeFlag("gh pr merge --admin 123"), "flag before the number");
  ok(hasAdminMergeFlag("gh pr merge 123 --admin"), "flag after the number");
  ok(hasAdminMergeFlag("gh pr merge --admin=true 123"), "--admin=true");
  // gh parses this flag with Go's strconv.ParseBool: EIGHT case-sensitive true
  // spellings. Matching only the literal `true` let every other spelling through
  // as "not an admin merge", so the command fell to the merge-registry gate and
  // merged with NO evidence — a live fail-open (review P1, cycle 2).
  for (const v of ["1", "t", "T", "TRUE", "True", '\"true\"']) {
    ok(hasAdminMergeFlag(`gh pr merge 123 --admin=${v}`), `--admin=${v} is a bypass (Go-true spelling)`);
    ok(hasAdminMergeFlag(`gh pr merge --admin=${v} 123`), `--admin=${v} before the number`);
  }
  ok(hasAdminMergeFlag("gh pr merge 123 --admin='True'"), "a single-quoted Go-true value");
  // ...and the Go-FALSE spellings must still not be refused: `--admin=false` is
  // an ordinary merge and must take the registry path, not be blocked here.
  for (const v of ["0", "f", "F", "FALSE", "false", "False"]) {
    ok(!hasAdminMergeFlag(`gh pr merge 123 --admin=${v}`), `--admin=${v} is NOT a bypass`);
  }
  // SHELL SPELLINGS (VGATE cycle 2): bash lowers each of these to a real
  // `--admin=true` before gh sees it, but we see the raw string. The gate cannot
  // evaluate a shell, so anything it cannot RESOLVE to a Go-false value is
  // treated as an admin merge. Enumeration is not possible (`$(…)` is arbitrary);
  // these are the shapes that broke the previous `=== "true"` rule.
  const shellSpellings = [
    "--admin\\=true",
    "--admin=$'true'",
    "--admin=`true`",
    "--admin=$(echo true)",
    "--admin=${X:-true}",
    '--admin=tr""ue',
    "--admin=$ADMIN_VAL",
    "--admin=true;echo x",
    "--admin=TRUE&&echo x",
    "--admin=true|cat",
  ];
  for (const s of shellSpellings) {
    ok(hasAdminMergeFlag(`gh pr merge 123 ${s}`), `${s} is a bypass (bash delivers --admin=true; we fail closed)`);
  }
  // The same bash-quoting family on the flag NAME: bash re-joins the token, so
  // these reach gh as a real `--admin=true` while carrying no literal `--admin`
  // in the raw string. Quotes are stripped before matching (VGATE round 2, D1).
  for (const s of ['--ad""min=true', '--"admin"=true', "--ad'min'=true", '--admin"=true']) {
    ok(hasAdminMergeFlag(`gh pr merge 123 ${s}`), `${s} is a bypass (quote-split flag name)`);
  }
  // VGATE round 3 found the SAME family via backslashes, line continuations and
  // ANSI-C quoting — all reach gh as `--admin` / `--admin=true`. Enumerating
  // spellings is what produced three rounds of fail-opens, so the scanner now
  // resolves quotes/escapes/continuations and FAILS CLOSED on the rest.
  const splicingSpellings = [
    "--ad\\min=true",
    "--adm\\in",
    "--ad\\m\\i\\n=true",
    "--ad\\\nmin=true",
    "$'--admin'",
    "$'--adm\\x69n'",
    "$'--admin=TRUE'",
    "--adm$'\\x69'n=true",
    "--admi${X}n=true",
    "--admi$X=true",
    "--admin=$ADMIN_VAL",
  ];
  for (const s of splicingSpellings) {
    ok(hasAdminMergeFlag(`gh pr merge 123 ${s}`), `${JSON.stringify(s)} is a bypass (spliced name or unresolvable value)`);
  }
  // ── #1420: the ANSI-C rule must NOT fire on a `$` that merely ENDS an
  // ordinary quoted string.
  //
  // The naive `/\$['"]/` test read the closing quote of `"bug$"` as an ANSI-C
  // opener, so `hasAdminMergeFlag` flipped true; `isAdminMergeCommand`'s
  // `gh`-word fallback then turned an ordinary READ command into an admin merge
  // and the gate blocked it with "carries no resolvable PR number". Production
  // shape: 927 of 981 `merge_gate_block reason=admin_merge_no_evidence` events
  // carried NO resolvable PR number — a false positive, not a merge.
  const ansiCFalsePositives = [
    ['gh label list --repo o/r --limit 5 --json name | grep -E "bug$"', "a regex anchored at end-of-line"],
    ["gh label list --repo o/r | grep -E 'bug$'", "the same regex in single quotes"],
    ['grep -E "bug$" file && echo ok', "the anchored regex mid-command"],
    ["gh pr list --search 'merge$'", "a search term that both ends in `$` and names a merge"],
  ];
  // NOT in this list — these are a SIBLING over-block by a different rule
  // (`hasUnresolvableConstruct && /admin/`, and an ANSI-C quote in a benign
  // VALUE), still open and tracked as #1421: `gh issue comment 5 --body
  // $'multi line'`, `echo $'done' && gh issue list`, `git commit -m $'fix:
  // thing'`, `gh pr view 1 --json body --jq '.body | test("admin$")'`. They are
  // unchanged behaviour, and asserting them here would force this fix to widen,
  // which is what made it fail OPEN twice.
  for (const [c, why] of ansiCFalsePositives) {
    ok(!hasAdminMergeFlag(c), `#1420: ${why} is not an admin flag: ${JSON.stringify(c)}`);
    ok(!isAdminMergeCommand(c), `#1420: ...and not an admin merge: ${JSON.stringify(c)}`);
  }
  // ...while every ANSI-C shape that can really carry the flag stays caught —
  // including the FULLY-spliced forms naming neither `merge` nor `admin`.
  for (const c of [
    "gh pr merge 999 $'--admin'",
    "gh pr merge 999 $'--adm\\x69n'",
    "gh pr merge 999 --adm$'\\x69'n=true",
    "gh pr merge 999 $'\\x2d\\x2d\\x61dmin'",
    "gh pr merge 999 $''--admin",
    "gh pr merge 999 \"$'--admin'\"",
    "gh p$'r' merge 999 --admin",
    "gh p$'r' m$'erge' 999 $'\\x2d\\x2d\\x61dmin'",
    "gh pr m$'erge' 999 $'\\x2d\\x2d\\x61dmin'",
    // VGATE cycle 2: the SPLICED-VERB + hidden-flag shape that a companion
    // `merge`/`admin` WORD condition let through — bash runs it as
    // `gh pr merge 999 --admin`, yet no raw word `merge` or `admin` appears, and
    // `hasConstructTokenAfter` cannot recover it (`dequote("$'gh'") !== "gh"`).
    // It is why this fix adds NO companion condition.
    "$'gh' p$'r' m$'erge' 999 $'\\x2d\\x2d\\x61dmin'",
  ]) {
    ok(isAdminMergeCommand(c), `#1420: the ANSI-C admin merge is still caught: ${JSON.stringify(c)}`);
  }
  // Fresh-context VGATE cycle 1 on this fix found a FAIL-OPEN: a predicate that
  // asks quote state whether the `$` is unquoted models ONE shell, so the `$'`
  // of `bash -c "gh pr merge $'\x2d…'"` — inside the OUTER shell's double-quoted
  // region but evaluated by the INNER shell — slipped through. Text shape, not
  // quote state, is what separates the `$`-at-end-of-string false positive from
  // these; every nested-shell/escaped spelling must stay caught.
  for (const c of [
    `bash -c "gh pr merge $'\\x2d\\x2d\\x61dmin'"`,
    `sh -c "gh pr merge $'\\x2d\\x2d\\x61dmin'"`,
    `sudo bash -lc "gh pr merge $'\\x2d\\x2d\\x61dmin'"`,
    `bash -c "gh pr merge $'\\x2d\\x2d\\x61dmin' 999"`,
    `echo "gh pr merge $'\\x2d\\x2d\\x61dmin'" | bash`,
    `bash -c "gh pr merge 999 $'--admin'"`,
    `bash -c "$'gh' p$'r' m$'erge' 999 $'\\x2d\\x2d\\x61dmin'"`,
    String.raw`bash -c 'gh pr merge $'\''\x2d\x2d\x61dmin'\'''`,
  ]) {
    ok(isAdminMergeCommand(c), `#1420: the nested-shell/escaped ANSI-C admin merge is still caught: ${JSON.stringify(c)}`);
  }
  // `gh pr "merge"` is the same family one level up: bash re-joins it, so the
  // CALLER's guard must see the normalized form or the whole gate is skipped.
  ok(isGhPrMergeCommand('gh pr "merge" 123 --admin=true'), 'gh pr "merge" is recognized as a merge command (normalized)');
  ok(isGhPrMergeCommand("gh pr merge 123"), "a plain `gh pr merge` is recognized");
  ok(!isGhPrMergeCommand("gh pr view 123 --json headRefOid"), "`gh pr view` is not a merge command");
  // A VERB we cannot resolve must not be a way PAST the gate (VGATE round 5).
  for (const c of [
    "gh pr $'merge' 123 --admin=true",
    'gh pr $"merge" 123 --admin=true',
    "gh pr m$'erge' 123 --admin=true",
    'gh pr m""erge 123 --admin=true',
    "M=merge; gh pr $M 123 --admin=true",
    "gh pr `echo merge` 123 --admin=true",
  ]) {
    ok(isGhPrMergeCommand(c), `an unresolvable verb is treated as a merge: ${JSON.stringify(c)}`);
    ok(hasAdminMergeFlag(c), `...and its admin flag is seen: ${JSON.stringify(c)}`);
  }
  // VGATE round 6: the SPLICE can sit on the `gh`/`pr` words too, or be glued to
  // the verb. Rule 2 keys on the unresolvable CONSTRUCT plus the two verb words
  // anywhere, not on a position — enumerating positions is what produced rounds
  // 3, 5 and 6.
  for (const c of [
    "gh $'pr' merge 123 --admin=true",
    "$'gh' pr merge 123 --admin=true",
    "g$'h' pr merge 123 --admin=true",
    "gh pr merge$(printf '%s' '') 123 --admin=true",
    "gh pr $(echo merge) 123 --admin=true",
    "gh pr {merge,view} 123 --admin=true",
  ]) {
    ok(isGhPrMergeCommand(c), `a spliced gh/pr/verb is treated as a merge: ${JSON.stringify(c)}`);
    ok(hasAdminMergeFlag(c), `...and its admin flag is seen: ${JSON.stringify(c)}`);
  }
  // Rule 2 must NOT make harmless commands GATE-RELEVANT. This asserts the
  // SHIPPED predicate (`isGitOp`) directly — not a replica. VGATE round 7 found
  // that a replica let the conjunction be dropped with the suite still green.
  for (const c of [
    'echo "gh pr merge 1 --squash"',
    "rg 'gh pr merge' scripts/",
    'echo "git commit -m x"',
    "gh pr view 123 --json headRefOid",
    'echo "$(date)"',
    "rg '{a,b}' -- files",
  ]) {
    ok(!isGitOp(c), `not gate-relevant: ${JSON.stringify(c)}`);
  }
  // The shipped predicate MUST be gate-relevant for every bypass shape above.
  for (const c of [
    "gh pr merge 123 --admin=true",
    'gh pr "merge" 123 --admin=true',
    "gh pr $'merge' 123 --admin=true",
    "gh $'pr' merge 123 --admin=true",
    'gh pr merge 123 -${V:--}admin=true',
    "gh pr merge 123 $V-admin=true",
    'gh pr merge 123 -$(printf %s \'-\')admin=true',
  ]) {
    ok(isGitOp(c), `gate-relevant (the rail must see this): ${JSON.stringify(c)}`);
  }
  // A construct WITHOUT the word `admin` must not trigger the ADMIN gate. This is
  // the over-block boundary the docstring promises: the common
  // `gh pr merge "$PR" --squash` stays an ordinary merge. (It is still
  // `isGitOp`-relevant — the registry gate governs every merge — so the assertion
  // belongs on `hasAdminMergeFlag`, not on `isGitOp`.)
  for (const c of [
    'gh pr merge "$PR" --squash',
    "gh pr merge 123 --body \"$(cat msg)\"",
    "gh pr merge 123 --squash --delete-branch",
    "gh pr merge 123 --admin=false",
  ]) {
    ok(!hasAdminMergeFlag(c), `a construct without \`admin\` does not trigger the admin gate: ${JSON.stringify(c)}`);
  }
  // A quoted MENTION carrying an admin flag must stay OUT of the gate: `gh` inside
  // the quotes is not a bare token, so this is not a command. This was a real
  // over-block (it fired on heredocs and greps) until the bare-`gh` requirement
  // was added (VGATE round 8); pin it so it cannot come back.
  ok(!isGitOp('echo "gh pr merge 1 --admin=true"'), 'a quoted MENTION with an admin flag is NOT gate-relevant');
  ok(!isGitOp('printf %s "gh pr merge 1 --admin=true"'), 'a quoted MENTION inside printf is NOT gate-relevant');
  // `hasAdminMergeFlag` is fail-closed and therefore far too broad to be a
  // RELEVANCE test on its own. Using it as one blocked ordinary shell commands at
  // zero dispatches (VGATE round 9) because it returns true for ANSI-C quoting and
  // for any construct beside the word `admin`. The shape conjunction is what
  // prevents that; pin it.
  for (const c of ["echo $'hello'", 'sed $\'s/x/y/\' file', "grep -P $'\\t' file", 'echo "admin $USER"', 'cat admin-$USER.txt', "echo $(date)"]) {
    ok(!isGitOp(c), `an ordinary command is NOT gate-relevant: ${JSON.stringify(c)}`);
  }
  // ...and a quoted MENTION stays clean even though its normalized text is a
  // perfect `gh pr merge` — the distinction is QUOTE STATE, not text, which is
  // why `hasBareGhWord` exists (VGATE round 10).
  for (const c of ["rg 'gh pr merge' scripts/", "printf %s 'gh pr merge 1 --admin=true'"]) {
    ok(!isGitOp(c), `a quoted mention is NOT gate-relevant: ${JSON.stringify(c)}`);
  }
  // NOT CLOSED, deliberately, and STATED in the docstring rather than claimed:
  // a `$VAR` expanded UPSTREAM of the string, `gh api … /merge`, and `gh alias`
  // shims are invisible here. Those need argv-level enforcement. Do not add an
  // assertion asserting otherwise.
  // An UNPARSEABLE value is refused rather than allowed. This is the safe
  // direction: gh errors on it (`invalid argument … strconv.ParseBool`), so
  // refusing a command gh would have rejected costs nothing, while allowing it
  // on the theory that gh would error is a fail-open if that theory is wrong.
  ok(hasAdminMergeFlag("gh pr merge 123 --admin=zork"), "an unparseable value is refused (fail closed)");
  ok(hasAdminMergeFlag("gh pr merge 123 --admin=''"), "an empty quoted value is refused (fail closed)");
  ok(hasAdminMergeFlag("gh pr merge --admin= 123"), "--admin= (gh's own empty = true)");
  ok(hasAdminMergeFlag("gh pr merge --squash --admin 123"), "after another flag");
  ok(hasAdminMergeFlag("cd /x && gh pr merge --admin 123"), "behind a cd chain");
  ok(!hasAdminMergeFlag("gh pr merge 123 --admin=false"), "--admin=false is NOT a bypass (must not refuse)");
  ok(!hasAdminMergeFlag("gh pr merge 123 --squash"), "plain merge untouched");
  ok(!hasAdminMergeFlag("gh pr merge 123 --adminx"), "a `--adminx` typo is NOT a bypass (no false block)");
  ok(!hasAdminMergeFlag("gh pr merge 123 --no-admin"), "`--no-admin` is not the flag");
});

test("isAdminMergeCommand: the flag-shape fail-closed rules and their carve-outs", () => {
  // Cycle-4 review P2: the `$VAR`-supplied-flag BRANCH could be deleted with the
  // suite still green, because the only class-6 case in the table (`V=--admin; gh
  // pr merge … $V`) is caught earlier by the literal-`admin` rule. These assert what
  // ONLY that branch provides, so deleting it goes red.
  ok(!isAdminMergeCommand("gh pr merge $PR --squash"), "the position argument is exempt in EITHER quoting form");
  ok(isAdminMergeCommand("gh pr merge $PR $FLAG"), "a SECOND `$`-bearing argument can hide the flag, so it fails closed");
  ok(isAdminMergeCommand("gh pr merge 999 $FLAG"), "a bare `$VAR` argument after the position fails closed");
  ok(isAdminMergeCommand("V=--admin; gh pr merge 999 $V"), "a `$VAR`-supplied flag fails closed");
  ok(isAdminMergeCommand('gh pr merge 999 "$(printf x)"'), "a QUOTED substitution argument fails closed");
  // The carve-outs that keep legitimate merges usable.
  ok(!isAdminMergeCommand('gh pr merge "$PR" --squash'), "the QUOTED position argument is NOT gated");
  ok(!isAdminMergeCommand('gh pr merge 999 --body "$(cat msg)"'), "a dynamic --body is NOT the flag");
  ok(!isAdminMergeCommand('gh pr merge 999 -F "$tmpfile"'), "a dynamic --body-file is NOT the flag");
  ok(!isAdminMergeCommand('cd "$HOME/wt" && gh pr merge 7'), "a `$` BEFORE the merge word is not the flag");
  ok(!isAdminMergeCommand("gh pr view $X"), "a non-merge gh call with a `$VAR` is NOT gated");
});

test("countMergeVerbs: a compound command must fail closed", () => {
  // Fresh review P1-1: `extractMergePrNumber` deliberately truncates at the first
  // separator and the gate evaluates ONE PR, so `gh pr merge 111 --admin; gh pr
  // merge 999 --admin` was judged against 111's evidence and then merged 999 with
  // no evidence at all. The caller blocks when the count exceeds 1.
  ok(countMergeVerbs("gh pr merge 111 --admin; gh pr merge 999 --admin") === 2, "two merges are counted");
  ok(countMergeVerbs("gh pr merge 111 --admin && gh pr merge 999 --admin") === 2, "&& counts too");
  ok(countMergeVerbs("gh pr merge 111 --admin\ngh pr merge 999 --admin") === 2, "a newline counts too");
  ok(countMergeVerbs("gh pr merge 123 --admin") === 1, "a single merge is one");
  ok(countMergeVerbs("gh pr merge 123 --squash") === 1, "a non-admin merge still counts (the registry gate sees it)");
  ok(countMergeVerbs("gh pr view 1") === 0, "a non-merge is zero");
  ok(countMergeVerbs("gh pr merge 1 --admin; gh pr list") === 1, "a trailing unrelated gh call is not a second merge");
  ok(countMergeVerbs("gh -R o/r pr merge 1 --admin") === 1, "the global -R flag does not hide the verb");
});

test("extractMergePrNumber: flag order never hides the PR number", () => {
  equal(extractMergePrNumber("gh pr merge 123"), 123);
  equal(extractMergePrNumber("gh pr merge --admin 123"), 123, "flag before the number (the evasion)");
  equal(extractMergePrNumber("gh pr merge --squash --admin 123"), 123);
  equal(extractMergePrNumber("gh pr merge 123 --admin"), 123);
  equal(extractMergePrNumber("gh pr merge --repo owner/name --admin 123"), 123, "--repo's value is not the PR");
  equal(extractMergePrNumber("gh pr merge -R owner/name 123"), 123);
  equal(extractMergePrNumber("gh pr merge --admin --repo=owner/name 123"), 123, "--flag=value form");
  equal(extractMergePrNumber("gh pr merge --admin"), null, "no number → cannot bind evidence");
  equal(extractMergePrNumber("gh pr merge --admin; sleep 123"), null, "a later command's number is NOT this merge's PR");
  equal(extractMergePrNumber("gh pr create --title 123"), null);
});

// ── #1007: the PR POSITIONAL — a URL, not only a number ──────────────────────
// `gh pr merge <url> --admin` used to be refused by BOTH layers (this scanner and the
// argv-level shim). That refusal was fail-closed, but it was an over-block — and an
// over-block is what pushes a caller at AGENT_ADMIN_MERGE_OVERRIDE, the outcome the
// gate exists to prevent. The URL is now resolved: the number is IN the token, so no
// second party is asked who the PR is.
//
// A BRANCH selector stays REFUSED, deliberately: resolving a branch to a number needs a
// `gh` call, i.e. the gate asking the gated thing for the identity it is about to check.
//
// PARITY: `scripts/gh-shim/gh::parse_pr_url` accepts the SAME one shape, and
// `tests/gh-shim/run.sh` §11 drives this same table through the argv layer (with a
// tripwire that fails if the TS shape moves without that file). If this table changes,
// change that one in the same commit.
section("#1007 — the PR selector: a strict URL is resolved, a branch is not");

const PR_URL_1006 = "https://github.com/daniel-ospina/agent-infra/pull/1006";

test("extractMergeSelector: a PR URL is resolved to its number AND its repo", () => {
  // The repo matters as much as the number: gh resolves the merge against the URL's
  // repo, so reading the evidence from anywhere else verifies a PR gh is not about to
  // merge (the `--repo` wrong-repo class, in a third spelling).
  const s = extractMergeSelector(`gh pr merge ${PR_URL_1006} --admin`);
  equal(s.pr, 1006, "the number is extracted from the URL");
  equal(s.repo, "daniel-ospina/agent-infra", "…and the URL's repo with it");
  equal(extractMergePrNumber(`gh pr merge ${PR_URL_1006} --admin`), 1006, "extractMergePrNumber delegates");
  equal(extractMergeSelector(`gh pr merge --admin ${PR_URL_1006}`).pr, 1006, "flag order does not hide the URL");
  equal(extractMergeSelector(`gh pr merge ${PR_URL_1006} --admin`).repo,
    extractMergeSelector(`gh pr merge --admin ${PR_URL_1006}`).repo, "the repo is found in either order");
  equal(extractMergeSelector("gh pr merge 123 --admin").repo, null, "a bare number carries no repo");
  equal(extractMergeSelector("gh pr create --title 123").pr, null, "a non-merge is out of scope");
});

test("extractMergeSelector: a BRANCH selector stays unresolved (fail closed)", () => {
  equal(extractMergeSelector("gh pr merge my-branch --admin").pr, null, "a branch is not a selector here");
  equal(extractMergeSelector("gh pr merge release/v2 --admin").pr, null, "…including a slash branch");
  equal(extractMergeSelector("gh pr merge feature/1007 --admin").pr, null, "…even when it contains digits");
  equal(evaluateAdminMergeGate(extractMergeSelector("gh pr merge my-branch --admin").pr, "a".repeat(40), [], false).status,
    "block", "…and the gate then blocks it (an over-block, stated as such)");
});

test("extractMergeSelector: every near-miss refuses (the number must be IN the token)", () => {
  const bad = [
    "https://github.com/o/r/pull/abc",
    "https://github.com/o/r/pull/",
    "https://github.com/o/r/pull/123/files",
    "https://github.com/o/r/pull/123/",
    "https://github.com/o/r/pull/123?s=1",
    "https://github.com/o/r/pull/123#x",
    "http://github.com/o/r/pull/123",
    "github.com/o/r/pull/123",
    "https://evil.com/o/r/pull/123",
    "https://www.github.com/o/r/pull/123",
    "https://github.com/o/r",
    "https://github.com//pull/1",
    "https://github.com/o//pull/1",
    "https://github.com/o!/r/pull/1",
    "https://github.com/o/x y/pull/1",
  ];
  for (const u of bad) equal(extractMergeSelector(`gh pr merge ${u} --admin`).pr, null, `refused: ${u}`);
});

test("resolveRepoContext: a URL's repo OUTRANKS --repo and GH_REPO (gh ignores both)", () => {
  // Probed live 2026-09-14 (recorded in scripts/gh-shim/gh):
  //   gh pr merge <URL to a repo that does not exist> --repo <one that does>
  //     → "Could not resolve to a Repository with the name '…definitely-not-a-repo-xyz'"
  //   gh pr merge <URL to one that exists> --repo <one that does not>
  //     → failed on the URL's PR, never on the bogus --repo
  // So `--repo` is dead input when the selector is a URL, and honouring it would read
  // the evidence from a repo gh is not merging.
  const ctx = resolveRepoContext(`gh pr merge ${PR_URL_1006} --admin --repo owner/other`, null);
  equal(ctx.repo, "daniel-ospina/agent-infra", "the URL's repo wins over --repo");
  equal(ctx.source, "url", "…and the context says where it came from");
  equal(resolveRepoContext(`GH_REPO=env/repo gh pr merge ${PR_URL_1006} --admin`, null).repo,
    "daniel-ospina/agent-infra", "…and over GH_REPO");
  // The URL is NOT a repo source when it is not the selector.
  equal(resolveRepoContext("gh pr merge 123 --admin", null).source, "fallback",
    "a bare-number merge is unaffected by this rule");
});

test("extractMergeSelector: a URL in a flag VALUE is never the selector — either order", () => {
  // VGATE cycle 1 (#1007) found this as a FAIL-OPEN: the walk was not quote-aware, so
  // `--body "see <url> here"` left the URL as a FREE token and it became the selector —
  // the gate then read the head and comments of a different PR in a DIFFERENT repo than
  // gh merges, and a foreign certificate would satisfy it. The vulnerable ordering is
  // the value BEFORE the positional; with the positional first the walk returns early,
  // which is why an earlier version of this test passed while the bug was live.
  const values = [
    `--body "see ${PR_URL_1006} for context"`, // quoted, multi-word — the exploit
    `--body "see ${PR_URL_1006}"`,
    `--body ${PR_URL_1006}`, // unquoted, single token
    `-b "see ${PR_URL_1006} here"`, // short form, same skip
    `--body-file ${PR_URL_1006}`,
    `--subject "re ${PR_URL_1006} now"`,
    `-t ${PR_URL_1006}`,
    `--author-email ${PR_URL_1006}`,
    `-A "notes ${PR_URL_1006}"`, // -A was MISSING from valueFlags
    `--match-head-commit ${PR_URL_1006}`,
    `--hostname ${PR_URL_1006}`, // --hostname was MISSING too
    `--body="see ${PR_URL_1006} here"`, // attached form
  ];
  for (const v of values) {
    // (a) THE VULNERABLE ORDERING: value first, real positional after it.
    const before = `gh pr merge ${v} 123 --admin`;
    equal(extractMergeSelector(before).pr, 123, `value before the positional: ${v}`);
    equal(extractMergeSelector(before).repo, null, `…and no URL repo leaks: ${v}`);
    ok(!resolveRepoContext(before, null).repo, `…and the repo context stays empty: ${v}`);
    // (b) the ordering the earlier test used (it returned early — vacuous for (a)).
    const after = `gh pr merge 123 --admin ${v}`;
    equal(extractMergeSelector(after).pr, 123, `positional first: ${v}`);
    equal(extractMergeSelector(after).repo, null, `…and no URL repo leaks: ${v}`);
  }
  // Escaped quotes: the tokenizer only closes a quote on an UNESCAPED one, in EVERY
  // context (never earlier than bash would). VGATE's second cycle reached the same
  // fail-open through `\"` inside a double-quoted value and through the `$'…\'…'` form.
  const escaped = [
    `--body "a\\" ${PR_URL_1006} b"`, // `\"` inside a double-quoted value
    `--body $'a\\' ${PR_URL_1006} b'`, // ANSI-C: `\'` is an escape, not a close
    `--subject "x\\" ${PR_URL_1006}"`,
  ];
  for (const v of escaped) {
    const before = `gh pr merge ${v} 123 --admin`;
    equal(extractMergeSelector(before).pr, 123, `escaped quote before the positional: ${v}`);
    equal(extractMergeSelector(before).repo, null, `…and no URL repo leaks: ${v}`);
  }
  // …and with NO positional, a value-hosted URL must not stand in for one.
  equal(extractMergeSelector(`gh pr merge --admin --body "see ${PR_URL_1006} here"`).pr, null,
    "a body URL is not a selector (no positional)");
  equal(resolveRepoContext(`gh pr merge --admin --body "see ${PR_URL_1006} here"`, null).source,
    "fallback", "…and it is not a repo source either");
});

test("extractMergeSelector: the two layers must agree on the NUMBER, not just the shape", () => {
  // A leading zero or a value above 2^53 is one the TS side cannot hold in a Number
  // while the shim passes the literal digits to the verifier. Refused on both sides
  // rather than silently read as a DIFFERENT PR's evidence.
  for (const n of ["0", "01006", "0001", "9007199254740993", "99999999999999999999"]) {
    equal(extractMergeSelector(`gh pr merge https://github.com/o/r/pull/${n} --admin`).pr, null,
      `refused on the TS side: /pull/${n}`);
  }
  equal(extractMergeSelector("gh pr merge https://github.com/o/r/pull/1006 --admin").pr, 1006,
    "a normal number still resolves (the guard is not an over-block)");
});

test("extractMergeSelector: nested substitutions — the selector the SHELL would pass", () => {
  // Every expectation here was taken from real bash argv (a fake `gh` printing "$@"),
  // not from the tokenizer. A substitution is ONE word to the shell, and `$( … )` /
  // backticks opened inside a quoted value carry their OWN quote state: a `"` inside
  // them does not close the outer `"`. Modeled with a level stack (VGATE #1007 c3).
  const cases: Array<[string, number, string | null]> = [
    [`--body "$(cat msg)" 123`, 123, null],
    [`--body "$(${PR_URL_1006})" 123`, 123, null], // the URL is inside the VALUE
    [`--body "$(echo ${PR_URL_1006})" 123`, 123, null],
    [`--body "\`echo ${PR_URL_1006} \`" 123`, 123, null],
    [`--subject "\`id -u\`" 123`, 123, null],
    [`--body "$(echo 999)" 123`, 123, null],
    [`--body "$((1+2))" 123`, 123, null],
    [`--body "$(echo $((1+2)))" 123`, 123, null],
    [`--body "$( (a) )" 123`, 123, null], // paren depth inside `$( … )`
    [`--body "$(echo ')')" 123`, 123, null], // a `)` inside a quoted inner region
    // The inner 77 is a VALUE of the inner `--body`-like construct; the shell hands the
    // outer positional. A tokenizer that reached into the substitution would name 77.
    [`--body "$(" 77 ")" 456`, 456, null],
  ];
  for (const [v, pr, repo] of cases) {
    const s = extractMergeSelector(`gh pr merge ${v} --admin`);
    equal(s.pr, pr, `shell-verified selector for: ${v}`);
    equal(s.repo, repo, `…and repo for: ${v}`);
  }

  // VGATE #1007 cycle 3 found a real FAIL-OPEN — and it was BASH-ACCEPTED, not just a
  // fatal-input artifact. A `$(case …)` region closes at its pattern `)` (bash does the
  // same), so the region popped early and the text after it became free tokens. But bash
  // evaluates `$(case x in y)` to an ERROR (empty + word removed), so the number after it
  // is consumed as `--body`'s VALUE — the positional is ABSENT and gh merges the CURRENT
  // BRANCH's PR, while the scanner reported that number. `case`/`esac` state keeps the
  // region open, so no token inside it can stand in for the positional.
  for (const body of [
    `--body $(case x in y) 123`, // bash: positional ABSENT (123 is --body's value)
    `--body $(case x in y) ${PR_URL_1006} 123`, // bash: selector 123 (URL is the value)
    `--body $(case x in y) ${PR_URL_1006} esac) 123`, // bash: syntax error, rc≠0
    "--body `case x in y) 123`", // bash: substitution errors, `--admin` is swallowed as the body
  ]) {
    const s = extractMergeSelector(`gh pr merge ${body} --admin`);
    equal(s.pr, null, `no token inside a case region is the selector: ${body}`);
    equal(s.repo, null, `…and no repo either: ${body}`);
    // Measured: for the first TWO rows bash ACCEPTS the command and runs gh, so this is a
    // fail-closed fix, not a cosmetic one — an unevidenced-in-reality PR can no longer be
    // named for approval. For the others bash fails before gh runs.
    equal(evaluateAdminMergeGate(s.pr, "a".repeat(40), [], false).status, "block",
      `…and the gate blocks: ${body}`);
  }

  // The ROOT still splits: a substitution is ONE word to the shell, so the literal token
  // after it is a separate word and is still found. NOTE this is a statement about the
  // TOKENIZER, not bash parity: bash passes the substitution's OUTPUT as the positional
  // (`$(printf x) 123` reaches gh as `x 123`), which is not statically knowable — and gh
  // then rejects a second positional. The argv-level shim is what decides that case.
  equal(extractMergeSelector(`gh pr merge $(printf x) 123 --admin`).pr, 123,
    "the substitution is one word; the next literal token is the next word");
  equal(extractMergeSelector(`gh pr merge 123 $(printf x) --admin`).pr, 123,
    "…in either order");
});

test("extractMergeSelector: unmodeled shell syntax in a QUOTED value refuses (never a fail-open)", () => {
  // These are the shapes where the fast string layer cannot reproduce the shell's argv:
  // a QUOTED value carrying shell separators (`;;`, `{ }`, `( )`, `for … done`, `&&`).
  // Each MEASURED against real bash argv: for every row below bash ACCEPTS the command
  // and gh would see the trailing 123 as its positional, while this layer refuses. That
  // is deliberately the SAFE direction — the over-block the issue is about, in its
  // narrowest form — and it is why the shim (real argv) is the authority here, not this.
  // If a future edit makes any of these resolve, prove it against bash argv first.
  const overBlocks = [
    `--body "$(case x in y) echo z ;; esac)"`,
    `--body "$(case x in y) echo z ;; y2) echo w ;; esac)"`,
    `--body "$(case x in (y) echo z ;; esac)"`,
    `--body "$(f() { echo x; }; f)"`, // a function definition in a quoted value
    `--body "$(for i in 1 2; do echo $i; done)"`,
    `--body "$([ -f x ] && echo y)"`,
  ];
  for (const v of overBlocks) {
    equal(extractMergeSelector(`gh pr merge ${v} 123 --admin`).pr, null,
      `refused rather than guessed (bash would merge 123): ${v}`);
    // …and the gate it feeds must therefore refuse too, not fall through to another path.
    equal(evaluateAdminMergeGate(extractMergeSelector(`gh pr merge ${v} 123 --admin`).pr,
      "a".repeat(40), [], false).status, "block", `…and the gate blocks: ${v}`);
  }
});

test("extractMergeSelector: a repo PAIR cannot leak its value's tail into the selector", () => {
  // VGATE #1007 cycle 4 (P0): `extractMergeSelector` used to read its token stream from
  // `stripRepoArgs(command)`, which removes only the FIRST whitespace-delimited word of a
  // value. A quoted `--repo "see <url> here"` therefore left ` <url> here"` as free text
  // and the URL branch returned that URL as the selector — naming a DIFFERENT PR and a
  // different repo than gh merges (the old `^\d+$`-only walk ignored the leaked URL, so
  // the URL feature introduced it). The selector now comes from the ORIGINAL tail.
  const pair = `--repo "see ${PR_URL_1006} here"`;
  const forms = [
    `gh pr merge ${pair} 123`, // quoted value, post-verb
    `gh pr merge -R "see ${PR_URL_1006} here" 123`,
    `gh pr merge --repo="see ${PR_URL_1006} here" 123`, // =-joined quoted value
    `gh pr merge ${pair} --repo cli/cli 123`, // a second, VALID --repo wins for gh
    `gh ${pair} pr merge 123`, // the pair between `gh` and `pr`
    `gh pr ${pair} merge 123`, // …and between `pr` and `merge`
    `gh -R "see ${PR_URL_1006} here" pr merge 123`,
  ];
  for (const cmd of forms) {
    const full = `${cmd} --admin`;
    equal(extractMergeSelector(full).pr, 123, `the real positional is the selector: ${full}`);
    equal(extractMergeSelector(full).repo, null, `…and the leaked URL's repo is not used: ${full}`);
    // The repo CONTEXT matters as much as the number: a `source:"url"` here read the
    // evidence/registry record of a repo gh is not merging into.
    ok(resolveRepoContext(full, null).source !== "url",
      `…and the URL is not the repo source either: ${full}`);
  }
  // The pre-verb spelling must STILL be found (this is what `stripRepoArgs` normalised for;
  // a leaked tail used to hide the verb and over-block).
  equal(extractMergeSelector(`gh -R owner/repo pr merge 123 --admin`).pr, 123,
    "a plain pre-verb repo pair still resolves");
  equal(extractMergeSelector(`gh --repo=owner/repo pr merge 123 --admin`).pr, 123,
    "…including the =-joined spelling");
  equal(extractMergeSelector(`gh -Rowner/repo pr merge 123 --admin`).pr, 123,
    "…and the attached spelling");
  equal(extractMergeSelector(`gh pr merge -R owner/repo 123 --admin`).pr, 123,
    "…and a post-verb one");
});

test("extractMergeSelector: the verb regex stays LINEAR on a crafted command (ReDoS guard)", () => {
  // The first cut of MERGE_VERB_RE used an ambiguous REPO_PAIR (`=\S+` and `\S*` both
  // match `=a`, and `\S*` matches the EMPTY string) under an unbounded repetition, so a failing
  // tail enumerated 2^k splits. Measured on that form: 80 ms at 20 `--repo=` tokens,
  // 1.3 s at 26, 5.2 s at 28, 20.8 s at 30, and >400 s (timed out) at 34. This function
  // runs on EVERY git-shaped bash call, so that is a denial of service in the gate
  // itself. The alternatives are now disjoint (`=`, whitespace, neither). The bound is
  // deliberately loose so a loaded machine cannot make it flaky, while still catching a
  // return of the exponential (which costs seconds at these sizes).
  for (const k of [40, 120]) {
    const cmd = `git commit -m x && gh ${"--repo=a ".repeat(k)}z`;
    const t0 = Date.now();
    equal(extractMergeSelector(cmd).pr, null, `a ${k}-pair command resolves no PR`);
    ok(Date.now() - t0 < 2000, `a ${k}-pair command finishes fast (${Date.now() - t0} ms)`);
  }
});

test("extractMergeSelector: a QUOTED verb is not this command's verb", () => {
  // A text search on the raw command matched `gh pr merge` inside a quoted argument and
  // attributed that URL's repo to a command that is not a merge at all (fresh review,
  // P2). The verb must start OUTSIDE quotes — the same quote model as everywhere else.
  const q = `gh pr view "gh pr merge ${PR_URL_1006} --admin"`;
  equal(extractMergeSelector(q).pr, null, "a verb inside a quoted argument does not resolve");
  equal(extractMergeSelector(q).repo, null, "…and its URL does not leak a repo");
  ok(resolveRepoContext(q, null).source !== "url", "…and it is not the repo source");
});

test("extractMergeSelector: a bare number must round-trip, or the two layers disagree", () => {
  // The shim forwards a bare positional to gh as the LITERAL digits. `Number()` rounds
  // above 2^53 and normalises a leading zero, so those make the scanner name a
  // DIFFERENT PR than the shim — the divergence the URL-digits rule already refuses.
  for (const bad of ["9007199254740993", "01006", "0001", "99999999999999999", "0"]) {
    equal(extractMergeSelector(`gh pr merge ${bad} --admin`).pr, null,
      `refused (cannot round-trip): ${bad}`);
  }
  equal(extractMergeSelector("gh pr merge 123 --admin").pr, 123,
    "an ordinary number still resolves (this guard is not an over-block)");
});

test("resolveRepoContext: a compound command does not lend the FIRST verb's URL repo to the SECOND", () => {
  // `extractPrNumber` takes the FIRST unquoted `gh pr merge` (a non-global
  // `.match`), matching `extractMergeSelector`'s first verb — no longer the
  // "counts PER VERB / takes the LAST" behaviour this comment used to describe.
  // (Spelling corrected in test-review cycle 2: the module resolves the FIRST
  // verb, and the number/repo must come from the SAME verb.) Attributing the first verb's URL repo to the
  // second verb's number read another repo's evidence for that number (fresh review, P2).
  const cmd = `gh pr merge ${PR_URL_1006}; gh pr merge 123`;
  equal(extractMergeSelector(cmd).repo, "daniel-ospina/agent-infra",
    "the selector still reports the first verb's URL repo (unchanged)");
  ok(resolveRepoContext(cmd, null).source !== "url",
    "…but a COMPOUND command may not take the URL repo for its gate lookup");
  // The single-verb form keeps the URL repo — this guard must not disable the feature.
  equal(resolveRepoContext(`gh pr merge ${PR_URL_1006} --admin`, null).source, "url",
    "a single-verb URL merge still takes the URL's repo");
});

test("resolveRepoContext: a QUOTED verb in an assignment does not hide the real URL repo", () => {
  // Re-review P2 on the F4 fix: `countMergeVerbs` counts a quoted mention conservatively
  // (by design, for the admin compound guard), so using it for repo attribution discarded
  // the URL repo for a LEGITIMATE single merge — and `extractPrNumber` read the quoted
  // mention as the gated PR (the quoted-verb defect again). Both are now precise: the
  // count uses the quote-aware verb matcher, and the number regex masks quoted regions.
  const cmd = `x="say gh pr merge 1"; gh pr merge ${PR_URL_1006} --admin`;
  equal(extractMergePrNumber(cmd), 1006, "the real merge is the URL's PR");
  equal(resolveRepoContext(cmd, null).source, "url",
    "…and the URL's repo is kept (a conservative verb count would drop it)");
  // The NUMBER must also come from the real verb: this is the wrong-PR evidence read the
  // reviewer flagged, fixed by making `extractPrNumber` see only UNQUOTED verbs.
  equal(extractPrNumber(cmd), null, "a quoted mention is not this command's PR number");
  equal(extractPrNumber(`gh pr merge --body "see gh pr merge 999" 138 --admin`), null,
    "…nor does a mention in a flag value shadow the positional (gh merges 138)");
  equal(extractMergePrNumber(`gh pr merge --body "see gh pr merge 999" 138 --admin`), 138,
    "…the quote-aware extractor still finds the real positional");
  equal(extractPrNumber('git commit -m "see gh pr merge 138"'), null,
    "…and a mention in a commit message does not drive the gate");
  // Unchanged behaviour, so the masking cannot silently disable the extractor.
  equal(extractPrNumber("gh pr merge 138 --repo owner/repo"), 138, "a plain command still parses");
  // PRE-EXISTING, NOT caused by masking: a quoted POSITIONAL was already null (the regex
  // needs bare digits), and both extractors refuse it, so the registry gate is skipped for
  // that spelling. The dequote fix and this hole are filed as a follow-up (#1021).
  equal(extractPrNumber('gh pr merge "138"'), null,
    "a quoted positional yields no number (pre-existing; the registry gate is skipped)");
  // A quote-SPLICED token is a FRAGMENT: bash turns `"1"38` into `138`, so the digits the
  // mask leaves visible are not the argument. Refused rather than guessed (round-4 review).
  equal(extractPrNumber('gh pr merge "1"38'), null, "a quote-spliced token is refused, not guessed");
  equal(extractPrNumber('gh pr merge 1"38"'), null, "…in either splice direction");
});

test("withGhShim (#984): the argv-level gh shim is put on PATH for every bash call", () => {
  const ORIG = "gh pr merge 123 --admin";
  const shimmed = withGhShim(ORIG, "/repo/scripts/gh-shim");
  ok(shimmed !== null, "a resolved shim dir yields a patched command");
  // Its OWN LINE: a `&&` prefix would change the command's exit status, which the
  // harness reports back to the agent.
  equal((shimmed as string).split("\n").length, 2, "the prefix is one line plus the command");
  ok((shimmed as string).endsWith(ORIG), "the caller's command is preserved verbatim");
  ok((shimmed as string).startsWith('export PATH="/repo/scripts/gh-shim":"$PATH"'), "PATH is prepended, quoted");
  equal(withGhShim(ORIG, null), null, "no shim installed → nothing injected (never a broken PATH)");
  // The kill switch: this touches EVERY bash call, so it must be switchable.
  const prev = process.env.AGENT_GH_SHIM;
  process.env.AGENT_GH_SHIM = "0";
  equal(withGhShim(ORIG, "/repo/scripts/gh-shim"), null, "AGENT_GH_SHIM=0 disables the layer");
  if (prev === undefined) delete process.env.AGENT_GH_SHIM;
  else process.env.AGENT_GH_SHIM = prev;
  equal(withGhShim("true", "/a b/gh-shim"), 'export PATH="/a b/gh-shim":"$PATH"\ntrue',
    "a shim path containing a space survives quoting");
});

test("withGhShim: the injected prefix must NOT make a benign command look like a git op", () => {
  // The prefix names the shim, so scanning the MUTATED text would hand the gates a
  // `gh` word the caller never wrote. The handler keeps the gates on the caller's
  // text for exactly this reason; this asserts the hazard is real, so a refactor
  // that starts scanning the patched string has a failing test to hit.
  const benign = "echo hello";
  equal(isAdminMergeCommand(benign), false, "the benign command is not an admin merge");
  const patched = withGhShim(benign, "/repo/scripts/gh-shim") as string;
  equal(isAdminMergeCommand(patched), false, "the prefix alone is not an admin merge");
  equal(isGitOp(patched), isGitOp(benign), "and the prefix does not fabricate a git op");
  // WHAT IS ACTUALLY INJECTED must be free of gate-relevant words. Other extensions
  // read the same mutated `event.input.command` AFTER this handler, so injecting the
  // CHECKOUT's path leaks the branch name (`…/930-admin-merge-rail/scripts/gh-shim`)
  // into every bash command — and `admin` there flips THEIR gates: with such a path
  // `isGitOp(patched)` is TRUE for a command that is not a git op (VGATE #984). The
  // synthetic path above cannot catch that, so assert against the real one.
  ok(!/admin/i.test(NEUTRAL_GH_SHIM_DIR),
    `the neutral shim dir carries no gate word (got ${NEUTRAL_GH_SHIM_DIR})`);
  const realPatch = withGhShim(benign, NEUTRAL_GH_SHIM_DIR) as string;
  equal(isGitOp(realPatch), isGitOp(benign), "the REAL injected prefix does not fabricate a git op");
  equal(isAdminMergeCommand(realPatch), isAdminMergeCommand(benign), "…nor an admin merge");
});

test("materializeGhShim: the shim is linked at a neutral path, not the checkout's", () => {
  const resolved = resolveGhShimDir();
  ok(resolved !== null, "a source shim resolves in this repo");
  equal(materializeGhShim(null), null, "no source → nothing materialized (never an empty PATH entry)");
  const neutral = materializeGhShim(resolved);
  equal(neutral, NEUTRAL_GH_SHIM_DIR, "materializes into the neutral directory");
  ok(neutral !== null && !/admin/i.test(neutral), "…whose path has no gate word");
  equal(materializeGhShim(resolved), neutral, "idempotent — a second call is a no-op");
});

test("resolveGhShimDir: resolves this checkout's shim, and an unusable override falls back", () => {
  const dir = resolveGhShimDir();
  ok(dir !== null, "the repo's scripts/gh-shim is found from the extension's own location");
  ok((dir as string).endsWith("gh-shim"), `resolved to a gh-shim dir (got ${dir})`);
  process.env.AGENT_GH_SHIM_DIR = "/nonexistent/shim";
  const fallback = resolveGhShimDir();
  ok(fallback !== null && fallback !== "/nonexistent/shim",
    "an unusable override FALLS BACK rather than silently disabling the layer");
  delete process.env.AGENT_GH_SHIM_DIR;
});

test("evidenceBodyIsCertifying: a marker alone is a vacuous pass", () => {
  const MARK = "a".repeat(40);
  const good = "<!-- admin-merge-safety: " + MARK + " -->\nPR head: " + MARK +
    "\nmain compared (union of 10 runs of python-ci.yml): s1:1,s2:2\nPR failing: 0 | main failing: 3 | unique to this PR: 0\n";
  ok(evidenceBodyIsCertifying(good, MARK), "full evidence certifies (lane-qualified provenance accepted)");
  ok(evidenceBodyIsCertifying(good.replace(" of python-ci.yml", ""), MARK),
    "lane-less provenance from an older evidence format still certifies");
  ok(!evidenceBodyIsCertifying("<!-- admin-merge-safety: " + MARK + " -->", MARK),
    "marker only (empty/unparsed set) does NOT certify");
  ok(!evidenceBodyIsCertifying(good.replace("unique to this PR: 0", "unique to this PR: 1"), MARK),
    "a non-zero unique count never certifies");
  ok(!evidenceBodyIsCertifying(good.replace("main compared (union of 10 runs of python-ci.yml): s1:1,s2:2\n", ""), MARK),
    "missing main provenance does NOT certify");
  // The rail prints the runs that ACTUALLY CONTRIBUTED to the union, so a one-run
  // baseline reads "1 run" (singular) and a lane whose runs were all green reads
  // "0 runs". Both must certify: if this regex tightened to plural-only, the
  // rail's OWN evidence would stop certifying and every merge would be blocked
  // with no way through — an over-blocking gate is a broken gate too (#1003).
  ok(evidenceBodyIsCertifying(good.replace("union of 10 runs", "union of 1 run"), MARK),
    "the singular 'union of 1 run' certifies (the rail emits it for a one-run baseline)");
  ok(evidenceBodyIsCertifying(good.replace("union of 10 runs", "union of 0 runs"), MARK),
    "the zero 'union of 0 runs' certifies (a lane whose runs all passed)");
  ok(!evidenceBodyIsCertifying(good.replace("union of 10 runs", "union of 1 banana"), MARK),
    "a malformed union count does NOT certify");
  ok(!evidenceBodyIsCertifying(good.replace("PR failing: 0 | main failing: 3", "PR failing: | main failing: "), MARK),
    "missing counts do NOT certify");
  // The forgery class the review said was NOT closed: the body's `PR head:` must
  // name the revision the marker names, so a valid marker pasted onto an
  // unrelated (or hand-typed) body cannot certify.
  ok(!evidenceBodyIsCertifying(good.replace("PR head: " + MARK, "PR head: " + "c".repeat(40)), MARK),
    "body `PR head:` disagreeing with the marker does NOT certify");
  ok(!evidenceBodyIsCertifying(good.replace("PR head:", "PR sha:"), MARK),
    "a body with no `PR head:` line at all does NOT certify");
  // Prefix tolerance must hold in BOTH directions. Until review cycle 2 the code
  // was `marker.length >= 40 ? bodyHead === marker : …`, so a FULL marker with a
  // SHORT `PR head:` returned false while the reverse returned true — the comment
  // claimed a symmetry the code did not have. This test previously exercised only
  // the marker-shortened direction (a `String.replace` of the first occurrence,
  // which is the marker comment, not the `PR head:` line).
  ok(evidenceBodyIsCertifying(good.replace(MARK, MARK.slice(0, 12)), MARK),
    "a short SHA in the MARKER line names the same revision (prefix-tolerant)");
  ok(evidenceBodyIsCertifying(good.split("PR head: " + MARK).join("PR head: " + MARK.slice(0, 12)), MARK),
    "a short SHA in the body's `PR head:` names the same revision (the asymmetric direction)");
  // A DIFFERENT revision must still fail, in both directions: tolerance is prefix
  // matching, not "any short sha matches".
  ok(!evidenceBodyIsCertifying(good.split("PR head: " + MARK).join("PR head: " + "d".repeat(12)), MARK),
    "a short SHA naming a DIFFERENT revision does NOT certify");
});

test("evaluateAdminMergeGate: pure decisions", () => {
  const head = "b".repeat(40);
  const commented = (sha: string, body: string) => [body.split("<SHA>").join(sha)];
  const ev = "<!-- admin-merge-safety: <SHA> -->\nPR head: <SHA>\nmain compared (union of 10 runs): s1:1\nPR failing: 1 | main failing: 1 | unique to this PR: 0";
  equal(evaluateAdminMergeGate(null, head, [], false).status, "block", "no PR number → block (fail closed)");
  equal(evaluateAdminMergeGate(1, null, [], false).status, "block", "no head → block");
  equal(evaluateAdminMergeGate(1, head, null, false).status, "block", "unreadable comments → block (fail closed)");
  equal(evaluateAdminMergeGate(1, head, commented("c".repeat(40), ev), false).status, "block", "stale evidence (head X, now Y) → block");
  equal(evaluateAdminMergeGate(1, head, ["<!-- admin-merge-safety: " + head + " -->"], false).status, "block", "vacuous marker → block");
  equal(evaluateAdminMergeGate(1, head, commented(head, ev), false).status, "allow", "head-bound non-vacuous evidence → allow");
  // A marker bound to the current head, pasted onto a body that names a DIFFERENT
  // revision: refused (the forgery case the review found open).
  equal(evaluateAdminMergeGate(1, head, [ev.split("<SHA>").join(head)
    .replace("PR head: " + head, "PR head: " + "d".repeat(40))], false).status, "block",
    "evidence body naming another revision → block");
  equal(evaluateAdminMergeGate(1, head, commented(head, ev.replace(" of python-ci.yml", "")), false).status,
    "allow", "lane-less provenance (older format) still allowed");
  equal(evaluateAdminMergeGate(null, null, null, true).status, "allow", "override hatch allows (audited)");
});

// ── #930 factory-level: the actual tool_call refusal ───────────────────────

const PR_ADMIN = 99900010;
function adminGh(head: string, comments: string[] | null, failComments = false) {
  return (cmd: string) => {
    if (cmd.includes("--json comments")) {
      if (failComments) throw ghError("simulated gh failure");
      return JSON.stringify(comments ?? []);
    }
    if (cmd.includes("headRefOid")) return head;
    throw ghError(`unexpected gh call: ${cmd}`);
  };
}
function evidenceBody(sha: string, counts = "PR failing: 1 | main failing: 1 | unique to this PR: 0"): string {
  return `<!-- admin-merge-safety: ${sha} -->\nPR head: ${sha}\nmain compared (union of 10 runs): s1:1,s2:2\n${counts}\n<details>raw comm -23 output</details>\nFlake classification: none needed`;
}

testAsync("#930 compound: a second merge in the same command is BLOCKED, not judged on the first PR", async () => {
  // Cycle-2 review P0: `countMergeVerbs` used a SECOND regex instead of the gate's
  // own recognizer, so a wrapped/quoted second verb counted as one. The command was
  // then judged against PR 111's evidence and merged 999 with none. Every spelling
  // below reached `gh pr merge 999 --admin` while the gate inspected 111.
  const shapes = [
    "sh -c 'gh pr merge 999 --admin'",
    'bash -c "gh pr merge 999 --admin"',
    "eval 'gh pr merge 999 --admin'",
    '"gh" pr merge 999 --admin',
    "'gh' pr merge 999 --admin",
    "`gh pr merge 999 --admin`",
    "gh pr merge 999 --admin",
    // Cycle-3 review P0: a construct-SPLICED verb word dequotes to a residue, so an
    // exact `dequote(tok) === "merge"` test missed it and the compound guard was
    // skipped — the second PR merged unevidenced.
    "gh pr $'merge' 999 --admin",
    "gh p$'r' merge 999 --admin",
    "gh pr ${X}merge 999 --admin",
    "gh ${X}pr merge 999 --admin",
  ];
  const seps = ["; ", " && ", " || ", " | ", " & ", "\n", "("];
  for (const sep of seps) {
    for (const second of shapes) {
      const command = `gh pr merge 111 --admin${sep}${second}`;
      await withTempHome(async () => {
        const prevMode = process.env.PI_MODE;
        process.env.PI_MODE = "print";
        // PR 111 carries VALID head-bound evidence, so the first merge alone would
        // legitimately pass — the block must come from the compound rule.
        _setRunGhOverride(adminGh("d".repeat(40), [evidenceBody("d".repeat(40))]));
        try {
          const { pi, fire } = mockPi();
          (reviewEnforcerFactory as any)(pi);
          await fire("session_start");
          const res = await fire("tool_call", { toolName: "bash", input: { command } });
          ok(res && res.block === true, `a compound command must block: ${JSON.stringify(command)}`);
          const blocked = tempAuditLines().filter((l) => l.event === "merge_gate_block");
          equal(blocked.length, 1, `exactly one audit entry for ${JSON.stringify(command)}`);
          equal(blocked[0].reason, "admin_merge_compound_command");
        } finally {
          _setRunGhOverride(null);
          if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
        }
      });
    }
  }
});

testAsync("#930 refusal: a single evidenced merge is NOT blocked by the compound rule", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const head = "d".repeat(40);
    _setRunGhOverride(adminGh(head, [evidenceBody(head)]));
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${PR_ADMIN} --admin` } });
      // It may still block for the UNRELATED reason that no review record exists in
      // this temp home — what must NOT happen is the compound rule firing on a
      // single merge. Assert the property, not the absence of any block.
      ok(
        String(res?.reason ?? "").indexOf("more than one") === -1,
        `a single merge must not be blocked by the compound rule: ${String(res?.reason).slice(0, 120)}`
      );
      equal(
        tempAuditLines().filter((l) => l.reason === "admin_merge_compound_command").length,
        0,
        "no compound-command audit row for a single merge"
      );
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

for (const [label, command] of [
  ["a plain un-evidenced admin merge", `gh pr merge ${PR_ADMIN} --admin`],
  ["--admin before the PR number", `gh pr merge --admin ${PR_ADMIN}`],
  ["--admin after the PR number", `gh pr merge ${PR_ADMIN} --admin`],
  ["--admin=true before the PR number", `gh pr merge --admin=true ${PR_ADMIN}`],
  ["--admin with no PR number at all", "gh pr merge --admin"],
  // The bash token-splicing family in the COMMAND SHAPE: bash re-joins these, so
  // they must reach the admin gate like any other admin merge. A raw-only guard
  // returned early and skipped the gate entirely (VGATE round 3).
  ["a quote-split `merge` verb", `gh pr "merge" ${PR_ADMIN} --admin=true`],
  ["a backslash-split flag name", `gh pr merge ${PR_ADMIN} --ad\\min=true`],
  ["an ANSI-C quoted flag", `gh pr merge ${PR_ADMIN} $'--admin'`],
  // VGATE round 6: the splice on the `gh`/`pr` words, which skipped BOTH gates.
  ["a splice on the `gh` word", `$'gh' pr merge ${PR_ADMIN} --admin=true`],
  ["a splice on the `pr` word", `gh $'pr' merge ${PR_ADMIN} --admin=true`],
  ["a substitution glued to the verb", `gh pr merge$(printf '%s' '') ${PR_ADMIN} --admin=true`],
  // VGATE round 9: `isGitOp` said yes while the CALLER's separate predicate said
  // no, so this was ALLOWED with no evidence. They now share one function.
  ["a splice mid-way through the `pr` word", `gh p$'r' merge ${PR_ADMIN} --admin=true`],
  ["a `$VAR`-supplied `pr` word", `V=pr; gh $V merge ${PR_ADMIN} --admin=true`],
  // VGATE round 10: a quote/backslash/continuation-spliced COMMAND NAME. bash
  // re-joins these to `gh`; a raw-string word test missed them entirely.
  ["a quote-split `gh` command name", `g"h" pr merge ${PR_ADMIN} --admin=true`],
  ["an empty-quote-prefixed `gh` name", `''gh pr merge ${PR_ADMIN} --admin=true`],
  ["a backslash-escaped `gh` name", `\\gh pr merge ${PR_ADMIN} --admin=true`],
  ["a line-continuation inside the `gh` name", "g\\\nh pr merge " + PR_ADMIN + " --admin=true"],
  // VGATE round 11: a FULLY quoted command name is executable, not a mention. The
  // previous rule admitted `''gh` and `g"h"` while excluding `"gh"` — the same
  // family, inconsistently. Command position now decides, not "any unquoted char".
  ["a fully-quoted `gh` command name", `"gh" pr merge ${PR_ADMIN} --admin=true`],
  ["a single-quoted `gh` command name", `'gh' pr merge ${PR_ADMIN} --admin=true`],
  ["a fully-quoted `gh` after a separator", `true && "gh" pr merge ${PR_ADMIN} --admin=true`],
  // Fresh independent review, P0-1: gh's GLOBAL `-R/--repo` may sit between
  // `gh` and `pr` — the most realistic spelling for a multi-repo operator, and
  // one this rail's own script advertises. Both gates skipped it entirely.
  ["gh's global -R flag before the verb", `gh -R owner/repo pr merge ${PR_ADMIN} --admin`],
  ["gh's global --repo flag before the verb", `gh --repo owner/repo pr merge ${PR_ADMIN} --admin`],
  ["gh's --repo= form before the verb", `gh --repo=owner/repo pr merge ${PR_ADMIN} --admin`],
  // Fresh review P0-2: a separator GLUED to the `gh` word leaves no whitespace
  // for a `(^|\s)gh` anchor, and splitting only on whitespace left `;gh` as a
  // token that never equals `gh`.
  ["a separator glued to the `gh` word", `(gh pr merge ${PR_ADMIN} --admin)`],
  ["a semicolon with no space", `true;gh pr merge ${PR_ADMIN} --admin`],
  ["a `sh -c` wrapper", `sh -c 'gh pr merge ${PR_ADMIN} --admin'`],
  ["a `bash -lc` wrapper", `bash -lc 'gh pr merge ${PR_ADMIN} --admin'`],
  ["an `eval` wrapper", `eval 'gh pr merge ${PR_ADMIN} --admin'`],
  // Cycle-3 review P0: gh's short repo flag may take an ATTACHED value
  // (`-Rowner/repo`), a valid pflag spelling that skipped both gates.
  ["gh's -R with an attached value", `gh -Rowner/repo pr merge ${PR_ADMIN} --admin`],
  ["gh's -R attached after another word", `true; gh -Rowner/repo pr merge ${PR_ADMIN} --admin`],
  // Cycle-3 review: a `$VAR` may SUPPLY the flag, so no text scan can see the
  // word `admin`. Fails closed (documented over-block for an unquoted `$PR`).
  ["a `$VAR`-supplied admin flag", `V=--admin; gh pr merge ${PR_ADMIN} $V`],
  // Cycle-4 review P0-1: a redirection / assignment / reserved-word PREFIX is a
  // command position; enumerating only introducers and `-c` let these skip both
  // gates when the command name was also quoted.
  ["a redirection before a quoted `gh`", `2>/dev/null "gh" pr merge ${PR_ADMIN} --admin`],
  ["an assignment prefix before a quoted `gh`", `FOO=bar "gh" pr merge ${PR_ADMIN} --admin`],
  // Cycle-4 review P0-2: `--` may separate an introducer's option from its script.
  ["`sh -c --` with the command quoted", `sh -c -- 'gh pr merge ${PR_ADMIN} --admin'`],
  // Cycle-4 review P0-3: the flag may be SUPPLIED by a quoted substitution, whose
  // `$` follows a `"` — a whitespace-anchored test missed it entirely.
  ["a quoted substitution supplying the flag", `gh pr merge ${PR_ADMIN} "$(printf '\\x2d\\x2d\\x61dmin')"`],
  // Cycle-5 review P0: a construct-ASSEMBLED flag in a BACKTICK substitution, in the
  // POSITION slot, or with a splice on the VERB itself — hex escapes dodge the
  // literal word `admin`, so no literal rule can fire.
  ["a backtick substitution supplying the flag", "gh pr merge " + PR_ADMIN + " `printf '\\x2d\\x2d\\x61dmin'`"],
  ["a substitution in the POSITION slot", "gh pr merge $(printf '\\x2d\\x2d\\x61dmin') " + PR_ADMIN],
  ["a variable in the position slot with a later number", "V=$(printf '\\x2d\\x2d\\x61dmin'); gh pr merge $V " + PR_ADMIN],
  ["a backtick-spliced `pr` word", "V=$(printf x); gh p`printf r` merge " + PR_ADMIN + " $V"],
  ["a backtick-spliced `merge` verb", "V=$(printf x); gh pr m`printf erge` " + PR_ADMIN + " $V"],
] as const) {
  testAsync(`#930 refusal: ${label} without evidence is BLOCKED`, async () => {
    await withTempHome(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      _setRunGhOverride(adminGh("d".repeat(40), []));
      try {
        const { pi, fire } = mockPi();
        (reviewEnforcerFactory as any)(pi);
        await fire("session_start");
        const res = await fire("tool_call", { toolName: "bash", input: { command } });
        ok(res && res.block === true, `expected a block for: ${command}`);
        ok(/admin-merge/.test(String(res.reason)), `block reason must name the admin-merge gate: ${String(res.reason).slice(0, 120)}`);
        const blocked = tempAuditLines().filter((l) => l.event === "merge_gate_block");
        equal(blocked.length, 1, "exactly one audit entry");
        equal(blocked[0].reason, "admin_merge_no_evidence");
      } finally {
        _setRunGhOverride(null);
        if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      }
    });
  });
}

testAsync("#930 stale evidence: a marker minted at an OLD head does not unlock the new head", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const head = "e".repeat(40);
    _setRunGhOverride(adminGh(head, [evidenceBody("f".repeat(40))]));
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${PR_ADMIN} --admin` } });
      ok(res && res.block === true, "stale evidence must block");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("#930 vacuity: a marker at the current head with no counts is BLOCKED", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const head = "1".repeat(40);
    _setRunGhOverride(adminGh(head, [`<!-- admin-merge-safety: ${head} -->`]));
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${PR_ADMIN} --admin` } });
      ok(res && res.block === true, "vacuous evidence must block");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("#930 valid head-bound evidence + clean review → allowed; the registry gate still runs", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const head = "2".repeat(40);
    // The registry gate must ALSO pass — admin evidence does not replace the
    // review record. A repo-less legacy record cannot be foreign.
    writeReviewFile(resolvePath(os.homedir(), ".pi", "agent", "reviews", `${PR_ADMIN}.json`),
      { pr: PR_ADMIN, head_sha: head, verdict: "clean" });
    _setRunGhOverride(adminGh(head, [evidenceBody(head)]));
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      await fire("tool_result", { toolName: "task" });
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${PR_ADMIN} --admin --squash` } });
      equal(res, undefined, "evidence + clean review at the head → merge allowed");
      const passes = tempAuditLines().filter((l) => l.event === "merge_gate_pass");
      ok(passes.some((l) => l.reason === "admin_merge_evidence_ok"), "the admin evidence verification is audited");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("#930 override hatch: AGENT_ADMIN_MERGE_OVERRIDE=1 allows a raw --admin (audited)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const head = "3".repeat(40);
    writeReviewFile(resolvePath(os.homedir(), ".pi", "agent", "reviews", `${PR_ADMIN}.json`),
      { pr: PR_ADMIN, head_sha: head, verdict: "clean" });
    _setRunGhOverride(adminGh(head, []));
    process.env.AGENT_ADMIN_MERGE_OVERRIDE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      await fire("tool_result", { toolName: "task" });
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${PR_ADMIN} --admin` } });
      equal(res, undefined, "override allows the merge");
      const passes = tempAuditLines().filter((l) => l.event === "merge_gate_pass");
      ok(passes.some((l) => l.reason === "admin_merge_override"), "the override is audited");
    } finally {
      delete process.env.AGENT_ADMIN_MERGE_OVERRIDE;
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("#1007 scanner flow: a PR URL resolves through the admin gate — and an UNEVIDENCED one is still blocked", async () => {
  // The over-block lived in TWO layers. This drives the extension end-to-end, so it
  // fails if the scanner refuses the URL even though the shim would have resolved it.
  // Both directions are asserted on the SAME command: the URL form must reach the
  // evidence decision (a), and must not weaken it (b).
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const head = "7".repeat(40);
    const url = `https://github.com/daniel-ospina/agent-infra/pull/${PR_ADMIN}`;
    // A repo-less legacy record: the registry gate finds it even under the URL's repo.
    writeReviewFile(resolvePath(os.homedir(), ".pi", "agent", "reviews", `${PR_ADMIN}.json`),
      { pr: PR_ADMIN, head_sha: head, verdict: "clean" });
    try {
      const run = async () => {
        const { pi, fire } = mockPi();
        (reviewEnforcerFactory as any)(pi);
        await fire("session_start");
        await fire("tool_result", { toolName: "task" });
        return fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${url} --admin` } });
      };
      // (a) head-bound evidence → ALLOWED. Before #1007 this was blocked with
      // "carries no resolvable PR number".
      _setRunGhOverride(adminGh(head, [evidenceBody(head)]));
      equal(await run(), undefined, "URL + head-bound evidence → allowed (the over-block is gone)");
      // (b) the SAME URL with NO evidence → still BLOCKED, by the admin-merge gate.
      _setRunGhOverride(adminGh(head, []));
      const blocked = await run();
      ok(blocked && blocked.block === true, "URL without evidence → still BLOCKED");
      ok(/admin-merge/.test(String(blocked && blocked.reason)),
        "…and it is the EVIDENCE gate that blocked, not a parse failure");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("#930 --admin=false is not a bypass — the admin gate does not fire (registry gate decides)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    _setRunGhOverride(adminGh("4".repeat(40), []));
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", {
        toolName: "bash",
        input: { command: `gh pr merge ${PR_ADMIN} --admin=false` },
      });
      ok(res && res.block === true, "no review record → the registry gate blocks");
      const blocked = tempAuditLines().filter((l) => l.event === "merge_gate_block");
      equal(blocked[0].reason, "no_review_record", "the ADMIN gate must not fire for --admin=false");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

// ── Summary ───────────────────────────────────────────
// Run the async factory tests strictly sequentially (they mutate process.env).
for (const run of pending) await run();

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
