---
disable-model-invocation: true
name: infra-verify
description: "Script-based verification for infrastructure, skills, and config changes. Unlike web/desktop clickthrough, infra has no UI — verification is automated script validation. Invoked by post-deploy-verify router for infra surface PRs."
domain: engineering
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read bash grep find
version: 1.1.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Infra Verification

**Announce at start:** "I'm running infra verification — validating scripts, skills, and config."

## Purpose

Run infrastructure-level validation checks against merged infra changes. Unlike web/desktop
surfaces, infra has no UI to click through — verification is **script-based validation**. This is
intentional: infra changes (skills, scripts, templates, CI config) are validated by parsing, linting,
and syntax-checking.

Every check in this skill is **fail-closed**: a check never reports `pass` while validating nothing
or less than its whole matched set. A check whose target set is empty is not offered — it is omitted
from `checks[]` (the surface is `skip` only when **no** check at all was offered); a check whose
tooling is missing, whose matched set is empty at run time, or whose input fails to parse **fails**.

## Contract

**Input:** PR number, repo root
**Output:** JSON `VerificationResult`
**Gate:** WARN-ONLY

**Declared coverage scope:** the four checks cover JS/TS scripts, skills, schema templates, and
workflow YAML only. They are **repo-scoped, not diff-scoped** — Step 1 offers a check on the existence
of its target tree *in the repo*, so a PR touching only classes no check covers (`terraform/*`,
`docker/*`, `k8s/*`, `supabase/*`, `enforcement/*`, `Dockerfile`, `docker-compose*`, `*.tf`, …) still
offers all four and reports `pass` against the repo's own trees while that changed surface goes
unvalidated. **That is a known fail-open, tracked by #1052** — stated here as a gap, not as a pass.
The surface status is `skip` (with a `reason`) only when no target set exists in the repo at all.

## Workflow

> **Shell contract (applies to every block):** blocks are **bash** and must run on **bash 3.2**
> (macOS) — no `mapfile`/`readarray`, no `${arr[-1]}`. Do **not** set `set -u`/`set -e`.
> Each `bash` invocation is a **fresh shell**, so no variable crosses blocks: Step 1 *prints* the
> offered set and each Step 2 block re-derives its own set. Enumerate with process substitution
> (`while … done < <(find … -print0)`) — never `find … | while`, whose subshell discards counters and
> silently restores the vacuous pass. Glob loops set `shopt -s nullglob` (or guard with
> `[ -f "$f" ] || continue`). `find` start points carry a trailing slash (`find templates/ …`) so a
> symlinked tree is dereferenced like the glob gates. Paths are passed as **argv**, never
> interpolated into an interpreter string. **BSD userland:** no GNU-only `sed`/`grep` constructs
> (e.g. `\+` in a BRE silently yields an empty match and can turn a clean tree into a false fail).

### Step 1 — Detect Available Checks

A check is offered only when its **target set is non-empty**. Tooling is deliberately *not* part of
the offer predicate: a missing tool is an actionable `fail` when the check runs, never a silent skip.

```bash
cd <REPO_ROOT>
shopt -s nullglob

CHECKS=()

# script-validate — offered iff ≥1 JS script exists. Mirrors node-ci.yml's
# `scripts/*.{cjs,mjs,js} bin/*.js` loop. The previous `ls … | head -1` probe
# took its exit status from `head` (always 0), masking `ls`'s failure, so the
# check was offered even when it had nothing to validate.
js_scripts=(scripts/*.mjs scripts/*.cjs scripts/*.js bin/*.js)
[ ${#js_scripts[@]} -gt 0 ] && CHECKS+=("script-validate")

# skill-lint — offered iff a skills tree with ≥1 SKILL.md resolves. Resolution
# order and discovery semantics mirror scripts/check-skill-lint.mjs
# (findSkillFiles skips `_`/`.`-prefixed entries recursively). The empty-
# SKILLS_DIR guard is load-bearing: unguarded, an unresolved $SKILLS_DIR makes
# `find "$SKILLS_DIR/"` expand to `find "/"` — an unbounded scan that can match
# an unrelated SKILL.md and spuriously offer the check.
SKILLS_DIR=""
for c in operations/skills .agents/skills skills; do
  [ -d "$c" ] && { SKILLS_DIR="$c"; break; }
done
if [ -n "$SKILLS_DIR" ] && \
   [ "$(find "$SKILLS_DIR/" \( -name '_*' -o -name '.*' \) -prune -o -name 'SKILL.md' -print 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
  CHECKS+=("skill-lint")
fi

# template-validity — offered iff ≥1 schema-bearing template exists. `find`
# matches dotfiles (shell `*.json` does not); the trailing slash dereferences a
# symlinked templates/.
[ -n "$(find templates/ -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)" ] \
  && CHECKS+=("template-validity")

# ci-config — offered iff ≥1 workflow YAML exists (`.yml` or `.yaml`).
ci_yamls=(.github/workflows/*.yml .github/workflows/*.yaml)
[ ${#ci_yamls[@]} -gt 0 ] && CHECKS+=("ci-config")

if [ ${#CHECKS[@]} -eq 0 ]; then
  echo "NO_CHECKS_AVAILABLE"
else
  printf '%s\n' "${CHECKS[@]}"
fi
```

### Step 2 — Run Checks

Run each **offered** check. Every block is self-contained and fail-closed.

**script-validate:**
```bash
cd <REPO_ROOT>
shopt -s nullglob
files=(scripts/*.mjs scripts/*.cjs scripts/*.js bin/*.js)
if [ ${#files[@]} -eq 0 ]; then
  echo "❌ script-validate: 0 scripts matched — failure to verify (fail-closed)"; exit 1
fi
failed=0
for f in "${files[@]}"; do
  if ! err=$(node --check "$f" 2>&1); then
    echo "❌ script-validate: $f failed node --check"; echo "$err"; failed=$((failed+1))
  fi
done
if [ $failed -gt 0 ]; then
  echo "failed $failed — offenders listed above; validated $(( ${#files[@]} - failed ))/${#files[@]} scripts"
  exit 1
fi
echo "✅ script-validate: validated ${#files[@]}/${#files[@]} scripts"
```
→ exit 0 = pass. Fails on a syntax error, naming **every** offender (not just the first argv — the
defect this replaced validated only the first).

**skill-lint:**
```bash
cd <REPO_ROOT>
SKILLS_DIR=""
for c in operations/skills .agents/skills skills; do
  [ -d "$c" ] && { SKILLS_DIR="$c"; break; }
done
if [ -z "$SKILLS_DIR" ]; then
  echo "❌ skill-lint: no skills dir resolved — failure to verify (fail-closed)"; exit 1
fi
out=$(node scripts/check-skill-lint.mjs --skills-dir "$SKILLS_DIR" 2>&1); rc=$?
printf '%s\n' "$out"
[ $rc -eq 0 ] || exit 1
n=${out%% *}   # first whitespace-delimited token, e.g. 123
case "$n" in
  ''|*[!0-9]*) echo "❌ skill-lint: cannot parse checked-count — failure to verify (fail-closed)"; exit 1 ;;
esac
[ "$n" -gt 0 ] || { echo "❌ skill-lint: linted 0 skills — failure to verify (fail-closed)"; exit 1; }
echo "✅ skill-lint: validated $n SKILL.md file(s)"
```
→ exit 0 = pass. `--skills-dir` is passed explicitly so the check and the linter share one directory;
the linter's exit-2 fail-closed path is engaged for a missing dir. The checked-count backstop closes
the vacuity where the linter prints `0 SKILL.md files checked. Clean.` and exits 0.

**template-validity:**
```bash
cd <REPO_ROOT>
repo_root=$PWD
# Two passes: a schema-only enumeration cannot report what it skipped.
all_templates=()
while IFS= read -r -d '' f; do all_templates+=("$f"); done < <(find templates/ -type f -print0 2>/dev/null)

schema=(); skipped_noschema=0; skipped_nonschema=0
for f in "${all_templates[@]}"; do
  case "$f" in
    *.json|*.yaml|*.yml) schema+=("$f") ;;
    *.md) skipped_noschema=$((skipped_noschema+1)) ;;    # markdown carries no schema
    *) skipped_nonschema=$((skipped_nonschema+1)) ;;     # .gitignore, .husky/*, *.plist (XML), …
  esac
done

if [ ${#schema[@]} -eq 0 ]; then
  echo "❌ template-validity: 0 schema-bearing templates (YAML/JSON) — failure to verify (fail-closed)"; exit 1
fi

needs_yaml=0
for f in "${schema[@]}"; do case "$f" in *.yaml|*.yml) needs_yaml=1 ;; esac; done
if [ $needs_yaml -eq 1 ] && ! (cd / && python3 -c 'import yaml') 2>/dev/null; then
  echo "❌ template-validity: YAML templates present but PyYAML is unavailable — cannot verify (fail-closed; install PyYAML)"
  exit 1
fi

failed=0
for f in "${schema[@]}"; do
  case "$f" in
    *.json)
      if ! err=$(node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" 2>&1); then
        echo "❌ template-validity: $f did not parse as JSON"; echo "$err"; failed=$((failed+1))
      fi ;;
    *)
      if ! err=$(cd / && python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$repo_root/$f" 2>&1); then
        echo "❌ template-validity: $f did not parse as YAML"; echo "$err"; failed=$((failed+1))
      fi ;;
  esac
done
if [ $failed -gt 0 ]; then
  echo "failed $failed — offenders listed above; validated $(( ${#schema[@]} - failed ))/${#schema[@]} schema template(s)"
  exit 1
fi
echo "✅ template-validity: validated ${#schema[@]}/${#schema[@]} schema template(s); skipped $skipped_noschema markdown (no schema), $skipped_nonschema non-schema"
```
→ exit 0 = pass. Validates **every** schema template (dotfiles included) and states the denominator;
markdown is skipped explicitly, never failed. `.plist` files are XML — out of scope here, validated by
`scripts/install-launchd.test.sh`; template workflow YAML is also covered by the actionlint gate.

> **Python must run with CWD outside the checkout.** For `python3 -c`, `sys.path[0]` is the current
directory, searched **before** site-packages — so a repo containing a `yaml.py` would have its own
code imported and executed by the verifying agent. Python is therefore invoked from `/` with the
file passed as an absolute path (`cd / && python3 -c '…' "$repo_root/$f"`).
>
> **`-I` alone would also close this hole, but `-s` would not** — `-s` only drops the **user**
site-packages directory and leaves the CWD on `sys.path`. And `-I` carries a side effect here: it
drops user site-packages too, turning a user-local PyYAML install into a permanent fail-closed red.
The CWD change closes the same hole without either consequence.
>
> Paths are always passed as **argv**, so a filename can never reach the interpreter source.

**ci-config:**
```bash
cd <REPO_ROOT>
repo_root=$PWD
shopt -s nullglob
wf=(.github/workflows/*.yml .github/workflows/*.yaml)
if [ ${#wf[@]} -eq 0 ]; then
  echo "❌ ci-config: 0 workflow YAML matched — failure to verify (fail-closed)"; exit 1
fi
(cd / && python3 -c 'import yaml') 2>/dev/null || { echo "❌ ci-config: PyYAML unavailable — cannot verify (fail-closed; install PyYAML)"; exit 1; }
failed=0
for f in "${wf[@]}"; do
  if ! err=$(cd / && python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$repo_root/$f" 2>&1); then
    echo "❌ ci-config: $f did not parse as YAML"; echo "$err"; failed=$((failed+1))
  fi
done
if [ $failed -gt 0 ]; then
  echo "failed $failed — offenders listed above; validated $(( ${#wf[@]} - failed ))/${#wf[@]} workflows"
  exit 1
fi
echo "✅ ci-config: validated ${#wf[@]}/${#wf[@]} workflows"
```
→ exit 0 = pass. Covers `*.yml` **and** `*.yaml`.

### Step 3 — Return Result

Map each offered check's exit code into the JSON `status` (a block's non-zero exit becomes a check
`fail`; it is **never** surfaced as a non-zero skill exit). A check that was **not offered** is
omitted from `checks[]` and recorded in `not_offered` — `not_offered[].reason` is **only ever** the
absent-target-surface reason, never a tooling reason (a missing tool is an offered-then-`fail` check).

```json
{
  "surface": "infra",
  "status": "pass",
  "checks": [
    {"name": "script-validate", "status": "pass", "validated": 25, "total": 25, "duration_ms": 120},
    {"name": "skill-lint", "status": "pass", "validated": 123, "total": 123, "duration_ms": 340},
    {"name": "template-validity", "status": "pass", "validated": 6, "total": 6,
     "skipped": [{"reason": "no schema", "count": 3}, {"reason": "non-schema", "count": 10}], "duration_ms": 80},
    {"name": "ci-config", "status": "pass", "validated": 10, "total": 10, "duration_ms": 150}
  ],
  "not_offered": [],
  "evidence": [],
  "issues_filed": []
}
```

- Any check failing → `"status": "fail"` with every offender in `evidence` (log type).
- No check offered → `"status": "skip"` with a `reason` naming the absent surfaces, `"checks": []`.
- Partial coverage (a check not offered) → `"status": "pass"` **plus** `not_offered` entries and a
  matching `evidence` entry (`{"type":"log","description":"<name> not offered: <reason>"}`), so a
  green can never silently mean "a surface went unverified". The router renders the partial marker
  from `not_offered` (and from any `validated` < `total`); the `evidence` entry preserves the reason.

## Why Script-Based (Not Agent-Executed)

Unlike web and desktop surfaces, infra changes have no user interface to click through. A skill file,
script, or CI config is validated by parsing and syntax-checking — not by "navigating." The agent runs
deterministic validation tools and reports results.

## Failure Handling

- **Never exit non-zero** — always return JSON. A check block's non-zero exit is mapped into the JSON
  `status`; it is never surfaced as a non-zero skill exit.
- **A check whose target surface is absent is _not offered_** — omitted from `checks[]` and recorded
  in `not_offered`; the surface status is `skip` **only when no check was offered at all** (and then
  it carries a surface-level `reason`). **An _offered_ check that matched nothing, whose tooling is
  missing, or whose input failed to parse → `fail`.** "Missing" therefore means *not offered* — never
  a silent pass over a surface that is present.
- **Log check output as evidence** for failures.
- **Available checks vary by repo** — a repo with none of the four surfaces legitimately reports
  `skip`; that is distinct from a present-but-unverifiable surface, which fails.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
