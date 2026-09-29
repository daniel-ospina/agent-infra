<!-- admin-merge-safety: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 -->
PR head: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45
test lane: any workflow
main compared (union of 0 runs of any workflow): 
PR failing: 2 | main failing: 7 | blocked by the decision: 0
Failing runs examined: PR=0 main=0 (with parseable FAILED lines: PR=0 main=0)
Lane completion: PR completed=7 tested=7 pending=0 | main completed=10 tested=10 pending=0
PR evaluated-tree surface (every workflow and app on head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45): green — 0 failing of 19 measured, 0 pending
Base check surface (every workflow and app on head of 'main'): green — 0 failing of 15 measured, 0 pending (reported for CONTEXT, never blocking)
Attribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.
   A set carrying a dropped token is CLIPPED, and a CLIPPED set is NOT COMPARABLE to a measured zero (the lane-parity gate's vocabulary, #1319). COMPLETE is the drop count 0 with no token listed below.
⚠️ vacuous comparison — no failure was compared, because NEITHER measured set carried one.
   measured sets: PR failing runs=0 | main failing runs=0 (lane: any workflow)
   lane parity: NOT ESTABLISHED — declared off; lane parity FAILS: this head did NOT execute 1 test shard(s) main's lane executes (parity family: test*), so 'PR failing: 0 | main failing: 0' compares TWO DIFFERENT LANES (tortoise #4263 → #4457).
   PR side: 0 failing run(s) of 7 completed / 7 tested for head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 (0 pending). EMPTY because nothing FAILED — a failing run whose log yielded no parseable failure identity would have BLOCKED at step 1c, not read as zero.
   main side: 0 failing run(s) of 10 completed / 10 tested over the window (10 run(s) requested). EMPTY because the lane is GREEN over that window — NOT because main has no run (a lane that never tested main BLOCKS at step 2b).
   main check surface: green — 0 failing of 15 measured, 0 pending; read across EVERY workflow, not just this lane. CONTEXT ONLY: it never blocks (a PR that repairs a red base must still land).
   PR evaluated tree: green — 0 failing of 19 measured, 0 pending; read from the HEAD commit, where GitHub reports the merge-ref evaluation, across EVERY workflow. THIS is the surface that gates the merge.
   Correct when the lane is green on both sides — but ONLY when both sides ran the SAME lane. The per-side counters tell 'green' from 'never run'; the parity line tells 'the same lane' from 'two different lanes'. A wrong lane selector certifies neither.
<details><summary>the 0 failure(s) this PR carries — all EXEMPT (measured on main with a matching signature and no worse rate)</summary>

(none — this PR carries no failure of its own)

</details>
<details><summary>main baseline: 0 pre-existing failure(s), for comparison</summary>

(none)

</details>
<details><summary>EXEMPT by the decision (visible — both rates, matching signature)</summary>

(none — no failure was exempted)

</details>
<details><summary>final residual (the exemption decision: BLOCKED ∪ UNATTRIBUTABLE) — must be empty</summary>

(empty — the decision exempts every failure this PR carries)

</details>
<details><summary>FAILED token(s) the parser DROPPED — not test ids, so NOT in any failing set (a CLIPPED set is NOT COMPARABLE to a measured zero, #1319). Rendering: the token text with markdown metacharacters escaped, so the evidence block structure cannot be broken.</summary>

(none — every FAILED token was a test id, so the failing sets above are COMPLETE)

</details>

Lists show at most 25 entries of 300 chars; the full sets are reproducible from the run ids above.
Flake classification: none needed (nothing blocked before the re-run)

<!-- admin-merge-retraction: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 -->
⚠️ RETRACTED — the admin merge of head `6f5366c6f4dbcfd9158fc3b2172758eac0390b45` FAILED and did NOT happen.

The evidence comment above (`admin-merge-safety: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45`) records that the safety
comparison passed and the evidence was posted. It does NOT mean this PR merged:
`gh pr merge` exited 1 after that marker was posted.

gh pr merge said:

    gh-shim: verify-admin-merge-evidence: no certifying evidence comment for head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45
    gh-shim: ✗ REFUSED — no head-bound evidence justifies this admin merge (PR #1406).
    gh-shim:   `--admin` bypasses required checks, so it needs the rail certificate:
    gh-shim:       scripts/admin-merge.sh 1406 [--workflow <lane>]

Re-run the rail once the cause is fixed; the evidence above is still head-bound to `6f5366c6f4dbcfd9158fc3b2172758eac0390b45`.

<!-- admin-merge-safety: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 -->
PR head: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45
test lane: any workflow
main compared (union of 0 runs of any workflow): 
PR failing: 2 | main failing: 7 | blocked by the decision: 0
Failing runs examined: PR=0 main=0 (with parseable FAILED lines: PR=0 main=0)
Lane completion: PR completed=7 tested=7 pending=0 | main completed=10 tested=10 pending=0
PR evaluated-tree surface (every workflow and app on head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45): green — 0 failing of 19 measured, 0 pending
Base check surface (every workflow and app on head of 'main'): green — 0 failing of 15 measured, 0 pending (reported for CONTEXT, never blocking)
Attribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.
   A set carrying a dropped token is CLIPPED, and a CLIPPED set is NOT COMPARABLE to a measured zero (the lane-parity gate's vocabulary, #1319). COMPLETE is the drop count 0 with no token listed below.
⚠️ vacuous comparison — no failure was compared, because NEITHER measured set carried one.
   measured sets: PR failing runs=0 | main failing runs=0 (lane: any workflow)
   lane parity: NOT ESTABLISHED — declared off; lane parity FAILS: this head did NOT execute 1 test shard(s) main's lane executes (parity family: test*), so 'PR failing: 0 | main failing: 0' compares TWO DIFFERENT LANES (tortoise #4263 → #4457).
   PR side: 0 failing run(s) of 7 completed / 7 tested for head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 (0 pending). EMPTY because nothing FAILED — a failing run whose log yielded no parseable failure identity would have BLOCKED at step 1c, not read as zero.
   main side: 0 failing run(s) of 10 completed / 10 tested over the window (10 run(s) requested). EMPTY because the lane is GREEN over that window — NOT because main has no run (a lane that never tested main BLOCKS at step 2b).
   main check surface: green — 0 failing of 15 measured, 0 pending; read across EVERY workflow, not just this lane. CONTEXT ONLY: it never blocks (a PR that repairs a red base must still land).
   PR evaluated tree: green — 0 failing of 19 measured, 0 pending; read from the HEAD commit, where GitHub reports the merge-ref evaluation, across EVERY workflow. THIS is the surface that gates the merge.
   Correct when the lane is green on both sides — but ONLY when both sides ran the SAME lane. The per-side counters tell 'green' from 'never run'; the parity line tells 'the same lane' from 'two different lanes'. A wrong lane selector certifies neither.
<details><summary>the 0 failure(s) this PR carries — all EXEMPT (measured on main with a matching signature and no worse rate)</summary>

(none — this PR carries no failure of its own)

</details>
<details><summary>main baseline: 0 pre-existing failure(s), for comparison</summary>

(none)

</details>
<details><summary>EXEMPT by the decision (visible — both rates, matching signature)</summary>

(none — no failure was exempted)

</details>
<details><summary>final residual (the exemption decision: BLOCKED ∪ UNATTRIBUTABLE) — must be empty</summary>

(empty — the decision exempts every failure this PR carries)

</details>
<details><summary>FAILED token(s) the parser DROPPED — not test ids, so NOT in any failing set (a CLIPPED set is NOT COMPARABLE to a measured zero, #1319). Rendering: the token text with markdown metacharacters escaped, so the evidence block structure cannot be broken.</summary>

(none — every FAILED token was a test id, so the failing sets above are COMPLETE)

</details>

Lists show at most 25 entries of 300 chars; the full sets are reproducible from the run ids above.
Flake classification: none needed (nothing blocked before the re-run)

<!-- admin-merge-retraction: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 -->
⚠️ RETRACTED — the admin merge of head `6f5366c6f4dbcfd9158fc3b2172758eac0390b45` FAILED and did NOT happen.

The evidence comment above (`admin-merge-safety: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45`) records that the safety
comparison passed and the evidence was posted. It does NOT mean this PR merged:
`gh pr merge` exited 1 after that marker was posted.

gh pr merge said:

    gh-shim: verify-admin-merge-evidence: no certifying evidence comment for head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45
    gh-shim: ✗ REFUSED — no head-bound evidence justifies this admin merge (PR #1406).
    gh-shim:   `--admin` bypasses required checks, so it needs the rail certificate:
    gh-shim:       scripts/admin-merge.sh 1406 [--workflow <lane>]

Re-run the rail once the cause is fixed; the evidence above is still head-bound to `6f5366c6f4dbcfd9158fc3b2172758eac0390b45`.

<!-- admin-merge-safety: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 -->
PR head: 6f5366c6f4dbcfd9158fc3b2172758eac0390b45
test lane: any workflow
main compared (union of 0 runs of any workflow): 
PR failing: 2 | main failing: 7 | blocked by the decision: 0
Failing runs examined: PR=0 main=0 (with parseable FAILED lines: PR=0 main=0)
Lane completion: PR completed=7 tested=7 pending=0 | main completed=10 tested=10 pending=0
PR evaluated-tree surface (every workflow and app on head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45): green — 0 failing of 19 measured, 0 pending
Base check surface (every workflow and app on head of 'main'): green — 0 failing of 15 measured, 0 pending (reported for CONTEXT, never blocking)
Attribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.
   A set carrying a dropped token is CLIPPED, and a CLIPPED set is NOT COMPARABLE to a measured zero (the lane-parity gate's vocabulary, #1319). COMPLETE is the drop count 0 with no token listed below.
⚠️ vacuous comparison — no failure was compared, because NEITHER measured set carried one.
   measured sets: PR failing runs=0 | main failing runs=0 (lane: any workflow)
   lane parity: NOT ESTABLISHED — declared off; lane parity FAILS: this head did NOT execute 1 test shard(s) main's lane executes (parity family: test*), so 'PR failing: 0 | main failing: 0' compares TWO DIFFERENT LANES (tortoise #4263 → #4457).
   PR side: 0 failing run(s) of 7 completed / 7 tested for head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45 (0 pending). EMPTY because nothing FAILED — a failing run whose log yielded no parseable failure identity would have BLOCKED at step 1c, not read as zero.
   main side: 0 failing run(s) of 10 completed / 10 tested over the window (10 run(s) requested). EMPTY because the lane is GREEN over that window — NOT because main has no run (a lane that never tested main BLOCKS at step 2b).
   main check surface: green — 0 failing of 15 measured, 0 pending; read across EVERY workflow, not just this lane. CONTEXT ONLY: it never blocks (a PR that repairs a red base must still land).
   PR evaluated tree: green — 0 failing of 19 measured, 0 pending; read from the HEAD commit, where GitHub reports the merge-ref evaluation, across EVERY workflow. THIS is the surface that gates the merge.
   Correct when the lane is green on both sides — but ONLY when both sides ran the SAME lane. The per-side counters tell 'green' from 'never run'; the parity line tells 'the same lane' from 'two different lanes'. A wrong lane selector certifies neither.
<details><summary>the 0 failure(s) this PR carries — all EXEMPT (measured on main with a matching signature and no worse rate)</summary>

(none — this PR carries no failure of its own)

</details>
<details><summary>main baseline: 0 pre-existing failure(s), for comparison</summary>

(none)

</details>
<details><summary>EXEMPT by the decision (visible — both rates, matching signature)</summary>

(none — no failure was exempted)

</details>
<details><summary>final residual (the exemption decision: BLOCKED ∪ UNATTRIBUTABLE) — must be empty</summary>

(empty — the decision exempts every failure this PR carries)

</details>
<details><summary>FAILED token(s) the parser DROPPED — not test ids, so NOT in any failing set (a CLIPPED set is NOT COMPARABLE to a measured zero, #1319). Rendering: the token text with markdown metacharacters escaped, so the evidence block structure cannot be broken.</summary>

(none — every FAILED token was a test id, so the failing sets above are COMPLETE)

</details>

Lists show at most 25 entries of 300 chars; the full sets are reproducible from the run ids above.
Flake classification: none needed (nothing blocked before the re-run)

