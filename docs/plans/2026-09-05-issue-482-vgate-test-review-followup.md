---
title: "#482 — test-review follow-up (#472): self-contained D1 bridge checks, drift-guard skip hardening, 04-merge-deploy fixture guard"
type: engineering
domain: platform
doc_status: live
subjects.team: epistemic-team
aboutSubjects: [agent-infra, epistemic-team]
aboutObjects: [issue-482, issue-472]
created: 2026-09-05
---

# #482 — verification-gate test follow-up (D1 sentinel bridge, tri-state drift-guard gate, scenario-41 real commit, 04 fixture guard)

## Scope (from issue body, confirmed against code at fc0c98f)

Four residual test-review findings from #472's 3-cycle review, all in the TEST files only —
**production code `extensions/verification-gate/index.ts` is OUT OF SCOPE**. Baseline
verified green: unit suite `197 passed / 0 failed` (worktree run), e2e suite has 50
`test()` entries (48 scenario-labeled + `setup:` + the #190 compound-keys test).

| # | Target | File / location (baseline line numbers) | Severity |
|---|---|---|---|
| T1 | Drift-guard enforce-vs-skip keys solely on `isSourceCheckout()` (`existsSync(new URL("../../.git", import.meta.url))`, L1651) → `.git`-less source artifacts silently soft-skip BOTH drift guards (01-preflight fence guard L1667+, 05-cleanup block guard L1495-1528) | `index.test.ts` | P1 |
| T2 | Scenarios 38/39 D1 bridge assertions are ordering-dependent (null-tolerant both-absent — degrades to `null === null` when prior scenarios never wrote the bridge) | `index.e2e.test.ts` L1387-1408 / L1430-1445 | P2 |
| T3 | Scenario 41 Leg B porcelain asserts are tautological (a blocked `-am` can never execute → working tree invariant regardless of verdict) | `index.e2e.test.ts` L1523-1590 | P2 |
| T4 | The 04-merge-deploy.md Step B delete literal TRUE fixture (L1482, byte-identical to `skills/commit-workflow/workflow/04-merge-deploy.md:91`) has NO doc↔fixture drift guard, while sibling `FULL_05_CLEANUP_BLOCK` got one | `index.test.ts` | P2 |

### Agreed constraints (from the verified converge step — BINDING)

- **T1 — `.git` governance stays PRIMARY**: fence-removal drift in a real checkout must
  still red via the guards' doc-null/parse hard-fail arms.
  - **Enforcement OR-arms** (for `.git`-less source artifacts): CI env + sibling-doc-fence
    presence (via the `import.meta` channel — NOT cwd resolution).
  - **The issue's rejected variant is NOT applied**: no "cwd-resolve the doc and enforce in
    the skip branch" (the deployed copy's `import.meta` channel DOES resolve a sibling doc,
    so that variant would spurious-red on the fence-less deployed 01-preflight.md).
  - **Deployed physical copy** (`~/.pi/agent/extensions/verification-gate` + the
    independently-synced `~/.pi/agent/skills` tree) must KEEP soft-skipping with current
    behavior in (a) the current source checkout and (b) the current deployed layout.
  - **Skip arm differentiates**: `deployed` (informative skip — doc present but fence-less)
    vs `unknown` (LOUD warning, never silent — the code-only-archive case FAILS CLOSED).
  - **Activation canary** added that does NOT red legitimate deployed runs (gated on
    git/CI presence).
- **T2** — deterministic PASS-shaped sentinel bridge: fixed bytes
  `{status:"PASS", verified_files:[{path:"<clearly-foreign-root>::sentinel", hash:<fixed 64-hex>}], timestamp:<fixed ISO>}`,
  no `Date.now()`. Written AFTER `session_start` resolves and IMMEDIATELY BEFORE the exempt
  op; then assert byte-identical after the op AND parse-assert no `verified_files` entry
  has a `root::` prefix equal to `realpathSync(<scenario repo>)`. Verified inert: foreign-root
  drop (recovery, `index.ts` ~L297), single-slot overwrite, and no post-38 scenario reads
  pre-38 bridge bytes.
- **T3** — drop the post-block porcelain assert; KEEP the hook-decision pins (sweep1/sweep2
  `block===true` + reason names README.md + no-hash-mismatch + attached `-am"x"` block);
  after the ALLOWED bare `git commit -m x` verdict, execute it FOR REAL (Leg-A pattern) then
  assert EXACT porcelain `equal(git(repo,"status --porcelain"), " M src/app.ts")`.
- **T4** — hoist the inline Step B delete literal into a shared UPPER_SNAKE const beside
  `FULL_05_CLEANUP_BLOCK` (L1386-1402); add a drift-guard test mirroring the 05 guard:
  source-checkout skip → `resolveRepoDoc` (same 3-path form) → doc-null `ok(false)` hard
  fail → content-anchored FULL-LINE equality with `trimEnd` anchored INSIDE the Step B fence
  via `indexOf("```bash\nPR_BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q '.headRefName')")`
  (unique — verified; immune to the spoofable partial prose mention at doc L110). Single-line
  const is the right surface — only the classification-relevant line; prose edits elsewhere
  in Step B must not red.

---

## 1. Selected approach per target + rationale

### T1 — **Fork A (i) + (iii): pure tri-state classifier core + per-guard probe wrapper, one shared gate**

Selected: a pure, table-testable decision core
`classifyGuardLayout({gitMarker, ci, piHomeLayout, docResolvable, fencePresent}) → "source" | "deployed" | "unknown"`
plus a thin real-probe wrapper `probeGuardLayout(fenceMarker, relFromHere, ...cwdRels)` that
performs the guard's doc read and computes the tuple. The three guards (01, 05, and the new
04) share ONE gate helper parameterized by their own fence marker.

The tuple carries a **pi-home location signal** (`piHomeLayout` — the module lives under
`join(homedir(), ".pi", "agent")`), added after the [SECOND-MODEL-GATE] P1 coherence finding:
content-wise, a `.git`-less source artifact (fenced docs) and a deployed physical copy whose
skills tree has synced to a fenced rev are IDENTICAL — the tuple alone cannot distinguish
"enforce" (tarball/vendor) from "soft-skip" (deployed fenced 05/04 docs, byte-identical to
source). Location is the only discriminator. Under the refined classifier, ALL three guards
soft-skip in the deployed pi-home layout regardless of doc generation (restoring the original
design intent: "enforcement against the independently-synced pair is meaningless"), and the
doc-fence signal remains solely a `.git`-less-SOURCE-ARTIFACT detector.

**Decision rules (in order):** `gitMarker` → source (git governance PRIMARY — fence-removal
drift in a real checkout still reaches the guards' hard-fail arms); else `piHomeLayout` →
deployed (location BEATS ci — a deployed copy must soft-skip unconditionally, even in a
shell that inherits `CI=true`/`GITHUB_ACTIONS`; Phase-7 ISSUE-3); else `ci && !docResolvable` → source
(CI + NO sibling doc — code-only archive under CI fails closed on the guards' doc-null
arms; never under the pi home. With a doc PRESENT, CI DEFERS to the doc's fence state
(rules 4-5): a fence-less doc under CI is a pre-#472-generation artifact — uncheckable,
not a defect — plan-review R2-1); else
`docResolvable && fencePresent` → source (.git-less source artifact carrying the guard's
fence — the #482 headline; also the CI+doc+fence tuple — rule 3 requires doc-null); else
`docResolvable` → deployed (fence-less doc — pre-#472-generation artifact for 01; for
04/05 a fence-less doc means the ceremony block is absent — soft-skip is defensible: a
missing fence cannot be drift-checked; informative soft-skip IN ANY ENV — git-governed
checkouts never reach this (rule 1 → the structural asserts red a fence-less doc), and
CI-without-git doc-carrying runs defer here by rule 3's doc-resolvable guard);
else → unknown (doc-less code-only archive → LOUD warn + fail-closed red).

**Why (i)+(iii) beats the alternatives:**

- **(i) pure core, table-tested**: the fix's central risk is a wrong decision in an exotic
  layout. A pure function over 5 booleans = 32 exhaustive, deterministic rows — no fs, no
  env (the "4 booleans = 16 rows" figure belonged to the rejected no-location variant). The
  32-row table test makes the layout contract reviewable and regression-proof. The
  T1 headline row (`.git`-less source artifact: `git=false, ci=false, docResolvable=true,
  fencePresent=true → "source"`) is pinned by name.
- **(iii) per-guard marker parameterization** unifies the 3 guards behind the same gate. The
  marker probe IS per-guard (01 = `<!-- VGATE-SHAPE-RULE` opener; 05 = the ceremony-fence
  opener ` ```bash\n# BRANCH = the merged PR branch`; 04 = the Step B fence anchor), and the
  doc read must happen PRE-decision (the fence OR-arm needs the doc text) — `probeGuardLayout`
  encodes exactly that order, so no guard can get it wrong.
- **(ii) boolean OR-arms** — rejected in full below (duplicate rejection paragraph removed; the
  standalone **Fork A (ii)** paragraph is the canonical record).

**Fork A (ii) (boolean OR-arm `isSourceCheckout() || isDeployedLayout()`) rejected**: the
`unknown` arm stays implicit (a code-only archive falls through to the EXISTING doc-null
hard fail whose message frames it as a source-tree breakage — misleading) and the canary has
no single decision point to assert. **(ii) would have been better only if** the change had to
be diff-minimal with zero new classifier coverage — rejected because T1's purpose is closing
a silent-coverage hole, which demands a testable decision core.

**Fork A (i)-without-location (tuple = {git, ci, doc, fence} only) rejected after the
[SECOND-MODEL-GATE] P1**: it classifies a deployed physical copy whose 04/05 docs are fenced
+ byte-identical (verified real machine state) as `source` → enforce-and-pass, violating the
binding "deployed must soft-skip" constraint and manufacturing a sync-skew false-red vector.
The location signal removes the collision. **(no-location) would have been better only if**
deployed copies were provably impossible to run with guard code — false today (the deployed
extension dir ships index.test.ts).

### T2 — **Fork B (1): leave the sentinel in place (default)**

Selected: plant the deterministic sentinel before each exempt op (scenarios 38 AND 39),
assert byte-identical + no-repo-root-entry after, and leave it. The sentinel is inert for
every subsequent reader: recovery drops non-matching-root entries before any hash work
(`index.ts` ~L297: `parsed.root !== normRoot → continue`), the next real PASS overwrites the
single slot (`writeBridge`), and grep-verified there are no post-39 full-bridge reads in the
suite. Fork B (2) (restore prior bridge in `try/finally`) would need the exempt op's body
restructured into a protected region and buys hermeticity that nothing downstream consumes —
**(2) would have been better if** a later scenario read pre-38 bridge bytes and depended on
their survival; verified none do. Fork B (3) (delete-after) reintroduces an absence slot and
adds an `unlink` between scenarios for zero benefit. Fork B (1) matches the gate's own
single-slot-overwrite semantics — the least machinery with the same guarantee.

### T3 — **Option (1): minimal agreed shape (no new scenario, no index-object plumbing)**

Selected: drop the tautological post-block porcelain assert after sweep1; after the ALLOWED
bare `git commit -m x` verdict, execute `git(repo, "commit -m x")` for real (the Leg-A
pattern at L1544/L1565) and assert exact porcelain. Why: the real commit turns a
harness-only verdict into real index state, so the exact-porcelain assert now proves the
docs exemption committed README.md ONLY and never rode `-a` or dragged the dirty
unstaged `src/app.ts`. Option (2) (index-object immutability across blocked sweeps via
`write-tree` snapshots) adds plumbing to prove a property the harness architecture already
guarantees (a BLOCKED tool_call never executes — there is no git process to mutate
anything); **(2) would have been better if** the gate ever executed commands on block
(escape hatches, partial allow) — it does not. Option (3) (split Leg B into scenario 41b,
suite 50→51) duplicates the whole repo setup for zero additional property — rejected.

### T4 — **Fork C (1): single-line const + full-line drift guard**

Selected: hoist the literal to `MERGE_DEPLOY_STEP_B_DELETE` beside `FULL_05_CLEANUP_BLOCK`,
rewire the TRUE-fixture test to the const, and add a full-line drift guard mirroring the 05
guard (same gate, doc-null hard fail, content-anchored full-line equality with `trimEnd`
anchored inside the Step B fence via the unique PR_BRANCH anchor). Fork C (2) (whole-Step-B-
fence const, a FULL_05 mirror) would red on the worktree-defer comment/echo lines inside the
fence (doc L94-98) — prose that is NOT classification-relevant; **(2) would have been better
if** agents pasted Step B as ONE command the way they paste the 05 ceremony block (the #470
shape) — they run Step B per-line, and only the delete push line feeds `isDeletionPush`.
Fork C (3) (single-line byte pin + whole-fence purity pin) WOULD catch a future maintainer
INSERTING a content push into Step B's fence, but the confirmed T4 shape scopes the guard to
the delete line: a whole-fence BYTE pin (C(2)) reds on benign prose edits at doc L94-98, and
a whole-fence PURITY pin (isDeletionPush over the fence body — writable and TRUE today, like
the FULL_05 shape with its if/fi `git branch -D` structure) fires only when a real content op
enters the fence — both beyond the issue's ask; only the delete push line feeds
isDeletionPush, and no scenario pastes whole-Step-B as one command. Rejected: machinery
beyond the issue's ask, conflicting with the confirmed single-line surface.

### Fork D — **activation canary: hybrid (git ∥ CI) gate**

Selected: the canary runs only when `isSourceCheckout() || (isCIEnv() && !isPiHomeLayout())`
(else it logs a skip and returns — never reds a legitimate deployed run, INCLUDING a
physical copy in a shell that inherits CI env — Phase-7 ISSUE-3 corner), then recomputes the
gate with the
guards' REAL probes (05 guard's marker via `probeGuardLayout`) and asserts
`layout === "source"`. The classifier's fence OR-arm (the T1 headline) is covered by the
32-row table test AND — after plan-review R4-3 — a canary **git-removal pin**: re-classify
THIS run's real measured probe tuple with `gitMarker: false` and assert `source` (rule 4's
real-probe path, which rule 1 would otherwise shadow in every git run). A CI-without-git
run whose doc is fence-less classifies `deployed` (rule 5) — the canary logs a consistency
line and returns rather than red (R2-1). Unconditional (no gate) would red deployed runs
(that is what it must never do). git-only would miss CI runs that strip `.git`.

---

## 2. Exact file edits

Line numbers are baseline (fc0c98f); anchors are content-based. All new/changed code lives
in `extensions/verification-gate/index.test.ts` (edits U1-U8), `index.e2e.test.ts` (E1-E4),
and a comment refresh in `.github/workflows/ci-main.yml` (Y1).

### U1 — New const cluster after `FULL_05_CLEANUP_BLOCK` (L1402)

Anchor: the closing of `FULL_05_CLEANUP_BLOCK` (`…git branch -D "$BRANCH" 2>&1 || echo "⚠️ local branch $BRANCH could not be deleted — delete manually: git branch -D $BRANCH"\nfi\`;`) — insert before the next `test("TRUE: delete-shaped forms…")`.

Add, with a comment block explaining placement (TDZ: these are `const`s referenced by tests
at L1480+ that execute immediately at module load, so they must be declared BEFORE first use;
the classifier *functions* below hoist, consts do not):

```ts
// #482: shared skip-arm messaging for the THREE drift guards (01-preflight, 05-cleanup,
// 04-merge-deploy). Declared here (before the guards that run at module load) — consts
// are TDZ until initialized; the classifier functions below hoist instead.
const DRIFT_GUARD_SKIP_DEPLOYED =
  "  ↪ skip (deployed pi-home layout or fence-less sibling doc — doc↔fixture enforcement requires a source checkout, CI, or a fence-carrying doc artifact; comparing against an independently-synced skills pair is meaningless)";
const DRIFT_GUARD_UNKNOWN_WARN =
  "  ⚠️ drift guard layout UNKNOWN (no .git marker, not under the pi home, no CI env, sibling skills doc unresolvable) — this looks like a code-only archive; refusing to pass vacuously (fail-closed). Run from an agent-infra source checkout or an artifact that carries the skills/ tree.";
const DRIFT_GUARD_UNKNOWN_FAIL =
  "drift guard layout UNKNOWN (no .git marker, not under the pi home, no CI env, sibling skills doc unresolvable) — code-only archive must not soft-skip the drift guards; run where the sibling skills doc is present";
// #482: shared 05-ceremony fence marker — SINGLE source of truth, consumed by the guard
// probe (fencePresent), the 05 guard's fence extraction (U5), AND the activation canary
// (Phase-7 ISSUE-7: triplicated markers drift independently). ⚠️ Slicing asymmetry: block
// BODY comparisons start at fenceOpen + "```bash\n".length, NOT at marker.length — the
// marker includes the "# BRANCH…" comment LINE, and the FULL_05_CLEANUP_BLOCK body starts
// AT that comment line (plan-review R1-2).
const DRIFT_GUARD_05_FENCE_MARKER = "```bash\n# BRANCH = the merged PR branch";
```

### U2 — New `MERGE_DEPLOY_STEP_B_DELETE` const (same cluster, U1)

```ts
// 04-merge-deploy.md Step B remote-delete line — the single classification-relevant line
// of the ceremony (skills/commit-workflow/workflow/04-merge-deploy.md:91), VERBATIM.
// Shared by the TRUE-fixture pin and the #482 drift guard. Line-only surface: prose edits
// elsewhere in Step B (worktree-defer comments/echoes, doc L94-98) must NOT red the guard.
const MERGE_DEPLOY_STEP_B_DELETE = `git push origin --delete "$PR_BRANCH" 2>&1 || echo "⚠️ remote delete failed — delete manually: gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/$PR_BRANCH"`;
```

### U3 — Rewire the TRUE-fixture test (L1480-1484)

Replace the body literal with the const (test name + assertion message unchanged):

```ts
test("04-merge-deploy.md Step B literal (TRUE ceremony fixture — 2>&1 drop, gh api prose, quote-strip)", () => {
  // MERGE_DEPLOY_STEP_B_DELETE — VERBATIM from
  // skills/commit-workflow/workflow/04-merge-deploy.md:91 (declared beside
  // FULL_05_CLEANUP_BLOCK above; pinned by the #482 drift guard below).
  ok(isDeletionPush(MERGE_DEPLOY_STEP_B_DELETE), "merge-deploy ceremony delete must classify pure");
});
```

### U4 — New 04 drift-guard test (insert after the 05 drift guard, after L1528)

```ts
test("#482 drift guard: MERGE_DEPLOY_STEP_B_DELETE == the live 04-merge-deploy.md Step B delete line", () => {
  // Mirror the 05-cleanup drift guard for the 04-merge-deploy Step B delete line
  // (the fixture behind the TRUE pin). Same #482 tri-state gate. The anchor is the
  // Step B fence opener (PR_BRANCH resolution line) — UNIQUE to the fence: the
  // spoofable partial prose mention at doc L110 sits AFTER the fence close and is
  // never inside the bounded search region.
  const fenceMarker = "```bash\nPR_BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q '.headRefName')";
  const { layout, docText } = probeGuardLayout(
    fenceMarker,
    "../../skills/commit-workflow/workflow/04-merge-deploy.md",
    "../../skills/commit-workflow/workflow/04-merge-deploy.md",
    "skills/commit-workflow/workflow/04-merge-deploy.md",
  );
  if (layout === "deployed") { console.log(DRIFT_GUARD_SKIP_DEPLOYED); return; }
  if (layout === "unknown") { console.warn(DRIFT_GUARD_UNKNOWN_WARN); ok(false, DRIFT_GUARD_UNKNOWN_FAIL); return; }
  if (docText === null) {
    ok(false, "04-merge-deploy.md unreachable from the agent-infra source tree — MERGE_DEPLOY_STEP_B_DELETE fixture drift guard would pass vacuously; restore the doc or fix the resolution");
    return;
  }
  const fenceOpen = docText.indexOf(fenceMarker);
  ok(fenceOpen !== -1, "04-merge-deploy.md must contain the Step B ```bash fence (PR_BRANCH anchor)");
  const bodyStart = fenceOpen + fenceMarker.length;
  const fenceClose = docText.indexOf("\n```", bodyStart);
  ok(fenceClose !== -1, "04-merge-deploy.md Step B fence must close");
  // Locate the delete invocation inside the fence by its stable verb+target prefix
  // (a partial edit like 2>&1 → 2>/dev/null must still find the line, then fail the
  // FULL-LINE compare below with a readable diff); compare the full line (trimEnd).
  const delStart = docText.indexOf('git push origin --delete "$PR_BRANCH"', bodyStart);
  ok(delStart !== -1 && delStart < fenceClose, "04-merge-deploy.md Step B fence must contain the remote-delete push line");
  const lineStart = docText.lastIndexOf("\n", delStart) + 1;
  const lineEnd = docText.indexOf("\n", delStart);
  equal(
    docText.slice(lineStart, lineEnd === -1 ? undefined : lineEnd).trimEnd(),
    MERGE_DEPLOY_STEP_B_DELETE,
    "04-merge-deploy.md Step B delete line drifted from MERGE_DEPLOY_STEP_B_DELETE — re-copy VERBATIM (the isDeletionPush TRUE fixture pins it)"
  );
});
```

### U5 — Migrate the 05 drift guard's gate (L1495-1528, internals only)

Replace the current pre-resolve skip arm (comment at L1496-1502 + `if (!isSourceCheckout()) { console.log(…); return; }` + the `resolveRepoDoc` call) with the tri-state gate; keep the doc-null arm message and every structural assert byte-identical:

```ts
  // #482: gate on the tri-state layout. .git governance is PRIMARY (rule 1); the pi-home
  // LOCATION rule (rule 2) soft-skips deployed copies regardless of doc generation — a
  // deployed pi-home copy whose sibling doc is present AND fenced is still deployed (the
  // [SECOND-MODEL-GATE] P1 headline: content alone cannot separate it from a .git-less
  // source artifact); CI + doc-unresolvable (rule 3) and fence-carrying sibling docs (rule
  // 4) route .git-less source artifacts into enforcement — a doc PRESENT under CI defers to
  // its fence state (fence-less → rule 5 deployed soft-skip; cycle-2 R1-F2); doc-less
  // code-only archives FAIL CLOSED (unknown, loud).
  const { layout, docText } = probeGuardLayout(
    DRIFT_GUARD_05_FENCE_MARKER, // shared const — single source of truth with the canary
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "skills/commit-workflow/workflow/05-cleanup.md",
  );
  if (layout === "deployed") { console.log(DRIFT_GUARD_SKIP_DEPLOYED); return; }
  if (layout === "unknown") { console.warn(DRIFT_GUARD_UNKNOWN_WARN); ok(false, DRIFT_GUARD_UNKNOWN_FAIL); return; }
```

⚠️ RANGE BOUNDARY (cycle-2 R4-F2; line numbers corrected cycle-3 R1-1): the snippet ends at
the `unknown` arm — the existing doc-null hard-fail arm BELOW the replaced range (05 guard
L1512-1515: `if (docText === null) { ok(false, "05-cleanup.md unreachable from the
agent-infra source tree — FULL_05_CLEANUP_BLOCK fixture drift guard would pass vacuously;
restore the doc or fix the resolution"); return; }`)
is KEPT VERBATIM and stays reachable because `probeGuardLayout` returns `docText: null` on an
unresolvable doc while `layout` is `source` (git rule 1 / CI rule 3). Do NOT paste a
`if (docText === null) { /* existing ok(false) — unchanged */ return; }` placeholder — a
silent-return arm before the real one would DEAD-CODE the `ok(false)` hard-fail and pass
doc-null vacuously (fail-open in the exact layout #482 must hard-fail). ⚠️ OVER-INCLUSION
(cycle-3 R4-1): if your selection range extends PAST the `unknown` arm into the doc-null arm
below (e.g. through the closing `}` at L1515), re-include that arm VERBATIM at the paste
point — the snippet intentionally omits it; a swallowed arm is unreachable in healthy runs
(ships green) and turns the doc-missing hard-fail into a bare `TypeError` in sim C/C-prime,
degrading the fail-closed diagnostic the evidence grep depends on.

The subsequent fence extraction is untouched EXCEPT its opener lookup — change
`const fenceOpen = docText.indexOf("```bash\n# BRANCH = the merged PR branch");` to
`const fenceOpen = docText.indexOf(DRIFT_GUARD_05_FENCE_MARKER);` (reuse the shared const —
leaving a second inline copy beside it is the exact triplication #482 exists to kill;
plan-review R1-2). ⚠️ Keep the slicing asymmetry: `bodyStart` stays
`fenceOpen + "```bash\n".length` — NOT `fenceOpen + DRIFT_GUARD_05_FENCE_MARKER.length` —
the marker string includes the `# BRANCH = the merged PR branch` comment LINE, and the
`FULL_05_CLEANUP_BLOCK` compare body starts AT that comment line (U1's const comment
carries this contract). Test name and assertion messages unchanged.

### U6 — Replace the shared helper block (L1644-1661: the `// ── Shared doc-resolution …`
comment through `resolveRepoDoc`'s close — KEEP the blank line + the `// ── #472 — doc drift
test …` comment + `section(...)` header that follow) with the #482 gate

```ts
// ── #482 — shared drift-guard layout gate (replaces the two-#472-guard isSourceCheckout
// enforce-vs-skip decision). Enforcement target: the agent-infra SOURCE CHECKOUT plus any
// .git-less source artifact OUTSIDE the pi-home layout — CI env with an UNRESOLVABLE
// sibling doc (rule 3), or a sibling skills doc that still carries this guard's fence
// marker (rule 4; a doc present under CI defers to its fence state — cycle-2 R1-F2). A
// DEPLOYED extension copy (~/.pi/agent/extensions/… — the pi agent layout) is
// identified by LOCATION (module under join(homedir(), ".pi", "agent")) — content alone
// cannot separate it from a .git-less source artifact (a deployed skills tree can sync to a
// fenced rev, making the pair content-identical): ALL guards soft-skip there, regardless of
// doc generation (enforcement against the independently-synced pair is meaningless, not
// drift). A doc-less code-only archive (no git, no CI, not pi-home) is UNKNOWN and FAILS
// CLOSED (never silent). ──

type GuardLayout = "source" | "deployed" | "unknown";
interface GuardLayoutProbe {
  gitMarker: boolean;     // .git dir (clone) or file (worktree) above this module
  ci: boolean;            // CI env present (GITHUB_ACTIONS / CI)
  piHomeLayout: boolean;  // module lives under join(homedir(), ".pi", "agent") — deployed copy
  docResolvable: boolean; // sibling skills doc reachable via resolveRepoDoc
  fencePresent: boolean;  // sibling doc contains THIS guard's fence marker
}

// Pure decision core — table-tested exhaustively (32 rows). Rule order (binding — Phase-7
// ISSUE-3: LOCATION beats CI so a deployed copy soft-skips even in a shell that inherits
// CI=true/GITHUB_ACTIONS):
//   1. gitMarker → source          (git governance PRIMARY — fence-removal drift in a real
//                                   checkout still reaches the guards' hard-fail arms)
//   2. piHomeLayout → deployed     (deployed physical copy — soft-skip unconditionally, any
//                                   doc generation, even under inherited CI env)
//   3. ci && !docResolvable → source   (CI + NO sibling doc — code-only archive under CI
//                                       fails closed on the guards' doc-null arms; never
//                                       under the pi home (rule 2). With a doc PRESENT, CI
//                                       DEFERS to the doc's fence state (rules 4-5): a
//                                       fence-less doc under CI is a pre-#472-generation
//                                       artifact — uncheckable, not a defect; R2-1)
//   4. docResolvable && fencePresent → source   (.git-less source artifact — #482 headline;
//                                       also the CI+doc+fence tuple — rule 3 needs doc-null)
//   5. docResolvable → deployed    (fence-less doc — pre-#472-generation artifact for 01;
//                                  for 04/05 a fence-less doc means the ceremony block is
//                                  absent — soft-skip is defensible: a missing fence cannot
//                                  be drift-checked; env-independent contract)
//   6. else → unknown              (doc-less code-only archive — LOUD fail-closed)
function classifyGuardLayout(p: GuardLayoutProbe): GuardLayout {
  if (p.gitMarker) return "source";
  if (p.piHomeLayout) return "deployed";
  if (p.ci && !p.docResolvable) return "source";
  if (p.docResolvable && p.fencePresent) return "source";
  if (p.docResolvable) return "deployed";
  return "unknown";
}

function isCIEnv(): boolean {
  return process.env.GITHUB_ACTIONS === "true"
    || (typeof process.env.CI === "string" && process.env.CI.length > 0
        && process.env.CI !== "0" && process.env.CI.toLowerCase() !== "false");
}
function isSourceCheckout(): boolean {
  return existsSync(new URL("../../.git", import.meta.url)); // dir in a clone, file in a worktree
}
function isUnderOrAt(root: string, agentHome: string): boolean {
  // Pure boundary compare (Phase-7 ISSUE-2: extracted so the location decision is
  // table-testable with synthetic paths — the exact-match, +sep-boundary, and
  // prefix-collision (~/.pi/agent2) cases): root IS the agent home, or lives under it.
  return root === agentHome || root.startsWith(agentHome + sep);
}
function isPiHomeLayout(): boolean {
  // Location probe: is this module's AGENT ROOT (= two hops up from the file, i.e. the .git
  // sibling that isSourceCheckout probes) the pi agent home? import.meta.url resolves
  // symlinks by default, so a canonical SYMLINKED install reports the real agent-infra path
  // (→ git marker present → source); a physical copy stays under ~/.pi/agent → deployed.
  // NOTE: new URL("../../", import.meta.url) from …/extensions/verification-gate/index.test.ts
  // resolves to the AGENT ROOT (~/.pi/agent for the deployed copy — EQUAL to agentHome, not
  // strictly under it), so the compare needs the exact-match arm isUnderOrAt(real, agentHome)
  // (real === agentHome OR startsWith(agentHome + sep)) — a bare startsWith(agentHome + sep)
  // misses the equal case ([SECOND-MODEL-GATE] P0 — verified in Node).
  try {
    const moduleDir = fileURLToPath(new URL("../../", import.meta.url)); // agent root
    const real = realpathSync(moduleDir);
    const agentHome = realpathSync(join(homedir(), ".pi", "agent"));
    return isUnderOrAt(real, agentHome);
  } catch { return false; }
}
function resolveRepoDoc(relFromHere: string, ...cwdRels: string[]): string | null {
  const viaUrl = new URL(relFromHere, import.meta.url);
  if (existsSync(viaUrl)) return readFileSync(viaUrl, "utf8");
  for (const rel of cwdRels) {
    if (existsSync(rel)) return readFileSync(rel, "utf8");
  }
  return null;
}

// Real-probe wrapper for ONE guard: resolves the doc FIRST (the fence OR-arm needs the
// doc text pre-decision), then classifies over the guard-specific fence marker. Returns
// the measured PROBE tuple too — the activation canary re-classifies it with gitMarker
// removed to pin rule 4's real wiring in git runs where rule 1 would otherwise shadow it
// (plan-review R4-3). Guard call-sites destructure { layout, docText } — unaffected.
function probeGuardLayout(fenceMarker: string, relFromHere: string, ...cwdRels: string[]): { layout: GuardLayout; docText: string | null; probe: GuardLayoutProbe } {
  const docText = resolveRepoDoc(relFromHere, ...cwdRels);
  const probe: GuardLayoutProbe = {
    gitMarker: isSourceCheckout(),
    ci: isCIEnv(),
    piHomeLayout: isPiHomeLayout(),
    docResolvable: docText !== null,
    fencePresent: docText !== null && docText.includes(fenceMarker),
  };
  return { layout: classifyGuardLayout(probe), docText, probe };
}
```

U6 also needs import additions at the top of the file (with the existing `node:fs` /
`node:path` imports): `fileURLToPath` from `node:url`; `sep` from `node:path`; `homedir`
from `node:os` (already imports `tmpdir`). The `section("doc drift test — 01-preflight
VGATE-SHAPE-RULE fence ↔ exports")` header AFTER the block stays (content anchors are
primary — the header sits at L1663/L1665, outside the replaced range).

### U7 — New classifier + canary tests (insert after U6's helpers, before the 01 section)

```ts
section("drift-guard layout gate — classifyGuardLayout (#482)");

test("classifyGuardLayout: 32-row decision table — git → source; pi-home → deployed (beats CI/fence/doc); CI+doc-null → source fail-closed; fence-carrying doc → source; fence-less doc → deployed; doc-less → unknown", () => {
  // LITERAL named rows pin the BINDING decisions (Phase-7 ISSUE-1 — a mirror-only table
  // would pass if classifier AND spec changed together): git governance dominance, the
  // pi-home location beats CI + doc generation, the #482 .git-less-source-artifact
  // headline, fence-less doc → deployed, doc-less → unknown fail-closed.
  equal(classifyGuardLayout({ gitMarker: true, ci: false, piHomeLayout: false, docResolvable: false, fencePresent: false }), "source",
    "git marker alone → source (governance PRIMARY — a doc-less git checkout still reaches the guards' doc-null hard-fail arms)");
  equal(classifyGuardLayout({ gitMarker: true, ci: true, piHomeLayout: true, docResolvable: true, fencePresent: true }), "source",
    "git marker dominates every other signal (source worktree in CI, even under a pi-home-shaped path)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: true, docResolvable: true, fencePresent: true }), "deployed",
    "pi-home LOCATION beats inherited CI env (Phase-7 ISSUE-3 — a deployed copy must soft-skip even in a shell exporting CI=true)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: true, docResolvable: true, fencePresent: true }), "deployed",
    "pi-home beats the fence (deployed fenced 04/05 pair → soft-skip, not enforce — [SECOND-MODEL-GATE] P1 resolution)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: true, docResolvable: false, fencePresent: false }), "deployed",
    "pi-home with a MISSING sibling doc is still deployed → green (never a spurious unknown-red)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: false, docResolvable: true, fencePresent: true }), "source",
    "#482 headline: .git-less SOURCE ARTIFACT outside pi-home with a fence-carrying doc → source (enforce)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: false, docResolvable: true, fencePresent: true }), "source",
    "CI + fence-carrying doc → source (rule 4 — rule 3 needs doc-null; a vendored fenced artifact under CI enforces)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: false, docResolvable: true, fencePresent: false }), "deployed",
    "CI + FENCE-LESS doc → deployed (rule 5 — CI defers to the doc's fence state; a pre-#472 fence-less doc under CI soft-skips like any other, R2-1)");
  equal(classifyGuardLayout({ gitMarker: false, ci: true, piHomeLayout: false, docResolvable: false, fencePresent: false }), "source",
    "CI + doc-NULL code-only archive → source (rule 3 — the guards' doc-null arms red it; fail-closed under CI)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: false, docResolvable: true, fencePresent: false }), "deployed",
    "fence-less doc outside pi-home → deployed informative soft-skip (rule 5 — env-independent contract)");
  equal(classifyGuardLayout({ gitMarker: false, ci: false, piHomeLayout: false, docResolvable: false, fencePresent: false }), "unknown",
    "doc-less code-only archive (no git/CI/pi-home) → unknown (LOUD fail-closed)");
  // Pure boundary-compare rows for the location helper (Phase-7 ISSUE-2 — the location
  // signal is the one discriminator that separates content-identical layouts; its compare
  // must be table-tested with synthetic paths, not only exercised by the manual sim).
  equal(isUnderOrAt("/Users/x/.pi/agent", "/Users/x/.pi/agent"), true, "exact agent-home match (deployed copy agent root)");
  equal(isUnderOrAt("/Users/x/.pi/agent/extensions", "/Users/x/.pi/agent"), true, "under the agent home");
  equal(isUnderOrAt("/Users/x/.pi/agent2", "/Users/x/.pi/agent"), false, "prefix collision (~/.pi/agent2) is NOT under ~/.pi/agent");
  equal(isUnderOrAt("/Users/x/.pi/agentsibling", "/Users/x/.pi/agent"), false, "sibling name is not under the agent home");
  equal(isUnderOrAt("/Users/x/repo", "/Users/x/.pi/agent"), false, "source checkout is not under the agent home");
  // Exhaustive sweep over the 5-boolean probe tuple (32 rows). The expected-value function
  // below mirrors the 6-rule spec — see the LITERAL named rows above this sweep for the
  // binding decisions; the sweep's job is 32-row COVERAGE (classifier ↔ spec divergence on
  // the named rows is caught by the literals, not by this mirror).
  const spec = (gitMarker: boolean, ci: boolean, piHomeLayout: boolean, docResolvable: boolean, fencePresent: boolean): GuardLayout => {
    if (gitMarker) return "source";
    if (piHomeLayout) return "deployed";
    if (ci && !docResolvable) return "source";   // rule 3 — CI + doc-null (doc present ⇒ CI defers to fence state)
    if (docResolvable && fencePresent) return "source";  // rule 4 — .git-less source artifact
    if (docResolvable) return "deployed";         // rule 5 — fence-less doc (pre-#472 artifact)
    return "unknown";                              // rule 6 — code-only archive, fail-closed
  };
  let checked = 0;
  for (const gitMarker of [false, true])
  for (const ci of [false, true])
  for (const piHomeLayout of [false, true])
  for (const docResolvable of [false, true])
  for (const fencePresent of [false, true]) {
    const key = `${gitMarker ? 1 : 0}${ci ? 1 : 0}${piHomeLayout ? 1 : 0}${docResolvable ? 1 : 0}${fencePresent ? 1 : 0}`;
    const want = spec(gitMarker, ci, piHomeLayout, docResolvable, fencePresent);
    equal(classifyGuardLayout({ gitMarker, ci, piHomeLayout, docResolvable, fencePresent }), want,
      `row ${key} (git=${gitMarker}, ci=${ci}, piHome=${piHomeLayout}, doc=${docResolvable}, fence=${fencePresent}) must classify ${want}`);
    checked++;
  }
  equal(checked, 32, "all 32 probe tuples exercised");
});

test("#482 activation canary: drift-guard gate classifies an enforcement run (git marker ∥ CI env) as source and the real probe resolves the fence", () => {
  // Fires only in an ENFORCEMENT layout (git marker present, or CI env outside the pi
  // home) — never reds a legitimate deployed run. Gate: skip when NOT git AND (no CI OR
  // pi-home) — the pi-home arm covers a deployed physical copy running in a shell that
  // inherits CI=true/GITHUB_ACTIONS (classifier rule 2 classifies it deployed; the canary
  // must not contradict the guards' soft-skip — Phase-7 ISSUE-3 corner). Uses the
  // SAME real probes as the guards (probeGuardLayout), so a wiring regression that routes
  // enforcement layouts into a skip arm (silent drift-coverage death) reds here.
  // Additionally asserts the REAL probe's fence OR-arm preconditions (doc resolved AND
  // fencePresent computed true) so a doc-path or marker-string regression in the fence arm
  // is caught in every git/CI run whose doc resolves — not just by the synthetic table
  // test (enforcement layouts with NO resolvable doc log a consistency line instead — the
  // guards' doc-null arms own the red; cycle-2).
  if (!isSourceCheckout() && (!isCIEnv() || isPiHomeLayout())) {
    console.log("  ↪ canary skip (activation gate: no .git marker and no CI env outside the pi home — guards still classify by doc/fence (rules 4-6) and MAY enforce; the canary's asserts fire only on git/CI runs)");
    return;
  }
  const { layout, docText, probe } = probeGuardLayout(
    DRIFT_GUARD_05_FENCE_MARKER, // shared const — single source of truth with the 05 guard
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "../../skills/commit-workflow/workflow/05-cleanup.md",
    "skills/commit-workflow/workflow/05-cleanup.md",
  );
  // Consistency arm: reachable ONLY when the gate fired, i.e. !git AND ci AND !piHome — a
  // pi-home copy inheriting CI env is already skipped AT THE GATE (the `!isCIEnv() ||
  // isPiHomeLayout()` arm) and never reaches here, so `deployed` here can only mean rule 5
  // (CI env + resolvable FENCE-LESS doc — CI defers to the doc's fence state, R2-1). The
  // guards soft-skip in agreement — a consistency outcome, NOT a wiring failure. (Cycle-3
  // R4-2 reviewed and retained: the message is accurate for every REACHABLE state; a rule-2
  // pi-home verdict cannot reach this arm — the gate above it already skipped. Noted so
  // future refactors keep the gate above this arm.)
  if (!isSourceCheckout() && layout === "deployed") {
    console.log("  ↪ canary consistency: CI env + fence-less sibling doc classifies deployed (rule 5) — guards soft-skip in agreement; no enforcement expected");
    return;
  }
  equal(layout, "source",
    "drift-guard gate must classify THIS run as source (git marker present, or CI env + doc-null/fence-carrying doc) — a deployed/unknown verdict here means all three drift guards are not enforcing in an enforcement layout");
  // No-doc arm: an enforcement layout with NO resolvable doc (rule 3 under CI, or rule 1 in
  // a git checkout whose doc is missing) — the guards' doc-null hard-fail arms own the red
  // (already proven by equal(layout,"source") → the guard proceeds to its doc-null ok(false));
  // there is no fence to pin (canary-false-red fix, cycle-2 R1-2/R2-6/R4-F1 — the old
  // unconditional fence assert redded exactly this layout, contradicting sim C-prime).
  if (docText === null) {
    console.log("  ↪ canary consistency: enforcement layout, no resolvable sibling doc — guards' doc-null arms fail closed; fence-precondition asserts skipped (no fence exists)");
    return;
  }
  ok(probe.fencePresent === true,
    "fence OR-arm preconditions must hold when the doc resolves in an enforcement layout: the real probe must compute fencePresent=true (either the doc lost its fence — the guards' structural asserts also red it — or a path/marker/tuple-key regression silently disabled the .git-less-source-artifact arm)");
  if (isSourceCheckout() && !probe.piHomeLayout && probe.fencePresent === true) {
    // Git-removal pin (rule-4 real wiring — rule 1 would otherwise shadow it in git runs):
    // re-classify THIS run's REAL measured tuple with the .git marker removed — with the
    // doc resolved AND fenced, rules 3-5 must still route it to source via the fence arm
    // (rule 4). A probeGuardLayout tuple-key typo (tsx strips types — no typecheck catches
    // it) would make fencePresent falsy → this assert flips to unknown and REDS here.
    // Gate (cycle-2 R4-F3/F4): skip when the doc is fence-less or missing (the guards red
    // those states via their own correctly-worded arms) or the checkout lives under the pi
    // home (git-removal → rule 2 deployed — exotic dev layout; rule 1 still enforces; the
    // cycle-1 equal(isPiHomeLayout(),false) pin is DROPPED — it protected nothing rule 1
    // doesn't already guarantee for git runs; location regression coverage = isUnderOrAt
    // literal rows + sim B).
    equal(classifyGuardLayout({ ...probe, gitMarker: false }), "source",
      "removing THIS run's .git marker must still classify source via the fence OR-arm (rule 4) — real-probe wiring pin for the #482 headline layout");
  }
});
```

### U8 — Migrate the 01 drift guard's gate (L1667-1685, internals only)

Same transformation as U5 — replace the `isSourceCheckout` early-return + `resolveRepoDoc`
call with `probeGuardLayout("<!-- VGATE-SHAPE-RULE", …3 paths for 01-preflight.md…)` +
the deployed/unknown arms. ⚠️ **INCLUDED in the replaced range: the pre-resolve rationale
comment at L1668-1672** ("Enforcement runs only from an agent-infra source checkout
(isSourceCheckout — .git marker above this file). Deployed extension copies soft-skip: …") —
its claim becomes FALSE under the tri-state gate (rules 3/4 enforce from CI env and .git-less
fence-carrying artifacts; the unknown arm fail-closes). Leaving it would reintroduce the
exact code/comment silent-drift class #482 exists to eliminate, in the very file being
hardened (plan-review R1-1). Replace with the U5-style #482 comment:

```ts
  // #482: gate on the tri-state layout. .git governance is PRIMARY (rule 1 — a fence-less
  // doc in a git checkout REDS via the structural asserts below); the pi-home LOCATION rule
  // (rule 2) soft-skips deployed copies regardless of doc generation; CI + doc-unresolvable
  // fails closed (rule 3); a .git-less artifact whose sibling doc carries this guard's fence
  // enforces (rule 4); a fence-less doc soft-skips (rule 5 — cannot be drift-checked); a
  // doc-less code-only archive FAILS CLOSED (unknown, loud — rule 6).
  const vgateOpen = "<!-- VGATE-SHAPE-RULE"; // 01 fence opener — LOCAL const, sole source of truth for THIS test (the probe AND the parse extraction below share it — cycle-2 R1-F3; no module const needed: only the 01 guard consumes it)
  const { layout, docText } = probeGuardLayout(
    vgateOpen,
    "../../skills/commit-workflow/workflow/01-preflight.md",
    "../../skills/commit-workflow/workflow/01-preflight.md",
    "skills/commit-workflow/workflow/01-preflight.md",
  );
  if (layout === "deployed") { console.log(DRIFT_GUARD_SKIP_DEPLOYED); return; }
  if (layout === "unknown") { console.warn(DRIFT_GUARD_UNKNOWN_WARN); ok(false, DRIFT_GUARD_UNKNOWN_FAIL); return; }
```

⚠️ RANGE BOUNDARY (cycle-2 R4-F2; line numbers corrected cycle-3 R1-1): the replacement ends
at the `unknown` arm — the existing doc-null hard-fail arm BELOW it (01 guard L1682-1685:
`if (docText === null) { ok(false, "01-preflight.md unreachable from the agent-infra source
tree — VGATE-SHAPE-RULE drift guard would pass vacuously; restore the doc or fix the
resolution"); return; }`) is KEPT VERBATIM (no silent-return placeholder — same rationale as
U5). ⚠️ OVER-INCLUSION (cycle-3 R4-1): if your selection extends PAST the `unknown` arm into
the doc-null arm (through the closing `}` at L1685), re-include it VERBATIM — same
healthy-run-green / doc-missing-`TypeError` degradation as U5.

Replacement part 2 (micro-edit, parse opener — cycle-2 R1-F3): change the parse line
`const open = docText.indexOf("<!-- VGATE-SHAPE-RULE");` (L1688) to
`const open = docText.indexOf(vgateOpen);` — the opener literal now lives ONCE as the local
const shared by the gate's probe and the extraction, so a marker rename cannot silently
desync `fencePresent` from the parse (the triplication class R1-2 removes). The closer
search on the FOLLOWING line (L1689: `const close = docText.indexOf("<!-- /VGATE-SHAPE-RULE",
open);`) is untouched — do not edit it.

Test name, doc-null message, and the remaining parse/`deepEqual` body (L1687-1740,
content-anchored — the test closes at L1741) unchanged.

### E1 — e2e: sentinel consts + helpers (after the `sha`/`git` helpers, ~L60)

Add `dirname` to the `node:path` import, then:

```ts
// ── D1 deterministic sentinel bridge (#482) ──────────
// Fixed PASS-shaped bytes planted immediately before an exempt op so the D1 allow-only
// byte-identity assert is ordering-independent (the old null-tolerant both-absent compare
// degraded to null===null whenever prior scenarios hadn't written the bridge). Foreign
// root → inert to every recovery (index.ts drops entries whose root ≠ the worktree root),
// inert to single-slot overwrite, and no post-39 scenario reads pre-38 bridge bytes.
// ⛔ The sentinel occupies the single bridge slot from scenario 38 until scenario 41's
// first real PASS write (Leg-A) — do NOT insert a bridge-READING scenario between 38 and
// 41 without reseeding a real bridge first (Phase-7 ISSUE-6).
const D1_SENTINEL_ROOT = "/__vgate-e2e-sentinel-root__";
const D1_SENTINEL_JSON = JSON.stringify({
  status: "PASS",
  verified_files: [{ path: `${D1_SENTINEL_ROOT}::sentinel`, hash: "0123456789abcdef".repeat(4) }], // fixed 64-hex
  timestamp: "2026-01-01T00:00:00.000Z", // fixed ISO — never Date.now()
});
function seedD1Sentinel(bridgePath: string): void {
  mkdirSync(dirname(bridgePath), { recursive: true });
  writeFileSync(bridgePath, D1_SENTINEL_JSON, "utf8");
}
function assertD1BridgeUntouched(bridgePath: string, repoRoot: string, label: string): void {
  const after = existsSync(bridgePath) ? readFileSync(bridgePath, "utf8") : null;
  // Byte-identity is the PRIMARY detector (throws BEFORE the parse below — when the
  // byte-equal passes, the content IS the sentinel, so the parse loop is defense-in-depth
  // that can only ever see the sentinel's own foreign-root entry; it exists to catch a
  // FUTURE loosening of the byte check to a per-field compare). Keep the parse AFTER the
  // throwing equal — never reorder.
  equal(after, D1_SENTINEL_JSON,
    `${label} — exempt op must leave the deterministic D1 sentinel bridge byte-identical (allow-only: no verifiedSet/bridge writes)`);
  const repoReal = realpathSync(repoRoot);
  for (const vf of (JSON.parse(after as string).verified_files ?? [])) {
    const sepIdx = vf.path.indexOf("::");
    ok(sepIdx === -1 || vf.path.slice(0, sepIdx) !== repoReal,
      `${label} — no verified_files entry may be keyed under the scenario repo root (${repoReal}): ${vf.path} would survive recovery`);
  }
}
```

### E2 — Scenario 38 (L1388-1408): replace the null-tolerant snapshot with the sentinel

Replace the ENTIRE block from the pre-existing D1-snapshot rationale comment (L1388-1391 —
"D1 allow-only snapshot (taken BEFORE the commit so the check is self-contained…)" —
SUPERSEDED: the sentinel makes the check self-contained; the old comment describing the
removed snapshot-then-compare machinery is folded away with the block) through `const
bridgePath = …` (L1392) to the closing of the final `equal(existsSync…` (L1408). Do NOT
re-declare `bridgePath`; the replacement below is the whole block, `bridgePath` declared
once. Replace with:

```ts
    const bridgePath = join(TEST_ROOT, ".pi", "agent", "verification", "latest.json");
    // #482: seed the deterministic sentinel AFTER session_start and IMMEDIATELY BEFORE
    // the exempt op — byte-identity is then ordering-independent and self-contained.
    seedD1Sentinel(bridgePath);
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m docs", cwd: repo },
    });
    equal(res, undefined, "docs-only commit must be ALLOWED (content-shape exemption)");
    const audit = readAuditLines();
    ok(audit.filter((l) => l.event === "gate_skip" && l.reason === "content_shape_exempt").length > skipBefore,
       "audit must record a gate_skip with reason content_shape_exempt");
    ok(audit.filter((l) => l.event === "gate_bypass").length === bypassBefore,
       "the skip must NOT add any gate_bypass entry (allow-only, no self-bless — D1)");
    // Audit deltas alone cannot catch a self-blessing skip (a contamination regression
    // emits gate_skip, not gate_bypass) — assert the durable registry channel directly.
    assertD1BridgeUntouched(bridgePath, repo, "docs-only commit");
```

### E3 — Scenario 39 (L1430-1445): same transformation

Replace the ENTIRE block from `const bridgePath = …` (L1430) through the closing of the
final `equal(existsSync…` (L1445 — the statement closes at L1445, NOT L1444) — same
whole-block semantics as E2: re-emit the `gh pr create` fire + `equal(res, undefined)`
allow-assert (message verbatim: `docs-only gh pr create must be ALLOWED (branch diff is
all docs)`) + the audit-delta `ok(…skipBefore…)` per E2's template (the exempt op's
allow/audit coverage must NOT be dropped — only the snapshot machinery is replaced), and
PRESERVE the L1432-1433 rationale comment ("`gh pr create` is NOT merge-scoped — its diff
IS this branch's files (computeBranchDiff)…") — relocate it above the replacement, it is
the only computeBranchDiff/mechanism-(a) documentation for the create verb — with the
sentinel seed placed after `session_start` and immediately before the `gh pr create`
tool_call, closing with `assertD1BridgeUntouched(bridgePath, repo, "docs-only gh pr create")`.
Keep the mixed-branch denial leg and its asserts untouched.

### E4 — Scenario 41 Leg B (L1570-1590): real commit + exact porcelain

(a) DELETE the tautological sweep1-era assert
`ok(git(repo, "status --porcelain").includes(" M src/app.ts"), "the -a sweep did NOT commit the dirty code file (working tree still dirty)");`
(blocked `-am` can never execute → invariant). Keep the sweep1/sweep2 hook-decision pins.

(b) Replace the final block:

```ts
    equal(bare, undefined, "bare git commit -m over ONLY staged docs is exempt");
    // #482: make the allowed bare docs commit REAL (Leg-A pattern) and pin the exact
    // porcelain — the old post-block porcelain assert was tautological (a blocked -am can
    // never execute, so the tree was invariant). The real commit proves the docs exemption
    // committed README.md ONLY and left the dirty UNSTAGED src/app.ts untouched.
    git(repo, "commit -m x"); // execute the allowed docs commit for real
    equal(git(repo, "status --porcelain"), " M src/app.ts",
       "real bare docs commit must commit README.md only — porcelain exactly ' M src/app.ts' (dirty unstaged src/app.ts untouched; D2: -a sweeps and bundles never ride the docs exemption)");
  });
```

### Y1 — ci-main.yml comment refresh (L82)

`# #379 — verification-gate: the commit-gate suite (unit 173 + e2e 39)` →
`# #379 — verification-gate: the commit-gate suite (unit + e2e)`. Comment-only. The count
NUMBERS are dropped entirely — this is the second drift of a count comment (173→200;
Phase-7 ISSUE-8: any numeric comment drifts again on the next test-count change; a
numberless comment cannot). Actuals (post-change): unit 200, e2e 50 — recorded in the PR
body and this plan instead of the workflow comment.

---

## 3. Cross-cutting: gate sharing, skip-arm migration, canary

- **Where the classifier lives**: `index.test.ts`, replacing the L1644-1661 helper block —
  one `classifyGuardLayout` + one `probeGuardLayout` + `isSourceCheckout` (unchanged probe) +
  `isCIEnv` + `resolveRepoDoc` (unchanged). All are function declarations → hoisted → callable
  from the guards at L1495/L1667 regardless of source order. The message consts and
  `MERGE_DEPLOY_STEP_B_DELETE` must sit BEFORE the first guard that runs (U1/U2 cluster after
  `FULL_05_CLEANUP_BLOCK`, L1402) — `const` TDZ (guards execute at module load).
- **Skip-arm migration (behavior preservation)**:
  - Current source checkout (git marker present): every guard classifies `source` →
    enforcement runs exactly as today (doc-null hard fail + structural/`deepEqual` asserts
    unchanged) — no behavior delta. This worktree run must show NO `↪ skip` lines.
  - Current deployed layout (new test file hypothetically deployed to
    `~/.pi/agent/extensions/verification-gate/`): the pi-home LOCATION probe classifies the
    layout `deployed` for ALL THREE guards (rule 2 — the pi-home LOCATION rule — fires
    before the doc/fence and CI rules) →
    informative soft-skip regardless of doc generation — including guards 05/04 whose
    deployed docs carry fences and are byte-identical to source (verified via diff). This
    resolves the [SECOND-MODEL-GATE] P1 collision (content alone cannot separate a deployed
    fenced copy from a .git-less source artifact) and restores the ORIGINAL design intent:
    enforcement against the independently-synced deployed pair is meaningless, so the guards
    soft-skip there, always. Net: suite green in the deployed layout; every guard logs the
    deployed skip message.
  - Canonical SYMLINKED install: Node resolves the symlink in `import.meta.url` → the module
    reports the real agent-infra path → git marker present → `source` → enforcement runs
    through the "deployed" symlink against the same-generation source doc (unchanged from
    today's behavior).
  - New enforcement arms: CI env + sibling-doc-fence presence OUTSIDE the pi-home layout —
    rules 3/4 OR into `source` AFTER the pi-home location rule (rule 3 fires only when the
    doc is UNRESOLVABLE — with a doc present, CI defers to its fence state via rules 4-5,
    R2-1), so a `.git`-less CI or source artifact enforces while a deployed copy (even in a
    shell inheriting `CI=true`) soft-skips.
  - New `unknown` arm: doc unresolvable + no git + no CI + not pi-home → loud `console.warn`
    + `ok(false)` fail-closed. This is a DELIBERATE behavior change for code-only archives
    (previously silent soft-skip) per the agreed constraints. A pi-home copy with a MISSING
    sibling doc is still `deployed` (rule 2) → green, never a spurious unknown-red.
- **New 04 guard** consumes the same gate via `probeGuardLayout` with the Step B fence marker
  (U4); full-line compare anchored inside the fence so prose edits (incl. the doc-L110
  mention) never red.
- **Canary**: U7, gated `isSourceCheckout() || (isCIEnv() && !isPiHomeLayout())` (equivalently:
  skip when `!isSourceCheckout() && (!isCIEnv() || isPiHomeLayout())` — the pi-home arm covers
  a deployed copy in a shell inheriting CI env, Phase-7 ISSUE-3 corner); uses the 05 guard's
  real probe (shared `DRIFT_GUARD_05_FENCE_MARKER` const). Coverage — stated HONESTLY per
  plan-review R2-2/R4-3 (cycle 1) and refined in cycle 2 (R1-2/R2-6/R4-F1/F3/F4): in a git
  run the classifier returns `source` at rule 1 before rules 2-6 are evaluated, so the
  canary's git-run asserts are (a) `equal(layout, "source")` (rule-1 real-probe wiring),
  (b) the fence OR-arm's REAL preconditions (`probe.fencePresent === true` — doc resolved AND
  marker found; pins the tuple-key-typo class tsx cannot typecheck) — fired only when the
  doc RESOLVES; enforcement layouts with NO resolvable doc (rule-3 CI doc-null, or a git run
  whose doc is missing) log a no-doc consistency line and return, because the guards'
  doc-null hard-fail arms own that red (the cycle-1 unconditional fence assert false-redded
  exactly those layouts, contradicting sim C-prime's "canary runs and passes"); and
  (c) a **git-removal pin** — re-classifying THIS run's measured probe tuple with
  `gitMarker: false` must still yield `source` via rule 4 — CI-visible real-probe coverage
  of the #482 headline arm that rule 1 would otherwise shadow. The pin is gated on
  `isSourceCheckout() && !probe.piHomeLayout && probe.fencePresent`: fence-less/missing-doc
  git runs red through the guards' own correctly-worded arms, and an exotic agent-infra
  checkout under `~/.pi/agent` keeps enforcing via rule 1 without a false-red (cycle-2
  R4-F3/F4). The cycle-1 `equal(isPiHomeLayout(), false)` location pin (R2-3) is DROPPED — it
  protected nothing rule 1 doesn't already guarantee for git runs; location regression
  coverage lives in the pure `isUnderOrAt` rows + sim B. A CI-without-git run whose doc is
  fence-less classifies `deployed` (rule 5) — the canary logs a consistency line and returns
  (guards soft-skip in agreement; R2-1). In deployed/unknown runs it skips with an explicit
  activation-gate log line (never red). Rules 2/5/6 REAL-wiring paths remain sim-B/C-verified
  (not CI-reachable in-repo: pi-home and doc-less layouts cannot be staged from a git checkout
  — documented residual); the location decision is additionally pinned by the classifier's
  literal rows and the pure `isUnderOrAt` boundary rows (Phase-7 ISSUE-2).

---

## 4. Test-count impact

| Suite | Before | After | Delta |
|---|---|---|---|
| Unit (`grep -c '^test('`) | 197 | **200** | +3: classifier 32-row table test, activation canary, 04 drift guard |
| E2E (`grep -c 'test("'`) | 50 | **50** | 0 (scenario 41 restructured in place; T3 option 1 — no 41b split) |

Unit test names added verbatim (for the review gate):
1. `classifyGuardLayout: 32-row decision table — git → source; pi-home → deployed (beats CI/fence/doc); CI+doc-null → source fail-closed; fence-carrying doc → source; fence-less doc → deployed; doc-less → unknown`
2. `#482 activation canary: drift-guard gate classifies an enforcement run (git marker ∥ CI env) as source and the real probe resolves the fence`
3. `#482 drift guard: MERGE_DEPLOY_STEP_B_DELETE == the live 04-merge-deploy.md Step B delete line`

ci-main.yml:82 comment refresh (Y1): YES, in this PR — numbers dropped (numberless
comment `(unit + e2e)` cannot re-drift; actuals recorded in the PR body: unit 200, e2e 50).

---

## 5. Verification plan (evidence per target) + acceptance criteria

Each item names the exact evidence. Run from the worktree
(`cd extensions/verification-gate && npx tsx index.test.ts`, `npx tsx index.e2e.test.ts`).

**Common simulation recipe (A/B/C)** — plan-review R4-1 fix: the earlier per-row recipe
copied ONLY `extensions/verification-gate/`, but the unit suite loads `index.ts` →
`../shared/{health,audit-log,print-mode}` (index.ts imports; the shared modules import node
builtins only) → `ERR_MODULE_NOT_FOUND` at module load → ZERO tests execute → a crash can
masquerade as a verdict. Every sim: ① copy the import closure preserving layout
(`mkdir -p /tmp/vg482-X/extensions && cp -R extensions/verification-gate extensions/shared
/tmp/vg482-X/extensions/` — the verification-gate copy carries its own `node_modules/`
(pi-coding-agent devDep) since `cp -R` of the dir includes it) plus the `skills` copy per
row; ② run `cd /tmp/vg482-X/extensions/verification-gate && env -u CI -u GITHUB_ACTIONS npx
--no-install tsx index.test.ts` (tsx v4.23.13 resolves from the user-level npx cache —
verified cwd-independent; the env-unset pins the UNKNOWN vs rule-3 outcome, R4-2); ③
**load-sanity gate**: before reading ANY skip/UNKNOWN/red line, `grep -q "=== Results:"`
the captured output (a load crash must never be misread as a verdict); ④ `rm -rf
/tmp/vg482-X` after.

| Target | Evidence |
|---|---|
| T1 source-checkout parity | Unit suite green `200 passed, 0 failed`; output contains the classifier table test + canary `✅` lines and NO guard-skip lines (`↪ skip` / `⚠️ … UNKNOWN`) — guards enforced in this worktree. |
| T1 .git-less source artifact enforces | **/tmp simulation A** (no repo files touched): common recipe above with `cp -R extensions/verification-gate extensions/shared /tmp/vg482-A/extensions/` + `cp -R skills/commit-workflow /tmp/vg482-A/skills/`; no `.git` anywhere; NOT under the pi home → suite green with NO guard-skip lines (the canary logs its own `↪ canary skip (activation gate…)` — no git/CI — which is EXPECTED, not a guard skip: the guards still ENFORCE here via rule 4 — fence-carrying doc; only the canary's git/CI-gated asserts are inactive; cycle-2 R2-F2 log accuracy). Then mutate the copied 04-merge-deploy.md Step B delete line (`2>&1` → `2>/dev/null`) → the 04 drift guard REDS while 05/01 stay green (proves enforcement bites in a `.git`-less artifact + guard isolation). Restore → green. |
| T1 deployed layout | **/tmp simulation B** (location probe — the headline rule-2 behavior): stage the extension copy under a FAKE pi-home (`HOME=/tmp/vg482-home`, tree at `/tmp/vg482-home/.pi/agent/extensions/{verification-gate,shared}/` + `/tmp/vg482-home/.pi/agent/skills/commit-workflow/` with the REAL deployed fence-less 01-preflight.md AND the fenced 04/05 docs, no `.git`) → suite green; EVERY guard logs the deployed skip (05/04 soft-skip by LOCATION even with fenced docs — proves the P1 fix). Variant B′: same tree with 01-preflight.md ALSO fenced → still deployed skips (rule 2 beats doc generation and CI). Variant B″ (plan-review R4-4 — reverse-HOME direction): same fake-pi-home tree run with `HOME=/tmp/vg482-third` (tree present, HOME FOREIGN, no CI env) → tuple git=F, ci=F, piHome=F, doc=T, fence=T → rule 4 → `source` → the fenced 04/05 guards ENFORCE (green — copied docs match fixtures; a mutated doc would RED) while the fence-less 01 → rule 5 → deployed skip: split-brain verdicts are a TESTED decision, not an emergent one (documented residual §6(d)). |
| T1 unknown fail-closed | **/tmp simulation C**: extensions/verification-gate + shared copy ONLY (import closure — NO skills tree, no `.git`, no CI env per recipe step ②) → unit suite RED; evidence = the `⚠️ drift guard layout UNKNOWN` warn + the `ok(false)` failure (grep the red `❌`/`ok(false)` — do NOT require the UNKNOWN string alone, R4-2). **C-prime** (rule-3 arm evidence, cycle-2 canary fix verified): same doc-less tree with `CI=1` exported → suite RED via the guards' per-doc doc-null `ok(false)` messages (`…unreachable from the agent-infra source tree…`); the canary RUNS (CI outside pi-home → gate fires), `equal(layout,"source")` passes (rule 3), then it logs its no-doc consistency line (`↪ canary consistency: enforcement layout, no resolvable sibling doc…`) and returns GREEN — no false-red (cycle-2 R1-2/R2-6/R4-F1). |
| T2 sentinel determinism | e2e green `50/0`; scenarios 38/39 output the byte-identical + parse asserts; run the e2e suite twice → identical results (sentinel write makes the D1 assertions ordering-independent). |
| T3 real-commit porcelain | Scenario 41 green with the exact `equal(porcelain, " M src/app.ts")` after the REAL `git commit -m x`; the tautological sweep1 porcelain assert is gone. |
| T4 const + drift guard | Unit green incl. `#482 drift guard: MERGE_DEPLOY_STEP_B_DELETE == …` (executes in this worktree); simulation-A mutation above proves it reds on doc drift while 05/01 stay green. |
| Canary | `✅ #482 activation canary…` present in the worktree run and under `GITHUB_ACTIONS=true`; absent-as-skip in simulations A/B/C (no git/CI → logs its own skip line). |
| CI wiring | `npx tsx` runs of both files green (the ci-main.yml command shape, run locally). |

Acceptance criteria (all must hold):
1. Unit suite: `200 passed, 0 failed` in the worktree (guards + canary execute — no guard-skip lines; the canary's own log lines are expected).
2. E2E suite: `50` entries, all passing, twice in a row.
3. Simulations A/B/C prove: `.git`-less+fence artifact enforces (and reds on real doc drift),
   deployed layout (fake pi-home, fenced 04/05 docs) soft-skips informatively by LOCATION,
   code-only archive fails closed loudly.
4. `MERGE_DEPLOY_STEP_B_DELETE` used by the TRUE fixture test AND pinned by its drift guard.
5. Scenario 41 executes the allowed docs commit and asserts exact porcelain ` M src/app.ts`.
6. No production file (`index.ts`) changed; no repo `.git` state touched by any verification.
7. KNOWN OPEN GAP (rule 5, accepted, env-independent — R2-1): a `.git`-less, non-pi-home
   artifact in ANY env (CI-without-git doc-carrying runs included — rule 3 fires only for
   doc-NULL) whose 04/05 doc LOST its ceremony fence classifies `deployed` and soft-skips
   silently (a missing fence cannot be drift-checked). This is documented, not silently
   absorbed — git-governed runs (the real drift surface) still catch fence-removal via the
   guards' structural asserts.

---

## 6. Runtime prerequisites / gotchas

- **node_modules**: present in the worktree extension dir (package.json devDep
  `@earendil-works/pi-coding-agent@0.84.3`, same as CI). No network, no credentials, no `.env`.
- **const TDZ ordering** (U1/U2): the guard tests execute at module load — message consts and
  the 04 literal must be declared before L1495/L1480; classifier functions hoist, consts do
  not. This is why the const cluster lives after `FULL_05_CLEANUP_BLOCK`.
- **Sentinel byte shape**: must match the gate's own write shape (`JSON.stringify` key order
  `status → verified_files → timestamp`, no whitespace) so a human diff against a real
  bridge write is readable. `hash: "0123456789abcdef".repeat(4)` = fixed 64-hex; fixed ISO
  timestamp — never `Date.now()`.
- **e2e HOME redirection**: `process.env.HOME = TEST_ROOT` at module load; sentinel helpers
  write under `TEST_ROOT/.pi/agent/verification/latest.json` — never the real home.
- **macOS realpath**: `tmpdir()` is `/var/folders/...` → realpaths to `/private/var/...`; the
  parse-assert uses `realpathSync(repo)` on both sides, matching the gate's
  `normalizeWorktreeRoot` semantics.
- **Residual risk (documented, accepted)**: (a) the pi-home location probe depends on the
  deployed layout living under `join(homedir(), ".pi", "agent")` — if pi's agent home ever
  moves, the probe needs updating (bounded; the exact-match `===` arm covers a module tree
  AT the agent home); (b) a deployed physical copy whose guard code syncs AHEAD of its
  skills tree is still soft-skipped by location — drift there stays invisible until the copy
  runs from a source context (the ORIGINAL design intent: enforcement happens where the
  docs are edited — the repo/CI); (c) `unknown` (doc-less, no git/CI, not pi-home) now
  hard-fails where today's silent skip passed — a DELIBERATE fail-closed change for code-only
  archives (§3); (d) exotic fail-soft corner: a .git-less source tarball extracted directly
  under `~/.pi/agent/extensions/…` would classify `deployed` (silent enforcement gap), and a
  `--preserve-symlinks` Node run of a canonical symlinked install would report the symlink
  path → `deployed` instead of `source`, and an unintended `HOME` override could flip a
  `.git`-less source artifact under the override's pi-home path into `deployed`
  (git-bearing checkouts are IMMUNE — rule 1 git shadows rule 2; none occur in any current
  workflow; documented, not blocking); the REVERSE direction (plan-review R4-4): a genuine
  deployed copy (~/.pi/agent) run with HOME redirected elsewhere (outer harness/sandbox, no
  CI env) → tuple git=F, ci=F, piHome=F, doc=T: fenced 04/05 docs classify `source` (rule 4)
  → those guards ENFORCE against the deployed pair (sync skew → spurious RED) while the
  fence-less deployed 01 → `deployed` (rule 5) skip — split-brain verdicts in one run.
  Pre-#482 `isSourceCheckout()` had no HOME dependency (deployed copies soft-skipped
  unconditionally) — #482 introduces env sensitivity; expected outcome is recorded as sim
  variant B″ (§5) so the split-brain is a tested decision, not an emergent one. None occur
  in any current workflow (pi runs with the real user HOME); documented, not blocking); (e) rule 5's "fence-less → deployed" rationale is
  01-specific (VGATE-SHAPE-RULE arrived in #472): for the 04/05 guards a fence-less doc in a
  .git-less non-pi-home artifact means the ceremony block is ABSENT — fence-removal drift
  there soft-skips by rule 5 (defensible: a missing fence cannot be drift-checked, and git
  governance still catches it in the real cases; rule 5 now fires in ANY non-git non-pi-home
  context, INCLUDING CI-without-git doc-carrying runs — rule 3 requires doc-NULL (R2-1): a
  pre-#472 fence-less snapshot vendored under a CI shell soft-skips rather than reddening the
  pipeline — the correct call: uncheckable, not drift; documented). The currently deployed extension test copy is pre-#472 (no drift guards at
  all, verified: 1296 lines, no `isSourceCheckout`), so there is no live deployed enforcement
  today either way.
- **/tmp simulations** are throwaway (no repo modification): A/B/C above, cleaned up after
  verification.

## Files touched

- `extensions/verification-gate/index.test.ts` — U1-U8 (unit 197 → 200)
- `extensions/verification-gate/index.e2e.test.ts` — E1-E4 (50, unchanged count)
- `.github/workflows/ci-main.yml` — Y1 comment refresh
- this plan: `docs/plans/2026-09-05-issue-482-vgate-test-review-followup.md`

---

## Plan-review cycle log (2026-09-05)

Cycle 1 — 3 parallel fresh-context reviewers (structural, integration, failure-mode) on the
plan as scoped. Result: 1×P1 + 8×P2, ALL plan-doc issues (no design reversal), fixed above:

| ID | Sev | Finding → Fix |
|---|---|---|
| R4-1 | **P1** | Sim A/B/C recipes copy only `extensions/verification-gate/`; `index.ts` imports `../shared/*` → `ERR_MODULE_NOT_FOUND` → zero tests execute → crash masquerades as a verdict → acceptance evidence unproducible → **fixed**: common recipe (import closure `{verification-gate,shared}` + carried node_modules, `env -u CI -u GITHUB_ACTIONS`, load-sanity `=== Results:` gate) |
| R1-1 | P2 | U8 under-specifies the replaced range — L1668-1672 preamble comment ("enforcement runs only from isSourceCheckout") goes FALSE under the tri-state gate → **fixed**: comment included in U8's replaced range + replacement snippet given |
| R1-2 | P2 | `DRIFT_GUARD_05_FENCE_MARKER` claimed single-source while the 05 guard's extraction keeps a second inline copy (L1518) with divergent slicing → **fixed**: U5 reuses the const in the extraction; U1 const comment documents the `bodyStart` slicing asymmetry |
| R2-1 | P2 | Rule-3 `ci → source` fires before rule 5 → a CI+fence-less-doc tuple (vendored pre-#472 snapshot) hard-reds the structural arm, contradicting the deployed-skip contract; no literal table row pinned it → **fixed**: rule 3 restricted to `ci && !docResolvable` (doc present ⇒ CI defers to fence state); 3 new literal rows (`CI+doc+fence → source`, `CI+fence-less doc → deployed`, `CI+doc-null → source`); contract language made env-independent |
| R2-2 | P2 | Canary in git runs proves only rule 1 — §3 claim "one canary + one table test cover all three guards' decision surfaces" overstates → **fixed**: honest coverage statement + canary consistency arm (CI+fence-less → deployed logs and returns) |
| R2-3 | P2 | `isPiHomeLayout` two-hop URL/realpath plumbing untested in any standard run → **fixed**: canary pins `equal(isPiHomeLayout(), false)` in git runs (guarded comment) |
| R4-2 | P2 | Sim C's UNKNOWN evidence fires only without CI env; a shell exporting CI/GITHUB_ACTIONS yields rule-3 doc-null reds instead → **fixed**: env-unset in the recipe + evidence greps the red; C-prime variant (CI=1 → doc-null reds) exercises rule 3 |
| R4-3 | P2 | Rule-4 real-probe wiring is CI-invisible (rule 1 shadows it; sim A manual-only) → **fixed**: canary git-removal pin (re-classify measured probe tuple with `gitMarker:false` → must stay `source`) + `probeGuardLayout` returns the probe tuple; committed-sim-script option documented as future work, not adopted (scope: test files only) |
| R4-4 | P2 | Reverse-HOME direction (genuine deployed copy + redirected HOME → rules 4/5 split-brain) undocumented → **fixed**: §6(d) residual + sim variant B″ recording the expected outcome |

Cycle 1 exit: P1 fixed, 8×P2 fixed in-plan. Re-review (cycle 2) dispatched fresh.

**Cycle 2** — 3 fresh reviewers on the revised plan. Result: 2×P1 + 4×P2, all plan-doc issues
(no design reversal), fixed above:

| ID | Sev | Finding → Fix |
|---|---|---|
| R1-2 / R2-6 / R4-F1 (dedup) | **P1** | Canary false-reds rule-3 (CI+doc-null) enforcement layouts: the unconditional fence-precondition assert `ok(docText !== null && fencePresent === true)` fails on `docText === null` after `equal(layout,"source")` passes — contradicted sim C-prime's "canary runs and passes" → **fixed**: no-doc consistency arm (log + return when `docText === null`; the guards' doc-null arms own the red) before the fence assert, which now fires only on resolvable docs; C-prime evidence wording corrected |
| R4-F2 | **P1** | U5/U8 snippets end with a `if (docText === null) { /* unchanged */ return; }` placeholder — pasted beside the KEPT real doc-null arm, the silent-return fires first and DEAD-CODES the `ok(false)` hard-fail → doc-null passes vacuously (fail-open in the layout #482 must hard-fail); also inverts sim C-prime evidence → **fixed**: placeholders removed from both snippets; explicit RANGE BOUNDARY notes (replacement ends at the `unknown` arm; keep the doc-null arms verbatim — 05 L1512-1515, 01 L1682-1685 — citations corrected cycle-3) |
| R1-F2 | P2 | U6 preamble + U5 replacement comment overstate the CI arm ("CI env present → enforcement") vs the R2-1-restricted rule 3 (needs doc-null) — the code/comment drift class #482 exists to kill, in new comments → **fixed**: both comments carry the doc-resolvability qualifier |
| R1-F3 | P2 | U8 introduces a second inline copy of the 01 fence opener (probe arg + parse `indexOf`) → **fixed**: local `const vgateOpen` shared by probe and parse (part-2 micro-edit swaps the parse line) |
| R4-F3 | P2 | Canary git-removal pin/fence assert misattribute doc-missing/fence-less git-run states to wiring regressions (guards already red those with correct messages) → **fixed**: no-doc arm returns before the pins; git-removal pin gated on `probe.fencePresent === true`; fence-assert message names both readings (doc-drift OR regression) |
| R4-F4 | P2 | `equal(isPiHomeLayout(), false)` + git-removal pin false-red an exotic legit layout (agent-infra cloned under `~/.pi/agent` — rule 1 still enforces; location pin protects nothing rule 1 doesn't already guarantee for git runs) → **fixed**: location pin DROPPED (cycle-1 R2-3 superseded; regression coverage = `isUnderOrAt` rows + sim B); pin block gated on `!probe.piHomeLayout` |
| R2-F2 | P2 | Canary skip log labels sim A — the #482 headline enforcement layout — "deployed/unknown run" (wrong diagnosis in the exact layout T1 exists to enforce) → **fixed**: skip log describes the activation GATE, not the layout verdict; sim-A evidence row updated |

Cycle-2 exit: 2×P1 + 4×P2 fixed in-plan. Re-review (cycle 3) dispatched fresh.

**Cycle 3** — 2 fresh reviewers (structural/integration + failure-mode) on the revised plan.
Result: 0×P0/P1, 3×P2 — two real, one declined-with-reason:

| ID | Sev | Finding → Disposition |
|---|---|---|
| R1-1 | P2 | RANGE BOUNDARY notes + U8 part-2 carry off-by-one baseline citations (05 arm is L1512-1515 not L1511-1514; 01 arm L1682-1685 not L1683-1686; parse opener L1688 — "~L1689" points at the PROTECTED closer-search line) → **fixed**: three citations corrected to the verified baseline; part-2 now names the closer line explicitly as untouched |
| R4-1 | P2 | Boundary notes cover only under-inclusion (placeholder); OVER-inclusion (selection swallows the kept doc-null arm) ships green in healthy runs and degrades doc-missing runs to a bare `TypeError` → **fixed**: over-inclusion warning added to both U5/U8 notes |
| R4-2 | P2 | Consistency-arm log attributes rule 5 / "fence-less" for all deployed verdicts — claimed wrong for the pi-home-inherited-CI corner → **DECLINED**: the canary gate (`!isSourceCheckout() && (!isCIEnv() || isPiHomeLayout())` → skip) already returns pi-home+CI runs BEFORE the consistency arm, so `deployed` there is reachable only via rule 5 and the message is accurate for every reachable state; added a reachability note to the arm's comment so future refactors keep the gate above it |

Cycle-3 exit: real findings fixed, one declined with documented reasoning. Re-review (cycle 4)
dispatched fresh for final verification.
