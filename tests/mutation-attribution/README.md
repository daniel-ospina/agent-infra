# Mutation attribution — the non-vacuity contract (agent-infra#3442)

Review had no contract requiring that a **new assertion can fail**. So a PR could be reviewed clean —
three times — on the strength of a guard whose test stays **green with the bug restored**, and nothing
in the review contract noticed. Five instances were measured in five PRs in one night (#3355, #3368 ×2,
#3374, #3355 round 4). The clearest statement of the root cause is #3368's own review:

> *"No mutation leg for the new gate — which is exactly how findings 1 and 2 survived three recorded
> clean reviews."*

The absence of a mutation leg is not a missing test. It is **why** the vacuous assertions went
undetected.

## The contract

For **each** assertion a diff adds that claims to protect a behaviour:

1. **A mutant per assertion** — not per file, not per PR. Where a suite already has `mutate_*`
   machinery, the new guard gets a leg in it.
2. **The catch must be attributable** — a mutant that reddens the suite through an *unrelated* row is
   not a proof. The failing assertion must be the one that **names** the behaviour.
3. **"Cannot fail" is a finding, not a nit.** An assertion whose value cannot vary under any mutation of
   the diff is dead weight that misleads a reader into believing the guard is covered. Make it
   reachable or delete it. A comment explaining why it cannot fail is **not** a fix.

## Where it is enforced (two halves, one grammar)

| Surface | Artifact it reads | What it requires |
|---|---|---|
| `scripts/orchestrator-harness/brief-gate.sh` (`--check <brief> reviewer`) | a reviewer **brief** | a non-empty `MUTATION ATTRIBUTION:` field — the *instruction* (prose is correct here). Refuses with **80**; scoped to role `reviewer` only. Suite: `brief-gate.test.sh` §A2/§B2/§C2 |
| `scripts/record-review.sh` (`verify_review_evidence`) | the review **artifact** (the PR comment) | the **filled** rows, or `none — <why>`. Refuses with **3**, so no `clean` record can be minted. Suite: `record-review.test.sh` §21 |

Neither can stand in for the other: a brief carries the instruction, an artifact carries the filled
attribution. `tests/mutation-attribution/run.sh` §4 drives both shipped implementations over the same
bodies and asserts they disagree exactly where the design says they must.

The syntax a clean artifact must carry:

```
MUTATION ATTRIBUTION:
- assertion: <the behaviour the new assertion protects> | mutant: <the revert of that behaviour> | red: <the row/test that goes red>
```

…or, when the diff adds no assertion at all:

```
MUTATION ATTRIBUTION: none — <why, concretely>
```

⛔ **The row is a BULLET with its slots FILLED.** The grammar requires `- ` at the start and
`assertion:` + `mutant:` + `red:` (`row:` also accepted) on that one line, and it refuses a row whose
slots still carry angle-bracketed placeholders. That last clause is not pedantry: a keyword match alone
accepted the reviewer BRIEF, and the help text the refusal itself prints, as a filled attribution — so a
refused lane could paste the remedy and mint `clean`. An unfilled template is a claim nobody made.

Both are **presence and shape**, never content: the gate cannot tell a real mutant from a fabricated
one. What it buys is that "I read the diff and it looks right" becomes a **named, checkable claim**, and
"I did not think about it" becomes impossible to omit. A false `none` is a review finding.

## The worked examples (copy these)

- **`examples/bash-suite-prefix-match.sh`** — the #3368 shape for a **bash** suite: a prefix match
  (`reason=pin-tree` admitting `pin-tree-shape`) where the two added rows stayed green even when the
  whole record-based probe was deleted. Shows the `mutate_*` leg, the `expect_red` attribution, and the
  control row that must **not** move.
- **`examples/python-mutation-leg.py`** — the #3355 shape for a **python** mutation harness: a
  `--mutations` corpus that never produced the case the assertion names. Shows `revert` / `restore`,
  `expect_red` **and** `expect_green`, and the `--mutations` shard selector.

Both fixtures **refuse to pass with their mutation leg removed** (`--no-mutations`), because a suite that
passes unproven assertions is the defect it documents. `run.sh` drives each twice — as shipped (must
pass) and as a self-mutant whose mutation reverts nothing (must fail, naming the row).

## The baseline

`baseline.tsv` records the five measured instances — `pr · assertion · what vitiated it · the mutant ·
the row that reddens` — so *"this PR would have been caught"* is checkable rather than rhetorical.
`run.sh` §1 asserts it holds **exactly** five complete rows: a row silently removed is the one change a
reader would never notice.

## Run

```bash
bash tests/mutation-attribution/run.sh
```
