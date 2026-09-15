# Plan — #1035: infra-verify fail-closed checks

<!-- research-path: docs/plans/2026-09-14-issue-1035-infra-verify-fail-closed.md -->
<!-- plan-review: cycles=8, status=clean, version=2.3.0 -->

**Issue:** #1035 (`complexity:standard`, `Level: task` → `task-workflow-standard`)
**Branch:** `fix/1035-infra-verify-fail-closed`
**Base:** `origin/main` @ `02b50eb`
**Tier:** standard → Low-Medium review (2 reviewers)
**Domain:** (not adversarial)

---

## Scope — Confirmed Problem

`skills/post-deploy-verify/infra-verify/SKILL.md` defines four inline checks. Two misreport, and
their "green" is vacuous:

1. **`template-validity` is inverted.** It globs `templates/*.{yaml,yml,json,md}` and requires a
   JSON/YAML parse. `templates/AGENTS.base.md` is markdown with no frontmatter, so it can never parse
   → `errors++` on *every* run. Verified: exits 1 on clean `main`. `templates/.mcp.base.json` — a
   schema-bearing template — is never matched, because shell `*.json` does not match dotfiles.
2. **`script-validate` validates 1 of 25.** One `node --check` with every path as argv; Node checks
   only the first. Verified on Node v22.23.2: `node --check good.mjs bad.mjs` → exit 0;
   `node --check bad.mjs` → exit 1. Reports `pass`. This repo matches **25** (`scripts/*.{mjs,cjs,js}`
   = 24 + `bin/agent-infra.js`).
3. **Vacuous pass.** An empty match set leaves `errors=0` → `[ 0 -eq 0 ]` → `pass`.
4. **(found during scoping)** The `script-validate` *offer* detection is itself vacuous —
   `ls scripts/*.mjs … 2>/dev/null | head -1 >/dev/null && CHECKS+=()` takes the pipeline status from
   `head` (always 0), masking `ls`'s failure. Reproduced → `OFFERED` in an empty dir.
5. **`skill-lint` is vacuously passable.** With no / an *existing-but-empty* / an `_`-prefixed-only
   skills tree, the linter's implicit-resolution miss exits 0 → `pass` while linting 0 skills.
   Verified: `--skills-dir /tmp/emptyskills` → `0 SKILL.md files checked. Clean.` exit 0.

### Alternative problem framings

| Framing | Assessment |
|---|---|
| **A. "The skill's documented commands do not do what the skill claims" (chosen)** | Covers defects 1–5. |
| B. "Delete the checks; defer to CI" | Rejected: CI covers scripts/workflows, but `.mcp.base.json` parseability + the session-time verdict are the skill's own contract. |
| C. "The real defect is that nothing executes the inline blocks" | Real but a *mechanism* limitation: the commands are wrong first (reproduced). Handled under Outcome-quality. |
| D. "Offer a check only when it has something to validate" | Adopted as the offer-gate (Task 1). |

### Assumptions (validated)

| Assumption | Evidence |
|---|---|
| Checks live inline in the skill; no separate script | `grep -rn template-validity` → `code-review/SKILL.md` (vocabulary) + this skill. |
| `templates/.mcp.base.json` exists | `ls -la templates/` (2040 bytes; hidden by plain `ls`). |
| `node --check` ignores trailing argv | reproduced, Node v22.23.2. |
| `find -name '*.json'` matches dotfiles; shell glob does not | `find templates -maxdepth 1 … -name '*.json'` → the dotfile. |
| Offer-detection is itself vacuous | `ls <empty-dir>/*.mjs … \| head -1 >/dev/null && echo OFFERED` → `OFFERED`. |
| CI's `script-validate` is per-file | `node-ci.yml`: `for f in scripts/*.{cjs,mjs,js} bin/*.js; do [ -f "$f" ] \|\| continue; node --check "$f"`. |
| CI topology | `ci.yml` `on: pull_request` → `node-ci.yml@main` (per-PR `script-validate` + `actionlint`); `ci-main.yml` is post-merge. |
| Template workflow YAML validated elsewhere | `check-workflow-actionlint.sh` default scope includes `templates/.github/workflows/*.yml` (**workflow YAML only**, docker-gated, CI). |
| Template plists validated elsewhere | `install-launchd.test.sh` §`plutil -lint`. |
| Interpreter availability | `node` required by the skill already; **PyYAML/python3 NOT guaranteed** (CI needs `pip install pyyaml`). |
| `skill-lint` resolution | resolves **`operations/skills` → `.agents/skills` → `skills`**; `findSkillFiles` skips `_`/`.`-prefixed entries **recursively**; explicit missing `--skills-dir` → exit 2; implicit miss → exit 0; self-reports `N SKILL.md files checked`. |
| Router JSON tolerance | router documents top-level `status: pass\|fail\|skip\|error`, per-check `{name,status,error?,screenshot?,duration_ms}`, evidence `{type: screenshot\|log, path, description}`; no code deterministically parses it. |
| `.md` templates carry no frontmatter | `head -5` of the 3 `.md` files under `templates/` — prose, no `---`. |
| Bash version | local bash **3.2.57**: no `mapfile`; `read -r -d ''`, process substitution, `shopt -s nullglob` work. |
| `find` on a missing dir / symlinked start point | BSD `find templates` (missing) → stderr + non-zero; `find` does **not** follow a symlinked start point, but `find templates/` (trailing slash) does. |

### Solution approaches (solution-diverge)

| # | Approach | Outcome quality | Failure modes | Enforcement |
|---|---|---|---|---|
| **1** | **Inline rewrite** — offer-gate on non-empty target set; JSON via `node`, YAML via PyYAML; per-file loops; every check fails closed on empty set / missing tooling / malformed input. | Green states exactly what was validated (`validated X/N`); no partial or tooling-degraded green. | Empty → fail; missing tooling → actionable fail; malformed → fail naming every offender. | In the file the agent executes — no resolution dependency. |
| 2 | Extract `scripts/…` + suite + **CI wiring**. | Same verdicts. Resolution dependency (`scripts/` is an agent-infra symlink in consumers — #708/#254) + byte-identical/drift-parity/byte-locked workflow edits. | Same. | Best, if the workflow edits are accepted. |
| 2b | Extract + suite, **not CI-wired**. | Suite is CI-invisible (repo E12: "a new suite … runs nowhere"). | Suite exists, nothing runs it. | None. |
| 3 | Delete the checks; defer to CI. | Loses the session verdict + `.mcp.base.json`. | n/a | n/a |
| 4 | Frontmatter-only parse for `.md`. | Broader, but no `.md` template here carries frontmatter. | n/a | n/a |

**Converged: Approach 1.** Deciders (failure-mode coverage does *not* discriminate — 1/2/2b reach the
same verdicts):

- **Decider 1 — resolution dependency (reliability).** 2/2b put the logic behind `scripts/`, an
  agent-infra **symlink** in consumers; the #708/#254 class is "a symlinked invocation path silently
  changed behaviour". Approach 1's primitives resolve against the repo root with no agent-infra
  dependency. A robustness argument, not a file-count one.
- **Decider 2 — enforcement (durability).** 2 is only CI-effective by editing byte-identical,
  drift-parity-gated, byte-locked workflow files; 2b yields a suite nothing runs.
- **Decider 3 — fail-closed everywhere.** Every check either validates its whole matched set or
  fails: no tooling-degraded green, no partial green. Missing tooling is an **actionable fail**
  (`install PyYAML`), matching the repo's own precedent for a gate that cannot run
  (`check-workflow-actionlint.sh`: missing docker → exit 2). This replaces an earlier draft's
  "skip-and-pass when PyYAML is absent", which a reviewer correctly identified as a false-green on
  5 of the 6 schema templates this repo owns.
- **Extensibility:** the recursive two-pass enumeration picks up new schema templates with no edit.

**Reuse, not a second validator (research mandate).** `script-validate` mirrors the existing per-file
loop in `node-ci.yml`. `.mcp.base.json`'s schema authority stays with
`extensions/mcp-client/resolution.test.ts`; workflow YAML with `check-workflow-actionlint.sh`; plists
with `install-launchd.test.sh`. The skill asserts **parseability only**, in the repo's existing shape.

### Fail-closed precedent (shape adopted)

`extensions/loop-enforcer/tier-config-parity.test.ts`: `rejects an empty source set —
adversarialBoundViolations({}) fails closed`; `rejects a shrunk subject set — de-listing a surface no
longer passes vacuously`; `stallThresholdViolations([])` → a `vacuous` violation.

**Adopted rule:** a check **never passes while validating nothing or less than its whole matched
set**. An empty target set means the check is **not offered** (recorded in `not_offered`), and the
top level is `skip` only when *no* check is offered; if a check is nevertheless offered and matches
zero (direct invocation / TOCTOU), the in-block **zero-set backstop** makes it `fail`. This satisfies
issue item 4 ("an empty match set is a failure to verify, not a pass") as "never a silent green in
either state".

### Domain classification

**(not adversarial).** WARN-ONLY, agent-executed post-deploy skill; blocks nothing, guards no trust
boundary; inputs are the repo's own committed files. No attacker-controlled input, no security
boundary to fail open. The defect class is *accidental vacuity*; the fix adopts the adversarial-pin
**discipline** without claiming an attacker threat surface. No test-coverage acceptance is asserted;
fail-closed behaviour is verified by demonstration.

### Axis Research (Phase 1.5 — internal; the mandate is repository-internal)

- **Canonical validator shape:** standalone zero-dep `scripts/` entries with exit-code contracts and
  suites — `check-skill-lint.mjs` (0/1/2), `validate-script.cjs` (0/1/2; embeds a YAML-subset parser
  *because CI has no `npm install`*), `check-workflow-actionlint.sh` (missing docker → exit 2).
  **Divergence justified:** the skill's blocks are inline, not a script (Decider 1/2), and are
  fail-closed in the same spirit.
- **Schema authority for the target template:** `extensions/mcp-client/resolution.test.ts` §
  `templates/.mcp.base.json`.
- **Workflow-template authority:** `scripts/check-workflow-actionlint.sh` (workflow YAML only).
- **Repo-native dep-free YAML reader — evaluated, rejected.** `scripts/workflow-yaml.mjs`
  (`parseWorkflowYaml`/`WorkflowYamlError`, node-stdlib only, fail-closed) exists because this repo has
  no root `node_modules` and forbids external YAML deps (#254/#666). **Verified:** it parses all five
  in-scope `templates/.github/workflows/*.yml` without throwing. Rejected on three grounds, the first
  two load-bearing: (ii) it lives behind `scripts/`, the agent-infra symlink of Decider 1;
  (iii) it is a **workflow reader with a bounded subset**, not a general validator — the check's schema
  predicate is deliberately **format-generic** (any `templates/**/*.{json,yaml,yml}`), so adopting a
  workflow-specific subset reader would make the check a differently-shaped validator (the mandate's
  warning) and would false-fail a future non-workflow YAML template (a bounded, non-in-scope risk, not
  a demonstrated one). PyYAML — format-general — is kept, and the "no PyYAML" state is now a
  fail-closed, actionable failure (Decider 3), not the silent green that made a reader look attractive.
  **Also rejected for `ci-config` specifically** (a reviewer's Good>Easy suggestion), on two concrete,
  verified grounds: (a) `workflow-yaml.mjs` has **no CLI entry point** — it exports a module only — so
  an inline skill block would need a `node --input-type=module -e 'import("./scripts/…")'` dynamic-import
  wrapper, which is fragile as a documented command; and (b) it would give `ci-config` a **hard
  `scripts/` module dependency** whereas the skill's existing `scripts/` calls are optional/gated
  (`[ -f … ]`), so a consumer checkout without the agent-infra scripts tree would fail `ci-config`.
  Recorded as a candidate follow-up if PyYAML-absence ever bites; not adopted here.
- **CI `script-validate` vs the skill's step:** CI (per-PR `ci.yml` → `node-ci.yml`; post-merge
  `ci-main.yml`) loops per-file with a `[ -f "$f" ] || continue` guard. The skill's step had drifted;
  the fix mirrors it plus non-vacuity + `validated X/N`. Difference for the PR: CI is the merge rail
  (CI-only); the skill's step is the session-invoked WARN-ONLY verdict.

---

## Plan

### Shell contract (applies to every block)

- **bash** (the skill already uses `shopt -s nullglob`); **bash 3.2** must work — no `mapfile`/
  `readarray`, no `${arr[-1]}`; lengths via `${#arr[@]}`; arrays iterated only when non-empty. No
  block sets `set -u`/`set -e`.
- Fresh shell per block; Step 1 **prints** the offered set; each Step 2 block re-derives its own set.
- **Enumeration (mandatory):** accumulate with process substitution, never a pipeline —
  `while IFS= read -r -d '' f; do arr+=("$f"); done < <(find … -print0)`. `find … | while` runs the
  body in a subshell, discarding counters and silently restoring the vacuous pass.
- **Glob loops de-vacuum:** `shopt -s nullglob` in the same block (or `[ -f "$f" ] || continue`).
- **`find` start point is dereferenced:** use `find templates/ …` and `find "$d/" …` (trailing
  slash) so a symlinked `templates/`/skills dir behaves like the `scripts/*` glob gates; a missing dir
  is `2>/dev/null` → empty set.
- **BSD-userland portability (mandatory):** blocks run on macOS with BSD `sed`/`find`/`grep`.
  GNU-only constructs are forbidden (e.g. `\+`/`\?`/`\|` in a BRE `sed`; `mapfile`). Prefer shell
  parameter expansion (`${out%% *}`) or `grep -E`/`sed -E`; never rely on a GNU extension that silently
  yields an empty match (which turns a clean tree into a false fail).
- Paths passed as **argv**, never interpolated into an interpreter string.
- **Backstop rule:** a block fails closed whenever its **target set is zero**, its **required tooling
  is missing**, or a matched file **fails to parse**. Tooling is not part of the offer predicate.

### Task 1: Rewrite Step 1 — offer each check only when its target set is non-empty

**Acceptance:** zero JS scripts → `script-validate` not offered; zero `SKILL.md` (linter discovery
semantics, recursive `_`/`.` exclusion) under the resolved skills dir → `skill-lint` not offered;
zero schema templates → `template-validity` not offered; zero workflow YAML (`*.yml`/`*.yaml`) →
`ci-config` not offered; nothing at all → exactly `NO_CHECKS_AVAILABLE`; otherwise the offered names
print one per line. **A missing tool** (absent linter, absent PyYAML) never suppresses a check that
has a non-empty target set — it makes that check **fail** when run.
**Files:** Modify `skills/post-deploy-verify/infra-verify/SKILL.md` (Step 1).

- `script-validate`: `js_scripts=(scripts/*.mjs scripts/*.cjs scripts/*.js bin/*.js)` under
  `nullglob`; offered iff `${#js_scripts[@]} -gt 0`.
- `skill-lint`: **resolution is pinned and guarded** — `s=""; for c in operations/skills .agents/skills skills; do [ -d "$c" ] && { s="$c"; break; }; done`.
  When `s` is empty none of the candidates exists → the check is **not offered** (and no `find` runs).
  Otherwise, offered iff `[ -n "$s" ] && find "$s/" \( -name '_*' -o -name '.*' \) -prune -o -name 'SKILL.md' -print`
  yields ≥1 line — the trailing slash dereferences a symlinked skills dir (matching the linter's
  `existsSync` resolution and the `templates/` rule); `_`/`.`-prefixed components are skipped
  recursively (a naive `find -name SKILL.md` over-counts a nested `skills/foo/_archived/SKILL.md`).
  The block passes `--skills-dir "$s"`. **The empty-`s` guard is load-bearing:** without it an
  unresolved `$s` makes `find "$s/"` expand to `find "/"` — an unbounded scan that can match an
  unrelated `SKILL.md` (e.g. under `~/.pi/agent/skills`) and spuriously offer the check, which then
  fails on `--skills-dir ""`. **The linter's own existence is NOT part of this predicate** — an absent
  `scripts/check-skill-lint.mjs` is a *tooling* absence: the check is offered and then **fails**
  (actionable), consistent with the States rule that `not_offered` reasons are target-set reasons only.
- `template-validity`: `find templates/ -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null`;
  offered iff the set is non-empty.
- `ci-config`: `nullglob` array of `.github/workflows/*.yml` + `*.yaml`; offered iff non-empty.

### Task 2: Rewrite `template-validity` — two-pass enumeration, dotfiles, explicit skips, fail-closed

**Intent:** validate every schema template the check owns; never fail a file it cannot validate;
never pass on less than the whole matched set.
**Acceptance:** `templates/.mcp.base.json` validated (JSON via `node`); the 5
`templates/.github/workflows/*.yml` validated; the 3 `.md` reported skipped (`no schema`); 6 `.plist` +
`.gitignore`/`.husky/*`/`RETIRED` reported skipped (non-schema; plists owned by
`install-launchd.test.sh`); a malformed `.json`/`.yml` → exit 1 naming **every** offender; **YAML
matched and PyYAML absent → exit 1** with an actionable message (`install PyYAML`, and note workflow
YAML is also covered by the actionlint gate); zero schema templates (direct invocation) → exit 1
backstop.
**Files:** Modify `skills/post-deploy-verify/infra-verify/SKILL.md` (Step 2 `template-validity`).

**Mechanism — two passes, because a schema-only `find` cannot report what it skipped:**
1. enumerate **all** files under `templates/` (process-substitution accumulation);
2. classify: `*.json` → validate via `node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f"`;
   `*.yaml|*.yml` → validate via `python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f"`;
   `*.md` → `skipped_noschema`; else → `skipped_nonschema`;
3. preflight: if ≥1 YAML matched and `python3 -c 'import yaml'` fails → exit 1 "cannot verify — PyYAML
   unavailable (install PyYAML)"; if zero schema matched → exit 1 backstop;
4. accumulate parse failures, print **every** offender one per line, exit 1 if any;
5. report `validated N/N schema template(s); skipped A markdown (no schema), B non-schema`.
Extension predicates group alternatives explicitly (`\( … -o … \)`) — unparenthesized, `-type f`
binds only to the first `-name` branch.

### Task 3: Rewrite `script-validate` — per-file loop, zero-set backstop, pinned counts

**Acceptance:** denominator **25**; clean → `validated 25/25 scripts`; a fault in `bin/agent-infra.js`
→ exit 1 naming it; a fault in a `scripts/*.mjs` → exit 1 naming it; **two** faults → both named;
zero scripts (direct invocation) → exit 1 backstop.
**Files:** Modify `skills/post-deploy-verify/infra-verify/SKILL.md` (Step 2 `script-validate`).
**Deviation from the issue's set (24 → 25):** the issue counts only `scripts/*.{mjs,cjs,js}` (24); the
check also matches `bin/*.js` (`bin/agent-infra.js`), mirroring `node-ci.yml` — recorded so it is not
read as accidental.

**Count semantics (and a stated deviation from item 3):** accumulate offenders, print **every** one
per line, then `failed M — offenders listed above`; on success `validated N/N scripts`. **Deviation
from item 3's literal "fails on the first non-zero exit":** accumulation removes the masking bug
(trailing argv never checked) *and* names all offenders; a first-offender-only exit hides the rest.

### Task 4: `ci-config` — `*.yml` + `*.yaml`, zero-set backstop, missing-tooling fail

**Acceptance:** zero workflow YAML → not offered; direct invocation with zero matches → exit 1
backstop; PyYAML absent but workflows present → **exit 1** with the actionable message (offered, then
fails — not silently omitted); a malformed workflow → exit 1 naming **every** offender; a valid
`*.yaml` workflow is counted (proving the `.yaml` alternative is live); clean → `validated N/N workflows`.
**Files:** Modify `skills/post-deploy-verify/infra-verify/SKILL.md` (Step 2 `ci-config`).

### Task 5: Step 3 — disambiguate states; carry counts; reconcile Failure Handling; make the router honest

**Intent:** the JSON contract, the Failure Handling section, and the router's aggregate report must
not contradict the new semantics or hide a partial/unvalidated surface.
**Acceptance:** the JSON carries per-check `validated` and `skipped` (with `reason`), a top-level
`not_offered: [{name, reason}]`, and valid JSON; the router's Step 3 report surfaces not-offered /
non-full coverage; Failure Handling is rewritten.
**Files:** Modify `skills/post-deploy-verify/infra-verify/SKILL.md` (Step 2 `skill-lint`, Step 3
**and** `## Failure Handling`) **and** `skills/post-deploy-verify/SKILL.md` (Step 3 report format, its
`VerificationResult` schema block — additive optional `not_offered`/`validated`/`skipped` — and the
evidence enum's `path` note).
**`skill-lint` in-block backstop (mechanism pinned, BSD-userland portable):** the linter has no
JSON/`--count` mode and exits 0 for the zero case, so capture stdout and fail closed unless it carries
a positive checked-count. **No GNU-sed-only constructs** (BSD `sed` does not support `\+` in a BRE —
verified: it yields an empty string, making `[ "" -gt 0 ]` error and firing a false fail on a clean
repo). Portable shell-only extraction:
```bash
out=$(node scripts/check-skill-lint.mjs --skills-dir "$SKILLS_DIR" 2>&1); rc=$?
printf '%s\n' "$out"
[ $rc -eq 0 ] || exit 1
n=${out%% *}   # first whitespace-delimited token, e.g. 123
case "$n" in ''|*[!0-9]*) echo "❌ skill-lint: cannot parse checked-count — failure to verify (fail-closed)"; exit 1 ;; esac
[ "$n" -gt 0 ] || { echo "❌ skill-lint: linted 0 skills — failure to verify (fail-closed)"; exit 1; }
```

**States (one rule, used everywhere):**
- check target set empty → **not offered**, omitted from `checks[]`, recorded in `not_offered`; if
  *no* check is offered → top-level `skip` with `reason`;
- check offered, target set zero (direct invocation / TOCTOU) → **`fail`** (backstop);
- check offered, required tooling missing → **`fail`** (actionable);
- check offered, a matched file malformed → **`fail`**, offenders listed;
- otherwise → `pass`, with `validated X/N` and any `skipped` buckets reported.
**Failure Handling rewrite:** "missing = skip, not fail" → "a check that is **not offered** →
`skip`; an **offered** check that matched nothing **or** whose tooling is absent → `fail`".
"Never exit non-zero — always return JSON" stays, plus "check-block exit codes are mapped into the
JSON `status`, never surfaced as a non-zero skill exit".
**Router honesty (the guarantee made real):** add to the router's Step 3 report format **and its
`VerificationResult` schema block** that `checks[]` contains only offered checks, and that the report
must render (a) `not_offered` and (b) any non-full `validated X/N`. Worked examples:
- all offered checks pass: `infra | ✅ pass | 4/4`;
- a target-set-empty check not offered: `infra | ✅ pass | 3/3 (+1 not offered: ci-config — no workflow YAML present)`;
- a **tooling-missing** check: `infra | ⚠️ fail | 2/3` **plus the separate `Failures:` line**
  (`ci-config: cannot verify — PyYAML unavailable (install PyYAML)`). The 4th table column is the
  router's `issues_filed` column and holds issue refs only — failure detail goes in the `Failures:`
  line / a `⚠️` annotation, never in the `Issues` column.
**`not_offered[].reason` is ONLY ever the empty-target-set reason — never a tooling reason** (a
missing tooling is an offered-then-failed check, per the States rule), and a surface containing a
failed check renders `fail`, never a `pass` with a `(+N not offered)` tail. Not-offered evidence uses
the documented `log` type: `{"type":"log","description":"<name> not offered: <reason>"}`; the router's
evidence enum gains an explicit `path` optional note for artifact-less entries. The added JSON fields
remain strictly additive; no code deterministically parses this JSON.

### Task 6: Verification + PR

**Acceptance:** transcript in the PR; local checks green; code-review clean.

### Verification Plan (exact commands + expected verdicts)

1. **Pre-fix reproduction:** `node --check good.mjs bad.mjs` → 0; `node --check bad.mjs` → 1; pre-fix
   `template-validity` on clean `main` → exit 1; offer-probe in an empty dir → `OFFERED`.
2. **Fixed, happy path (real repo):** `script-validate` → `validated 25/25 scripts`;
   `template-validity` → `validated 6/6` (JSON + 5 workflow YAML) with exact skipped buckets (3 `.md`
   no-schema; 6 `.plist` + `.gitignore`/`.husky/*`/`RETIRED` non-schema); `ci-config` →
   `validated N/N workflows`; `skill-lint` → clean (123 SKILL.md).
3. **Catches broken input:** a `SyntaxError` in a copy of `scripts/*.mjs` → exit 1 naming it; in a
   copy of `bin/agent-infra.js` → exit 1 naming it; malformed `.json` in a scratch `templates/`
   (template-validity) → exit 1 naming it; malformed `.yml` in a scratch `templates/` (template-validity,
   PyYAML present) → exit 1 naming it; malformed `.yml` in a scratch `.github/workflows/`
   (ci-config) → exit 1 naming it. **Multi-fault:** 2 broken `scripts/` + 2 broken workflows → every
   offender printed in both blocks. **`ci-config` `.yaml`:** a valid `*.yaml` counted; an invalid one named.
4. **Offer-gate absences:** scratch trees asserting the printed set — (a) no JS scripts →
   `script-validate` absent; (b) no workflow YAML → `ci-config` absent; (c) `templates/` with only
   `.md` → `template-validity` absent; (d) **`templates/` dir absent** → `template-validity` absent;
   (e) existing-but-empty skills dir → `skill-lint` absent; (f) linter absent with a skills tree →
   `skill-lint` **offered**, then fails (actionable — not omitted from the set);
   (g) `skills/foo/_archived/SKILL.md` only (nested) → `skill-lint` absent;
   (h) nothing matches → exactly `NO_CHECKS_AVAILABLE`; (i) a **symlinked** resolved skills dir →
   `skill-lint` still offered and lints its target; (j) **no skills dir resolves** at all → `skill-lint`
   absent **and no `find` runs** (\(guards the `find "$s/"` → `find "/"` unbounded-scan case\), with
   `NO_CHECKS_AVAILABLE` when every other surface is also absent.
5. **Fail-closed / backstops, direct invocation:**
   (a) `template-validity` with zero schema templates → exit 1;
   (b) `template-validity` with a scratch `templates/` holding **only** a `.yml` and PyYAML unavailable
   → exit 1 "cannot verify — PyYAML unavailable" (**the** reachable missing-tooling state — the
   offer-gate does not suppress it);
   (c) `script-validate` with zero scripts → exit 1; `ci-config` with zero workflows → exit 1;
   (d) `ci-config` with workflows present and PyYAML unavailable → exit 1 (actionable);
   (e) a **symlinked** `templates/` (start-point dereference) → `template-validity` still offered and
   validates the target files;
   (f) direct `skill-lint` against a scratch tree whose linter self-reports `0 SKILL.md files checked`
   → exit 1 with the "linted 0 skills — failure to verify" message (the only reachable path to the
   backstop; step 4 only asserts the offer gate), plus a control run on `skills/` where the portable
   extraction yields `123` (guards the BSD-`sed` class);
   **`template-validity` multi-offender:** a scratch `templates/` with **two** malformed schema
   templates (one `.json`, one `.yml`, PyYAML present) → exit 1 and **both** paths printed.
6. **JSON + router honesty:** parse the emitted `skip` result and a partial `pass` result with
   `node -e 'JSON.parse(...)'` → ok. Assert the partial `pass` carries per-check `validated` and
   `skipped[].reason` **and** `not_offered`; render (a) a partial `validated X/N` (e.g. 5/6, a skipped
   bucket) through the router report and show the transcript, **and** (b) a target-set-empty
   `not_offered` case, **and** (c) a tooling-missing check, asserting it renders `fail` (never a green
   with a `(+N not offered)` tail).
7. **Diff scope:** `git diff --name-only origin/main` → only `skills/**/*.md` + this plan doc.
8. **Repo-gate sanity (not affected by this diff; required by the dispatch contract):**
   `node scripts/check-skill-lint.mjs --skills-dir skills` → `123 … 0 issue(s). Clean.`;
   `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts` → 52 passed;
   `npx tsx extensions/loop-enforcer/termination.test.ts` → 46 passed;
   `bash scripts/materialize-agents.sh --check .` → pass.

### Acceptance Criteria

- `template-validity` validates `templates/.mcp.base.json` and the 5 workflow YAMLs, reports the 3
  `.md` and 10 non-schema files skipped, and fails closed on a malformed file, a zero-schema backstop,
  and missing PyYAML — never a tooling-degraded green.
- `script-validate` validates all **25** matched files (incl. `bin/agent-infra.js`), reports
  `validated X/N scripts`, names every offender, and exits 1 on a zero-match backstop.
- `ci-config` covers `*.yml` and `*.yaml` (both positively exercised), fails closed on zero matches
  and missing PyYAML, and names every offender.
- `skill-lint` mirrors the linter's recursive discovery semantics and fails closed when the linter's
  self-reported checked-count is 0.
- Every check is offered only when its target set is non-empty; zero-input checks are unreachable as
  passes; partial not-offered surfaces are recorded in `not_offered` **and** rendered by the router's
  report — a partial `pass` is never silently green.
- `check-skill-lint` stays clean; the PR diff is `skills/**/*.md` (+ this plan doc) only.
- **Known, accepted residual:** the inline blocks are verified by demonstration (the transcript above),
  not by a suite — extraction was rejected under Decider 1/2. Recorded, not glossed.

## Learnings

- **A pipeline's exit status comes from its last command.** `ls … | head -1` reported `head`'s
  status, so the offer probe could never detect "nothing to validate" (D4). Any probe whose success
  is read from a pipeline is structurally unable to fail closed.
- **`node --check` consumes only `argv[1]`-style first argument semantics for the *set*, not the
  list.** Passing several paths validates one and reports success for all (D2) — the same vacuity
  class as an empty match, reached from the opposite direction.
- **Shell globs do not match dotfiles**, so `templates/*.json` silently under-matched
  `templates/.mcp.base.json`; `find` does. Enumeration and validation must use the same matcher.
- **A linter that reports its own count is a vacuity detector.** `check-skill-lint` printing
  `0 SKILL.md files checked. Clean.` and exiting 0 (D5) is a pass over nothing; asserting the
  self-reported count is > 0 inside the block is the cheapest fail-closed fix, and it needs no GNU
  tooling (`n=${out%% *}`) — a `sed`-based extraction broke on BSD userland.
- **"Not offered" and "offered but empty" are different states.** Conflating them is what produced
  the vacuous greens; the contract now separates target-absence (`not_offered`/`skip`) from
  tooling-absence and zero-match-at-run-time (`fail`).
