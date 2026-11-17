# WORKTREE REPORT — agent-infra #4034 round-2 fixer · `fix/4034-round2-findings`

Worktree: `/home/cmux/agent-infra/.worktrees/4034-backstop`
Branch: `fix/4034-round2-findings` (base `origin/main` @ `8f90074fe`)
Follow-up to PR **#4065** (`fix/4034-backstop-5x`, **MERGED** at `52784ccdda`, merge commit `6893e7910`)

⛔ **`tools/worktree_report.py` DOES NOT EXIST IN THIS REPO** (checked: `ls tools/` has only `fleet/`,
`install-ci-runner-x64.sh`; `lane-report-gate.sh` returns **5 NO-CONSUMER** for agent-infra for exactly
this reason). So this file is written by hand and every number below is a MEASURED tail of a command run
in this worktree, quoted verbatim so it can be re-run. No count here is asserted from memory.

## The state I found, because it changes the assignment

The brief said "#4065 open, MERGEABLE, head `52784ccdda`; update PR #4065, not a new PR". Measured:

```
$ gh pr view 4065 --repo daniel-ospina/agent-infra --json state,headRefOid,mergedAt,mergeCommit
state MERGED · headRefOid 52784ccdda663015a4d30917dc30f8f537f91819
mergedAt 2026-11-16T13:48:25Z · mergeCommit 6893e79107dc0f36309adf1dd7be033d89547883
$ git ls-remote origin refs/heads/fix/4034-backstop-5x        → (nothing: the branch is deleted)
$ git diff HEAD origin/main --stat                            → 76 files, 20957 insertions
```

So #4065 was merged **with the seven-finding re-review outstanding**, its branch is gone, and this
worktree's base was 76 files behind `origin/main`. Updating #4065 is not possible (GitHub does not accept
commits onto a merged PR, and the branch no longer exists), so the seven fixes land as a **follow-up PR
against `origin/main`** — the same work, continued, not a second PR for it. That is the one deviation
from the brief and it is stated rather than papered over.

**Uncommitted predecessor work was found in the tree** (8 files, 301 diff lines: a stale-pin rewrite, the
residual table, two test blocks, prose tweaks) — a lane killed mid-flight. Per agent-infra#2981 it is
**never discarded**: it is preserved two ways before the base moved —
`git switch -c wip/4034-round2-predecessor` → commit `c376aabc8`, and a patch file at
`~/.pi/agent/state/4034-round2/predecessor-wip-*.patch` (25 391 bytes). It was **not** shipped as-is: it
was written against the pre-merge text of those files and it left finding 4's overstatement in place, so
its content was re-implemented against `origin/main` and this report records which finding each edit
serves.

## The seven findings, each with the file:line it changed

| # | file:line | what changed |
|---|---|---|
| 1 (P2, fail-open) | `scripts/orchestrator-harness/install-drainer-timer.sh:233-329` (+ `scripts/lib/systemd-unit-parse.sh`, `scripts/install-disk-reaper-timer.sh:669-691`, `pi-bootstrap/setup.sh:941`, `docs/ops/ai-drainer.md:355-372`) | the pin is read with systemd's GRAMMAR, not a `^Environment=LANE_TIMEOUT=` spelling match: unit + `<unit>.d/*.conf` in systemd's order, quoted values, several assignments per line, whitespace around `=`, last-wins, bare `Environment=` reset. A pin nothing can resolve is **UNKNOWN (5)**, never "no pin" (0) |
| 2 (P2) | `scripts/orchestrator-harness/claims.sh:125-146`, `merge-one.sh:1970-1972` | the residual is THREE rows (`_gw` 900 → 46290 / 1710 spare · 1800 → 47190 / **810 spare** · 3900 → 49290 / 1290 over) plus the threshold (`_gw` > 2610, `GATE_POLL_SECS` > 87); `3900` is named as the merge TERM, not `_gw`; `39000` → `41100` |
| 3 (P3) | `scripts/orchestrator-harness/lane-reap.test.sh:48-56` | `unset LANE_REAP_LIVE_MIN LANE_REAP_IDLE_MIN` at suite entry, so the shipped-window arms cannot grade the ambient window |
| 4 (P2) | `scripts/orchestrator-harness/README.md:2352-2378`, `lane-merge.sh:254-256,536-559` | design operand (247 × 120 = 29640) split from the OPERATIVE allowance (the watchdog's 22 × 120 = 2640 s, on BOTH clocks); the merge phase still cannot out-watch its 5400 s check wait; `:534-535`'s stale `7 × 120` corrected |
| 5 (P3) | `scripts/orchestrator-harness/ARCHITECTURE.md:184` | the `claims.sh` table row is one line again (it was split mid-cell, leaving `raised the lane term 5x), and orphaned host \|` as its own paragraph) |
| 6 (P3) | `scripts/orchestrator-harness/dispatch-merge.sh:42-45` | `(CLAIM_ISSUE_TTL, 4 h since #2029, 5 h since #2999, 13 h 20 m since agent-infra#4034)` |
| 7 (P3) | `scripts/orchestrator-harness/README.md:3099,4844-4845,5100-5101,5877-5879`, `ai-drainer.test.sh:1748-1750` | `wall_bound=7200s` sample → 36000 s; three "3 h" `CLAIM_ISSUE_TTL` statements → 13 h 20 m; "3000s ≈ 2.5 ticks" → 36000 s ≈ 30 ticks |

Item 1 was proven the way the brief asked (`--status` returns 5 **not 0** where the pin cannot be
resolved) — with one deliberate deviation, stated in the commit and repeated in the PR body: for a
**quoted pin** and a **drop-in pin** whose *value* is stale the correct grade is **3 STALE**, not 5, because
the value DOES resolve and 3 is what `docs/ops/ai-drainer.md` publishes for "disagrees with the seam"; 5
is reserved for the unresolvable (an unterminated-quote pin line, a non-numeric value). What finding 1 is
about — rc 0 certifying a box that dispatches at the old cap — is closed for every spelling an ARM tests,
and no arm returns 0 over a cap that disagrees with the seam. ⛔ THE BROADER CLAIM THIS REPORT FIRST MADE
("closed in every spelling") WAS FALSE AND IS WITHDRAWN (round-2 re-review, F4): four further spellings —
`EnvironmentFile=`, a pin under `[Install]`, a backslash continuation, and a `\x4C`-style escape — each
still exited 0 over a box at 7200, and they are closed in the shared parser (`env_compile_hazards`, section
scope, continuation joining) with an arm per spelling. What this document can assert is what its arms
measure; `docs/ops/ai-drainer.md` publishes the same three-answer contract.

### The item-1 probe matrix, measured through the shipped `--status`

Fake `systemctl`, temp unit dir, seam read from `spawn-gate.sh` (36000), drop-ins moved out of the way
between arms. Every row is a real run of `install-drainer-timer.sh --status` in this worktree:

| fixture | rc | note |
|---|---|---|
| shipped unquoted pin = seam | **0** | unchanged |
| plain stale 7200 | **3** | unchanged |
| quoted stale `"LANE_TIMEOUT=7200"` | **3** | was **0** (fail-open) |
| list form `HOME=/x LANE_TIMEOUT=7200` | **3** | was **0** |
| indented `  Environment = LANE_TIMEOUT=7200` | **3** | was **0** |
| base=fresh + drop-in stale 7200 | **3** | was **0** |
| base=stale + drop-in fresh | **0** | the drop-in WINS, both directions |
| unterminated quote naming the pin | **5** | was **0** |
| non-numeric pin (`abc`) | **5** | cap unresolvable |
| pin then bare `Environment=` reset | **0** | the reset CLEARS the pin (no pin) |
| no pin at all | **0** | `ExecStart=` grading, unchanged |

Non-vacuity: with `INSTALLER` pointed at `origin/main`'s installer (temp copy, then restored) the same
suite reports **200 passed, 8 failed** — one arm per fail-open spelling above.

## Suites, verbatim, as measured

| command | result |
|---|---|
| `bash scripts/orchestrator-harness/ai-drainer.test.sh` | `ai-drainer.test: 208 passed, 0 failed` |
| `bash scripts/orchestrator-harness/ai-drainer.test.sh` (pre-fix installer) | `200 passed, 8 failed` — the 8 new arms, the non-vacuity control |
| `bash scripts/orchestrator-harness/lane-merge.test.sh` | `ALL 207 lane-merge checks passed` |
| `bash scripts/orchestrator-harness/lane-reap.test.sh` | `lane-reap.test: 235 passed, 0 failed` (also with `LANE_REAP_LIVE_MIN=125`, and with `LANE_REAP_IDLE_MIN=60`) |
| `bash scripts/orchestrator-harness/lane-reap.test.sh` (pre-fix suite, ambient `LANE_REAP_LIVE_MIN=125`) | `❌ LIVE-WINDOW: at the shipped 601 min … (got: lanes=0/1 zombie=0, want: lanes=1/1 zombie=0)` — the item-3 defect, reproduced |
| `bash scripts/orchestrator-harness/lane-bound.test.sh` | `RESULT: 83 passed, 0 failed` |
| `bash scripts/orchestrator-harness/claim-orphan.test.sh` | `150 passed, 0 failed` |
| `bash scripts/orchestrator-harness/test-claims.sh` | `RESULT: 301 passed, 0 failed` |
| `bash scripts/disk-reaper.test.sh` | `ALL PASS (720 assertions)` (the extracted `Environment=` lib is behaviour-identical for its original caller) |
| `bash pi-bootstrap/tests/test-setup-no-nesting.sh` | `OK: no nesting, active files refreshed, farm links preserved` (the new lib is declared in `lib_srcs`) |
| `bash scripts/orchestrator-harness/check-single-source.sh` | `ok: one source of truth — 11 shared file(s) …` |
| `bash scripts/orchestrator-harness/selftest.sh` (this branch) | `677 passed, 25 failed`, then **`678 passed, 24 failed`** on a re-run — see the baseline row |
| `bash scripts/orchestrator-harness/selftest.sh` (`origin/main` @ `8f90074fe`, scratch worktree, removed after) | `678 passed, 24 failed` |
| the two FAIL lists compared (`comm`) | **0 new failures, 0 fixed** — the 24 are pre-existing on `origin/main`; the 25th was a re-run flake, and the unique FAIL-name sets are identical |
| `bash scripts/check-false-pass-shapes.sh` | `PASS: no finding in the SCANNED SET (362 file(s)) … 0 finding(s)` |
| `bash pi-bootstrap/tests/test-cell-install.sh` | **NOT A PASS — not run to its end** (see below) |
| `bash -n` on every touched shell file | clean |

⛔ **CI STATE IS NOT RECORDED HERE, ON PURPOSE.** Every push produces a new head and a new check set, so a
green line in this file would describe a commit nobody is merging. At the head this file was last
written for, the PR's whole check set passed (`ci / lint`, `typecheck`, `unit-test`, `script-validate`,
`skill-lint`, `test`, `verify`, `drift-check`, `vendor-drift`, `sigpipe-grep`, `pi-sdk-parity`,
`harness-single-source`, `http-pool-hygiene`, `pi-config-extensions`, `cost-config`, `search-cost`,
`sanctioned-pin`, `verdict-pin`, `workflow-lock`, `workflow-drift`) — read the PR for the current one.

⛔ `pi-bootstrap/tests/test-cell-install.sh` **exceeded a 900 s and then a 1 200 s window on this box and was
not run to its end**: the partial run logged in `~/.pi/agent/state/4034-round2/cell-install.log` holds
**190 `ok:` lines and 0 failures** — and was STILL GROWING when the window closed, so the number is a
floor taken at one instant, not a total (re-read the log to see where it ended). It is DISCLOSED as
not-a-pass rather than reported green. The file I touched in `pi-bootstrap/` is one array entry in
`setup.sh`, and the farm arm that reads that array (`test-setup-no-nesting.sh`) DID pass — but
`test-cell-install.sh` is unmeasured by this lane and a reviewer should treat it as such.

## Residuals, stated

1. **A quoted / drop-in stale pin grades 3, not 5.** Deliberate, explained above and in the PR body.
2. **`CLAIM_BRANCH_TTL` (14400) still sits below one lane's backstop (36000)** and nothing renews it —
   unchanged by this lane, pre-existing from #4065, stated in `claims.sh:175-190` and in the PR body.
   The escape is the single knob; the pre-push guard refuses fail-closed in the meantime.
3. **`GATE_POLL_SECS` > 87 puts `CLAIM_ISSUE_TTL` over its own sum** (row 3 of the claims table). Closed
   for the two shipped configurations (`_gw` 900 and 1800); an operator override past 2610 s must raise
   the default with it — now stated as a threshold instead of an example.
4. **The `--watch` allowance is 22 chunks (2640 s) on both clocks**, so the 5× buys the LANE TERM and a
   non-decaying allowance, not 11× more supervision. Stated in both `README.md` and `lane-merge.sh`; the
   number that a reader will find in each place is now the same number.
5. **`lane-reap`'s 601-minute window still counts a ghost tree LIVE for up to 10 h** (the second
   direction of that trade). Unchanged here; recorded in `lane-reap.sh:190-200` and in #4065's body.
6. `merge-one.sh`'s edit is **comment-only** (a number in a prose block), so no `merge-one` suite was
   re-run for it; every executable change is covered by the suites above.

## What this lane did NOT do

- No Tortoise graph write, no deletion, no MCP/SDK surface change.
- No change to the 45-minute progress allowance (`DEFAULT_PROGRESS_AGE_MS = 2_700_000`), to the seam
  (`LANE_BACKSTOP_S` 36000), to `CLAIM_TTL_MAX` (43200, still a CEILING with floor
  `max(48000, 14400, 43200)`), or to any assertion (every new arm is additional; none replaced a weaker one).
- No review attestation recorded and no merge attempted — the review gate belongs to the parent, and the
  harness reviewer mints the record at the final head.

---

# Addendum — the round-2 RE-review, answered (`a0aa08abb`, `ccbdb3cdd`)

A fresh-context reviewer read this PR at `c5e372fe7d6b` and returned **ISSUES (1)**: one P2 and three P3.
All four are answered below; the numbers are re-measured in this worktree, not carried from the prose
they correct.

## The P2 — and it is the same defect this PR exists to remove, one directive over

`scripts/orchestrator-harness/install-drainer-timer.sh:290` read the no-pin arm's `ExecStart=` from
`$UNIT_DIR/$svc` ALONE, through a `^ExecStart=/bin/bash ` spelling match — while the `Environment=`
reader three arms above already used the drop-in-aware `$unit_text`. A `<unit>.service.d/*.conf` that
overrides the command was therefore **invisible**, and the arm graded a script systemd does not run: no
pin + a drop-in → :310-311 printed *"agrees with the … s this checkout would render"* and the function
fell to `return 0`. This is the shape `install-disk-reaper-timer.sh` closed with `effective_execstarts`
(its own comment records the measured defeat), and it falsified the PR body's *"closed in every
spelling"*.

Fixed by reading the command from the text systemd parses, with the primary sources' semantics:
`effective_execstarts` **moves into `scripts/lib/systemd-unit-parse.sh`** (that file's own recorded rule
is "one definition, both callers"; this is the second caller, and the reaper now sources it instead of
keeping a copy). systemd.unit(5): drop-ins are "parsed after the main unit file itself has been parsed".
systemd.service(5): a bare `ExecStart=` "reset[s] the list", and `Type=oneshot` may carry several
commands — so every effective command is graded, because a oneshot runs them all.

Measured through the shipped `--status` on one fixture (base `ExecStart=/bin/bash <fresh>`), pre-fix and
post-fix are DIFFERENT BINARIES of the same script (`git show <head>:…` into a probe copy):

| fixture | pre-fix | post-fix |
|---|---|---|
| base fresh + drop-in `ExecStart=` → `ExecStart=/bin/bash <stale 7200>` | **0** — "agrees with the … s this checkout would render" | **3** STALE, names the stale script |
| base STALE + drop-in `ExecStart=` → `ExecStart=/bin/bash <fresh>` | **3** (false stale) | **0** — the graded script is the one systemd runs |
| `ExecStart = /bin/bash <stale>` (whitespace around `=`, legal systemd) | **5** — "names no readable script" | **3** STALE |
| one plain `ExecStart=/bin/bash <fresh>`, no pin | 0 | 0 (unchanged) |

Three arms were added to `ai-drainer.test.sh` pinning rows 1–3, and the suite is
`211 passed, 0 failed` (it was 208 before: the three arms). Priority order is stated in the code: STALE
(3) outranks UNKNOWN (5) outranks clean (0) — a script the verb cannot read (`bash -c …`, a quoted
path, a missing file) is still never a clean.

## The three P3s, all doc-only, all verified against the primary source

| finding | what it said | disposition |
|---|---|---|
| `claims.sh:143` | the pre-#4034 crossing is **1410** s, not 1710 (1710 is the `_gw` = 900 row's SPARE figure) | corrected, with the recount shown: base 45390 − (36000 − 7200) = 16590 against 18000 → 1410; and 1410 + 1200 = 2610 is the post-change threshold. Verified against the rows above it, not against a sentence |
| `README.md:2353` | the baseline column is labelled `origin/main (7200 s clock)`, but `origin/main` ships `LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-36000}"` (`spawn-gate.sh:3566`) since #4065 merged | relabelled **pre-#4034 tree**; re-verified with `git show origin/main:scripts/orchestrator-harness/spawn-gate.sh \| grep LANE_BACKSTOP_S=` → `3566:LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-36000}"` |
| `docs/ops/ai-drainer.md:361` | "rc 0 MEANS THE PIN WAS ACTUALLY READ, IN WHATEVER SPELLING" contradicts the rc table three lines above it, whose no-pin row exits 0 | rewritten: rc 0 means **a cap was read and agrees with the seam**, and the output names which of the two shapes it was; the no-pin shape (ExecStart script, unit + drop-ins, oneshot's several commands) is now spelled out there |

## The ambient red on this PR, root-caused (not a finding)

`ci / unit-test` was RED at `991122e35` and `pipeline-compliance` was RED. Neither was caused by the
findings above.

* **`ci / unit-test` → `check-skill-lint.test.mjs`, "implicit no-dir → exit 0".** The arm ran the CLI
  from `os.tmpdir()` and the implicit lookup walks `<cwd>/skills` — SHARED HOST STATE on the
  self-hosted runner. Reproduced in this worktree: `mkdir -p /tmp/skills` → **170 passed, 1 failed**
  with the runner's exact message; `rmdir /tmp/skills` → **171 passed, 0 failed**. So the check's colour
  depended on what OTHER jobs had written to /tmp: a false-RED generator on a required check, which
  blocks every lane's merge. The arm now uses `fs.mkdtempSync` (unique, empty by construction) and
  removes it; verified **171 passed, 0 failed with the polluting directory PRESENT**.
* **`pipeline-compliance`** reads (a) a line-leading issue reference — satisfied by the body's own
  `Part of #4034` line, re-run locally → `✅ [a] linked issue #4034`; and (c) a **head-bound
  code-review record**, which is the harness reviewer's to mint at the final head. This lane does not
  attest its own review and does not merge.

## Suites run for this addendum (measured, in this worktree)

| command | result |
|---|---|
| `bash scripts/orchestrator-harness/ai-drainer.test.sh` | **211 passed, 0 failed** |
| `bash scripts/disk-reaper.test.sh` (the `effective_execstarts` move) | **ALL PASS (720 assertions)** |
| `bash scripts/orchestrator-harness/claim-orphan.test.sh` | **150 passed, 0 failed** (re-measured twice at this head; the `145` first written here does NOT reproduce — the count is the run's own tail line, never carried) |
| `bash scripts/orchestrator-harness/lane-bound.test.sh` | **83 passed, 0 failed** — including arm (i0), which reads `DRAINER_LANE_TIMEOUT` out of the installer file this addendum edits |
| `node scripts/check-skill-lint.test.mjs` (with `/tmp/skills` present) | **171 passed, 0 failed** |
| `node scripts/check-pi-pin-lockstep.mjs` | **132 passed, 0 failed** |
| `bash scripts/check-bash32-parse.sh` | **471 scripts parse under bash 3.2.57** |
| `bash scripts/check-pipeline-compliance.sh` (local, `PR_NUMBER=4103`) | (a) ✅ · (c) awaiting the harness reviewer's head-bound record |
