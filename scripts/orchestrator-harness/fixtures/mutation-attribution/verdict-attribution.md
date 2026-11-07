# What a CLEAN reviewer verdict must carry (agent-infra#3442)

The `--evidence` artifact named by `record-review.sh` for a fresh `clean` record must carry this
section. `brief-gate.sh --mutation-missing` is the ONE parser; `record-review.sh` refuses to mint the
record without it (`verify_review_evidence`'s last arm), and the reviewer's brief is rendered from the
same file (`brief-gate.sh --section reviewer`).

## MUTATION ATTRIBUTION — the block a clean verdict must carry

### The table — one row per NEW assertion

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `scripts/x.sh:120` — "the gate refuses an empty brief" | `sed 's/rc=80/rc=0/' scripts/x.sh` | `x.test.sh` §A (i) | `❌ … REFUSED with 80 (got 0)`, rc=1 |
| `runners.py:88` — "a stale ref is not alive" | `alive = True  # pre-fix spelling` | `test_stale_ref_is_not_alive` | `1 failed, 12 passed` |

### Or, when the diff adds no assertion at all

The shape is INDENTED rather than live: a live `NO NEW ASSERTIONS:` line in this document would exempt
the document itself, so deleting the table above would still leave it ADMITTED — the documented shape
would prove nothing. Type the line yourself:

    NO NEW ASSERTIONS: docs-only — the diff touches `docs/ops/*.md` and adds no executable assertion.

⛔ Write it at COLUMN 0. The indented form above is a QUOTED code block and the parser skips it —
which is why it is shown that way (a LIVE line in this document would exempt the document itself, so
deleting the table above would still leave it admitted).

### The three rules

1. A mutant per NEW GUARD — not per file, not per PR.
2. The catch must be **attributable**: a mutant that reddens the suite through an unrelated row is not
   a proof. Name the row that names the behaviour (#3368's prefix match; #3355's repair-arm anchor).
3. An assertion whose value cannot vary under ANY mutation of the diff is dead weight that misleads
   the next reader. Make it reachable or delete it; a comment explaining why it cannot fail is not a
   fix.
