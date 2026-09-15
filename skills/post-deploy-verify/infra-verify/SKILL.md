---
disable-model-invocation: true
name: infra-verify
description: "Script-based verification for infrastructure, skills, and config changes. Unlike web/desktop clickthrough, infra has no UI — verification is automated script validation. Invoked by post-deploy-verify router for infra surface PRs."
domain: engineering
type: Bounded
subjects.team: organisation-design-team
allowed-tools: read bash grep find
version: 1.2.0
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

Every `find`-based enumeration is also **bounded**. A `find` start point is resolved once to its
physical path and admitted only when that path is inside the checkout or the matching subtree of
`${AGENT_INFRA_PATH}`; a start point outside that boundary (e.g. a committed `templates -> /`)
**fails** with an explicit refusal instead of being scanned — `find <dir>/` dereferences a
symlinked start point and walks the whole target (#1051). The single-level **glob** enumerations
(`scripts/*.mjs`, `.github/workflows/*.yml`) still follow a symlinked path component with no
boundary check — single-level (non-recursive), not boundary-checked, and tracked separately in #1083; they are deliberately
not claimed as covered here.

## Contract

**Input:** PR number, repo root. `${AGENT_INFRA_PATH}` is **read from the environment** — it is not passed
by the caller — and is what admits a symlinked skills/templates tree whose target lives outside the
checkout. With it unset (or unresolvable) such a tree is refused, never silently skipped; see
`scripts/link-skills.sh`, whose `$HOME/agent-infra` fallback this check deliberately does not adopt
(residual 1 in the #1051 plan doc).
**Output:** JSON `VerificationResult`
**Gate:** WARN-ONLY

**Declared coverage scope:** the four checks cover JS/TS scripts, skills, schema templates, and
workflow YAML only. They are **repo-scoped, not diff-scoped** — Step 1 offers a check on the existence
of its target tree *in the repo*, so a PR touching only classes no check covers (`terraform/*`,
`docker/*`, `k8s/*`, `supabase/*`, `enforcement/*`, `Dockerfile`, `docker-compose*`, `*.tf`, …) still
offers all four and reports `pass` against the repo's own trees while that changed surface goes
unvalidated — a known fail-open (tracked by #1052), **not a clean run**. The surface status is `skip`
(with a `reason`) only when no target set exists in the repo at all.

## Workflow

> **Shell contract (applies to every block):** blocks are **bash** and must run on **bash 3.2**
> (macOS) — no `mapfile`/`readarray`, no `${arr[-1]}`. Do **not** set `set -u`/`set -e`.
> Each `bash` invocation is a **fresh shell**, so no variable crosses blocks: Step 1 *prints* the
> offered set and each Step 2 block re-derives its own set. Enumerate with process substitution
> (`while … done < <(find … -print0)`) — never `find … | while`, whose subshell discards counters and
> silently restores the vacuous pass. Glob loops set `shopt -s nullglob` (or guard with
> `[ -f "$f" ] || continue`). **`find` start points are never given a trailing slash.** A trailing
> slash dereferences a symlinked start point, and `-P` cannot undo it (the slash is resolved on the
> command line, before `find` ever sees a symlink), so `find templates/` in a repo that commits
> `templates -> /` walks the filesystem (#1051). Every block that enumerates a tree defines
> `bounded_root` and passes the **physical** path it returns to `find -P`. A start point whose
> physical path is outside the checkout *and* outside the matching subtree of `${AGENT_INFRA_PATH}`
> (`${AGENT_INFRA_PATH}/skills`, `${AGENT_INFRA_PATH}/templates`) — the shared agent-infra tree
> consumer repos symlink their skills directory to — **fails closed**; it is never silently
> not offered, because a check that vanishes is a false green. The subtree bound (not the whole
> shared checkout) keeps a `templates -> $AGENT_INFRA_PATH` redirect from scanning the shared
> repo's unrelated trees. Paths are passed as **argv**, never
> interpolated into an interpreter string. **BSD userland:** no GNU-only `sed`/`grep` constructs
> (e.g. `\+` in a BRE silently yields an empty match and can turn a clean tree into a false fail).
> **`<REPO_ROOT>` must be substituted** with the absolute repo root (the `task` cwd) before the block
> runs — every block opens `cd "<REPO_ROOT>" || exit 1`, so an unsubstituted placeholder exits 1 on its
> first line with no check output. That hard exit is the fix for #1051, not a check failure: a literal
> paste would otherwise `cd` to the ambient directory and silently re-base the whole boundary.

### Step 1 — Detect Available Checks

A check is offered only when its **target set is non-empty**. Tooling is deliberately *not* part of
the offer predicate: a missing tool is an actionable `fail` when the check runs, never a silent skip.

```bash
cd "<REPO_ROOT>" || exit 1
shopt -s nullglob

# ── bounded_root — start-point symlink safety (#1051) ──────────────────────
# A trailing slash dereferences a symlinked START POINT and `-P` cannot undo
# it (the slash is resolved before find ever sees a symlink), so `find
# templates/` on a committed `templates -> /` walks the filesystem. Resolve the
# start point ONCE here (physically), admit it only when its physical path is
# inside the checkout or the matching subtree of the shared agent-infra tree
# (`${AGENT_INFRA_PATH}/<subtree>`), and hand `find` that physical path —
# never a symlink, never a trailing slash. rc 0 = admitted
# (path printed on stdout) / rc 1 = no entry at all (absent) / rc 2 = present
# but outside the permitted boundary, or the checkout root itself could not be
# resolved / rc 3 = present but unverifiable (a plain file, a dangling symlink,
# a symlink loop, an unlistable tree, or otherwise unresolvable). rc 2 and rc 3
# FAIL CLOSED, are
# offered (never silently not offered), and are never scanned. With AGENT_INFRA_PATH unset a symlinked tree is refused, not
# silently dropped. Identical in every block that enumerates a tree.
repo_real=$(pwd -P)
agent_real=""
if [ -n "${AGENT_INFRA_PATH:-}" ] && [ -d "${AGENT_INFRA_PATH}" ]; then
  agent_real=$(cd "${AGENT_INFRA_PATH}" && pwd -P)
fi
bounded_root() {   # $1 candidate start point (may be a symlink) - $2 its subtree under ${AGENT_INFRA_PATH}
  local physical
  [ -n "$repo_real" ] || return 2   # no boundary basis: refuse, never a '/*' wildcard admission
  [ -e "$1" ] || [ -L "$1" ] || return 1   # no entry at all: empty target set
  [ -d "$1" ] || return 3           # present, but not a directory (file, dangling link, loop)
  [ -r "$1" ] || return 3           # present, but not listable: the probe would read empty and vanish
  physical=$(cd "$1" 2>/dev/null && pwd -P) || return 3   # present, but unresolvable
  case "$physical" in
    "$repo_real"|"$repo_real"/*) printf '%s\n' "$physical"; return 0 ;;
  esac
  if [ -n "$agent_real" ] && [ -n "$2" ]; then
    case "$physical" in
      "$agent_real/$2"|"$agent_real/$2"/*) printf '%s\n' "$physical"; return 0 ;;
    esac
  fi
  return 2
}

CHECKS=()

# script-validate — offered iff ≥1 JS script exists. Mirrors node-ci.yml's
# `scripts/*.{cjs,mjs,js} bin/*.js` loop. The previous `ls … | head -1` probe
# took its exit status from `head` (always 0), masking `ls`'s failure, so the
# check was offered even when it had nothing to validate.
js_scripts=(scripts/*.mjs scripts/*.cjs scripts/*.js bin/*.js)
[ ${#js_scripts[@]} -gt 0 ] && CHECKS+=("script-validate")

# skill-lint — offered iff a skills tree with ≥1 SKILL.md resolves. Resolution
# order and discovery semantics mirror scripts/check-skill-lint.mjs
# (findSkillFiles skips `_`/`.`-prefixed entries recursively). The start point
# goes through bounded_root and is enumerated as its physical path. The empty-
# SKILLS_DIR guard still closes the unresolved-`find "/"` case; bounded_root
# closes the resolved-symlink case, and an out-of-boundary tree is OFFERED
# here so its Step 2 block fails closed rather than the check disappearing.
SKILLS_DIR=""
for c in operations/skills .agents/skills skills; do
  [ -d "$c" ] && { SKILLS_DIR="$c"; break; }
done
# A candidate that is PRESENT but not a directory (a dangling symlink, a
# symlink loop, a plain file) still has to reach bounded_root: it is rc 3,
# so the check is offered and then fails closed. Treating it as "no skills
# dir" would silently un-offer a present check (a false green). Directory
# precedence is kept, so a stray file cannot shadow a real skills dir.
if [ -z "$SKILLS_DIR" ]; then
  for c in operations/skills .agents/skills skills; do
    { [ -e "$c" ] || [ -L "$c" ]; } && { SKILLS_DIR="$c"; break; }
  done
fi
if [ -n "$SKILLS_DIR" ]; then
  skills_rc=0
  skills_phys=$(bounded_root "$SKILLS_DIR" skills) || skills_rc=$?
  if [ "$skills_rc" -ge 2 ]; then
    CHECKS+=("skill-lint")
  elif [ "$skills_rc" -eq 0 ] && \
       [ -n "$(find -P "$skills_phys" \( -name '_*' -o -name '.*' \) -prune -o -name 'SKILL.md' -print -quit 2>/dev/null)" ]; then
    CHECKS+=("skill-lint")
  fi
fi

# template-validity — offered iff ≥1 schema-bearing template exists. `find`
# matches dotfiles (shell `*.json` does not); the start point goes through
# bounded_root (a trailing slash would dereference a symlinked templates/).
tv_rc=0
tv_phys=$(bounded_root templates templates) || tv_rc=$?
if [ "$tv_rc" -ge 2 ]; then
  CHECKS+=("template-validity")
elif [ "$tv_rc" -eq 0 ] && \
     [ -n "$(find -P "$tv_phys" -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print -quit 2>/dev/null)" ]; then
  CHECKS+=("template-validity")
fi

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
cd "<REPO_ROOT>" || exit 1
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
cd "<REPO_ROOT>" || exit 1
# ── bounded_root — start-point symlink safety (#1051) ──────────────────────
# A trailing slash dereferences a symlinked START POINT and `-P` cannot undo
# it (the slash is resolved before find ever sees a symlink), so `find
# templates/` on a committed `templates -> /` walks the filesystem. Resolve the
# start point ONCE here (physically), admit it only when its physical path is
# inside the checkout or the matching subtree of the shared agent-infra tree
# (`${AGENT_INFRA_PATH}/<subtree>`), and hand `find` that physical path —
# never a symlink, never a trailing slash. rc 0 = admitted
# (path printed on stdout) / rc 1 = no entry at all (absent) / rc 2 = present
# but outside the permitted boundary, or the checkout root itself could not be
# resolved / rc 3 = present but unverifiable (a plain file, a dangling symlink,
# a symlink loop, an unlistable tree, or otherwise unresolvable). rc 2 and rc 3
# FAIL CLOSED, are
# offered (never silently not offered), and are never scanned. With AGENT_INFRA_PATH unset a symlinked tree is refused, not
# silently dropped. Identical in every block that enumerates a tree.
repo_real=$(pwd -P)
agent_real=""
if [ -n "${AGENT_INFRA_PATH:-}" ] && [ -d "${AGENT_INFRA_PATH}" ]; then
  agent_real=$(cd "${AGENT_INFRA_PATH}" && pwd -P)
fi
bounded_root() {   # $1 candidate start point (may be a symlink) - $2 its subtree under ${AGENT_INFRA_PATH}
  local physical
  [ -n "$repo_real" ] || return 2   # no boundary basis: refuse, never a '/*' wildcard admission
  [ -e "$1" ] || [ -L "$1" ] || return 1   # no entry at all: empty target set
  [ -d "$1" ] || return 3           # present, but not a directory (file, dangling link, loop)
  [ -r "$1" ] || return 3           # present, but not listable: the probe would read empty and vanish
  physical=$(cd "$1" 2>/dev/null && pwd -P) || return 3   # present, but unresolvable
  case "$physical" in
    "$repo_real"|"$repo_real"/*) printf '%s\n' "$physical"; return 0 ;;
  esac
  if [ -n "$agent_real" ] && [ -n "$2" ]; then
    case "$physical" in
      "$agent_real/$2"|"$agent_real/$2"/*) printf '%s\n' "$physical"; return 0 ;;
    esac
  fi
  return 2
}

SKILLS_DIR=""
for c in operations/skills .agents/skills skills; do
  [ -d "$c" ] && { SKILLS_DIR="$c"; break; }
done
# See the Step 1 note: a present-but-unresolvable candidate is rc 3 from
# bounded_root (offered, then refused below) — not "no skills dir resolved".
if [ -z "$SKILLS_DIR" ]; then
  for c in operations/skills .agents/skills skills; do
    { [ -e "$c" ] || [ -L "$c" ]; } && { SKILLS_DIR="$c"; break; }
  done
fi
if [ -z "$SKILLS_DIR" ]; then
  echo "❌ skill-lint: no skills dir resolved — failure to verify (fail-closed)"; exit 1
fi
skills_rc=0
skills_phys=$(bounded_root "$SKILLS_DIR" skills) || skills_rc=$?
case "$skills_rc" in
  0) ;;
  2) echo "❌ skill-lint: $SKILLS_DIR is neither inside the checkout nor under \${AGENT_INFRA_PATH}/skills, or the checkout root itself could not be resolved (repo_real='$repo_real') — refusing to scan (bounded-scan guard, #1051; set AGENT_INFRA_PATH to the shared agent-infra checkout)"; exit 1 ;;
  *) echo "❌ skill-lint: no verifiable skills dir at $SKILLS_DIR (rc=$skills_rc) — failure to verify (fail-closed)"; exit 1 ;;
esac
# The linter's own discovery FOLLOWS a symlinked `SKILL.md` FILE — readdirSync
# reports isDirectory() false for it, so it is not skipped, and readFileSync
# resolves the link. A committed `SKILL.md -> /outside` would therefore be read
# from outside the boundary and reported green. Refuse instead (#1051, C5) —
# pruning the same `_*`/`.*` entries the linter prunes, so the refusal covers
# exactly the linter's own follow set and is not a false red.
if [ -n "$(find -P "$skills_phys" \( -name '_*' -o -name '.*' \) -prune -o \
          -name 'SKILL.md' ! -type f -print -quit 2>/dev/null)" ]; then
  echo "❌ skill-lint: $SKILLS_DIR contains a symlinked SKILL.md entry — the linter would follow it, so its file set cannot be bounded (bounded-scan guard, #1051)"; exit 1
fi
out=$(node scripts/check-skill-lint.mjs --skills-dir "$skills_phys" 2>&1); rc=$?
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
the linter's exit-2 fail-closed path is engaged for a missing dir. The path handed to the linter is
the **physical** root `bounded_root` admitted — the start point is resolved once and this block
follows no symlink afterwards. That is not the same as "nothing symlinked is ever read": the
linter's own discovery follows a symlinked `SKILL.md` *file*, so such an entry is **refused**
above rather than handed over. An absent or unverifiable start point exits 1 (fail-closed), and
one outside the checkout and `${AGENT_INFRA_PATH}/skills` exits 1 with an explicit refusal. The checked-count backstop closes
the vacuity where the linter prints `0 SKILL.md files checked. Clean.` and exits 0.

**template-validity:**
```bash
cd "<REPO_ROOT>" || exit 1
# ── bounded_root — start-point symlink safety (#1051) ──────────────────────
# A trailing slash dereferences a symlinked START POINT and `-P` cannot undo
# it (the slash is resolved before find ever sees a symlink), so `find
# templates/` on a committed `templates -> /` walks the filesystem. Resolve the
# start point ONCE here (physically), admit it only when its physical path is
# inside the checkout or the matching subtree of the shared agent-infra tree
# (`${AGENT_INFRA_PATH}/<subtree>`), and hand `find` that physical path —
# never a symlink, never a trailing slash. rc 0 = admitted
# (path printed on stdout) / rc 1 = no entry at all (absent) / rc 2 = present
# but outside the permitted boundary, or the checkout root itself could not be
# resolved / rc 3 = present but unverifiable (a plain file, a dangling symlink,
# a symlink loop, an unlistable tree, or otherwise unresolvable). rc 2 and rc 3
# FAIL CLOSED, are
# offered (never silently not offered), and are never scanned. With AGENT_INFRA_PATH unset a symlinked tree is refused, not
# silently dropped. Identical in every block that enumerates a tree.
repo_real=$(pwd -P)
agent_real=""
if [ -n "${AGENT_INFRA_PATH:-}" ] && [ -d "${AGENT_INFRA_PATH}" ]; then
  agent_real=$(cd "${AGENT_INFRA_PATH}" && pwd -P)
fi
bounded_root() {   # $1 candidate start point (may be a symlink) - $2 its subtree under ${AGENT_INFRA_PATH}
  local physical
  [ -n "$repo_real" ] || return 2   # no boundary basis: refuse, never a '/*' wildcard admission
  [ -e "$1" ] || [ -L "$1" ] || return 1   # no entry at all: empty target set
  [ -d "$1" ] || return 3           # present, but not a directory (file, dangling link, loop)
  [ -r "$1" ] || return 3           # present, but not listable: the probe would read empty and vanish
  physical=$(cd "$1" 2>/dev/null && pwd -P) || return 3   # present, but unresolvable
  case "$physical" in
    "$repo_real"|"$repo_real"/*) printf '%s\n' "$physical"; return 0 ;;
  esac
  if [ -n "$agent_real" ] && [ -n "$2" ]; then
    case "$physical" in
      "$agent_real/$2"|"$agent_real/$2"/*) printf '%s\n' "$physical"; return 0 ;;
    esac
  fi
  return 2
}

# Two passes: a schema-only enumeration cannot report what it skipped.
tv_rc=0
tv_phys=$(bounded_root templates templates) || tv_rc=$?
case "$tv_rc" in
  0) ;;
  2) echo "❌ template-validity: templates is neither inside the checkout nor under \${AGENT_INFRA_PATH}/templates, or the checkout root itself could not be resolved (repo_real='$repo_real') — refusing to scan (bounded-scan guard, #1051; set AGENT_INFRA_PATH to the shared agent-infra checkout)"; exit 1 ;;
  *) echo "❌ template-validity: no verifiable templates dir (rc=$tv_rc) — failure to verify (fail-closed)"; exit 1 ;;
esac
all_templates=()
while IFS= read -r -d '' f; do all_templates+=("$f"); done < <(find -P "$tv_phys" -type f -print0 2>/dev/null)

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
      if ! err=$(cd / && python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f" 2>&1); then
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
markdown is skipped explicitly, never failed. The enumeration runs over the **physical** root
`bounded_root` admitted (`find -P`, no trailing slash), so a start point that resolves outside the
checkout and `${AGENT_INFRA_PATH}` exits 1 with an explicit refusal before anything is read — never
a partial or out-of-checkout green. `.plist` files are XML — out of scope here, validated by
`scripts/install-launchd.test.sh`; template workflow YAML is also covered by the actionlint gate.

> **Python must run with CWD outside the checkout.** For `python3 -c`, `sys.path[0]` is the current
directory, searched **before** site-packages — so a repo containing a `yaml.py` would have its own
code imported and executed by the verifying agent. Python is therefore invoked from `/` with the
file passed as an absolute path (`cd / && python3 -c '…' "$f"`; `$f` comes from the physical-root
enumeration, so it is already absolute).
>
> **`-I` alone would also close this hole, but `-s` would not** — `-s` only drops the **user**
site-packages directory and leaves the CWD on `sys.path`. And `-I` carries a side effect here: it
drops user site-packages too, turning a user-local PyYAML install into a permanent fail-closed red.
The CWD change closes the same hole without either consequence.
>
> Paths are always passed as **argv**, so a filename can never reach the interpreter source —
> the pre-#1035 form interpolated `$f` into the `python3 -c` source, which was itself an injection.

**ci-config:**
```bash
cd "<REPO_ROOT>" || exit 1
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
- **A scan start point outside the permitted boundary fails.** Each tree enumeration resolves its
  start point physically (`bounded_root`) and admits it only inside the checkout or the matching
  subtree of `${AGENT_INFRA_PATH}`. An out-of-boundary start point is an _offered_ check that **fails**
  (`refusing to scan`), never a silent `not_offered` and never an unbounded walk (#1051). A start
  point that is **present but unverifiable** — not a directory, not listable (mode 111), or `cd`/`pwd -P`
  fails on it — is
  treated the same way: offered, then failed (`no verifiable …`), never silently dropped. Only a
  genuinely **absent** start point (no entry at all) has an empty target set
  and is therefore not offered. This is the deliberate exception to *"an absent surface is not
  offered"*: the surface is present, it is just not verifiable within the declared boundary, so
  silence would be a false green.
- **Log check output as evidence** for failures.
- **Available checks vary by repo** — a repo with none of the four surfaces legitimately reports
  `skip`; that is distinct from a present-but-unverifiable surface, which fails.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
