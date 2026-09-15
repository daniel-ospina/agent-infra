---
title: "#1051 — infra-verify: bound every find start point (bounded-scan root)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-15
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1051, issue-1035, issue-1080, issue-1081, issue-1082, issue-1083, issue-1084, infra-verify, bounded-scan
---

# #1051 — `infra-verify`: bound every `find` start point (bounded-scan root)

<!-- research-path: issue-scoping (problem-diverge → problem-converge) + problem-verify; solution-diverge → solution-converge + solution-verify; Phase 7 adversarial gates -->
<!-- plan-review: cycles=2, status=clean, exit_reason=adversarial-threat-surface-covered, tier=standard, version=2.3.0 -->

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
| C2 | start-point symlink → shared tree, **non-matching** subtree (`templates -> $AGENT_INFRA_PATH/skills`, or a name-**prefix** sibling of the matching subtree) | refused (subtree bound **and** the trailing-`/` separator on the shared-tree arm) | B2, E2, K2, E2b |
| C3 | symlink in an **intermediate** path component (`operations -> <outside>`, real `skills` beneath) | whole-chain physical resolution refuses it | F |
| C4 | **unresolvable** start point — dangling symlink **or symlink loop** (`ELOOP`), on either start point (`templates` **or** `skills`) | present, so **offered**; Step 2 fails closed; no walk, never silently un-offered | H (templates) + P (skills: dangling, loop, plain file) + absent twins |
| C5 | symlinked **descendant** (`templates/nested -> <outside>`; `skills/x/SKILL.md -> <outside>`) | `find` engine: not traversed (`-P`); delegated linter: **refused** (it *does* follow a symlinked `SKILL.md` file) | G (+ `-L` twin), M (+ linter twin) |
| C6 | vulnerable start-point forms in shipped source (`find <dir>/`, `find -H`, `find -L`, and **any** quoting form of a trailing slash: `find "$var/"`, `find skills/`) | absent from every shipped bash fence — asserted on the actual operand of every non-comment `find`, with anti-vacuity twins per form | I |
| C7 | boundary basis unavailable (`repo_real=""` from a failed `pwd -P`) | refused — no `"/*"` wildcard admission | J |
| C8 | `AGENT_INFRA_PATH` misconfigured (regular file, `/`, dangling, symlink, relative) | file//`/`/dangling → refuse; symlink/relative → resolve and admit only the matching subtree | N |
| C9 | **unchecked or non-failing `cd <REPO_ROOT>`** (`cd $x`, `cd "$x"`, `cd "$x" \|\| true`, `cd "$x" \|\| exit 0`) silently rebasing `repo_real` to the ambient cwd | every block is `cd "<REPO_ROOT>" \|\| exit 1` (predicate self-tested per form) **and** behaviourally: each block run with `<REPO_ROOT>` unsubstituted exits non-zero and enumerates nothing in the ambient cwd | L, I, R1, R2 |
| C10 | the symlinked-`SKILL.md` refusal being **wider than the linter's own prune set** (a `_*`/`.*` entry the linter never reads) | no false red — the refusal mirrors `check-skill-lint.mjs`'s prune exactly | M2 |
| C11 | a start point that is **present but unlistable** (mode 111: `[ -d ]` passes because it needs only `+x`, `find` cannot read it) | rc 3 → offered → failed closed with its own verdict, so the check cannot vanish silently | Q |

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
| `skills/post-deploy-verify/infra-verify/SKILL.md` — **3 `bounded_root` preambles across 5 executable fences** (all five `cd`-guarded) covering 4 `find` start points | skill bash | `bounded_root` + `find -P`; tests A/B/B2/D/E/E2/F/H/P/Q/R1/R2/K2/E2b/S | ✅ |
| `templates/` enumeration, symlinked skills dir, **`ci-config` enumeration** (the three surfaces #1051 names) | skill bash | the first two are covered above; `ci-config` uses single-level globs (`.github/workflows/*.yml`) that follow a symlinked path component — **deferred → #1083** (bounded, so fail-open is not reachable; the prose says so and does not claim otherwise) | ⚠️ deferred |
| `${AGENT_INFRA_PATH}` boundary contract | skill contract / env | Contract "Input" line + C8 tests | ✅ |
| `${AGENT_INFRA_PATH}` unset vs `scripts/link-skills.sh` (`$HOME/agent-infra` fallback) | env contract | **deliberate divergence**, documented in the skill's Contract and pinned by test R (a symlinked tree with the var unset is offered, then refused naming the var — never a silent skip). The ≥5 in-repo fallback definitions are folded into **#1096** | ⚠️ residual |
| Containment predicate (this skill, `pi-task-session-prune.sh`, `check-test-regression.cjs`) | shared policy | **#1096** — one declared contract + a CI parity test, with a named owner and a dated trigger | ⚠️ filed |
| Delegated linter (`check-skill-lint.mjs`) | external tool | physical `--skills-dir` + symlinked-`SKILL.md` refusal (test M) | ✅ |
| CI per-PR | `.github/workflows/ci.yml` `verify` job | new step (`node extensions/shared/test-infra-verify-scan.mjs`); does **not** touch the lockstep-pinned `test-command` scalar. Failure modes: step not wired (suite never runs per-PR; the post-merge glob catches it later), suite red (blocks the `verify` job), suite timeout (bounded: ~4s, every bash call capped) | ✅ |
| CI post-merge | `extensions/*/test*.mjs` glob (ci-main.yml) | filename matches the existing glob. Failure mode: filename drift silently drops the post-merge lane | ✅ |
| Workflow byte-lock | `scripts/workflow-lock.json` | re-locked with `node scripts/check-workflow-lock.mjs --update-lock`. Failure modes: lock not re-locked (ci.yml hash mismatch → `check-workflow-lock.mjs` red), lockstep scalar disturbed (`check-pi-pin-lockstep.mjs` red) | ✅ |
| Plan doc | `docs/plans/2026-09-15-issue-1051-bounded-scan-root.md` | this artifact (issue-scoping + the plan-review gate) | ✅ |
| Data stores / APIs / auth / UI | — | none | n/a |

## Verification

`node extensions/shared/test-infra-verify-scan.mjs` → **98 passed, 0 failed**. Negative twins executed
in the same suite: `find <dir>/`, `find -H`, `find -L` each LEAK the sentinel while the fixed form
refuses; the delegated linter's follow of a symlinked `SKILL.md` is exercised both ways (refused by the
skill, reproduced by the linter). Mutation-verified RED (each mutation applied to a scratch copy, never
the tracked file): pre-fix `find templates/` revert, `-P` dropped, empty-boundary guard dropped, rc-3
folded into rc-1, Step 1 not offering on rc≥2, the skills admission guard removed (M4, caught by case
E), the `[ -L ]` probe removed (M5, the loop cases), `|| exit 1` removed (M6, tripwire), a one-sided
preamble divergence (M7b), the linter-prune dropped (M8, case M2), the skills two-pass candidate
resolution reverted to `[ -d ]` only (M9, case P), the unlistable-start-point guard removed (M10, case
Q), `|| exit 1` weakened to `|| true` (M11, the `cd` predicate), a `find "$tv_phys/"` folded back into a
fence (M12 — a form the pre-review tripwire missed), `|| true` in **only the two blocks** whose case-R
arm was previously not load-bearing (M13), and the `uncheckedCd` regex neutered (M14 — the
anti-vacuity twins were inert until the fix-round review caught it). A regression in the fixed form cannot trigger the
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
    name; missing `research-path` marker → added. The `plan-review` marker was recorded as **NOT RUN**
    until the commit-workflow gate, which is what caused the code-review round to run the gate; the
    header now carries its real two-cycle signature (clean, adversarial exit).
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
    name — and `plan-review: NOT RUN` was honest *at that point*, but the marker was subsequently
    superseded by the real gate run, see the commit-workflow round below) and re-ran every gate;
    numbers in this doc reproduce exactly.
  - **Agent #4 (devil's advocate) stalled** (harness silence threshold, zero tool activity) and returned
    no verdict; re-dispatched against this final tree for the adversarial verdict. Its cycle-1
    reproduction attempt found no in-scope boundary escape.

- **commit-workflow code-review gate** (PR #1090, 8 agents: Guidance, Bug scan two-pass, History +
  prior PR comments, Security, Skill Infrastructure, Ontology & Templates, Config, test review):
  - **Clean:** Security `NO ISSUES FOUND`; Config `NO ISSUES FOUND` (YAML parses, step gates, lock
    digest-only change, lockstep scalar byte-identical and untouched, both CI lanes wired, ~4s
    runtime, no permissions/triggers changed).
  - **P1 (test review)** — the C6 tripwire's slash regex required the slash *outside* the quotes, so
    `find "$tv_phys/"` and `find skills/` appended to a fence left the suite GREEN (mutation M12 now
    proves it red). Fixed by asserting the actual **operand** of every non-comment `find`, with an
    anti-vacuity twin per quoting form and an in-situ append twin.
  - **P1 (plan-review #2)** — C9 was only string-asserted: `|| true` and `|| exit 0` passed the old
    tripwire and nothing ran a block with `<REPO_ROOT>` unsubstituted. Fixed: the `cd` predicate is a
    self-tested function (5 lines must be `cd "…" || exit 1`), plus case **R**, which runs each block
    against a nonexistent repo root and asserts non-zero rc **and no sentinel leak** from the ambient
    cwd.
  - **P1 (plan-review #1)** — two deferred residuals had no re-check mechanism → **#1096** filed with
    a named owner and a dated trigger; residual 1 given an explicit A/B disposition instead of
    "follow-up".
  - **P1 (history)** — #1035's pinned case (i) is satisfied only when `${AGENT_INFRA_PATH}` resolves;
    the env-unset consumer shape was neither pinned nor disclosed at the claim sites. Fixed: test **R**
    pins offered-then-refused-naming-the-var, the skill's Contract now states the divergence
    explicitly (and references `link-skills.sh`), and the plan doc's residual 1 records ≥5 in-repo
    unset definitions instead of two.
  - **P2 (bug scan)** — a start point that is **present but unlistable** (mode 111 passes `[ -d ]`,
    which needs only `+x`) made the offer probe read empty and the check *vanish* — the same false-green
    class this issue removes. Fixed: `[ -r "$1" ] || return 3` → new declared class **C11** + case Q
    (skipped as root, where the assertion would be vacuous).
  - **P2 (bug scan)** — rc 2 conflated "outside the boundary" with "no boundary basis", so the refusal
    pointed the operator at `AGENT_INFRA_PATH` when the checkout root was the unresolvable part. Fixed:
    the refusal names both causes and prints `repo_real`.
  - **P2 (guidance + ontology)** — `type: Bounded` on a 495-line skill; `version:` absent from the
    writing-skills schema; `domain: platform`; `un-offered` coined against the canonical
    `not offered` / `not_offered`; "bounded" used in two senses one paragraph apart; the Contract named
    an input the router never passes; `<REPO_ROOT>`'s substitution contract undefined on both sides.
    All fixed (domain → `operations`; the four prose fixes; the Contract now says the variable is read
    from the environment, not passed) or recorded as a scoped deviation (Bounded, `version`).
  - **P2 (history)** — the #1049 citation was stale (`closed NOT_PLANNED` 15h before the comment) and
    #1050 (the "no gate executes a skill's inline blocks" mechanism, also `NOT_PLANNED`) was
    unreferenced. Both corrected in the doc; the suite header now names #1050 and states the suite is a
    one-off pin, not that mechanism.
  - **P2 (duplication, advisory)** — the containment predicate is 3 implementations (corrected from
    "five places": `checkout_guard.sh`/`is-main.mjs` are equality/identity tests) and
    `${AGENT_INFRA_PATH}` unset has ≥5 definitions; both folded into **#1096**. The advisory
    `keep separate` verdicts (in-file copies, test harness) are recorded, not actioned.

- **commit-workflow re-review round** (fresh plan-review #1/#2 cycle 2 + fresh code-review bug scan +
  adversarial fix-verifier):
  - **Adversarial fix-verifier: `THREAT SURFACE COVERED`** — all nine probes (out-of-boundary skills,
    empty `repo_real`, candidate precedence, symlinked `SKILL.md` under a pruned name, prune-set parity
    in both directions, mode-111 nested dir, literal `<REPO_ROOT>`, descendant symlink, mode-111 start
    point) came back refused or fail-closed; no in-scope bypass reproduced.
  - **P2 (conf 97, test review)** — the `uncheckedCd` anti-vacuity twins were **inert**: each twin ran
    the predicate on a one-line fixture, so `cds.length !== 5` short-circuited and the regex was never
    exercised (neutering the regex left the suite green). Fixed: twins are built from the real source
    with the vulnerable form substituted, plus a twin asserting the predicate is *false* on the
    pristine source; mutation M14 → RED.
  - **P2 (conf 90, test review + bug scan)** — case R's template-validity/skill-lint arms were not
    load-bearing: the sentinel-only fixture made those blocks refuse anyway, so a fail-open `cd` still
    satisfied `rc !== 0`. Fixed: split into **R1** (in-boundary start points in the fixture cwd, so a
    rebased block *succeeds* — and an added diagnostic assertion excludes a crashed block) and **R2**
    (the #1035 env-unset shape); mutation M13 → RED on `#1051 R1: template-validity`.
  - **P2 (conf 75, bug scan)** — the new C11 class (present but unlistable) was implemented and tested
    but **not named** in the rc-3 legend or the Contract's closed enumeration, so a reader following
    the contract would conclude a mode-111 tree is admitted. Fixed in all three legends (still
    byte-identical) and the Contract bullet.
  - **P2 (conf 60, bug scan)** — case Q captured the original mode but never restored it (`void prev`);
    an abnormal exit could leave a mode-111 tree that `rmSync` cannot empty. Fixed with `try`/`finally`
    restoring the captured modes.
  - **Fresh post-fix verification round** (two independent fresh reviewers, after the fixes above):
    - **P1 (conf 95, test quality)** — the shared-tree arm's separator, `"$agent_real/$2"/*`, was
      **unpinned**: `"$agent_real/$2"*` left the suite green, and `templates ->
      ${AGENT_INFRA_PATH}/templates-evil` was then scanned and reported green — the same false-PASS
      class on the delegated-tool path. Fixed: cases **K2** (templates arm) and **E2b** (skills arm)
      with prefix-sibling dirs under the allowed tree; mutation M39 → RED on both.
    - **P2 (conf 95, test quality)** — `leaksOutside` had **no positive control**: all nine uses are
      negated, so `() => false` was undetected, and a refusal that echoed the out-of-boundary physical
      path could leak with the suite green. Fixed: a positive-control twin (T1 → RED).
    - **P2 (conf 90, test quality)** — case Q accepted either refusal wording, so
      `[ -r "$1" ] || return 2` passed while the block claimed a present in-checkout tree was *outside*
      the boundary; and the linter's `checked 0` backstop was unpinned. Fixed: Q asserts each label's
      own rc-3 verdict (M32 → RED) and case **S** pins the 0-lint backstop (M29 → RED).
    - **P2 (conf 85, test quality)** — case F's fixture lacked the `scripts` symlink its own comment
      claimed, so its refusal rested on wording alone. Fixed: fixture aligned and a leak assertion added.
    - **P2 ×5 (conf 85–100, consistency)** — the issue comment still carried `66 passed` and the
      pre-C11 rc-2 definition, called #1049 a *live* issue (it is closed `NOT_PLANNED`), and the plan
      doc said C1–C10 / "two residuals" / a 495-line skill / `tests …/Q/R`. All corrected.

  - **P2 (conf 90/68, plan-review)** — the `plan-review` marker and two "not run" statements were stale
    once the gate ran, and the **scoping comment** still carried the old counts and the rc-2 definition
    without "no boundary basis". Fixed: the marker now carries the gate's real signature, and the issue
    comment was edited to mirror the doc.

### Adversarial-bound disclosure

`[ADVERSARIAL-BOUND] cycles=2 threats=11 covered=11 residuals=#1083,#1084,#1096` — acceptance here is
**declared-threat-surface coverage** (every class C1–C11 test-covered + green CI), not a literal
`NO ISSUES FOUND`; the three residuals are filed and deliberately not chased. Class C10, the cycle-2
P1 and C11 were found by these gates and fixed in-cycle; the bound was not consumed to hide an
unresolved issue.
- **duplication & architecture reviewer** (advisory): `unify-contract-keep-drivers` on the containment
  predicate duplicated across scripts — recorded, not actioned here (the skill cannot `source` a helper;
  a shared contract doc is the follow-up home). `keep separate` on the 3 in-file copies (byte-identity
  pinned) and on the CI dual-run. Its two live duplicates are already filed: #1082 (sibling skills) and
  the `${AGENT_INFRA_PATH}` "unset" divergence (`link-skills.sh` silently falls back to
  `$HOME/agent-infra`, `bounded_root` refuses) is recorded here as a residual.

## Residuals (declared)

1. `${AGENT_INFRA_PATH}` "unset" has **≥5** distinct in-repo definitions, not two (`link-skills.sh`
   and `check-skill-links.sh` → `$HOME/agent-infra`; `materialize-agents.sh` → `$self_dir`;
   `check-agents-materialized.sh` → `$HERE/..`; `install-launchd.sh` → `resolve_infra_main()`;
   `bounded_root` → refuse). This change **deliberately does not adopt the `$HOME/agent-infra`
   fallback**: that would make an implicit ambient path a boundary basis, widening the trust surface
   this issue exists to bound — and the adversarial bound for that surface is spent (see the
   disclosure below), so a post-bound change there would ship unreviewed. The refusal is fail-closed;
   the consumer-facing consequence — a symlinked tree created by `link-skills.sh` in an environment
   that never exported the variable goes from *scanned* to *refused* — is accepted as a false red
   (spurious red: the class #1049 was closed as on 2026-09-15), now pinned by test R and documented
   in the skill's Contract. Vocabulary unification is folded into #1096.
2. The containment predicate is reimplemented in **three** places — `scripts/pi-task-session-prune.sh`
   (`safe_child_dir` / `path_inside_root`), `scripts/check-test-regression.cjs`, and this skill —
   across 5+ call sites, with no shared declaration and no parity test. (`checkout_guard.sh:83` and
   `is-main.mjs:215` are equality/identity tests, not containment — corrected from an earlier
   "five places" claim.) **Filed as #1096**, with a named owner and a dated trigger, because the
   review gate requires deferred work to carry a re-check mechanism; `#1080`/`#1081`/`#1082` are
   cited there as instances of the drift it prevents.
3. #1083 (glob enumerations), #1084 (per-skill-symlink consumer `skill-lint`) and #1096
   (containment contract + parity test) — filed, not chased.
3a. **C10's opposite direction is declared out of scope:** the refusal is pinned against the linter's
   *current* follow set (tests M/M2), but a future `check-skill-lint.mjs` that *widens* what it reads
   (e.g. starts recursing into symlinked dirs) would turn nothing red. Any change to that script must
   re-derive the refusal; the coupling is a comment-level contract today, not a test.
3b. `type: Bounded` on a now-510-line skill is **pre-existing** (~297 at HEAD) and deliberately **not**
   restructured here: the three byte-identical preamble copies are forced by the copy-paste-executable
   block contract (a fresh shell cannot `source` a helper), and splitting into `workflow/*.md` would
   put the executable blocks behind a second read at dispatch time. Trigger to revisit: any future
   change to the skill's block structure.
3c. The suite is a **one-off regression pin for #1051's guard** — it does **not** implement #1050's
   general "execute a skill's inline blocks in CI" mechanism (closed `NOT_PLANNED`, category B).
   Recorded here and in the suite header so that closure is not half-falsified.
3d. `version:` is de facto used by ~30/123 skills but is absent from the frontmatter schema in
   `skills/writing-skills/SKILL.md`, so its bump semantics are undefined. Not filed (doc drift,
   category B).
3e. `#1049` was **closed `NOT_PLANNED` as category B on 2026-09-15** (consumer-checkout
   offered-then-failed `skill-lint` false-red class). It is cited for the *rationale* it records — do
   not add a `scripts/` dependency to a materialized consumer checkout — not as a live issue; the
   class persists and this change adds one more instance of it, accepted under that closure
   (residual 1).
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
