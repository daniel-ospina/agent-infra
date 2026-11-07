## Measured at `a0e8d16e` (current `origin/main`) — the base-owned red set is larger than three

While merging PR #3374 (a `pipeline-compliance`-only blocker), I reproduced every failing `bash-suites`/`verify` arm in a **clean worktree at `origin/main` = `a0e8d16e`** (`/tmp/base3057b`), and compared it to the same suite on the PR head. The failing sets are **set-identical** — nothing below is caused by the PR, whose authored diff (`git diff --name-only origin/main...HEAD`) lists none of these files.

| suite | base `a0e8d16e` | PR head (post forward-merge) |
|---|---|---|
| `scripts/orchestrator-harness/selftest.sh` | `606 passed, 21 failed` | the same 21 arms |
| `pi-bootstrap/tests/test-setup-no-nesting.sh` | 2 FAIL (`producer-set` + `DELIVERED BY NOTHING`) | identical |
| `scripts/orchestrator-harness/auto-rail.accounting.test.sh` | 4 FAIL (recycled-pid ×2, `SEARCH-FAILED` ×2) | identical |
| `scripts/pr-doctor-fetch-refspec.test.sh` | 2 FAIL (`adopt-fix.sh` worktree arm) | identical |
| `scripts/orchestrator-harness/brief-gate.test.sh` | 2 FAIL (missing-validator exit 78; "files touching the gate are EXACTLY the declared set") | identical |

The 21 `selftest.sh` arms, verbatim at base:

```
FAIL  holder-only INCOMPLETE with NO claim registry on the box is NOT queued
FAIL  (2952b) …and the refusal names the MISSING registry
FAIL  …and it is TOLERATED, not refused
FAIL  controller honours the claim written by the chain path
FAIL  shipped run_agent() kills a hung agent at the wall limit (elapsed=?s rc=? ran=0)
FAIL  the cell supervisor inlines SCOPE=own|broad|auto into the session command   (3)
FAIL  the doctor loop's session command carries SCOPE / ENV_FILE                 (2)
FAIL  the session command string does not carry the merge key
FAIL  the cell preflight names an EXISTING-BUT-UNREADABLE key file as such
FAIL  cmd_check reports the key present when keys.env carries it
FAIL  cmd_check warns that an ambient-only key does not reach the session
FAIL  the start path surfaces an ambient-only key verdict on stderr
FAIL  the start path surfaces the no-key verdict on stderr
FAIL  a WHITESPACE-ONLY key … / the start path surfaces the whitespace-only verdict (2)
FAIL  a keys.env HOME= without a key does not hide the key in $CELL_HOME
FAIL  a NEWLINE-ONLY key … judged whitespace-only, not present via the file
FAIL  cloud-cell-bringup runs gh under $CELL_HOME, not a keys.env HOME=
```

Two of these clusters already have their own roots: the `cloud-cell-bringup` PATH-reading cluster is #1798, and the `keys.env` `HOME=` cluster is the #3226 class.

`verify`'s red is the one this repo already tracks in #2788, one declaration further along: it is now `scripts/pi-reap-worktrees.sh: REAP_WT_PRESERVE_KEEP_DAYS` (the `REAP_WT_MIN_AGE_MINUTES` fix from #3431 has not landed yet). It is not fixable from any PR that does not touch `pi-reap-worktrees.sh` — which is exactly the shape #3415 describes.

**Consequence for the rail:** a `bash-suites`/`verify` arm that the BASE owns cannot be cleared by the lane, so the only landing path for a PR whose required check is green is to treat the base-owned arms as declared (see #3415). Nothing here is a request to make these advisory — it is the measured set so a lane can tell its own red from main's.
