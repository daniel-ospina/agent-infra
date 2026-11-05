#!/usr/bin/env python3
"""python-mutation-leg.py — WORKED EXAMPLE of the contract agent-infra#3442 lands, in the shape that
fails on PYTHON harnesses: a `--mutations` shard that never exercises the case the new assertion names.

WHY THIS SHAPE AND NOT A HYPOTHETICAL. It is #3355's measured failure. A liveness assertion
`alive = str(entry) in alive` was added, and the suite grew a `Mutation` list — but no Mutation
produced the `alive=False` case at all, so `--mutations` sharded over a corpus that never reached the
leg. The leg was correct; its PROOF was missing, and three recorded clean reviews did not notice.

⛔ THE TWO FAILURE MODES THIS FILE DISTINGUISHES, because conflating them is how the defect survives:
  1. NO MUTATION NAMES THE ROW — the mutation set holds no revert for this assertion.
  2. A MUTATION EXISTS BUT ANCHORS ELSEWHERE — it reddens the suite through an UNRELATED row, so
     "mutations applied: 1, all caught" reads green while the assertion under test never moved. This
     is the one #3355's first review found, and the reason `expect_green` exists beside `expect_red`.

HOW TO COPY THIS FILE.
  RULE       — the behaviour under test lives behind ONE indirection, so a mutation swaps it rather
               than rebinding a global (a rebound global makes mutation N's result depend on N-1).
  ROWS       — one entry per assertion the diff ADDS, named after what it protects.
  MUTATIONS  — ONE entry per row: `revert` installs the pre-fix behaviour, `restore` puts the fixed one
               back, `expect_red` names the row that MUST redden, `expect_green` names a row that must
               NOT move (attribution), and `why` is the one line a reviewer reads.

  python3 python-mutation-leg.py --check       → rows, then every mutation; exits non-zero naming any
                                                mutation that does not redden ITS row.
  python3 python-mutation-leg.py --mutations   → lists the mutation corpus (the shard selector).
  --no-mutations                               → SKIPS the leg and REFUSES: a suite that passes with
                                                its mutation leg removed IS the defect it documents.
"""

from __future__ import annotations

import sys

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  ok   {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL {msg}")


# ── 1. the production behaviour, behind ONE indirection ─────────────────────────────────────────
def is_alive_exact(entry: str, alive_entries: list[str]) -> bool:
    """The fixed liveness rule: exact membership."""
    return str(entry) in alive_entries


def is_alive_prefix(entry: str, alive_entries: list[str]) -> bool:
    """The PRE-FIX rule (what a mutation restores): a PREFIX match, so `cell-1` reads 'alive' when
    only `cell-10` is — the same over-acceptance class as #3368's `pin-tree` / `pin-tree-shape`."""
    return any(a.startswith(str(entry)) for a in alive_entries)


RULE = {"is_alive": is_alive_exact}
ALIVE = ["cell-10", "cell-20"]

# ── 2. the assertions the diff adds: one entry per row, named after what it protects ────────────
ROWS = {
    # The migration-driven case that pins the EXACT rule.
    "T57_liveness_exact": lambda: RULE["is_alive"]("cell-1", ALIVE) is False,
    # A case that passes under BOTH rules — the attribution control. A mutation that reddens THIS row
    # instead of T57 has anchored the wrong behaviour, which is #3355's first-review finding.
    "T58_liveness_admits_itself": lambda: RULE["is_alive"]("cell-10", ALIVE) is True,
}

# ── 3. one mutation per row that encodes a fix ──────────────────────────────────────────────────
MUTATIONS = [
    {
        "id": "prefix-match-restored",
        "why": "reverts the exact-membership rule to the pre-fix prefix match",
        "revert": lambda: RULE.__setitem__("is_alive", is_alive_prefix),
        "restore": lambda: RULE.__setitem__("is_alive", is_alive_exact),
        "expect_red": "T57_liveness_exact",
        "expect_green": "T58_liveness_admits_itself",
    },
]


def run_rows() -> bool:
    clean = True
    for name, row in ROWS.items():
        try:
            passed = bool(row())
        except Exception as exc:  # noqa: BLE001 - a raising row is a failing row, not a crash
            bad(f"{name} raised {exc!r}")
            clean = False
            continue
        if passed:
            ok(f"{name} passes on the FIXED code")
        else:
            bad(f"{name} does NOT pass on the fixed code — a green mutation leg over a broken row proves nothing")
            clean = False
    return clean


def run_mutations() -> bool:
    clean = True
    for mut in MUTATIONS:
        mut["revert"]()
        try:
            red = {name: not bool(row()) for name, row in ROWS.items()}
        finally:
            mut["restore"]()
        want_red, want_green = mut["expect_red"], mut["expect_green"]
        if red.get(want_red):
            ok(f"mutant({mut['id']}) REDDENS {want_red} — the row that names the behaviour")
        else:
            bad(
                f"mutant({mut['id']}) did NOT redden {want_red} — {want_red} is a VACUOUS pin "
                f"({mut['why']}); this is #3355's missing or detached mutation leg"
            )
            clean = False
        if red.get(want_green):
            bad(f"mutant({mut['id']}) ALSO reddened {want_green} — the catch is not attributable")
            clean = False
        else:
            ok(f"…and {want_green} still passes, so the catch is attributable to the exact-match rule")
        # The FIXED rule must be back before the next mutation, or the preconditions drift.
        if not run_rows():
            bad(f"mutant({mut['id']}) left the fixed rule broken — the restore is load-bearing")
            clean = False
    return clean


def main(argv: list[str]) -> int:
    if "--mutations" in argv:
        for mut in MUTATIONS:
            print(f"{mut['id']}\texpect_red={mut['expect_red']}\t{mut['why']}")
        return 0
    print("== python worked example: the #3355 missing-leg shape ==")
    clean = run_rows()
    if "--no-mutations" in argv:
        # ⛔ A SUITE THAT PASSES WITH ITS MUTATION LEG REMOVED IS THE DEFECT IT DOCUMENTS. The rows are
        # asserted and unproven, so the verdict is INCOMPLETE — never clean.
        bad("the MUTATION LEG IS MISSING: this suite asserts rows it cannot show to be falsifiable (that is #3442, exactly)")
        clean = False
    else:
        clean = run_mutations() and clean
    print(f"  PASS={PASS} FAIL={FAIL}")
    return 0 if (clean and FAIL == 0) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
