---
title: "#1051 — infra-verify: bound every find start point (bounded-scan root)"
type: engineering
domain: platform
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-15
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1051, issue-1035, issue-1080, issue-1081, issue-1082, issue-1083, issue-1084, infra-verify, bounded-scan
---

# #1051 — `infra-verify`: bound every `find` start point (bounded-scan root)

<!-- research-path: issue-scoping (problem-diverge → problem-converge) + problem-verify; solution-diverge → solution-converge + solution-verify; Phase 7 adversarial gates -->
<!-- plan-review: NOT RUN — this is the issue-scoping artifact for #1051, gated by the Phase 7 review cycles logged below (2 cycles, adversarial cap). If this doc is promoted to an execution plan, run plan-review first. -->

**Issue:** daniel-ospina/agent-infra#1051 · **Tier:** standard (skill-domain upgrade) · **Component:**
`skills/post-deploy-verify/infra-verify/SKILL.md` · **Parent:** #1035 (PR #1046) · **Domain:** adversarial
(gate/enforcement — "a repo-committed symlink cannot make the scan escape or false-green")

## Confirmed problem

`infra-verify`'s `find <dir>/` enumerations dereference a symlinked **start point**. POSIX evaluates
each path operand "unaltered as it was provided, including all trailing `<slash>` characters", so the
slash is resolved during pathname resolution and `-P` (the default, which governs only symlinks met
*during* traversal) never sees a symlink to protect. A repo that commits `templates` (or a skills dir)
as a symlink to `/` or `$HOME` therefore turns a bounded in-checkout scan into a filesystem-wide walk —
scan amplification, out-of-repo reads, and a green over a tree that is not the checkout's `templates/`.

The trailing slash was **deliberate** (#1035): consumer repos symlink a shared skills tree whose
target lives outside the checkout, and #1035's verification case (i) pins "a symlinked resolved skills
dir → `skill-lint` still offered". So a naive containment guard (`resolved path must be under $PWD`)
attacks the intended feature — empirically confirmed: `find skills -name SKILL.md` yields 0 on the
symlinked consumer trees, i.e. dropping the slash alone silently un-offers the check (a false green of
the same class as the bug).

**Confirmed definition (Phase 2, confidence 88/100):** every `find`-based enumeration must resolve
each start point once to its **physical** path and admit it only when that path lies inside the
checkout or the **matching subtree** of `${AGENT_INFRA_PATH}` (set and resolvable), failing closed
with an explicit refusal otherwise.

## Adversarial threat surface (`[ADVERSARIAL-BOUND]`)

In scope — each class has a runnable test in `extensions/shared/test-infra-verify-scan.mjs`:

| # | Adversarial input | Required behaviour | Test |
|---|---|---|---|
| C1 | start-point symlink → out-of-checkout dir (`templates -> /`, `skills -> <outside>`) | Step 1 **offers**; Step 2 exits non-zero, explicit refusal; no outside path enumerated | A, E |
| C2 | start-point symlink → shared tree, **non-matching** subtree (`templates -> $AGENT_INFRA_PATH/skills`) | refused (subtree bound) | B2 |
| C3 | symlink in an **intermediate** path component (`operations -> <outside>`, real `skills` beneath) | whole-chain physical resolution refuses it | F |
| C4 | **unresolvable** start point — dangling symlink **or symlink loop** (`ELOOP`), on either start point (`templates` **or** `skills`) | present, so **offered**; Step 2 fails closed; no walk, never silently un-offered | H (templates) + P (skills: dangling, loop, plain file) + absent twins |
| C5 | symlinked **descendant** (`templates/nested -> <outside>`; `skills/x/SKILL.md -> <outside>`) | `find` engine: not traversed (`-P`); delegated linter: **refused** (it *does* follow a symlinked `SKILL.md` file) | G (+ `-L` twin), M (+ linter twin) |
| C6 | vulnerable start-point forms in shipped source (`find <dir>/`, `find -H`, `find -L`, variable + slash) | absent from every shipped bash fence | I |
| C7 | boundary basis unavailable (`repo_real=""` from a failed `pwd -P`) | refused — no `"/*"` wildcard admission | J |
| C8 | `AGENT_INFRA_PATH` misconfigured (regular file, `/`, dangling, symlink, relative) | file//`/`/dangling → refuse; symlink/relative → resolve and admit only the matching subtree | N |
| C9 | **unchecked `cd <REPO_ROOT>`** silently rebasing `repo_real` to the ambient cwd (a substitution containing a space, an invoker whose cwd is `/`) | every block fails hard on a failed `cd` (`cd "…" || exit 1`), and no unquoted/unchecked form ships | L, I |
| C10 | the symlinked-`SKILL.md` refusal being **wider than the linter's own prune set** (a `_*`/`.*` entry the linter never reads) | no false red — the refusal mirrors `check-skill-lint.mjs`'s prune exactly | M2 |

Out of scope (stated, not chased):

- **TOCTOU** between `bounded_root`'s resolve and the subsequent read (needs a concurrently mutating
  repo; a WARN-ONLY local check has no adversary process model). Mitigated by physical path + `-P`.
- **Operator-controlled `AGENT_INFRA_PATH`** — the boundary is *defined* by that trusted env value.
- **Single-level glob enumerations** (`scripts/*.mjs`, `.github/workflows/*.yml`) — bounded (not
  unbounded) but they do follow a symlinked path component → **#1083**; the skill's prose says so and
  does not claim them.
- **The per-skill-symlink consumer layout** (`operations/skills/<name> -> …`) leaving `skill-lint`
  un-offered — pre-existing on `origin/main`, and it needs the linter's discovery semantics changed →
  **#1084**.

## Plan

**Approach A (chosen): resolve-once + permitted-root allowlist, inline per self-contained block.**

- `repo_real=$(pwd -P)`; `agent_real=$(cd "${AGENT_INFRA_PATH}" && pwd -P)` when the var is set and a
  directory.
- `bounded_root DIR SUBTREE` → rc 0 prints the **physical** path / rc 1 absent (empty target set) /
  rc 2 out-of-boundary or no boundary basis / rc 3 present-but-unverifiable. rc 2 and rc 3 both fail
  closed; the caller is offered so the failure is loud.
- Callers pass the physical path to `find -P` with **no trailing slash**; the allowlist is
  `$repo_real` *or* `$agent_real/$SUBTREE` (`skills`, `templates`) — the matching subtree, never the
  whole shared checkout.
- `skill-lint` delegates to `check-skill-lint.mjs` on the physical root and **refuses** a symlinked
  `SKILL.md` entry, because that engine follows it (out-of-boundary read + false green otherwise).

**Rejected alternatives.** *Containment to `$PWD`* — breaks the six consumer repos that symlink a
shared tree. *Drop the trailing slash alone* — silently un-offers the check (false green). *`find -P
<dir>/`* — a no-op: the slash is resolved before `find` runs. *`find -H`* — dereferences the start
point by design (twin-verified leak). *Depth/count cap only* — no boundary rule, and truncation is a
false green. *`git ls-files`/`git grep`* — cannot enumerate an out-of-tree symlinked tree and cannot
see untracked files. *Root-anchored traversal (`find -P . -path './skills/*'`)* — a symlinked tree
yields 0 matches → the same silent un-offer. *Git-identity containment* — adds a `git` subprocess per
scan and widens the boundary to "any repo with an agent-infra origin". *`openat2 RESOLVE_BENEATH`* —
unavailable in bash 3.2 / BSD userland.

**Kept inline, not extracted.** The skill's blocks are fresh-shell and copy-paste executable, and a
new `scripts/` dependency would make the checks fail in materialized consumer checkouts that lack the
agent-infra `scripts/` tree (#1049 is that false-red). Drift is pinned by a test that asserts the
three preambles are byte-identical.

## Wiring

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| `skills/post-deploy-verify/infra-verify/SKILL.md` — 4 start points, 3 blocks | skill bash | `bounded_root` + `find -P`; tests A/B/B2/D/E/F/H | ✅ |
| `${AGENT_INFRA_PATH}` boundary contract | skill contract / env | Contract "Input" line + C8 tests | ✅ |
| Delegated linter (`check-skill-lint.mjs`) | external tool | physical `--skills-dir` + symlinked-`SKILL.md` refusal (test M) | ✅ |
| CI per-PR | `.github/workflows/ci.yml` `verify` job | new step (`node extensions/shared/test-infra-verify-scan.mjs`); does **not** touch the lockstep-pinned `test-command` scalar | ✅ |
| CI post-merge | `extensions/*/test*.mjs` glob (ci-main.yml) | filename matches the existing glob | ✅ |
| Workflow byte-lock | `scripts/workflow-lock.json` | re-locked with `node scripts/check-workflow-lock.mjs --update-lock` | ✅ |
| Data stores / APIs / auth / UI | — | none | n/a |

## Verification

`node extensions/shared/test-infra-verify-scan.mjs` → **66 passed, 0 failed**. Negative twins executed
in the same suite: `find <dir>/`, `find -H`, `find -L` each LEAK the sentinel while the fixed form
refuses; the delegated linter's follow of a symlinked `SKILL.md` is exercised both ways (refused by the
skill, reproduced by the linter). Mutation-verified RED (each mutation applied to a scratch copy, never
the tracked file): pre-fix `find templates/` revert, `-P` dropped, empty-boundary guard dropped, rc-3
folded into rc-1, Step 1 not offering on rc≥2, the skills admission guard removed (M4, caught by case
E), the `[ -L ]` probe removed (M5, the loop cases), `|| exit 1` removed (M6, tripwire), a one-sided
preamble divergence (M7b), the linter-prune dropped (M8, case M2), and the skills two-pass candidate
resolution reverted to `[ -d ]` only (M9, case P). A regression in the fixed form cannot trigger the
catastrophe it guards: the sentinel is a tiny temp tree, **never `/`**.

Also green: `node scripts/check-workflow-lock.mjs`, `node scripts/check-pi-pin-lockstep.mjs` (123/0),
`node scripts/check-skill-lint.mjs --skills-dir skills` (123 checked, clean), the ci.yml literal-path
fence, and `bash -n` on every fence.

## Review cycle log

- **problem-verify** (1 cycle): P1 — sibling same-class defects were "filed separately" in prose but
  never filed → filed **#1080** (`check-test-wipes.sh`), **#1081** (`check-skill-links.sh` dead
  `[ -L ]`), **#1082** (find-bugs + codebase-audit prose). P2 ×4 → tightened the allowlist to the
  matching subtree, made the refusal actionable, corrected the overstated consumer evidence (7 `*/skills`
  symlinks, 2 dangling; `operations/skills` is a real dir in every functional consumer), and this
  document is the persisted research record. P3 ×2 → corrected the precedents cited (the sound one is
  `scripts/pi-task-session-prune.sh:157-181`; `check-skill-links.sh:55,69` is the counter-example) and
  widened the drift pin to the whole preamble.
- **solution-verify** (1 cycle): P0 — (1) `check-skill-lint.mjs` follows a symlinked `SKILL.md` *file*
  (out-of-boundary read + false green) and declared class C5 covered it only for the `find` engine →
  refused in the skill + test M with a linter twin; (2) declared class C8 had no test → test N. P1 —
  C6's `find -H` absence was unasserted → tripwire. P2 — rc 1 conflated "absent" with "present but
  unverifiable" → rc 3 split + test O; no plan doc → this file. P3 — the test header overclaimed "never
  on a self-reported marker" → corrected.
- **Phase 7 cycle 1** (Agents #1 codebase/docs + #4 devil's advocate, parallel, fresh contexts; #2 UX
  skipped — no UI surface, #3 epic — standalone issue):
  - **P0 (devil's advocate)** — an `ELOOP`/self-referential start point failed `[ -e ]` and was folded
    into rc 1 "absent", so a *present* check was silently un-offered **against the artifact's own
    contract** (a false green — the exact failure mode this issue exists to remove). Fixed: the helper
    now tests `[ -e ] || [ -L ]` (an entry that exists but does not resolve), so dangling **and** looping
    symlinks are rc 3 → offered → failed closed; C4 restated; case H covers both plus an absent twin.
  - **P1 (devil's advocate)** — declared class C1's *skills* half was **not** test-covered: case E's
    fixture omitted the `scripts/` symlink, so the delegated linter died `MODULE_NOT_FOUND` and the
    block exited 1 for a reason unrelated to the guard — deleting the guard left E 4/4 green. Fixed:
    E now links `scripts/` and asserts the boundary-refusal wording (mutation `M4` → RED on `#1051 E`),
    and the missing skills twin of B2 was added (E2).
  - **P1 (devil's advocate)** — the boundary basis is the post-`cd` cwd and `cd <REPO_ROOT>` was neither
    quoted nor checked: a substitution containing a space silently rebased `repo_real` to the ambient
    cwd (a false green; not repo-committable, so not a bypass of the declared claim, but a real
    false-green path and the only story in the pre-mortem that reaches a whole-filesystem walk). Fixed:
    all five blocks are now `cd "<REPO_ROOT>" || exit 1`, pinned by a tripwire.
  - **P2 (codebase/docs)** — the symlinked-`SKILL.md` refusal did not prune the `_*`/`.*` entries the
    linter prunes → false red with a false justification. Fixed (prune mirrored) + case M2.
  - **P2 (devil's advocate)** — the byte-identity pin used a lazy `[\s\S]*?\n\}` regex that a column-0
    `}` would truncate. Fixed: brace-counting extraction (M7b → RED).
  - **P2 (codebase/docs)** — stale `ci.yml:269` citation (the +13-line step moved it) → cited by step
    name; missing `research-path` marker → added (and an honest note that `plan-review` was **not** run
    rather than a forged clean signature).
  - Clean dimensions reported by both: three preambles byte-identical (independent extraction, same
    sha256); bash 3.2 + GNU findutils both enforce the trailing-slash dereference (so the twins are not
    Linux-only); CI wiring minimal and lockstep-scalar untouched; no in-scope boundary escape or
    out-of-boundary read reproduced by any repo-committable input.
- **Phase 7 cycle 2** (fresh Agents #1 and #4; this is the last cycle under the adversarial bound):
  - **P1 (codebase/docs, NEW, fixed in-cycle)** — the `skills` candidate resolution was `[ -d ]`-only,
    so a **present** but unresolvable `skills` entry (dangling symlink, symlink loop, plain file) never
    reached `bounded_root`: `skill-lint` was silently un-offered while the same diff's prose promised
    "never silently dropped", and C4 named only `templates`. This is live, not theoretical — the plan
    doc's own consumer evidence records **2 of 7** consumer `*/skills` symlinks as dangling. Fixed with
    a two-pass resolution that keeps directory precedence and lets a present non-directory reach
    `bounded_root` (rc 3 → offered → refused), plus the C4 skills twins as test P (dangling, loop,
    plain file, precedence, absent twin); mutation `M9` → RED.
  - Agent #1 re-verified all three cycle-1 fixes empirically (prune-scoped refusal, citation by step
    name, honest `plan-review: NOT RUN`) and re-ran every gate; numbers in this doc reproduce exactly.
  - **Agent #4 (devil's advocate) stalled** (harness silence threshold, zero tool activity) and returned
    no verdict; re-dispatched against this final tree for the adversarial verdict. Its cycle-1
    reproduction attempt found no in-scope boundary escape.

### Adversarial-bound disclosure

`[ADVERSARIAL-BOUND] cycles=2 threats=10 covered=10 residuals=#1083,#1084` — acceptance here is
**declared-threat-surface coverage** (every class C1–C10 test-covered + green CI), not a literal
`NO ISSUES FOUND`; the two residuals are filed and deliberately not chased. Class C10 and the cycle-2
P1 were found by these gates and fixed in-cycle; the bound was not consumed to hide an unresolved
issue.
- **duplication & architecture reviewer** (advisory): `unify-contract-keep-drivers` on the containment
  predicate duplicated across scripts — recorded, not actioned here (the skill cannot `source` a helper;
  a shared contract doc is the follow-up home). `keep separate` on the 3 in-file copies (byte-identity
  pinned) and on the CI dual-run. Its two live duplicates are already filed: #1082 (sibling skills) and
  the `${AGENT_INFRA_PATH}` "unset" divergence (`link-skills.sh` silently falls back to
  `$HOME/agent-infra`, `bounded_root` refuses) is recorded here as a residual.

## Residuals (declared)

1. `${AGENT_INFRA_PATH}` "unset" has two meanings in-repo: `scripts/link-skills.sh` falls back to
   `$HOME/agent-infra`; `bounded_root` refuses. The refuse is the safe direction; unifying the
   vocabulary is a follow-up (duplication review, D-finding 3).
2. The containment predicate is reimplemented in five places across the repo with no shared
   declaration (`scripts/pi-task-session-prune.sh`, `checkout_guard.sh`, `check-test-regression.cjs`,
   `is-main.mjs`, this skill). Follow-up: one declared contract.
3. #1083 (glob enumerations) and #1084 (per-skill-symlink consumer `skill-lint`) — filed, not chased.
4. `.github/workflows/ci.yml`'s literal-path fence (`grep -rE … skills/ extensions/ scripts/`, step
   "Literal-path fence") follows a symlinked path component, but its polarity is over-block
   (fail-closed), so per the A/B rule it is a **B** item and is deliberately not filed: if never fixed,
   the cost is a spurious red plus runner time.
5. **Out-of-scope by declaration, re-confirmed in cycle 1:** TOCTOU between resolve and read
   (no adversary process model for a WARN-ONLY local check); `AGENT_INFRA_PATH` itself is trusted
   (it *defines* the boundary); the negative twins hard-fail if some future `findutils` stops
   dereferencing a trailing-slash start point — a deliberate vacuity guard, documented in the test
   header.
6. **Cycle-2 adversarial P2, declined as a work item (A/B rule → B, fail-closed):** the
   symlinked-`SKILL.md` refusal uses `! -type f`, which is wider than the linter's read set for a
   *directory* literally named `SKILL.md` (the linter recurses into it rather than reading it), so
   that contrived layout gets a spurious red with a misleading message. Over-block, not fail-open:
   if it is never fixed the cost is a spurious red plus runner time ("nothing but time"), so per the
   A/B rule it is recorded and not filed. Related coupling note: the refusal's shape mirrors the
   linter's follow set by comment + the shared prune expression, not by a test that asserts the
   *linter's* follow set independently — a future linter change (e.g. it starts recursing into
   symlinked dirs) would need the refusal re-derived.
