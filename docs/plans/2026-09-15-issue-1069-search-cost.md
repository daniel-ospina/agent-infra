---
title: "#1069 — fleet search must be ignore-aware by construction"
type: engineering
domain: platform
doc_status: draft
created: 2026-09-15
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra
---

# #1069 — Fleet search must be ignore-aware by construction

**Issue:** `daniel-ospina/agent-infra#1069` · **Tier:** standard · **A/B:** B (friction; consequence
stated) · **Domain:** adversarial (argv/root classification) — **review bound: 2 cycles**
**Date:** 2026-09-15 · **Branch:** `fix/1069-search-cost` · **Rev:** 8 (after seven solution-verify
cycles + the duplication/architecture reviewer)

## Confirmed problem (Phase 2, confidence 84)

The fleet teaches and defaults to **untracked, ignore-blind search primitives** — `grep -r` appears
**134× across 22 shipped skill files**, `rg` **1× incidentally** (`skills/writing-skills/SKILL.md:125`, a
collision check), `git grep` **0×** — and `templates/AGENTS.base.md` (the propagation vehicle to
tortoise, DMeer, premise-labs, swarm, wt-\*) carries **no search guidance at all**. A search an agent
believes is scoped therefore becomes an index-free, ignore-free tree walk over
`.worktrees/*/node_modules` (169 GB in tortoise). The three mechanisms that already prevent it
(`.gitignore` `.worktrees/` at line 11, dot-directory hidden-skip, the tracked-file index) are
unreachable from the primitive the agent is told to use.

Two harms, one cause: **taught harm** (the shipped corpus teaches the walk) and **live harm** (an
agent's habitual `grep -rn` / `find .` at a repo root walks it on the spot). "Three concurrent walkers
cannot be fixed by asking agents nicely" (#1069 live-evidence comment).

### What the issue's own prescribed remedy does NOT do (problem-verify confirmed)

| Proposed remedy | Verdict |
|---|---|
| Committed `.ripgreprc` | **Dead text.** ripgrep reads config only via `RIPGREP_CONFIG_PATH` (unset); no repo-config discovery. |
| Repo-level `.ignore` / `.gitignore` addition | **Zero behaviour change.** `grep -r`/`find` read no ignore file; `rg`/`fd` already skip `.worktrees/`. |
| "an ignore that both `rg` and `git grep` honour" | **Impossible.** `git grep` reads the index; it has no ignore-file mechanism. |
| The specified fixture test | **Vacuous.** It passes today with no change, and still passes after deleting `.gitignore:11`, because `.worktrees` is a dot-directory and `rg` skips hidden by default. It cannot be a "fails-if-removed" pin. |
| Acceptance clause 1 as written | Simultaneously a **no-op** (for the tools it names) and **unsatisfiable** (for the tools that walk). |

Survives: an AGENTS.md guidance line, `git grep` guidance (correct for the *other* reason —
index-bounded), and the *idea* of a pinned test, re-pointed at a corpus contract.

## Solution — one package, two halves, one invariant

**A+B. C rejected.** *(Rev 2: `match.mjs` removed — the classifier lives in `index.ts` on the shared
parser; the guard is root-based, not cwd-based; the corpus pin is two-directional.)*

- **Half A — make the taught default ignore-aware, and keep it that way.** A `## Search` contract in
  `templates/AGENTS.base.md` (propagates) **hand-mirrored** into agent-infra's own `AGENTS.md`
  (marker-less legacy — `materialize-agents.sh --merge` refuses; `--check` only warns); rewrite the
  **133 unbounded** taught occurrences across **21** skill files (the 134th is bounded and stays); a
  hermetic repo-contract harness that fails the build if the ignore-blind primitive returns to the
  corpus.
- **Half B — refuse the walk shape at the tool boundary.** `extensions/search-guard/`: a
  `pi.on("tool_call")` classifier that returns `{ block: true, reason }` for an unbounded recursive
  search over a vendored/parallel tree, with the reason naming a runnable replacement.
- **Invariant:** *the corpus teaches only primitives the guard allows; the guard refuses only the shape
  the corpus no longer teaches.* **Both directions are enforced by the harness** (see Testing) — the
  forward direction alone is satisfiable vacuously by a `classify()` that returns `null` for
  everything.

### Why A+B and not A alone

The confirmed "taught harm" leg is A's job, and A alone does not stop a live walk — it is the inert
remedy problem-verify already refuted. The issue's own evidence settles it: "Three concurrent walkers
cannot be fixed by asking agents nicely."

### Why A+B and not B alone

*(Rev 2 — the Rev-1 claim "B would be disabled within a week" was overstated, because Rev 1's predicate
was cwd-scoped and fired only at a hub root. With the root-based predicate the claim becomes true: at
any repo/worktree root the guard blocks an unbounded `grep -rn`/`find .` — which is exactly what the
corpus teaches 133 times. So B alone would block our own documented commands at repo roots and be
graded an over-blocking adversary.)* A removes the taught harm; B removes the live harm. Both are
required, and the invariant above is what keeps them coherent.

### Why C is rejected

`scripts/search.sh` introduces a third search vocabulary alongside A's `rg`/`git grep` primitives; its
substrates re-implement `git grep`/`rg`; it does not stop a live walk. Against the two-strikes
retirement rule, machinery with no unique capability. Also rejected: a `$HOME/bin/grep` PATH shim
(per-machine state, defeated by `command grep`) and process/container isolation (SOTA for the class, but
a new architecture decision far beyond a category-B chore).

### §Reuse — the classifier sits on the shared parser (duplication-reviewer `unify-contract-keep-drivers`)

`extensions/shared/git-command-parse.ts` (644 lines) is **"THE single copy of the git/gh command-parsing
helpers"** (#966). Its header records the exact failure mode of a private copy: *"by 2026-09 the copies
disagreed on SEVEN input classes, their test suites asserted OPPOSITE answers for `cd /a && cd /b && <op>`,
and verification-gate's stale copy carried the fail-open root mis-resolution of #960."*

**`extensions/search-guard/index.ts` therefore imports — it does NOT re-implement:**

| Need | Shared source | Why |
|---|---|---|
| quote model | `unquotedMask(command)` — `git-command-parse.ts:165` | the module's own single quote model; the part that diverged 7 ways |
| `cd`-chain → effective cwd | `parseCdChains(command)` → `{ last, unattributable }` — `:458` | last-`cd`-wins is a *proved* contract (`:22-30`), and `unattributable` is the honest "a cd ran but I cannot resolve it" case |
| `~` / `$VAR` / relative expansion | `expandCdTarget(path, base)` — `:294` | already handles `~`, not `~user`, and refuses statically-unresolvable targets |
| `.js`→`.ts` module mapping | `import { … } from "../shared/git-command-parse.js"` | the specifier `verification-gate/index.ts:24` and `review-enforcer/index.ts:21` already use; `module-load-hooks.mjs` reproduces pi's jiti mapping |

Only R1–R4, the root predicate, and the block-reason text live in `search-guard`. There is **no
`match.mjs`** — a second zero-dep classifier module would have been the 4th cwd resolver / 3rd
tokenizer in the family. A ~25-line word-split over the shared `unquotedMask` is a traversal, not a
second quote model.

**Drift-pin:** `test.mjs` asserts `index.ts` imports `shared/git-command-parse.js` (mirroring the #966
drift-pins at `verification-gate/index.test.ts:515-528`, which today hardcode only two file paths — see
the follow-up issue for the family-wide parity suite).

## Adversarial Threat Surface

Rev 2's predicate is **root-based**, not cwd-based: `classify` resolves the *search root* (explicit
operand, `..`, absolute path, `~`, `$HOME`, or the exec cwd when implicit) and blocks when that root is
a system/home root **or** a tree that carries vendored/parallel trees — `root/{node_modules,.worktrees}`
or one level down (`root/*/node_modules`, which is the `extensions/*/node_modules` and
`packages/*/node_modules` layout, and `.worktrees/*/node_modules`).

**Rule set (Rev 4 — numbering is the contract the tests assert):**

- **R0 — command-word location (the wrapper-prefix rule).** The classifier anchors on a watched binary
  token (`grep`, `find`, `rg`, `fd`) that appears at the head of the command **or** preceded only by
  *prefix-like* tokens. Declared prefix set: `!`, `time`, `sudo`, `doas`, `nohup`, `command`, `env`,
  `nice`, `ionice`, `stdbuf`, `timeout`, `VAR=value` assignments, and `\`-escaped words.
  **Argument consumption is declared, not inferred (Rev 7):** `timeout` consumes its own value-taking
  options (`-s`/`--signal`, `-k`/`--kill-after` — each attached, separate, **or in the GNU `--signal=VALUE`
  form**) and then one duration word;
  `stdbuf` consumes `-i`/`-o`/`-e` (attached or separate). All other prefixes are **word-only** — their
  own flags are not parsed
  — and shell grouping / control-flow (`{ …; }`, `( … )`, `if…then…fi`, `for…do…done`) is **not
  parsed**. The word-only prefixes and shell grouping are declared residuals with their own ALLOW row
  (T4d), while the parsed `timeout`/`stdbuf` options are in scope and BLOCK (T4b), so the
  boundary is tested rather than implied. A watched token preceded by anything else (a pipeline stage, a
  non-prefix writer, e.g. `echo find /`) is **not** classified and the command ALLOWs. *This is the
  Rev-4 hole: the allowlist was closed at `env|nice|command|VAR=`, so `! find /`, `time grep -rn p`,
  `sudo find /`, `timeout 600 grep -rn p`, `nohup find .` were never seen as searches.*
- **R1 — system/home root.** Applies to a **recursive search only** (`find`, or `grep` with
  `-r`/`-R`/`--recursive`/`-d recurse`); non-recursive `grep` — including a file operand such as
  `grep -i x ~/Library/…/stderr.log` — is never classified by R1–R5. For a recursive search, **any**
  operand, or the implicit root, that resolves to a **directory** which is `/`, a **home directory**, a
  **top-level system prefix** (`/Users`, `/home`, `/Volumes`, `/System`, `/Applications`, `/private`,
  `/etc`, `/usr`, `/var`, `/opt`, `/tmp`, `/bin`, `/sbin`, `/Library`), **or a direct child of one**
  (`/home/u`, `/Users/u`) → BLOCK; a **file** operand is exempt. The depth-2 boundary is deliberate:
  `/Users/u/proj` (T2b) and every other below-the-top-level tree are **not** R1 roots — they are judged by
  R2/R3 on whether they carry vendored trees, which is what keeps T5/T8/T12 legal. Cwd-independent.
  Quotes are stripped by the shared `unquotedMask`, so `find "/"`, `find '$HOME'` and `find "~"` are all
  caught. *(Rev 6 left this underdetermined: the identity reading did not reach T2's `/home/u`, and the
  containment reading blocked T12.)* **Consequence for the harness (Rev 8):** since `/tmp` is a
  top-level prefix and a direct child of one is a root, the fixture hub must not itself be `mktemp -d`'s
  output on Linux (`TMPDIR` unset → `/tmp/tmp.XXXXXXXXXX` → depth 2 → an R1 root, which would make T9 and
  the §14(iii) `### Use` check fail for the *wrong* reason and vacuously satisfy T5/T6/T7/T13). The hub is
  therefore **one level deeper — `HUB="$(mktemp -d)/hub"`** — so both platforms evaluate it at depth ≥ 3
  and the R2 layer, not R1, is what those rows exercise.
- **R2 / R3 — root predicate.** For an unbounded recursive `grep -r*` (R2) or `find` (R3), **every** operand
  is resolved and classified, not just the first:
  - an operand that does **not resolve statically** (`$VAR`, `$(…)`, backticks) → **BLOCK** (fail-closed,
    mirroring the `unattributable` principle `git-command-parse.ts` applies at `:306-325`). A null operand
    must never fall through to ALLOW. **This bullet is evaluated FIRST** — an operand with an expanding
    component is never considered by the glob clause below, which is what settles `$VAR/*` (Rev 8: the
    ordering was previously only implied);
  - an operand containing a glob metacharacter (`*`, `?`, `[`, **`{`** — a brace expansion is a glob:
    `{src,supabase}/*` has the literal prefix `{src,supabase}`, a directory that does not exist and so
    trivially "carries no vendored trees", yet the shell expands it to `supabase/*`, i.e. exactly the
    T17f bypass) is **bounded** — and therefore ALLOWED —
    only when its **resolved literal prefix** is a safe directory: normalize the components before the
    first metacharacter (`.`/`..` collapsed, `~` expanded via the shared `expandCdTarget`) and require the
    result to be a **non-root, non-home directory that carries no vendored trees under this very R2/R3
    predicate**. So `supabase/functions/*/index.ts` → prefix `supabase/functions`, clean → ALLOW;
    `supabase/*` → prefix `supabase`, which carries `supabase/*/node_modules` → BLOCK; `src/../*` →
    normalizes to `.` → BLOCK (identical to T17e); `*`, `./*/x`, `~/*`, `{src,supabase}/*` → no literal
    component (or a non-literal one) → BLOCK. Additionally, **every component before the first
    metacharacter must contain no `{`, `}`, `$` or backtick** — a component that is not a literal path
    name is not a directory the predicate can trust. This
    is what keeps the one deliberately-unrewritten site
    (`skills/commit-workflow/workflow/04-merge-deploy.md:314`) green. The justification is **not** "the
    shell expands the glob to files" — a glob can yield *directories*, which `grep -r` then recurses, so
    Rev 6's textual rule over-approximated and admitted the declared bypass; it is "the literal prefix is a
    bounded, vendored-free directory, and the predicate is re-run on it". T17d/T17e/T17f/T17g pin all four
    directions;
  - an operand whose resolved directory carries **vendored or parallel trees** — `root/node_modules`,
    `root/.worktrees`, or one level down (`root/*/node_modules`, the `extensions/*/node_modules` /
    `packages/*/node_modules` / `.worktrees/*/node_modules` layouts) → BLOCK. **`.git` alone is NOT a
    trigger** (Rev 5 listed it, which contradicted the declared out-of-scope claim *and* made every plain
    git repo an over-block); the out-of-scope bullet and Risk 1 now say the same thing;
  - all operands safe → ALLOW.
- **R3p — the bounding-shape test.** `find` is *bounded* only when
  `-maxdepth` is present, **or** `-prune` is present **and its predicate names a genuinely directory-blocking
  target** (`node_modules`, `.worktrees`, `.git`, `.*`, `_*`, or a `-path`-based prune). A bounded `find` is exempt from **the vendored-root predicate (R2/R3) and from operand
  resolution** — the bound is what removes the amplification — so `find . -name '*.ts' -maxdepth 3` at a
  repo root and `find "$SKILLS_DIR/" … -prune … -print` (unresolvable operand) are both ALLOWED. **R1 is
  never exempted:** `find / -maxdepth 3` is BLOCKED. A bare `-prune`, or a `-prune` guarded by a file-name
  predicate (`-name '*.ts'`), **does not bound traversal** (`-prune` fires only on directories), so the walk
  stays full-depth and the full operand policy applies. **Predicate association is positional:** the guard is
  the `-name`/`-path` expression *immediately preceding* the `-prune` (or the `\( … \)` group terminating at
  it) — not any `-name` anywhere in argv, which would be satisfiable by `-name '*.ts' -prune -o -name
  node_modules -print` (T11e). *This is the Rev-3 hole: Rev 3 exempted the whole shape from the root predicate, so
  `find / -name x -prune -o -name y -print` — an FS-root walk — was ALLOWED.*
- **R4 — ignore-defeat flags.** A `--no-ignore*` **prefix match** for **both** `rg` and `fd` (covering
  `--no-ignore`, `--no-ignore-vcs`, `--no-ignore-parent`, `--no-ignore-global`, `--no-ignore-dot`), plus
  `rg -u`/`-uu`/`-uuu`/`--unrestricted` and `fd -I` (including inside a cluster such as `-HI`), `fd -u`,
  `fd --unrestricted`, at any root → BLOCK. **Bare `fd -H`/`--hidden` is ALLOWED**, symmetrically with
  `rg --hidden` (T18): `fd --help` states that with `--hidden` alone "files or directories that are
  ignored … are still ignored", i.e. it does not defeat `.gitignore` — blocking it would contradict the
  same rationale T18 rests on, and `fd --help` presents `-H` only as part of the `-HI`/`-u` convenience
  `-HI` cluster. Verified against the shipped `rg 15.2.0 --help` and `fd 10.4.2 --help`; **every flag R4
  keeps has its own T17 row** — `-u`/`-uu`/`-uuu`, `--no-ignore`/`-vcs`/`-parent`/`-global`/`-dot`. *(Rev 7
  claimed the row invariant and named `-HI` as an `fd --help` alias; `fd --help` documents `-H, --hidden`
  standalone and contains no `-HI` string, so that justification clause is dropped in Rev 8 — the verdict
  and the quoted sentence stand on their own.)*
- **R5 — the exclusion carve-out.** An unbounded `grep -r*` is ALLOWED at any root when it carries **both**
  `--exclude-dir=.worktrees` **and** `--exclude-dir=node_modules` (`--exclude-dir=.git` is recommended but
  not required). This is what makes the taught non-git fallback and T9 legal. **R5 applies only where R1 does not — R1 is evaluated first and is never softened by
  `--exclude-dir`.** It applies to `grep` only: R4 is deliberately not softened by a `--glob` companion, because Half A teaches
  `git ls-files --others --exclude-standard` as the untracked-file remedy instead of any ignore-defeat flag.
- **R6 — kill-switch.** `SEARCH_GUARD_DISABLED=1` in the command env → ALLOW (documented escape).

| # | Bypass class | Adversarial input | Required | Test |
|---|---|---|---|---|
| T1 | FS-root walk | `find /`, `find / -name '*.ts'` | BLOCK (cwd-independent) | R1 |
| T2 | Home dir / system prefix / its direct child | `find ~`, `grep -rn p /Users`, `grep -rn p /home/u`, `/Volumes`, `/private`, `/System` | BLOCK (depth ≤ 2 from `/`) | R1 |
| T2b | **Home subtree below the top level** | `find ~/proj`; `grep -rn p ~/proj/src` where `~/proj` carries no vendored trees | ALLOW (R1's depth-2 boundary; the same tree **with** `node_modules` is BLOCK via R2/R3, see T15) | R1-scope |
| T3 | Quoted / literal root | `find "/"`, `find '$HOME'`, `find "~"` | BLOCK (quote-stripped token compare) | R1 |
| T4 | Wrapper prefix | `env find /`, `nice find /`, `command find /`, `FOO=1 find /`, `find -L /` | BLOCK (R0) | R0/R1 |
| T4b | **Wrapper prefixes outside the Rev-4 allowlist** | `! find / -name x`, `time grep -rn p`, `sudo find /`, `timeout 600 grep -rn p`, `nohup find .`, `stdbuf -oL grep -rn p`, `timeout -s KILL 600 grep -rn p`, `timeout -k 5 600 grep -rn p`, `timeout --signal=KILL 600 grep -rn p`, `timeout --kill-after=5 600 grep -rn p` | BLOCK (R0; the last three are why `timeout`'s value-taking options — including the `=VALUE` spelling — are declared) | R0 |
| T4c | R0 negative control | `echo find /` (the watched token is preceded by a non-prefix writer) | ALLOW | R0 |
| T4d | **Declared residual** | `sudo -u root find /`; `env -i find /`; `{ find /; }`; `( find / )`; `if true; then find /; fi` | ALLOW (wrapper options + shell grouping are out of scope — this row is the test that says so) | R0 |
| T5 | Unbounded grep, implicit dot | `grep -rn p` (no operand) at a repo root | BLOCK | R2 |
| T6 | Unbounded grep, explicit dot | `grep -rn p .` at a repo root | BLOCK | R2 |
| T7 | `--include` decoy | `grep -rn p --include='*.py'` at a repo root | BLOCK (`--include` filters after traversal) | R2 |
| T8 | Bounded grep | `grep -rn p src/`; `grep -rn p --include='*.ts' src/` | ALLOW | R2-allow |
| T9 | Both excludes present (R5 carve-out) | `grep -rn p --exclude-dir=.worktrees --exclude-dir=node_modules` (no operand, at a repo root) | ALLOW | R5 |
| T9b | **R5 cannot soften R1** | `grep -rn p --exclude-dir=node_modules --exclude-dir=.worktrees /` | BLOCK (R1 evaluated first) | R1 |
| T10 | Repo-root `find` | `find . -name '*.ts'`; bare `find -type f` | BLOCK | R3 |
| T11 | Bounded `find` | `find . -name '*.ts' -maxdepth 3`; `find "$SKILLS_DIR/" \( -name '_*' -o -name '.*' \) -prune -o -name 'SKILL.md' -print` (`skills/post-deploy-verify/infra-verify/SKILL.md:87` — the `\( -name '_*' -o -name '.*' \)` group terminates at the `-prune` and names directory-blocking targets, so the shape is bounded and the unresolvable `"$SKILLS_DIR"` operand is exempt) | ALLOW | R3p |
| T11b | **Bare `-prune` (bounds nothing)** | `find . -name '*.ts' -prune` — `-prune` fires only on directories and `-name '*.ts'` matches none, so the walk stays full-depth | BLOCK | R3 |
| T11c | **`-prune` with a file-name predicate** | `find . -name '*.ts' -prune -o -print`; `find . -name x -prune -o -name y -print` | BLOCK (R3p does not exempt it; root `.` is a vendored root) | R3 |
| T11d | **FS root + bounding-looking suffix** (the Rev-3 hole) | `find / -name '*.ts' -prune -o -name '*.js' -print` | BLOCK (R1 applies regardless of shape) | R1 |
| T11e | **Non-adjacent blocking name** | `find . -name '*.ts' -prune -o -name node_modules -print` — the guard for the `-prune` is a file-name predicate | BLOCK (positional association, R3p) | R3 |
| T12 | Explicit-root `find` | `find src/ functions/ -name '*.ts'` (the live `find-bugs` shape) | ALLOW — at the **R3** layer (safe resolved operands, no vendored trees); it carries no `-maxdepth`/`-prune`, so it is independent of R3p | R3-allow |
| T13 | **Parent-dir root** (was undeclared) | `grep -rn p ..` from fixture `repo/src` where `repo` carries `node_modules` | BLOCK | R2 |
| T14 | **Absolute hub path** (was undeclared) | `grep -rn p /Users/…/tortoise` | BLOCK (root carries `.worktrees`) | R2 |
| T15 | **Worktree cwd** | `grep -rn p .` / `grep -rn p` from `.worktrees/<b>/` | BLOCK when the worktree root carries `node_modules` / `*/node_modules` (tortoise shape) | R2 |
| T15b | Unresolvable root, no bounding prune | `find "$VAR" -name x -prune -o -print` — the prune predicate bounds nothing, so traversal is full-depth | BLOCK | R3 |
| T16 | **Monorepo `packages/`** (was undeclared) | `grep -rn p packages/` → root has `*/node_modules` | BLOCK | R2 |
| T17 | Ignore-defeat `rg` / `fd` | `rg --no-ignore p`, `rg --no-ignore-vcs p`, `rg --no-ignore-global p`, `rg --no-ignore-dot p`, `rg -u`, `rg -uu`, `rg -uuu`, `rg --unrestricted p`, `fd -I`, `fd -HI` (the `I` in the cluster), `fd --no-ignore`, `fd --no-ignore-vcs`, `fd --no-ignore-parent`, `fd -u`, `fd --unrestricted` at any root — `--no-ignore*` **prefix for both binaries**, plus `-I`/`-u` | BLOCK | R4 |
| T17h | `fd --hidden` precision | `fd --hidden p`; `fd -H p` | ALLOW (fd's `-H` does not defeat `.gitignore` — `fd 10.4.2 --help`; symmetric with T18) | R4-allow |
| T17b | Unresolvable operand | `grep -rn p $PWD`; `grep -rn p $(pwd)` | BLOCK (fail-closed — see the operand policy) | R2 |
| T17c | Multi-operand, one unsafe | `grep -rn p src/ /Users/…/tortoise` | BLOCK (EVERY operand is classified) | R2 |
| T17d | **Anchored glob operand** (bounded) | `grep -rl "…" supabase/functions/*/index.ts` (the deliberately-unrewritten site) | ALLOW (resolved literal prefix `supabase/functions` is a clean directory) | R2 |
| T17e | **Unanchored glob operand** | `grep -rn p *`; `grep -rn p ./*/x`; `grep -rn p ~/*` | BLOCK (no literal non-root prefix) | R2 |
| T17f | **Glob whose prefix dir itself carries vendored trees** | `grep -rn p supabase/*` with `supabase/*/node_modules` present | BLOCK (the predicate is re-run on the literal prefix dir — Rev 6's textual rule ALLOWED this) | R2 |
| T17g | **Path-traversal glob** | `grep -rn p src/../*` | BLOCK (the prefix normalizes to `.`, i.e. the root) | R2 |
| T18 | `rg --hidden` precision | `rg --hidden p` | ALLOW (`--hidden` still honours `.gitignore`) | R4-allow |
| T19 | `cd` precedence | `cd <fixture-safe-dir> && grep -rn p` from a hub root — the target is a directory **inside the `mktemp` fixture**, never a live `/tmp` path (a stray `/tmp/*/node_modules` on a dev box would flip this ALLOW row) | ALLOW — the root is the `cd`-target and carries no vendored trees | cwd |
| T20 | `cd` into a repo | `cd <hub> && grep -rn p` from elsewhere | BLOCK | cwd |
| T21 | Unattributable `cd` | `cd $X && grep -rn p` (`parseCdChains` → `unattributable`) | BLOCK (fail-closed on the unresolvable case only) | cwd |
| T22 | Kill-switch | `SEARCH_GUARD_DISABLED=1 grep -rn p` | ALLOW (documented escape) | kill-switch |
| T23 | Untracked-file gap (A's caveat) | `git ls-files --others --exclude-standard` remedy is ALLOWED and teaches no ignore-defeat flag | ALLOW | guidance pin |

### Explicitly OUT OF SCOPE (allowed through; documented in the extension README + the block-reason footer)

- **Recursive payload parsing:** `sh -c` / `bash -c` / `eval` / backticks / `$()` / `xargs` — unbounded,
  refused as a design boundary.
- **Token obfuscation:** `f""ind`, `\find`, `"find" /`, `${IFS}`, aliases, shell functions defined
  earlier in the same call.
- **A wrapper's own options and shell grouping / control-flow:** `sudo -u root find /`, `env -i find /`
  (R0's prefixes are word-only **except** `stdbuf`/`timeout`, whose declared options *are* parsed — so
  `timeout -s KILL 600 grep -rn p` is in scope and BLOCKs, T4b), and `{ find /; }`, `( find / )`,
  `if true; then find /; fi`, `for f in x; do find /; done`. T4d pins these as ALLOW.
- **Other walkers:** `du -a /`, `tar`, `rsync`, `python3 -c os.walk('/')`, `node -e`, `perl -e`,
  `ls -R /` (safe by construction — no `-a`), `mdfind`.
- **Unbounded recursive search outside a vendored-tree root:** a repo with neither `node_modules` nor
  `.worktrees` at or one level below the root is not blocked (no amplification to remove).
- **Walks initiated from a script file's contents** — only the top-level command string is classified.
- **Sessions where the extension is not loaded:** `--no-extensions`, non-pi harnesses (Claude Code /
  Cursor / Codex), MCP search tools, and **a session already running when the extension lands**
  (MEMORY.md `[extensions]`: the module loads at startup; a running session keeps the old module —
  deploy lag is expected, not a failure). `check-pi-config-extensions.sh` guarantees farm parity, NOT
  that a session has it loaded; the plan does not cite it as proof of liveness.
- **`extensions/main-worktree-guard`** — untouched by design. Its `test.mjs:3946,3963,3984` pins
  `find . -name README.md` as SILENT; a separate extension leaves those pins intact by construction.
- **Corpus scan outside the teaching surface:** `scripts/`, `extensions/`, `.github/` are not scanned
  (executable code with bounded variable roots and test fixtures legitimately contain the string —
  `extensions/main-worktree-guard/test.mjs` holds `find . -name README.md` as fixture data, and
  `ci.yml:269`'s `grep -rE` has explicit bounded roots). Declared, not silent.

## Implementation plan

### Step 0 — pre-flight
1. `bash scripts/check-no-sigpipe-grep.sh` and `bash tests/sigpipe-grep/run.sh` green.
2. Corpus inventory: **134** `grep -r/-R/--recursive` occurrences in 22 files —
   `skills/security-review/**` = **131** across 20 files, `skills/code-review/SKILL.md` = **2**
   (lines 512-517, unbounded), `skills/commit-workflow/workflow/04-merge-deploy.md:314` = **1**
   (`grep -rl "…" supabase/functions/*/index.ts` — **bounded glob root → NOT rewritten**).
   So **133 sites across 21 files** are rewritten.
3. Confirm `git grep -n -e 'execute.*+' -- '*.py'` × `rg -n 'execute.*\+' -g '*.py'` fidelity on a live
   pattern before writing guidance.

### Step 1 — A1: the `## Search` contract
4. Insert `## Search` immediately before `## Tool Quality & Retirement` in **both**
   `templates/AGENTS.base.md` (~line 314) and the repo's own `AGENTS.md` (~line 352), plus a **manual
   fleet step** for `~/.pi/agent/AGENTS.md` (outside the repo — see Risks #5). ~35 lines with two
   labelled subsections:
   - **`### Use`** — every command here **must classify ALLOW**. The recommended primitives:
    `rg` (default; honours `.gitignore` and skips hidden paths — `.worktrees/` is skipped because it is
    **hidden**, `node_modules/` because `.gitignore` generally covers it) **if present, else
    `git grep -n`**; `git ls-files`; `rg --files <glob>`. Plus the **bounding forms**, which are
    recommendations, not anti-examples: `--exclude-dir=.worktrees --exclude-dir=node_modules`,
    an explicit non-root operand, `-prune` with a directory-blocking predicate, `-maxdepth`. **`git grep`
    requires a git work tree** — for a non-git target tree the bounded third fallback is
    `grep -rn P --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.worktrees` (the shape R5
    classifies ALLOW), so the security-review use case has a working path everywhere.
  - **`### Avoid`** — every command here **must classify BLOCK**. It contains **only** the
    anti-examples (`grep -r p`, `grep -rn p .`, `find . -name x`, `find / -name x`) and **no** bounding
    forms — the bounding forms live in `### Use` precisely so rule (iii) below is satisfiable. *(Rev-3
    put the bounding forms in `### Avoid`, which made "every Avoid command classifies non-null"
    unsatisfiable on the plan's own guidance.)*
   - **`git grep` requires a git work tree**, and the two agent-facing statements about expensive work
     cross-reference each other: one line naming `docs/ops/load-policy.md` (the fleet load contract).
   - One line that the runtime guard exists and that its block reason names the replacement.
5. Correct the `rg` regex caveat (BRE `\|` → Rust `|`; `--include` → `--glob`) and prefer `git grep -n`
   where the pattern is BRE.

### Step 2 — A2: rewrite the taught corpus (133 sites / 21 files)
6. The 20 `skills/security-review/**` "Key Grep Patterns" blocks (131 sites) → `git grep -n -e … -- '*.py' '*.js'`
   semantics with an `rg` alternative. **Semantic translation, not `sed`.**
7. `skills/code-review/SKILL.md:512-517` (2 sites) → `git grep -n -e "from '.*<module-path>'" -- '*.ts' '*.tsx'`.
8. Leave `skills/commit-workflow/workflow/04-merge-deploy.md:314` and `skills/find-bugs/SKILL.md:49`
   **unchanged** (bounded roots — must stay clean under the rule, and rewriting a bounded glob-rooted
   grep to an index-wide `git grep` would be a real semantics change).
9. Post-rewrite: **zero** unbounded taught searches in fenced blocks of `skills/` + `templates/`.

### Step 3 — B: `extensions/search-guard/`
10. `extensions/search-guard/index.ts` (TS, ~220 lines) — named export
    `classifySearchCommand(command, execCwd) → { block: true, reason } | null` (pure, testable) and
    `export default function (pi: ExtensionAPI)` registering `pi.on("tool_call")` +
    `isToolCallEventType("bash", event)`. Imports `unquotedMask` / `parseCdChains` / `expandCdTarget`
    from `../shared/git-command-parse.js`. Root predicate + operand policy as above. **Block, never
    rewrite argv** — acceptance (c) forbids silent semantics changes.
    **Filesystem probe robustness (Rev 3):** the one-level-down `root/*/node_modules` check uses
    `readdirSync(root, { withFileTypes: true })` inside `try/catch` with a **declared fail-open to
    ALLOW** policy (a category-B cost guard must not abort a tool call — the #879 class that
    `main-worktree-guard` documents), the child scan is **bounded** (first N entries) so a huge
    directory cannot make the hook O(n) per command, and an unreadable root has its own test.
11. `extensions/search-guard/test.mjs` — **module-load pinned** via
    `../main-worktree-guard/module-load-hooks.mjs` + `registerHooks` (Node ≥ 22.13; local v22.23.2), so
    the REAL `index.ts` is imported and the REAL registered `tool_call` handler is driven against a
    hermetic fixture. This is the #744/#697 class: a suite that imports only a helper stays green while
    `index.ts` is broken and the gate is inert in every session.
12. `extensions/search-guard/README.md` — rule table, in/out-of-scope declaration, kill-switch,
    block-reason contract (every reason contains a runnable replacement, availability-resolved).
13. Wiring: symlink `pi-bootstrap/pi-config/extensions/search-guard -> ../../../extensions/search-guard`;
    `manifest.json` → `files["extensions/"].entries` (28→29); a `ci.yml` step. The `ci-main.yml`
    `extensions/*/test*.mjs` glob picks up `test.mjs` post-merge automatically.

### Step 4 — A3: the repo-contract harness `tests/search-cost/run.sh`
14. One shell harness (repo convention: `find`/`grep`/`awk`/`sed` only — `rg`/`fd` are absent on
    `ubuntu-latest`). It:
    - (i) is **not** a `node extensions/search-guard/test.mjs` invocation — see the classifier
      interface below (the `extension-tests` glob owns that suite post-merge, so running it here too
      would double-run it);
    - (ii) **classifier-driven corpus scan:** every fenced code block command in `skills/` + `templates/`
      is classified through `test.mjs --classify` (below); a **non-null** classification is a violation,
      EXCEPT inside the `## Search` **`### Avoid`** subsection — which (iii) asserts classifies non-null.
      The fence opener **need not carry a language tag** (2 of the 134 sites —
      `skills/code-review/SKILL.md:510` — sit in an untagged fence) and indented fences (up to 4 leading
      spaces, e.g. `skills/commit-workflow/workflow/04-merge-deploy.md`) are scanned too; **a fence opener
      may be preceded by zero or more `> ` blockquote markers**, which is a real shape in the scan set
      (`skills/carousel-b2b-design/SKILL.md:163,166,172,174`;
      `skills/reviewers/duplication-architecture/SKILL.md:104…214`) and must have its own fixture control. A **positive
      control on an untagged fence** (`grep -rn p .` inside an untagged ``` block in a fixture skill)
      must make the scan red. Driving the scan from the classifier (not a regex) is what makes it
      non-evadable by flag ordering (`grep -nr p`, `grep -ir p`) and removes the self-contradiction where
      the scan red on the guidance section it enforces;
    - (iii) **coherence, both directions — extraction rule stated:** `### Use` and `### Avoid` each contain
      **one or more fenced blocks**, and the harness extracts the **fenced** commands of each subsection
      (inline code is prose, not a command, and is not extracted). Every `### Use` command must classify
      `null`; every `### Avoid` command must classify non-null. A subsection that yields **zero** extracted
      commands fails non-vacuity — so a rewrite of either subsection into prose cannot silently disarm the
      pin (Rev 4 left this rule unstated, which would have made the Use direction vacuously green);
    - (iv) **non-vacuity:** `classify()` must return non-null for at least one declared-block shape **and**
      each of `### Use`/`### Avoid` must yield ≥1 extracted command — a classifier that returns `null` for
      everything, or a subsection rewritten as prose, fails the harness;
    - (v) `## Search` present in **both** AGENTS files and naming `rg` and `git grep`; the scan set is
      `skills/` + `templates/AGENTS.base.md` + the root `AGENTS.md` (the file that actually loads — the
      materialize gate pins that every base line reaches it, but repo-specific extra lines are unscanned
      otherwise);
    - (vi) false-positive / scope controls, **run against a `mktemp` fixture tree, never the live
      checkout** (the live tree's `extensions/*/node_modules` presence is environment state and would make
      the control flaky): a fixture fence `grep -rE '/Users/…' skills/ extensions/ scripts/` — resolvable
      operands, no vendored trees — must classify ALLOW. *(The `ci.yml:269` line itself is `! grep -rE …`,
      a `!`-prefixed run-string that R0 would have skipped vacuously in Rev 4; the fixture reproduces its
      operands without the `!`.)* **`scripts/check-test-wipes.sh:55` is a
      scope control, not a classifier control**: it is a `$ROOT`-interpolated `grep -rn` *inside a script
      body*, and the guard classifies only the top-level command string (already in the out-of-scope list).
      *(Rev 3 listed it as an expected-ALLOW classifier control, which contradicted the fail-closed
      unresolvable-operand rule.)*

   **Classifier interface (so the implementer cannot re-open the #744 class):**
   `node extensions/search-guard/test.mjs --classify <command> [--cwd <dir>]` loads the REAL `index.ts` through
   `module-load-hooks.mjs` and prints `BLOCK <reason>` or `ALLOW`, with a non-zero exit for BLOCK. The
   shell harness calls **only** this entry point for (ii)–(iv); it never imports the classifier itself
   and never runs the extension suite as a whole — `extensions/*/test*.mjs` is owned by the
   `ci-main.yml` `extension-tests` glob post-merge and by an explicit `ci.yml` step per-PR, so invoking it
   from `script-validate` as well would double-run it. The `--classify` path still loads the real module
   through the loader hooks, so the module-load coverage is retained inside `run.sh` without the
   double-run.
   `--cwd` defaults to `process.cwd()`; **the harness always passes `--cwd "$HUB"`, where
   `HUB="$(mktemp -d)/hub"`** — one level below the `mktemp` root so the hub is never itself an R1 root on
   a Linux `/tmp` `TMPDIR` (Rev 8; otherwise T9 and the `### Use` R5 fallback classify BLOCK via R1 and
   T5/T6/T7/T13 pass for the wrong reason) — and the fixture carries `.worktrees/w/node_modules`, for
   (ii)–(iv), so the `### Avoid` implicit-root and
   dot-root verdicts do not depend on the live checkout's vendored state. (This worktree has no
   `node_modules` anywhere and `.git` is not a trigger, so without `--cwd` those rows would classify
   ALLOW and rule (iii) would be green-by-accident.) This is the same environment-independence §14(vi)
   already applies to its controls.
15. Wiring: **CI only** (no `.husky/pre-commit` entry — the verified convention is fast `scripts/check-*.sh`
    scanners in pre-commit and `tests/*/run.sh` suites in CI, and the suite's latency is unmeasured); a
    **dedicated `search-cost` job in `ci.yml`** mirroring `sigpipe-grep` (`ci.yml:88-103`), **with
    `actions/setup-node@v4` pinned to `node-version: '22'`** (the `sigpipe-grep` job has no setup-node and
    works today only because the ubuntu-24.04 image ships Node 22.23.2 — the harness needs Node ≥ 22.13 for
    type-strip, so the pin is made explicit rather than inherited); and **one explicit line
    `bash tests/search-cost/run.sh`** added to the existing `ci-main.yml` `script-validate` step (an
    explicit list, not a loop) — **not** `node extensions/search-guard/test.mjs`, because the
    `extension-tests` `extensions/*/test*.mjs` glob already owns that suite post-merge
    (`ci-main.yml:50-52` documents the convention; invoking it in both places would double-run it).
    `auto-file-on-failure.needs` (`ci-main.yml:341`) is untouched and `tests/actionlint/run.sh:76-114`
    stays green.
16. Save this plan; note the threat-surface declaration and the 2-cycle bound in the PR body.

## Testing strategy

- `node extensions/search-guard/test.mjs`
  - T1–T23 above (40 rows), each an assertion on the **registered handler's** return value.
  - Hermetic hub fixture (`mktemp`): `git init`, `.gitignore` with `.worktrees/`, a tracked file with
    `MARKER`, a `.worktrees/w/node_modules/dep.js` with `MARKER`.
  - **Non-vacuity, real:** `git grep -n MARKER` returns only the tracked file while `grep -rn MARKER .`
    returns the `.worktrees/.../node_modules` copy too — the harm is proven real and the exclusion is
    proven real, not asserted. (git + grep only → CI-portable.)
  - Positive controls (ALLOW rows) so an over-blocking guard fails the suite.
  - Drift-pin: `index.ts` imports `shared/git-command-parse.js`.
  - Mutation: delete R2 → T5–T7/T13/T14/T15/T15b/T16/T17b/T17c/T17e/T17f/T17g fail — **provided the hub
    is at depth ≥ 3** (`HUB="$(mktemp -d)/hub"`), otherwise the implicit/dot-root rows are satisfied by R1
    and this mutation signal is vacuous on Linux (Rev 8). (The **T17d ALLOW
    row is unaffected** — with R2 deleted the shape simply stops being classified.) delete R3p → **T11's
    two ALLOW inputs** fail (T12 is ALLOW at the R3 layer, not via R3p); delete R2's anchored-glob clause →
    T17d fails; delete R1 → T1–T4/T2b/T9b/T11d fail; relax R3p to "`-prune` present" →
    T11b/T11c/T15b/T11e fail; delete R5 → T9 fails;
    delete the `pi.on("tool_call")` registration → the handler-driven cases fail (not a text assertion).
- `bash tests/search-cost/run.sh` — (i)–(vi) above, plus mutation: revert one rewritten skill file → red.
- `node extensions/main-worktree-guard/test.mjs` unchanged and green (guardrail).

## Verification commands

```
bash scripts/check-no-sigpipe-grep.sh && bash tests/sigpipe-grep/run.sh
node extensions/search-guard/test.mjs
bash tests/search-cost/run.sh
bash scripts/check-pi-config-extensions.sh
bash tests/actionlint/run.sh
node extensions/main-worktree-guard/test.mjs
rg -n '## Search' templates/AGENTS.base.md AGENTS.md
rg -n 'shared/git-command-parse.js' extensions/search-guard/index.ts
bash tests/materialize-agents/run.sh    # base↔AGENTS.md mirror (the new ## Search lines must be mirrored)
rg -n 'grep -[a-zA-Z]*[rR]' skills/ templates/   # 4 hits, all intended: (1) the deliberate bounded site
                                                  #   skills/commit-workflow/…/04-merge-deploy.md:314,
                                                  #   (2) the 2 ## Search ### Avoid anti-examples,
                                                  #   (3) the 1 ## Search ### Use R5 fallback.
                                                  #   The HARNESS (classifier-driven, fixture-cwd) is the
                                                  #   acceptance signal for (b) — not this count.
```

The last three lines are the guidance/import pins the harness also asserts — listed here so the
verification set is complete and independently runnable.

## Acceptance criteria

| | Criterion | Mechanism | Evidence |
|---|---|---|---|
| (a) | A recursive source search started at the repo root does not descend into `.worktrees/*/node_modules` | (1) the default primitives `rg`/`git grep` are ignore/index-scoped, **proven non-vacuously**; (2) `search-guard` refuses the unbounded shape at the tool boundary, from any cwd | `node extensions/search-guard/test.mjs` |
| (b) | The pinned test fails if the exclusion is removed | mutations: R2 removal, root-predicate removal, R1 removal, registration removal, corpus-rewrite revert, `## Search` deletion | both suites |
| (c) | No behaviour change to any tool's semantics — only the default search set | the guard **blocks**, never rewrites argv; `grep`/`find` binaries, `.gitignore`, `main-worktree-guard`, `builtin-tools`, `task-heartbeat` untouched | guardrail suite |

## Runtime prerequisites

`node` ≥ 22.13 (type-strip; local v22.23.2, and the `ci.yml` `search-cost` job pins it explicitly rather
than inheriting the runner default) · `git` on PATH · **no new package, no `npm ci`, no network**. `rg` is
guidance-only in shipped text and is resolved at runtime for the block reason; `mdfind` is never invoked.

## Integration Docs

**New third-party dependencies: NONE.**

| Dependency | Version | Where used | Availability finding |
|---|---|---|---|
| `node` (`node:fs`, `node:path`, `node:module`) | ≥22.13 | `search-guard/{index.ts,test.mjs}` | CI `node-version: '22'`; local v22.23.2 |
| `git` | any | `git grep`/`git ls-files` guidance; hermetic fixture | universal (dev + `ubuntu-latest`) |
| `find`,`grep`,`awk`,`sed` | system | `tests/search-cost/run.sh` | present on `ubuntu-latest` + macOS |
| pi extension API | `@earendil-works/pi-coding-agent` | `ExtensionAPI`, `isToolCallEventType`, `tool_call` | already in use — `skill-enforcer.ts:238,244`; smallest precedent `audit-logger.ts` (58 lines) |
| **`extensions/shared/git-command-parse.ts`** | in-repo, #966 | `unquotedMask`, `parseCdChains`, `expandCdTarget` | the declared single copy; imported by `verification-gate/index.ts:24` and `review-enforcer/index.ts:21`; the `.js` specifier maps to the `.ts` file under pi's jiti and under `module-load-hooks.mjs` |
| `extensions/main-worktree-guard/module-load-hooks.mjs` | in-repo, #744 | `search-guard/test.mjs` loader | **reused, not copied** — avoids a second loader implementation; read-only (no modification) |
| `rg` (ripgrep 15.2.0) | pi-managed | **guidance text only**; runtime-resolved for the block reason | at `~/.pi/agent/bin/rg` — delivered by the pi install, so present on any pi-bootstrapped machine incl. tortoise sessions; **NOT** on `ubuntu-latest`, no workflow installs it → never in a shipped script, test, or CI command |
| `fd` 10.4.2 / `mdfind` | — | block-reason strings / rule predicates only | **`fd` is pi-managed in the same `~/.pi/agent/bin/` directory as `rg`** (pi `CHANGELOG.md:4078`), so it is likewise present on a pi-bootstrapped machine; neither is used in shipped text or scripts. `mdfind` is macOS-only and blind to dot-dirs. |

**API-surface findings:** `pi.on("tool_call", …)` may return `{ block: true, reason }` and cannot be
defeated by allow-listing (unlike Claude Code's `PreToolUse: deny`, ignored for allow-listed Bash per
anthropics/claude-code#18312); `isToolCallEventType("bash", event)`; `event.input.command` is the
classified string; `event.input` is mutable but is deliberately NOT mutated (acceptance (c)).

## Risks & declared residuals

1. **Over-block (cat-B admission):** *if this is never fixed, the user loses a lane for ~80 single-core
   minutes per walker (three concurrent walkers observed)*, against a one-command rewrite named in the
   block reason. Bounded by: the root predicate fires only on vendored/parallel trees or system/home
   roots; T8/T9/T11/T12/T18/T19/T23 are ALLOW positive controls; `SEARCH_GUARD_DISABLED=1` kill-switch
   (env only — a false block is escaped by rewriting the command, so the `$TMPDIR` TTL-marker recovery
   pattern `main-worktree-guard` needs for a spawn-time hatch is explicitly rejected as cat-B
   multiplicity).
2. **BRE→Rust-regex translation** in the 21-file rewrite is the highest-risk mechanical step. Prefer
   `git grep -n` (identical BRE); spot-check both forms.
3. **Guidance-only residual:** non-pi harnesses get A but not B. Declared, not silent.
4. **Deploy lag:** a session already running when the extension lands keeps the old module until
   restart. Declared; not treated as a failure.
5. **Global AGENTS.md — post-merge fleet step (owner: the operator, trigger: after this PR merges).**
   `~/.pi/agent/AGENTS.md` is outside the repo (no version control, no review) and loads for every
   session on this machine, including tortoise. The exact edit: add a `### Search` bullet to its
   "Rules that were learned the hard way" list naming `rg`/`git grep` as the search primitives and
   `find /` as forbidden. Not absorbed into the PR (it is machine state, not a repo artifact); its
   absence does not weaken Half B, which reaches every pi session regardless of AGENTS.md.
6. **Corpus scan scope** is the teaching surface (`skills/` + `templates/` fenced blocks) — declared
   out of scope for `scripts/`/`extensions/`/`.github/` (see the out-of-scope list).
7. **Consumer drift warning (non-blocking, expected):** adding a `## Search` section to
   `templates/AGENTS.base.md` makes every consumer checkout (tortoise, DMeer, premise-labs, swarm, wt-*)
   report `⚠️ BASE-OWNED CONTENT DRIFTED` on `scripts/materialize-agents.sh --check` until each runs
   `--merge`. It **exits 0** and `scripts/check-agents-materialized.sh` only fails on a missing *required*
   heading (`## Search` is not one), so this is a warning, not a breakage — stated here so it is not
   mistaken for CI noise. agent-infra's own `AGENTS.md` is hand-mirrored in this PR, so the real-repo pin
   (`tests/materialize-agents/run.sh:323-336`) stays green.
8. **Adversarial bound: 2 cycles.** Acceptance = every declared in-scope class covered by a test +
   green CI. Residuals outside the declared surface are filed from cycle 1, not chased. On exit:
   `[ADVERSARIAL-BOUND] cycles=<N> threats=40 covered=<N> residuals=<#…|none>` in the PR body — never
   presented as an unbounded clean.
9. **Declared fail-open (the probe):** an unreadable/unstattable root makes the predicate stand down and
   ALLOW. This is deliberate for a category-B cost guard (a throw inside a `tool_call` hook would abort
   the whole bash tool call), and it is tested and disclosed rather than silent.

## Estimated diff shape

~1,100 lines / ~30 files. `search-guard/{index.ts,test.mjs,README.md}` ≈ 660 lines;
`tests/search-cost/run.sh` ≈ 200; 21 skill files ≈ 135 changed lines (mostly 1:1); 2 AGENTS files ≈ +35
each. **No new CI job in `ci-main.yml`** (the `extensions/*/test*.mjs` glob covers the extension suite
post-merge, and one explicit `script-validate` line covers the shell harness), so
`auto-file-on-failure.needs` is untouched.

---

## Implementation notes — Rev 9 (what the code does that this plan predicted differently)

Recorded after the code was written and both suites were green. Each item is a *disclosed* deviation, not
a silent one.

1. **T4d is stronger than planned.** The plan declared shell grouping / control-flow
   (`{ find /; }`, `( find / )`, `if …; then find …`) an out-of-scope ALLOW residual. The implementation
   skips `{`, `}`, `(`, `)`, `then`, `do`, `fi`, `else`, `elif` at the head position like a prefix, so all
   four shapes **classify BLOCK**. The rows are pinned as BLOCK. The word-only wrapper-option residual
   (`sudo -u root find /`, `env -i find /`) still stands.
2. **The harness is two files, not one.** `tests/search-cost/run.sh` (fixture, controls, acceptance-(b)
   mutation) plus `tests/search-cost/scan.mjs` (fence extraction + the classifier-driven corpus scan).
   Rationale: the corpus is **10,854 commands across 277 files**; one `--classify` process per command
   would be ~10k Node startups. `scan.mjs` loads the real classifier once and classifies in-process,
   through the same loader hooks.
3. **`scan.mjs` exit codes are the contract:** `0` clean, `1` a violation was found, `2` the scan could
   not run. `run.sh` treats `2` as a failure — a crash must never read as "caught".
4. **Every operand is classified, not just the first** (T17c). This was a real defect in the first
   implementation: only `operands[0]` was resolved, so `grep -rn p src/ <hub>` allowed the walk.
5. **`grep`'s bare pattern word is consumed.** `grep -rn PATTERN [PATH…]` — the first non-flag word is the
   pattern, not an operand. Treating it as an operand made every `grep -rn p` classify against a
   non-existent root and **allow**. Pinned by the whole `T5/T6/T7/T9` family.
6. **Three corpus sites changed behaviour on purpose** (semantic translation, disclosed):
   - `security-review/references/supply-chain.md` — the "unpinned dependencies" pattern dropped `^`, which
     matched *every* line and so discriminated nothing; the `node_modules/ site-packages/` walk became
     `find … -maxdepth 3 \( -name '*.js' -o -name '*.py' \) -print0 | xargs -0 grep -n …`; the
     `uses:.*@…` line moved to `git grep -- '.github/workflows/*'`.
   - `security-review/references/logging.md` — the `grep -rn … | xargs -I {} grep -L … {}` pipeline was
     **already broken** at HEAD (it fed `file:line:match` strings to `grep -L` as filenames). Repaired to
     `git grep -l … | xargs -r grep -L …`.
   - **12 file-operand sites** (both `Dockerfile` blocks, the `.npmrc`/`package.json`/`setup.py` targets)
     dropped the no-op `-r` and keep `grep -n`: a file operand cannot traverse, and `git grep` would go
     blind to a gitignored `.npmrc`, which is exactly the file a credential audit must read.
7. **Pre-existing, unrelated:** `node extensions/main-worktree-guard/test.mjs` fails 2 cases
   (`bd runtime with set (unchecked-out) → recovery: block`,
   `bd runtime branch -D unchecked-out → recovery: block`) **identically at clean `HEAD`** (verified in a
   detached `/tmp/mwg-probe` worktree of `HEAD`: 1807 passed / 2 failed). Not touched by this change.
