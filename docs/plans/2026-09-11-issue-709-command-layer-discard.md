---
title: "#709 — gate the working-tree-discard family at the command layer — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-709, issue-664, issue-678, issue-617, issue-623, issue-744, main-worktree-guard
---

# Issue #709 — Gate the working-tree-discard family at the command layer

**Issue:** [#709](https://github.com/daniel-ospina/agent-infra/issues/709) · **Complexity:** standard · **Date:** 2026-09-11

## Objective

Intercept the working-tree-discard family at the **command layer** for the actor that
actually performs it — including `task` / `pi -p` sub-agents — keyed on the command's
**effect on uncommitted tracked work**, not on whether the argv matches a blocked git
verb.

## Confirmed problem

`extensions/main-worktree-guard` gates *git argv*, not the *effect*, and it exempts
worktrees wholesale for the destructive-verb arms:

| Command | Hub (main) | Linked worktree |
|---|---|---|
| `git checkout -- <dirty path>` | **allow** (`classifyGitCommand` pinned `allow` at `test.mjs:108`) | allow |
| `git checkout <tree-ish> -- <path>` | allow | allow |
| `git restore <path>` | `block:restore` | **exempt** (`eff.isWorktree`) |
| `git checkout .` / `-f` | `block:checkout-discard-all` / `block:force-checkout` | **exempt** |
| `git reset --hard` / `git clean -fd` | `block:reset` / `block:clean` | **exempt** |

The 2026-09-10 incident (an unrestored mutation-test mutant in the shared hub,
[#664](https://github.com/daniel-ospina/agent-infra/issues/664)) is exactly the first
row: the discard that matters is the one that classifies `allow`. The M4 hub-state gate
does block `git checkout -- <path>` *while the hub is disordered* (`test.mjs:2247`) —
the clean-hub case, and every worktree case, are open.

Sub-agents: `spawnSubAgent` strips `AGENT_ALLOW_MAIN_EDITS`/`ELDATO_ALLOW_MAIN_EDITS`
(#617/#623) and `main-worktree-guard` is not disabled by `SKILL_ENFORCER_DISABLED`, so
the guard **is** the enforcement surface for `pi -p` children — it just doesn't cover
the discard family.

## Design

A new **effect-keyed** arm (M5) in the bash branch of `main-worktree-guard/index.ts`,
fed by a new pure classifier export in `classify-git.mjs`:

```
extractWorkingTreeDiscards(command)
  → [{ inv, verb, args, scope: "all" | "paths", pathspecs: string[], form: string }]
```

Family (token-level, from `allGitInvocations`):
- `checkout` — `-- <pathspec>…`, `<tree-ish> -- <pathspec>…`, bare `.`/`./…`/`:/…`,
  `-f`/`--force` (scope `all` when no pathspec)
- `restore` — worktree restore (bare, `--worktree`, `-s <tree>`); **`--staged`-only is
  index-only and stays allow**
- `switch` — `-f` / `--force` / `--discard-changes`
- `reset --hard` — scope `all` (or the paths after `--`)
- `checkout-index -f` / `-a`, `rm -f`, `read-tree --reset -u`, `apply -R`,
  `checkout -p`, `restore --staged --worktree`, `checkout <bare-path>`,
  `:(magic)` pathspecs, `-2`/`-3` stages, `show <rev>:<p>` / `show :<p>`
- non-git revert shape: `git show <rev>:<path>` / `cat-file` whose stdout is redirected
  onto a tracked path
- **script files** — `bash /tmp/undo.sh`, `./undo.sh` (executable) and `source f` are
  read (depth ≤ 3, ≤ 64KB) and the same extraction runs on their content; M4's
  `_backdoorBlock` returns early for worktrees, so this is the one surface a worktree
  `pi -p` child could otherwise hide in. `eval '<payload>'` is extracted one level.

Reviewer round-1 fold-in: long options match by **unambiguous prefix**
(`--har` ≡ `--hard`), `git checkout <tree-ish> <path>` without `--` is a path
restore, quoted-split verbs (`git ch'ec'kout`) are resolved by the tokenizer, and
the fail-closed set grew to `--pathspec-from-file`, xargs/find placeholders, `eval`
payloads and `--work-tree` targets. False-positive guards: a flag before `--` is not
a tree-ish, `--staged` prefixes stay index-only, `--ours/--theirs` and unmerged
(`UU`/`AA`/`DD`) entries are not discards, heredoc DATA bodies and full-line `#`
comments are stripped, and the direct invocation's cd chain is no longer
double-applied.

Reviewer round-2 fold-in: a surviving `--staged` (with `--worktree` or a
`--source=`) is tree-sourced; heredoc/comment scanning is quote-aware (a `<<`
inside quotes no longer opens a phantom heredoc that blinds the rest of the
command, and a mid-line `#` comment is not a command); CODE-interpreter heredocs
(`python3 <<PY`) are extracted through the code-payload path; `git checkout
-p/--patch` and `git apply -R/--reverse` joined the family.

Deliberately NOT in the family: `git clean` (untracked-only — `git clean -fdx` build
artifact cleanup in a private worktree is ordinary, and the M4/legacy arms still block
it in a shared main checkout) and `git stash push` (stores; does not discard).

Effect decision (the whole point): resolve the invocation's effective cwd
(`resolveInvocationTarget`), run a **bounded** `git status --porcelain=v1 [-- <paths>]`
there and block **only** when the discard would destroy uncommitted state:

- scope `all` → any tracked entry (X or Y ≠ ` `, `??`/`!!` excluded)
- scope `paths` → any listed path with a **worktree-vs-index** difference
  (`Y ≠ ' '`), since `checkout --`/`restore` restore from the index; tree-source
  forms (`checkout <tree> --`, `restore -s`) also consider `X ≠ ' '`
- untracked-only dirt → **allow** (`checkout -- .` does not delete untracked files)

Consequences:
- `git checkout -- <clean file>` stays allow → ordinary work unaffected.
- `git restore --staged <file>` stays allow → index-only, per the issue's own note.
- `ls`, `cat`, `git status`, `git log`, `git diff`, `rg` stay allow → read-only proof test.
- The deliberate-discard case (dirty target) blocks **in both hub and worktree**, and the
  block reason directs to the copy-based probe recipe (#664) — never mutate in place.

### Escape hatches preserved (unchanged)

The arm is placed **after** the existing `_isAllowMainEdits() ||
readAllowMarkerState(...)` return in the bash path, so:
- the env hatch (`AGENT_ALLOW_MAIN_EDITS=1` / `ELDATO_ALLOW_MAIN_EDITS=1`) bypasses it;
- the `~/.pi/agent/.allow-main-edits` marker (stamped JSON, session-scoped, 15-min TTL)
  bypasses it;
- `SKILL_ENFORCER_DISABLED` is untouched (and is not read by the guard).

No change to `classifyGitCommand`/`classifyGitCommandDetailed` verdicts → the frozen
`allow` pins and the M2/M3/M4 arms are byte-identical. M5 only **adds** blocks on top.

## Wiring

| Surface | Wiring point | Test |
|---|---|---|
| `classify-git.mjs` | new exports `extractWorkingTreeDiscards` + `discardDestroysWip` (pure) | `test-discard-gate.mjs` Part A |
| `index.ts` loader | M5 exports read from the cached module namespace (NOT added to the destructuring assignment — each new target there is a new `test-module-load.mjs` Part A assertion, and that suite's contract is exactly 49/0) + typeof skew guards | `test-module-load.mjs` 49 passed / 0 failed, real load with 0 degradation warnings |
| `index.ts` bash arm (M5) | `_worktreeDiscardBlock(command)` after the marker/env return, before the degradation/full classifier arms | `test-discard-gate.mjs` Part B (hub + linked worktree, dirty/clean) |
| script-file surface | `extractScriptPath` + bounded content walk inside `_worktreeDiscardBlock` | `test-discard-gate.mjs` B6e/B6f |
| `pi -p` sub-agent | `spawnSubAgent` strips the env hatch (#617/#623); M5 runs in the child's process (env hatches removed in Part B; `SKILL_ENFORCER_DISABLED=1` set) | `test-discard-gate.mjs` Part B |
| escape hatches | arm sits after the hatch return; no change to marker parser/env checks | `test-discard-gate.mjs` B11a–d |
| negative controls | clean targets, untracked-only dirt, `--staged`, read-only commands | `test-discard-gate.mjs` B5/B7a/B8 |

## Verification checklist

| Surface | Layer | Expected |
|---|---|---|
| classification | unit | every family form extracts with the right scope/pathspecs; `--staged` excluded |
| effect | unit | dirty hub target blocks; dirty **linked-worktree** target blocks; clean target allows |
| `all` scope | unit | `checkout .` / `-f` / `reset --hard` / `clean -fd` block iff a tracked entry is dirty |
| read-only | unit | `ls`, `cat x`, `git status`, `git log`, `git diff`, `rg x` all allow |
| index-only | unit | `git restore --staged f` allows |
| hatches | unit | env hatch + marker bypass M5 |
| module load | unit | `test-module-load.mjs` stays **49 passed / 0 failed** |
| full suite | unit | `test.mjs` no new failures (baseline on `origin/main`: 1786 passed / 2 failed) |
| behavioral | new suite | `test-discard-gate.mjs` 254 passed / 0 failed |

Reviewer round-3 fold-in: `git checkout --ours/--theirs/-m/--merge/--conflict=`
now yields a descriptor instead of being exempt outright — they are conflict
resolution only on an UNMERGED path, and on a plain modified file real git
treats them as an index-source restore that destroys WIP (the pure unmerged
skip keeps genuine resolution allowed). `git checkout-index -f --stdin` fails
closed (target list on stdin), `--prefix=`/`--temp` are not discards, `git
apply -R3`/`-3R` joined the reverse cluster and `-R --check/--stat/--numstat/
--summary` are report-only, `git rm --cached`/`-n` are index-only/dry-run,
heredoc bodies behind SPAWNER wrappers (`env|nice|nohup|command|timeout N
bash`) and absolute-path interpreters (`/bin/sh undo.sh`, `busybox sh
undo.sh`) are now reached, backtick substitution and in-command git aliases
are resolved, and the index.ts pre-bail no longer defeats the quote-aware
tokenizer (`g"it"`/`'g'it`/`g\it`).

Reviewer round-4 fold-in: a single bare `git checkout <token>` is ref-or-path —
the pure extractor flags `ambiguousRef` and the handler resolves it with a
`rev-parse` probe (a ref is a switch, anything else is a path restore), which
closes the incident verb's twin without `--`; `:(magic)` pathspecs and the
`-2`/`-3` numeric stage shortcuts joined the family; a heredoc consumer that is
NOT the first token of the line (`true && bash <<EOF`, `set -e; bash <<EOF`,
`cd <wt> && bash <<EOF`) is now resolved (previously the body was blanked, i.e.
detection was silently REMOVED); `_wtScanLine` tracks word starts so an ESCAPED
space before `#` no longer truncates the line; `_wtBacktickSpans` tracks double
quotes (an apostrophe inside `"…"` hid later spans); `$'\x67it'` ANSI-C
command words are decoded; `git show refs/heads/main:p > p` and `git show :p > p`
are recognised. False positives: `--source` without `--staged` is worktree-only
and `checkout-index`/plain `apply -R` are index-sourced, so all three use
`fromTree: false` and no longer block a staged-only change; `apply -R --cached`
is index-only; `{git,}` brace alternation and a command-position `$(echo git)`
are documented residuals (open-ended grammar-spelling class).

Reviewer round-5 fold-in: `_wtScanLine` re-emits the heredoc DELIMITER (it used
to drop it, so the shared walker's `<<` + operand skip ate the next real command
word — `cat <<EOF … EOF` followed by `git checkout -- f` was invisible) and
ignores `<<` inside `(( ))` arithmetic, inside a multi-line quoted string, and
inside a quoted segment when choosing the opener (`echo 'a<<b' && bash <<EOF`);
ANSI-C decoding is restricted to a plain command word so a decoded quote/`<<`
cannot re-parse as syntax; quoted `$( … )` spans are walked; a non-static git
verb (`git "$@"`), a `$`-bearing script path (`bash $S`) and a file piped into a
shell (`cat undo.sh | bash`) fail closed / are walked; an xargs/`find -exec`
FEEDER with zero positionals falls back to the conservative descriptor; and
`git restore --staged --pathspec-from-file=…` is index-only → allow. `git
checkout -f <path>` resolves through the same ref-vs-path probe (a ref keeps
whole-tree scope). `extractScriptPath`'s basename matching is now
ABSOLUTE-ONLY — matching `./time evil.sh`'s basename had retired the M4
script-content closure for colliding names. Residual: a script run from inside a
shell FUNCTION body (`f(){ bash /tmp/undo.sh; }; f`).

Reviewer round-6 fold-in: an UNQUOTED heredoc delimiter is read as a shell word
(`cat <<E-O-F`, `<<EOF.txt` — stopping at the first non-word char left the
terminator unmatched and swallowed every later line, including a discard); a
REDIRECTION before the interpreter (`2>/dev/null bash <<EOF`) no longer defeats
head resolution; `ash`/`mksh`/`oksh` joined the shell set; the substitution
passes now run on the STRIPPED text (heredoc data and `#` comments produced
phantom descriptors); here-strings (`bash <<< 'git checkout -- f'`) and process
substitution (`bash <(printf 'git checkout -- f')`) feeding an interpreter fail
closed, as does an opaque interpreter `-c` payload (`S=…; bash -c "$S"` —
resolved when the assignment is in the same command); and bare `git restore`
(a git usage error) is allow again.

## Non-goals / residuals

- Not blocking all git in worktrees — only the discard family, and only when it destroys
  uncommitted tracked work.
- Not extending the write-tool/main-worktree-guard hub write gate to worktrees: ordinary
  tracked-file edits in a worktree are the point of a worktree (the #625 in-place
  *overwrite* gate keeps its existing hub scope; the M5 non-git arm covers only the
  `git show <rev>:<path> > <path>` revert shape).
- Documented residual: `cp backup file` / arbitrary interpreter writers that rewrite a
  tracked file from a non-git source are not detected as discards (indistinguishable
  from an edit without reading content). Tracked as a follow-up if the fleet needs it.
- Probe failure (`git status` errors) is fail-safe allow, matching the codebase's
  existing write-gate convention ("never false-block"); an unresolvable invocation
  target (`$VAR` cd chain), an unresolvable pathspec, `--pathspec-from-file`,
  xargs/find placeholders and an unresolvable `eval` payload fail **closed**.
- Script-file discards are covered to a bounded depth (`bash /tmp/undo.sh`,
  `./undo.sh`, `/bin/sh undo.sh`); a chain deeper than 3 and a nested `eval`
  are documented residuals (same class as the #627 residual). A git alias
  configured in an EARLIER command (`git config alias.zz 'checkout --'` then
  `git zz f`) is a documented residual — resolving it needs a config read; the
  same-command `-c alias.x=` and `config alias.x … && git x` forms ARE gated.
- `git worktree remove --force <wt>` (whole-checkout teardown of ANOTHER
  checkout's WIP) is a documented residual — it is not a working-tree discard of
  the checkout the command runs in; the `using-git-worktrees` manifest gate is its
  control.
- A non-static command word (`{git,}` brace alternation, `$(echo git)` in command
  position) is the same open-ended bash-expansion family as README Residual 1 —
  closing it needs a full expansion evaluator.
- A script executed from inside a shell FUNCTION body (`f(){ bash /tmp/undo.sh; };
  f`) is not resolved — the head of the line is not an interpreter. The
  direct-pipe form (`cat /tmp/undo.sh | bash`) IS walked.
