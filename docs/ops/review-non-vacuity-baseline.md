# The discriminating-power baseline (agent-infra#3442)

Five assertions, in five PRs, in **one night**. Every one of them was reviewed **clean**. Every one of
them would have stayed **GREEN with the bug restored** — so the review certified a guard that did not
exist. This file is the baseline the non-vacuity contract is measured against: a PR that reproduces
any of these shapes must be refused, and `scripts/orchestrator-harness/mutation-attribution.test.sh`
drives each one through `brief-gate.sh --mutation-missing` to prove it.

| # | PR | the assertion | what it did under the pre-fix code |
|---|---|---|---|
| 1 | #3355 | `alive=str(entry) in alive` liveness leg | **no `Mutation` produced the case at all**, so the CI `--mutations` shard never exercised it. A hand-built `alive=False` mutant reddened T57 — the test worked; its PROOF was missing |
| 2 | #3368 | `assert_absent "$OUT" "unbound variable"` (`test.sh:4413`) | the fixed line was replaced with the exact pre-fix spelling the code comment calls a P1 and it **stayed GREEN**, because the fixture sets `CELL_HOME` so `$HOME` is never expanded |
| 3 | #3368 | `reason=pin-tree` vs `reason=pin-tree-shape` | deleting the **entire** record-based probe (`:2655-2684`) left G15a and G15b **green** — prefix match, so the shape backstop satisfied them |
| 4 | #3374 | `LAYER VERIFIED` credential state (`test.sh:1493`) | grepped the whole log for a phrase `cell-install.sh:327` prints **unconditionally** → green even if the state is removed from the cert line it exists to protect |
| 5 | #3355 (round 4) | `check(record["ceiling"] == 3 …)` | no mutation of the diff could redden it — `ceiling` is capped regardless |

**The root, in #3368's own review's words:** *"No mutation leg for the new gate — which is exactly how
findings 1 and 2 survived three recorded clean reviews."* The absence of the mutation leg is not a
missing test; it is **why** the vacuous assertions went undetected.

## What the contract now does about it

- The reviewer's brief states it (`brief-gate.sh --section reviewer`) and the dispatch is REFUSED
  without it (exit 80), on the #2258 precedent.
- A fresh `clean` record cannot be minted over a review artifact that carries no attribution
  (`record-review.sh` → `verify_review_evidence` → `brief-gate.sh --mutation-missing`).
- The copyable shape per suite class is in
  `scripts/orchestrator-harness/fixtures/mutation-attribution/`: a bash suite (the #3368 prefix-match
  shape, rows 2–3) and a python mutation harness (the #3355 missing-leg shape, rows 1 and 5).

## What it does NOT do — stated so a green run is not read as more than it is

The gate checks **presence and shape**, never substance. It cannot tell a mutant that really reddens
the named row from one the author invented, and it cannot tell an **equivalent** mutant from a killed
one (undecidable in general — `https://cacm.acm.org/research/how-do-java-mutation-tools-differ/`). What
it removes is the measured failure mode: a clean verdict with **no** attribution at all, which is
indistinguishable from a guard nobody ever tried to break. Attribution itself is reviewed by the
reviewer and the orchestrator, which is the half a machine cannot decide.
