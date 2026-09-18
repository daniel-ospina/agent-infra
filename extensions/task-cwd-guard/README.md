# task-cwd-guard

Refuses a `task` dispatch whose resolved spawn directory is a **shared main
checkout**, and names the worktree remedy. Issue: [#1240].

## The problem

pi's `task` tool spawns the child in the **parent's cwd** unless the caller passes
`cwd` (#1071). Sessions root in repo checkouts, so a child dispatched without an
explicit `cwd` lands in a *shared main checkout* — where every branch move is
unsafe and one lane's unpushed commit makes the guard gate git writes for every
session rooted there. Measured on the tortoise hub (2026-09-18): 63 processes,
24 live pi sessions, ~124 `task` dispatches/hour inheriting the hub. The hub is
an **attractor**: sessions start there, children inherit there, and the
population regrows faster than it can be cleared.

## What it does

One `tool_call` hook, scoped to the `task` tool only:

1. Resolve the child's target directory — the tool's `cwd` argument if supplied,
   else the parent's cwd — with #1071 parity (`trim → resolve → realpath`).
2. Classify it structurally with git (`git rev-parse --git-dir` vs
   `--git-common-dir`, both realpath'd):
   * **main checkout** — the two name the same directory (`<top>/.git`);
   * **linked worktree** — `--git-dir` is `<common>/worktrees/<name>`, a
     different realpath;
   * **non-repo** — git says so, or git could not run.
3. `main` → refuse (default), naming the checkout, the source of the target
   (`cwd` argument vs inherited), and the exact worktree remedy. Everything else
   passes untouched.

## Posture

| `TASK_CWD_GUARD` | behaviour |
|---|---|
| unset / `""` / `1` / `true` / anything unrecognized | **block** (the shipped default) |
| `warn` | `ctx.ui.notify(..., "warning")` + stderr, allow |
| `0` / `false` / `no` / `off` | disabled (and does not even spawn git) |

Unknown values stay *enforcing* on purpose: an operator typo must not silently
disable the gate.

## Why no auto-created per-child worktree

The issue prefers "default-to-per-child-worktree … where possible". It is not
possible here without introducing a worse failure mode, for two reasons:

1. **Volume.** At the measured ~124 dispatches/hour, minting a worktree per
   child mints ~124 admin dirs/hour (plus their trees). The existing reapers
   cannot keep up, and the hub is replaced by a worktree farm.
2. **A detached-HEAD worktree is a silent-work-loss class.** The only
   name-free worktree form is `git worktree add --detach`; commits made on a
   detached HEAD become unreachable the moment the worktree is reaped. Silent
   destruction of work is P0 in this repo — "off by default, reversible" is the
   only admission path for an automatic side effect, and this is neither. A
   named branch instead requires a naming decision the guard cannot make.

The common case still needs no caller change **where it is safe**: a parent
already in a linked worktree passes it straight through (the child inherits the
worktree), and a non-repo target is allowed. Only the shared-main case is
refused, and its message carries the one-command remedy.

## Scope

`task` only. The `subagent` tool has the same failure mode but a different input
shape (per-item `cwd` inside `tasks`/`chain` arrays); it is deliberately out of
scope here and tracked separately. A `bash`/`read`/… tool call is untouched.

## False positives

Fail-open on unknowns is deliberate. A non-repo target, a missing `git`, and an
unresolvable path all ALLOW: the gate's failure mode is over-block (friction),
not a false PASS on something dangerous, and a child in `/tmp` or a fresh
directory has no shared branch state to damage. A child targeting a directory
that does not exist is reported asynchronously by the spawn itself (#1071's
`taskCwdRefusal`) — this gate must not become a second, differently-worded
refusal for that case.

The structural comparison has no path-substring false negative: a main checkout
whose own path contains a `worktrees` segment is still classified `main` (the
historical #618/#621 defect of the substring test). Conversely, a worktree
*nested inside* the main checkout (`.worktrees/<name>`) is correctly classified
`worktree` — pinned by `test-cwd-guard.mjs` B5/B6, and mutation-verified.

## Tests

```bash
node extensions/task-cwd-guard/test-cwd-guard.mjs
```

77 assertions, both directions, with real git fixtures: shared main → blocked;
nested linked worktree → allowed; non-repo → allowed; non-`task` tool untouched.

[#1240]: https://github.com/daniel-ospina/agent-infra/issues/1240
