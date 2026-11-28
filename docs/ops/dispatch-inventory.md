# Dispatch inventory — every way the harness starts work, and what stops it starting twice

**Issue:** agent-infra#4260 (§1 of its research mandate; the table below is that section, derived from the
code at `b526f3c79`, not from the issue text).
**Purpose:** answer one question — *when does the harness dispatch new work, for what, and is the thing it
de-duplicates on the resource the job actually consumes?* — and state the invariant, so that the
`branch-claim.sh` push guard (the subject of #4260) is judged against it instead of being widened by taste.

Every row below cites the line it was read at in `scripts/orchestrator-harness/`. Line numbers move; the
anchors (`[redfix:begin]`, `[gatevec:begin]`, function names) are what to search for when they do.

## 1. The table

`LANE IDENTITY` is the worker/session name, which is also the local identity every census on a box
(`reap_stale_workers`, the `^fix-` ceilings, the `[cap]` worker count, the cell supervisor's prune guard,
`wt_count`) uses. `DEDUP KEY` is the mechanism that is consulted *immediately before* the spawn — not a cap,
not a capacity reading.

| # | TRIGGER (exact condition) | LANE IDENTITY | DEDUP KEY | IS THE KEY THE RIGHT RESOURCE? |
|---|---|---|---|---|
| 1 | **Issue work.** A candidate in `candidates.txt` that is not in `dispatched.txt` (`orch-loop.sh:9778`), not in the live-worker set `INFLIGHT_ISSUE_SET` (`orch-loop.sh:9787`), not yielded by capacity transfer (`:9790`) and not placed on a peer (`:9813`), whose cross-box CAS `refs/claims/issue-<N>` is won (`orch-loop.sh:9829`–`9890`; `claims.sh` `claim_issue_acquire`) | `lane-<N>` → `chain-<N>` | **`refs/claims/issue-<N>`** (atomic push-CAS, cross-box) **+ `dispatched.txt`** (same box) **+ live `lane-<N>`/`chain-<N>` worker record** | **YES — the issue.** Three layers, and the coarse one is the durable one: the claim is the resource, the ledger and the census are fast paths. A refused item is NOT written to `dispatched.txt` and NOT put in `.batch`, so it stays a candidate for the next cycle with no blacklist to undo (`orch-loop.sh:9829` comment). |
| 2 | **Continuation of a stalled/died issue.** Same path as (1): a dead lane's item is freed by `dispatch-merge.sh` pruning `dispatched.txt` when the batch completes (`dispatch-merge.sh:103`–`107`), by the claim's lease/orphan arms (`claim-reaper.sh`, `claims.sh` `claim_prune`), and by the live-worker census no longer naming it | `lane-<N>` | same as (1) | **YES, with a stated freshness limit.** The key is the issue. What is time-based rather than liveness-based is *reclamation*: a holder whose box died is released by the lease or by the dead-host/orphan arms, which is the fleet's documented abstention doctrine (`docs/ops/fleet-liveness.md`) — an absence is not a verdict. This is deliberate, not a gap: a liveness test on the *holder* cannot be answered for a foreign box. |
| 3 | **Batch → chain.** `orch-loop.sh:10101` runs `dispatch-merge.sh "$REPO" "$OR" $(tr '\n' ' ' < "$O/.batch")` | `chain-<N>` | **Nothing of its own** — and that is correct: the issue claims were taken by the caller before the ids entered `.batch`, and `.batch` / `dispatched.txt` are written **before** the call (`dispatch-merge.sh:80`, `:304`, `:333`) | **YES by construction.** `dispatch-merge.sh` is a *consumer* of a key that is already held; it deliberately does not take a second key (`claims.sh` `claim_issue_release_record` releases the caller's). A re-entrant batch cannot double-dispatch an issue whose CAS the controller already won. |
| 4 | **Rail refusal → fixer** (the REDFIX role). `[redfix:begin]` … spawn at `orch-loop.sh:7188`, gated on `pr_owner_live` (`:7150`) and the `fix-` ceiling (`:7156`) | `fix-<PR>` | **`state/redfix-<PR>`** holds `"<head> <book>"` (`:7185`) — the head the refusal was about — plus `state/fixcount-<PR>` and `state/parked-<PR>` (head-valued) | **Head is right for the VERDICT, wrong for the MUTATION.** A rail refusal is a statement about a *tree*, so a new head invalidates it and must re-arm the role — correct. But the worker it spawns consumes the **branch**: its output is a push. See §3. |
| 5 | **NOCHECKS re-read** (`orch-loop.sh:7392`), which resolves the unreadable surface by re-reading the run list and then re-enters the ordinary arms | (no worker of its own) | `state/nochk-breaker` (`:6652`, `:7398`) bounds the re-read; the result then flows into rows 4/6/7/8 | **YES (nothing is dispatched here).** It is a classifier repair, not a dispatch. |
| 6 | **CONFLICTED → rebase fixer.** `orch-loop.sh:7543`, gated on `pr_owner_live` (`:7520`) and the `fix-` ceiling (`:7523`) | `fix-<PR>` | **`state/conflictcount-<PR>`** — a PR-lifetime budget, **explicitly NOT head-keyed** (`:7498`–`7510`, with the reason stated in the code: a push does not re-arm it) — plus `parked-<PR>` | **YES — the PR/branch.** Coarse on purpose: the resource the rebase consumes is the branch's history, not one head. |
| 7 | **CI red → fixer.** `orch-loop.sh:7787` (gate-hit arm) and `:8062` (`CI_RED` arm), both gated on `pr_owner_live` and the `fix-` ceiling | `fix-<PR>` | **`state/fixcount-<PR>`** — PR-lifetime — plus `state/needsfix-<PR>-<head>` (`merge-one.sh:2522`, `:2550`) and `parked-<PR>` | **YES — the PR.** The budget is deliberately the PR's, so two heads cannot each "start fresh" forever; the findings marker is per head because findings are per diff. Both granularities are used, each where it belongs. |
| 8 | **Review.** `orch-loop.sh:7967` spawns `review-<PR>` (which is `merge-one.sh`), gated by `review_disp_decide` (`:1982`) on **`state/reviewdisp-<PR>` = `"<head> <n>"`** (`:1935`, `:1977`), by the review-at-head refusal (`:7831`, `review_athead_bump`), by `review_round_remaining` (`:2149`) and by `state/needsreview-<PR>-<head>` | `review-<PR>` | **`(PR, head)`** — head is in the key | **YES — a review consumes a DIFF.** A new head is genuinely new work, so head-keyed is the *correct* granularity here, and the round ceiling is what stops it becoming an infinite loop. This is the row that shows "keyed on the head" is not a defect by itself. |
| 9 | **Landing.** `orch-loop.sh:7614` spawns `merge-<PR>` when `MERGE_AUTHORITY=rail`, or `:7630` runs `gh pr merge --squash` and `:7648` `gh pr merge --squash --auto` when `MERGE_AUTHORITY=gate`; preceded by `claim_selection_verdict "$PR" "$HEAD_N"` (`:6844`) | `merge-<PR>` | **rail arm:** `pr_owner_live` (`:7602`) + `state/mergeclaim-<PR>.lock` (inside `merge-one.sh:643`) + `refs/claims/pr-<N>` (`merge-one.sh:843`) + `refs/claims/<PR>-<head12>` (`:890`). **gate arms:** **NONE** — re-issued every cycle until the PR leaves the open set | **Rail: YES** (PR at a head; the local lock plus two durable claims). **Gate arms: NO DEDUP**, and that is defensible only because `gh pr merge` is idempotent at GitHub and the PR leaves the listing once merged — a *state* fact, not a key. `pr_owner_live` is LIVENESS, not identity: it stops a second worker while one is running, and says nothing about "this head was already taken to the rail" once the worker exits. |
| 9b | **Draft → ready.** `orch-loop.sh:6762` (and the unconditional `gh pr ready … \|\| true` at `:7570`/`:7646`) | (no worker) | **NONE** — a failed `ready` is simply retried next cycle (`:6765`) | **NO KEY, and none is needed:** idempotence is GitHub's, and the cost of a retry is one API call. Recorded so the inventory is closed, not as a defect. |
| 10 | **CI re-run actuator.** `orch-loop.sh:8110`–`8118` (`gh run rerun --failed`), gated on `python-ci-gate` in the check set and on `state/rerun-<PR>-<RID>` | (no worker) | **`state/rerun-<PR>-<RID>`**, touched only on success (`:8119`) | **KEYED ON THE RUN — deliberately finer than the head, and it shows.** It answers "this RUN was already re-run" exactly, which is what the actuator consumes; it does NOT bound "this HEAD's CI has been re-run N times", so a second run on an unchanged head is a fresh key. Whether that matters depends on `rerun-*` pruning, which is **UNVERIFIED** in the reapers (`state/rerun-*` is not in the `MERGED\|CLOSED` sweep's list at `:6789`). |
| 10b | **Background backlog refresh.** `orch-loop.sh:10642` runs `refresh-candidates.sh` when the backlog is below 6 or the latch is stale (`:10374`) | (no worker) | **`$O/.refresh.lock`** (`mkdir` at `:10387`, stale-cleared at `:10648`) | **YES — the refresh job itself**, and it is a lock, not a claim (same box only). `refresh-candidates.sh` dispatches nothing; it also *reads* `refs/claims/issue-<N>` per candidate and queues only on an explicit `rc 0` (`:5770`–`5798`). |
| 11 | **Drain stall → diagnostician.** `orch-loop.sh:9459`–`9478`, firing only on `_stalled=1` | stall-fix worker | **`state/drain-stall`** pass counter (`DRAIN_STALL_FIX_EVERY`, default one pass in three) | **No identity key, and stated as such.** The resource is *this box's drain*, which no peer can consume, and the dispatch is read-only by contract (`stall-fix.sh` never touches a PR a lane holds). The bound is the pass counter, not a claim. |
| 12 | **Adoption of a sick/unowned PR** (`adopt-fix.sh`; the controller's pr-sickness role runs `ps_select` from `orch-loop.sh:8289`–`8323` (`[prsick-pass:begin]`) when `PRSICK=1`, and the spawn itself is `pr-sickness.sh:574`–`583` `ps_spawn_fixer`) | `fix-<PR>` | **`state/mergeclaim-<PR>.lock`** + `ps_held`'s `pr-<N>`/lease read (`pr-sickness.sh:434`–`438`) + **`state/psick-<PR>-<head12>`** (head-keyed budget, cap `PS_MAX_TRIES`) | **YES — the PR.** The lock's holder is provable-dead or the takeover refuses (`adopt-fix.sh:218`); the budget is per head because the work is a diff, and the pass-level `PS_MAXSPAWN` is a capacity ceiling beside it, not a substitute. |
| 13 | **Candidate refresh** (`refresh-candidates.sh`) | — | — | **It dispatches NOTHING.** It writes/refreshes `candidates.txt` and certifies an issue CLEAN by reading the registry; the code states that a certification is not a lock and the claim is (`orch-loop.sh:9828` comment). Listed here so the inventory is closed, not because it is a dispatch path. |

**Control structure, stated accurately.** The PR sweep is **one pipeline subshell** — `printf … | while IFS=$'\t' read -r PR BR DRAFT OWN` (`orch-loop.sh:6745`) to `done` (`:8234`) — and inside one row the arms are a **precedence ladder of row-owning guards, each of which writes a `disp` row and `continue`s**, not an `elif` chain. Order per row: draft (`6762`) → `MERGED|CLOSED` marker sweep (`6788`) → **the cross-box claim gate `claim_selection_verdict` (`6844`), which applies to every arm below** → `[redfix]` (`6913`–`7226`, owns the row via one gated `continue`) → parked guard (`7292`) → `AUTHORITY_UNKNOWN` (`7339`) → classifier (`7349`, empty ⇒ `NOCHECKS` at `7380`) → `CONFLICTING` router (`7480`) → `case "$V"` (`7563`: `GREEN`/`PENDING`/`FAILED`, and inside `FAILED` the review-gate chain `7704`–`8014` then the CI-red arm `8015`–`8075`) → **the rerun actuator after the chain (`8085`–`8129`), so two actuators can fire on one PR in one cycle** → tail arms (`8131`–`8212`).
The `[gatevec:begin]` block at `8987`–`9149` (#2924/#2927) is the **issue path's** gate vector, not the PR arms: there the `elif` chain was replaced by independent first-wins guards that assign `GATE_WHY` only if still unset and append every arm's verdict to `GATE_VEC`, so "which gate refused this cycle" is a vector instead of one masked string. The order inside the PR ladder is load-bearing in the same way: the durable claim decides **before** any arm acts, and REDFIX runs **before** the parked guard, because a parked head is exactly the head nobody will repair.

## 2. The invariant, in one sentence

> **No two workers may move the same resource at once: every dispatch is keyed on the resource whose next
> state it will produce — the ISSUE for issue work, the (PR, head) for a review or a landing, the PR for a
> repair budget, the CI RUN for a re-run, and the BRANCH for anything that pushes — and every such key is
> enforced at the point of mutation, not merely at the point of dispatch.**

## 3. Which triggers violate it

**Every fixer arm** — rows 4, 6, 7, 8's findings remedy, and 12 — violates the second half of the invariant
for any PR branch outside the push guard's scope.

The dispatch side of these arms is *already* keyed at the right granularity. This is not an inference: it is
what `fix-one.sh:798`–`808` records and implements. The per-head claim (`refs/claims/<PR>-<head12>`) cannot
stop the #3696 writer, because **its push creates a new head**, so it takes a fresh key and wins its own CAS
every time (measured on tortoise PR #11385: 11 superseded heads, five clean reviews on five different heads,
zero landings). The coarse key that answers the real question — *does another lane own this BRANCH right
now?* — is `refs/claims/branch-<slug>`, and `fix-one.sh:874`–`900` takes it **first, before the fixer runs**.
`branch-claim.sh:60`–`67` records the property that matters here: **the acquire is pattern-independent** —
`fix-one.sh` claims whatever branch it was handed.

So the key exists, is coarse enough, and is taken by every fixer. `refs/claims/branch-<slug>` is acquired at
**exactly one site in the tree** — `fix-one.sh:879`, after the PR-owner lock (`:753`) and before the head claim
(`:952`) — and released by its EXIT trap; `merge-one.sh` never takes it, because the fixer's chain hands over
the PR lock instead (`fix-one.sh:1428`). What is narrower than the key is the **guard**: `claim_branch_guard` is only consulted for branches matching `BRANCH_CLAIM_PATTERN`
(`branch-claim.sh:57`, `:196`), defaulting to `integration/* fix/* rescue/*`. For a `feat/*`, `pr-go/*`,
`design/*`, `scope/*` or `…-tm` branch the claim is taken and enforced against *peers' acquires*, but the
push itself is unguarded — and the measured population was on exactly those prefixes (6 of 10 open PRs).
`branch-claim.sh:68`–`74` already states this direction honestly ("the claim still refuses a peer's
`acquire`, and an unguarded push is simply the status quo"); #4260 is the issue that says the status quo is
the defect.

**Therefore the fix belongs in the guard, not in the dispatch key.** A dispatch-side change would be a second
implementation of a key that already ships and is already at the right granularity — the #4228 failure mode.
The guard is the *backstop* for the one thing dispatch-time keying cannot cover: a worker that acquired the
branch and then a **second** worker that pushes onto it without acquiring (a human, a script, a lane from an
older deployment). That backstop must be in front of every branch a lane can write — and, per #4260 §3(b),
installed on every box that can write one.

### 3.1 What widening the scope costs — the fail-closed arms, stated

Widening the guard from three prefixes to **every** non-trunk branch is not free, and the bound is narrower
than "an unclaimed branch is never refused". That sentence is true **only for the `unclaimed` arm**. Before
ownership is decided at all, `claim_branch_guard` (`claims.sh`) has five REFUSAL arms that fire on their own:

```
registry-unreadable         `git ls-remote origin "$ref"` non-zero            -> rc 2
claim-unreadable            the claim ref exists, its lease is unreadable     -> rc 2
clock-unreadable            the local clock cannot judge the lease             -> rc 2
lease-unreadable            the lease term does not parse                      -> rc 1
claim-expired-unreclaimed   expired but not reclaimed                         -> rc 1
```

and `branch-claim-hook.sh` refuses on **any** non-zero.

⇒ **The cost of the widening, in one sentence: a box whose claim registry is momentarily unreadable — a
network/DNS blip (a cell can be unreachable for hours), a git/`gh` outage, or a checkout whose remote is not
literally named `origin` (the ref is hardcoded `origin`, and the hook forwards only `$remote_ref`) — refuses
every push to every non-trunk branch on that box until it clears, where the old three-prefix default refused
three prefixes.** Hooks are **per repository, not per worktree** (`git rev-parse --git-path hooks` in a linked
worktree resolves the COMMON hooks dir; `git-worktree(1)`: "sharing everything except per-worktree files such as
HEAD, index"), so one `install-hook` arms every worktree of that repo on that box — which is why the blast
radius is a box-wide statement, not a checkout-local one.

Fail-closed is the intended polarity and is **not** changed here: an abstention is not permission, and the
alternative — a momentary outage silently permitting a stray push — is the exact loss this guard exists to stop.
What is being closed in this paragraph is that the change shipped on a sentence its own callee refutes.

## 4. What already ships (checked, not assumed — #4260 §2)

| Mechanism | State in the tree at `b526f3c79` | Evidence |
|---|---|---|
| Issue-keyed claims (#1871, shipped 2026-10-16) | **PRESENT** | `refs/claims/issue-<N>` CAS at `orch-loop.sh:9829`–`9890`; `claims.sh` `claim_issue_acquire` / `claim_issue_release_record`; `dispatch-merge.sh:50`–`72` releases through it |
| The already-resolved guard (#4190, `fixgate-prresolve`) | **PRESENT** | `fix-one.sh` `[fixgate-prresolve:…]` markers + its own suite `fix-one-prresolve.test.sh` |
| P3-only findings → an advisory record, no fixer (#4241 → #4242) | **PRESENT** | `state/advisory-<PR>-<head>` tested at `orch-loop.sh:7877`; `review_round_remaining` (`:2149`) deliberately does not count advisory records (`:2143`–`2150`) |
| Branch-keyed claims (#3328 / #3696) | **PRESENT** — acquire is pattern-independent, guard is prefix-scoped | `branch-claim.sh:57`, `:107`, `:196`; `fix-one.sh:874`–`900` |

Nothing in this inventory proposes to re-derive any of the four.

## 5. Open questions this inventory does NOT settle

- **Row 2's freshness** is bounded by a lease, not by a liveness proof, for a foreign box. That is the
  abstention doctrine, not a bug, and it is not in #4260's scope.
- **Row 11** has no identity key. It is read-only by contract; if `stall-fix.sh` ever gains write actions,
  this row is where the key must be added.
- **The guard's INSTALL COVERAGE — the FIRST half of #4260 §4.2 — is not closed by this change, and the residual
  is stated rather than implied.** §4.2 asks two things: how does every checkout on every cell get the hook, and
  how is that proven. This change delivers the second half. Measured at this head:

  ```
  $ git grep -n 'install-hook' -- ':!*.test.sh' ':!*.md' ':!branch-claim.sh' ':!branch-claim-hook.sh'
  cloud-cell-doctor.sh:2529   # a comment ABOUT it
  install.sh:1730             # a comment ABOUT it
  ```

  **Zero callers.** `install.sh` seeds `branch-claim.sh` and `branch-claim-hook.sh` into `$O` — that is the
  *script*, not the *hook*: a seeded `$O/branch-claim.sh` leaves `$REPO/.git/hooks/pre-push` absent. So the
  cells that were unarmed **stay unarmed** until a provisioning step or an operator runs
  `bash <tree>/scripts/orchestrator-harness/branch-claim.sh install-hook` in the checkout the box pushes from.
  What changed is that the absence is now **named**: `cloud-cell-doctor.sh hygiene` records
  `branch-claim hook NOT ARMED in <repo> — HOOK-FAIL <host> MISSING (...)`, whose parenthesised text carries the
  remedy command, on every scheduled pass — instead of nobody being able to say which cell was unarmed. Every
  comparable splits the same way: `pre-commit`/`lefthook` expose an explicit `install` verb for a provisioning
  step to call, and CI invokes the check directly rather than reading a fresh clone's missing hook as a fault of
  the machine.

  **Where the arming step belongs** (not done here — it changes a box-bootstrap path, not the guard): the
  provisioning that seeds `$O` — `install.sh` for the macOS orchestrator, `cloud-cell-supervisor.sh apply/start`
  for the cells — is what would run `install-hook` against `$REPO` and let `check-hook` gate the result.
  ⛔ **AND IT MUST RUN THE DEPLOYED `$O/branch-claim.sh`, NOT A PIN'S COPY.** `install-hook` bakes
  `$SELF_DIR/branch-claim.sh` into the hook, and `cloud-cell-supervisor.sh prune` deletes old harness pins —
  so an arming step run out of a pin directory would leave a hook naming a path that is later removed, which
  is the `GATE-ABSENT` shape the verifier exists to catch and which **refuses every push on that box**. The
  stable gate path is the seeded `$O` copy; that is the one to install from.
  ⛔ **AND THE VERIFIER NO LONGER WAITS FOR `prune` TO NOTICE (review P1).** `check-hook` byte-compares the
  gate the hook names against the `branch-claim.sh` beside it (`GATE-STALE`) and the hook itself against
  `branch-claim-hook.sh` (`HOOK-STALE`). Before that, the window between installing from a pin and `prune`
  deleting it was a FALSE PASS: the hook was present, executable, ours, parseable and resolvable while the
  gate it baked carried the pre-#4260 three-prefix scope — `HOOK-OK` about a box that was still ungated,
  which is the fleet reading the measured defect as fixed. It is a CONTENT compare, not a path compare, so a
  byte-identical copy at a pin's or a consumer repo's path stays green.
  Until then the doctor row is an OBSERVATION with a printed remedy, and an unarmed cell is a known-absent
  state, not a fixed one.
