# main-worktree-guard — Pi extension

Guards the **SHARED main checkout** of a project against two classes of
collision between parallel agents:

1. **write/edit tool calls** targeting the main checkout (parallel agents
   editing main could silently overwrite each other's uncommitted changes),
   and
2. **destructive/state-changing git commands** via the bash tool — `git reset
   --hard`, branch checkout/switch, pull/merge/rebase, clean, force-push,
   `branch -D`, restore, stash pop (incident 2026-08-06: a `git reset --hard
   origin/main` mid-PR yanked the working tree out from under another agent).

**Worktrees are ISOLATED** — none of this applies inside a linked worktree.
The guard blocks only in the shared main checkout, where branch-state changes
and hard resets silently destroy other agents' work.

There is **NO auto-bypass**: the guard blocks every time, so a rogue or
parallel agent cannot retry its way past it. Escapes are deliberate and
documented (env hatch below, escape marker below).

**Degradation (fail-safe):** if `classify-git.mjs` fails to load (jiti edge
case), the bash guard degrades to warn-only while the write/edit guard stays
fully enforced. The escape-marker check degrades to **inactive** (block) on
any failure — a failed import or stamp never silently allows.

## M4 — hub-state gate: the hub stays on `main` + clean (#1484)

The **hub** (the shared main checkout of a non-infra repo) has exactly two
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
| `git worktree add/list/prune/remove` | `git push -f` / `--delete` |
| `git push origin <currently-checked-out-branch>` (WIP preservation) | write/edit tools in the hub |
| `touch ~/.pi/agent/.allow-main-edits` (escape marker) | |

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

**Scope (#347):** M4 fires only when the session cwd IS the hub's main checkout
and the hub is off-main/dirty. Worktree sessions are exempt (they are isolated
by construction); agent-infra is exempt (#99 — in-main feature work is its
norm; its hub-discipline check is downgraded to a dirty-warn). **Worktree-
TARGETED git ops are exempt per-invocation:** M4 resolves each git invocation's
EFFECTIVE target (cd-chains, `-C`, `GIT_DIR`/`--git-dir`, subshell/pipe/`&`
scoping, `git worktree list` membership derived from the worktrees' reverse-
pointer admin dirs — porcelain has no gitdir column — + cwd containment,
realpath-normalized) and exempts worktree-targeted invocations — a hub-rooted
session that `cd`s into a worktree is no longer frozen by hub disorder
(2026-08-27 tortoise incident class). **Shared-ref verbs are NOT exempt (round-3 inverted allowlist):** worktrees
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
block. **Interpreter-inline gating:** `bash -c 'git …'`/`sh -c`/`zsh -c`/
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
from the hub cwd, and crafted reverse-pointer files — closed by two-way
back-reference validation plus, since #351, a `git worktree list --porcelain`
cross-check (see the [deliberate-obfuscation residual
tier](#deliberate-obfuscation-residual-tier-out-of-threat-model-351); an agent
that writes `.git/worktrees/` internals directly is a deliberate-bypass actor,
same class as the documented `GIT_INDEX_FILE` limitation). The write/edit M4 block is target-aware (hub-equality): only
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

**The nightly hub-state check (`hub-state-check.sh`, launchd every 6h)** is the
visibility layer: it fails loudly with the recovery command and opens one
deduped GitHub issue per repo when the hub goes bad. Day 0 validation: the
live `pr1467` hub fails the check — that is the point.

### What this gate is NOT

- **Not a worktree blocker:** `git worktree add/list/prune` stay allowed.
- **Not a read blocker:** `git status`, `git log`, `git diff`, `git fetch`,
  `git show`, etc. remain available.
- **Not an agent-infra gate:** the infra repo's in-main feature work (#99) is
  untouched.
- **Not a terminal gate:** humans in a terminal can always run the one-liner.

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
| `git worktree list` porcelain cross-check (P2) | **IMPLEMENTED** | One `execSync` per map build — and the map builds per classified git invocation while the hub has linked worktrees (a few ms each; the plan's sessionCwd-keyed cache, follow-up #7, is the future mitigation — a TTL cache was rejected here because it would open a false-block window for a worktree added within the TTL). Conservative on disagreement (entry rejected → block). Degrades to skip (two-way validation only) when `git worktree list` cannot run — incl. git < 2.16 — surfaced by a one-time warn; probe-verified it cannot false-block legitimate worktrees (git's porcelain lists every entry the two-way check accepts; path whitespace preserved). New regression pins X1–X4 in `test.mjs`. |
| Bash-expansion evaluator for command-position `${…}` / `${var//…}` (P2) | **DEFERRED** | A full evaluator is a large lift; a bounded one for the documented spellings is either trivially bypassable (the family is open-ended — `${G:0:3}` → `${G::3}` → `${G#g}` → …) or risks false-positives on legitimate expansions (`${HOME}`, `${PWD}`, `${SHA:0:7}` must keep passing — probe-verified today). Cost/benefit vs. the accidental-collision threat model: an accidental actor never writes `${G:0:3}`; closing it adds walker complexity to a 24-round-reviewed, fully-pinned regression suite for an out-of-model adversary. Revisit if the threat model ever includes adversarial shell. |

Cross-references: plan `docs/plans/2026-08-27-issue-347-m4-worktree-freeze.md`
§5a (the residual tier), issue #351 (this decision), #347 / PR #348 (the
review rounds that surfaced the family).

## Environment variables

| Variable | Purpose | Required for |
|---|---|---|
| `AGENT_ALLOW_MAIN_EDITS=1` | Deliberate solo-session bypass — disables the guard for the whole session. Must be set before the session starts; cannot be set on a running process. | — |
| `ELDATO_ALLOW_MAIN_EDITS=1` | Legacy alias of the above (checked second). | — |

The env hatch is fixed at session start. For a **mid-session** escalation on a
running, guard-blocked session, use the escape marker below.

## Escape hatches — EMERGENCY-ONLY, every one carries a consequence (#1484)

All three escapes are for **solo sessions or hub recovery only** — they are
NOT routine options, and using any of them while the hub is disordered makes
**you** the next incident writeup:

| Escape | How | Consequence (what you are opting into) |
|---|---|---|
| env hatch | `AGENT_ALLOW_MAIN_EDITS=1` at session start | Full guard bypass — M1/M2/M3/M4 all off. The nightly `hub-state-check` will FLAG the hub and open a GitHub issue; sibling sessions in the hub are unprotected and will be disrupted. Prefer `hub-worktree.sh <branch>` instead. |
| TTL escape marker (#207) | `touch ~/.pi/agent/.allow-main-edits  # reason` as its own bash call | Bypasses M2/M3 for 15 min — but **M4 stays ACTIVE** (D3): in an off-main/dirty hub you can only run sanctioned recovery ops, never resume feature work. The audit log records your session id. |
| script backdoor | ~~write /tmp/x.sh + bash /tmp/x.sh~~ | **CLOSED (#1484)** — git-bearing scripts are gated by the M4 allowlist. It was the most likely vector for the 2026-08-18 incident; it no longer exists. |
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

## The script backdoor — closed since #1484

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

## What it does NOT fix

**Hung processes.** A hung process cannot issue any tool call, so it can never
touch a marker. The hung-process class currently has **no owner** — #203 is
closed with a different scope (auto-sync non-main-branch recovery, not process
supervision). A process-supervision follow-up (new issue) is required. The
marker fixes **guard-blocked** sessions only.

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
