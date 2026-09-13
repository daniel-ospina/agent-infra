# main-worktree-guard — Pi extension

Guards the **SHARED main checkout** of a project against two classes of
collision between parallel agents:

1. **write/edit tool calls** targeting a repo's main checkout (parallel agents
   editing main could silently overwrite each other's uncommitted changes),
   and
2. **destructive/state-changing git commands** via the bash tool — `git reset
   --hard`, branch checkout/switch, pull/merge/rebase, clean, force-push,
   `branch -D`, restore, stash pop (incident 2026-08-06: a `git reset --hard
   origin/main` mid-PR yanked the working tree out from under another agent).

**Worktrees are ISOLATED** — none of this applies to writes INSIDE a linked
worktree, with ONE exception: the working-tree-discard family (M5, #709) is
effect-keyed and applies in a linked worktree too, because that is where the
`pi -p` review fixers run. See M5 below.

**#618/#621 — hub-write gating is TARGET-aware:** the write/edit gate and the
tracked-file bash gate resolve the WRITE TARGET's repo checkout
(`resolveTargetCheckout` — git toplevel + MAIN-vs-worktree, realpath-normalized,
cached), never the session cwd. A tracked-file write into ANY repo's MAIN
checkout is gated wherever the session sits: worktree sessions (previously
exempt wholesale), foreign/non-git cwds (previously invisible — no toplevel to
compare), and other repos' sessions (an agent-infra-rooted controller writing
tortoise/premise-labs/DMeer/eldato main after the #615 removal). Own-worktree
writes stay free (their targets resolve to the worktree's checkout, never a
main checkout — epic-529 preserved structurally). New ADDITIVE files into a
hub main stay free: they WARN on the #350 WIP patterns only — but an
overwrite of any EXISTING hub-main file (tracked, `.git/`-metadata, or
untracked WIP) is a destructive cross-session write and blocks.

There is **NO auto-bypass**: the guard blocks every time, so a rogue or
parallel agent cannot retry its way past it. Escapes are deliberate and
documented (env hatch below, escape marker below).

**Degradation (fail-safe — and fail-OPEN):** if `classify-git.mjs` fails to
load (jiti edge case) **totally**, every binding from the failure point on
keeps its inert default. The bash guard degrades to **non-blocking** — one
load-time warning, then every command passes silently — and the write/edit
guard **fails open**: its target classification (`resolveTargetCheckout`,
`hasDotGitAncestor`) is among the stubbed bindings, so the gate takes its
"isolated by construction" branch and allows. The inert defaults are deliberate
— a failed import must never false-block — but the consequence is that a load
failure is a **silent loss of enforcement, not a safe mode**, which is why
`test-module-load.mjs` (below) pins the load path itself. A **partial** failure
is the different shape #744 had — a destructuring abort keeps whatever bound
before it, so the earlier gates (script-content, the #73 delete arm) kept
working — see the section on the #744 fix below. The escape-marker
check is the exception: it degrades to **inactive** (block) on any failure — a
failed import or stamp never silently allows.

## M5 — working-tree-discard gate: effect, not argv (#709)

The legacy destructive-verb arms key on **git argv**, and two gaps followed
from that:

- `git checkout -- <path>` — the 2026-09-10 incident verb (an unrestored
  mutation-test mutant left in the shared hub, #664) — classifies `allow`
  (pinned by `test.mjs:108`); the M4 hub-state gate catches it only while the
  hub is DISORDERED.
- Every other discard verb (`restore`, `checkout .`, `checkout -f`,
  `reset --hard`) is exempt wholesale in a **linked worktree** (repo
  convention: review work happens in worktrees), which is where the `pi -p`
  mutation-test fixers actually run.

M5 keys on the **effect** instead. A discard-family command is blocked when
the checkout it targets is carrying uncommitted work that the discard would
destroy:

| Form | Scope | Discards |
|---|---|---|
| `git checkout [<tree-ish>] -- <paths>` | paths | worktree vs index |
| `git checkout <path>` (one bare token, not a ref) | paths | worktree vs index — the handler's `rev-parse` probe decides ref vs path |
| `git checkout -f <path-or-ref>` | all (ref) / paths (path) | forced switch, or a single-path restore — the handler's `rev-parse` probe decides |
| `git checkout .` / `./x` / `:/x` / `:(magic)` | paths | worktree vs index |
| `git checkout -f` / `--force` | all | everything tracked |
| `git restore [--worktree] [-s <tree>] <paths>` | paths | worktree (index only with `--staged`) |
| `git switch -f` / `--discard-changes` | all | everything tracked |
| `git reset --hard [-- <paths>]` | all / paths | index + worktree |
| `git checkout-index -f <paths>` / `-a` | paths | index vs worktree |
| `git checkout -p` / `--patch` | paths / all | interactive hunk discard |
| `git checkout --ours` / `--theirs` / `-m` / `--conflict=<style>` / `-2` / `-3` | paths | index vs worktree — conflict resolution ONLY on an unmerged path |
| `git restore --staged --worktree` | paths | index reset from HEAD + worktree |
| `git rm -f <paths>` | paths | index + worktree |
| `git read-tree --reset -u` | all | index + worktree |
| `git apply -R` / `--reverse` (`-R3`/`-3R` too) | all | reverses an applied patch (paths live in the patch); index only with `--index`/`--3way` |
| `git show <rev>:<path> > <path>` | paths | committed content over the file (slashy revs and `:path` index source included) |

Long options match by **unambiguous prefix** (`--har` ≡ `--hard`, `--discard-ch` ≡
`--discard-changes`), `git checkout <tree-ish> <path>` without `--` is treated as
the path restore git executes, and `git checkout <token>` (a single bare token) is
resolved by a `rev-parse` probe — a token that names a commit is a branch/tag
switch, anything else is a path restore (`git checkout -f <ref>` keeps whole-tree
scope because a forced switch discards everything). **Fail-closed** (effect not
statically resolvable): `--pathspec-from-file`, `--stdin` target lists,
`$VAR`/backtick pathspecs, xargs/find `-exec` placeholders (`{}`/`{}+`), a
non-static git VERB (`git "$@"` behind a shell function), a `$`-bearing script
path (`bash $S`), an unresolvable `cd` chain, and an `eval` payload that cannot
be resolved. **Fail-open** (never false-block): an unreadable `git status` on a
directory that is not a checkout.

`git restore --staged`-style **index-only** operations (`git restore --staged`
— including the `--pathspec-from-file` spelling — `git rm --cached`,
`git rm -n/--dry-run`, `git apply -R --cached`),
**report-only** reverse applies (`git apply -R --check/--stat/--numstat/--summary`),
`git checkout-index --prefix=<dir>`/`--temp` (exports elsewhere), unmerged conflict
entries (`UU`/`AA`/`DD` — which is what keeps
`checkout --ours/--theirs/-m/--conflict=` legitimate on a REAL conflict), heredoc
**data** bodies, string-quoted `<<` phantoms (incl. `<<` in `(( ))` arithmetic
and inside a multi-line quoted string), and `#` comments (full-line and
mid-line, honouring the escaped-whitespace rule) are NOT discards; code heredocs
(`bash <<EOF`, `cat <<EOF | bash`, `python3 <<PY`, the SPAWNER-wrapped forms
`env|nice|nohup|command|timeout N bash <<EOF`, and any list-form consumer such as
`true && bash <<EOF` / `set -e; bash <<EOF`) and executable scripts
(`./undo.sh`, `bash undo.sh`, `/bin/sh undo.sh`, `busybox sh undo.sh`, and a
script PIPED into a shell — `cat undo.sh | bash`; alternate shells `ash`/`mksh`/`oksh`
and a redirection before the interpreter — `2>/dev/null bash <<EOF` — included) ARE
walked (bounded depth 3, 64KB), quote/escape-concat verb names (`g"it"`, `'g'it`,
`g\it`) are resolved by the tokenizer (the arm's pre-bail is quote-aware), ANSI-C
command words (`$'\x67it'`) are decoded when they form a plain word, and backtick
substitution (`` `git checkout -- f` ``), a quoted `$( … )` substitution, and an
in-command git alias (`git -c alias.z='checkout --' z f`, `git config alias.zz …
&& git zz f`) are resolved too. The substitution passes run on the STRIPPED text,
so heredoc data and `#` comments cannot produce phantom descriptors. An
UNQUOTED heredoc delimiter is a shell word (`<<E-O-F`, `<<EOF.txt`), not
word-characters only. A data heredoc no longer swallows the NEXT
command word: the delimiter is re-emitted so the shared walker's `<<` + operand
skip consumes the placeholder, not the following `git`. **Also fail-closed**: a
here-string or process substitution feeding an interpreter (`bash <<< 'git
checkout -- f'`, `bash <(printf 'git checkout -- f')`) and an opaque interpreter
`-c` payload (`S=…; bash -c "$S"` — resolved when the assignment is in the same
command, else blocked when the command mentions a discard verb).

The decision (`discardDestroysWip`) is pure and unit-tested: scope `all`
blocks on ANY tracked porcelain entry; scope `paths` blocks on a
worktree-vs-index difference (`Y ≠ ' '`) — a `fromTree` source (a commit/tree
restore or a `--staged` index reset) additionally destroys a staged-only change
(`X ≠ ' '`). Index-sourced operations (`checkout-index`, plain `apply -R`)
therefore use `fromTree: false` even at whole-tree scope — a staged-only entry
is already in the worktree and survives them. `git restore` with no pathspec (a git usage error) and `echo <<< 'git checkout …'`
(a non-interpreter here-string) are inert. **Allowed**: untracked-only dirt
(`checkout -- .` never deletes `??`), staged-only changes for an
index-source restore, clean targets, `git restore --staged` (index-only), and
every read-only command. Unresolvable targets (`$VAR` pathspec, unresolvable
`cd` chain) fail CLOSED; an unreadable `git status` fails open (never
false-block), matching the repo's write-gate convention.

**Escape hatches are unchanged**: M5 sits after the env-hatch / TTL-marker
return, so `AGENT_ALLOW_MAIN_EDITS=1` and the `~/.pi/agent/.allow-main-edits`
marker bypass it exactly as they bypass M2/M3. Task children are unhatched by
default (#617/#623), so for the `pi -p` fixer M5 — not a prose rule — is the
enforcement surface.

`git clean` is deliberately NOT in the family (untracked-only; build-artifact
cleanup in a private worktree is ordinary, and the M4/legacy arms already
block it in a shared main checkout). `cp <backup> <tracked>`, arbitrary
interpreter writers, a script chain deeper than 3, a nested `eval`, a script run
from inside a shell FUNCTION BODY (`f(){ bash /tmp/undo.sh; }; f` — the head of
the line is not an interpreter; the direct-pipe form IS walked), a git alias
configured in an EARLIER command (`git config alias.zz 'checkout --'` then
`git zz f` — resolving it needs a config read; the same-command form IS
gated), a non-static command word (`{git,}` brace alternation, a
command-position `$(…)` such as `$(echo git)` — the same open-ended
bash-expansion family as Residual 1), `git show <rev>:<clean> > <dirty>`
(cross-path overwrite), and `git worktree remove --force <wt>` (whole-checkout
teardown, not a working-tree discard of the current checkout — the
`using-git-worktrees` manifest gate is its control) are documented residuals —
indistinguishable from an edit without reading file content (the #625 in-place
overwrite gate keeps its existing shared-main scope).

Three further documented residuals were found by the round-9 adversarial review
and are tracked as follow-ups rather than fixed here (each is a narrow,
deliberate-obfuscation-adjacent spelling, and the obvious fixes carry real
false-positive risk): **(a)** a destructive FLAG supplied through a variable
(`H=--hard; git reset $H`, `F=-R; git apply $F <patch>`) — the extractor keys on
literal flag tokens, and failing closed on every `$`-bearing argument would
false-block the ordinary `git checkout -b "$BRANCH"`; **(b)** a
`git show <rev>:<path>` revert piped into a writer the write-target model does
not know (`| dd of=<path>`, `| cp /dev/stdin <path>`; redirects, `tee` and
python `open()` ARE gated); **(c)** `bash /dev/stdin < script.sh`, where the
script operand is a FIFO so the bounded walk reads nothing and the `<` operand
is not reached. None of the three is in the `pi -p` fixer's ordinary path.

Two fail-closed COSTS are accepted alongside them: any NULL-VERB `git` in a
command that mentions a feeder (`printf 'status\n' | xargs git`, and even
`echo 'use xargs to batch' && git --version`) blocks while the tree is dirty,
because a null-verb `git` under an `xargs`/`find -exec` feeder has its
subcommand supplied at runtime (the walker consumes terminal global flags, so
`--version` is indistinguishable from the bare form) and the textual probe for
it was evadable (`printf 'check\'\'out -- f`, `printf 'check\x6fut -- f`); and
an opaque `-c` payload sharing a command with a discard verb blocks even when
the visible invocation is legitimate.

## M4 — hub-state gate: the hub stays on `main` + clean (#1484)

The **hub** (the shared main checkout of a guarded repo — agent-infra included
since #615) has exactly two
legal states: checked out on `main`/`master` and a clean working tree
(`git status --porcelain` empty — **untracked files count as dirty**). M4
enforces this at runtime: **when the session cwd IS the hub and it is off-main
or dirty, every git operation outside the sanctioned recovery allowlist is
BLOCKED**, and write/edit in the hub is blocked too.

| Allowed (sanctioned recovery) | Blocked |
|---|---|
| `git checkout main` / `git checkout master` | `git commit`, `git add` |
| `git pull --ff-only` (plain pull may merge → blocked) | `git checkout -b` / `switch -c`, any other checkout |
| `git fetch` | `git push` to any branch but the checked-out one |
| `git status`, `git log`, read-only ops (`diff`, `show`, …) | `git merge` / `rebase` / `reset` / `clean` / `restore` |
| `git worktree add/list/prune/remove` | `git push -f` / `--delete` (see #436 carve-out below) |
| `git push origin <currently-checked-out-branch>` (WIP preservation) | write/edit OVERWRITES in the hub (see #436 carve-out below) |
| `touch ~/.pi/agent/.allow-main-edits` (escape marker) | |

**#436 carve-outs (collision-free ops stay legal while disordered):** two
classes of operation that cannot touch the dirty set or any sibling are
**allowed** in a disordered hub, mirroring the degradation path's
not-checked-out-anywhere semantics:

1. **Branch ref-cleanup** — `git push origin --delete <b>` and
   `git branch -D <b>` are allowed when `<b>` is checked out NOWHERE in this
   clone (not the hub's branch, not in any worktree) and is not `main`/
   `master`. `git` itself refuses deleting a branch checked out in any
   worktree; the remote-delete gate protects siblings whose worktree tracks
   the deleted branch. Shape-restricted (fail-closed): the remote (when
   present) must be exactly `origin`, no pre-flag positionals (git treats
   them as delete refspecs — `push origin pr1467 --delete stale` deletes
   both), and `main`/`master`/`.`/local-path/URL remotes are refused.
   Per-invocation and opt-in (the caller passes the checked-out set) — a
   compound `delete && commit` still blocks on the commit (no laundering).
   Documented residuals (#439 P2-3): if `git worktree list` fails the set
   degrades to the hub's own branch only (a sibling worktree checkout of the
   deleted branch is then invisible — local `branch -D` stays protected by
   git itself); sibling CLONES of the repo are out of the guard's visibility
   (same limitation as the degradation path).
2. **New-file writes** — the write/edit tool may CREATE a file at a path that
   does not exist AND is not inside the immediate container of a sibling
   untracked file (expanded `--untracked-files=all` porcelain). Overwrites
   of existing files (tracked or untracked) stay blocked — that is the
   hub-feature-edit vector (#347 amplifier). Fixes the tortoise #2238 friction
   (new docs forced to /tmp during the API-keys workstream). Residuals
   (#439 P2-4, additive-only): immediate-container scope (a deeper tracked dir
   containing a sibling's new subdir stays writable) and lexical (not
   symlink-resolved) path comparison. Both carve-outs are pure-logic
   unit-tested in `test.mjs` (`branchDeleteNames` /
   `branchDeleteAllowance` / `newFileWriteCollisionFree` + runtime pins).
   **#628 volume policy (warn → escalate → cap):** collision-free is not
   harm-free — unbounded new files grow the dirty set the hub recovery must
   later carry, and the carve-out returned before any write-time prompt. The
   carve-out now (a) warns at WRITE TIME for every new hub file while
   disordered (all paths — not just the #350 `docs/plans`/`migrations`/scratch
   patterns), (b) escalates the banner once a session crosses
   `HUB_NEW_FILE_WARN_BUDGET` (10) new files, and (c) BLOCKS past
   `HUB_NEW_FILE_BLOCK_CAP` (25) with a worktree-routing reason
   (`hubNewFileVolumeVerdict`; per-session counter). The block is a true
   positive by construction (a disordered hub is already illegal), so it does
   not violate the "false-blocks are not acceptable" doctrine; the common
   one-or-two-new-files case (#436 tortoise #2238 friction) is unchanged apart
   from the banner. Prompts are suppressed under the env hatch / an active TTL
   marker (the documented prompt contract); the CAP stays active under the
   marker (D3 — the marker never re-enables hub writes).

**Why WIP preservation:** the 2026-08-18 incident left 38 commits on `pr1467`
in the hub. `git push origin <checked-out-branch>` is the ONE allowed push so
a stranded lane's work never silently dies before recovery.

**Escape-hatch interaction (D3):** M4 **stays ACTIVE under the TTL marker** —
consistent with the #265 contract that M1 detection stays active under the
hatch. A stranded lane can recover with the marker (or even without it — the
sanctioned recovery ops above are allowed directly), but **cannot resume
feature work in the hub**. Only `AGENT_ALLOW_MAIN_EDITS=1` (env, set at
session start, deliberate solo session) disables M4. The sanctioned terminal
one-liner (`cd <repo> && git checkout main && git pull --ff-only`) is
touched only by humans and is unaffected.

**Scope (#347/#618/#621):** M4 fires only when the session cwd IS the hub's main checkout
and the hub is off-main/dirty. Worktree sessions are exempt from the M4 git-verb gates (they are isolated
by construction); the write gates are TARGET-aware (#618/#621) — a worktree or
foreign session's tracked-file write into a hub main checkout is gated by the
TARGET repo even though M4 never fires on the session cwd. Agent-infra is NOT exempt (#615 — the #99 carve-out is
removed: its main checkout is a pure hub too, so it gets the same M4 discipline
as every other repo). **Worktree-
TARGETED git ops are exempt per-invocation:** M4 resolves each git invocation's
EFFECTIVE target (cd-chains, `-C`, `GIT_DIR`/`--git-dir`, subshell/pipe/`&`
scoping, `git worktree list` membership derived from the worktrees' reverse-
pointer admin dirs — porcelain has no gitdir column — + cwd containment,
realpath-normalized) and exempts worktree-targeted invocations — a hub-rooted
session that `cd`s into a worktree is no longer frozen by hub disorder
(2026-08-27 tortoise incident class). **CROSS-REPO worktrees (#397):** the
worktree map used to be derived from the SESSION cwd frame only, so a worktree
of a DIFFERENT repo (an agent-infra worktree reached from a tortoise session)
missed the map and every sanctioned agent-infra mutation was false-blocked
(2026-08-30 #387: 4 commits, 3 pushes, a PR body and a tag all had to be
delegated to gate-exempt sub-agents). `resolveInvocationTarget` now falls back
to deriving the map from the invocation's OWN frame (the cwd where git itself
resolved the git-dir) with the same two-way back-reference + porcelain
cross-check — a foreign worktree is recognized, tagged `foreignWorktree`, and
treated as **fully isolated**: git repos never share ref namespaces, so none of
the session-hub protections (shared-ref re-classification, main-protection,
protected-branch refspec guards) apply to it. Only the session repo's own
worktrees share the hub's ref namespace. A foreign-wt push/fetch whose remote
operand resolves into the session hub's repo is NOT exempt — it rewrites the
hub's OWN refs: direct local paths, `file://`/`file://localhost/` URLs (LOCAL
transports), CONFIGURED remote names whose (push)url is a hub path (`remote add
hub <hub-path>` then `push hub main`), `-c`/`--config`/`--config-env=`/
`GIT_CONFIG_*` remote overrides (effective-config probes, cycle-4/5), `--repo=`
(a FALLBACK — the positional `<repository>` takes precedence per git docs),
and bare/refspec-first pushes resolving to such a remote (cycle-2/3/4/5
closures, same git-common-dir identity). Documented residual: a foreign-wt
push naming the session repo's origin as a NON-local URL (http/ssh/git/scp)
can still advance the session repo's REMOTE refs — the gate cannot cheaply
compare remote URLs; the session hub's LOCAL refs are unreachable through a
non-local transport.**Shared-ref verbs are NOT exempt (round-3 inverted allowlist):** worktrees
share the hub's ref namespace — only worktree-LOCAL verbs (commit/add/reset/
merge/rebase/checkout/restore/clean/apply/pull/… — the wt's own working tree,
index, and branch) are auto-exempt; everything else (`push`/`update-ref`/
`symbolic-ref`/`tag`/`branch -D`/`remote`/`stash`/object-store/UNKNOWN verbs
like `git subtree push`) is re-classified against the worktree's OWN checked-out
branch (`git push origin <the wt's branch>` is the carve-out; push `-f`/
foreign/delete/empty-source-`:ref`/`--all`/`--prune` still block).
**Main-protection:** a worktree checked out on `main`/`master` is the hub's
protected branch — mutations block; `git checkout main` AND force forms
(`checkout -B main`) from a worktree while the hub is off-main (main free)
block. (Both bullets are session-repo-scoped: foreign worktrees are exempt per
the #397 doctrine above.) **Recovery-checkout verification (#397 hardening):**
a sanctioned-recovery `git checkout main|master` is refused loudly when the
branch cannot be checked out in the target repo (no local `refs/heads/<b>` and
no unique remote-tracking DWIM source — DWIM is checked per configured remote's
FETCH REFSPEC, matching git's `checkout --guess`/`unique_tracking_name`, so a
planted tracking ref with no matching refspec, or a multi-remote ambiguity,
both block) — `git checkout -q main
2>/dev/null` swallows the failure, the agent proceeds believing it is on main,
and the next destructive op moves the CURRENT branch (2026-08-30 #387: a
swallowed checkout failure preceded a reset that moved `feat/387-ci-central`
to main). The gate fails loudly instead of blessing a doomed checkout.
(Residuals: `git -c checkout.guess=false` disables DWIM entirely; a dirty
working tree can still fail the checkout at run time — both fail VISIBLY
unless stderr is swallowed; the hardening closes the silent-failure class.)
The same hardening applies to the SCRIPT surface (`scriptGitVerdict`).
**Interpreter-inline gating:** `bash -c 'git …'`/`sh -c`/`zsh -c`/
`eval` content is recursively parsed and gated (no inline bypass);
`bash -x evil.sh` style leading interpreter flags are skipped (script files
still gated). **fetch/pull refspecs:** explicit `:dst` refspecs writing
`refs/heads/main|master` block (implicit-dst fetches stay recovery).
**symbolic-ref** from a worktree target blocks (shared refs). `GIT_INDEX_FILE`/
`GIT_OBJECT_DIRECTORY` redirecting outside the worktree block (with a
resolve-fallback for not-yet-existing paths). `&>`/`>&`/`&>>` are single
redirect tokens (not background boundaries) and are args boundaries.
`export`/`unset` consume all following args (their operands are never command
words); `unset NAME` deletes the persisted var; redirects never start a command
(a redirect-led `cd` is still the builtin). No total-bash-gate bypass: the
exemption is semantic, never path-string-based; hub/foreign/unresolvable
targets keep today's blocks (including `-C <wt> --git-dir=<hub>/.git …`,
`--git-dir=<hub>/.git/worktrees/<x>` from the hub cwd, `GIT_DIR=<wt>/.git`
from the hub cwd, and crafted reverse-pointer files — mitigated (for the
accidental variants) by two-way back-reference validation plus, since #351, a
`git worktree list --porcelain` cross-check (see the [deliberate-obfuscation
residual tier](#deliberate-obfuscation-residual-tier-out-of-threat-model-351);
a fully-consistent deliberate craft passes both — an agent that writes
`.git/worktrees/` internals directly is a deliberate-bypass actor, same class
as the documented `GIT_INDEX_FILE` limitation). The write/edit M4 block is target-aware (hub-equality): only
HUB-targeted writes block while the hub is disordered (D3 preserved — the
block still runs before the marker bypass); worktree/foreign/`/tmp` writes are
isolated. `GIT_DIR`/`GIT_WORK_TREE` env PREFIXES are scoped to the next command
only (a bare prefix overrides an exported value — bash);
`export GIT_DIR=`/`export GIT_WORK_TREE=` persist for the whole command until
`unset`/`export` without value, and are subshell-scoped (`(unset GIT_DIR)`
does not leak); `VAR=x cd "$VAR"` same-segment expansion is bash-faithful
(pre-assignment — unresolvable → conservative block); `VAR=x` followed by a
redirect is a prefix, not a statement. Worktree exemptions are audited
(`event: "m4_worktree_exemption"` — blocked ops are never logged as
exemptions).

**The script backdoor is CLOSED.** The old escape — `write /tmp/x.sh` + `bash
/tmp/x.sh` — executed arbitrary git unblocked. Now a shell-script execution
(`bash`/`sh`/`zsh`/`source`/`./x.sh`) in the hub whose content performs a
non-sanctioned git mutation is blocked: the script's git ops are gated by the
SAME recovery allowlist. Recovery scripts keep working (`hub-worktree.sh`
contains only `fetch` + `worktree add`), and read-only git in scripts is fine.
**#347:** the script path + content gating resolve against the command's
EXECUTION cwd (cd-resolved, subshell/pipe-scoped) — `cd <wt> && bash x.sh`
resolves x.sh inside the worktree; worktree-targeted script content is exempt,
while content targeting the hub (`git -C <hub> reset …`) blocks even from a
worktree cwd. Subshell-wrapped executions (`(cd … && bash x.sh)`) are covered.
**#627 — the non-shell interpreter sibling is closed too (INLINE payloads).**
`python -c`, `node -e`/`--eval`/`-p`, `ruby -e`, `perl -e`, `php -r`,
`deno eval`, `bun -e`, `lua -e`, `Rscript -e`, `julia -e`, `osascript -e`,
`pwsh -c`/`-Command` (version/path-qualified spellings and `env`/`sudo`/`cd`
wrappers included) are now gated by the SAME allowlist: `extractCodePayload`
resolves the inline payload, and `codePayloadGitVerdict` classifies the
extracted `git …` command(s) with the script surface's per-invocation target
resolution. Single-dash flags are parsed POSIX letter-by-letter with an operand
table, so the real flag+payload is always reached (`python3 -W ignore -c`,
`python3 -Sc`, `perl -we`, `ruby -I lib -e`, `node -r ./setup -e`,
`php -d k=v -r`); exact multi-char single-dash flags (`pwsh -Command`) are
resolved before clustering. Inline payloads are ALSO recursed by the shared
walker, so the structured classifier (M2/M3/M4) sees them.

**How the scanner avoids both bypasses and false-blocks.** A payload is scanned
only when it BOTH references a process-execution sink (module/method identifier
presence — `subprocess`, `child_process`, `os.system`, `execSync`, `Popen`,
`spawn*`, `passthru`, `proc_open`, `popen`, a backtick command, the paren-less
Ruby/Perl `system "…"`) AND contains an argv-shaped `git …` command in
**command position**. Command position is decided from the token stream —
array element 0, a top-level/assigned command string, or a token following only
shell-interpreter / wrapper words — NOT from a sink call window. That is what
makes variable indirection (`cmd = ["git","reset"]; subprocess.run(cmd)`),
aliased/destructured imports (`from subprocess import run`, `import subprocess
as sp`), chained receivers (`require('child_process').execSync(…)`), and wrapper
argv (`["bash","-c","git reset --hard"]`, `["sudo","git",…]`) visible, while
prose/data stay inert (`print('git reset --hard')`, a docstring, a `# git reset`
comment, `subprocess.run(['echo','git reset needed'])`, `os.system('echo git')`,
`{git:'repo'}`, `/git/`, `re.exec(s)`, `x = "os.system('git reset')"`). A
`cwd=<literal>` keyword argument becomes an implicit `git -C <cwd>`, so worktree
parity holds for the standard per-call cwd override as well as the
`cd <wt> && …` chain (`commandExecutionCwd` sees the code invocation's
cd-chain). **Residuals** (#627 → #694): `python -m <module>`, bare
stdin/pipe/heredoc payloads, package-runner wrappers (`npx`/`uv run`), a sink
reached only through dynamic indirection (`__import__('subprocess')`), and
dynamically constructed git commands (`'gi'+'t'`, `chr(103)+…`, base64).
**Documented fail-closed trade-offs.** Three classes are deliberately conservative (blocked) because static analysis cannot separate them from a real payload: (a) an assigned string that contains a command-line-shaped `git …` invocation (`MSG='git reset --hard is forbidden'` alongside a sink); (b) a JS template literal / Python triple-quoted string containing a newline-separated git command line; (c) an argv array whose first element is `git` when the payload also contains an unrelated spawn primitive (`subprocess.run(['ls']); print(['git','reset'])`). All three require a spawn reference to already be present; a plain `print('git reset')` (no sink) stays allowed. Repeated payload flags are UNIONED (node keeps the last `-e`, ruby/perl/osascript concatenate all), PowerShell flags are matched case-insensitively (other CLIs stay case-sensitive, so ruby's `-E utf8` is an encoding operand), command-line strings are normalized past `sudo`/`env`/`nice -n`/`eval`/`nohup` wrappers, and backtick/`$( )` command substitution is scanned.

**File / shebang / module payloads are NOT content-gated** — `python3 x.py`,
`./x.py`, `bash -c 'python3 x.py'` were never gated before #627 either, and
reading an arbitrary repo script against the hub-recovery allowlist false-blocks
legitimate fixtures that run git in temp repos (the same semantics the shell
surface already has). Tracked as separate follow-ups.

### Incident writeup — 2026-08-18 (the canonical hub-discipline failure)

At **13:42 on 2026-08-18**, a lane checked `pr1467` out in the **tortoise hub**
(the shared main checkout). The checkout bypassed the guard (hatch / script
backdoor / terminal — the audit log and the empty unscoped marker file rule
out the TTL-marker path). The consequences, all of which M4 now prevents:

- **29 hours off-`main`** — the hub sat on `pr1467` until 2026-08-19 ~19:00,
  silent because the session-start warning is skipped in print mode and the
  env-hatched session ignored it.
- **38 commits ahead of main** + 3 untracked files (`demo/`,
  `.playwright-mcp/`, a scoping doc) — a stranded divergent tree.
- **Sibling disruption:** other sessions' git ops in the hub hit M2 branch-
  ownership blocks and merge ceremonies needed worktree-context workarounds.
- **VGATE collision:** commit-workflow blocks `git commit` unless every staged
  file passed `[VGATE] verify files:` — foreign staged files from the `pr1467`
  lane tripped VGATE for sibling sessions committing from the hub.
- **Root cause:** the lane's worktree was broken — a detached-HEAD worktree in
  `/private/tmp` (OS temp, reaped), with no `.env`/`.venv`/`.mcp.json` (they
  only lived in the hub). Agents choose the hub when the sanctioned path fails.
  → Slice D ships `hub-worktree.sh` (one command, never `/tmp`, never detached,
  auto-setup symlinks) so isolation is the easy path again.

**The age-gated hub-state check (`hub-state-check.sh`, run at pi session start by
`extensions/session-checks.ts` — #432; launchd can't read ~/Documents under TCC)
watches the main checkouts of agent-infra (#615 — the #99 exemption is removed)
and its sibling hub repos tortoise, premise-labs, DMeer, eldato (#619)**: it fails
loudly with the recovery command and opens one deduped GitHub issue when the
hub goes bad. Day 0 validation: the live `pr1467` hub fails the check — that is
the point.

### What this gate is NOT

- **Not a worktree blocker:** `git worktree add/list/prune` stay allowed.
- **Not a read blocker:** `git status`, `git log`, `git diff`, `git fetch`,
  `git show`, etc. remain available.
- **Not an agent-infra carve-out (anymore):** the infra repo's in-main feature
  work was #99-exempt; the exemption is removed (#615) — agent-infra feature
  work happens in worktrees and its main checkout gets the same gate as every
  other hub. Shared-state edits (MEMORY.md, skills, config) land via worktree
  → merge → sync, or the commit-workflow micro fast-path.
- **Not a terminal gate:** humans in a terminal can always run the one-liner.

## Hub-WIP hygiene warnings — put WIP in a worktree (#350) + #437 tracked-write gate

The **#347 amplifier**: agents write WIP (plan docs to `docs/plans/`,
migrations, scratch files) directly in the hub main checkout instead of an
isolated worktree. The write/edit tool blocks main-checkout edits, but
**bash heredoc/tee/python writes were
unguarded** — so the discipline violation silently accumulates, marks the hub
dirty, and trips M4's freeze. Surfaces:

1. **Write/edit-gate warning:** a write/edit target inside a hub main
   checkout matching the WIP patterns (`docs/plans/` segment pair, any
   `migrations/` segment, scratch suffixes `.tmp`/`.bak`/`.scratch`/`~`) emits a
   prominent `HUB WIP — PUT IT IN A WORKTREE` banner instead of silently
   passing. Relevant where the write is NOT already blocked: NEW-file writes by
   worktree/foreign sessions into a hub via an absolute
   path (target-aware since #618/#621 — the banner fires against the TARGET
   hub, not the session's own cached main). Cross-cwd writes into a hub main
   block when they are TRACKED, `.git/`-metadata, or an overwrite of an
   EXISTING untracked file (another session's uncommitted hub WIP — only
   genuinely NEW files are additive; cycle-2 P2); genuinely-new files are
   warned on the WIP patterns. For main-checkout writes (already blocked), the block reason
   now names the amplifier pattern.
2. **Bash-write GATE for TRACKED files in hub MAIN checkouts (#437 +
   #618/#621):** the gate is TARGET-aware — each write candidate's containing
   checkout is resolved, and hub discipline applies per target. The gate runs
   for EVERY bash command (a CLEAN main-rooted controller writing another
   repo's hub via python/heredoc/tee is gated exactly like the write/edit
   tool — the #621 channel). Same-vs-cross-checkout is judged by the SESSION's
   own checkout, never by a command `cd`-site: when the SESSION is rooted in
   the target main, a bash write (`>`/`>>` redirect, `tee`, python
   `open(…, "w"|"a")`) whose target is an INDEX-TRACKED file is
   **blocked while that hub is OFF-MAIN or DIRTY** —
   the same freeze the write/edit tools apply, on the bash route
   that previously landed the tracked-file dirt of the 2026-08-31 tortoise
   session (write/edit blocked → python-heredoc fallback → landed). When the
   write target is a hub main the SESSION is NOT rooted in (a worktree
   session → its own repo's main, a foreign/non-git cwd, or another repo's
   session — whether the path is absolute or reached by `cd`-ing into the
   hub), the write is a DELIBERATE cross-checkout hub write: a TRACKED
   target blocks REGARDLESS of hub state, and so does any target under that
   main's `.git/` metadata (`.git/hooks/*`, `.git/config`, the `.git`
   pointer — never
   index-tracked, so a cross-checkout session cannot plant a hub hook) —
   the vectors behind the 2026-09-08
   mass `.husky/pre-commit` rewrite from the GitHub parent dir and the
   wt-session python open() probes. Tracked-ness
   is exact (`git ls-files --error-unmatch`, one bounded call for all
   candidates per target repo); hub-equality is realpath-normalized;
   main-vs-worktree is judged STRUCTURALLY (gitdir vs commondir realpaths —
   a main checkout whose path contains a `worktrees` segment is not
   misread as a linked worktree), and a symlinked/external `.git` dir is
   caught by testing the UNREALPATH'd spelling too (cycle-2 F4).
   Two scoped relaxations (cycle-2/3 fold-ins): (a) a main checkout strictly
   NESTED under the session's own checkout tree (a private submodule /
   vendored / experiment copy inside the session's work area) is NOT a
   shared hub ONLY when the SESSION ITSELF is a NON-main checkout — a
   worktree/private checkout owns its tree, so the cross-checkout freeze
   does not reach it (the sibling-hub vectors — GitHub-parent foreign cwds,
   other repos' canonical main checkouts — are never under a worktree's
   private tree either); a MAIN-rooted session's nested checkouts (a
   submodule under a hub) stay frozen — the exemption is capped at non-main
   sessions so an ancestor MAIN over sibling hubs cannot lift the freeze
   (cycle-3 B-1); (b)
   under an active TTL marker the bash gate keeps only M4 D3's
   disordered-OWN-hub freeze, mirroring the write/edit route whose #618 gate
   the marker return precedes (the marker is an audited solo-session hatch).
   Hub `.git/`-metadata writes block for ANY session in ANY hub state EXCEPT
   an active marker's same-rooted CLEAN main (its open recovery window) —
   hooks/config are never a build side-effect (cycle-2 P1; cycle-3 B-2
   reconciled the message/docs with the operative rule). A
   cross-checkout bash overwrite of an EXISTING untracked hub file blocks
   exactly like the write/edit tool route — only genuinely NEW files are
   additive (cycle-3 A-2). Script-chain content is walked to a bounded
   budget; on budget exhaustion the gate fails closed ONLY when the walk
   already saw hub-main candidates (or the session shell is rooted in a
   DISORDERED hub main) — a >64-token hub-free fan-out of sourced helpers
   must not false-block (cycle-3 A-1).
   Block message states the single coherent rule: bash writes respect the same
   hub gate as the tools; only the session-start host env bypasses — a
   mid-command `export` cannot. The gate resolves redirect operands that the
   static walker CAN name; operands that are shell expansions (`> $OUT`,
   `> "$FILE"`, `> $(cmd)`, `~`/`~user` paths) stay literal and are NOT
   resolved (out of threat model — the walker has no shell state; see the
   classify-git.mjs docstring residual list). Mechanism boundary (post-#474
   review): the gate covers bash write PRIMITIVES — `>`/`>>`/`>&` redirects,
   `tee`, and python `open(…,"w"/"a")` — PLUS (since #625) the in-place
   overwrite VERBS that carry no primitive token (`sed -i`/`gsed -i`,
   `perl -pi`, `awk -i inplace`, the `cp`/`mv`/`install`/`rsync`/`ln`
   destination — a directory destination expands per-source to
   `dir/<basename(src)>` — `truncate`, `dd of=`, `sort -o` (long options match
   any UNAMBIGUOUS prefix, `--out=FILE` included), `sponge`,
   `ed`/`ex`/`vi`/`vim`/`nvi` (every file operand); a bundled `-t` (`cp -ft
   dir`, `install -Dt`); rsync operand options match unambiguous prefixes;
   and `sort -ro`/`-uo`). Long options are matched exactly OR by an
   UNAMBIGUOUS getopt_long abbreviation (`sed --in-pl` ≡ `--in-place`,
   `gawk --incl inplace` ≡ `--include inplace`), so an abbreviated in-place
   flag cannot slip the gate; and `cp`/`mv`/`install` require at least one
   SOURCE before a destination is surfaced (a single-operand `cp f` is a
   malformed no-op that writes nothing); and `\`+newline line continuations
   are deleted before the operand is read, so a continuation (with or without
   following indent) between a redirect/`tee` operator and its target cannot
   hide the target. An fd-prefixed OUTPUT redirect for ANY fd
   (`2>f`, `3>f`, `N>|f`) is a write candidate — the open truncates the file
   even when nothing is written through it; `N<f`/`N>&M`/`N>&-` are not.
   Still outside this mechanism's scope (documented residuals):
   verb-in-ARG fan-outs (`find -exec`, `xargs`), archive/member writers
   (`tar -x`, `unzip -o`, `patch`), directory-TREE copies whose per-file
   targets are not in the command string (`cp -R src/ dst/`), backtick
   command substitution (the `$( )` form IS walked), arbitrary interpreter
   writers (`node -e`, `ruby -e`, `php -r` — the #627 git-CONTENT gate above
   covers their git payloads; the WRITE-target rewrite class remains open,
   #663), a bare `rm` of a tracked file,
   an rsync option that takes a separate operand but is neither in the
   arity table nor an unambiguous prefix of an entry (and the same class for
   sort), rsync options whose operand is itself a WRITTEN file
   (`--log-file`, `--write-batch`, `--only-write-batch`, `--backup-dir`),
   `N>file` inside an interpreter pre-scan (`bash 2> f script.sh`), and
   path-identity indirection the gate cannot see pre-execution (a hardlink to
   a hub file, or a symlink the same command creates). Own-main UNTRACKED/NEW writes stay free (build/formatter/npm-install
   side effects on genuinely new files must not false-block); a TRACKED
   own-main write blocks clean OR disordered (#625 removed the #437 clean-hub
   residual — it let a compound `printf … >> MEMORY.md && git add && git
   commit && git push` through).
   NEW-file (nonexistent) targets and own-main untracked writes are NOT this
   gate's concern (see 3; the #436 collision-free carve-out semantics apply) —
   a CROSS-checkout overwrite of an EXISTING untracked hub file blocks (A-2,
   above).
3. **Bash-write warning (untracked WIP — still warn-only):** hub-targeted
   non-git bash writes whose target matches a WIP pattern emit the same banner
   with a `(via bash …)` note. Heuristic and conservative: `/tmp` scratch-ish
   targets are excluded (hub-equality), false-positive warnings are acceptable,
   false-blocks are not. Own-main untracked writes stay warn-only (#437 keeps
   this — the gate's tracked/existing-untracked freezes never cover a
   same-rooted session's own hub; only CROSS-checkout overwrites of existing
   untracked hub files block, A-2).
4. **Hub-hygiene inventory:** the session-start hub-discipline check (#73) now
   also lists untracked WIP files (`git status --porcelain=v1
   --untracked-files=all`, bounded — the per-file expansion runs only when
   untracked content exists, so a clean hub costs zero extra git calls),
   calling out `docs/plans/` and `migrations/` as the #347 amplifier pattern,
   plus a **throttled periodic re-scan** (once per 5 minutes — never
   per-command) that flags new untracked WIP mid-session. The #73 session-start
   banner also carries a routing nudge: the concrete `hub-worktree.sh <branch>`
   one-liner (plus a `salvage` hint when dirty-on-main — #2238/#435).

**Suppression:** all warnings are suppressed under the env hatch
(`AGENT_ALLOW_MAIN_EDITS=1`). Under the TTL escape marker (#207), the
**tool-call-time prompts** (write-gate and bash-write warnings, periodic
re-scan) are also suppressed (the marker bypass returns before they run), but
the **session-start inventory** still fires once (it layers on the #73
session-start banner, which fires under the marker). All warnings dedupe per
(surface, pattern, path) per session — the write-gate and bash surfaces keep
separate dedupe namespaces, and the inventory dedupes per path.

**Design deviations (documented):** the bash-write WARN heuristic resolves
write targets against the session cwd — `cd`-prefixed writes into the hub are
false-negatives on the WARN surface (a warning is cheap, a missed one is not
an incident); the #618/#621 bash GATE is a target-aware cd-resolving walker
with NO cheap pre-bail (a write-free command costs only the pure string walk;
`bash -c '…'` / sudo-tee / spawner-wrapped payloads are walked, never
pre-filtered away), and its same-vs-cross-checkout decision is SESSION-rooted
(a worktree/foreign session that `cd`s into a hub and writes is still a
cross-checkout write and blocks — review fold-in on the old command-site
comparison); a same-checkout shell's TRACKED write into its own main
blocks clean OR disordered (#625; own-main UNTRACKED/new writes stay free);
a failed hub-toplevel
cache resolution disables the warn surfaces for up to 30s (then retries —
never terminally); hub-equality is realpath-normalized (M4's blocks use fresh
per-call resolution and are unaffected); the python `open()`
regex only fires when a python interpreter token is present (bare, versioned
like `python3.11`, or path-qualified like `venv/bin/python`; commands over
64KB skip the scan) — prose that mixes an unquoted python token with a quoted
`open(…,"w")` can still false-positive (warn-only, deduped); heredoc bodies
are scanned literally, so a body line containing `> <wip-path>` can emit a
spurious banner (P3 — warn-only, deduped per path; the real redirect target
still warns); an intra-repo symlink alias
(e.g. `docs-link → docs/plans`) can miss the pattern on the un-realpath'd
spelling (warn-only false-negative — the perf constraint keeps the pure pattern
filter first).

**Why warning, not block (untracked WIP):** the write/edit block for
main-checkout edits is a deliberate permanent gate in every guarded repo
(agent-infra included since #615); the
untracked-WIP patterns are a hygiene signal, and an agent may legitimately
need a scratch file briefly. The warning surfaces the violation at write time
so the agent moves the work to a worktree
(`bash scripts/checkout-hygiene/hub-worktree.sh <branch>`) before it becomes
the next M4 freeze. The #437 tracked-write gate is the exception that DOES
block: writing an index-tracked hub file via bash (disordered hub, or clean
own-hub since #625) destroys the very dirty delta the freeze protects — and is the mechanism that
created the 2026-08-31 tortoise dirt — and since #618/#621 a DELIBERATE
cross-checkout tracked write into ANY hub main (worktree/foreign session) is
blocked regardless of hub state, matching the write/edit tool's target-aware
gate. Its tracked-ness test is exact
(`git ls-files`), so the heuristic deviations below (false-positives on
heredoc bodies, cd-prefix false-negatives, symlink aliases) apply to the
WARN surface only — the block fires only on a real tracked hub file.

## Deliberate-obfuscation residual tier (out of threat model) (#351)

**The threat-model boundary, stated once:** the guard defends against
**ACCIDENTAL collision** between parallel agents — a session that runs an
ordinary `git reset --hard`, `git checkout -b`, or `git -C <hub> …` in the
shared main checkout, or an ungated write into it. It does **NOT** defend
against **adversarial shell** — an actor deliberately obfuscating git
invocations to evade classification. A deliberate-bypass actor is the same
threat class as a human editing `.git/` internals by hand; **no tool gate can
fully close it** (only policy + worktree isolation can). The residual tier is
documented here (issue #351) so the boundary is explicit and future work does
not rediscover it as a "hole". The guard rejects the ACCIDENTAL variants of
every class below — the two-way reverse-pointer validation + porcelain
cross-check close the map-poisoning variants (Residual 2), the walker's
command-position `$VAR` resolution closes plain-`${VAR}` name-splitting
(round-11), and the semantic core closes the accidental spelling family; the
deliberate variants remain documented residual.

### Residual 1 — Bash-expansion name-splitting (parameter expansions)

A git command word synthesized from a parameter expansion in command
position:

```bash
G=git; ${G:0:3} -C <hub> reset --hard            # ${G:0:3} → "git" — classified "non-git", runs
X=foocmd; ${X//foo/git} -C <hub> reset --hard    # substitution → "git"
```

Probe-verified (2026-08, #351): both verdict `non-git` — the walker's
command-position `$VAR` resolution (round-11) only handles plain `${VAR}` /
`$VAR`, so no invocation is seen and the command executes. Closing this
requires a **full bash expansion evaluator** (offset/length slices, `//` / `#`
/ `%` substitutions with glob semantics, arithmetic, nesting, env-var
dependence) — and every closure reveals a sibling, so the family is
open-ended. **Decision: deferred** — see the hardening table below.

> **Already-closed sibling (documented for accuracy):** quote-concat
> name-splitting (`G='g'it`, `'g'it -C … reset --hard`) is NOT open — the
> tokenizer strips quotes, so `'g'it` tokens as `git`, and the round-11
> assignment var-hop (`G='g'it; $G …`) resolves to a git word. The
> same-segment PREFIX spelling (`G='g'it $G …`) is also not a hole: bash
> expands `$G` pre-assignment (VULN-001 semantics — unset G makes it a
> no-op), and when G is pre-set in a prior segment, round-11 resolves it and
> blocks (probe-verified, #351). Only parameter-expansion operations remain in
> this class.

### Residual 2 — direct `.git/worktrees/` internals writes (map poisoning)

An agent writing the reverse-pointer files + a crafted back-referencing
gitfile can poison the worktree map:

```bash
mkdir -p <hub>/.git/worktrees/evil && printf '<path>/.git\n' > <hub>/.git/worktrees/evil/gitdir
printf 'gitdir: <hub>/.git/worktrees/evil\n' > <path>/.git
```

The **two-way back-reference validation** (VULN-003 closure) rejects the
accidental variants — a crafted gitdir whose target has no back-referencing
gitfile, a substring-matching gitfile, a stale admin dir. A **determined
writer defeats it**: a fully-consistent pair passes two-way AND `git worktree
list` (git derives its view from the same reverse-pointer files —
probe-verified), and the fake admin dir still fails `git rev-parse` (it is not
a complete git directory: no `commondir`/`HEAD`), so the poison is inert
without a full admin-dir craft. #351 added the **porcelain cross-check**
(hardening table below) as defense-in-depth: partial crafts whose
reverse-pointer content git cannot resolve from its own frame (relative
content, dangling gitfile) are now rejected at map build. Fully-consistent
crafts remain documented residual — a deliberate-bypass actor.

### Residual 3 — the open-ended grammar-spelling family

Every closure (redirect / fd / spawner / flag / substitution spelling)
reveals a sibling — #347's 24 code-review rounds closed spellings in waves
(`2>&1` → `<&0` → `< /dev/null` → `bash <(...)`; `-C` → `--cd` → `-Cfoo` →
`--git-dir=…`; `checkout -B` → `switch -C` → `-Bmain` →
`--force-create=…` → `-bfoo`; …). The family is open-ended by construction: a
grammar over shell spelling has infinitely many members. The guard's
mitigation is the **semantic core** — per-invocation effective-target
resolution, shared-ref re-classification, fail-closed defaults for
unresolvable forms — not spelling enumeration.

### Hardening decision (#351)

| Item | Decision | Rationale |
|---|---|---|
| `git worktree list` porcelain cross-check (P2) | **IMPLEMENTED** | One `execSync` per map build — and the map builds per classified git invocation while the hub has linked worktrees (a few ms each; the plan's sessionCwd-keyed cache, follow-up #7, is the future mitigation — a TTL cache was rejected here because it would open a false-block window for a worktree added within the TTL). Parsed with `--porcelain -z` (git ≥ 2.36 — the `-z` option for `git worktree list` landed in 2.36.0; older git → skip + one-time warn). Conservative on disagreement (entry rejected → block). Degrades to skip (two-way validation only) when `git worktree list` cannot run — surfaced by a one-time warn. Probe-verified it cannot false-block legitimate worktrees (git's porcelain lists every entry the two-way check accepts; paths with trailing spaces or embedded newlines preserved by the NUL parse). New regression pins X1–X6/X5b/X6b in `test.mjs`. |
| Bash-expansion evaluator for command-position `${…}` / `${var//…}` (P2) | **DEFERRED** | A full evaluator is a large lift; a bounded one for the documented spellings is either trivially bypassable (the family is open-ended — `${G:0:3}` → `${G::3}` → `${G#g}` → …) or risks false-positives on legitimate expansions (`${HOME}`, `${PWD}`, `${SHA:0:7}` must keep passing — probe-verified today). Cost/benefit vs. the accidental-collision threat model: an accidental actor never writes `${G:0:3}`; closing it adds walker complexity to a 24-round-reviewed, fully-pinned regression suite for an out-of-model adversary. Revisit if the threat model ever includes adversarial shell. |

Cross-references: plan `docs/plans/2026-08-27-issue-347-m4-worktree-freeze.md`
§5a (the residual tier), issue #351 (this decision), #347 / PR #348 (the
review rounds that surfaced the family).

## Environment variables

| Variable | Purpose | Required for |
|---|---|---|
| `AGENT_ALLOW_MAIN_EDITS=1` | Deliberate solo-session bypass — disables the guard for the whole session. Must be set before the session starts; cannot be set on a running process. ⚠️ **Does NOT propagate to task children** (#617/#623): sub-agents inherit the parent's env via the `...process.env` spread in `builtin-tools` `subAgentEnv`, but since #623 the hatch is **default-stripped** — both AGENT/ELDATO_ALLOW_MAIN_EDITS are deleted from the child env after the spread, so a hatched controller dispatches an **UNHATCHED** fleet (M4/M2/M3 apply to task sub-agents exactly as to an unhatched controller). A controller that deliberately needs an in-main task child must pass the per-dispatch `allow_main_edits: true` opt-in on the `task` call (and the equivalent `allow_main_edits` param on the legacy `subagent` tool) — the child then inherits only a hatch the controller env itself carries. An ambient launcher hatch can therefore never silently hatch a fleet. | — |
| `ELDATO_ALLOW_MAIN_EDITS=1` | Legacy alias of the above (checked second) — same default-strip + opt-in semantics for task children (#623). | — |

The env hatch is fixed at session start. For a **mid-session** escalation on a
running, guard-blocked session, use the escape marker below.

## Escape hatches — EMERGENCY-ONLY, every one carries a consequence (#1484)

All three escapes are for **solo sessions or hub recovery only** — they are
NOT routine options, and using any of them while the hub is disordered makes
**you** the next incident writeup:

| Escape | How | Consequence (what you are opting into) |
|---|---|---|
| env hatch | `AGENT_ALLOW_MAIN_EDITS=1` at session start | Full guard bypass of the BLOCKING gates — M2/M3/M4 off (M1 deviation detection stays active, warn-only). Nothing automated exempts agent-infra main dirt anymore (#615/#619 — hub-state-check now includes agent-infra + the sibling hub repos tortoise/premise-labs/DMeer/eldato; sibling sessions in the hub are unprotected and will be disrupted). Prefer `hub-worktree.sh <branch>` instead. |
| TTL escape marker (#207) | `touch ~/.pi/agent/.allow-main-edits  # reason` as its own bash call | Bypasses M2/M3 for 15 min — but **M4 stays ACTIVE** (D3): in an off-main/dirty hub you can only run sanctioned recovery ops, never resume feature work. The audit log records your session id. |
| script backdoor | ~~write /tmp/x.sh + bash /tmp/x.sh~~ | **CLOSED (#1484)** — git-bearing scripts are gated by the M4 allowlist. **#627:** the non-shell sibling (`python -c`, `node -e`, `ruby -e`, `perl -e`, `php -r`, `pwsh -Command`) is closed for INLINE payloads too; residuals: `python -m`/bare-stdin/pipe payloads, dynamic string construction, and file/shebang payloads (`python x.py`, `./x.py`). Env hatch / TTL marker still bypass it. |
| terminal | a human runs `cd <repo> && git checkout main && git pull --ff-only` | THE sanctioned recovery (#206). Terminals are never intercepted; this is how a stranded hub gets un-stranded. |

Rule of thumb: **if you are not recovering the hub or working alone, you
should be in a worktree — `hub-worktree.sh <branch>` makes it one command.**

## The escape marker — deliberate mid-session escalation (#207)

A guard-blocked-but-functional session (alive, issuing tool calls, stranded in
the shared main checkout) opens a **sanctioned, bounded, audited,
session-scoped** window by touching a marker file. This upgrades the only
mid-session escape that existed before — an undocumented script-execution
backdoor (see below) — into a bounded hatch.

### The one-touch command

Run this as **its own bash tool call** inside a guard-loaded session:

```bash
touch ~/.pi/agent/.allow-main-edits  # recovery: <reason>
```

- The trailing `# recovery: <reason>` comment is optional but recommended —
  it is extracted into the marker content and the audit record.
- **The touch must be its own command.** A combined
  `touch ... && git checkout main` in ONE bash call does NOT work: the guard
  classifies the whole command before any stamping happens, so the git part
  is blocked and the touch never runs. Put the recovery git op in the
  **FOLLOW-UP** call:

```bash
# call 1 (allowed — opens the window)
touch ~/.pi/agent/.allow-main-edits  # recovery: stranded main
# call 2 (now allowed — the recovery op)
git checkout main && git pull --ff-only
```

### 15-minute expiry

The window is **mtime-based**: a marker is active only while its mtime is
younger than 15 minutes (`ALLOW_MAIN_EDITS_MARKER_TTL_MS` — a fixed constant,
deliberately NOT env-overridable). The guard re-reads the marker **on every
tool call** — it is never cached. Re-running the same `touch` refreshes the
window (mtime update; the guard re-stamps the content). A marker exactly
15 minutes old is expired — the same recovery op is blocked again until you
re-touch.

### Session scoping + stamping contract

The marker is **per-process-session-scoped**, not machine-wide:

- Only the guard's tool_call handler writes the stamp
  `{"session_id", "reason", "ts"}` — it stamps when it observes an allowed
  `touch` of the marker path, BEFORE allowing the command. `touch` then
  refreshes mtime and preserves the content (no ordering race).
- **The stamp runs in EVERY session state (#620)** — the env hatch
  (`AGENT_ALLOW_MAIN_EDITS=1`) cannot mint an un-stamped, un-audited marker:
  a bash `touch` of the marker path is guard-stamped + audited even under the
  hatch. Writing the marker file via the write/edit tool is blocked in every
  session state (hatch / active-marker / worktree / agent-infra) — the audited
  bash touch is the only route the GUARD stamps.
- **Trust-model limit:** the guard stamps only what it OBSERVES as a bare
  `touch`. An out-of-band write (a `printf`/`echo`/redirect in a tool call or
  a human terminal that puts stamped-SHAPE JSON on the path) is not
  distinguishable from a legitimately-stamped file and carries no `gate_bypass`
  audit event — this residual predates #620 and is outside the guard's audit
  surface; unparseable out-of-band content is inert → blocked (fail-safe).
- The window is active ⟺ mtime fresh AND content parses AND
  `session_id` matches the current session's id (`PI_SESSION_ID`, with the
  extension-context session manager as fallback).
- **A human terminal `touch` produces an unscoped empty file → inert →
  blocked.** The touch must be a bash tool call inside a guard-loaded session
  for the guard to stamp it.
- **Headless / print-mode sessions with a null session id cannot escalate**
  (fail-safe block).

### Delegation caveat

The marker is per-process-session-scoped — a subagent does **NOT** inherit the
parent's `PI_SESSION_ID` (pi only writes it into bash-tool child envs; the
extension-host env of a subagent carries the subagent's OWN id). **Recovery
must run in the session that created the marker; delegating the touch to a
subagent re-scopes the marker to the subagent's id or fails-closed** (the
parent's read-side match fails → the parent stays blocked). A subagent
re-touching an active marker RE-SCOPES it to the subagent's id, revoking the
parent's window.

### One window, all repos

The marker is repo-agnostic: one active window covers every repo the session
touches (the hub and any worktrees). Accepted and documented — no per-repo
scoping.

### Audit location

Every stamp writes one JSONL line to `~/.pi/agent/audit/gate-events.jsonl`
via the shared audit facility:

```json
{"ts":"…","event":"gate_bypass","extension":"main-worktree-guard","reason":"main_edits_marker","session_id":"…","marker_path":"…","ttl_ms":900000,"expires_at":"…","marker_content":"{\"session_id\":…,\"reason\":…,\"ts\":…}"}
```

The marker content is logged, so even a bare `touch` (no reason comment)
records a timestamped creation with the session id. The session itself also
prints a one-line log at stamp time:

```
[main-worktree-guard] 🔓 Escape marker active for session <id> until <expires_at> (reason: <reason>)
```

### Fail-safe semantics

Absent / unreadable / expired / unparseable / unscoped / mismatched /
**symlinked** (the pinned `realpathSync(path) !== resolve(path)` check rejects
any symlink indirection) marker → treated as absent → **blocked**. A
`printf`/`echo`/redirect that writes the marker path is **out-of-contract**:
it clobbers the guard's stamp, the marker becomes unscoped, and the guard
blocks. The env hatch is unchanged — the marker is an additional OR branch,
never a replacement.

## The script backdoor — closed since #1484 (shell + #627 interpreters)

**CLOSED since #1484.** The old escape — `write /tmp/recover.sh` (outside
project paths classify ALLOW) + `bash /tmp/recover.sh` (classifies
`allow-non-git`) — executed arbitrary git unblocked and was the most likely
vector for the 2026-08-18 hub incident. Today, shell-script execution in the
hub is gated: `extractScriptPath` + `scriptGitVerdict` in `classify-git.mjs`
read the script and gate its git content with the SAME M4 recovery allowlist.
A script containing `git commit`, `git checkout -b`, a foreign push, etc. is
blocked with a reason naming the closure; recovery scripts (`hub-worktree.sh`:
`fetch` + `worktree add`) and read-only git in scripts pass. Inline `bash -c
'…'` is gated as the caller's own command by the normal classifier.

**#627 extends the closure to non-shell code interpreters (inline payloads).**
The same payload escaped via `python3 -c "import subprocess; subprocess.run(['git',
'reset','--hard'])"` (array form — no `git` token at a shell command position).
`extractCodePayload` resolves the INLINE payload and `codePayloadGitVerdict`
applies the SAME allowlist + per-invocation target resolution as the shell
surface (see the design note above for the sink gate + command-position anchor).
Three boundaries are deliberate:
- **Sink + command-position requirement** — a candidate is only emitted when the
  payload contains a process-spawn primitive AND a `git …` command in command
  position, so inert literals/prose/data stay allowed (no false-blocks).
- **Worktree parity** — a worktree-targeted code git op (`cd <wt> && python3
  -c "… git commit …"`, or a `cwd=<wt>` kwarg) is exempt exactly like its shell
  twin (#347).
- **Inline only** — file/shebang/module/stdin payloads (`python3 /tmp/x.py`,
  `./x.py`) are NOT content-read: doing so false-blocks legitimate scripts that
  run git in temp repos (and the shell surface has the same semantics).
Residuals (documented, not gated → tracked follow-ups): `python -m <module>`,
bare stdin/pipe/heredoc payloads, file/shebang payloads, dynamic string
construction, and pathological obfuscation (the open-ended family shared with
the shell residual tier).

## What it does NOT fix

**Hung processes.** A hung process cannot issue any tool call, so it can never
touch a marker. The hung-process class currently has **no owner** — #203 is
closed with a different scope (auto-sync non-main-branch recovery, not process
supervision). A process-supervision follow-up (new issue) is required. The
marker fixes **guard-blocked** sessions only.

## Tests

| Suite | Command | Covers |
|---|---|---|
| `test.mjs` | `node extensions/main-worktree-guard/test.mjs` | `classify-git.mjs` + `branch-ownership.mjs` decision surfaces (pure functions) |
| `test-module-load.mjs` | `node extensions/main-worktree-guard/test-module-load.mjs` | **the `index.ts` LOAD path** — the wiring `test.mjs` cannot see |
| `test-discard-gate.mjs` | `node extensions/main-worktree-guard/test-discard-gate.mjs` | **the M5 discard gate (#709)** — pure extraction/effect (Part A) + the REAL `index.ts` handler driven against a hermetically built hub + linked worktree (Part B): dirty/clean targets, staged-only, untracked-only, hub-targeted from a worktree session, prefix spellings, quote-split verbs, bare-path/`-f <path>` ref-vs-path, magic pathspecs, numeric stages, `rm`/`read-tree`/`apply -R [-R3]`/`checkout -p`/`checkout --ours`/`checkout-index`, script + `eval` + heredoc (plain and punctuated delimiter) + list-form-heredoc + filtered head + piped-script + backtick + `$( )` + alias + ANSI-C + `$VAR` + verb-indirection + xargs-feeder + here-string + process-substitution + opaque `-c` + `--work-tree` bypass closures, fail-closed forms, false-positive guards (heredoc data, arithmetic `<<`, mid-line/escaped-whitespace comments, substitution-in-data, index-only `rm`/`restore`/`apply -R`, report-only `apply -R`, `checkout-index --prefix`/`-a`, cd chains, conflict resolution, phantom heredocs), and both escape hatches |

`test-module-load.mjs` exists because of a real regression (#744): #697 added a
rename-destructuring assignment (`extractCodePayload: _extractCodePayload, …`)
whose five `_`-prefixed targets were declared NOWHERE. An assignment to an
undeclared identifier is a `ReferenceError` in ESM (always strict mode); it
threw inside the guarded `await import("./classify-git.mjs")` block and the
catch logged `bash git guard DISABLED`. The assignment runs left-to-right, so
the 21 targets listed before `_extractCodePayload` were already bound to the
real exports — the legacy classifier, the #73 coordinated-delete arm and the
script-content gate kept working — while every binding at or after it kept its
fail-safe default, so **those later gates silently degraded in every session**
— while `test.mjs`
stayed green, because it imports `classify-git.mjs` directly (and its comments
assert that `index.ts` is not importable in tests). TypeScript flags the bug
(`TS2552: Cannot find name '_extractCodePayload'`, and the same for its four
siblings), but the repo has no root `tsconfig.json`, so the CI typecheck job
self-skips.

The suite has two parts, both zero-dependency (no `node_modules`, so it runs in
CI):

- **Part A — static scope tripwire.** Parses the `({ … } = …)` assignment
  patterns out of `index.ts` and asserts every target is a declared binding
  somewhere in the file. Catches the exact bug class anywhere.
- **Part B — real module load** (Node ≥ 22.13). Imports the REAL `index.ts`
  through `module-load-hooks.mjs`, which type-strips the TS sources and stubs
  `@earendil-works/pi-coding-agent` — the same shapes pi's jiti loader
  produces. It then drives the registered `tool_call` handler against a
  hermetic MAIN checkout and asserts BEHAVIOR: the #627 inline-interpreter gate
  blocks an argv-form git payload the legacy string classifier misses, the
  disordered-hub write gate blocks a tracked overwrite, and the #628 new-file
  cap blocks write #26. Those paths read the very bindings that stay stubbed
  when the import degrades, so the suite is red on the pre-#744 module.
  (The `#628` boundary assertion is the one part of this suite with a known
  flake — a transient block inside the `1..25` carve-out window shifts it; the
  failure message says so when that happens, and it is tracked as #768.)

**CI wiring.** Per-PR: the `verify` job in `ci.yml` runs it as a named step
(added by #744) — not in the pinned `ci` job, whose `test-command` value
(`scripts/check-pi-pin-lockstep.mjs`, guard (j)) pins to exactly this one
accumulator invocation. Post-merge: the
`extensions/*/test*.mjs` glob in `ci-main.yml` (`push` → main) picks it up
automatically, so no explicit line is needed there — an explicit one would
double-run it. Both are plain zero-dep `node` invocations, neither needs
`npm ci`.

## Manual verification checklist

Claims in this README are kept minimal and implementation-literal. From the
shared main checkout of a project with the guard active:

1. `git checkout main` → **blocked** (guard reason shown) when the hub is
   clean; **allowed** (M4 sanctioned recovery) when the hub is off-main/dirty.
2. `touch ~/.pi/agent/.allow-main-edits  # recovery` as its **OWN** bash
   call → allowed; the session logs the 🔓 escape-marker line (this works
   since #1484 — the stamp-ordering fix; before that the touch was swallowed
   by the allow-non-git early return and the marker was inert).
3. `git checkout main && git pull --ff-only` in the **FOLLOW-UP** call →
   succeeds.
4. `cat ~/.pi/agent/.allow-main-edits` → shows `session_id` + `reason` + `ts`.
5. `tail ~/.pi/agent/audit/gate-events.jsonl` → a `gate_bypass` /
   `main_edits_marker` line with session_id + marker content + expires_at.
6. Wait 15+ minutes → the same recovery op is **blocked again**.
7. Re-`touch` → immediately allowed again (refresh).
8. **M4 matrix (disordered hub):** with the hub on a non-main branch or
   dirty — `git commit` / `git checkout -b x` / `git push origin main`
   (foreign) / edit tool → **blocked**; `git checkout main`, `git pull
   --ff-only`, `git fetch`, `git status`, `git worktree add`, `git push
   origin <checked-out-branch>` → **allowed**. With the marker active,
   recovery ops stay allowed and feature ops stay blocked (D3); with
   `AGENT_ALLOW_MAIN_EDITS=1` everything is allowed (env = full bypass).
9. **Backdoor closure:** in the hub, `bash /tmp/recover.sh` where the script
   contains `git commit` → **blocked** with the closure reason; a script with
   only `fetch`/`worktree add`/`status` → runs.
10. `bash scripts/checkout-hygiene/hub-state-check.sh --repo <hub>` → exit 0
    on main+clean, exit 1 + recovery command on off-main/dirty.
11. **#350 WIP hygiene:** from the hub main checkout — an OVERWRITE of an
    existing/tracked file (`cat > docs/plans/wip.md` in a DISORDERED hub —
    the #437 tracked-write gate — or `write docs/plans/wip.md` in any hub
    state) → **blocked**; the write/edit block reason names the `docs/plans/`
    pattern on the main+clean gate (#615 removed the agent-infra warn-only
    exemption). A NEW untracked file in a disordered hub passes the #436
    collision-free new-file carve-out (hub stays dirty — #628 now warns at
    write time for every new hub file, escalates past the budget, and blocks
    past the cap); a
    WORKTREE session writing `docs/plans/wip.md` into the hub via an absolute
    path → `HUB WIP — PUT IT IN A WORKTREE` warning, command still runs
    (never blocked); `echo x > /tmp/foo.tmp` → no warning (outside the hub);
    the session-start banner lists untracked
    `docs/plans/`/`migrations/`/scratch files when present.
