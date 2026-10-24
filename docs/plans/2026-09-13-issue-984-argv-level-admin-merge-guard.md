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

## Installation — ONE farm declaration, two platforms

The shim is useless on a box that does not have it, and *the way it went missing is the whole
lesson*: the review-enforcer resolves it as `EXTENSION_DIR/../../scripts/gh-shim`. On a laptop
`setup.sh` keeps the extensions as **farm symlinks** into the checkout, so node's module
resolution follows the link and `../..` **is the checkout** — the shim is found even though
nothing ever installed it. On a cloud cell the extensions are **real copies**, so the same
expression is `~/.pi/agent/scripts/gh-shim`, a directory nothing farmed. Measured on a live
cell, on every lane:

```
[review-enforcer] ⚠️  #984 argv-level gh shim not found — only the string scanner is active,
   so bash token splicing can still hide an admin merge.
```

That is the merge gate running in its documented DEGRADED mode (no argv inspection at all)
while `--verify` printed LAYER VERIFIED — a cell that reports itself ready with a gate that
cannot do its job. So the shim is now **farmed**, from the same declaration the laptop uses:

| Path | Role |
|---|---|
| `pi-bootstrap/setup.sh` · `merge_gate_srcs` | THE declaration: `record-review.sh`, `gh-shim/gh`, `verify-admin-merge-evidence.sh`. The macOS bootstrap installs from it; `cell-install.sh` **parses** the same array, so there is no second list to drift. |
| `~/.pi/agent/scripts/gh-shim/gh` | The installed shim (mode 755 — a PATH entry without the execute bit is *skipped* by bash, so the real `gh` runs and nothing enforces). |
| `~/.pi/agent/scripts/verify-admin-merge-evidence.sh` | Its `../` sibling — the shim resolves the verifier from its own location and fails CLOSED without it, so shipping one without the other refuses every admin merge. |
| `pi-bootstrap/cell-install.sh` · `guard_gh_shim` | The read-back, in **two independently verified halves** — they fail in OPPOSITE directions, so neither can stand in for the other. **(1) The directory the EXTENSION RESOLVES** is verified **on its own, unconditionally** — present AND executable, whether or not `AGENT_GH_SHIM_DIR` is exported, because it is what a lane started WITHOUT the variable resolves, and a valid preference cannot stand in for it. ⛔ It is resolved the way the extension resolves it: `EXTENSION_DIR` is `dirname(fileURLToPath(import.meta.url))`, the REALPATH of the loaded module, so the CELL case (`extensions/review-enforcer/../..` = `~/.pi/agent/scripts/gh-shim/gh`) and the LAPTOP case (extensions kept as farm symlinks, so the same expression is `<checkout>/scripts/gh-shim/gh`) are DIFFERENT directories — the extension directory is therefore taken PHYSICALLY (`cd -P`) before the `../..` step, so the path certified is the path the module resolves on both platforms, rather than one lexical constant that is a false PASS on one and a false BLOCK on the other. **(2) `AGENT_GH_SHIM_DIR` is a *preference*, not an override**, and it decides ONLY whose `../verify-admin-merge-evidence.sh` sibling is required: the SAME candidate list and order as the extension (`AGENT_GH_SHIM_DIR` first, then the installed copy; the first candidate holding an EXECUTABLE `gh` wins, so an unusable value FALLS BACK rather than failing a healthy cell), with the sibling resolved **through symlinks** — a symlinked shim, and a candidate DIRECTORY that is itself a link, with every `..` taken PHYSICALLY (`cd -P`/`pwd -P`) so the path tested is the path the kernel resolves — and a link CYCLE refused rather than walked forever (bounded hop count, and the bound itself is validated first: a non-numeric value makes `[ -gt ]` ERROR, which would leave `&& return 1` unfired and re-open the spin; `--install` ends by verifying, so an unbounded walk would hang `cloud-cell-bringup.sh --check`). It FAILS BY NAME the absent / non-executable installed copy, the missing verifier sibling, and an unresolvable link chain, and it prescribes `--install` ONLY when the failing candidate is the installed copy (an operator's override is not repaired by re-installing). It runs in `--verify` AND at the end of `--install`, so `cloud-cell-bringup.sh --check` — which verifies BEFORE it installs — repairs a cell instead of certifying it. |
| `pi-bootstrap/tests/test-cell-install.sh` §(l) | Proves it: the artifact, the wiring (`gh` resolves to the INSTALLED shim with that directory first on PATH, derived PHYSICALLY from the extension's own location), the BEHAVIOUR (driven with a stub real `gh` it refuses an unevidenced `--admin` **and** is shown to have reached the installed verifier — a refusal without the verifier being called would be the wrong gate working), a positive control (an ordinary `gh pr view` passes), and every refusal arm, each followed by `--install` restoring a clean `--verify`: **absent** / **non-executable** / **verifier missing**, plus the two halves of the preference contract — a **644 INSTALLED shim with a valid preference exported** is still refused (the preference is not a substitute), an **override with no verifier sibling** is refused with the override-specific remedy (deleting the candidate loop leaves every other arm green, so this one exists to pin it), while a **symlinked shim** and a **symlinked candidate DIRECTORY** both PASS on a healthy cell and both REFUSE (naming the RESOLVED path) once the verifier is gone. It also exercises the OTHER platform: with `extensions/review-enforcer` a **farm symlink** into a fixture checkout, the guard must certify the FIXTURE's `scripts/gh-shim` — REFUSED when it is absent (the false PASS, where the farmed `$DEST` copy satisfied the lexical derivation; MEASURED: hard-coding the installer's `installed=` left the whole suite green before this arm) and PASSED when it is there (the false BLOCK). Finally it drives the resolver's **hop bound** at function level: a self-referential link and a mutual loop must fail closed (rc=1, no path), a legitimate 3-hop chain must still resolve, and a **non-numeric bound** must fall back rather than spin (measured pre-fix: rc=124). Every arm reads a PER-RUN log, so no assertion is satisfied by an earlier arm's output. |

⛔ The gate was **not** weakened to make it "work" without the shim: the degraded mode IS the
defect, so the verifier refuses it by name instead.

## Files

- `scripts/gh-shim/gh` (new)
- `scripts/verify-admin-merge-evidence.sh` (new)
- `extensions/review-enforcer/index.ts` (PATH injection + `STATED LIMITS`)
- `extensions/review-enforcer/index.test.ts` (3 tests)
- `tests/gh-shim/run.sh` (new suite, 26 assertions)
- `pi-bootstrap/setup.sh` (`merge_gate_srcs` — the ONE declaration, both platforms)
- `pi-bootstrap/cell-install.sh` (`guard_gh_shim` — the named read-back)
- `pi-bootstrap/tests/test-cell-install.sh` (§(l) — absent ⇒ fails by name, install ⇒ passes)
- `pi-bootstrap/tests/test-setup-no-nesting.sh` (merge-gate summary derived from the array, not a literal count)

## Verification

- `bash tests/gh-shim/run.sh` → 26 passed
- `bash tests/admin-merge/run.sh` → 152 passed
- `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` → 170 passed
- VGATE review to run on this head before merge.
