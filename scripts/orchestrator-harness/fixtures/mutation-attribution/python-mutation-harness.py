"""WORKED EXAMPLE — the #3355 missing-leg shape (agent-infra#3442).

NOT IMPORTED BY ANYTHING: `mutation-attribution.test.sh` READS this file as the copyable shape for a
python suite that already carries a mutation table.

WHY THIS SHAPE EXISTS. #3355 shipped `assert alive == (str(entry) in alive)` with NO `Mutation(...)`
that ever produced the liveness case, so the CI `--mutations` shard never exercised the leg: the
assert was correct and its PROOF was missing. A hand-built `alive=False` mutant reddened it — the
test worked, nobody had shown it. The rule this file encodes is that the mutation is part of the
TEST, not an afterthought a reviewer has to imagine.
"""

MUTATIONS = [
    # Every Mutation names: the edit, and the TEST IDS whose failure is the proof. `expect_failing` is
    # the ATTRIBUTION (#3442 rule 2) — a Mutation with no expected-failing set can only prove that
    # *something* went red, which is how #3355's first review found a mutation anchored to the
    # repair-arm `continue` instead of the liveness leg it was supposed to protect.
    Mutation(
        name="liveness: a stale ref reads dead",
        source="runners.py",
        find="alive = entry.heartbeat_age_s < 90",
        replace="alive = True  # the pre-fix spelling",
        expect_failing=["test_stale_ref_is_not_alive"],  # the leg that was MISSING in #3355
    ),
    Mutation(
        name="liveness: an unreadable box is not 'alive'",
        source="runners.py",
        find="if not entry.readable: return False",
        replace="if False: return False",
        expect_failing=["test_unreadable_box_is_not_alive"],
    ),
]
