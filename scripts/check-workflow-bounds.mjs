#!/usr/bin/env node
/**
 * check-workflow-bounds — EVERY JOB in EVERY workflow declares a time bound.
 *
 * ── THE DEFECT THIS PINS (agent-infra#2055) ──────────────────────────────────────────────────────
 * `grep -c timeout-minutes .github/workflows/*.yml` returned 0 for most of this tree, and a job with
 * no bound is a job that can hang for as long as GitHub will let it. Measured: PR #2168's
 * `bash-suites` step sat `in_progress` for >55 min with every peer job long finished, and the landing
 * rail refused to classify ANYTHING — "a running job is not a failure, and this is NOT a stall claim"
 * — so the PR was unlandable for as long as one job failed to reach a terminal conclusion. A bound
 * cannot make the work finish; it makes the job END, which is what turns an indefinite queue hold
 * into a named, failing check.
 *
 * ── WHY THIS IS A NODE READ, NOT A GREP (the #666 / #675 lesson) ─────────────────────────────────
 * The question is "does job J have its own `timeout-minutes`?", which is a question about PARSED
 * STRUCTURE. Text matching answers a different one ("does the string appear somewhere in the file")
 * and three generations of text-matching guards in this repo were defeated by YAML's own syntax:
 * quoted keys, block scalars, a decoy `timeout-minutes:` inside a `run: |` body, and a STEP's bound
 * standing in for a JOB's. So this reads `scripts/workflow-yaml.mjs` (the structural parser #675
 * landed) and asks the parsed node. A decoy inside a scalar is not a node and cannot satisfy it, and
 * a step's bound lives under `steps[i]`, never on the job.
 *
 * ── WHAT IT ASSERTS, EXACTLY ─────────────────────────────────────────────────────────────────────
 *   (a) every workflow file parses, and has a `jobs` mapping with at least one job;
 *   (b) every job is BOUNDED, in one of two shapes — and the difference is not cosmetic:
 *         • it carries its own `timeout-minutes` (a JOB bound), or
 *         • EVERY one of its steps carries one (a STEP bound), which bounds the job's total by
 *           their sum.
 *       A STEP bound is the STRONGER of the two: its trip is `failure`, which the rail reds. A JOB
 *       bound's trip is `cancelled`, which the rail reads NON-RED — it ends the hold and names the
 *       job, but it does not turn a hang into a red. `ci.yml`'s `verify` is the job that only has
 *       the step shape (66 steps, Σ 326). ⛔ ITS ORIGINAL JUSTIFICATION NO LONGER HOLDS and is corrected
 *       here rather than left standing (review finding, P2): the first draft argued a 66-step job could
 *       not satisfy the lane guard's “job > Σ steps” under the 360-minute ceiling — true at Σ 381, FALSE
 *       at Σ 326, where a job bound in 327..359 would satisfy it. The shape is kept deliberately because
 *       it is the one that keeps the ONLY trip RED: with `J > Σ` a job bound could never fire anyway, so
 *       it would buy no protection and would relabel the job from "step-bounded" to "job-bounded",
 *       which is exactly the weaker shape this guard exists to discourage.
 *       A reusable-workflow CALL job (`jobs.<id>.uses`) is the third case — see (d);
 *       ⛔ AND A BOUND'S STEP BUDGET MUST BE REACHABLE (added at review, P2, measured). A job with
 *       no `timeout-minutes` still has one: GitHub's implicit 360-minute ceiling — and its trip is
 *       `cancelled`, NON-RED to the rail. So if the step bounds SUM to 360 or more, the platform's
 *       non-red cancel arrives before the last step bounds do, and those bounds are decorative. A job
 *       bounded only by its steps is therefore required to have Σ < 360. (This was real: `ci.yml`'s
 *       `verify` shipped 65 step bounds summing to 381 min in the first draft of this change.)
 *       ⛔ THE SAME RULE APPLIES WHEN THE JOB HAS A BOUND OF ITS OWN (added at review, P2, measured).
 *       A job bound J is itself a cancelling ceiling, so a step bound lying at or beyond J can never
 *       fire — and J's trip is `cancelled`/NON-RED, so the non-red conclusion PRE-EMPTS the red step
 *       that actually hung, which is the same false pass in the other direction. Where EVERY step
 *       carries a finite numeric bound, Σ must therefore be strictly BELOW `min(J, 360)` (an inert
 *       J > 360 cannot fire at all, so 360 is what covers the job). Nothing is blocked by this: a job
 *       that declares a bound may always raise it (to ≤ 359) until it sits above Σ — EXCEPT where Σ
 *       itself is ≥ 360, when no such bound exists and the tail step bounds are what must come down (the
 *       violation says which of the two applies).
 *       ⛔ AND A SUM THIS GUARD CANNOT COMPUTE IS REPORTED, NEVER SILENTLY CERTIFIED (added at review,
 *       P2, measured). `${{ … }}` is an accepted step bound (clause (c)), so a step-only job may carry
 *       one and Σ is then uncomputable; treating that as "nothing to check" is how the reachability
 *       rule above becomes decorative, so it is a NOTE on every run (the doctrine this file already
 *       keeps for a foreign callee). The numeric bounds are still summed, and a numeric subtotal that
 *       ALREADY reaches the ceiling is refused regardless of the expression.
 *   (c) the value is a positive integer number of minutes, or a `${{ … }}` expression (GitHub
 *       resolves `jobs.<id>.timeout-minutes` from the `github`, `needs`, `strategy`, `matrix`,
 *       `vars` and `inputs` contexts, so a reusable workflow may legitimately forward one);
 *   (d) a CALL job cannot be bounded directly: GitHub's schema for `jobs.<id>.uses` accepts only
 *       `name, uses, with, secrets, strategy, needs, if, concurrency, permissions`, and a
 *       `timeout-minutes` there is a WORKFLOW VALIDATION ERROR ("Unexpected value"), i.e. every run
 *       of the file dies. So for a call job this guard asserts the OPPOSITE (no bound may be
 *       declared) and then follows the call INTO the called file when that file is ours, requiring
 *       every job inside it to be bounded. That is what closes the hole instead of relabelling it: a
 *       caller's work is bounded by the callee's jobs, so the callee is where the bound must be.
 *       A call to a workflow that is NOT in this repo is reported as a NOTE, never silently passed —
 *       its bounds are not ours to assert, and the summary counts it so the exemption is visible.
 *
 * ⛔ WHAT IT DOES **NOT** CLAIM, STATED SO IT CANNOT BE MISREAD (#2055's own amended indicator):
 * a `jobs.<job_id>.timeout-minutes` trip is reported **`cancelled`**, and this repo's merge rail reads
 * `cancelled` as NON-RED. A job bound is therefore a RUNNER-LEAK BACKSTOP and a NAMING device, not a
 * red-producing bound. The red-producing bound is the STEP bound, which is `failure`, and the jobs
 * that run long work in this repo already carry one (#2482 sized them, #3187 pins them: `bash-suites`
 * 70 min on the shard step, `bash-suites-gate` 70, `script-validate*` on their shard steps). Where a
 * job has NO step bound, a job bound still converts "the whole queue waits forever" into "one named
 * job ends", which is strictly better than the measured 55-minute hold — the remaining false-pass
 * surface (a non-verdict scored non-red) is ONE root, tracked as #3242, and is not created here.
 *
 * ── BOTH WORKFLOW ROOTS, NOT JUST THE LIVE ONE (added at review, P2, measured) ──────────────────
 * This repo's workflow files live in TWO places: `.github/workflows/` (what GitHub runs) and
 * `templates/.github/workflows/` (the reusables consumers generate from — 5 files, 13 jobs). The
 * header above says EVERY workflow, and the template root is where one of them reaches a CONSUMER's
 * queue: `templates/…/pipeline-compliance.yml` is the consumer copy of this repo's only required
 * check. It is deliberately NOT one of the four `scripts/sync-ci-workflows.sh` materializes, so
 * `workflow-drift` byte-compares it never — a bound deleted there was previously caught by nothing at
 * all. Both roots are scanned whenever they exist; a fixture root without `templates/` simply skips
 * it, and a template job is labelled `templates/<file>::<job>` so the two roots stay distinguishable.
 * (`scripts/check-workflow-actionlint.sh` is the in-repo precedent: it lints both roots too.)
 *
 * ── WHY "job bound > sum of step bounds" IS NOT ASSERTED UNIVERSALLY ────────────────────────────
 * ⛔ THE ARITHMETIC ARGUMENT IS GONE; THE SCOPING IS WHAT REMAINS (review finding, P2). This section
 * used to argue that a 66-step job under the 360-minute ceiling would need steps averaging <5.5 min,
 * which would false-block a slow-but-healthy step. That was true of `verify`'s FIRST draft (Σ 381, above
 * the ceiling); it is FALSE of the tree this ships — `verify`'s Σ is 326, averaging 4.94 min, so a job
 * bound in 327..359 would satisfy `job > Σ steps` today. The rule stays scoped for the reason that still
 * holds: the invariant is not satisfiable IN GENERAL (a genuinely slow suite can push Σ past 359, where no
 * job bound can sit above it), and a bound that cannot be satisfied is not a bound. So the rule asserted
 * here fires only when the shape makes Σ knowable and the remedy real — EVERY step carries a bound (numeric
 * or expression; a numeric subtotal that already breaches the ceiling is refused regardless) — and its
 * remedy is always stated as one that exists. A job whose steps are not ALL bounded is covered by the
 * JOB-level NOTE instead, which names any step bound lying beyond the job bound.
 *
 * ── FAIL-CLOSED ─────────────────────────────────────────────────────────────────────────────────
 * Exit 2 (refusal) — not 0 — when the guard cannot answer: no workflow files, a file whose `jobs` is
 * not a mapping or holds no job, unparseable YAML, or a `--root` with no `.github/workflows`. A guard
 * that passes when it read nothing is the class of defect it exists to find (#637, #675 P2).
 *
 * Exit codes: 0 every job bounded (or bounded through its callee) · 1 a job has no usable bound, or a
 * call job declares one (which GitHub rejects), or a bound sits at/below the step budget it is meant
 * to pre-empt — each named with its file · 2 refusal.
 *
 * Usage:
 *   node scripts/check-workflow-bounds.mjs [--root DIR] [--list]
 *     --root DIR   audit DIR/.github/workflows AND DIR/templates/.github/workflows (when present)
 *                  instead of this repo's (fixtures, mutations)
 *     --list       print `<file>::<job>\t<bound>` for every job, then the verdict (used by the suite
 *                  to prove the parse is NON-VACUOUS — it must see the jobs it claims to check)
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseWorkflowYaml, WorkflowYamlError } from "./workflow-yaml.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * This repo's own slug. A `uses:` naming it can be resolved to a file HERE, which is what lets a
 * caller job be certified through its callee. Spelled out (not derived from git) on purpose: a guard
 * whose own subject changes with the checkout can be satisfied by moving the checkout.
 */
const SELF_SLUG = "daniel-ospina/agent-infra";

/**
 * GitHub's ceiling for `jobs.<job_id>.timeout-minutes` on a hosted runner (the default when no bound is
 * declared). A bound at or above it can never fire first, and its own trip is `cancelled` — NON-RED to
 * this repo's rail — so anything that must produce a RED has to sit strictly below it.
 */
const PLATFORM_CEILING_MIN = 360;

function parseArgs(argv) {
  const out = { root: resolve(HERE, ".."), list: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") {
      const v = argv[++i];
      if (!v) {
        process.stderr.write("check-workflow-bounds: --root needs a directory\n");
        process.exit(2);
      }
      out.root = resolve(v);
    } else if (a === "--list") {
      out.list = true;
    } else if (a === "--help" || a === "-h") {
      process.stdout.write("usage: check-workflow-bounds.mjs [--root DIR] [--list]\n");
      process.exit(0);
    } else {
      process.stderr.write(`check-workflow-bounds: unknown argument ${JSON.stringify(a)}\n`);
      process.exit(2);
    }
  }
  return out;
}

/** A bound this guard can accept: a positive integer, or an expression it cannot evaluate. */
function classifyBound(raw) {
  if (raw === undefined || raw === null) return { ok: false, why: "declares no timeout-minutes at all" };
  if (typeof raw !== "string") return { ok: false, why: `is not a scalar (${typeof raw})` };
  const v = raw.trim();
  if (v === "") return { ok: false, why: "declares timeout-minutes with an EMPTY value" };
  if (/^\$\{\{[\s\S]*\}\}$/.test(v)) return { ok: true, expression: true, value: v };
  if (!/^[0-9]+$/.test(v)) {
    return { ok: false, why: `declares a non-integer timeout-minutes (${JSON.stringify(v)})` };
  }
  if (Number(v) <= 0) {
    return { ok: false, why: `declares timeout-minutes ${v}, which is not a positive number of minutes` };
  }
  if (Number(v) > 360) {
    // Not fatal: GitHub cancels at the runner's own ceiling first, so a larger number is inert
    // rather than wrong. Reported as a NOTE so nobody believes it protects anything.
    return { ok: true, value: v, inert: true };
  }
  return { ok: true, value: v };
}

/**
 * Resolve a `uses:` value to a workflow path inside THIS repo, or null when it is not ours.
 * Accepted: `<slug>/.github/workflows/<f>@<ref>`, `<slug>/.github/workflows/<f>` (no ref), and
 * `./.github/workflows/<f>`.
 */
function resolveLocalCallee(uses) {
  // Two capture groups only: the OPTIONAL `<slug>` (absent for a `./…` call) and the path. The `./`
  // prefix is its own alternative with no capture group, so a `./` call leaves `slug` undefined.
  const m = /^(?:(?:\.\/)|([^/@\s]+\/[^/@\s]+)\/)?(\.github\/workflows\/[^@\s]+?\.ya?ml)(?:@.*)?$/.exec(
    uses.trim()
  );
  if (!m) return null;
  const [, slug, rel] = m;
  // ⛔ THE TWO FORMS MEAN DIFFERENT ROOTS once there are two (review finding, P3).
  // `<slug>/.github/workflows/<f>` names the REPO root, so a caller sitting in
  // `templates/.github/workflows/` resolves it to `.github/workflows/<f>` — not to a template sibling.
  // `./.github/workflows/<f>` is a path relative to the caller, so it stays in the caller's own root.
  // Conflating them made a template caller report a present workflow as "does not exist".
  if (slug === undefined) return { rel, rooted: false }; // `./…` — relative to the caller
  if (slug === SELF_SLUG) return { rel, rooted: true }; // `<slug>/…` — the repo root, always
  return null;
}

function main() {
  const { root, list } = parseArgs(process.argv.slice(2));

  // ── THE TWO WORKFLOW ROOTS (see the header). `.github/workflows/` is required; the template root
  // is scanned whenever it exists, so a fixture root (which has none) and a mutation copy behave as
  // before while the live tree gets both. Labels keep the roots distinguishable to the reader.
  const rootSpecs = [
    { dir: join(root, ".github", "workflows"), label: "", required: true },
    { dir: join(root, "templates", ".github", "workflows"), label: "templates/", required: false },
  ];

  /** @type {{key: string, path: string, label: string}[]} */
  const scanned = [];
  for (const spec of rootSpecs) {
    if (!spec.required && !existsSync(spec.dir)) continue;
    let entries;
    try {
      entries = readdirSync(spec.dir);
    } catch (e) {
      process.stderr.write(
        `check-workflow-bounds: ✗ REFUSING — cannot read ${spec.dir} (${e.code || e.message}).\n` +
          `   A guard that read no workflow cannot say every job is bounded; this is exit 2, not a pass.\n`
      );
      process.exit(2);
    }
    const here = entries.filter((f) => /\.ya?ml$/.test(f)).sort();
    if (here.length === 0) {
      process.stderr.write(
        `check-workflow-bounds: ✗ REFUSING — ${spec.dir} holds no .yml/.yaml file.\n` +
          `   Nothing was checked, so nothing can be certified: exit 2.\n`
      );
      process.exit(2);
    }
    for (const f of here) scanned.push({ key: spec.label + f, path: join(spec.dir, f), label: spec.label });
  }
  const byKey = new Map(scanned.map((e) => [e.key, e]));
  const files = scanned.map((e) => e.key);

  const violations = [];
  const notes = [];
  const seen = new Set();
  let jobCount = 0;
  let bounded = 0;
  let boundedBySteps = 0;
  let callers = 0;
  let viaCallee = 0;

  /** Load one workflow file's `jobs`, refusing (exit 2) rather than guessing. */
  function loadJobs(file) {
    let doc;
    try {
      doc = parseWorkflowYaml(readFileSync(byKey.get(file).path, "utf8"));
    } catch (e) {
      const kind = e instanceof WorkflowYamlError ? "unparseable by the structural reader" : "unreadable";
      process.stderr.write(
        `check-workflow-bounds: ✗ REFUSING — ${file} is ${kind}: ${e.message}\n` +
          `   Fail-closed on purpose: a workflow this guard cannot read is NOT one it may certify.\n`
      );
      process.exit(2);
    }
    const jobs = doc && doc.jobs;
    if (!jobs || typeof jobs !== "object" || Array.isArray(jobs)) {
      process.stderr.write(
        `check-workflow-bounds: ✗ REFUSING — ${file} has no \`jobs\` mapping.\n` +
          `   Either the file is not a workflow or the parser lost it; both mean "nothing was checked".\n`
      );
      process.exit(2);
    }
    const ids = Object.keys(jobs);
    if (ids.length === 0) {
      process.stderr.write(
        `check-workflow-bounds: ✗ REFUSING — ${file} declares \`jobs\` with NO jobs in it.\n` +
          `   A file with nothing to check cannot be a pass: exit 2.\n`
      );
      process.exit(2);
    }
    return jobs;
  }

  /** Certify every job in one file. `label` names the file as the reader sees it. */
  function auditFile(file, depth) {
    if (seen.has(file)) return; // a diamond, not a new hole
    seen.add(file);
    if (depth > 3) {
      process.stderr.write(
        `check-workflow-bounds: ✗ REFUSING — reusable-workflow calls nest deeper than 3 levels at ${file}.\n` +
          `   GitHub allows a chain, this guard does not follow one further; raise the bound deliberately.\n`
      );
      process.exit(2);
    }
    const jobs = loadJobs(file);
    // The root label this file came from (`""` for `.github/workflows/`, `"templates/"` otherwise), so a
    // `uses:` resolved to `.github/workflows/<f>` is followed INTO THE SAME ROOT the caller lives in.
    const label = byKey.get(file).label;
    for (const id of Object.keys(jobs)) {
      jobCount++;
      const job = jobs[id] || {};
      const where = `${file}::${id}`;

      // ── A CALLER JOB: GitHub's caller schema has no `timeout-minutes` at all ────────────────
      if (typeof job.uses === "string" && job.uses.trim() !== "") {
        callers++;
        const local = resolveLocalCallee(job.uses);
        const own = classifyBound(job["timeout-minutes"]);
        if (job["timeout-minutes"] !== undefined) {
          violations.push(
            `${where} declares timeout-minutes on a reusable-workflow CALL job — GitHub's caller schema ` +
              `(name, uses, with, secrets, strategy, needs, if, concurrency, permissions) rejects it as ` +
              `"Unexpected value", which fails EVERY run of this file. The bound belongs on the jobs inside ` +
              `${job.uses.trim()}.`
          );
          continue;
        }
        if (list) process.stdout.write(`${where}\t(call → ${job.uses.trim()})\n`);
        if (local === null) {
          notes.push(
            `${where} calls ${job.uses.trim()}, which is not a workflow in this repo — its jobs are not ` +
              `certified here (the caller schema forbids a bound, so a third-party callee's own bounds are the only ones that can exist)`
          );
          continue;
        }
        // A `./…` call stays in the caller's root; an explicit `<slug>/…` call names the repo root.
        const calleeKey = (local.rooted ? "" : label) + local.rel.replace(/^\.github\/workflows\//, "");
        if (!byKey.has(calleeKey)) {
          violations.push(
            `${where} calls ${job.uses.trim()}, resolved to ${local.rel} in THIS repo, but that file does not ` +
              `exist — the call is broken, so nothing inside it can be bounded`
          );
          continue;
        }
        viaCallee++;
        auditFile(calleeKey, depth + 1);
        continue;
      }

      // ── AN ORDINARY JOB: a JOB bound, or a bound on EVERY step ─────────────────────────────
      const steps = Array.isArray(job.steps) ? job.steps : [];
      const badSteps = [];
      for (let i = 0; i < steps.length; i++) {
        const s = steps[i];
        const sv = classifyBound(s && typeof s === "object" ? s["timeout-minutes"] : undefined);
        if (!sv.ok) {
          const what = s && typeof s === "object" ? s.name || s.uses || `step #${i + 1}` : `step #${i + 1}`;
          badSteps.push(`${what} ${sv.why}`);
        }
      }
      const verdict = classifyBound(job["timeout-minutes"]);
      if (list) {
        process.stdout.write(
          `${where}\t${verdict.value ?? (verdict.ok === false && steps.length && badSteps.length === 0 ? `(steps: ${steps.length} bounded)` : "(none)")}\n`
        );
      }
      if (verdict.ok) {
        // ⛔ AND THE STEP BUDGET MUST FIT INSIDE THE BOUND THAT CANCELS IT (review finding, P2, measured).
        // A job bound J is a cancelling ceiling, so a step bound at or beyond J can never fire — and J's
        // trip is `cancelled`/NON-RED, so the non-red conclusion pre-empts the red step that hung.
        //
        // ⛔ SCOPED TO "EVERY STEP CARRIES SOME BOUND", NOT "EVERY STEP IS NUMERIC" (review finding, P2,
        // measured). Requiring all-numeric here let ONE `${{ … }}` step bound switch the whole rule off,
        // silently — Finding A's class, on this branch. The NUMERIC subtotal is provable on its own, so
        // it is always checked; only the part that depends on the expression is downgraded to a NOTE.
        // A job with UNBOUNDED steps is out of scope entirely (the JOB-level NOTE below covers it).
        const everyStepBounded = steps.length > 0 && badSteps.length === 0;
        if (everyStepBounded) {
          const numeric = steps.map((s) => Number(s && s["timeout-minutes"]));
          const known = numeric.filter((n) => Number.isFinite(n));
          const unevaluable = numeric.length - known.length;
          const knownSum = known.reduce((a, b) => a + b, 0);
          // An inert J (> 360) cannot fire at all, so the platform ceiling is what actually covers the job.
          const ceiling = verdict.expression || verdict.inert ? PLATFORM_CEILING_MIN : Number(verdict.value);
          if (verdict.expression) {
            notes.push(
              `${where} declares an EXPRESSION job bound and every step carries a bound, so whether its bound ` +
                `sits above their ${knownSum}-min numeric subtotal${unevaluable > 0 ? ` (+${unevaluable} expression bound(s))` : ""} ` +
                `could NOT be checked — a bound at or below that sum would make its last step bounds unreachable`
            );
          } else if (knownSum >= ceiling) {
            violations.push(
              `${where} declares timeout-minutes ${verdict.value} but its ${steps.length} step bounds` +
                (unevaluable > 0 ? `, of which only the ${known.length} numeric ones are summed here,` : "") +
                ` SUM to ${knownSum} min — at or above ${verdict.inert ? `the platform's ${PLATFORM_CEILING_MIN}-minute ceiling (which pre-empts its inert ${verdict.value})` : "its own job bound"}, ` +
                `so the last step bounds could never fire and the job-level \`cancelled\` (NON-RED to the rail) ` +
                `pre-empts the red step that actually hung. ` +
                // The remedy must be one that EXISTS. `knownSum < 359` is the exact test, not `< 360`:
                // at knownSum === 359 no INTEGER job bound lies strictly between it and the 360 ceiling
                // (review finding, P3 — the 359 edge fell between the two branches).
                (knownSum < PLATFORM_CEILING_MIN - 1
                  ? `Raise the job bound above ${knownSum} and below ${PLATFORM_CEILING_MIN}, or lower the tail step bounds.`
                  : `No job bound can sit above ${knownSum} inside the platform's ${PLATFORM_CEILING_MIN}-minute ceiling, so the step bounds are what must come down.`)
            );
            continue;
          } else if (unevaluable > 0) {
            notes.push(
              `${where} declares timeout-minutes ${verdict.value} and every step carries a bound, but ${unevaluable} of ` +
                `them are \`\${{ … }}\` expressions, so Σ could not be evaluated — the reachability rule was NOT ` +
                `applied to those (the ${known.length} numeric bound(s) total ${knownSum} min, so the expression ` +
                `bound(s) must stay below ${ceiling - knownSum} min)`
            );
          }
        }
        bounded++;
        if (verdict.inert) {
          notes.push(
            `${where} declares ${verdict.value} min — above the platform's 360-minute ceiling, so the runner cancels first and the number is inert`
          );
        }
        // A job bound is a BACKSTOP; if its steps are unbounded, say so once per job so the
        // weaker shape is visible rather than implied. It is a NOTE, not a violation:
        // `check-ci-lane-parity.mjs` refuses that shape in the two lane documents already.
        if (steps.length > 0 && badSteps.length > 0) {
          // …and name any step bound that is ALREADY beyond the job bound, so the NOTE genuinely covers
          // the shape the all-numeric rule above cannot (review finding, P3: it claimed coverage it did not give).
          const ceilingHere = verdict.expression || verdict.inert ? PLATFORM_CEILING_MIN : Number(verdict.value);
          const stranded = steps.filter((s) => Number(s && s["timeout-minutes"]) >= ceilingHere).length;
          notes.push(
            `${where} is bounded only at the JOB level — ${badSteps.length}/${steps.length} step(s) carry no bound, so its trip is ` +
              `\`cancelled\` (NON-RED to the rail). The job ends and names itself; a step bound would red it.` +
              (stranded > 0
                ? ` NOTE: ${stranded} step bound(s) here are at or above ${ceilingHere} min and can never fire.`
                : "")
          );
        }
        continue;
      }
      if (steps.length > 0 && badSteps.length === 0) {
        // A step-only job must be bounded BELOW the platform ceiling, or its last step bounds can
        // never fire (the 360-minute default cancel — `cancelled`, NON-RED — arrives first).
        const numeric = steps.map((s) => Number(s && s["timeout-minutes"]));
        const known = numeric.filter((n) => Number.isFinite(n));
        const unevaluable = numeric.length - known.length;
        const sum = known.reduce((a, b) => a + b, 0);
        if (sum >= PLATFORM_CEILING_MIN) {
          violations.push(
            `${where} is bounded only by its ${steps.length} step bounds` +
              (unevaluable > 0 ? `, of which only the ${known.length} numeric ones are summed here` : "") +
              `, which SUM to ${sum} min — at or ` +
              `above the platform's ${PLATFORM_CEILING_MIN}-minute job ceiling, whose trip is \`cancelled\` ` +
              `(NON-RED to the rail). The last step bounds could never fire, so lower them: the step ` +
              `bounds are the red-producing bound and they must all be REACHABLE.`
          );
          continue;
        }
        // ⛔ A SUM THIS GUARD CANNOT COMPUTE IS REPORTED, NEVER SILENTLY CERTIFIED (review finding, P2,
        // measured). `${{ … }}` is an accepted step bound, so `Number()` of it is NaN and Σ is unknown;
        // falling through to `boundedBySteps++` would report the job as certified on a property that was
        // never evaluated — silently, which the file's own doctrine forbids. NOTE, so it is visible.
        if (unevaluable > 0) {
          notes.push(
            `${where} is bounded by its ${steps.length} step bounds, but ${unevaluable} of them are \`\${{ … }}\` ` +
              `expressions, so Σ could not be evaluated — the ${PLATFORM_CEILING_MIN}-minute reachability rule was ` +
              `NOT applied (the ${known.length} numeric bound(s) total ${sum} min, so the expression bound(s) ` +
              `must stay below ${PLATFORM_CEILING_MIN - sum} min)`
          );
          boundedBySteps++;
          continue;
        }
        notes.push(`${where} is bounded by its steps alone (Σ ${sum} min, under the ${PLATFORM_CEILING_MIN}-minute ceiling)`);
        boundedBySteps++;
        continue;
      }
      violations.push(
        steps.length === 0
          ? `${where} ${verdict.why}`
          : `${where} ${verdict.why}, and NOT every step is bounded either (${badSteps.join("; ")})`
      );
    }
  }

  for (const file of files) auditFile(file, 0);

  if (jobCount === 0) {
    process.stderr.write(
      `check-workflow-bounds: ✗ REFUSING — parsed ${files.length} workflow file(s) and found ZERO jobs.\n` +
        `   That is the guard failing to read, not the tree being clean: exit 2.\n`
    );
    process.exit(2);
  }

  for (const n of notes) process.stdout.write(`⚠️  ${n}\n`);

  if (violations.length > 0) {
    process.stderr.write(
      `\n❌ check-workflow-bounds: ${violations.length} job(s) fail the time-bound rule (agent-infra#2055).\n` +
        `   A job with no \`timeout-minutes\` can hang until the platform's 6-hour ceiling, holding the merge\n` +
        `   queue: measured, PR #2168's \`bash-suites\` held an otherwise-reviewed PR for >55 minutes.\n` +
        `   Add \`timeout-minutes\` to the JOB, sized from CI's own measured p90, and put the derivation in a\n` +
        `   comment beside it so a later edit cannot silently raise it (see .github/workflows/ci.yml's\n` +
        `   \`bash-suites\` for the form). A reusable-workflow CALL job cannot carry one — bound the jobs\n` +
        `   inside the workflow it calls.\n\n`
    );
    for (const v of violations) process.stderr.write(`   • ${v}\n`);
    process.stderr.write("\n");
    return 1;
  }

  process.stdout.write(
    `✅ check-workflow-bounds: ${bounded} job(s) declare their own bound` +
      (boundedBySteps > 0 ? `, ${boundedBySteps} are bounded by EVERY step's own bound` : "") +
      (callers > 0 ? `, ${viaCallee}/${callers} call job(s) are bounded through the workflow they call` : "") +
      ` — ${jobCount} job(s) across ${files.length} workflow file(s).\n`
  );
  return 0;
}

process.exit(main());
