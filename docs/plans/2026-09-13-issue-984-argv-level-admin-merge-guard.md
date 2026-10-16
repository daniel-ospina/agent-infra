# Plan — #984: argv-level admin-merge enforcement (`gh` shim)

**Issue:** #984 · **Branch:** the #984 branch · **Scoping:** issue #984 comment (`<!-- issue-scoping: v5.1 … -->`)

## Problem, in one line

The merge gate answers a **shell** question with **string** rules, and seven adversarial
rounds each closed one splice and found the next — because resolving `$VAR`/`$(…)`
requires *evaluating a shell*, which a gate must not do.

## The load-bearing finding

`docs/extensions.md` §`tool_call`: **`event.input` is mutable and mutations affect real
execution** (*"Mutate it in place to patch tool arguments before execution"*). So the
extension can put a `gh` shim ahead of the real `gh` on `PATH` for **every** bash call.
When the shim runs, bash has finished: the splice is already the literal `--admin`. That
converts "enforce at argv level" from an aspiration into a wiring change.

## Design

| Piece | Responsibility |
|---|---|
| `scripts/gh-shim/gh` | Inspects **its own argv**. An admin merge (or `gh api …/merge`) is refused unless head-bound evidence exists. Everything else is `exec`'d to the real `gh` untouched. |
| `scripts/verify-admin-merge-evidence.sh` | The certifying contract, **one implementation**. Reads the PR's comments and requires *one* comment to carry the marker bound to the **current** head, `PR head:`, the union line, and `unique to this PR: 0`. |
| `extensions/review-enforcer` `tool_call` | Prepends the shim dir to `PATH` on every bash call, so enforcement is not something a caller can forget. `AGENT_GH_SHIM=0` is the kill switch; `AGENT_GH_SHIM_DIR` relocates the shim. |
| The existing scanner | Kept as the **fast first layer** — better messages, no process spawn — with its `STATED LIMITS` now documented as *backed by* the argv layer rather than standing alone. |

## Non-obvious decisions

- **The string gates analyse the caller's command, not the patched one.** The injected
  prefix names the shim path (`…/gh-shim/gh`), so scanning the mutated text would hand the
  gates a `gh` word the caller never wrote. The handler keeps `rawCommand` for every gate
  and mutates only `event.input.command`. There is a test asserting the hazard so a
  refactor that starts scanning the patched string has a failing test to hit.
- **The prefix is its own line, not `&&`.** The harness reports the command's exit status
  back to the agent; `&&` would change what is reported.
- **Fail closed on the undecidable:** no PR number in argv, a non-numeric PR, an unusable
  head, or a missing verifier all refuse. An unverifiable admin merge does not happen.
- **One comment, not several.** The contract clauses are `select`ed inside a per-comment
  pipeline, so a marker in one comment and a verdict in another cannot add up to a
  certificate — a forgery class a naive concatenation would allow.
- **`AGENT_ADMIN_MERGE_OVERRIDE=1` still works, loudly** (existing audited hatch).

## Adversarial threat surface

In scope, each covered by a test, acceptance = every declared class tested + green CI:
flag-name splicing, verb splicing, `xargs {}` assembly, `gh api …/merge`, stale-head
evidence, split-across-comments evidence, and non-regression of ordinary `gh` use
(over-blocking is a failure too).

Out of scope, stated: a command that resets `PATH`/`env -i` or calls the real `gh` by
absolute path; `argv` expanded in a parent process the harness never sees; and the
default-deny inversion for the admin concern alone (needs its own scoping).

## Files

- `scripts/gh-shim/gh` (new)
- `scripts/verify-admin-merge-evidence.sh` (new)
- `extensions/review-enforcer/index.ts` (PATH injection + `STATED LIMITS`)
- `extensions/review-enforcer/index.test.ts` (3 tests)
- `tests/gh-shim/run.sh` (new suite, 26 assertions)

## Verification

- `bash tests/gh-shim/run.sh` → 26 passed
- `bash tests/admin-merge/run.sh` → 152 passed
- `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` → 170 passed
- VGATE review to run on this head before merge.
