---
title: "Plan: #254 skill-lint frontmatter YAML validation — dep-free state-aware validator + oracle lock"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-28
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-254, check-skill-lint
---

<!-- research-path: Library-deps axis (Phase 1.5) — 3 external queries (gray-matter/opencode #24181 fail-silent precedent; posit-dev/frontmatter fail-strict camp; remark-frontmatter "linter must share the loader's grammar"; pitfalls: Node has no stdlib YAML, JSON-subset restriction is a trap) + exhaustive local empirical probing of pi's installed yaml-2.9.0 (30+ classes, re-verified across 4 problem-verify rounds + 2 solution-verify rounds + second-model gate). Behavior ground truth: pi v0.84.3 bundle; probe transcripts reproduced by scripts/probe-frontmatter-fixtures.mjs. -->

# Issue #254 — Skill-lint frontmatter YAML validation: tokenizer + rule engine + oracle lock

> **For Pi:** Use `executing-plans` to implement this plan task-by-task. Tasks are TDD (Red → Green → Refactor); each task's test-first step is explicit.

**Goal:** Make `scripts/check-skill-lint.mjs` detect every enumerated pi-loader frontmatter error class with zero false positives on the live 121-file corpus, dep-free (O/I (1): works without js-yaml; O/I (3): no new npm dependencies), verified by a dev-machine oracle that imports pi's real `parseFrontmatter`/`loadSkillsFromDir`.

**Team:** organisation-design-team
**Worktree:** `.worktrees/issue-254` (branch `feat/254-skill-lint-yaml`)
**Related issues:** #359 (consumer propagation, soft dep), #360 (pi parse-failure observability), #361 (pi ` #` truncation observability)

---

## 1. Problem statement (confirmed, after 4 problem-verify cycles + solution-verify)

`check-skill-lint.mjs`'s frontmatter validation implements a different grammar than pi's loader, and CI verdicts drift in both directions. Three concrete divergences: **(1) extraction** — the linter uses `indexOf('---', 3)` + `slice(3)` + `.trim()` with no BOM/CRLF normalization; pi uses `stripBom` + CRLF normalize + `indexOf('\n---', 3)` + `slice(4, endIndex)` with no trim (verified in pi's `dist/utils/frontmatter.js`). **(2) fallback** — agent-infra is dep-free (no `node_modules`), so the `js-yaml` dynamic import always fails and the live production path is a regex *presence check* (`^name:` / `^description:` only) that cannot detect any YAML error class: files pi's loader rejects (unquoted `: ` in a description → "Nested mappings are not allowed in compact mappings", duplicate keys, unbalanced quotes, tab indentation, unresolved aliases, multi-doc, reserved-character value starts, block-sequence-after-key, non-string descriptions…) pass CI and silently drop the skill in pi (the #242 incident: `planning/shared/research/SKILL.md` shipped broken, CI green, skill dead). **(3) a third grammar** — `findDuplicateKeys` is a separate hand-rolled regex scanner (misses quoted keys, keys in flow, keys inside block scalars). The fix: mirror pi's extraction exactly, replace the regex fallback with a quote/flow/block-state-aware validator over the enumerated error-class corpus, fold dup-key detection into it, add a key-scoped string-type gate (description/name must parse to a non-empty string — mirrors pi's `hasDescription`), and lock fidelity with a probe-derived fixture matrix plus a dev-machine oracle test that imports pi's real bundle.

---

## 2. Approach decision (solution-converge)

### Decision: **B + C** — two-layer validator (tokenizer + stateless rule engine) packaged as a shared module with dual test harnesses (CI fixture-regression + dev-machine oracle).

| Criterion | Why B+C wins |
|---|---|
| **Outcome quality** | The deliverable is behavioral fidelity to pi's yaml-2.9.0 *net consequence* across ~14 rule classes covering ~30 error variants, ~2 truncate classes, ~20 never-flag classes. In B, each class is one declarative rule that mirrors one yaml error message ("Nested mappings are not allowed in compact mappings" ↔ `throw-unquoted-colon-value`); a reviewer audits the rule table against the enumerated corpus as a checklist. In A, the same classes are branches in one dense state machine — the failure mode that *caused* this issue (a hand-rolled grammar nobody can audit) scales with every new branch. |
| **Edge-case handling** | B localizes ALL state (quotes, flow, block scalars, indentation, list generations) in the tokenizer — one place, testable with token-level golden tests (feed text → assert token stream). Rule bugs are separately testable (feed tokens → assert findings). In A, a state bug and a verdict bug are entangled in one function. |
| **Failure-mode coverage** | B's layer boundary is a test seam: tokenizer bugs → wrong tokens → caught by golden tests; rule bugs → wrong findings → caught by fixture tests; both → caught by the oracle's net-consequence parity. |
| **Future extensibility** | The corpus will grow (pi evolves yaml; new classes get discovered). In B, a new class = a new rule + fixtures — no state-transition surgery. |
| **Auditability** | The rule table IS the documentation: one entry per enumerated class, each citing the pi behavior it mirrors. |

**Novelty note:** no prior art exists for a dep-free lint that mirrors a loader's YAML grammar without a parser dependency (Phase 1.5: Flint requires a parser dep; remark-frontmatter parses but does not validate; remark-lint-frontmatter-schema validates post-parse against JSON Schema). The hand-rolled tokenizer + oracle lock is therefore a novel approach — justified precisely because dep-free is a hard constraint and the oracle provides the fidelity mechanism vendoring would otherwise buy. **Pre-commit hook alternative (review-gate addition):** the repo's husky v9 infra (.husky/pre-commit) plus pi's importable bundle make an authoring-time hook viable — see Task 0. The original E-rejection ("fail-closed + thin regex") attacks the CI-side regex fallback; a pi-importing authoring hook is a different, viable option now included as Task 0, not absorbed into the rejected list.

**Mitigations for B's real risks:**
- *Token vocabulary is a new abstraction* → the vocabulary is **bounded and specified** in §5.1 (the complete list, 17 token types). It is scoped to the enumerated corpus, not a general YAML tokenizer — matching the re-scoped zero-drift target (fix 3). No invented grammar during implementation.
- *Two places to get wrong* → token golden tests (layer 1) + rule fixture tests (layer 2) + oracle net-consequence parity (both layers) — three independent nets.
- *More code than A* → accepted per quality-over-convenience; the extra lines are the declarative rules and their tests, which are the audit surface.

### Rejected alternatives (with "when this WOULD have been better")

- **A — single-pass state machine in parseFrontmatter.** Would be better when: the corpus were small and static, the validator were a throwaway, and the team wanted the smallest file set with the fastest path to green. It fails the extensibility and auditability criteria that matter for a permanent CI gate on a moving corpus. A's one genuine insight — a single scan is the only source of truth — is preserved in B (the tokenizer is that single scan; rules are pure consumers).
- **D — vendored YAML parser.** Would be better when: dep-free were relaxed (it is a hard constraint) — and even then, a vendored *subset* re-creates the same drift at a different layer and still needs the oracle to prove fidelity. Non-viable under the hard constraint.
- **E — fail-closed + thin regex.** Would be better when: the O/I target were only "CI fails on a missing script" (it is not — the core target is detecting throw-classes, which a presence regex cannot). Non-viable against O/I (1)(2); its one useful idea (fail-closed flip, fix 7) ships in this plan regardless.

### Synthesis notes

- **C is orthogonal and mandatory**: the fix-points (3) (4) (8) require a shared validator module, a probe-derived fixture matrix, and a dev oracle — so the converged design is literally "B internals + C wiring". The shared module (`scripts/frontmatter-validate.mjs`) is imported by the linter CLI, the CI regression test, and the oracle test — one grammar, three consumers, no test-only copy drift.
- **Share-loader-grammar principle** (opencode #24181 precedent — invalid frontmatter silently ignored by a tool's parser): embodied here as the extraction mirror + oracle net-consequence parity. Divergence was validated empirically against pi's installed bundle rather than via generic research — the empirical probes ARE the evidence trail (reproducible via `scripts/probe-frontmatter-fixtures.mjs`).
- **Probe-derived facts already verified on this machine** (pi v0.84.3, yaml 2.9.0 — used to pin fixture expectations and rule boundaries; the fixture-generation task re-derives and commits them):
  - `description: foo: bar` and `description: foo:` → **throw** "Nested mappings are not allowed in compact mappings" (colon+space or colon-at-EOL in a plain VALUE span). `foo:bar` (no space) → OK. `https://` → OK. Bare `key:` (empty value, e.g. `steps:`) → OK.
  - `description: foo\n  bar: baz` (colon in a multi-line plain continuation) → **throw**; `description: foo\n  continued here` → OK (folded plain).
  - Unbalanced single/double quotes → **throw** ("Missing closing 'quote"); `''`-doubling → OK; a blank line inside a double-quoted scalar terminates it → **throw**; backslash escapes in double quotes must not close the quote.
  - Duplicate keys, including quoted (`"name"` vs `name`) → **throw** "Map keys must be unique".
  - Tab as indentation → **throw** "Tabs are not allowed as indentation"; tab mid-value → OK.
  - `description: *nope` (unresolved alias) → **throw**; `description: &empty` (empty anchor) → parses to `null` → skill **dropped** by the string gate (not a parse throw).
  - `...` followed by content inside the frontmatter → **throw** "Source contains multiple documents"; EOF `...` → OK.
  - `description: @x`, `` description: `x ``, `%foo` at value start or line start → **throw** reserved/directive indicator; `foo @ bar` mid-value → OK; `%YAML`/`%TAG` directives → OK.
  - `description: {a: b}` (closed flow as entire value) → parses to an object → **dropped** by the string gate (no parse throw); `description: {a: b` (unclosed) → **throw**; `description: {a: b} trailing` and `description: "x" trailing` → **throw** "Unexpected scalar at node end"; `foo {a: b} bar` mid-scalar → **throw** (nested mapping).
  - `description: foo\n- item` → **throw** "Implicit keys need to be on a single line"; the col-0 `- item` **state persists across blank and comment lines**; an *indented* seq under a key (`steps:\n  - a`) → OK.
  - Root block seq alone (`- item1\n- item2`) → parses to an **array** → dropped by the string gate; root seq **followed by** root keys → **throw**.
  - `description: |` with nothing after → empty string → **dropped** by the string gate; block scalars with `: `/` #` content → OK (opaque).
  - String-type gate (mirrors pi `hasDescription = typeof description === "string" && description.trim() !== ""`): `null`, `~`, `true/false`, numbers, flow collections, nested maps (`description:\n  key: val`), block seqs, empty `""`, whitespace-only `"   "`, empty block scalar, alias-resolved-to-non-string → all resolve non-string/empty → pi **drops** the skill. `2026-08-28` → **stays a string** (yaml core schema has no timestamp resolution). `name: 42` → name non-string → pi falls back to the directory name (loads) — the linter flags it per writing-skills schema (safe-direction divergence, register).
  - Extraction: `\n---` anchor (an *indented* `  ---` line inside the frontmatter does NOT terminate extraction — it folds into a plain scalar); BOM and CRLF are normalized; missing closing `---` → pi returns `{frontmatter: {}}` → skill **dropped** silently; `---abc` opening line → the `abc` lands inside the yamlString → bare-key throw; `---\n---` → empty yamlString → `parse('')` → `null` → `{}` → dropped.

---

## 3. Proposed solution — architecture and files

### 3.1 File inventory

| File | Action | Role |
|---|---|---|
| `scripts/frontmatter-validate.mjs` | NEW | Shared validator module. Dep-free, node-18. Exports `extractFrontmatter`, `tokenizeFrontmatter`, `evaluateTokens`, `validateFrontmatter`, `ERROR_CLASSES` (const list for tests). |
| `scripts/check-skill-lint.mjs` | REFACTOR | CLI: file discovery, dir resolution, schema checks (allowed-tools, name≠dir + `shared-<dir>` exemption, forbidden-prompt), findings → issues, exit 0/1/2. **Removes** the js-yaml dynamic import, the regex-presence fallback, and `findDuplicateKeys` (folded into the validator). |
| `scripts/frontmatter-fixtures.mjs` | NEW | Probe-derived fixture matrix — `FIXTURES = [{id, class, content, expected}]` with committed net-consequence records (incl. pi diagnostics where relevant) + `PI_VERSION_PIN`. Imported by both test files. |
| `scripts/check-skill-lint.test.mjs` | NEW | CI fixture-regression test (node:assert harness, ✅/❌ markers, tmp-dir integration, 121-tree sweep). No pi import. |
| `scripts/check-skill-lint.oracle.test.mjs` | NEW | Dev-machine oracle test — imports pi's bundle (`dist/bundle/index.js`), golden net-consequence parity on fixtures + live corpus, version pin, diagnostics capture. NOT wired into CI. |
| `scripts/probe-frontmatter-fixtures.mjs` | NEW | Probe runner that (re)generates the committed `expected` records in `frontmatter-fixtures.mjs` (explicit `--write`; the oracle's drift output points here). Records pi's net consequence AND diagnostics list. |
| `.github/workflows/ci-main.yml` | EDIT | extension-tests job: explicit line running `scripts/check-skill-lint.test.mjs`. |
| `.github/workflows/node-ci.yml` + `templates/.github/workflows/node-ci.yml` | EDIT | skill-lint job fail-open → fail-closed (missing script → job FAILS). Template + materialized copy in the same PR; then `scripts/sync-ci-workflows.sh`. Consumer blast radius tracked by **#359**. |
| `scripts/cron-quality-gates.sh` | EDIT | New `oracle` subcommand (case-dispatch + load gate + usage doc). |
| `docs/upstream-pi-bugs.md` | EDIT | Two draft entries: **#360** (missing/empty description → skill dropped; pi emits an un-surfaced `description is required` warning diagnostic — the surfacing gap is #360's scope) and **#361** (unquoted ` #` in plain-scalar values silently truncates with zero diagnostic; rule recorded verbatim incl. whitespace-precedence). |
| `docs/ci-centralization-plan.md` | EDIT | node-ci section: skill-lint is now fail-closed on missing script (deliberate breaking change, tracked by #359); all other node-ci jobs still skip gracefully with ⚠️ — the doc's "skip gracefully" claim is scoped to non-gate jobs. |
| `.husky/pre-commit` | EDIT | Task 0: staged-SKILL.md frontmatter check via pi's bundle (dev machines). |
| `templates/launchd/com.eldato.skill-lint-oracle.plist` | NEW | Task 10 drift-watch: launchd schedule for the oracle (renders via install-launchd.sh — filename follows the repo's label-from-filename convention, matching the hub/canary templates; hard-fail if script target unresolved). |
| `scripts/patch-pi-retry.sh` | EDIT | Task 10 drift-watch: re-probe precondition — pi version change without a successful oracle re-probe → loud failure. |
| `docs/plans/2026-08-28-issue-254-skill-lint-yaml.md` | NEW | This plan. |
| Issue #254 | EDIT | Scoping comment re-scopes the target ("on the enumerated, oracle-tested corpus"); O/I wording amended in the body. |

### 3.2 Key design decisions

**D1 — Extraction mirror (fix 1).** `extractFrontmatter(content)` reproduces pi's `dist/utils/frontmatter.js` exactly: `stripBom` → CRLF/LF normalize (`\r\n`→`\n`, then `\r`→`\n`) → `startsWith("---")` gate → `indexOf("\n---", 3)` → missing ⇒ `{yamlString: null, body}` → else `yamlString = slice(4, endIndex)` (**no trim** — pi does not trim) and `body = slice(endIndex + 4).trim()`. The linter keeps its P0 checks for missing opening / missing closing / empty frontmatter (pi's net consequence for all three is `{frontmatter: {}}` → skill dropped → same verdict direction, safe-divergence; fix 6).

**D2 — Two-layer internals (B).** `tokenizeFrontmatter(yamlString) → tokens[]` owns ALL state (see §5.1). `evaluateTokens(tokens) → findings[]` is a table of stateless rules, one per enumerated class, each a pure function `(tokens, idx, ctx) → finding | null`. The tokenizer is the only stateful pass; rules are pure pattern matching. Findings are `{class, field, line, message, severity}`. **js-yaml is removed deliberately**: js-yaml is a DIFFERENT YAML implementation than pi's `yaml` package (2.9.0) — keeping an optional js-yaml fast-path would reintroduce a third grammar (the same argument that justifies folding findDuplicateKeys); fidelity is owned solely by the validator + oracle lock.

**D3 — Severity + exit contract.** THROW-classes and the string-type gate → **P0** (pi drops the skill → the skill is dead). TRUNCATE-classes → **P1** (pi loads but silently corrupts the value). Any finding (P0 or P1) → exit 1, preserving the current "any issue fails" contract; the severity label aids triage. A validator internal error → `validator-internal-error` **P0** (fail-closed: a validator bug turns CI red, never silently green).

**D4 — String-type gate (fix 9, key-scoped to name/description).** Mirrors pi's `loadSkillFromFile`: `hasDescription = typeof description === "string" && description.trim() !== ""`; `name` used only when `typeof name === "string"`. The gate runs on the tokenizer's value-mode + a **mini core-schema resolver** for plain values (§5.2). Distinct messages: `gate-description-nonstring` (drop — P0), `gate-name-nonstring` (pi falls back to dir name — linter stricter per writing-skills schema; safe-direction, register), `gate-name-empty` (string but `trim() === ''` — same fallback, safe-direction, register).

**D5 — Quote-aware name/description extraction (fix 9).** The linter's name≠dir and description checks consume `data.name` / `data.description` produced by the validator from TOKENIZER values — quoted values are unquoted (incl. `''`-doubling resolution), flow/block/nested-map values are typed, so `name: "foo"` no longer yields `"\"foo\""` (the current regex fallback's false-positive class).

**D6 — Dup-key folding (fix 5).** `findDuplicateKeys` is deleted. The tokenizer emits KEY tokens with `(indent, generation, quoted)`; the dup-key rule flags same-name collisions within one `(indent, generation)` — generation bumps per block list item (the existing indent-aware scheme), quote-aware (quoted `"name"` collides with `name` — probe-confirmed yaml behavior), flow/block-scalar-blind (KEY tokens exist only outside flow and block bodies).

**D7 — Unknown-construct policy (fix 3).** Recognized-throw → P0; recognized-safe → pass; unrecognized plain-scalar content → pass; fail-closed ONLY when validation cannot run (extraction failure or internal error → P0). The tokenizer never throws on unknown constructs — it emits `VALUE_PLAIN` and the rules pass them. TOKENIZE_ERROR is reserved for constructs that are *definite* parse errors (unbalanced quotes, unclosed flow at value position, tab-as-indentation).

**D8 — Acknowledged-drift register.** Documented in §5.4 and carried into the validator's header comment:
- (a) missing opening/closing/empty frontmatter → explicit P0 where pi silently returns `{}` (same net verdict, better message);
- (b) name non-string / empty-string → P0 where pi falls back to dir name (writing-skills schema strictness);
- (c) `\n---` frontmatter-shape continuation in the body → P1 authoring warning where pi ignores body `---` entirely (acceptance 0/121 — no corpus file exercises it; oracle verdict on synthetic fixtures; register fallback if undecidable);
- (d) **resolved alias into description resolving to non-string/empty → P0 `gate-description-nonstring`** (SAFE DIRECTION, consistent with D3 and oracle parity — pi resolves the anchor, the string gate drops the skill; the linter must not pass what pi drops); alias into name resolving to non-string/empty → `gate-name-nonstring`/`gate-name-empty` (D4 semantics).

**D9 — Fail-closed flip (fix 7) + dir-level decision.** `node-ci.yml` + `templates/.github/workflows/node-ci.yml` skill-lint jobs flip to: missing script → `exit 1` (job FAILS). **Dir-level decision:** keep exit-0 when no skills dir is *implicitly* resolved (the reusable workflow runs on consumer repos that may have no skills tree — flipping would break every consumer); flip **explicit** `--skills-dir <path>` pointing at a missing dir → exit 2 (script error). Documented in the script help. **Consumer impact of the flip (repos syncing the new template without `scripts/check-skill-lint.mjs` will fail node-ci) is a deliberate, stated breaking change — propagation to consumer repos (eldato, tortoise, worktrees) is tracked by issue #359 (soft dependency, can ship separately).**

**D10 — Trust model.** CI trusts the committed probe records (`frontmatter-fixtures.mjs`); the dev oracle re-derives them from live pi on every run and fails on drift or version mismatch. The live-corpus sweep runs in BOTH tests: CI asserts zero findings; the oracle asserts per-file net-consequence parity — together, on **agent-infra's 121-tree + the enumerated corpus**: CI guarantees no false positives, the oracle guarantees no false negatives. Consumer corpora are a separate population — **Task 10 (e) adds a consumer-sweep leg** (when tortoise/eldato checkouts exist on the dev machine, sweep their skills trees; divergence fails the oracle; absent checkouts are a documented skip). The template + materialized fail-closed flip ships in THIS PR (Task 11); **#359 gates CONSUMER adoption of the new template (propagation + consumer-corpus validation), not the flip itself** — consistent with D9's "soft dependency, can ship separately".

**D11 — BOM policy (review-gate addition).** All PINNED pi loader paths (v0.84.3) strip BOM — the only skill-file loader `loadSkillFromFile` calls `parseFrontmatter` → `extractFrontmatter` → `stripBom` (oracle-verified: `loadSkillsFromDir` LOADS a BOM'd SKILL.md on the node-fs path). Env/session-path BOM behavior is bundle-version-dependent (some bundle variants parse without stripBom; observed drop on one variant, load on others — conflicting evidence across probe sessions, not resolvable against a single pin). The linter does NOT silently strip BOM: a BOM'd SKILL.md is flagged **P0 authoring error** (`bom-prefixed-frontmatter`) — a **deliberate safe-direction strictness** (a BOM'd skill file is an authoring accident; authors should save without BOM), NOT a mirror of any guaranteed pi drop on the pinned version. **Placement (normative): `validateFrontmatter` checks the RAW content (`charCodeAt(0) === 0xFEFF`) BEFORE calling `extractFrontmatter`, emits `bom-prefixed-frontmatter` P0, then CONTINUES validating the BOM-stripped content (report all findings — no short-circuit). The extraction mirror's stripBom applies only to non-flagged content and to the oracle's extraction-parity comparison.** Any future pi version with a non-stripping path is caught by the version-pin gate + re-probe precondition (Task 10). **The BOM fixture is excluded from Task 10 (c) extraction parity** (pi's `parseFrontmatter` strips BOM, so extraction parity would trivially match while verdicts legitimately diverge — extraction parity covers only the non-flagged extraction-edge fixtures).

**D12 — Oracle reference selection (review-gate addition).** Fixture parity and live-corpus parity execute through `loadSkillsFromDir` on materialized tmp skill trees — exercising pi's real `hasDescription` gate + name fallback + drop semantics — NOT a locally reimplemented copy of the gate (a reimplementation would be a second hand-rolled grammar). Extraction parity additionally compares against the exported `parseFrontmatter` (BOM fixture excluded per D11). **Fixture relation field (normative): each fixture record carries `expectedRelation: "drop" | "load" | "load-with-truncation" | "ack-drift-flagged"`; the oracle asserts the validator verdict against the committed `expected` AND pi's recorded consequence against the committed consequence, treating `ack-drift-flagged` as a green, documented divergence (used for R2 name-gate and R5 BOM fixtures, where pi's node-fs path LOADS while the linter flags P0 — D12's strict "P0 ⇒ pi drops" mapping applies only to non-ack-drift fixtures).** Truncate-class parity semantics (explicit): a P1 truncate finding must correspond to pi loading the file with a truncated value; a validator P0 must correspond to pi dropping the file (or `ack-drift-flagged`); a validator pass must correspond to pi loading the file intact (or loading with truncation only when the validator emitted the matching P1). **Shadowed-file relation: a validator pass on a pi-skipped (shadowed) file is vacuously consistent; a finding on a skipped file is reported as an over-flag candidate for triage, not a parity failure.**

---

## 4. Implementation tasks (TDD — each is Red → Green → Refactor)

> Parallelization: T1 → T2 is sequential (the tokenizer consumes extraction). T3–T6 are mutually orderable; **T7 depends on T3–T6** (its composition-contract tests assert throw findings, truncate findings, string-gate data, and dup-key behavior); T8 can START in parallel with T2–T7 (its probe script only needs extraction) and must `--write` its records before T9; T9 depends on T8 + T3–T7; T10 depends on T8 + T7. T0, T11, T12 are independent.

### Task 0 — Authoring-time pre-commit hook (review-gate addition, prevents the #242 incident class at the source)

**Intent:** catch throw-classes at the authoring moment (the #242 failure arrived via an author commit, not CI). Uses existing husky v9 infra (.husky/pre-commit) + pi's importable bundle — the same PI resolution as the oracle. Dev-machine only; the CI gate remains the dep-free validator.
**Implementation:** `.husky/pre-commit` step (or a script it calls, e.g. `scripts/check-staged-skill-frontmatter.mjs`): for each staged `**/SKILL.md`, import pi's `dist/bundle/index.js` (same resolution as T10), run `parseFrontmatter` (bundle export — note `hasDescription` is NOT exported; reimplement pi's gate using the D4 formula verbatim: `typeof description === "string" && description.trim() !== ""`, from `skills.js:232`), exit 1 on any throw/drop with a clear message ("quote your description; pi will drop this skill"), **and flag a leading U+FEFF on the raw staged content (same check as D11)**. Skips cleanly with a visible SKIP if pi is not installed (local hook — a missing local pi must not block commits). **Verdict scope (stated explicitly): the hook gates only throw/drop-via-description classes + BOM; the truncate P1 class (` #`), name-gate classes (R2), and other validator rules are CI's job — a hook pass is NOT a CI pass.**
**Acceptance:** committing a deliberately-broken SKILL.md (unquoted `: `, missing description, BOM) with pi installed → blocked; committing a clean file → passes; no pi → visible SKIP, commit proceeds.

### Task 1 — Extraction mirror (fix 1)

**Intent:** `extractFrontmatter` behaves identically to pi's `dist/utils/frontmatter.js` extraction on every edge.
**Red (test-first):** Fixtures asserting: BOM prefix stripped; CRLF and lone-CR normalized; opening `---abc` (trailing content on the opener); *indented* `  ---` mid-frontmatter does NOT terminate extraction (folds into the scalar); `\n---` terminates; no-trim yamlString; missing closing → `{yamlString: null}`; `---\n---` → empty string; second `---` block in the body is body, not frontmatter.
**Green:** Implement in `scripts/frontmatter-validate.mjs` per D1.
**Refactor:** Keep pure; no side effects; export for the oracle to compare against pi's extraction output directly.

### Task 2 — Tokenizer + state machine (quotes/flow/block)

**Intent:** The single stateful pass producing the token stream for layer 2. Token golden tests pin every transition edge.
**Red (test-first):** Token-level golden tests (feed text → assert token stream):
- plain `key: value` → KEY + VALUE_PLAIN; `key:` alone → KEY + VALUE_EMPTY; `key:\n  a: b` → KEY + VALUE_NESTED.
- quoted: `'it''s fine'` → VALUE_QUOTED(single, `it's fine`); `"a: b # c"` → VALUE_QUOTED(double, `a: b # c`); `"a\"b"` → escape does not close; unclosed quote → TOKENIZE_ERROR(quote); blank line inside a double-quoted scalar → TOKENIZE_ERROR(quote) (continuation must be indented — probe-confirmed); quote spanning lines → one VALUE_QUOTED.
- block: `|`/`>`/`|-`/`|+`/`>+`/`>-` headers → VALUE_BLOCK_HEADER + opaque VALUE_BLOCK_BODY (content with `: `/` #` NOT tokenized); empty block scalar → header with no body; dedent out of a block body → next structural token.
- flow: `description: {a: b}` → VALUE_FLOW; `description: [a, b]` → VALUE_FLOW; unclosed `{a: b` → TOKENIZE_ERROR(flow); mid-scalar flow `foo {a: b} bar` → VALUE_PLAIN with an inline `flowRegions[{start, end, kind}]` annotation.
- structure: LIST_ITEM bumps generation; KEY carries `(indent, generation, quoted)`; blank/comment lines are preserved as tokens (rules need them for state-persistence checks); `...` → DOC_MARKER; `&a`/`*a` → ANCHOR/ALIAS; leading tab before content → TOKENIZE_ERROR(tab); tab mid-line → plain content.
**Green:** Implement the scanner with the §5.1 state model.
**Refactor:** Token vocabulary constants exported; no verdicts in this layer.

### Task 3 — Throw-class rules

**Intent:** Every enumerated THROW-class emits a P0 finding; never-flag OK-classes emit nothing. Quote/flow/tab classes CONSUME layer-1 TOKENIZE_ERROR tokens (assert the mapping — do not re-derive state in the rules layer).
**Red (test-first):** One fixture per class (asserting the exact class id), plus one never-flag fixture per OK-class:
THROW: `throw-unquoted-colon-value` (`description: foo: bar`; `description: a: b:c`; multi-line continuation `foo\n  bar: baz`), `throw-colon-at-eol-value` (`description: foo:`), `throw-unbalanced-quote` (single, double, blank-line-inside-quote), `throw-unclosed-flow` (value position), `throw-tab-indent`, `throw-reserved-char-start` (`@`, backtick, `%` at value/line start; NOT mid-value), `throw-bare-key` (`foo` alone at root/key indent; `---abc` opener), `throw-multi-doc` (`...` + content; NOT EOF `...`), `throw-block-seq-inline` (`description: foo\n- item`), `throw-seq-state-persists` (blank/comment line between valued key and `- item`), `throw-root-seq-before-keys` (`- item\nname: test`), `throw-unresolved-alias` (`*nope`; NOT `&a`/`*a` pair), `throw-flow-map-mid-scalar` (`foo {a: b} bar`), `throw-multiple-tokens` (`{a: b} trailing`, `"x" trailing`).
OK (never-flag): `://`; closed flow as ENTIRE value on non-desc/name keys; block scalars (incl. with `: `/` #` inside); quoted `: `/` #`; anchors; apostrophes; unspaced colons in values (`foo:bar`); trailing spaces; mid-value tabs; `-42` (parse-OK; gate handles); `-item` mid-scalar; brackets mid-scalar; `2026-08-28`; merge keys not applied; nested block map on non-desc keys; indented block seqs under keys; full-line comments; `%YAML`/`%TAG` directives; `[key]: v` flow key.
**Green:** Implement the rule table entries for these classes.
**Refactor:** Each rule a small named function; rules table is a flat array, greppable.

### Task 4 — Truncate-class rules

**Intent:** P1 detection of silent value corruption pi tolerates.
**Red (test-first):** `truncate-unquoted-hash`: `description: foo # bar` → P1 (pi loads `"foo"`); NOT flagged: full-line comments, quoted ` #`, block-scalar bodies, ` #` mid-flow. `truncate-fm-continuation`: body containing a `\n---` line outside ``` fences → P1; ```-fenced `---` and no-fence-clean bodies → pass (acceptance 0/121 — register per D8(c)).
**Green:** Implement both rules. **Whitespace-precedence fixtures:** `foo#bar` → PASS (no space before #), `foo #bar` → flag P1 (space before #), `https://a#b`-adjacent → PASS (no whitespace); record the exact rule verbatim in the #361 draft (yaml semantics: ` #` preceded by whitespace starts a comment).
**Refactor:** Register D8(c) note in the validator header.

### Task 5 — String-type gate (fix 9)

**Intent:** key-scoped P0 mirroring pi's `hasDescription`/name fallback with distinct messages.
**Red (test-first):** `description` resolving to null/`~`/empty, `true/false`, `42`/`-42`/`1e3`, `{a: b}` flow, `[a, b]` flow, `""`, `"   "`, empty block scalar, nested map (`description:\n  key: val`), block seq (`description:\n  - a`), **alias-resolved-to-non-string (`a: &x 42` + `description: *x`)**, **absent `description:` key entirely → P0 (the canonical pi drop class — `frontmatter.description === undefined` → `hasDescription` false → skill null)**, **absent `name:` key → `gate-name-*` per R2 (pi falls back to dir name)** → `gate-description-nonstring` P0. `name: 42` → `gate-name-nonstring` P0. `name: ""` → `gate-name-empty` P0. Strings that must PASS: `2026-08-28`, `https://x.com/a`, `foo:bar` (plain, unspaced colon), quoted `"foo"`, `'it''s fine'`, block scalar with content, `l'intention`, `foo @ bar`, **`0b101`, `190:20:30`, `1:20:30.5`, `1_000` ARE strings (yaml-2.9.0 core schema — probe-confirmed; do NOT classify as int/float); `yes`/`no`/`on`/`off`/`y`/`n` ARE strings (YAML 1.2 core schema — do NOT treat 1.1 bool spellings as bools)**. Non-string gate cases: `42`, `-42`, `1e3`, `0123` (→123 decimal), `0x1A`, `0o17`, `.inf`, `.nan`, `true`/`false`/`TRUE`, `null`/`Null`/`~`.
**Green:** Implement the gate with the mini core-schema resolver (D4, §5.2).
**Refactor:** Resolver table extracted as a small pure function with its own unit cases.

### Task 6 — Dup-key folding (fix 5)

**Intent:** Replace `findDuplicateKeys` — same-mapping detection, quote/flow/block-aware.
**Red (test-first):** `name: x` twice → P0 `dup-key`; quoted `"name"` + `name` → P0 (probe-confirmed collision); same key at different indents → pass; same key across list elements (`- a: 1\n- a: 2`) → pass; keys inside flow (`{a: 1, a: 2}` — yaml's own flow dup check) → covered by throw (probe-verify; map to `dup-key` if yaml throws); keys inside block scalars → pass; `steps:` repeated under distinct list elements → pass.
**Green:** Implement the dup-key rule over KEY tokens.
**Refactor:** Delete `findDuplicateKeys` from `check-skill-lint.mjs`.

### Task 7 — Validator composition + linter CLI refactor (fix 9 wiring)

**Intent:** `validateFrontmatter(content)` composes extract → tokenize → evaluate → derive `data`; the CLI consumes it.
**Red (test-first):** Composition contract: clean file → `{ok: true, data: {name, description, …}}` with quote-aware values (`name: "foo"` → `data.name === 'foo'`); throw-class file → `{ok: false, findings: [P0…]}`; truncate-only file → `{ok: true, findings: [P1…]}` — `ok: true` means "validation completed without internal error, data derivable" (NOT "no findings"); P1 findings still drive exit 1 per D3; internal error path → `{ok: false, findings: [validator-internal-error P0]}`. CLI contract (tmp-dir integration): deliberately-broken skills dir → exit 1 with `[P0] frontmatter:` lines; truncation-only tree → exit 1 with `[P1]` lines; `--skills-dir <missing>` → exit 2; no dir implicitly → exit 0.
**Green:** Implement composition + CLI refactor; remove js-yaml import and regex fallback.
**Refactor:** `run()` seam (deps injection) matching the load-gate.test.mjs pattern for the CLI contract tests.

### Task 8 — Fixture matrix generation (probe-derived)

**Intent:** `scripts/frontmatter-fixtures.mjs` holds the committed, oracle-recorded matrix.
**Implementation:** `scripts/probe-frontmatter-fixtures.mjs` imports pi's bundle (same PI resolution as the oracle test), runs every fixture content through **`loadSkillsFromDir` on materialized tmp skill trees** (pi's real gate — `hasDescription` + name fallback + drop semantics; never a locally reimplemented copy) and records the net consequence + pi's diagnostics list; `--write` writes `FIXTURES` (with `expected` + `PI_VERSION_PIN`) into the fixture module. The matrix covers: every THROW class, every TRUNCATE class, every string-gate variant (int forms `[+-]?\d+`/`0x`/`0o`/`0123`-decimal/exponent/`.inf`/`.nan`; string forms `0b`/sexagesimal/underscore-groups/comma-numbers/dates; 1.1-bool-spellings-are-strings), **absent-key cases (no `description:` key → drop; no `name:` key → dir-name fallback)**, every OK/never-flag class, extraction edges (BOM/CRLF/anchors/indented-`---`/`---abc`/missing-closing/`---\n---`), **BOM'd-file case (validator verdict P0 `bom-prefixed-frontmatter` per D11; pi node-fs consequence = LOADS — R5 ack-drift-flagged)**, the O/I case (`unquoted colon-space description`), deliberately-broken composites, and multi-class files. **Each record carries `expectedRelation` per D12 (drop/load/load-with-truncation/ack-drift-flagged).** **Env-path BOM pin (comment in `frontmatter-fixtures.mjs`):** the oracle exercises only the node-fs path (`loadSkillsFromDir`, strips BOM); env/session-path BOM behavior is bundle-version-dependent (conflicting evidence across probe sessions) — the R5 safe-direction rationale does NOT depend on it, and the probe optionally asserts the bundle's env-path source (grep for a non-stripping parse variant, analogous to the version pin) so the dependency is drift-checked.
**Acceptance:** Running the probe with no `--write` reports zero mismatches against the committed records; `--write` produces a reviewable diff (records + version pin).

### Task 9 — CI fixture-regression test (fix 8)

**Intent:** `scripts/check-skill-lint.test.mjs` — the CI gate. Repo-convention harness (node:assert, custom `test()` with ✅/❌, `process.exit(1)` on failure, tmp-dir fixtures via `fs.mkdtempSync`; ✅/❌ + assert markers per the repo scripts-test convention — note `scripts/*.test.mjs` are NOT covered by the cron mutation gate, which scans only `extensions/*/test.mjs`; the markers are required by convention and by the Task 9 mutation-survival spot check).
**Coverage:** (a) every fixture's verdict class matches `expected` (validator-only, no pi); (b) every OK-class fixture yields zero findings; (c) the deliberately-broken fixtures MUST FAIL (assert exit 1 + P0 class); (d) O/I case exact fixture → P0 `throw-unquoted-colon-value`; (e) extraction-edge fixtures; (f) name≠dir with quoted-name regression; (g) **121-tree sweep**: run the validator over `skills/` → assert ZERO findings (zero false positives). Assertion markers present (mutation-gate grep convention).
**Acceptance:** `node scripts/check-skill-lint.test.mjs` green on the full 121-tree; mutation-survival check: deleting any rule leaves a red test.

### Task 10 — Dev oracle test + cron subcommand (fix 4)

**Intent:** `scripts/check-skill-lint.oracle.test.mjs` — the drift lock, dev-machine only.
**Implementation:** PI resolution precedence (glob per patch-pi-retry.sh precedent — the real layout has a `node-v*` component): `PI_NODE_ROOT` (default `$HOME/.local/share/pi-node`) → `"$PI_NODE_ROOT"/node-v*/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/index.js` → realpath; else `PI_NODE_BIN` → `$(dirname $PI_NODE_BIN)/../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/index.js`; else `command -v pi` → realpath → same derivation (precedents: `patch-pi-retry.sh:77-82`, `install-launchd.sh`). **Standardize on `dist/bundle/index.js`** (the diverge-doc-verified entry; `dist/index.js` also exists but bundle is the production binary's library entry — no `main()` side effects; if the bundle path vanishes in a pi upgrade and only `dist/index.js` survives → hard-fail exit 2 with a re-probe message, never silently fall back). Hard-fail on pi-not-found / binary-relocated (exit 2) and on `VERSION !== PI_VERSION_PIN` (exit 1 — pi version drift; re-probe deliberately, never soft-skip). Golden checks: (a) fixture parity — for every fixture, validator verdict classes + derived data vs pi's live net consequence, executed via **`loadSkillsFromDir` on materialized tmp skill trees** (pi's real gate) + diagnostics; (b) live-corpus parity — for every file in `skills/`, validator verdict vs pi's net consequence, with **pi's loaded set computed shadowing-aware** (a directory with its own SKILL.md shadows nested SKILL.md files — a general loader semantic, not a hardcoded 3-file exclusion list); files pi skips are reported as over-flag candidates, not silently excluded; (c) extraction parity — `extractFrontmatter` output vs pi's exported `parseFrontmatter` extraction on the extraction-edge fixtures (BOM fixture excluded per D11); (d) **adversarial fuzz leg (review-gate addition)** — a deterministic generator producing random frontmatter variants (quote/flow/indent/block-scalar combinations) with a **committed fixed seed (`FUZZ_SEED = 254` in `frontmatter-fixtures.mjs`, overridable via `--seed`) and a bounded iteration count (N=1000, wall-time noted)** run through both linter and pi with divergence counted; divergence is REPORTED + fails the oracle with the candidate case surfaced via the oracle test's explicit **`--write-append` path** (inserts the surfaced case into `frontmatter-fixtures.mjs` with a user-supplied `expectedRelation`, then `--write` regenerates; alternative documented procedure: copy the case into the probe's fixture list, run probe `--write`, re-run oracle) — consistent with T8's reviewable-diff discipline, never auto-append; (e) **consumer sweep (review-gate addition)** — when tortoise/eldato checkouts exist on the dev machine, sweep their `skills/` trees (validator verdict vs pi net consequence); **divergences are REPORTED + written to a committed disposition register (e.g. `consumer-sweep-register.mjs`), NOT exit-1 — consumer corpora are a separate population with no zero-false-positive guarantee, and fixing them is #359's propagation work; the sweep is a report-only pre-warning until #359 merges**; absent checkouts are a documented skip. Blocking legs remain the enumerated fixtures + 121-tree + fuzz. **Checkout currency:** the oracle verifies the dev checkout is current (`git rev-parse HEAD` vs `origin/main`, or fetch `skills/` fresh) before trusting the live-corpus parity — a stale checkout would give parity against a stale corpus. (f) **staleness warning (review-gate addition — no such logic exists in cron-quality-gates.sh today): `arch`/`mutation` subcommands gain a `last-oracle-run` staleness check — stale → warn + exit 0 (visible without its own schedule).** **Cron:** `scripts/cron-quality-gates.sh` gains `oracle` subcommand (case-dispatch, `load_gate_entry` preflight, usage text; exit 0 clean / 1 drift / 2 environment / 3 deferred). **Drift-watch (INSTALLED, not just documented):** (i) install the launchd plist for the oracle in this PR (`templates/launchd/oracle.plist` → install-launchd.sh); (ii) hard-wire a re-probe precondition into pi-update paths (`scripts/patch-pi-retry.sh` and any version-bump path): pi version change without a successful oracle re-probe → loud failure; (iii) persist a `last-oracle-run` timestamp file consumed by the T10 (f) staleness warnings. exit 1 (drift, incl. version mismatch) or exit 2 (pi not found / environment) alerts (session-postmortem/log surface) and blocks until re-probed.
**Acceptance:** `node scripts/check-skill-lint.oracle.test.mjs` and `scripts/cron-quality-gates.sh oracle` green on the dev machine; deleting a rule fails the oracle; scheduling + owner documented.

### Task 11 — CI wiring (fixes 7–8)

**Intent:** The gate is wired and fail-closed.
**Implementation:** (a) `ci-main.yml` extension-tests: insert `echo "== scripts/check-skill-lint.test.mjs =="` + `node scripts/check-skill-lint.test.mjs || failures=$((failures+1))` between the ci-ref-check line and the extensions glob loop. (b) `templates/.github/workflows/node-ci.yml` skill-lint job: replace the skip-else with `exit 1` ("missing required gate — FAILING"); `cp` via `scripts/sync-ci-workflows.sh` to `.github/workflows/node-ci.yml` (workflow-drift job enforces template/materialized parity in the same PR). (c) The existing `ci-main.yml` skill-lint job already runs fail-closed (`node scripts/check-skill-lint.mjs --skills-dir skills`) — unchanged.
**Acceptance:** `git diff` shows both copies flipped; `scripts/sync-ci-workflows.sh` is a no-op afterwards (idempotent parity); `node scripts/ci-ref-check.test.mjs` still green; #359 referenced for the consumer-breaking-change propagation.

### Task 12 — Docs + issue write-back

**Intent:** Plan, O/I amendment, upstream drafts — the record is complete.
**Implementation:** (a) This plan is committed at `docs/plans/2026-08-28-issue-254-skill-lint-yaml.md`. (b) Issue #254: scoping comment re-scopes the target ("zero drift ON THE ENUMERATED, ORACLE-TESTED CORPUS; unknown-construct policy: recognized-throw→P0, recognized-safe→pass, unrecognized plain-scalar→pass, fail-closed only when validation can't run") and the body's Targets line is amended to match. (c) `docs/upstream-pi-bugs.md`: **two** draft entries — **#360**: missing/empty description → skill dropped; pi emits an un-surfaced `description is required` warning diagnostic for declared skills (the surfacing gap, not the detection, is #360's scope); **#361**: unquoted ` #` in plain-scalar values silently truncates with zero diagnostic (yaml parses fine per spec; the corruption is author-invisible). agent-infra's linter now flags both (P1 for ` #` truncation / P0 for missing description) as the safe-direction guard.
**Acceptance:** Docs committed; issue comment + body amendment posted; upstream draft entries present; #359/#360/#361 cross-referenced.

---

## 5. Design details (normative for implementation)

### 5.1 Tokenizer state model and token vocabulary

**State struct** (one per scan): `{ quote: {kind, startLine} | null, flowStack: [{kind, line}], blockScalar: {headerLine, indent, chomp} | null, keyIndent: -1, listGen: 0, activeListIndent: -1, lastValueSameLine: bool, docMarkerPending: bool, seenRootKey: bool, seenRootListItem: bool }`. Blank/comment lines never reset pending quote/flow/block state — they are emitted as tokens and rules use them (Task 3's state-persistence fixtures).

**Token vocabulary (bounded — the complete list):**
`DOC_MARKER(line)` · `KEY(name, indent, generation, quoted, line)` · `KEY_ONLY(line, indent)` · `VALUE_PLAIN(lines, indent, line, flowRegions[])` · `VALUE_QUOTED(kind, content, line)` · `VALUE_BLOCK_HEADER(chomp, indent, line)` · `VALUE_BLOCK_BODY(lines, indent)` · `VALUE_FLOW(kind, line)` · `VALUE_ALIAS(name, line)` · `VALUE_EMPTY(indent, line)` · `VALUE_NESTED(indent, line)` · `LIST_ITEM(indent, line)` · `ANCHOR(name, line)` · `COMMENT(line)` · `BLANK(line)` · `TOKENIZE_ERROR(kind, line, detail)`.

**Rule table** (layer 2, one entry per class): §2's probe-derived mapping, §3.2 D2–D8. Rules consume token runs; `TOKENIZE_ERROR` tokens map 1:1 to quote/flow/tab throw-classes (rules assert the mapping, never re-derive state); `KEY` runs feed the dup-key rule; KEY+VALUE pairs feed the string gate and quote-aware extraction.

### 5.2 Mini core-schema resolver (string-type gate)

Plain-value resolution table (yaml-2.9.0 core schema scalars, probe-confirmed against pi's bundle). Non-string: `null|Null|NULL|~|""`; `true|false|True|False|TRUE|FALSE`; int forms `[+-]?\d+`, `0x…` (hex), `0o…` (octal), leading-zero decimal (`0123` → 123); float forms decimal (`….\d…`), exponent (`1e3`), `.inf|.Inf|.INF`, `.nan|.NaN|.NAN`. **Everything else → string**, including: ISO dates (`2026-08-28`, timestamps — core schema has no timestamp resolution), **YAML 1.1 bool spellings (`yes|no|on|off|y|n` — these ARE strings in 1.2 core schema; do NOT add them as bools)**, **`0b…` binary (`0b101` → "0b101" string), sexagesimal (`190:20:30`, `1:20:30.5` → strings), underscore groups (`1_000` → "1_000" string), comma numbers (`1,000,000`)**, `v1.2.3`, `50% off`. Quoted → string (content trimmed for the `!== ''` check). Flow collection / nested map / block seq / empty block scalar / **alias-resolved-to-non-string-or-empty (safe direction — P0 gate, register R4)** → non-string or empty per §2 probe table.

### 5.3 Extraction mirror (normative spec)

```js
const normalizeNewlines = (v) => v.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
const stripBom = (v) => (v.charCodeAt(0) === 0xFEFF ? v.slice(1) : v);
// if !normalized.startsWith("---") → {yamlString: null, body: normalized}
// endIndex = normalized.indexOf("\n---", 3); if -1 → {yamlString: null, body: normalized}
// yamlString = normalized.slice(4, endIndex)          // NO trim
// body = normalized.slice(endIndex + 4).trim()
```
Linter P0 additions (safe-direction, fix 6): `yamlString === null` with `startsWith('---')` → missing closing; `!startsWith('---')` → missing opening; `yamlString === ''` → empty frontmatter; **raw content starting with U+FEFF → `bom-prefixed-frontmatter` (D11 — raised BEFORE extraction on the raw content; validation continues on the stripped content)**.

### 5.4 Acknowledged-drift register (fix 3 fallback)

| # | Construct | Linter verdict | pi net consequence | Rationale |
|---|---|---|---|---|
| R1 | Missing opening/closing `---`; empty frontmatter | P0 (explicit) | silent `{}` → skill dropped | Same net verdict; better message (fix 6) |
| R2 | `name` non-string / empty-string / **absent** | P0 (distinct message) | falls back to dir name, loads | writing-skills schema strictness (safe direction); absent-name is ack-drift-flagged (D12 — linter flags, pi loads with dir fallback) |
| R3 | `\n---` continuation in body (outside ``` fences) | P1 authoring warning | ignored (body) | acceptance 0/121; oracle verdict on synthetic fixtures |
| R4 | Resolved alias into **description** resolving to non-string/empty | **P0 `gate-description-nonstring`** | pi resolves the anchor → string gate drops the skill | **SAFE DIRECTION** — linter must not pass what pi drops; consistent with D3 + oracle parity. Alias resolving into **name** to non-string/empty → `gate-name-nonstring`/`gate-name-empty` (D4 semantics — pi dir-name fallback, safe-direction strictness) |
| R5 | BOM-prefixed SKILL.md | **P0 `bom-prefixed-frontmatter`** | all pinned pi loader paths strip BOM (node-fs LOADS — oracle-verified); env-path behavior version-dependent | **SAFE-DIRECTION authoring strictness (D11)**: flag rather than silently strip; NOT a mirror of a guaranteed pi drop on the pinned version — future non-stripping paths caught by version-pin + re-probe |

---

## 6. Testing strategy

**CI fixture-regression test** (`scripts/check-skill-lint.test.mjs`, no pi):
- Fixture → expected verdict per class (all THROW/TRUNCATE/gate/dup classes; assert exact class ids).
- OK-class fixtures → zero findings (the never-flag list is the zero-false-positive contract).
- Deliberately-broken fixtures that MUST FAIL (including the exact O/I case).
- Extraction-edge fixtures (BOM/CRLF/anchors/`---abc`/indented-`---`/missing-closing/empty).
- CLI integration in a tmp-dir: broken tree → exit 1; explicit missing `--skills-dir` → exit 2; implicit no-dir → exit 0.
- **121-tree sweep**: run the validator over `skills/` → assert zero findings (zero false positives). Corpus files with oracle-confirmed true positives (e.g. an unquoted ` #` in a description — pi truncates it today) are FIXED in this PR (quote the value; oracle-verified), never papered over. **Execution note:** the fixture-regression test runs post-merge only (ci-main is `on: push: branches: [main]`); pre-merge, the node-ci skill-lint job runs the refactored CLI over the 121-tree. This matches the ci-ref-check precedent — the O/I-case fixture verdicts are exercised post-merge + dev-machine, which is convention-consistent (stated as a decision, not an accident).

**Dev oracle test** (`scripts/check-skill-lint.oracle.test.mjs`, dev machine / cron only):
- Fixture net-consequence parity: validator verdict + derived data vs pi's live net consequence, executed via **`loadSkillsFromDir` on materialized tmp skill trees** (pi's real gate — `parseFrontmatter` alone is parse-only; the string-gate/drop live in the loader) + diagnostics per fixture; `expectedRelation` per D12 (drop/load/load-with-truncation/ack-drift-flagged).
- Live-corpus parity: every file in `skills/` — validator verdict vs pi net consequence, with pi's loaded set computed shadowing-aware (the 3 post-deploy-verify nested skills are the concrete instance of the general shadowing semantic — computed, never a hardcoded exclusion; surfaced as over-flag candidates if flagged). This is the zero-drift-on-corpus guarantee. **Checkout-currency verified** (git rev-parse HEAD vs origin/main) before trusting the parity.
- Extraction parity vs pi's `parseFrontmatter` extraction on extraction-edge fixtures (BOM fixture excluded per D11).
- **Adversarial fuzz leg** (FUZZ_SEED=254, N=1000, deterministic; divergence → report + fail + manual `--write-append` triage per Task 10 (d)).
- **Consumer sweep** (tortoise/eldato when checkouts exist; report + disposition register, NOT exit-1 — per Task 10 (e) and #359 sequencing).
- Version pin: `VERSION` from the bundle vs `PI_VERSION_PIN`; mismatch → exit 1 (re-probe deliberately, never soft-skip). pi-not-found → exit 2 (loud environment failure).
- **Drift-watch**: INSTALLED (not just documented): launchd plist for the oracle in this PR; re-probe precondition in `patch-pi-retry.sh`; `last-oracle-run` staleness warning added to `arch`/`mutation` cron subcommands (Task 10 (f) — no such logic exists today). Drift (exit 1) or environment (exit 2) alerts and blocks until re-probed.

---

## 7. Verification plan (prove it works)

1. `node scripts/check-skill-lint.test.mjs` → all sections ✅, exit 0 (fixture verdicts + O/I case + broken-tree exits + 121-tree sweep zero findings).
2. `node scripts/check-skill-lint.mjs --skills-dir skills` → `121 SKILL.md files checked. 0 issue(s). Clean.` exit 0.
3. Dev machine: `node scripts/check-skill-lint.oracle.test.mjs` → fixture parity (incl. expectedRelation + ack-drift) + live-corpus parity + extraction parity + version pin green (pi v0.84.3 / yaml 2.9.0); fuzz leg run and any surfaced divergences triaged via `--write-append` to zero open divergences; consumer sweep reported + register updated (or documented skip).
4. `scripts/cron-quality-gates.sh oracle` → exit 0.
5. CI analog locally: replay the ci-main extension-tests step body (`failures=0; node scripts/check-skill-lint.test.mjs || failures=$((failures+1)); …`); replay the node-ci skill-lint job body with `--skills-dir skills`; simulate the missing-script branch (`[ -f missing ] || exit 1`) → exit 1 (fail-closed proven).
6. `scripts/sync-ci-workflows.sh` → idempotent no-op; `git diff` shows template and materialized copies flipped identically; `node scripts/ci-ref-check.test.mjs` green (workflows touched).
7. Mutation spot-checks: comment out one rule → its fixture fails red (no silent-pass); delete the oracle version pin → oracle fails.
8. **Hook proof-of-work:** stage a deliberately-broken SKILL.md (unquoted `: `, missing description, BOM) → commit BLOCKED; clean file → passes; `command -v pi` hidden → visible SKIP, commit proceeds.
9. **Drift-watch proof-of-work:** `launchctl list | grep oracle` → plist present; `scripts/cron-quality-gates.sh oracle` → exit 0; `last-oracle-run` timestamp file updated; stale-warning path exercised by faking an old timestamp.
10. commit-workflow full gate: typecheck + tests + review loop per repo process.

---

## 8. Acceptance criteria (map to O/I)

- **[O/I (1)]** `description: unquoted colon space` → P0 `throw-unquoted-colon-value` with **no js-yaml installed** (validator dep-free; js-yaml import deleted) — pinned by the O/I-case fixture and the tmp-dir broken-tree integration test.
- **[O/I (2)]** A tree containing such a file fails: `node scripts/check-skill-lint.mjs --skills-dir <broken>` → exit 1; the ci-main skill-lint job (already fail-closed) runs the same validator on `skills/`; the new `check-skill-lint.test.mjs` line runs in extension-tests.
- **[O/I (3)]** `package.json` untouched — zero npm dependencies added; validator runs on node ≥ 18 (engines preserved).
- **[Targets, re-scoped]** 100% of the ENUMERATED throw-classes produce a finding (fixture verdict parity, CI + oracle); zero false positives on the 121-file corpus (CI sweep zero findings; oracle confirms those zero findings are not false negatives); zero drift between linter verdict and pi-loader behavior on the enumerated, oracle-tested corpus (oracle parity green on fixtures + live corpus with the version pin).
- **[fixes 1,5,6,7,8,9]** extraction mirrors pi (extraction-edge fixtures + extraction parity); dup keys incl. quoted flagged; missing-closing-`---` stays P0; node-ci.yml + template fail-closed in the same PR (drift gate green); test wired into ci-main.yml extension-tests; quote-aware name/description extraction (quoted-name ≠ dir regression pinned).
- **Fail-closed semantics:** validator internal error → P0 (CI turns red, never silently green); pi-not-found in the oracle → exit 2; version mismatch → exit 1.
- **Complexity tier note:** the deliverable is a partial YAML-grammar reimplementation, but the issue's "standard" rating is defensible because each of the 12 tasks is individually micro/standard-sized with explicit test-first steps — the tier governs proportional gates, not the total work volume.

---

## 9. Runtime prerequisites

- **Node ≥ 18** (repo `engines`; CI node 22). `.mjs` ESM, no build step.
- **pi only for the oracle leg + Task 0 pre-commit hook** (dev machine / cron): resolved via `PI_NODE_ROOT` (default `$HOME/.local/share/pi-node`) glob `node-v*/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/index.js` / `PI_NODE_BIN` / `command -v pi` (patch-pi-retry.sh precedent); exports `parseFrontmatter`, `loadSkillsFromDir`, `VERSION` — verified on this machine.
- **No `npm install`, no new dependencies** — the validator is pure Node stdlib (fs/path/assert in tests only).
- Corpus invariants relied on: 121 SKILL.md files; zero block-scalar descriptions in the live tree today (block-scalar gate/OK fixtures are synthetic); no unquoted ` #` in live plain values (sweep verifies; any true positive is fixed, not waived); nested SKILL.md files under a dir with its own SKILL.md are shadowed by pi's loader (computed in the oracle's loaded-set parity, not a hardcoded exclusion).
