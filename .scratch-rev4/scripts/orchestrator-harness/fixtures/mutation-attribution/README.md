# MUTATION ATTRIBUTION fixtures (agent-infra#3442)

Worked examples for the non-vacuity contract: one per suite class the issue measured, so the shape is
**copyable** rather than described. Every file here is driven by
`scripts/orchestrator-harness/mutation-attribution.test.sh`.

- `bash-suite.sh` — a bash suite: the #3368 **prefix-match** shape (a mutant that deletes a whole
  probe is masked by a sibling gate that matches on a prefix, so the assertion that names the
  behaviour is the one that must be shown going red).
- `python-mutation-harness.py` — a python suite with its own `Mutation(...)` table: the #3355
  **missing-leg** shape (the assert is correct but no `Mutation` ever produces the case, so the CI
  `--mutations` shard never exercises it).
- `verdict-attribution.md` — what the reviewer's PR comment must carry. Two shapes: the table (one row
  per new assertion) and the `NO NEW ASSERTIONS:` exemption.

Both code fixtures are **demo files, not part of any suite**: they are read by
`brief-gate.sh --mutation-missing` in the test, never executed as production code.
