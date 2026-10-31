---
title: "Orchestrator harness — autonomous lane dispatch and merge rail (`~/orchestrator`)"
type: operations
domain: platform
created: 2026-10-12
ownedBy: organisation-design-team
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: daniel-ospina/tortoise, tortoise#8246, daniel-ospina/agent-infra, agent-infra#1700, agent-infra#1712
doc_status: draft
---

# Orchestrator harness

> **Component reference:** [`ARCHITECTURE.md`](./ARCHITECTURE.md) — per-script I/O and failure
> surface, the state-file lifecycle, the gate constants, triage and invariants. This file remains
> the authority for provenance, install, merge policy and measured results.

> **What this is.** A self-contained, single-host harness that turns one laptop into an
> autonomous delivery lane: it sweeps the open PR queue, dispatches GitHub issues into
> isolated worktrees as autonomous `pi` lanes, runs a fresh-context review → signed-record
> → merge chain on each result, and repairs the PRs whose reviewer found real problems.
>
> **Where it came from.** Built ad hoc in `~/orchestrator/` on one box during the
> 2026-10-10 → 2026-10-11 run that merged ~99 PRs (77 of them between
> `2026-10-10T23:45Z` and `2026-10-11T21:22Z`). It was never version-controlled. It was first
> versioned in tortoise as `operations/orchestrator-harness/` (PRs #8251, #8308, #8329, #8298;
> tracked by tortoise#8246) as the handover so it could be **evaluated** before being adopted.
>
> **Where it lives now.** `agent-infra/scripts/orchestrator-harness/` (relocation:
> agent-infra#1700). The home is agent-infra because this is fleet/agent operations, not
> tortoise product code — the merge rail it sits alongside (`admin-merge.sh`, `atomic-land.sh`)
> and the fleet's box-level script `cadence-nudge.sh` are already in `agent-infra/scripts/`, as
> are the multi-file tool subdirectories `checkout-hygiene/`, `ci/` and `gh-shim/`. Three scripts
> this same change versions into that directory existed only in local config before:
> `ci_runner_gate.sh` (the CI runner-label fallback gate), `cloud-cell-bringup.sh` (cell bring-up)
> and `cloud-cell-supervisor.sh` (the per-cell launcher — on a cell it is what starts this
> controller, since launchd is macOS-only).
> The old tortoise path
> (`operations/orchestrator-harness/`) is replaced by a stub pointer to this home in a follow-up
> tortoise PR that opens only after this one merges — tracked by tortoise#8432 (the relocation
> issue); until that PR lands the old path is a stale duplicate, so do not run it.
>
> ⛔ **Every post-copy change through tortoise `ef59f6d6f` has been PORTED here (agent-infra#1712),
> and that port is the precondition for removing the tortoise copy.** This directory is a
> point-in-time copy taken at 2026-10-13 05:50 local (= 10:50Z) from tortoise `0e060082f`. **Eight**
> tortoise commits touching this directory merged between `0e060082f` and `ef59f6d6f`
> (2026-10-13T15:48:33 local) — the declared port point — and all eight are present here:
>
> | commit | tortoise | what it carries |
> |---|---|---|
> | `8fe1e7b13` | #8437 | core-derived load ceiling, `MIN_MEM_FREE_MB`, the dead `REPO` default corrected — `orch-loop.sh`, `install.sh`, `refresh-candidates.sh`, `launchd.plist.template`, `README.md`, `selftest.sh` |
> | `a59858d07` | #8465/#8467 | dispatch pool ordered by **severity**, not issue number — `refresh-candidates.sh` + `selftest.sh` |
> | `ff6d1bc19` | #8471 | the follow-up that makes #8465's self-tests discriminate — `refresh-candidates.sh` + `selftest.sh` |
> | `77a0c32bd` | #8515 | `checked.txt` written only on the terminal CLEAN verdict (agent-infra#1716) — `refresh-candidates.sh`, `selftest.sh`, `README.md` |
> | `b559cb02a` | #8516 | INT/TERM `exit` rather than returning from the trap, so the lock and the process end together (agent-infra#1715) — `orch-loop.sh` + `merge-one.sh` + `selftest.sh` |
> | `45dd16cc8` | #8519 | a FAILED PR listing is not an EMPTY one; the reaper fails closed (agent-infra#1705) — `refresh-candidates.sh`, `selftest.sh`, `README.md` |
> | `26f6c9488` | #8514 | portable load/swap/mtime/memory probes and `nproc` core count, so the Linux cell controller runs (agent-infra#1702) — `orch-loop.sh`, `install.sh`, `selftest.sh`, `README.md` |
> | `ef59f6d6f` | #8518 | required checks classified by **allow-list polarity**, not a deny-list, so an unrecognised or null conclusion is red rather than reading `PENDING` (agent-infra#1714) — `orch-loop.sh`, `fix-one.sh`, `selftest.sh`, `README.md` |
>
> ⚠️ **A COUNT is the wrong anchor; the SHA is.** Three different counts were each correct at a
> different moment while this port was being written: `26f6c9488` and `ef59f6d6f` both landed
> *between* a fetch of `origin/main` and the commit built on that fetch, so even a freshly-read ref
> was stale by the time it was used. The instruction for any future copy is therefore: **re-fetch,
> diff the tortoise tree against this one at that moment, port everything not present, and record
> the SHA you ported to here.** The removal PR must re-run that diff against the then-current
> tortoise tip: a port is only complete *relative to a declared sha*, and removing the tortoise copy
> while any delta remains deletes the only tree carrying that fix.
> The last of them merged at 15:16 local **while this port was being written**, which is the point:
> a hand-kept list only catches what its author already knew. Two guards exist instead of a list.
>
> 1. **`port-provenance.txt`** pins the tortoise blob hash of every file at the port's sync point,
>    and **`check-port-drift.sh`** fails if the tortoise tree no longer matches it, naming the file.
>    Run it before the follow-up tortoise PR removes anything:
>    `./check-port-drift.sh --tortoise /path/to/tortoise`.
> 2. **The ported `selftest.sh` checks are the anti-regression guard** — each of the seven commits
>    added checks that are RED on the pre-fix tree (16 for #1702 alone), so a reverted port fails the
>    suite rather than merely looking different.
>
> ⚠️ **The follow-up has a second obligation the sha list never covered.** tortoise's **open**
> branch `fix/8468-closure-linkage` also rewrites this directory (severity-ordered pool, a
> `.prio`-keyed P0 bypass of the merge-priority gate, `merged-not-closed.sh`, a `Closes`-not-`Refs`
> lane brief). This PR ports it: `merged-not-closed.sh`, the severity-ordered pool and the
> `Closes`-not-`Refs` lane contract are in, and **the `.prio`-keyed P0 bypass is NOT** — main's
> merge-priority rule became unconditional (owner ruling, 2026-10-18), which supersedes it; see
> "Ports taken from the retired fork" below.
>
> ⚠️ **This port is faithful EXCEPT for a declared set of fail-open / false-PASS fixes.** These are
> agent-infra's, not tortoise's — a later diff between the two trees WILL show them, and they must not
> be read as lost work in either direction:
>
> | divergence | why it is here |
> |---|---|
> | `orch-loop.sh` guards **every** limit with `is_limit` (digits **and** at most nine of them) before its first arithmetic read — `MAX_LANES`, `MAX_REVIEW`, `MERGE_PRIORITY_AT`, `MAX_FIX`, `MAX_FIX_TRIES`, `BATCH`, `CYC`, `STALE_MIN`, `SWEEP_MAX_AGE`, `SWEEP_MIN_REMAIN` (and `MAX_LOAD`/`MIN_SWAP_FREE`/`MIN_MEM_FREE_MB`, which had `is_num`: the first two are plist-supplied gates that `[` would ERR on at or above 2**63, the last is plist-supplied too, so all three moved to `is_limit`) | two failure modes, both fail-**OPEN**: `[ -ge ]` on a non-number is FALSE and FALSE in the gate chain ALLOWS, so `MAX_LANES=4x` dropped the lane cap, `MERGE_PRIORITY_AT=notanum` removed the drain-before-dispatch gate, `BATCH=abc` dispatched the whole backlog in one cycle, and `MAX_FIX_TRIES=abc` let fixer attempt 10 run past a cap of 3. `[` also ERRORS at or above 2**63, so an absurd-but-numeric limit opened them the same way. `is_num` itself stays unbounded for an **epoch mtime** (already 10 digits), but `_NCPU` is now `is_limit` too: its source is the host (`sysctl`/`nproc`), not the plist, so an absurd-but-numeric probe reached `$(( 10#$_NCPU * 10 ))` and WRAPPED — 99999999999999999999 to 3875820019684212726, 19 digits but still BELOW 2**63-1, so `[ -ge ]` does NOT ERROR: it simply never binds and the gate OPENS **silently** (the earlier wording said `[ -ge ]` ERRORS here — corrected, fifth review round 2026-10-14) — and 2**63 to exactly 0, which `is_limit` ACCEPTS because install.sh allows 0 for every limit but CYC (`[ "$L" -ge 0 ]` is always true, so the gate CLOSES and the box dispatches nothing). `install.sh` now mirrors the loop's guard (`is_limit` + the `_NCPU >= 1` probe guard + the two MAX_LOAD guards) because install.sh is what substitutes `__MAX_LOAD__` into the live plist — the wrap survived there on the real production path |
> | `orch-loop.sh` reads base 10 where it read base 8 | `$((MAX_REVIEW + 2))` read `030` as **octal** (26, not 30) and `$((STALE_MIN * 60))` did the same. `MERGE_PRIORITY_AT` already normalised with `10#` |
> | `install.sh` refuses a non-integer, an out-of-range value, or a value carrying a `__TOKEN__` | `MAX_LANES=4x` was written into the live launchd plist and `install.sh` exited 0, so the plist lied about the ceiling; and the sed rules run in order, so `OR=__MAX_LANES__` rendered as the default (then a literal `4`, now 2.5× cores) — exit 0, valid XML, and the daemon then ran `gh --repo <default>` |
> | `install.sh` renders to a temp file and `mv`s it into place, and asserts no `__…__` survived | the redirect truncates `$PLIST` **before** `sed` runs, so rejecting after writing straight to it left the live plist empty or poisoned — and §9's next step (`launchctl unload && load`) then failed, so a rejected re-install destroyed a working daemon config. `plutil -lint` cannot see a substitution that did not take |
> | `install.sh` creates the plist's directory (`mkdir -p "$(dirname "$PLIST")"`) | an agent-infra addition, not a lost tortoise line: a sandboxed or first-time `HOME` has no `Library/LaunchAgents` and the redirect then died |
> | `selftest.sh` pins the documented default of every host-independent limit, drives the swap gate with real swap (`SWTOTAL` != 0) **and** a non-default ceiling, drives `install.sh` instead of grepping it, and extracts the coercion lines to RUN them | the default-agreement check could not see both files drifting **together**; `SWTOTAL=0` short-circuits the swap gate before the comparison; a source-text pin survives the guard being disabled (`if false && grep …`); and a fixture that re-implements the pattern in the test asserts nothing about the shipped code |
> | `orch-loop.sh` moves the sweep's PR **listing** to a conditional REST call (`gh api --paginate -i` + `If-None-Match`, ETag in `state/sweep-etag`, age floor `SWEEP_MAX_AGE`) and takes its rate-limit signal from the **response headers** (`x-ratelimit-remaining`/`-reset`/`Retry-After`) rather than `/rate_limit`; the `# BEGIN sweep-quota` helper block (`sweep_fail_kind`/`sweep_defer_until`) and the new `sweep-quota.test.sh` are agent-infra-only (and the ported `selftest.sh` gains the section that runs it, with its coercion-count pin) | a `304` is not charged to the primary rate limit, so the listing is free, and the `/rate_limit` counter was measured reporting `graphql 4933/5000` while **every** GraphQL call failed — a cell that cannot list PRs cannot merge and read as idle-but-fine (agent-infra#1762). tortoise still carries the polling sweep, so a faithful port must not delete this block as "unported work": port it or keep it |
>
> The upstream-logic defects found in the same review are **not** diverged here; they are tracked
> instead — `fix-one.sh`'s spaced-check-name word-splitting (agent-infra#1703) and the classifier's
> inert `(app, name)` grouping (agent-infra#1733) are still present, matching tortoise.
> `can_spawn()`'s load-only gate (agent-infra#1732) is the one that is now DIVERGED: the memory arm
> is agent-infra's, and tortoise still carries the load-only form until it is ported.
>
> **Status: evaluation artifact.** Nothing here installs or runs on its own. `install.sh`
> renders a launchd plist and *prints* the load command; it does not execute it.
> Tracked by tortoise#8246.

---

## 0. Requirements and intended behaviour

> **Status.** Owner-stated requirements, recorded 2026-10-16 after this harness was found **dormant
> while a superseded dispatcher was live** on the same box. This section is the authority for *what
> the system is for*; §2 and [`ARCHITECTURE.md`](./ARCHITECTURE.md) describe how the current code
> meets it (and §0.3 where it does not).

### 0.1 The fleet

One orchestrator per machine, each focused on **one repo**. Other repos may be open on the box; the
orchestrator and its heartbeat dispatch to exactly one.

| machine | repo |
|---|---|
| new laptop | `daniel-ospina/tortoise` |
| girlfriend's laptop | `daniel-ospina/tortoise` |
| cmux cloud cell 1 | `daniel-ospina/tortoise` |
| cmux cloud cell 2 | `daniel-ospina/agent-infra` |
| cmux cloud cell 3 | `daniel-ospina/tortoise` |

⚠️ **This table is the intended mapping, not a measured one.** Measured 2026-10-17 it does not hold: cell-2 holds *both* checkouts and ran tortoise merges all evening, and **cell-3 has no tortoise checkout at all**. The mapping must be **verified by the box**: raised in agent-infra#1901 (**closed** 2026-10-17, which made the queue/checkout pair *refusable* instead of silently wrong), with the residue — which machine actually serves which repo — carried by open agent-infra#1906.

A **second controller on one box is harmless, not forbidden**: it exits immediately on the
single-instance lock. No mechanism is needed for it.

### 0.2 What the system must do

| # | requirement |
|---|---|
| **R1** | A heartbeat checks capacity every cycle — cpu, ram, swap, **disk** — and dispatches only when there is capacity. |
| **R2** | It works **un-owned PRs first**: fix them, or run the merge path, to get them merged. |
| **R3** | Only when no un-owned PRs remain does it take the next un-owned **issue**, in label order: **P0 → P1 → P2 → P3 → oldest with no P label**. |
| **R4** | "Un-owned" is decided by **cross-machine coordination**, because several machines work the same repo. |
| **R5** | **There is no blocked item.** Anything stuck is either fixed automatically or becomes a **user question** (the AGENTS.md question protocol). The same applies to issues. ⚠️ **Sequence:** while the question gate is unbuilt, `parked-*` remains the de-facto terminal state — **build the escalation path first**, then retire the park. (The gate's two language marks landed in agent-infra#1903, closed 2026-10-19; the path itself is still unbuilt, §0.3 R5.) |
| **R6** | The drain rule is **threshold-free**: while **any** workable un-owned PR remains, the box drains the PR queue and opens no issues (owner ruling 2026-10-18, agent-infra#2099 — `mp_reason`, `orch-loop.sh:1520-1531`). `MERGE_PRIORITY_AT` (default 25) is **not** the gate any more: it survives as the **unreadable-count fallback** (`orch-loop.sh:2354` is the code — `is_num "${UPN:-}" \|\| UPN=$(( 10#${MERGE_PRIORITY_AT:-25} + 1 ))`; the rule it applies, "treat the count as over the line", is stated in the comment at `:220-222`) and as the reviewer/fixer headroom (`review_slots`/`fix_slots`, `:1596-1614`). |
| **R7** | One repo per orchestrator; the harness is single-repo by construction (`REPO`, which has **no default** and is refused when unset — `orch-loop.sh:15`). ⚠️ `OR` is **derived from `REPO`'s origin** at `orch-loop.sh:59` and is deliberately **overridable** (an explicit `OR=` still wins, for a cell that must grade another repo's queue), so `OR` is not the construction. |
| **R8** | **Capacity transfer:** when a machine refuses an item for *capacity*, the item remains eligible for **another** machine. Without this, per-machine correctness becomes fleet-wide starvation (agent-infra#1909). |

### 0.3 Where the current code does not meet them

| req | gap |
|---|---|
| R3 | the pool queries **three** labels — `P0-blocker`, `P1-severe`, `P2-moderate` (`refresh-candidates.sh:1843-1850`) — so the **P3** tier in R3's ladder is never dispatched, and the unlabeled-oldest tier is not implemented either. Carried by **two open** issues: agent-infra#1849 (order the pool strictly P0→P1→P2→P3→P4, with an OLDEST-first fallback when a repo has no priority labels) and agent-infra#1786 (the pool is keyed on three hardcoded labels, so a repo with its own severity vocabulary gets a silently empty pool). Both name this pool, not a neighbouring one; neither is closed. |
| R5 | `parked-<PR>` / `parkreason-<PR>` are terminal **at that head only**: the file holds the head it parked and the sweep skips the PR only while that value equals the current head (`orch-loop.sh:2899`), so **any push re-arms it** — and a rail park lifts itself, with no push at all, when the surface goes non-red (`orch-loop.sh:2625-2655`). `MAX_FIX_TRIES` (3) is one of several caps, not the terminal rule: `MAX_RED_FIX_TRIES` (2) parks a red tree at that head (`:2821`), and `MAX_FIX_TRIES` also bounds conflicts (`:3008`) and needs-fix (`:3170`). What is missing is the **destination**, not the cap: `scripts/ask-owner.py` is referenced **zero times** by `orch-loop.sh` / `merge-one.sh` (`rg -c ask-owner` finds no line in either) — the escalation path is unbuilt. |
| R2 | the sweep is state-driven (check status); ownership *is* consulted via `claim_live`, but it is not itself the selection criterion. |
| R1 | disk is enforced in `spawn-gate.sh` for **spawning**, but it does not reach the controller's own writes (heartbeat `orch-loop.sh:850`, `state/*`) — and a full disk does **not** kill the loop: `orch-loop.sh` sets `set -u` and never `-e` (`:4`), so a failed write fails that write only. The half that stays silent is the heartbeat: an unwritable `$O/state` at least leaves a tombstone the dispatch line reads back as `[dispatch] BLOCKED: a refresh pass finished and could not record its outcome` (`orch-loop.sh:1178-1209`), while `heartbeat()` is a bare `date +%s > "$O/heartbeat"` whose failure nothing reports. ⛔ **And the gate is not source-only any more**: since agent-infra#1884 `spawn-gate.sh` also ships THE SPAWN POINT — installed as `$HOME/.pi/agent/bin/pi`, first on PATH — so every caller that resolves `pi` through PATH is gated without cooperating (`spawn-gate.sh:491-530`), and `merge-one.sh` treats that refusal (rc=76) as *no verdict*, not as a review (`merge-one.sh:717-733`). The residues the code itself names: `merge-one.sh`'s own `run_agent()` copy gets the LOAD gate at the spawn point but **not the DISK gate** (`spawn-gate.sh:15-21`), and **neither `orch-loop.sh` nor `install.sh` sources the file** — but for different reasons, and only one of them keeps all three predicates: the loop keeps its own `is_num`, `is_limit` and `can_spawn` (defined at `orch-loop.sh:135` / `:142` / `:1459`) and applies `can_spawn` at **six** sites — `orch-loop.sh:2829`, `:3013`, `:3052`, `:3150`, `:3173`, `:3224` (counted with `grep -n can_spawn orch-loop.sh`, which returns those six call sites plus the definition and one comment; `spawn-gate.sh`'s own header still says "four DECISION sites" and that count is stale — it is not the count used here) — while `install.sh` keeps only `is_num` and `is_limit` (`:54` / `:63`), defines **no** `can_spawn`, and gates no spawn at all — it renders `MAX_LOAD` into the plist (`spawn-gate.sh:22-25`). |
| R8 | ✅ **met** — kept listed so the delivery record stays with the requirement. **Transfer (the yield):** `lane.sh:135` records a capacity refusal and `capacity_yield_live()` (`orch-loop.sh:1634-1652`) makes this box stand down **without consuming the item** — no `dispatched.txt` row, no claim (`:3687-3693`) — so a peer can take it immediately (agent-infra#1909, closed). **Placement (the half this row used to call missing — it ships):** the loop reads the whole fleet and asks `cap_place` which box should take the work (`orch-loop.sh:3424-3433`, which sets `CAP_STATE=place`/`CAP_PLACE`), and hands an item to the least-loaded eligible peer when this box is itself piling up — `CAP_LPC_SELF >= CAP_YIELD_AT_LPC`, default `400` = 4.00 load-per-cpu (`capacity.sh:106`) — left unclaimed and un-consumed so that peer can take it (`orch-loop.sh:3699-3707`; agent-infra#2252, PR #2253 merged). Two limits the code names itself, **not gaps in the requirement**: below the prefer-elsewhere line this box *takes* the work, because yielding every candidate to whichever peer is momentarily a little idler is a thrash machine (`orch-loop.sh:3699-3702`); and a `$O` that predates `capacity.sh` degrades to the LOCAL gates only — which is **loud, not silent**: the loop logs it every cycle (`orch-loop.sh:3436`) and `install.sh`'s whole-surface comparison records `deployedMatchesSource: false` with `capacity.sh(differs-or-missing)` (`:983` is the record, `:946-948` builds the `(differs-or-missing)` string, `:1001-1003` is the warning). |

**Delivery record — all four issues this paragraph used to call outstanding are CLOSED, and none of them owes an update to this section:** R5 → **#1903** (closed 2026-10-19, delivered by PR #1911: the two `ask-owner` language marks are now mechanical — and the residue is the *destination*, not the marks, since `scripts/ask-owner.py` is still referenced **zero times** by `orch-loop.sh` / `merge-one.sh`, so the escalation path is unbuilt and `parked-*` remains the de-facto terminal state, §0.3 R5) · R1 → **#1884** (closed 2026-10-19: the gate now ships the SPAWN POINT as `$HOME/.pi/agent/bin/pi`, and the residues `spawn-gate.sh`'s own header names remain — `merge-one.sh`'s `run_agent()` copy has no **DISK** gate, and neither `orch-loop.sh` nor `install.sh` sources the file, the loop keeping its own `is_num`/`is_limit`/`can_spawn` at the **six** `can_spawn` call sites the row above enumerates) · §0.1 → **#1901** (closed 2026-10-17: the queue/checkout pair is now compared and **refused** as `QUEUE_STATE=mismatch`, so the table above stands as this document's record of the *intended* mapping — and the residue, which box actually serves which repo, is open **#1906**) · §0.5 `SCOPE` → **#1908** (closed 2026-10-17; the measurement it asked for is §7.2d *Does a claim EXCLUDE?*, and the residue is the **landing** row's exclusion REQUIREMENT, which that measurement does not cover). **R8 owes nothing either: it is delivered** — the yield in **#1909** (closed) and placement in **#2252** (PR #2253, merged) — so it names no open issue; the row above is kept as that delivery record, and an earlier draft's "placement is missing" claim was false against `orch-loop.sh:3424-3433`. ⛔ **R3 names its carriers, R2 names none.** R3 is carried by open **#1849** and open **#1786** (row above) — an earlier draft called it filed nowhere, which was false. R2 alone names no issue: searched open issues 2026-10-22 for `ownership`, `state-driven`, `claim_live`, `un-owned`, `selection criterion`, `dispatch pool` and `oldest-first`, and no issue carries the gap as this row states it — the nearest hits are about ownership *signals* and liveness rather than the selection criterion (#1295, #2070) or about the missing PR **selector** rather than the criterion (#2330), so neither is a carrier. So nothing carries R2, and an earlier draft's claim that every gap was tracked was false for it.

### 0.4 Cross-machine coordination — guaranteed, and not

Guaranteed: a claim is an **atomic CAS in the shared repo**. There are **three key shapes**, and the
third is the one that fences landing:

| key | taken by | for |
|---|---|---|
| `refs/claims/<PR>-<head-sha12>` | a reviewing lane (the paid reviewer, via `merge-one.sh`) | reviewing **this head** of a PR |
| `refs/claims/issue-<N>` | a dispatching lane | opening a lane for an issue |
| `refs/claims/pr-<N>` | the landing path (`claim_pr_key`, `claims.sh:682`; `claim_pr_acquire`, `:772`; taken by `merge-one.sh` **first**, before the per-head claim) | landing **this PR**, whichever head it is on |

The lease is **data, not liveness**, so a dead box's claim expires; every release/reclaim is fenced
with `--force-with-lease`; each box reads a snapshot refreshed in one fetch per cycle. ⛔ The
per-head key **cannot express "this PR"**: two heads of one PR are two CASes and **both acquire**,
which is why the per-PR key exists on top of it.

**Not** guaranteed: exactly-once execution. The promise is **at-least-once with idempotent side
effects**, and that promise is **not uniform across operations** — the distinction decides whether a
duplicate is merely wasteful or destructive:

| operation | a duplicate means | verdict |
|---|---|---|
| **dispatch** (opening a lane for an issue) | a wasted worker; the side effect is idempotent per issue | tolerable |
| **landing** (merging a PR) | a **second landing attempt against a moved head** — the reviewed diff is no longer the diff being merged | **not tolerable**; which is why landing also takes the per-PR key `refs/claims/pr-<N>` (measured excluding, #1952/M6) — the per-head key cannot express "this PR" (M3) |

A claim *reduces* duplicate work; it does not prove mutual exclusion. Any design that assumes "a claim
means it runs once" is wrong (research: agent-infra#1709).

### 0.5 Inventory — required, additive, legacy

**Required** (implements a requirement): `orch-loop.sh` (R1, R2, R6) · `refresh-candidates.sh` (R3) ·
`dispatch-merge.sh`, `lane.sh`, `chain-merge.sh`, `merge-one.sh`, `fix-one.sh` (R2, R5) ·
`claims.sh` (R4) · `spawn-gate.sh` (R1).

**Additive — kept. Not owner-required, but load-bearing for correctness:**

| component | why it stays |
|---|---|
| `repo-authority.sh` | the per-repo merge contract; without it tortoise's required-check names are enforced on every other repo |
| `record-review.sh` + HMAC marker + `ai-review-gate` | the gate-mode repo requires a signed review artifact in the PR body |
| `admin-merge.sh` / `atomic-land.sh` | the only safe landing path for a behind head and for `--admin` |
| `selftest.sh` + the `*.test.sh` contracts | each pins one mechanism and is RED on the pre-fix tree; they caught real defects in contributed fixes |
| `check-port-drift.sh` + `port-provenance.txt` | gates removal of the tortoise-side copy |
| `check-deployed-drift.sh` | answers "which harness commit is this box running?" |
| `report.sh`, the wall-time series, the `[res]` line | cheap measurement — it is how the reviewer stall rate was found |
| `install.sh` + `launchd.plist.template` | renders config from one source, refuses an out-of-range value instead of writing it, and prints the start command **without running it** unless asked — `--start` starts **and proves it started** (pid + heartbeat), `--restart` is the un-wedging path (§0.6) |
| `nonblocking-dispatch.sh` | removes the blocking-caller problem |
| `worker-terminal.sh` | the ONE place a worker is launched, asked whether it is alive, counted and killed (`orch-loop.sh` / `dispatch-merge.sh` both source it). Without it a lane is a tmux window that dies at ~21 log lines (§2.1) |
| `capacity.sh` | R8's other half: MEASURED cross-box placement — load-per-core, lanes, disk and memory per box on the shared origin, so the next lane goes to the least-loaded ELIGIBLE box instead of to whichever controller asked first (§9) |
| `claim-reaper.sh` | R4's release half: a claim is released only when its holder is demonstrably GONE — 7 stale refs on a box with 0 live lanes made the fleet originate nothing (§7.2b, measured 2026-10-21) |
| `lane-container-reap.sh` | the leaked test-DB reaper (#2868): removes a lane's private `fdb-lane-*` / `*-pg` / `*-fdb` / `falkordb-6673-*` / `tortoise-ci-*` container ONLY when the owning lane is provably gone — the slug is absent from `git worktree list` (or the PR has no `refs/claims/` snapshot), no live process holds the name, AND the container is past the age bound. **Dry run by default** (`--apply` arms it); all three proofs must hold, and an unreadable `docker ps`/`ps` aborts the whole pass (exit 3, `CANNOT-VERIFY`) rather than reaping blind. Shared instances (`falkordb`, …) are protected by name and never candidates. Its test suite is a mutation suite: every deletion gate reddens when reverted |
| `live-ownership.sh` | R2/R3's predicate as a live fact: "owned" means a LIVE PROCESS is working the PR, not that a registry says so; it supplies the sweep order and the un-owned count (§7.2f) |
| `worker-supply.sh` + `install-worker-supply.sh` | the SUPPLY half of the repair pool (agent-infra#2700): the doctor CLASSIFIES orders and places at most one pass worth; without a supplier the pool empties and every later pass prints `undeliverable` with `inflight=0`. This re-offers the DEAD orders through the one dispatcher, on a 60 s clock, under the machine's own `fix + review` budget |
| `merged-not-closed.sh` | the question no other tool could answer — which OPEN issues already have a MERGED PR (tortoise#8468). Without it, finished work sits in the priority queue looking untouched |
| `cycle-record.sh` | the self-dispatch proof: one record per controller cycle, and a verdict that refuses to call an absent or stale record healthy (§9) |
| `repo-slug.sh` | the one `owner/name` resolver the controller and the candidate pool read; its one deliberate exception (`cloud-cell-supervisor.sh`'s own copy) is held in lockstep by `test-gates.sh`, not by prose |
| `repo-target.sh` | the ONE repo-identity assertion for a dispatch (agent-infra#2724/#2694): the target is an argument (`--repo`/`--repo-dir`, **no default**), and after the worktree exists its own `origin` and `git-common-dir` are compared with that target. A mismatch, an unreadable origin, or an absent target REFUSES (exit 72) naming **both slugs**; the branch half refuses a branch the target repo does not have, so `cannot materialise <branch>` is never the first line a human reads. Sourced by `lane.sh`, `dispatch-merge.sh`, `fix-one.sh` and `adopt-fix.sh`; a `[repo-target]` line per assertion (identity, and branch when a branch is asserted) makes a wrong-repo lane a grep — a dispatch that refuses after its identity line reads `result=REFUSED` on its LAST line. ⛔ A mirror/`file://` origin cannot name its repo, so such a checkout refuses EVERY batch (72) and `OR=` cannot clear it: the assertion compares the artifact with the target. The remedy is `git -C <checkout> remote set-url origin https://github.com/<owner>/<name>.git`; there is deliberately no env override |
| `reviewer-preflight.sh` | discloses the reviewer requirement BEFORE the lane works (agent-infra#2148), instead of the lane discovering it by being refused at the rail |
| `gh-limit.py` | the serialiser every harness `gh` call passes through (agent-infra#1988): four boxes act as ONE account, so one rate-limit bucket is shared and nothing else queues the calls |

**Retired — the safety claim is settled by measurement; the pin itself is an operator setting:**

| component | verdict |
|---|---|
| **the `SCOPE=own` partition** ("exactly one BROAD box, others OWN") — its **safety role** | **Retired for dispatch and review, where the measurement reaches it; the landing row keeps an exclusion REQUIREMENT.** A claim was measured **excluding** for **dispatch** and for **review** (3/3 laps × 6 racers, exactly one winner per lap) — those two rows measure the *operation*, so the pin's safety role is retired there (§7.2d *Does a claim EXCLUDE?*, agent-infra#1908). ⛔ **Landing must NOT be retired on that measurement**: M6 shows the per-PR key (`refs/claims/pr-<N>`) excluding, and landing takes that key — but M6 measures the **claim**, not the merge, because `gh pr merge` is not pinned to a sha and the guard there is a read, not a fence. So the requirement stays, met by the per-PR key; §7.2d *Does a claim EXCLUDE?* says exactly this in its own closing note — the `SCOPE=own` row "may move … for the first two and must not for the third". `SCOPE=own` was never what excluded any of them. ⛔ **What survives is a caveat, not the safety claim: this is a partition, not coordination.** It selects which *PR branches* the sweep looks at (`*-tm`, `*-cap`, `fix/*`) by a naming convention every box shares, so it is not a claim registry and must not be mistaken for one (§5 item 3). `install.sh` still renders the value |

**Deprecated, still live — do NOT remove yet:**

| component | status |
|---|---|
| `parked-*` / `parkreason-*` as a terminal state | **written and read on every cycle** — `park_ctrl` (`orch-loop.sh:1503`) is called from the red-tree caps (`:2727`, `:2793`, `:2799`, `:2821`, `:2881`), the conflicted cap (`:3008`), the needs-fix cap (`:3170`) and the CI-red cap (`:3219`), and `:2899` reads the park back each sweep. It becomes retired **only** when `ask-owner.py` is wired into the loop (R5) — until then `parked-*` **is** the terminal state, and ripping it out early leaves a stuck PR with no destination at all |

**Legacy — retired, must not run:**

| component | why retired |
|---|---|
| swarm-era coordination jobs — `coordinator`, `swarm-watchdog`, `agent-implementer`, `agent-strategist`, `team-strategist`, `pipeline-ingest` | superseded by this harness; two dispatch systems on one box double-dispatch. The swarm repo's `origin/main` has had **no commits since 2026-09-18** (checked against the remote, not a local checkout — a local one here was 283 commits behind) |
| the `content-inspiration` job | its entry point was an uncommitted file; the `.mjs` pipeline survives on its branch |
| `retired/` (10 files: six `.sh`, four `.py`) | earlier iterations, kept for the record only — and `retired/` is outside the depth-1 `*.sh` drift gate (§4.1) |

### 0.6 Activation is part of the design, not an afterthought

Having the right code and **running** the right code are different problems. Measured 2026-10-16:
this harness was **dormant** while six swarm-era dispatchers fired every 120 s. Two mechanisms now
answer the question, and neither is a separate script to invent:

* **"Is this box up, and on which tree?"** — `scripts/harness-up status` prints one line per
  component (pid + age) and **ONE verdict** (`scripts/harness-up:9`); `harness-up` / `harness-down`
  bring the stack up and down in dependency order, and re-running `up` is a no-op on an
  already-running tree (`:6-7`). `install.sh` is not a substitute: it renders config, refuses
  out-of-range values, and never touches a loaded job unless asked — its `--start` / `--restart`
  (`install.sh:8-9`) render + install **then prove it started** (pid + heartbeat,
  `:1096`/`:1142`).
* **"Which system is this box provisioned for?"** — `docs/ops/ACTIVATION-MATRIX.md` is the measured
  provisioned-vs-improvised record, Mac and cell, with a per-row re-measurement recipe.

**Retiring a legacy job is a declared list, not a new script.** Add the label to
`templates/launchd/RETIRED`; `retire_pass` → `retire_job` (`install-launchd.sh:578-598`) unloads and
removes each listed job (`:584` prints `RETIRED (unloaded + removed)`) and refuses a label that still
has a template in the directory (`:594`). `is_retired` (`:571`) is that same list read as a
predicate, and it is what stops a retired label's template being installed (`:730`). A label in
`RETIRED` must not also have a `.plist` template.

### 0.7 The load ceiling

`MAX_LOAD` is where a box stops adding work. It is **derived, not fixed**: `cores × 10` as shipped,
overridable per box (`MAX_LOAD` in the plist or `keys.env`), with a hard fallback of **40** when the
core probe is unusable (`orch-loop.sh:177` for the derivation, `:178` for the fallback, mirrored at
`install.sh:72` — an earlier draft of this section said 32, which is neither the fallback nor the
shipped value).

> ⚠️ **The `×8` rule is a PROPOSAL with NO CARRIER — not shipped behaviour.** It was written as PR
> **#1907** (`×10 → ×8`), which was **closed UNMERGED on 2026-10-22**; **no open issue carries the
> rule** either — searched open issues 2026-10-22, and the only mention (**#1961**) merely *assumes*
> `cores × 8` while arguing a different defect (RAM binds before load), so it is not a carrier for this
> change. The rule is therefore **not pending, and nothing has to land before this document** — the
> document is landable on its own. What ships is the derivation `cores × 10` (`orch-loop.sh:177`),
> which the **Tuning** table below records, **plus** the already-shipped **fallback of 40**
> (`orch-loop.sh:178`); those are two different constants and must not be read as one.

| cores | shipped ceiling (`cores × 10`) |
|---|---|
| 4 | 40 ← also the fallback when `_NCPU` cannot be probed |
| 8 | 80 |
| 10 | 100 |

**Why the proposal is ×8.** The shipped derivation `cores × 10` (8 → 80, 10 → 100) corresponds to
the highest load observed as tolerable on a 10-core box. ×8 (4 → 32, 8 → 64, 10 → 80) keeps a
deliberate margin *below* what was seen to work: on a machine that is also somebody's laptop, load is
a symptom of contention rather than a target to reach. A dedicated box can raise the shipped value
with the override; the derived value stays conservative by design. ⛔ **That is an argument, not a
delivery**: whoever wants it must open the issue, change `orch-loop.sh:177` and its `install.sh:72`
mirror, and only then does this section describe the code.

> `MAX_LOAD` and `MERGE_PRIORITY_AT` are different things and are often confused: `MAX_LOAD` is the
> box's capacity ceiling, while `MERGE_PRIORITY_AT` (default **25**) is **not a gate** — the drain gate
> has no threshold (ONE workable un-owned PR closes the issue path, §0.2 R6 / §7.2f) and the value only
> sets the reviewer/fixer headroom and the unreadable-count fallback.

## 1. Why it exists

The repo's normal path is one agent, one issue, one PR, human-paced. On a box that is left
running overnight that path is idle most of the time. This harness keeps the box saturated
without a human in the loop:

- **Fan-out:** N simultaneous implementation lanes, each in its own git worktree.
- **Fan-in:** a per-PR chain that reviews, records the review as a gate artifact, and merges.
- **Back-pressure:** every cycle is gated on load average and swap, so the box throttles
  itself instead of thrashing. While **any** unowned but workable open PR remains, the only work this
  cell creates is **taking one on** (§7.2f): issues are not picked until the un-owned queue is empty.
  An "unowned" PR is one **nothing live is working** — the test is a live process whose cwd is on that
  PR's head ref (or whose path carries the PR number), plus a live claim from another box; session
  names, `needsfix-*` markers and local claim refs are NOT ownership, because they outlive the process
  that wrote them. Because a merge backlog means the scarce capacity belongs to review and merge, the
  reviewer AND fixer headroom rises (`MAX_REVIEW+2` / `MAX_FIX+2`) rather than the fleet idling.
  Counting TOTAL open PRs instead capped the fleet on a busy queue: a PR mid-review, mid-fix,
  mid-merge — or held by a claim on another box — read as congestion. Measured 2026-10-16, two live
  cells logged `merge-priority (20 open PRs — draining)` at `lanes=1` (live) of a configured `max_lanes=32` with
  59-86% CPU idle and 13.9 GB RAM free (agent-infra#1824; see the tuning table in §4).
  ⚠️ A cross-box claim is a **declared window**, not proof of life — `claims.sh` is explicit that a
  lease is *data, not liveness* (a REMOTE pid cannot be probed), so an abandoned claim reads as owned
  until the lease expires — **unless the holder can be shown ORPHANED** (§7.2b, `agent-infra#2094`:
  this box's own former host name, a host on `CLAIM_DEAD_HOSTS`, a host absent from a current
  `CLAIM_KNOWN_HOSTS` roster, or a local pid that is gone for a PR claim). The residual is a claim
  from a host none of those rules can judge — an unknown name with no roster — which still reads as
  owned until its lease expires; it is an under-count of orphanhood on purpose, because the
  over-count direction steals a live peer's work. The direction is recorded on `pr_owned()` in
  `orch-loop.sh`.
- **Self-healing:** a PR whose reviewer reports real findings is routed to a *fixer*, fixed,
  and re-reviewed — rather than being left red forever (this is the bug that stranded ~15
  PRs before it was fixed; see §7).
- **A capacity pool, not only an isolation boundary.** The five machines are not five independent
  single-host harnesses that happen to share a repo; they are **one pool of capacity** over one
  queue. So a per-machine capacity decision must never become a fleet-wide one: when a box refuses
  an item because *it* is full, the item stays **eligible on every other box**. That is the
  requirement this document calls **R8** (agent-infra#1909), and it is not automatic — the refusal
  used to hold the cross-box issue claim for 90 minutes while the chain waited for a PR no agent
  could open, so one load spike made the issue ineligible on all five boxes at once. Measured
  2026-10-17: the Mac refused at load 98-180 (correctly) while cell-2 sat at 0.29 load with 14.5 GB
  free and cell-3 at 0.04 load, and **47 P0/P1 issues went untouched with ~20 vCPU idle on the same
  account**; the gap was filled by hand with six manually-created dispatch lanes. The transfer
  mechanism is in §7.2d — and it is deliberately **not** built on load average: the signal is the
  worker gate's own refusal, whatever it bound on (that gate binds on **load, memory, disk or land**
  — the last one is repo-wide and is recorded as NOT transferable in §7.2/§7.2g; the lanes/swap terms
  — and the controller's OWN memory arm, a DIFFERENT floor (`MIN_MEM_FREE_MB`, §7 below: two
  populations, one probe) — belong to the controller's separate gate, which refuses before any claim is taken), because load is a
  symptom of contention rather than a measure of capacity (`docs/ops/load-policy.md`), and a
  capacity gate a caller can skip is not a gate (agent-infra#1884).

It deliberately does **not** use the `task` sub-agent tool. Workers are separate `pi -p`
processes in their own **durable terminal** where the cmux daemon answers; where it does not, they run
in a **tmux session carrying the HOME+keys.env contract** (macOS launchd and a Linux cell — see §2.1), so
a killed worker cannot take the controller down with it.

---

## 2. Architecture

```text
                      launchd  com.eldato.orchestrator-loop  (RunAtLoad + KeepAlive)
                                        │
                                  orch-loop.sh        ← the controller, one process
                                        │
        ┌───────────────────────────────┼────────────────────────────────┐
        │                               │                                │
   (1) merge sweep              (2) capacity-gated dispatch      (3) backlog refresh
        │                               │                                │
        │  for every open non-draft PR  │  read candidates.txt            │  refresh-candidates.sh
        │  read repo's required checks  │  skip if in dispatched.txt      │  pre-flight each issue
        │                               │  dispatch-merge.sh:             │  (collision_preflight.py)
        │   GREEN   → merge authority   │    git worktree add             │  append CLEAN ones
        │   PENDING → auto (gate mode)  │    wt_spawn lane-<N>  ──┐       │
        │   FAILED  → see below         │    wt_spawn chain-<N> ──┤       │
        └───────────────────────────────┴─────────────────────────┼───────┘
                                                                  │
                        ┌─────────────────────────────────────────┘
                        ▼
        lane-<N>   → lane.sh   : pi -p in .worktrees/tm-<N>, implement → commit → push → open PR
                        │
        chain-<N>  → chain-merge.sh : poll for the PR to appear, then
                        ▼
        merge-<PR> → merge-one.sh :
                        the repo's merge authority decides the whole step (agent-infra#1764)
                        gate mode (the repo REQUIRES `ai-review-gate`):
                        1. fresh-context reviewer → posts its review as a PR comment (the audit artifact)
                        2. CLEAN   → record-review.sh (HMAC-signed marker into the PR body)
                                     → wait for ai-review-gate SUCCESS → gh pr merge --squash
                            ISSUES  → touch state/needsfix-<PR>-<head>   ← hands off to the fixer path
                          no verdict → touch state/needsreview-<PR>-<head>  ← re-runs the REVIEW; never
                                     a fixer, and bounded by MAX_REVIEW_TRIES (agent-infra#2132)
                        rail mode (the repo does NOT require the gate — e.g. agent-infra):
                        1. a head-bound review RECORD already in the store at this head → straight to
                           the rail (the normal case: the lane's own review pass recorded one)
                        2. otherwise the review path above RUNS FIRST (agent-infra#1825): the rail is
                           no longer an excuse to skip the review, because `pipeline-compliance`
                           check (c) — this repo's only required check — accepts nothing but that
                           record. Then → `scripts/admin-merge.sh <PR>`, the repo's own rail, which
                           posts its own head-bound evidence and merges. `gh pr merge` is NEVER
                           called here: it would land on the required checks alone, bypassing the rail.
                           Refused 3x at one head → PARK that head.
                        ▼
        fix-<PR>   → fix-one.sh  : materialises a worktree for the branch (including foreign
                                   branches), runs a fixer over the reviewer's findings, pushes a
                                   new commit, then re-runs merge-one.sh end-to-end
```

### State files written by the merge sweep

| file | written by | lifetime |
|---|---|---|
| `state/prclass.tsv` | the sweep's classifier, one row per PR per cycle | folded at the top of the next cycle by `lo_class_compact` (it decides the ORDER only) |
| `state/pr-meta.tsv` | the 200 listing, PR → `created_at` | rewritten on every 200 (never appended) |
| `state/last-open-prs` | `open_pr_count`, `number:headOid:headRefName` | rewritten per read; DELETED on a failed read (so "no rows" means "not known to be owned") |
| `state/prdisp.tsv` | the sweep + the parent, `pr \t head \t token \t act\|wait \t reason` (**agent-infra#2126**) | **truncated by the parent before the sweep**, at most one row per PR per cycle. It is a RECORD of what the drain acted on or why it did not — never an input to the count or the gate (pinned by `test-gates.sh` and `pr-dispatch.test.sh`). `act` means an action the cycle ACTUALLY took — a worker spawned, a merge issued, an auto-merge armed, a draft readied, or a CI rerun — and `wait` means a row with a printed reason; both count ROWS (the line prints `row(s)`), and the swept set also carries owned PRs, so neither number is ever printed as a count of un-owned PRs. `first #N` and the funnel's "dispatching"/"NO UNIT SPAWNED" wording are both derived from it, so a printed claim has an action or a named wait behind it — and a cycle that recorded nothing says so instead. Two degraded states are named instead of guessed: an **unwritable** `state/` reads `record UNWRITABLE … UNKNOWN, not zero`, and a cycle with **no recorded rows** reads `NO ROWS … either the listing returned no rows, or the record could not be written … UNKNOWN, not zero` (a truncate succeeds with no allocation, so a full `state/` passes the writability probe and then fails every write — the row count cannot tell those two causes apart, so the line names both). The funnel is handed the same third fact, so it cannot print a measured zero for a cycle that measured nothing. On a population that is not enumerable (the count came from the listing while the ledger only holds the swept set) the line carries an explicit `NOT enumerable this cycle` caveat — the two numbers have different denominators and are never printed as if they shared one. |

### Worker types

| Session | Script | Writes to | Purpose |
|---|---|---|---|
| `lane-<N>` | `lane.sh` | `.worktrees/tm-<N>` on `feat/<N>-tm` | implement issue #N → commit → push → open PR → **take it to `merged`** through `lane-merge.sh` (bounded) |
| `chain-<N>` | `chain-merge.sh` | — | wait for the PR **and for the lane's merge-phase verdict**, then delegate to `merge-one.sh` if the lane did not merge it |
| `review-<PR>` | `merge-one.sh` | — | **the review ORDER** for a `(PR, head)`: a fresh-context reviewer → evidence comment → signed record, then the same landing path as `merge-<PR>` if it came back CLEAN. Dispatched by the PR path on `NEEDS-REVIEW` (agent-infra#2971) — it was spawned under the `merge-<PR>` tag until then, so a pass that REVIEWED read in the log as another merge worker and `merge-10213` was re-spawned pass after pass |
| `merge-<PR>` | `merge-one.sh` | — | **repo-authority-dependent**: gate mode = fresh review → signed record → wait green → squash-merge; rail mode = (a head-bound record already at the head, else the same fresh review → signed record first) → the repo's own `scripts/admin-merge.sh` (#1825) |
| `fix-<PR>` | `fix-one.sh` | the PR's worktree | repair findings, **a failing required check**, or **a rail refusal that names a red tree** (agent-infra#2223 — the RED-FIXER role in the sweep), push, re-run the merge chain. ONE fixer per PR by construction: all three reasons spawn under this session name, so a second reason while a fixer lives finds the session and spawns nothing |
| `cell-doctor` | `cloud-cell-doctor.sh loop` | `state/roles/`, `logs/doctor.log` | the cell's **own** scheduled roles — `doctor` (reap + restart a missing controller), `merge` (land attested PRs on the standard rail), `hygiene` (caches/worktrees **+ the cross-box review-record registry**: `registry-sync.sh union`, hourly, from a dedicated throwaway worktree of the agent-infra checkout, and **best-effort** — a failed sync logs the box/store/exit code and the pass continues, so a dark or rate-limited store can never fail a hygiene pass or block a merge decision; agent-infra#2577). Started by `cloud-cell-supervisor.sh start`; see §6.5.7 |

### State files (`$O/`)

| File | Meaning |
|---|---|
| `heartbeat` | epoch seconds, rewritten every cycle — the liveness probe |
| `state/refresh-last` | the last refresh pass's OWN outcome (agent-infra#2229): `result=ok|fail|running`, `stage=` (startup/provision/list/persist/preflight/budget/judge/skip/handoff), `rc=`, `at=`, `repo=`, `why=`, `cmd=` (the command that failed), plus `judged=`/`queued=`/`backlog=`/`handed=`/`unusable=`. Written by `refresh-candidates.sh` as a `result=running` TOMBSTONE at entry and then the outcome at most once, with an exit nobody converted recorded as a FAILURE by its `EXIT` trap (rc=0 included) — and read by `orch-loop.sh`, which may print `skipped (…)` only for `result=ok`. A record without a known `result=` is UNREADABLE and reads as BLOCKED, never as a healthy pass |
| `.refresh-unrecorded` | the pass's FALLBACK marker: written into `$O` whenever a `state/refresh-last` write fails (an unwritable `state/`), removed by the next successful write. Its PRESENCE means "a pass finished and its outcome is not on disk" — the record underneath is an EARLIER pass and is not this cycle's health — so `orch-loop.sh` reads it BEFORE the record and prints `BLOCKED`, quoting the marker's own `stage=`, `rc=` and `why=` (a marker with `rc=0` is a SUCCESS whose record failed) |
| `state/queue-state` | what the last pool READ saw, with the epoch of the read — `EMPTY`, `READ(<n>)`, `PARTIAL(<tiers>)` or `UNREADABLE`. `orch-loop.sh` prints it in the cycle line as `queue=$(queue_state_token)`, so a refresh that could not read the pool (`queue=UNREADABLE`) is never mistaken for a fleet with nothing to do (`queue=EMPTY`); an absent file reads `UNKNOWN`, never `EMPTY` (agent-infra#1931) |
| `.orch.lock` | atomic single-instance lock (noclobber create); stale locks are reclaimed |
| `candidates.txt` | the dispatch backlog: issue numbers that passed collision pre-flight. Its ORDER is the dispatch priority, with one qualification (`PRODUCT_FLOOR`, agent-infra#2054): up to that many slots of each batch are filled from `candidates.product.txt` first — entries that are ALSO in this file, always — so a product issue can jump the queue but nothing can enter it. ⛔ AND THE FLOOR YIELDS TO AN EMERGENCY: a `P0-blocker` candidate inside the batch window, a `red-tree` rail refusal that is not parked, or an emergency class that could not be read, all stand the floor down for that cycle and are reported as `product-floor OVERRIDDEN emergency=<reason>` — see the `PRODUCT_FLOOR` row in §Tuning |
| `candidates.product.txt` / `candidates.harness.txt` | the floor's split of `candidates.txt` (agent-infra#2054), re-derived from it at the end of every refresh pass (never accumulated, so a dispatched-then-pruned issue does not go on "proving" product work exists). Membership is the class: `product` = the item's repo is in `PRODUCT_REPOS` AND it does not carry the `harness` label. Absent ⇒ no split has run on this box |
| `candidates.emergency.txt` | the `P0-blocker` subset of `candidates.product.txt`'s parent backlog, in **backlog order** — i.e. the P0 candidates this box could dispatch, by their own label, intersected with `candidates.txt`. It is what the floor consults before reordering, so an emergency can never be displaced by a share target. ⛔ **ABSENT ≠ EMPTY**: the writer CREATES the file (possibly empty) on a completed read, so an empty file beside an `OK p0=0` record means the split RAN and saw no P0 — while an ABSENT file means no pass could classify this cycle, and the floor reads that as UNKNOWN and stands down |
| `state/product-class` | WHICH arm classified the batch and what it measured: `NOT-A-PRODUCT-REPO …` / `BUDGET-SKIPPED …` / `LISTING-FAILED …` / `LISTING-TRUNCATED …` / `WRITE-FAILED …` / `OK product=<n> harness=<m>`. Written by `write_product_queues`; the dispatch line repeats it instead of asking a second time |
| `state/emergency-class` | the emergency split's outcome, and deliberately a SEPARATE polarity from `state/product-class`: `OK p0=<n>`, `NOT-A-PRODUCT-REPO …` (no floor applies, so nothing to override), or `UNKNOWN-<BUDGET-SKIPPED|LISTING-FAILED|LISTING-TRUNCATED|WRITE-FAILED> …`. ⛔ Every `UNKNOWN-` arm also REMOVES `candidates.emergency.txt`, and the reader requires the file to exist with a line count matching the recorded `p0=` before it trusts an `OK` record — so a stale record left standing by a failed write cannot be read as "no P0". An unreadable PRODUCT class under-claims (an unclassifiable item must not satisfy the floor); an unreadable EMERGENCY class must not, because "no P0 could be read" is not "there is no P0" — so every `UNKNOWN-` arm stands the floor down (`product-floor OVERRIDDEN emergency=p0-unknown(…)`), naming the reason |
| `dispatched.txt` | issues already handed to a lane — **pruned** when the issue is still open, no PR branch matches it and no `lane-<N>` is live (see §7.1) |
| `checked.txt` | issues whose pre-flight returned **CLEAN** (the terminal verdict); an **errored** pre-flight and a **COLLISION** leave no entry, so the next pass re-attempts them (agent-infra#1716). ⛔ **REVALIDATED EVERY PASS** (agent-infra#2183): an entry survives only while a re-checkable keep-fact holds — `dispatched`, `queued`, `pr`, `lane`, or a live cross-box `claim` — and anything else is **released** and re-judged, so a candidate judged CLEAN whose lane never started cannot be suppressed for ever. A reaped number is dropped from it too. The release is bounded (`CHECKED_RELEASE_MAX`, 24 asks/pass) and rotated by `state/checked-release-cursor`, which holds the **last issue asked** (not the largest), so a head of permanently-held entries cannot starve the tail. ⛔ The bound applies to the registry path: a box with **no `$O/claims.sh`** takes the documented fallback and releases the whole residue in one pass (no claim can exist there, so there is nothing to re-check per entry) |
| `state/collided` | `"<expiry-epoch> <issue>"` per line — candidates a peer was holding at the last pre-flight. A pass walks PAST a fresh record without spending a pre-flight run, so a blocked pool HEAD is not re-bought on every pass; a skipped candidate stays out of `candidates.txt` and out of `checked.txt`, so it is **deferred, never dropped** — the record lapses after `POOL_COLLISION_TTL` (900 s) and the candidate is judged again (agent-infra#1729). Only a COLLISION is recorded: a DEGRADED / INCOMPLETE / verdict-less answer is an environment failure and stays visible on every pass (agent-infra#1736) |
| `state/mergeclaim-<PR>.lock` | single-owner claim: only one worker may review/record/merge/**fix** a given PR. Taken by `merge-one.sh`, by the doctor's `merge` role, and — since the pusher hole was closed (#2574) — by `fix-one.sh`, the one worker whose product is a NEW HEAD: without it a lander could re-resolve a head that a fixer then moved under it, and the rail refuses with the just-minted attestation stale. A LIVE holder makes the fixer DEFER with a refundable bail marker and no attempt consumed. A claim whose pid `kill -0` proves GONE is TAKEN OVER — measured, and by `mv` aside + verify, never `rm && write`: the record is renamed aside, what was detached is checked against the dead pid that was measured, and a record that turns out to be a peer's LIVE claim is put back with `ln` (create-if-absent) **if the path is still free** — if a third party has re-claimed it in between, the displaced claim cannot be reinstated, which is logged as a WARNING and reported as its own deferral (never as "nothing was deleted"). `fix-one.sh` also CREATES the record with its pid already in it (a pre-written file `ln`-ed into place), because a noclobber create that writes the pid afterwards leaves the file briefly EMPTY and the other three readers treat "no owner" as a reason to `rm` it. An EMPTY or unparseable record is **not** stale ON ITS CONTENT ALONE (that same window), so content alone never reaps it. ⛔ AN EMPTY RECORD THAT HAS OUTLIVED ANY POSSIBLE CREATE WINDOW IS A MEASUREMENT, NOT AN INFERENCE (agent-infra#3096): `fix-one.sh`'s `prlock_no_owner_abandoned` and `pr-owner-liveness.sh`'s `pl_verdict` both reclaim one whose `find -mmin` age exceeds `PRLOCK_NO_OWNER_GRACE_MIN` (default 2 m — microseconds vs the 21 h measured on the cells), by detach-and-verify, never `rm && write`. Before that reconcile the two verdicts DISAGREED for one state — `pl_verdict` answered OWNED for a 21-hour-old 0-byte record while `pr_owned` counted the PR un-owned — so the controller spawned nothing for a PR nothing owned and the issue path stayed shut. The `OVERRIDES`-style departure from the earlier literal rule is marked in `pr-owner-liveness.sh`'s header with its evidence; the rule it protects (never reap on emptiness ALONE) is unchanged. A lock state no re-dispatch can clear (a path that is not a regular file, or an unwritable `$O/state`) is REFUSED and the attempt is CONSUMED, so `MAX_FIX_TRIES` parks the PR instead of a refunded spin. **Per box** — the cross-box fence for the landing path is `refs/claims/pr-<PR>` in the shared repo (§7.2b) |
| `state/needsfix-<PR>-<head>` | "a reviewer reported real issues at this exact head" — the only state that authorises a fixer ON THE REVIEW-GATE ARM (the CI-red and CONFLICTING arms dispatch on a red required check / an unmergeable head with no marker at all, by design). Deleted when a fixer is spawned, and cleared by a CLEAN verdict whose signed marker VERIFIED at that head; a verdict-less run never deletes it (nothing was pushed, so it supersedes nothing) |
| `state/needsreview-<PR>-<head>` | "a reviewer run at this head produced NO usable verdict" — the remedy is another REVIEW, never a fixer (agent-infra#2132). Written by `merge-one.sh` ONLY (the controller cannot see whether evidence exists). One marker per PR; swept when a GATE-authority PR goes GREEN, when the PR is MERGED/CLOSED, when the signed marker verifies, and by `prune_orphan_markers` once per cycle for PRs that left the open listing (never for a marker newer than the listing). On a rail repo GREEN does not imply evidence, so the sweep does not run there |
| `state/reviewcount-<PR>` | **RETIRED** (agent-infra#2971): its `"<head> <n>"` budget is now the `state/reviewdisp-<PR>` record below — ONE budget shared by the two arms instead of two books neither could see. A leftover file is inert and is deleted wherever the old one was |
| `state/reviewdisp-<PR>` | `"<head> <n>"`: review ATTEMPTS at this `(PR, head)`, spent by BOTH arms (agent-infra#2971) — the **CONTROLLER** on a dispatch, and `merge-one.sh` when a reviewer run produced no usable verdict on a path nothing counted above it (`REV_PAID=1` in the spawn command tells it the controller already paid, so one attempt is never counted twice). The controller dispatched for that (PR, head), written only after a spawn succeeded. The head is the key, so a push re-arms it; an unchanged head is never re-reviewed **once CLEAN evidence exists at it** (`REVIEW-AT-HEAD`), and otherwise spends at most `MAX_REVIEW_TRIES` re-records before `REVIEW-CAP` — the budget is per head, not per PR (agent-infra#2653). Before the spawn the arm asks `review_disp_decide`, and an **unreadable head is not a key** (a review spent on an unnamed head cannot be keyed, compared or recorded — the arm refuses and names the head): **`REVIEW-AT-HEAD`** — the enforcer's store already holds a CLEAN record at exactly this head (BOTH store names are read: the repo-qualified file and the legacy `<pr>.json`, the same pair `merge-one.sh::record_at_head` checks) — so no second review is bought for an unchanged head; **`REVIEW-CAP n/max`** parks a head that spent `MAX_REVIEW_TRIES` re-records with no verdict. None is ever a silent skip. `MAX_REVIEW_TRIES=0` is **REPORT-ONLY** (no dispatch, nothing parked — the `MAX_RED_FIX_TRIES=0` idiom), and an UNWRITABLE record is named rather than swallowed (`reviewdisp` ⇒ park, `reviewathead` ⇒ `REVIEW-AT-HEAD-UNBOUNDED`; an unwritable `parked-<PR>` ⇒ `PARK DID NOT LAND`, never `PARKED`): a swallowed write makes the bound itself best-effort, which is exactly how a cap becomes unbounded. Pruned on MERGED/CLOSED and by `prune_orphan_markers` |
| `state/reviewathead-<PR>` | `"<head> <n>"`: consecutive `REVIEW-AT-HEAD` refusals at that head (agent-infra#2653). ⛔ It exists because AT-HEAD is the ONE state that neither dispatches nor parks, and its remedy (a re-record) is `merge-one.sh`'s, which the withholding branch prevents from running — so at `MAX_REVIEW_TRIES` the PR PARKS as **`REVIEW-AT-HEAD-STUCK`** with the exact re-record command, instead of logging a wait row for ever. Pruned with `reviewdisp` |
| `state/fixcount-<PR>` | fixer attempts for that PR, capped by `MAX_FIX_TRIES` |
| `state/railrefusal-<PR>` | the rail's last refusal, **head-bound**: `head=`, `attempt=`, `override=`, `class=` (`red-tree`/`override`/`conflict`/`unreadable`/`other`), `reason=` (**verbatim**) and `detail=`. Written by `merge-one.sh` (every ingress) and by the cell doctor's `merge` role. The sweep spawns a red-fixer for a `red-tree` class at the CURRENT head only; a stored head ≠ the current head means a push happened, so the record is dropped and the new head is **re-railed** (agent-infra#2223). Absent ⇒ nothing to repair |
| `state/fixgate-<PR>-<head>` | written by `fix-one.sh` when a controller-spawned fixer's agent was refused by the load/disk gate (so nothing ran). The red-fixer role consumes it to refund the per-head attempt; it is also reclaimed on a merge/close. Without it, two gate refusals burn `MAX_RED_FIX_TRIES` and park a red PR saying a fixer "did not clear it" — false, since no agent started |
| `state/redfix-<PR>` | `"<head> <n>"` — red-fixer attempts at that head, capped by `MAX_RED_FIX_TRIES` (2), beside `MAX_RED_FIX` (4) red-fixer lanes per box. Head-keyed, so a fixer's push buys a fresh budget; at the cap the refusal is kept, the PR parks and the reason carries the rail's verbatim line |
| `state/parked-<PR>` | terminal state: the fixer cap was reached at the head recorded inside the file, so the sweep skips it until a new push re-arms it |
| `state/rerun-<PR>-<runid>` | CI re-run already requested for this run — prevents loops |
| `state/merged-<PR>.done` | merge confirmation |
| `state/lanemerge-<PR>.phase` | the lane entered its **merge phase** (it, not the controller, is driving the merge). `chain-merge.sh` waits on it so a review is never recorded at a head the lane then fixes |
| `state/lanemerge-<PR>.round` | fix rounds spent by `lane-merge.sh` — the **cap is 3**, and the tool refuses the next round rather than granting it |
| `state/lanemerge-<PR>.verdict` | the merge phase's machine verdict (`MERGED <sha>`, `FIX_REQUIRED`, `BLOCKED_ATTESTATION`, `BLOCKED_ATTEMPTS`, `BLOCKED`, `WAITING_*`). `lanemerge-issue-<N>.verdict` is the issue-keyed copy **`lane.sh` reads** for its post-run "no merge-phase verdict" diagnostic (chain-merge reads the PR-keyed file), and `lanemerge-<PR>.issue` persists the issue number so a later `--watch` can still write it |
| `state/lanemerge-<PR>.last` | the last failing check NAMES observed — what the handoff comment quotes, so the next holder inherits the diagnosis |
| `state/last-open-n` | the last SUCCESSFUL open-PR count; reused only when positive if a later count fails — a failure never reads as 0 |
| `state/last-open-prs` | the `number:headOid:headRefName` rows from that same SUCCESSFUL listing — the **ownership scan's** input (`unowned_pr_count`) and the selection's population. The head ref is what the live-process predicate is matched against; a row is only used when it has all three fields, so a truncated file cannot read as "nothing is owned". A missing/unreadable file is UNKNOWN, not empty: `open_pr_count` REMOVES it on a failed read and the gate then blocks on the fail-closed listing count. Written on success and REMOVED on a failed listing, so a fallback count is never paired with the previous listing's rows; absent rows mean **nothing is owned** (the whole count is unowned), which is the fail-closed direction. Both files come from ONE `gh pr list` call. |
| `state/roles/<role>.state` | the cell doctor's LAST-PASS record per role (`last_pass_at`, `last_pass_epoch`, `passes`, `last_rc`, `last_result`), written atomically and only by a completed pass — `status` reads it, so "never ran" is distinguishable from "idle" (§6.5.7) |
| `state/roles/.desired` | the cell is SUPPOSED to be running; written by `start`, removed by `stop`, so the doctor restarts a controller that `stop` did not silence |
| `state/roles/loop.ident` | `pid|<identity>` for the doctor loop, where the identity is `proc:<starttime>` from `/proc/<pid>/stat` on Linux and `ps -o lstart=` where `/proc` does not exist — `status` verifies BOTH before reporting the loop RUNNING, so a recycled pid (after a tmux server restart, an OOM kill or a crash) cannot make a dead loop read as alive |
| `state/roles/merge.attempts` | `PR head epoch reason` for every rail call the merge role made — the head-level cooldown that stops a REFUSED head being retried blind |
| `logs/` | one log per worker: `lane-*.log`, `lane-merge-<PR>.log` (the lane's merge-loop chain), `chain-*.log`, `merge-*.log`, `fix-*.log`, `orch-loop.log` — `merge-rate.sh` deliberately does NOT count `lane-merge-*.log` as a lane |
| `wip/` | dirty-worktree captures taken before a shutdown (see §6), plus one `capwip-<stamp>-<pid>/` per lane KILLED AT ITS WALL-CLOCK CAP (#2045): `tracked.patch`, `untracked.tgz`, `untracked.list`, `tracked.numstat` (the re-parse's own output, kept as evidence that the patch was verified) and `SNAPSHOT.txt`. The newest `WIP_SNAPSHOT_KEEP` (10) directories are kept — a cell's disk is the first thing that stops dispatch, so this is a bounded directory, not a log |
| `state/capwip.tsv` | one row per cap kill **on every path** — epoch, label, cap seconds, elapsed, exit status, the verdict (`COMPLETE`/`PARTIAL`/`NOTHING-LOST`/`LOST`/`UNSNAPSHOTABLE`) and the snapshot dir (empty where no directory exists). The companion to `state/walltime.tsv` (`report.sh` computes the cap-hit RATE there; this is what says whether the kill cost any work) and the reason a cap hit is no longer an absence in the fleet's accounting |
| `state/lane-end.tsv` | one row per **terminal agent transition, cap or not** (#2834) — epoch, label, exit status, cap flag, the tree verdict (`dirty`/`clean`/`unpushed-only`/`cannot-verify`/`not-a-worktree`/`not-measured`), the rescue (`refs/wip/<slug>`/`archived-local`/`nothing`/`FAILED`/`UNAVAILABLE`/`DISABLED`), the local ref that pins the archived commit, the unpushed-commit count, and **the root that was measured** (`root` — the only column that can expose a wrong-tree archive). ⛔ **Every path writes through ONE writer** (`lane_end_record`), including the two that return BEFORE the measurement — `not-measured` (the operator hatch) and `not-a-worktree` (a root that is not a worktree ROOT: not a repository at all, or a path *inside* one) — because an absence used to be indistinguishable from a lane that never ended. ⛔ The root rule is the CALLEE'S (`bg-rescue-wip.sh:96-103`, `--show-toplevel` = `pwd -P`), not a weaker one (`rev-parse --git-dir` succeeds anywhere inside a repo, so it used to ratify a corner of a checkout and then fail one layer down as `rescue=FAILED`); what it does **not** catch — and does not claim to — is a caller that sets no `WIP_PATH` while its cwd sits at the ROOT of another checkout, which is why the measured root is a recorded column rather than an assumed one. ⛔ **`FAILED` means the rescue failed AND no ref pins anything**; `archived-local` is the third state, `bg-rescue-wip.sh` having exited 2 while `refs/wip-local/<slug>` is valid (a PARTIAL archive and a failed push both land there — the replayed callee lines above say which). ⛔ **The `ref` column names the LOCAL `refs/wip-local` pin and is EMPTY over an archive in exactly one case**: `bg-rescue-wip.sh` pushed `refs/wip/<slug>` and could not write that pin (it is guarded — `:246-252` warns and carries on), so the row reads `rescue=refs/wip/<slug>` with an empty ref and a loud line saying so. An empty ref alone is **not** "nothing was archived". The exit-path companion to `capwip.tsv`: the cap is not the common termination (`hit its … cap` appeared in **0** of 373 lane logs on the measured session), so without this row a lane that simply ENDED left no trace at all — its report said IN PROGRESS, the branch had no new commit, and the only copy of the work was a scratch worktree a reaper eventually deletes |

### Why the *reviewer* is a separate process from the *controller*

`merge-one.sh` spawns a fresh-context `pi -p` reviewer that has never seen the implementing
lane's reasoning. It reads the changed files at the PR head (`git show origin/<branch>:<path>`)
rather than only diff hunks, and posts its verdict as a PR comment. That comment is the
evidence the `record-review.sh` signature points at, so the merge gate is auditable after
the fact: the PR body names the comment it was signed against.

### Non-blocking dispatch — the orchestrator keeps its own time

`nonblocking-dispatch.sh` launches a headless worker and **returns immediately**. It exists because
the built-in `task`/`subagent` tools always block the caller (agent-infra#1662): an orchestrator that
dispatches N workers pays `max(worker)` wall-clock and cannot react to anything until the slowest
settles.

It is deliberately thin. It carries **no agent invocation of its own** — it backgrounds
`run_agent()` from `spawn-gate.sh`, so a background worker is load-gated exactly like `lane.sh` and
`fix-one.sh`, gets the same wall-clock watchdog, and appends the same `state/walltime.tsv` row with
`KIND=bg`. Routing it through the helper is also what keeps `spawn-gate.test.sh`'s invoker census an
equality: a direct spawn here would be a fourth, ungated launch path.

```bash
bash nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds] [bg|prfix]
bash nonblocking-dispatch.sh --status <name>     # running | done rc=0 | failed rc=N | lost
```

Status comes from the worker's own exit-status file plus a pid probe — **never `%CPU`**, which reads
0 for a worker that is merely WAITING (`docs/ops/fleet-liveness.md`). "launched" is the only success
this script reports: it cannot tell you the work succeeded.

⛔ **A CAP KILL IS ITS OWN FACT (#2045).** Measured 2026-10-18: of eight background lanes, three
produced nothing, and one died mid-work at its 35-minute cap — 269,237 characters of transcript,
seven MODIFIED files in its worktree, no report, no `.rc`, and the launcher reported
`worker finished: … commits=0 PR=none`. A killed lane's log is a slow lane's log, so nothing in the
harness could tell it from a lane with nothing to do. `run_agent` (`spawn-gate.sh`) now snapshots the
worktree **after** the hard kill has landed — a verified `tracked.patch` + `untracked.tgz` under
`$O/wip/capwip-*`, a `state/capwip.tsv` row, and a loud `[cap]` line naming the replay command — and
the worker publishes `$D/<name>.cap`, so `--status` says
`failed rc=143 (cap 3000s hit — COMPLETE WIP snapshot: …)` instead of a bare exit status. A cap hit on
a **clean** tree says `NOTHING WAS LOST` on the same line, because the two facts used to be
indistinguishable. The snapshot never delays the kill (it runs after `wait`), never CHANGES what the
worker staged, its branch or its stash (it runs `git status --no-optional-locks`, `git diff HEAD`,
`git ls-files`, a parsing `git apply --numstat`, and `tar` — the flag matters because a plain
`git status` refreshes the stat cache under `.git/index.lock` and could make a surviving writer's next
git command fail on a lock the rescue took), and it calls a backup
`COMPLETE` only after re-parsing it.

⛔ **AND A LANE THAT ENDS IS ITS OWN FACT TOO (#2834).** The cap is the RARE termination: on one
measured fleet session of 373 dispatched lanes, `hit its … cap` appeared in **zero** lane logs, while
**148** worktrees were left holding uncommitted or unpushed work and `origin` held no `refs/wip/*` from
that session. So `run_agent` now ALSO runs the shipped `scripts/bg-rescue-wip.sh` at the end of every
invocation **that started an agent** — after `wait`, after the cap snapshot, before it returns — and the
tool puts the work on
**origin** under `refs/wip/<branch-slug>` (built with `git commit-tree` through a throwaway index, never
`git stash`, whose ref is repo-global and whose `pop` can silently drop a PEER lane's entry). Three
things are deliberate and are asserted by `wip-rescue-exit.test.sh`:
  * the root is `WIP_PATH` when the caller sets it and `$PWD` otherwise, because `fix-one.sh` `cd`s into
    the MAIN checkout while the work lives in the fixer's worktree — archiving the wrong tree would be
    worse than no rescue, since it reports a capture the lane never received;
  * it costs a network call only when there IS something to save (one `git status` + one `rev-list`
    otherwise), and it never changes the lane's exit status: a lane's status and the fate of its
    worktree are different facts;
  * `unpushed-only` is MEASURED and NAMED but never archived **here**, and the reason is the callee's
    contract rather than branch safety: `bg-rescue-wip.sh` archives only a NON-EMPTY `git status`
    (`:150-166`), so a clean-but-unpushed tree makes it exit 0 having done nothing, and `refs/wip/<slug>`
    is a non-force ref built with `commit-tree` — not a branch. Teaching it to archive `HEAD`'s tree is a
    change to that shipped tool's contract and is deliberately out of scope, so #2834's ask 1 is met for
    the DIRTY half and recorded for the unpushed half: the commits live in the repo's object database and
    survive the WORKTREE being removed, but not the BRANCH being deleted.
  * ⛔ **THE SCOPE IS "AN AGENT STARTED", NOT "EVERY CALL"** — the ten GATE REFUSALS inside `run_agent`
    (brief gate, fork, disk/no-headroom, load, land-backlog, pi's own load/fork refusal) `return` before
    the spawn and therefore reach neither the rescue nor the ledger. That is the honest reading: nothing
    ran, so there is no terminal transition to record, and a refused lane writes NO `lane-end.tsv` row —
    an absent row is not "the lane ended clean", which is why the remedy for a fleet-wide gap here is the
    log of the refusal, not this table.
A rescuer that cannot be FOUND is `rescue=UNAVAILABLE` and a loud line naming the homes it searched —
never a silent skip, which is how an operator's own copy of this call was a no-op for a whole session
(`cd` before `_HERE` was resolved from a relative `BASH_SOURCE`, so `[ -f … ] && bash …` degenerated to
`false`). ⛔ **`UNAVAILABLE` carries TWO causes, and the `tree` column says which**: `tree=not-a-worktree`
means the ROOT was refused and no search happened at all (the rescuer is usually present), while any other
`tree` value means the rescuer was genuinely not found. A count of `UNAVAILABLE` rows is therefore not a
count of boxes missing the script — read the `tree` column with it. The launcher publishes the verdict in `$D/<name>.end`, so `--status` answers "what happened to
the work" as well as "what was the exit code":
`caplane failed rc=143 (cap 1s hit — …) end: tree=dirty rescue=refs/wip/work (refs/wip-local/work@87d4aba)`.

⛔ **Nothing here reviews anything.** The worker runs with `AGENT_SKIP_REVIEW_GATE=1` (a child has no
`task` tool and cannot satisfy the gates itself), so **the PARENT owns the review gate** — hand the
PR to `chain-merge.sh`, which polls for it and runs `merge-one.sh`. A background worker whose PR is
never handed to the chain is unreviewed code by default.


⚠️ `install.sh` does **not** copy it — it places no `*.sh` in `$O` at all, only `gh-rest/gh`
(`install.sh:533-541`) and `$O/gh-limit.py` (`:550-558`); everything else is the operator's `cp`, §4 step 1.
Its `DRIFTED` warning iterates an explicit `for f in …` list of twenty-two `*.sh` plus `gh-rest/gh`
and `gh-limit.py` — twenty-four entries (`install.sh:855`, moved by this PR's own added line) —
and this file **is** on it (added when
`pr-doctor`'s dispatch was wired to it, #1890), so a missing or stale `$O/nonblocking-dispatch.sh`
names itself instead of silently leaving every background dispatch to fail. ⛔ A stale copy is
still REPORTED, twice: the provenance stamp's `deployedMatchesSource` compares **every** shipped
`*.sh` against `$O`, and `check-deployed-drift.sh` fails on any differing
blob. What puts this file in `$O` is the install step in §4 — `deploy-mac-orchestrator.sh`, the
symlink-farm route, or (legacy, plain-directory `$O` only) `cp scripts/orchestrator-harness/*.sh
~/orchestrator/`. Whichever you used, re-run it after editing this script: on a symlink farm the
`cp` form refuses with "are the same file". There, re-point the links at the new
checkout (or re-run your farm installer) — do **not** run the plain `cp`, and note that
`deploy-mac-orchestrator.sh`'s `install_file` ends the farm: it writes a temp file and renames it
onto the destination (`mv -f`), and a rename over a symlink replaces the LINK, so `$O/<script>`
becomes a real copy and `doctor` then reports `kind=stamp` instead of `kind=linked-checkout`.

On a **plain-directory** `$O` the verified redeploy is §4.1's
`bash deploy-harness.sh --src . --o ~/orchestrator`: it copies every shipped file (`gh-limit.py`,
subdirectories and this one included) and byte-verifies each, instead of the depth-1 `cp *.sh`.
⛔ It is **not** a symlink-farm route, and the two refusals have different blast radii — do not read
them as one: a **directory** on the deploy path that is a symlink is refused in the preflight (exit
`78`) with **nothing written**; a target **file** that is a symlink is refused **per file** (exit `1`)
and the run says the runtime is **PARTIAL**, because the other sources in that run were copied. So on a
farm: re-point the links as above, and if a `1` is reported, read the ledger before trusting anything.
`install.sh`'s own `DRIFTED`/provenance warnings name the helper too (`install.sh:822`, `:1003`).

⚠️ This is a stopgap for an open gap, not the fix. **agent-infra#1666** lands non-blocking dispatch
as a first-class primitive (`task({ background: true })` plus `task_status`/`task_collect`). Once that
merges it supersedes this script for `task`-based orchestrators; the harness keeps this one for its
own `pi` workers, which do not go through `task`.

---

### 2.1 The worker launcher — `worker-terminal.sh`

Every worker (`lane-*`, `chain-*`, `merge-*`, `review-*`, `fix-*`) is started by ONE module, `wt_spawn`, never by
a hand-written command in a caller. It asks the box what it can actually provide and **refuses** when
the answer is nothing (no cmux answer AND no `tmux` binary):

| `wt_launcher` | when | what a worker is |
|---|---|---|
| `terminal` | `cmux tree --json` answers (a Mac inside cmux; a cell whose guest CLI can run) | a **daemon-owned durable terminal**: `cmux layout apply` with a one-surface layout on the cell's CLI, or `cmux surface new-terminal --machine <id> --cwd <dir> --no-open -- /bin/bash <run>` where the installed CLI has that scope. Its process tree hangs off the cmux daemon (`__terminal-host`), not off the controller or a transient `exec` |
| `tmux` | no cmux answer, but `tmux` exists — the launchd Mac, **and a Linux cell** (agent-infra#2210 reopened) | a detached tmux session **with an explicit environment contract**: `export HOME=<the HOME that holds the credential>`, that HOME's `keys.env` sourced when present, `O` exported, then the caller's command. A cell's guest cmux CLI cannot run at all (`cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui`), so this is the ONLY surface that can start a worker there |
| `none` | no surface at all: no cmux answer AND no `tmux` binary | **nothing — the spawn is REFUSED and logged**, naming both surfaces it looked for. There is genuinely nothing to run a worker in |

⛔ **The `~21 log lines` death is an ENVIRONMENT failure, not a tmux one** (measured 2026-10-22 on
cell-1; agent-infra#2210 was reopened for exactly this). `gh`'s credential is HOME-bound
(`$HOME/.config/gh/hosts.yml`), and a tmux spawn inherits the **server's** environment — whatever
shell happened to create that server. Against ONE bare server (`env -i HOME=/home/cmux`, no keys),
the pre-fix arm `tmux new-session -d -s X 'cd CWD && CMD'` produced **7 lines and `gh auth status` rc=1**
(`You are not logged into any GitHub hosts`), while the same session with `export HOME=/tmp/cell-home;
. $HOME/keys.env` produced **50 lines and rc=0**. Every lane alive on that box carried the prefix by
hand, which is why the death reproduced for the controller and never for an operator. So the tmux arm
now refuses **loudly** a spawn it cannot give a credential to (`wt_spawn` refuses and names every
place it looked) instead of starting a worker that will stop at its first `gh` call.

Two ordering rules in that contract are load-bearing, both measured (2026-10-22):

- **`HOME` is re-asserted AFTER `keys.env` is sourced.** A `HOME=` line inside `keys.env` is exported
  by the `set -a` source and would otherwise repoint the worker at a home with no credential — the
  exact silent death the gate exists to refuse, reported as provisioned. (Same two-step shape as
  `cloud-cell-supervisor.sh`: pre-source so `$HOME` expansions inside the file resolve to the cell
  home, post-source so the file cannot move it.) Keys are sourced under `set -a` … `set +a` for the
  same reason the supervisor does it: an assignment without `export` is legal there.
- **A caller's `GH_TOKEN` counts as provision only when this spawn CREATES the tmux server.** Against
  an already-running server a `new-session` gets the SERVER's global environment (measured on tmux
  3.4: no `GH_TOKEN` in the pane, `unknown variable` from `show-environment`), because `GH_TOKEN` is
  not in tmux's `update-environment` list. So with a server in place, the credential must be in the
  worker's HOME/`keys.env` or in the server's own environment — either name, non-empty; else refused.

A `none` verdict is **not** allowed to be mute: `wt_launcher_why` carries the probe's own answer (one call, stderr only) into the controller's `[startup]` line — `[startup] worker launcher=none (cmux=yes, uname=Linux) — cmux tree --json failed (rc=1): cmux: cmux-tui daemon binary not found at …` — and into `wt_spawn`'s `none` refusal (`REFUSED … — why: …`; the other thirteen `REFUSED` lines report their own failure directly and do not repeat it — fourteen in total, re-counted after the rebase onto main, which added four). Measured on cell-1, 2026-10-22 (agent-infra#2366): without it, `launcher=none` was indistinguishable from a tty gate, a `TERM` gate, a drifted probe shape or an absent daemon, and the diagnosis it was already holding took an investigation to re-derive. The suffix appears **only** for `none`; `tmux` on launchd and `terminal` on a cell are healthy states and are not stamped `failed:`. A `none` startup line costs **two** `cmux tree` calls (the verdict's and the reason's) — a pinned count, not a guess.

There is **no env override** for the launcher: a gate an agent can defeat with an export is not a gate.
(`WT_WORKER_HOME` is not a launcher override — it names the HOME that holds a worker's credentials, an
input to the environment contract.)
Around the spawn, three properties hold:

- **the concurrency caps still bind** — `wt_count` reads ONE census (`cmux tree --json` plus the tmux
  session list, memoized in `state/.wt-census` for `WT_TABLE_TTL=10`s (the absent-owner confirmation window is `WT_ABSENT_CONFIRM=60`s — overridable, but `0` is NOT "off": it is coerced to 60, because zero would confirm on ONE sample), because every caller reads it
  through a command substitution), and a worker is identified the way its launcher named it: by the
  `wt-<worker>` workspace for the layout grammar, and by its **terminal id** (recorded at spawn) for
  `surface new-terminal`, which takes no name. Its polarity is fail-CLOSED in BOTH halves: a `cmux
  tree` that cannot be read counts its workers ALIVE, and so does a `tmux ls` that fails with anything
  other than the genuine `no server running` — a daemon or socket in trouble can never raise a ceiling,
  and a reap never deletes the record of something it could not look at;
  ⛔ **but "cannot be read" is not "is not there", and the difference is the whole census.** An
  ABSENT session owner is a *reading*, not an unreadable one: a terminal lives inside the session
  owner, so `cmux tree` answering `cannot connect to session socket …: Connection refused` (empty
  stdout, nothing listening) means no durable terminal exists, and once that answer is **CONFIRMED —
  two samples at least `WT_ABSENT_CONFIRM` (default 60 s) apart** — its records are **dead**; a single
  refusal only opens the window and keeps the caps binding (a hard-killed owner leaves pty children
  behind, and a restart window is seconds), while a readable census — or a successful terminal spawn,
  which proves the owner answered — or ANY answer that is neither readable nor absent (a banner, the `cannot connect …: No such file or directory` wrapper) closes it again, and a stamp older than `WT_ABSENT_STALE_MIN` = **max(4×`CYC`, 2×`WT_ABSENT_CONFIRM`)** (never narrower than the window) — or one dated in the future — is treated as a first sample rather than a confirmed one. This is the same polarity the tmux half already
  applies to `no server running`. A daemon that ANSWERS with something
  undecodable (a banner, a drifted shape, `cmux: cannot read`) is still UNKNOWN and still pins every
  cap. Without that distinction there is no bound anywhere between "unreadable" and "slot held":
  measured 2026-10-24, a dead daemon left 18 stale worker records counted as 18 live workers for 26h,
  `wt_close` could never PROVE a close (its verification read was the same unreadable census), the
  review-lane ceiling never fell (`review lanes=11/6`), no review was dispatched for 8 NEEDS-REVIEW
  PRs, the PR queue could not drain, and the issue path stayed shut over 175 candidates
  (agent-infra#2653);
- **each worker still has its log** — `logs/<worker>.log` is unchanged. What an operator can read
  AFTER the fact depends on the surface, and the difference is deliberate:
  - a **durable terminal** worker gets `state/run-<worker>.sh` (the exact command, verbatim) and
    `state/env-<worker>.sh` (0600, the exported names) — it is a login shell and inherits nothing;
  - a **tmux** worker gets `state/worker-<worker>` carrying `kind=tmux`, **`home=`** (the HOME it was
    given, i.e. where its credential came from), `cwd=` and `created=`, and its launch line is the
    session's own command — `tmux list-panes -t '=merge-42' -F '#{pane_start_command}'` (no `-p`: tmux
    3.4 answers `unknown flag -p` and exits 1);
  so the audit artifact exists on every surface, and the one that carries the environment contract
  says which HOME it carried;
- **a worker's environment travels explicitly (on a cmux surface)** — a durable terminal does NOT
  inherit the caller's shell (measured: no `DEEPSEEK_API_KEY`/`GH_TOKEN`), so `wt_spawn` writes
  `state/env-<worker>.sh` (mode 0600, the controller's exported names) and the run script sources it.
  On a **tmux** surface (macOS launchd, or a Linux cell) the contract is different and explicit: the
  launch line exports `HOME` — the one that actually holds the `gh` credential — sources that HOME's
  `keys.env` when it exists, sources `pi-keys.env` **when it is the file that assigns the model-key
  variable** (that file is `<home>/pi-keys.env` on a Mac, where the LANE MODEL credential lives; one
  carrying only other settings is NOT sourced, so box-local knobs do not belong there), and exports
  `O`; a box where that produces no credential is REFUSED. Two credentials are gated, both
  BEFORE any session exists: the `gh` token and the model key `models.json` names for the lane
  provider. The model key may come from the caller (only when this spawn creates the server), from a
  file the launch line sources, or from the tmux SERVER's own global environment — and the caller-side
  pre-check is given exactly the environment the pane would inherit, so the gate's answer and the
  pre-check's answer cannot disagree. The launch line also **pins the pair** it resolved
  (`PI_LANE_PROVIDER` and `PI_LANE_MODEL`) so the lane runs, and bills, the provider whose credential
  was checked. The pair is resolved in the order the launch line establishes it: `keys.env` then
  `pi-keys.env` (last non-blank value wins), and **then the caller's own exported
  `PI_LANE_PROVIDER`/`PI_LANE_MODEL`** — the caller is a source too, and a value it names is measured
  and pinned like any other. What is *cleared* rather than inherited is a model **no** source names, so
  a stale value on the tmux server cannot land beside a provider the gate checked; the lane's own
  `${PI_LANE_MODEL:-deepseek-flash}` default then applies.

The stale-worker reap targets the same census (`reap_stale_workers()` → `wt_close`), because the
workspace, not a session name, is now the identity: `wt_close` closes the terminal + workspace and
**returns non-zero, keeping its record, unless it can prove the surface is gone** — so an unverified
kill is retried next cycle instead of being counted.

## 3. Prerequisites

| Dependency | Why | Notes |
|---|---|---|
| `tmux` | the worker surface on macOS (the launchd surface) **and on a Linux cell** (where the guest cmux CLI cannot run), and half of the liveness census | `brew install tmux`. ⛔ A cloud cell DOES use it for workers — with the environment contract (`HOME` + `keys.env`); a tmux worker started without that contract is the measured `~21 log lines` death, and `worker-terminal.sh` refuses that spawn rather than starting it (see §2.1) |
| `gh` (authenticated) | all queue + PR operations | needs push access to the target repo |
| `pi` on `PATH` | the worker runtime (`pi -p --provider ${PI_LANE_PROVIDER:-deepseek} --model ${PI_LANE_MODEL:-deepseek-flash}`) | the resolved default is `deepseek/deepseek-flash` — an id that exists (agent-infra#2208). Both halves are **env-overridable** (`PI_LANE_PROVIDER`, `PI_LANE_MODEL`), read in the shared `run_agent` (`spawn-gate.sh`, sourced by `lane.sh`/`fix-one.sh`/`nonblocking-dispatch.sh`) **and** in `merge-one.sh`'s own `run_agent` (the `chain-<N>` first-review path), which deliberately default identically — set them **in `keys.env`**, because the controller and doctor sessions re-source that file and do not inherit an ambient export. The resolved pair is written to each lane's log as `[agent] provider=… model=…`, and `cloud-cell-supervisor.sh check` REPORTS the pair and whether the box's `models.json` lists it. That report never refuses: pi merges its own built-in catalog with the box's list (and `modelOverrides`), so absence from the file is not proof the id fails — `pi --list-models <id>` is the authority |
| `uv` | `lane.sh` runs `uv sync --extra embeddings --extra parity` in each worktree | tortoise-specific; `refresh-candidates.sh`'s SCOUT venv is repo-aware since agent-infra#1736 (skipped when there is no `pyproject.toml`; the extras are read from that project) |
| `python3` | `orch-loop.sh`'s required-check classifier and `fix-one.sh`'s failing-check list | absent, the classifier returns an empty verdict, no case arm matches, and **every PR is skipped in silence** |
| `~/.pi/agent/scripts/record-review.sh` | writes the HMAC-signed review marker the `ai-review-gate` check verifies | shipped by `agent-infra`; **gate mode only** — a repo that does not require the gate consumes no such marker, so `merge-one.sh` does not mint one there. A cell's `start` provisions it when the cell has none — see below |
| **the operational layer** (`~/.pi/agent/{scripts,extensions,skills,AGENTS.md,settings.json}`) | a lane is only as guarded as its `pi`; without the layer a box has **no review-enforcer, no verification-gate, no main-worktree-guard, no search-guard, no audit-logger, no skills** | installed by `pi-bootstrap/cell-install.sh`, and on a cell it runs from `cloud-cell-bringup.sh --check`. Measured 2026-10-15 on a live cell: `scripts/` did not exist at all (24/24 declared farm files absent), and the merge path died `rc=127` on the missing `record-review.sh` (agent-infra#1723) |
| **`AI_REVIEW_GATE_KEY`** | the merge authority — env var, or `~/.pi/agent/.ai-review-gate-key` | **this harness cannot merge a gate-mode repo without it.** Treat as a secret; never commit it |
| **`DEEPSEEK_API_KEY`** | the WORKER RUNTIME's provider credential — `pi -p --provider deepseek` (in the shared `run_agent` that `spawn-gate.sh` defines, sourced by `lane.sh`/`fix-one.sh`, and in `merge-one.sh`) cannot authenticate without it | `start` publishes the NAME (never the value) into tmux `update-environment`, so a worker the controller spawns inherits the value the controller sourced from `keys.env`. Measured 2026-10-16: with the name absent a cell still MERGES (the rail needs no agent) while every review and fixer died `No API key found for deepseek` — RUNNING, burning its dispatch capacity, unable to review, fix or dispatch (agent-infra#1852). `keys.env`/the shell is the authoritative source: a listed name the creating client lacks is STRIPPED by tmux, so a value living only on the tmux server is not a supported configuration. Treat as a secret; never commit it |
| the target repo's branch protection | the REQUIRED-check list and the merge authority are read from it at runtime (agent-infra#1764) | `gh api repos/$OR/branches/main/protection/required_status_checks`. `REQ=…` in the cell env / `keys.env` overrides the read. Unreadable → `FALLBACK_REQ` (non-empty, fail-closed). Requires admin read on the repo, else the fallback applies every cycle and nothing merges |
| `REVIEW_GATE` (optional) | names the check that IS the merge authority — the repo's gate | defaults to `ai-review-gate`; set it only for a repo whose gate has another name. It is read from the environment, so an ambient/`keys.env` value takes effect: **an override that changes the merge authority away from what the repo's own declaration gives is logged** as `⚠️ … CHANGES the merge authority`, naming the consequence. On a rail repo a flip to `gate` authority means a RAW merge (no head-bound evidence), so treat that line as an error, not noise |
| a collision pre-flight tool | `refresh-candidates.sh` refuses overlapping dispatches | resolved **per repo** (agent-infra#1736): the target repo's own `tools/collision_preflight.py`, else a tortoise checkout (`TORTOISE_REPO`, or its legacy `TORTOISE` alias). The tool requires **Python >= 3.12** and refuses an older interpreter with exit 3 and no verdict, so the selected interpreter (scout venv, or a bare `python3` when there is no `pyproject.toml`) is version-gated: `--check` and the refresh both refuse a too-old one (permanent `rc=3`) instead of queueing nothing in silence. `SCOUT_PY` pins the interpreter, like `SCOUT_UV` pins `uv`. Put `TORTOISE_REPO` in `keys.env` — the controller session re-sources it, while an ambient-only export does not reach a pre-existing tmux server |
| `.worktrees/` gitignored in the target repo | worktrees are created under it | `git check-ignore .worktrees` |

**`cloud-cell-supervisor.sh check` vouches only for what it actually probes, and refuses to certify
a cell missing any of them: `tmux`, an authenticated `gh`, `git`, `python3`, `pi`, a cloned repo
whose `origin` remote names the SAME repo the queue dispatches (`OR` is derived from it; a mismatch,
or a pair that cannot be read, is refused naming both values — agent-infra#1901), a checkout
with the worker scripts in `$O`, and — since agent-infra#1717 — a non-empty, executable
`~/.pi/agent/scripts/record-review.sh` with its `lib/diff-normalize.py` sibling.** The rest of the
table is *not* a refusal by name: a missing `AI_REVIEW_GATE_KEY` is a **warning** — a keyless cell
still runs a controller and is still a **MERGE ACTOR** (`gh pr merge --auto` does not go through the
key; see the ⛔ measured note at the top of `cloud-cell-supervisor.sh`), it just cannot complete a
*signed* merge in a gate-mode repo. **`DEEPSEEK_API_KEY` is the same shape, one step further:**
`start` now publishes the NAME into tmux `update-environment` (agent-infra#1852, below), but `check`
does **not** probe that a VALUE exists anywhere — a name held by neither `keys.env` nor the ambient
shell is stripped by tmux, so every review and fixer still dies `No API key found for deepseek` while
`check` prints the banner. That probe is #1852's candidate fix 3, deliberately NOT claimed by
agent-infra#1896: it has its own false-block risk (a value that lives only in the key FILE, or a cell
provisioned for a provider other than deepseek), so it is tracked on the issue rather than asserted
here. Do not read `CELL CAN RUN A CONTROLLER` as proof that a worker can authenticate.

The `.worktrees/` gitignore is not probed at all, and
`tools/collision_preflight.py` is not a dependency `check` refuses on by that name: the only by-name
read in `cloud-cell-supervisor.sh` itself is `repo_vendors_tool()`, which uses it solely to decide
whether an operator's `TORTOISE_REPO` is relevant. The refusal is indirect but real — the #1736
dispatch-provisioning probe (`refresh-candidates.sh --check`, which `cmd_check` runs) reads that same
literal path and refuses a repo that resolves no copy of it — so `check` does refuse that cell in
effect.
Its verdict is the literal line `CELL CAN RUN A CONTROLLER`, so a dependency that is absent must
fail *there* — a cell that is blessed and then discovers the gap mid-review pays for the discovery:
`git`, `python3`, `pi` and `~/.pi/agent/scripts/record-review.sh` are fatal, `uv` warns (as it does
in `install.sh`) — but the #1736 dispatch probe (`refresh-candidates.sh --check`, which `cmd_check`
runs) refuses a `pyproject.toml` repo whose scout venv has to be built while `uv` does not resolve on
`PATH`, so `uv` is fatal in effect there. And `start` provisions the record step from this checkout
when the cell has none (agent-infra#1717).

**Single-host assumption.** Everything is local: tmux sessions, worktrees, logs, the key.
There is no scheduler, no queue service, no shared database. Two boxes running this against
the same repo work fine *because* GitHub is the coordination medium — but they will duplicate
work unless they coordinate (see §5, "broad mode").

### GitHub API surface — the REST adapter (`gh-rest`)

The harness reaches GitHub through `gh`, whose hot paths (`pr view`, `pr checks`, `pr list`,
`issue list`) are **GraphQL**. GraphQL has its own secondary limit, and when GitHub refuses it the
failure is silent rather than loud: measured 2026-10-17, every GraphQL call returned
`graphql_rate_limit` (even `{viewer{login}}`) while the primary quota still read `4511/5000` and the
REST endpoints answered normally. A five-minute window with **every harness process killed** did not
clear it.

That one asymmetry stopped both halves of the harness, and neither log line named the cause:

| Capability | Broken call | Symptom |
|---|---|---|
| dispatch | `fleet_state.py` board read (`gh pr list`) | *"the GitHub board could not be read"* → board stale → claim gate `INCOMPLETE` → backlog 0 |
| merging | sweep per-PR reads (`gh pr view`, `gh pr checks`) | `NOCHECKS` → fail-closed → **no PR could merge** (19 mergeable PRs, hours) |

`gh-rest/gh` is a PATH shim that supplies the REST equivalents for exactly those shapes and
**delegates everything else verbatim** — including `gh api`, which is already REST:

| Translated | REST endpoint |
|---|---|
| `pr view --json …` | `GET /repos/{o}/{r}/pulls/{n}` |
| `pr checks --json …` | `GET /repos/{o}/{r}/commits/{sha}/check-runs` |
| `pr list --json …` | `GET /repos/{o}/{r}/pulls?state=…` |
| `issue list` / `issue view --json …` | `GET /repos/{o}/{r}/issues…` (PRs filtered out) |
| `pr ready` | `POST …/pulls/{n}/ready_for_review` |
| `pr merge` (incl. `--match-head-commit`) | `PUT …/pulls/{n}/merge` |
| `pr comment --body` | `POST …/issues/{n}/comments` |

### The layer underneath: `gh-limit` (#1988)

Four boxes act as **one GitHub account**, so they share one REST bucket and one GraphQL bucket.
Nothing serialised the harness's calls and nothing backed off when a box was refused, so one box's
burst became another box's secondary limit — and the refused call was read by its caller as "no
data", which is how a cell that could not merge looked like a cell with nothing to do.

`gh-limit.py` is the one implementation of GitHub's documented policy (serialise; honour
`retry-after`; honour the bucket's `x-ratelimit-reset` when it is empty; otherwise wait at least a
minute and grow exponentially; fail after a bounded number of attempts). Serialising alone decides
*who goes next*, though, and thirteen lanes asking for the **same** read queued thirteen times for
one answer already known after the first — measured `gh pr view` 0.676 s at 3 lane processes and
63 s at 13, on 4658/5000 quota. So identical concurrent **reads** are now coalesced (#2243): one
in-flight load per normalised request, waiters share its result (or its failure, at the leader's exit
code), the wait is bounded (past it the caller gets a distinct `busy`, exit 75, naming the holder's
age), a dead or overrunning leader is taken over, and mutations are never coalesced. The per-box
`flock` is unchanged and still what guarantees one request in flight.

It is reached from two thin
entry points, both of which put it FIRST on the harness's `PATH`, so no call site has to remember it
and no new call site can forget it:

| Entry point | Where | Installed by |
|---|---|---|
| `gh-rest/gh` (the REST adapter above) | Mac | `install.sh` → `$O/gh-rest` first on the daemon PATH |
| `gh-limit/gh` (nothing but the layer) | cloud cells | `cloud-cell-supervisor.sh` → `$O/gh-limit` first on the controller PATH **and** published through tmux `update-environment`; `deploy-crossbox.sh` seeds the same two files and passes the PATH on the controller's `new-session` line (it does not touch `update-environment`) |

⛔ **The shim has to be re-asserted after the tool-dir prepend.** Every gh-calling harness script
opens with `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts a REAL `gh` ahead of the
seeded shim on any box whose gh lives in one of those dirs (measured: on the Mac it does), leaving
an inert layer that reports protection and provides none. `orch-loop.sh`, `merge-one.sh`,
`fix-one.sh`, `lane.sh` and `chain-merge.sh` therefore re-prepend `$O/gh-limit`/`$O/gh-rest` after
that line — and so does `nonblocking-dispatch.sh`, which calls no `gh` itself but spawns a whole
worker session in-process, so its PATH becomes that worker's PATH.

The predicate, exactly: **every `*.sh` in this directory that prepends those tool dirs AND invokes
`gh` must carry BOTH stanzas** (`$O/gh-limit` and `$O/gh-rest`), plus `nonblocking-dispatch.sh` for
the spawning reason above, and `gh-limit.test.sh` fails naming the file and the missing stanza. It is
a per-file two-line obligation — not an unpickable one — and a new script written outside this
directory is not covered by it. Two further entry paths exist so the common callers do not depend on
that obligation: the Mac adapter already resolves the layer for every call it serves, and the
heartbeat's own telemetry tools (`objective.py`, `merge-queue.py`, `beta-progress.py`,
`ask-owner.py`, `turn-classify.py`, `turn-end.py`, `undelivered-answers.py`, `pr-doctor.py` —
EIGHT, not the nine this list carried before agent-infra#1874 retired `retired/queue-dispatch.py`;
a retired tool is not in the beat, so it is not counted here) prefer `$O/gh-rest/gh` then
`$O/gh-limit/gh` over their pinned real binary — derived from `$O`, never from PATH.
⛔ THAT DOES NOT KEEP #1872'S PIN BY ITSELF: the layer resolves the real
`gh` by walking PATH, so the tools that have a pinned candidate hand it through as
`GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH`; the three that never had one let the layer walk.

Why two entry points rather than one: moving the call sites onto REST is #1978/#1986's change, and
mixing a REST translation into a cell with a new backoff would make a translation bug and a backoff
bug indistinguishable. The wrapper therefore translates nothing; the REST adapter additionally
translates, and both call the same helper.

Notes worth keeping:

* **Single flight is per box, not per account.** Boxes cannot see each other; what this buys is a
  burst of 1 per box instead of 1 per lane. The lock is held per ATTEMPT and released across the
  wait, so a sleeping caller does not park the box — the invariant is "no two requests overlap",
  and the `/rate_limit` probe, which runs during backoff, holds it too.
* **A successful call is invisible** (stdout/stderr replayed byte for byte) because callers parse
  merged output. Retries are announced in `$GH_LIMIT_DIR/events.log`; only a FINAL failure writes to
  stderr.
* **A limited box says so**: `$GH_LIMIT_DIR/last-limit` is printed by `orch-loop.sh`'s cycle line as
  `gh=rate_limited(bucket=graphql reset=<epoch> until=<epoch> <age>)`, age-bounded to 15 minutes so a
  past limit cannot pass as a current one — and as `gh=recovered(bucket=… <age>)` once a later call
  succeeded, because a record is not a state. `until=` is the window the box honours; `reset=` is the
  bucket's own. The failure text carries the words "rate limit", which is the
  phrase `objective.py`'s transport markers turn into `VERDICT=GH-RATE-LIMITED`.
* **The waits belong to the call sites that can afford them.** `GH_LIMIT_NO_WAIT=1` makes the layer
  record the limit and return at once (and bounds the LOCK wait to `GH_LIMIT_NO_WAIT_LOCK_S`, 5 s, so
  a busy box cannot queue a 90 s reader to death); the EIGHT heartbeat tools set it (it was nine
  until agent-infra#1874 retired `retired/queue-dispatch.py`; the count is the same eight
  `docs/ops/gh-rate-limits.md` lists), because they are killed at 90-420 s while the first documented
  backoff is 60 s — sleeping there converts a
  RATE-LIMITED verdict into a timeout. The shim is also `exec`'d, not spawned, so a caller's timeout
  or `run_bounded`'s TERM kills the helper instead of orphaning it mid-backoff against a bucket
  GitHub has already refused.
* **A shim is identified by its own sentinel line** (`harness-gh-shim-marker`), not by the helper
  beside it: the missing helper is the fail-open state, and keying identity on it made two shims
  resolve into each other and every gh call exit 127.
* **Conditional REST is a GET only.** `gh api <path>` (optionally `--jq`) stores its ETag per URL and
  replays a 304 from cache — free, because a 304 is not charged to the primary limit. The cached body
  is base64 (`byte-exact` on replay, binary included) and the cache is bounded, since every distinct
  poll URL earns an entry. Any shape whose output this layer would have to re-create by hand
  (`--paginate`, `--template`, `-H`, `-f`, a non-GET method) is left completely alone, and an
  unframeable response is returned AS-IS — never re-requested (a second request on a box that is
  being refused is exactly what the layer exists to prevent; the suite pins one request, no re-run).

**Design: an adapter, not a fork.** No harness file changes, so every cell stays on one harness
version — the convergence property this repo exists to protect — while the API surface becomes a
deployment concern. `install.sh` copies the shim to `$O/gh-rest/gh` and puts that directory **first**
on the daemon `PATH`, so controller, lanes, chains and merge workers all inherit it.

**Two deliberate refusals.** `pr merge --auto` is a GraphQL-only mutation (REST cannot express
auto-merge), so it is *delegated* — it fails loudly while GraphQL is refused rather than pretending
to have armed. And nothing is guessed: a failed REST call exits non-zero with the API's own message
instead of returning an empty result that would read as "nothing to do".

**The rule that keeps it honest:** a flag or filter the adapter does not model **delegates the whole
call** to the real `gh`. It never drops a flag and answers anyway — dropping one is not a slow answer,
it is a *wrong* one. Review of the first draft found that same bug at three severities, each of which
would have caused the failure the adapter exists to prevent:

| Dropped | Consequence |
|---|---|
| `pr list --head` | `chain-merge.sh` polls for "the branch's PR", gets the newest open PR, **merges an unrelated PR** and records the review marker against it |
| `issue list --label` | the three severity queries return the same unfiltered list, so every issue is tier 0 and P0-before-P2 ordering inverts (#8465) |
| `pr comment` output | `merge-one.sh` cannot extract the evidence URL and **parks every reviewed PR** with a false diagnosis |

**Verify it** (offline; drives a stub `gh`, needs no credentials, 28 assertions):

```bash
bash gh-rest.test.sh
```

The invocations in the suite are **copied from the callers** (`chain-merge.sh`, `refresh-candidates.sh`,
`fix-one.sh`, `merge-one.sh`), not invented — the first draft asserted shapes nobody used and shipped
two P0s green. They pin: `--paginate` returning concatenated arrays; positionals starting at `$3`;
a handler that falls through printing twice; REST's `open`/`true` vs gh's `OPEN`/`MERGEABLE`; REST
`/issues` including PRs; `--limit`; legacy commit statuses (a protection context that is not a check
run); a 200 whose body says `merged: false`; and a failing `--jq` exiting non-zero instead of looking
like "no rows".

**Known gap (tracked separately):** the install stamp and `check-deployed-drift.sh` fold their payload
over `$O/*.sh` only, so this adapter — like `launchd.plist.template` — is outside the deployed-bytes
record. Adding it in one place alone makes every healthy deployment read as drift, so it needs the
stamp, the drift checker and the selftest moved together.

---

## 4. Install

**On a cmux cloud cell**, `scripts/cloud-cell-bringup.sh --check` provisions the toolchain,
the network, the provider, `gh` auth/push, the target-repo clone, the dispatch pre-flight and
**the operational layer** — that last one from the agent-infra checkout already on the cell via
`pi-bootstrap/cell-install.sh`, and it REFUSES to print `CELL READY` if the layer cannot be
installed. Two things a `CELL READY` does NOT speak for, and which the operator still owns:
**`AI_REVIEW_GATE_KEY`** (push it in `keys.env`; what actually ENFORCES it is the
`ai-review-gate` check on each PR — `cloud-cell-supervisor.sh check` only WARNS, and says so)
and **`AGENT_INFRA_PATH`**, which the `AGENTS.md` this step
installs declares as a prerequisite — nothing on the cell sets it (`session-checks` and
`auto-sync` silently skip without it, and `sequence-enforcer` in gate mode reports an
unpassable checkpoint), so export it in the cell session's environment. `cell-install.sh` copies
the farm set that `pi-bootstrap/setup.sh` declares (parsed, not re-listed), every extension in
`manifest.json`'s ship-list except `cmux-session.ts` (a Linux cell has no cmux desktop app),
the skill tree, the sub-agent definitions, `templates/AGENTS.base.md` and a merged
`settings.json`; run it with `--verify` to check an existing cell with no writes.

⛔ **"Installed" and "ACTIVE" are different questions, and the layer answers only the first.**
`docs/ops/ACTIVATION-MATRIX.md` (agent-infra) is the one place that records, per component, how it
becomes active on a Mac vs a Linux cell and whether that is **provisioned** (a shipped file installs
it and a read-back verifies it) or **improvised** (a shell-rc line, a hand-written plist, a symlink
into a worktree, an operator-pushed file — nothing re-creates it). Read it before concluding that a
green `CELL READY` means a guarded lane: two components that decide whether the box is *unattended*
— the argv-level `gh` shim and the controller watchdog — are improvised on the Mac and absent on
cells today. `cell-install.sh --verify` now prints one `activation:` line for the shim, resolved
through the **same** candidates `review-enforcer` reads, so the row is checked rather than asserted.

#### When a cell says it is provisioned and is not — the eight measured signatures

Measured 2026-10-27 while provisioning `pi-cell-1` / cell 3 / cell 4: every row below is a failure an
operator hit **after** some step had reported success. **The gate is the authority; this table is its
index** — `scripts/cloud-cell-bringup.sh --check` fails closed with `CHECK FAILED [<check name>]` (or a
supervisor `FATAL`) and prints the FIX line, so read the refusal, not this table, for the current state
of any single check. Nothing here is a procedure to run *instead* of `--check`.

| failure signature | cause | the command that fixes it |
|---|---|---|
| `cell-install.sh --install` ends right after `LAYER VERIFIED`, and no pin is recorded | the layer is not the cell: the harness pin is created by a **separate** gate, so an install can succeed over a cell that has none (#2909) | `HOME=$HOME CELL_HOME=$HOME bash scripts/cloud-cell-bringup.sh --check` — `check_harness_pin` **refuses** a cell with no pin now; it is the only writer, so there is nothing to run first |
| `FAIL com.eldato.ai-drainer: placeholder(s) this runtime does not know: {{AI_DRAINER_O}}`, `no StartInterval…`, then `the declared job set is BROKEN — refusing …` and the controller dies `rc=1` | shipped job declarations vs shipped runtime (#2908) | fix the declaration in `templates/launchd` and re-run `--check`; `check_schedule` refuses a non-zero `fleet-schedule.py --verify` **or any `FAIL` line** |
| `REPO is not set and no single checkout could be derived` | TWO homes — `/home/cmux` (checkout) and `/tmp/cell-home` (farm/state/keys) | `CELL_HOME=$HOME WORKDIR=$HOME/<repo> bash scripts/cloud-cell-bringup.sh --check`; `check_one_home env` refuses a `CELL_HOME` that is not this box's home, and any cell-state path in `/tmp` outside it |
| 17 jobs `broken target: …/.pi/agent/scripts/… does not resolve — the farm is INCOMPLETE` **while the farm is installed** | the same two homes: the declarations expand `{{HOME}}` to the home the farm is NOT under | the same fix as the row above — one home, re-run `--check` |
| `install-*-timer.sh --status` prints `installed` for a 7-line hand-written `/tmp` shim | a hand-written unit is indistinguishable from a rendered one by name | re-render it: `scripts/cloud-cell-supervisor.sh apply` (or the owning installer's `--install`); `check_one_home units` refuses a rendered unit whose `Environment=`/`ExecStart=` carries a `/tmp` path, and the installer `--status` DRIFT arm (drainer lane) refuses a unit it did not render |
| `FATAL: doctor session 'cell-doctor' belongs to another state dir (…)` | a stale tmux session minted by a **previous** state dir blocks the doctor role | `tmux kill-session -t cell-doctor` — the `FATAL` prints it with the owning state dir; the supervisor never clears another state dir's session (#1856) |
| `FATAL: a controller runs from this machine's shared harness path (pid …)` | a leftover inner-chain member (`tmux → bash -c → orch-loop.sh`) from a previous state dir blocks the first start | `kill <pid>` — the `FATAL` now prints it with each pid's state dir; the supervisor does not signal a pid it cannot prove it owns |
| `claims.sh: line 1205: printf: write error: No space left on device`, controller dead, on a cell that printed `CELL READY` | no reaping **before** lanes: the reaper came from the scheduler that would not start | `bash scripts/orchestrator-harness/disk-reaper.sh --apply --repo <checkout>`; `check_reaping_armed` runs the shared `disk-floor.sh` floor+reclaim pass and refuses a cell still under it after the pass |

**On a Mac (or any box you own),** do all four steps below from the ROOT of an agent-infra
checkout:
```bash
# 1. Run all four steps from the ROOT of an agent-infra checkout — the harness now lives there.
#    Put it where $O will point (default ~/orchestrator): the daemon executes $O/<script>,
#    not the shipped copies.
#
#    ⛔ PREFER THE VERSIONED SHAPE — this is §11's rule, applied to the install step (§11 is why the
#    three-way fork happened: `~/orchestrator` was 8 of 8 files with NO git). Two supported routes:
#      * macOS:  bash scripts/deploy-mac-orchestrator.sh   (copies the harness and RECORDS the commit
#                 + a per-file manifest in $O/.harness-provenance — §4.3; add --dry-run to see the plan
#                 and what it would overwrite without writing anything)
#      * any box: make $O a symlink farm into a git clone, so "which commit is this?" has an answer —
#                 bin/harness doctor reports that as kind=linked-checkout
#
#    ⚠️ THE PLAIN `cp` BELOW IS THE LEGACY ROUTE AND IT IS NOT A FIX PATH: on the symlink-farm shape it
#    does not merely go stale, it FAILS — measured: `cp scripts/orchestrator-harness/x.sh $O/` where
#    `$O/x.sh` is a symlink into this checkout prints `cp: '…/x.sh' and '…/o/x.sh' are the same file`
#    and exits 1, naming no next step. Use it only when $O is a plain directory you intend to keep as
#    one, and re-run it after every harness edit (a copy is not a fix — §11).
mkdir -p ~/orchestrator && cp scripts/orchestrator-harness/*.sh ~/orchestrator/
mkdir -p ~/orchestrator/logs ~/orchestrator/state ~/orchestrator/wip

# 2. Point it at your box. MOST values are overridable with a default; REPO is NOT — see below.
export REPO=$HOME/eldato/tortoise        # REQUIRED: the target repo's local main checkout.
# ⛔ OR is DERIVED from $REPO's origin remote (agent-infra#2040) — do NOT pin it unless this box must
# grade a DIFFERENT repo's queue than the one it dispatches into. A standing literal here meant the
# controller counted one repo's open PRs while dispatching another's issues (measured 2026-10-18).
                                         # FOUR scripts refuse an unset REPO by name:
                                         # orch-loop.sh and deploy-mac-orchestrator.sh exit 78;
                                         # install.sh exits 1 via die(); cloud-cell-quiesce.sh
                                         # exits 1 via ${REPO:?}. deploy-mac-orchestrator.sh
                                         # RELAUNCHES the controller, so its guard runs BEFORE it
                                         # stops the running one. Without that, a shipped default
                                         # naming one developer's home causes one of two things on
                                         # any other machine: REPO missing -> the controller dies
                                         # at startup and crash-loops under KeepAlive; REPO wrong
                                         # but existing -> the refresh aborts every cycle while
                                         # the controller keeps beating. ⛔ SEVEN shipped SHELL
                                         # scripts still carry a REPO default of their own — the
                                         # complete grep over `*.sh`, `retired/` and `*.test.sh`
                                         # excluded:
                                         # refresh-candidates.sh:18, report.sh:24,
                                         # cloud-cell-supervisor.sh:93,
                                         # deploy-crossbox.sh:23,
                                         # pi-reap-worktrees.sh:1174 (`${REPO:-$PWD}`),
                                         # stale-worktrees.sh:35 (`REPO="$PWD"`) and
                                         # stale-main-triage.sh:16 (`${1:-$PWD}`). The `$PWD`
                                         # three are the worst shape: $PWD is `/` under launchd,
                                         # so the default resolves to a real non-repo directory
                                         # and fails later as `not a git repository: /` instead
                                         # of at the REPO boundary. ⛔ TWO of the same class are not
                                         # shell scripts, and they are the rawest form of it — a
                                         # hardcoded home with NO env override, used only to import
                                         # the SDK: `goal-state.py:29`
                                         # (`REPO = "/Users/<someone>/Documents/GitHub/tortoise"`)
                                         # and `seed-goal-map.py:29` (the same literal passed straight
                                         # to `sys.path.insert`). Tracked separately. #1977 covers
                                         # the first and the third; the other five are untracked. So export REPO in
                                         # the daemon AND the session env (#1935).
export O=$HOME/orchestrator              # the harness state directory
export SCOPE=own                         # drain scope: auto (default) | own | broad.
                                         # A fleet runs ONE broad box; the rest pin own (section 5).
                                         # install.sh renders this into the plist (launchd
                                         # inherits no shell env) and refuses a bad value.
                                         # ⚠️ The pin's SAFETY role is retired for dispatch and
                                         # review (§7.2d "Does a claim EXCLUDE?" measured the
                                         # claim excluding there); the landing row KEEPS an exclusion
                                         # requirement, met by the per-PR key. What is left is a
                                         # selection partition, not a claim registry — section 5,
                                         # item 3 (#1908).

# 3. Render + install the launchd agent (does NOT load it). Invoke it BY PATH, from that same
#    repo root: install.sh resolves `launchd.plist.template` from ITS OWN directory, so
#    `cd ~/orchestrator && ./install.sh` dies with "missing template" — step 1 copies only *.sh.
bash scripts/orchestrator-harness/install.sh

# 4. Start it when you mean to — and have the start PROVEN, not assumed.
#    install.sh --start renders, then `launchctl enable` → `bootout` → `bootstrap` (falling back to
#    the legacy `load` if bootstrap fails), then verifies the label has a PID **and** that
#    ~/orchestrator/heartbeat advanced. It exits non-zero with one actionable line if either fails.
#
#    Two tunables, both optional: `START_TIMEOUT` (seconds to wait for that pid+heartbeat, default
#    30) and `LC_HB_STALE` (how old the heartbeat may be before a LOADED job counts as "not
#    cycling", default `2*CYC + 300` — derived from this cell's cycle, because a fixed bound fails a
#    healthy CYC=900 cell). A validation run (no flag) touches no launchd state at all.
#
#    ⛔ NEVER `launchctl load -w` / `unload -w` here: `-w` writes a PERSISTENT Disabled override
#    (`man launchctl`), so an unload/load pair whose bootstrap fails leaves the controller
#    removed AND disabled, silently. Measured 2026-10-17: 48 min of dead dispatch, then 19 more
#    (agent-infra#1975).
bash scripts/orchestrator-harness/install.sh --start
```

Step 3 also records **which harness commit this box runs** in `$O/.agent-infra-stamp.json`
(agent-infra#1745; see §9). Run `install.sh` from the agent-infra checkout as shown — if the source
is not a git repo the record reads `UNKNOWN` and `check-deployed-drift.sh` exits 2 rather than
passing, which is the intended fail-closed behaviour and not an install failure.

### 4.1 Redeploying an existing box — `deploy-harness.sh`, and what a success is allowed to mean

**The supported *manual* redeploy path is `deploy-harness.sh`** — the one an operator runs by hand,
and the one this section specifies. It is not the only code that writes `$O`, and saying so would be
the same overclaim this file exists to remove. The others, named with the gap each still carries:

| Path | What it still does |
|---|---|
| `install.sh` (step 3 above) | places **no `*.sh` in `$O` at all**: it seeds only `$O/gh-rest/gh` (`install.sh:539`) and `$O/gh-limit.py` (`install.sh:556`), no per-file verdict. The `*.sh` payload on a first install is §4 step 1's manual `cp scripts/orchestrator-harness/*.sh ~/orchestrator/` — depth-1 only, so `gh-limit/gh` and `retired/` are never covered by it. Its `DRIFTED`/provenance warnings now name `deploy-harness.sh` as the remedy (`install.sh:822`, `:1003`). It is the FIRST install; use it, then `deploy-harness.sh` for every redeploy |
| `deploy-mac-orchestrator.sh` phase A (`:292-296`, with `install_file` at `:106-110`) | `cp -R` for subdirectories and `install_file` for files with **both rcs unchecked**, then reports `copied $(ls "$H" | grep -vc …)` — a count of the *source listing* — and cmp-verifies **only `claims.sh`** |
| `deploy-crossbox.sh` step 3 (`:57-92`) | depth-1 `cp -p "$H"/*.sh "$O"/`, then `seeded $O with $(ls "$O"/*.sh \| wc -l)` — success evidence read from the **target**, the exact formula #2041 names |
| `cloud-cell-supervisor.sh seed_and_stamp` (Linux cells, `:1281`; called at `:1872`, `:2523`) | the wired path on a cell; agent-infra#2039 tracks that it does not seed `$O/gh-rest` |
| `cloud-cell-quiesce.sh` step 4 (`scripts/cloud-cell-quiesce.sh:74-79`) | the cell-recovery redeploy: `cp "$HARNESS"/*.sh "$O"/ 2>/dev/null || true` — depth-1, **rc discarded**, then `seeded $O with $(ls "$O"/*.sh | wc -l)` read from the **target**, and a controller started on it (`:89-92`). That is all three mechanisms #2041 names, verbatim; it is listed here rather than quietly omitted |
| `orchestrator-bringup.sh deploy_harness` (`scripts/orchestrator-bringup.sh:640`, called at `:1042` — the `harness-up` / `bin/harness start` path) | depth-1 `cp -p "$HARNESS_BRINGUP"/*.sh` with stage-then-rename and a plan printed before writing, but **no post-copy byte verification**: the `cmp` at `:652` feeds the plan message, and `:693`'s "deployed N harness script(s)" counts the SOURCE listing. It seeds `$O/gh-rest/gh` but neither `gh-limit.py` nor `$O/gh-limit/gh`, and never `retired/` |

Routing those through this helper is the remaining #2041 work; until then the table above is the
honest statement of coverage.

```bash
bash scripts/orchestrator-harness/deploy-harness.sh \
  --repo . --o ~/orchestrator          # or --src <harness dir>; notifies $O/bg/notify.sh
```

Exit `0` means **DEPLOYED AND VERIFIED**, and that phrase is a conjunction of three facts about
*this run*: the source shipped ≥1 file, every one of those files was copied by this run, and every
one compares byte-for-byte equal at the target (with the executable bit intact). Nothing is ever
counted from a listing of the target — a runtime full of the previous deployment's scripts cannot
make an empty deploy look successful, which is the exact defect this replaced (agent-infra#2041:
`bg/finish.sh` ran a bare `cp -R`, ignored its rc, and then notified `convergence COMPLETE` quoting
`$(ls "$O"/*.sh | wc -l)` — the *previous* deploy's files — as this one's evidence. Measured
consequence: `gh-limit.py` and the `gh-limit/` shim were missing from a deployment everyone believed
current, so every harness `gh` call was unserialised and unbounded).

Exit `1` = the copy or the verification failed; `78` = refused **before touching the target**
(source absent, source is not a harness — all five identity anchors: `orch-loop.sh`, `claims.sh`,
`gh-limit.py`, `gh-rest/gh`, `gh-limit/gh` — the source's inventory could not be read in full, the
source ships a symlink, a **symlinked directory** sits on the deploy path under `$O` (writing through
it would land the bytes outside the runtime the operator named — the same escape as a symlinked
target file, one directory up), source and target overlap, the source ships no files, target is not a
directory). **A refusal writes nothing at all, not even the ledger.**

Notifications: every path that reaches the preflight emits a failure notification naming its cause,
and no path emits a success one. The argument-parsing refusals (`--src` with no path, an unknown
flag) happen *before* the notifier is resolved and exit `78` on stderr only — they never claim
anything about a deploy.

`$O/.deploy-ledger.tsv` is the per-file evidence (`copied` / `verified` / `COPY-FAIL` / `DRIFT` /
`MODE-UNSET` / `STALE-STAMP` / `STAMP-UNCHECKED` per path, plus the verdict line). `DRIFT` covers a
byte difference, a lost executable bit, a mode that differs from the source, and a symlink at either
end; `MODE-UNSET` records a path whose mode could not be read at all (no usable `stat`), which the
VERIFIED line also says out loud. It is written only once a copy has
been attempted, so it is never present in a runtime that was refused, and `check-deployed-drift.sh`
ignores it (it hashes `*.sh`). If the ledger cannot be installed the bytes are still verified, but the
verdict says the evidence file is missing rather than pointing at one that does not exist.

**This proves the COPY. It does not prove the RELATION, or that nothing extra is running.** After a
redeploy, `check-deployed-drift.sh` is the complement **for the top level of `$O`** — it hashes every
`*.sh` the repo ships at the ref **directly under the harness dir**, requires every one to be present
in `$O` with the same git blob, and requires `$O` to carry no `*.sh` the repo does not ship, so a script
retired two releases ago does not keep running behind a verified deploy. Run both.

⛔ **AND KNOW ITS EDGE — this helper deploys more than that gate compares.** The gate's repo side is
`ls-tree … | grep -E "^${REL}/[^/]+\.sh$"` (`check-deployed-drift.sh:333`), i.e. **depth-1 `*.sh`**, and
its deployed side is `*.sh` in `$O` (`:336`); its own header says so (`:60-62`). This helper copies a
recursive `find`, so **the rule is: every file that is not a top-level `*.sh` is outside that
comparison.** Concretely: `$O/retired/` (six `.sh` and four `.py`), `$O/gh-rest/gh`, `$O/gh-limit/gh`,
`$O/gh-limit.py`, `$O/launchd.plist.template`, `$O/port-provenance.txt` and the two docs.
`install.sh`'s `DRIFTED` list (`install.sh:855`) carries exactly two of them — `gh-rest/gh` and
`gh-limit.py` — never `retired/*` or `gh-limit/gh`. `check-single-source.sh --o` **does** compare
`gh-limit/gh` and the `*.py` against canonical (`check-single-source.sh:260`, `:307-311`) — ⚠️ but NOT
`launchd.plist.template`, `port-provenance.txt` or `retired/*`: `DEPLOY_SET` at `:260` is
`*.sh` + `*.py` + `gh-rest/gh` + `gh-limit/gh` and nothing else (an earlier draft of this paragraph said
"the template" and was wrong — a tampered `$O/launchd.plist.template` is MISSED, which matters because
`install.sh:133` reads that file when install.sh is run from `$O`). It also **skips a missing file**
(`:308` is `[ -f "$O_DIR/$f" ] || continue`), so an **ABSENT**
`$O/gh-limit/gh` is compared by nothing on any path — and a missing shim is exactly what #2041
measured. So "run both" closes the loop for top-level scripts and for a *differing* shim, and not for a
*missing* one: more than the bare `cp *.sh` it replaces, less than *every file*.

⚠️ Two earlier drafts of this paragraph were wrong and are recorded rather than quietly replaced: one
said the shim had "no comparator on any path" (false — `check-single-source.sh --o` compares it for
*difference*), the other said **four** populations were uncovered (false — the set is defined by the rule
above, not by a count). An unverified claim in a file about unverified claims is this issue, so both are
stated here.

**AND THIS HELPER NOW RECORDS THE BOX'S OWN PROVENANCE (`agent-infra`, 2026-10-29).** At the end of a
verified deploy it writes `$O/.harness-provenance` — the source commit, the ref, and a sha256 for
every file the source shipped — through the shipped `harness-provenance.sh`. That record is what makes
*"which commit is this box running?"* answerable **with no checkout present**, and what lets the NEXT
deploy tell a hand patch from its own last run. `check-deployed-drift.sh` reads it FIRST and falls back
to `install.sh`'s `.agent-infra-stamp.json`, so a box that was attributable before this record existed
still is. §4.3 is the operator's page for it.

Because the record is now written by the deploy, a stamp left stale by a redeploy is **superseded**
rather than an alarm: the verdict says `legacy identity record STALE … superseded by
.harness-provenance` and records `STALE-STAMP` in the ledger, but `check-deployed-drift.sh` will no
longer call this deploy *"a post-install hand edit"* — the newer record describes the bytes it just
verified. If the provenance write FAILS, the old advice stands and is printed with it: re-run
`install.sh` to re-record the stamp. `orchestrator-bringup.sh` still does `deploy_harness`, then
`install.sh`.

⛔ **A stamp is only compared when the fold over `$O/*.sh` actually completed.** If any `*.sh` in the
runtime is unreadable (a root-owned `0600` leftover, a script the repo no longer ships) or no
`sha256sum`/`shasum` is present, the verdict says `identity record NOT CHECKED` and records
`STAMP-UNCHECKED` instead — never `STALE`. A partial digest is not a comparison, and a false "run
install.sh to re-stamp" sends the operator to a step whose *own* fold fails on the same file, so the
alarm could not be cleared by following it. The bytes are still verified; only the stamp comparison is
withheld, and it says so.

The helper does **not** restart the controller — restart ownership stays with the caller, because a
deploy helper that restarts cannot avoid claiming a restart. `bg/finish.sh` (unversioned; see #2026)
must call it and gate on its exit code, replacing its old lines 31–36 with:

```bash
      if ! bash "$R"/scripts/orchestrator-harness/deploy-harness.sh --repo "$R" --o "$O"; then
        log "DEPLOY FAILED — main was NOT re-adopted; controller left alone"
        exit 1
      fi
      # ⛔ The restart is a SEPARATE, PROVEN step — never `nohup … &` + `disown` and then a
      # notification. There is no `$O/supervisor.sh`; the shipped restart path is install.sh
      # (launchd: renders, bootout, bootstrap, then verifies pid AND a fresh heartbeat) and
      # orchestrator-bringup.sh restart for the whole stack. Both exit non-zero when the start
      # cannot be proven, which is what the gate below reads.
      if ! bash "$R"/scripts/orchestrator-harness/install.sh --restart; then
        log "DEPLOYED AND VERIFIED, but the controller was NOT restarted (install.sh --restart failed)"
        bash "$B/notify.sh" "orchestrator: deploy verified, restart FAILED" \
          "Re-adopted main; the deploy is VERIFIED (see $O/.deploy-ledger.tsv) but the restart was not proven. The controller is NOT running the new bytes." high
        exit 1
      fi
      bash "$B/notify.sh" "orchestrator: controller restarted" \
        "Re-adopted main; the deploy is VERIFIED (see $O/.deploy-ledger.tsv). install.sh --restart proved the controller is up on those bytes." high
      log "RE-ADOPTED main; deploy verified; controller restarted (proven by install.sh --restart)"
      exit 0
```

That is the whole fix: success stops being a statement the deploy makes about itself and becomes a
verdict reached from its own copy ledger — and neither message can speak for an event the run did not
observe.

### 4.2 Operating an existing box — liveness, uninstall, and the env-var notes

```bash
# liveness / stop
cat ~/orchestrator/heartbeat                 # epoch seconds, should be < ~5 min old
tmux ls                                      # no cmux answer (macOS launchd, or a Linux cell): lane-*, chain-*, merge-*, review-*, fix-*
cmux workspace list                          # a cell: wt-lane-*, wt-chain-*, wt-merge-*, wt-review-*, wt-fix-*
```

`install.sh --uninstall` removes the agent (`launchctl bootout`), **reads the domain back**, and only then
deletes the plist — if the label is still **LOADED** it exits non-zero and keeps the plist instead of
printing ✅ (a `KeepAlive` job sitting inside its respawn throttle is loaded with NO pid, which is why
the verdict is not a pid test), and if the read itself fails it exits non-zero too rather than calling an
unreadable domain "removed". It writes **no** persistent Disabled override, so a later `--start` is a
plain start rather than a start that has to fight a sticky disable first.

Every mutating path (`--start`, `--restart`, `--uninstall`) first checks two things, and refuses with
one line rather than acting if either fails: **`$HOME` must be the real home** (a sandboxed `$HOME`
acts in the real user's domain — agent-infra#446; tests opt in with `ELDATO_ALLOW_TEST_HOME=1` plus a
`launchctl` stub on PATH), and **a job already loaded under this label must be loaded from this
plist** — `launchctl bootout <domain> <path>` resolves the removal by the LABEL it reads out of that
plist (measured), so without that check a sandboxed run would remove the production controller. A
third read guards both of those: `launchctl print` failing is **UNKNOWN**, never "not loaded", so an
unreadable domain (or an unreadable account record) makes the run refuse instead of acting on a guess.

`ELDATO_ALLOW_NON_DARWIN=1` is the suite's test-only bypass of the installer's macOS precondition (the
only automated gate runs on Linux, and `--start`/`--uninstall` are the incident's own path). It is the
same discipline as `ELDATO_ALLOW_TEST_HOME=1` and never applies to a normal run.

⛔ **AND THE LABEL ITSELF IS PART OF THAT CONTAINMENT (agent-infra#1996).** launchd resolves a label in
the USER domain and IGNORES `$HOME`, so a plist rendered under a throwaway home still addresses the
live job by name — "the sandbox has its own `$HOME`" protects nothing. `install.sh` therefore treats a
non-default `LABEL` as a sandbox seam and nothing else: `label_guard` refuses a **non-default** label on
the invoking user's real `$HOME`, and refuses a **production** label (`com.eldato.orchestrator-loop`,
`com.eldato.orchestrator-watchdog`) anywhere but the real `$HOME`. `selftest.sh` installs
`LABEL_OVERRIDE=…-loop-test`, addresses every sandbox plist by that name, and puts a `launchctl` stub on
`PATH` that **exits 97** on either production label — so "no test addressed production" is measured over
the whole run, not assumed.


Run the offline self-test first — it needs no network, tmux server or git writes. **Every check
exercises the shipped script** (it extracts the real classifier, `sess()`, the claim block and the
reaper, or runs `install.sh` for real) rather than re-implementing the logic — a test that
re-implements the fix passes on the broken copy and proves nothing. `need()` fails a check whose
extraction comes back empty, so a check cannot pass by driving nothing; the live total is printed
by `./selftest.sh` rather than quoted here.

```bash
./selftest.sh          # run it for the live list. Covers: syntax, exact session matching, the
                       # fail-closed gate classifier, claim atomicity and stale-claim recovery,
                       # the reaper's keep/reap decisions, rejection of a hostile branch name,
                       # install.sh rendering with a hostile path, limit-default consistency,
                       # placeholder parity, the daemon PATH (shim exclusion + execute-probe) and
                       # the failed-count fallback, README overclaim guards, credential scan,
                       # repo-aware scout provisioning and the permanent/transient refresh split
                       # (refresh-scout.test.sh, #1736)
```

**The gate key only reaches the daemon if it is a FILE.** `install.sh` deliberately does not copy a
secret into a world-readable plist, and launchd inherits no shell environment — so an env-only
`AI_REVIEW_GATE_KEY` is reported as insufficient, not as "present". The box cannot merge without it.

**The load gate is installed as `pi` itself (agent-infra#1884).** `spawn-gate.sh` is double-duty: the
library `lane.sh`/`fix-one.sh` source, AND an executable that both installers copy to
`$HOME/.pi/agent/bin/pi`, one of the first directories on PATH on every surface (and kept in the
runner-gate plist PATH, so the daemon and the tmux children it starts inherit it). Every process that
runs `pi` therefore resolves the GATE, not just the callers that remembered to source it: a
hand-written `tmux new-session -d -s x "… pi -p …"` runner included. That path was the defect —
nothing refused, logged or counted, and the box went to load 258 against its own `MAX_LOAD=100`. A
refusal is loud (1-min load, ceiling, the item, and the calling process), counted in
`~/.pi/agent/state/spawn-gate.tsv` (allowed runs too; bounded by a one-generation rotation at 5 MiB,
because this is the highest-volume sink in the tree and a device that fills silently is #1765's
defect), and exits 76 (a LOAD refusal) or 72 (a MEMORY refusal, #2387), which `run_agent` translates to
the callers' usual `AGENT_LOAD_REFUSED` / `AGENT_MEM_REFUSED` with `AGENT_STARTED=0`. Its stated limits are in the file's header:
the real binary by ABSOLUTE path or a `PATH` reset is not gated (deliberately — that is the
operator's rescue route when the box is over its ceiling, and the refusal message prints it), a
caller that exports its own `MAX_LOAD` sets its own ceiling, and a box where neither installer has
run has no shim. `pi-bootstrap/cell-install.sh --verify` byte-compares the installed copy.

### 4.3 "Which commit is this box running?" — ask it, and read the answer

`$O` is **not a checkout**, so `git` cannot answer this (`cd ~/orchestrator && git rev-parse --show-toplevel`
→ `fatal: not a git repository`). The deploy path therefore leaves a record beside the bytes —
`$O/.harness-provenance`, written by `harness-provenance.sh` at the end of a **complete** deploy
(`deploy-harness.sh`, `deploy-mac-orchestrator.sh` phase B, and `orchestrator-bringup.sh start` — the
three writers that also refuse-to-overwrite and record; the OTHER paths that write `$O/*.sh` are named,
with the gap each still carries, in the coverage table earlier in this section). Plain text, one `sha256  path` line per
file the deploy wrote, so a box answers with no checkout, no network and no `jq`. The manifest is the
**write set**, not the source tree: `start` installs only the depth-1 `*.sh`, so it records only those
(it passes `--skip` for every file it does not write) — a `README.md` that a full deploy put in `$O` is
therefore neither claimed by `start`'s record nor able to refuse a `start` that never touches it.

```bash
# THE ONE-LINE ANSWER — works on a box with no checkout at all
bash ~/orchestrator/harness-provenance.sh show --o ~/orchestrator
#   harness commit 5712e52776c8   ref origin/main   recorded 2026-10-29T10:02:11Z   78 file(s)

# HAS ANYTHING IN $O CHANGED SINCE THAT DEPLOY? (question (a) — names the file, and which side is newer)
bash ~/orchestrator/harness-provenance.sh check --o ~/orchestrator

# IS THE BOX THE CHECKOUT AT $REF RIGHT NOW? (question (b) — needs the checkout; also answers (a))
bash ~/orchestrator/check-deployed-drift.sh --o ~/orchestrator --repo <agent-infra checkout>
```

**The two questions are different, and the report never conflates them.** This was the 2026-10-29
defect: a box printed `harness=diverged:5712e52776c8` for a state the two questions describe
differently, so a diagnosis made against the checkout described code the box was not running.

A box that answers **both** questions cleanly carries **no `harness=` token at all** — its token is
`[current]` inside the `OK:` line. Only a box that does NOT match gets one, because a token in a
dispatch row is a claim that something is wrong:

| summary token | question | what it means | what to do |
|---|---|---|---|
| *(none — `OK: … [current]`)* | (a)+(b) | the record names this commit AND `$O` holds exactly those bytes | nothing |
| `harness=behind:<sha12>` | (a) | the box is recorded from `<sha12>`, an **ancestor** of the ref: a known, deliberate state | redeploy when you mean to adopt the new tip |
| `harness=diverged:<sha12>` | (a) | `<sha12>` is **not an ancestor** of the ref — the box runs code main does not carry | find out why before redeploying |
| `harness=uncommitted-edit:<file>` | (a) | `$O` holds bytes **no deploy wrote** (`<file>` differs from the record) — a hand patch | **recover the patch first**: a redeploy destroys it (§4.1 refusal) |
| `harness=source-dirty:<sha12>` | (a) | the record names `<sha12>` — **this** commit — but its own `sourceDirty=true` (or, for a legacy *stamp* record, `agentInfraDirty=true`) says the deploy was staged from a checkout with uncommitted changes, so `<sha12>` does **not** describe the bytes on the box | redeploy from a **clean** checkout: that is what makes the box identifiable at all |
| `harness=incomplete:<file>` | (a) | the record names `<file>` and `$O` does not have it — the deployed tree is **incomplete**; nothing was edited and no byte differs | redeploy: it **creates** the file; nothing you wrote is discarded |
| `harness=payload-differs` | (b) | the bytes differ from the checkout but the record still describes `$O` (e.g. the checkout moved on) | redeploy to adopt |
| `harness=surface` | neither — not a statement about `$O`'s bytes | a surface hit on a **different** harness dir this box carries (the running controller's, `~/orchestrator`, a cell's copy) is the only failing comparison. It appears in **two shapes**: `$O` was never compared at all — absent, or a `--surface` run that found no readable record for it (the body prints `identity: SKIPPED`) — **or** `$O` was compared and answered clean on all three questions | reseed *that* dir (or move the box onto the pin: `scripts/harness-up`); redeploying `$O` cannot clear it. On the first shape `$O` also has no usable deploy record, so redeploying is what would make the box identifiable |

### Precedence when more than one state is true

`uncommitted-edit:<file>` › `behind:`/`diverged:` › `incomplete:<file>` › `source-dirty:<sha12>` ›
(`surface` | `payload-differs`). The token is ONE line, so the order is the answer to "which fact does
an operator act on first": unrecoverable bytes, then where the box sits, then code that is missing,
then a record that cannot describe the box at all, then the last two.

**`surface` is never a statement about `$O`'s own bytes, and it has TWO shapes.** A token is printed
only when the run found a problem (`problems > 0` in the script), and with no `$O` every question
about `$O` abstains — so the `O_ABSENT` arm can only be reached when the **surface pass** is what
differed. On that shape `$O` was **never compared at all** (absent, or a `--surface` run with no
readable record for it — the body prints `identity: SKIPPED`); on the other shape `$O` **was**
compared and answered clean on all three questions, which is the `Q_BYTES=0` precondition — a
condition on *that* arm alone, not on `surface` as a token. `$O`-absent alone emits **no** token at
all (a clean surface pass is an `OK` summary): the token names a drift, and the drift is always the
other dir.

**The last two are therefore ALTERNATIVES, not a chain:** a surface hit that coincides with `$O`'s
own bytes differing reports `payload-differs` — and the other-directory fact is then carried by the
report body's "for a surface hit, reseed the copy the RUNNING component uses" line, not by the
token. It is stated here rather than left to the `if` order in the code; `check-deployed-drift.test.sh`
§9b grades the `incomplete` over `source-dirty` case, `dirty + behind/diverged` is the other combined
state the chain produces (it reports `behind:`/`diverged:`), and §9g grades the `O_ABSENT` shape —
the one that emits `surface` with no question about `$O` answered.

The refusal has **two directions**, and both matter: a file whose bytes differ from the record, and a
file `$O` carries that the record never saw — *when the incoming source ships that name*, because that is
the file the copy overwrites. (A hand-placed file the source does not ship is merely reported; the deploy
does not delete it.) `harness-provenance.sh check` refuses a record that cannot describe itself — no
record, an unreadable one, `files=0`, or a `files=` count that disagrees with the manifest below it — so a
damaged record can never be the gate's "clean". Three more states are ROUTINE, not edits, and all are
named as such so nobody goes looking for a patch that does not exist: a **`STALE-RECORD`** byte (the
check) or a **`PENDING`** file (the writer) is `$O` already holding the *ref's / source's* bytes while the
record predates them — what `deploy-mac-orchestrator.sh`'s phase-A-only run deliberately leaves behind;
the remedy is a completed deploy, and nothing you wrote is discarded. A **`SAME-AS-SOURCE`** file is `$O`
carrying a name the record never saw *with the source's own bytes*, which happens routinely because each
`write` REPLACES the record: a broad deploy records the docs, then `orchestrator-bringup.sh start`
re-records the box with its narrower write set and those names drop out of the manifest. Overwriting them
with themselves discards nothing, so they are reported and **not** counted — there is no patch to hunt,
and the deploy does not refuse. (A file whose bytes **differ** from the source still refuses, naming it an
`UNCOMMITTED-EDIT`: that one is a real patch, and it is the arm that must never go quiet.) And a record written from a
checkout with uncommitted changes says **`sourceDirty=true`** instead of implying the commit owns those
bytes — `show` prints `(SOURCE WAS DIRTY …)` beside the commit, and the check reports it as an identity
problem (the legacy stamp called the same fact `agentInfraDirty`, and the better record used to MASK it).
A deploy that **stages through a temporary directory** (`deploy-mac-orchestrator.sh` extracts
`git archive <ref>`) cannot derive either of two fields from that directory — it is not a checkout, and
the deploy deletes it — so it states both: `--source-dirty false` (a `git archive` payload is a commit's
tree, so the commit DOES own those bytes) and `--origin <live harness dir>` (what is recorded as
`source=`, which a plain `check` classifies a phase-A leftover against). ⛔ Underived, such a record said
`sourceDirty=unknown`, which the check **refuses** — and since this record is preferred over the legacy
stamp, a mac box that was attributable *lost* its attribution. ⛔ And a manifest line that lost its
`<sha256>  <path>` separator is **UNKNOWN**, never a file named after its digest: `%%` and `#` both
return the whole line when the separator is absent, so the two readers now test for it explicitly.
Two rules keep the gate honest in both directions:
`--src` narrows the check to the files that deploy would actually WRITE (`--skip <relpath>` for a partial
deploy such as `deploy-mac-orchestrator.sh`'s phase A, which never writes `orch-loop.sh`), and a `--src`
that ships no files is **UNKNOWN**, not "nothing to discard". And `write` itself **refuses** to record a
tree whose bytes differ from the source: a record may only ever describe a deploy, never bless a patch.

`check-deployed-drift.sh` prints the question beside each line (`DRIFT(record):`, `DRIFT(identity):`,
`DRIFT(checkout):`), and **a missing or unreadable record is exit 2 — UNKNOWN, never "clean"**. An
unnameable alarm is weak, but silence is what lost the fix: with only `install.sh`'s legacy stamp there
is no per-file manifest, so the report fails the run and *says* it cannot name the file.

**A redeploy REFUSES to overwrite an uncommitted edit.** Measured 2026-10-28: a hand-applied fix to
`$O/merge-one.sh` was reverted **twice** by redeploys (the file's mtime moved at 20:02 and again at
20:15, after the patch), the box ran unpatched code, and a production fix looked like it had
"stopped working". Those three writers compare `$O` against its own record **before
copying**, print every file they would discard with which side is newer, and exit **78 with nothing
written** (`orchestrator-bringup.sh start` refuses with its own rc=1 and the same file list, because
its contract is `0 ok · 1 refused · 2 cannot-determine`). ⛔ They are NOT every path that writes
`$O/*.sh`: a cell's `deploy-crossbox.sh` step 3, `cloud-cell-supervisor.sh seed_and_stamp` and
`cloud-cell-quiesce.sh` step 4 still copy with neither the refusal nor the record — the coverage table
earlier in this section names each, and routing them through this helper is #2041's remaining work:

```bash
bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator
#   REFUSING: /Users/me/orchestrator carries UNCOMMITTED EDITS that this deploy would OVERWRITE
#   UNCOMMITTED-EDIT   merge-one.sh — … edited AFTER the record …
#   → copy the patch aside (or land it in the repo), or re-run with --accept-discard

bash scripts/deploy-mac-orchestrator.sh --dry-run     # the plan, and the refusal, writing nothing
bash scripts/deploy-mac-orchestrator.sh --accept-discard   # discard them deliberately
bash scripts/orchestrator-bringup.sh start --accept-discard # the same, on the verb operators run
```

`--accept-discard` is a **flag on every one of them**. `deploy-mac-orchestrator.sh` also reads
`ACCEPT_DISCARD=1` from the environment (its `PHASE`/`WAIT`/`DRY_RUN` are env too);
`deploy-harness.sh` and `orchestrator-bringup.sh` deliberately do **not**, because an export set for the
mac path used to silently disarm the gate on the two scripts that protect the same live patch. So on
these two the gate is **not reachable through ambient environment**; on `deploy-mac-orchestrator.sh` it
is, by that script's own documented env seam — pass the flag there too if you want the same guarantee.

`--dry-run` prints the **plan** (`new` / `unchanged` / `overwrite` per file) *before* the gate runs, so
a run that would refuse shows both the refusal and the exact list `--accept-discard` would destroy; it
exits `0` when the deploy would proceed and **`78` when it would refuse** (a dry run that reports a
refusal with `0` would be the same silence in a new place). A ref that predates
`harness-provenance.sh` ships no checker: the deploy then says **it cannot tell** what it would
discard — it does not read as clean.

A box with **no record at all** cannot prove what it would discard, so the deploy says so out loud
instead of assuming it is safe — and it names the lever that works: **`--accept-discard`** proceeds and
writes the record at the end, so every *later* deploy can tell an edit from its own bytes. (Writing a
record by hand onto a box that is behind or half-deployed does NOT work — the writer refuses to describe
bytes `$O` does not have, which is why neither deploy prints that as its remedy. A box that still holds
exactly the ref it was deployed from can be recorded with
`harness-provenance.sh write --o $O --src <checkout>/scripts/orchestrator-harness`.)

**The alternative, and its price — a symlink farm.** `$O` may instead be symlinks into a git clone
(`bin/harness doctor` reports that as `kind=linked-checkout`), which makes the commit answerable **by
construction**: `$O/orch-loop.sh → <clone>/scripts/orchestrator-harness/orch-loop.sh`, so there is
nothing to record and nothing to drift. The price is paid by anything that **writes into `$O`**, and
the two shipped writers do NOT agree about it — measured on a farm-shaped target:

* `deploy-harness.sh` **refuses** a symlink at the destination, per file, by name (`-L` leaf guard),
  exit `1` — the farm is safe from it and its deploys simply never land;
* `scripts/deploy-mac-orchestrator.sh` installs *stage-then-rename* (`cp` to a temp path in the same
  directory, then `mv -f`), and a rename over a symlink **replaces the LINK**, so the same deploy
  silently converts the farm entry into a regular copy of the ref and exits `0`. Nothing fails and
  nothing warns: the farm is unwound one file at a time, and the next `doctor` no longer says
  `kind=linked-checkout`.

So the farm is a **choice about who owns the bytes**, not a free upgrade: it suits a box that tracks
one clone exactly, and it must be paired with a discipline that never runs a copying deploy into `$O`
— including `--dry-run`-first habits, because the macOS route will not tell you. A fix applied "in
place" on a farm also edits the checkout itself (its own, different, blast radius). The record +
manifest path above is what a box that is copied into every deploy should use.

### Tuning (10-core / 32 GB box — the values that were actually used)

| Var | Value | Why |
|---|---|---|
| `MAX_LOAD` | `cores*10` (100 on a 10-core box; sanity ceiling) | dispatch stops above this 1-min load |
| `MAX_LANES` | **derived**: `10#$_NCPU * 5 / 2` — 2.5× cores, floored (25 on a 10-core box, 10 on a 4-core box, 10 on an unprobeable host) | concurrent implementation lanes. **Capacity gates dispatch, not a lane count** (owner ruling, 2026-10-17, verbatim: *"dispatch should be gated on capacity, not on number of lanes. max lanes 8 is too low. that needs to be configured to 2.5x the number of CPUs"*). The shipped default was a flat `4`, and the box this was measured on had its plist **pinned** at `8`: `[cap] load=79/100 lanes=9/11 max_lanes=8 … [dispatch] skipped (lanes=9>=max_lanes=8)` — 21 points of load headroom and comfortable swap/memory, so dispatch was refused for a lane count while capacity was available. A **valid** pin (plist/`keys.env`) still wins and is never recomputed; an **invalid** one is refused by `install.sh` and repaired by the loop to the derived default; a derived value that fails `is_limit` falls back to `10`. ⚠️ The plist **pins** the number, so a box picks this default up only on a fresh `install.sh` render. ⚠️ `2.5 × cores` is ALSO `LOAD_SUSPEND_THRESHOLD`'s default (`docs/ops/load-policy.md` §2) — that is a 1-minute **load** threshold, this is a count of **lanes**; they are not one ceiling |
| `MAX_REVIEW` | `4` | concurrent `merge-<PR>` reviewers |
| `MERGE_PRIORITY_AT` | `25` | **no longer a gate — headroom only.** The gate is threshold-free (§7.2f): one workable un-owned PR is enough to stop the issue path, and there is no age-based release (a stalled drain gets `DRAIN STALLED`, never a licence to open work). This value now only selects the *drain posture* — from here the reviewer/fixer headroom rises to `MAX_REVIEW+2` / `MAX_FIX+2`, so a 25-PR backlog is drained by the capacity that actually clears it instead of being capped to a trickle. Kept as a name because operators and the `[cap]` line read it |
| `MERGE_STALL_MIN` | `180` | **display only.** The age at which the `[dispatch] DRAIN STALLED — no PR merged in <age>m while <n> un-owned remain` diagnostic fires. It gates **nothing**: the issue path is closed by un-owned PRs, not by a land age, so a big or unreadable value can never open it. An unset or non-numeric value falls back to 180; a land marker stamped in the FUTURE prints `DRAIN STALL UNMEASURED` (neither a stall nor an all-clear) instead of a fresh `0m` |
| `MERGE_PRIORITY_MAX_AGE_MIN` | `180` | **display only** — the `[cap] last_land=` field and the `DRAIN STALLED` line. ⛔ This knob used to bound an age-based RELEASE of the gate; that was **deleted** (agent-infra#2099): the release turned *PRs are not landing* into *dispatch more issues*, hiding a stall behind fresh activity, and no unattended lane can move the unowned count itself (every session authenticates as the same GitHub user). `test-gates.sh` pins the release machinery ABSENT |
| `FUNNEL_MAX_AGE_MIN` | `30` | how old a `state/refresh-funnel` record may be before the `[dispatch]` line prints `funnel STALE(<age> > <bound>)` instead of that record's decomposition. The refresh exits before writing its funnel on the pool-read and provisioning paths, so an old pass's numbers can sit beside a newer `queue=READ(n)` — a record is not a state |
| `MAX_FIX` | `3` | concurrent `fix-<PR>` fixers |
| `MAX_FIX_TRIES` | `3` | per-PR fixer attempts before it is left alone |
| `MAX_REVIEW_TRIES` | `3` | verdict-less reviewer runs at ONE head before that head is parked (agent-infra#2132). ⛔ ONE budget, keyed on the head, spent by BOTH arms in `state/reviewdisp-<PR>` (agent-infra#2971: the controller on dispatch, `merge-one.sh` on a verdict-less run that nobody counted — `REV_PAID=1` marks the dispatcher-paid case so an attempt is never counted twice) — so "we already tried review twice at this head" is the same number to both, and `REVIEW-CAP` and the reviewer-side park cannot disagree. The record is `"<head> <n>"`, a push resets it, and any run that DID produce a verdict (findings, or a verified CLEAN) resets it too — it bounds CONSECUTIVE verdict-less runs — so a reviewer that keeps hitting its cap cannot buy an unbounded run of paid reviews. ⛔ **THE SAME LIMIT IS READ BY TWO FILES** (agent-infra#2653): `merge-one.sh` bounds its own reviewer runs with it, and `orch-loop.sh` — which dispatches the `review-<PR>` review ORDER — keys its `state/reviewdisp-<PR>` budget on it. Two readers, ONE budget (the controller coerces it to the same default, and the suite pins the count). ⛔ AND A REVIEWER RUN THAT ENDS WITHOUT ITS `CLEAN`/`ISSUES` MARKER IS A COUNTED FAILED ATTEMPT, never silence (agent-infra#2971): `merge-one.sh`'s EXIT trap records it with its exit code and last line, which is the artifact whose absence made the 2026-10-28 log simply stop at 23:30. ⚠ A head whose signed marker verified but whose gate never reaches SUCCESS is no longer re-reviewed by the controller at all: the store's head-bound CLEAN record is read directly (`REVIEW-AT-HEAD`, agent-infra#2517's record key), which bounds the paid side of the agent-infra#1756 class — what remains is that such a head has no *actuator* in the controller (the gate re-triggers on `edited`, so a RE-RECORD, not a review, is its remedy; that arm is `merge-one.sh`'s CLEAN path) |
| `MIN_SWAP_FREE` | `600` | MB. ⛔ Two limits worth knowing before trusting it: on a host with **no swap at all** (`SwapTotal: 0`, i.e. a container) the gate is **INERT by design** — `swap_total=0` reads as uninitialised, not as pressure (`orch-loop.sh:1438` for the gate, `:1413-1415` and `:1431` for the rule), so capacity there is decided by load and memory only — and on a host that **has** swap the metric is a level, not a counter: swap that has been used stays used, so a past spike holds the FREE level down and the gate flaps across its own threshold (measured `swap_free=549M<=min_swap_free=600M` at load 5.4 of a 64 ceiling; agent-infra#1961). `MIN_MEM_FREE_MB` is the metric that reflects the present |
| `MIN_SWAP_FREE` | `600` | MB. ⛔ Two limits worth knowing before trusting it: on a host with **no swap at all** (`SwapTotal: 0`, i.e. a container) the gate is **INERT by design** — `swap_total=0` reads as uninitialised, not as pressure (the `[cap]` gate's swap arm, beside `swap_usage_mb`/`mem_avail_mb`, for the gate; the same `swap_total=0` arm for the rule), so capacity there is decided by load and memory only — and on a host that **has** swap the metric is a level, not a counter: swap that has been used stays used, so a past spike holds the FREE level down and the gate flaps across its own threshold (measured `swap_free=549M<=min_swap_free=600M` at load 5.4 of a 64 ceiling; agent-infra#1961). `MIN_MEM_FREE_MB` is the metric that reflects the present |
| `MIN_MEM_FREE_MB` | `512` | MB of *available* memory (`MemAvailable` on Linux, else `MemFree`+`Cached`; `free`+`inactive` on macOS). macOS shows pressure as compression with swap flat, so swap alone does not see it. ⛔ This is the CONTROLLER's dispatch arm; the SPAWN gate's own floor is `MEM_MIN_AVAIL_MB` below — two populations, one probe (`mem_avail_mb`, byte-identical in both files and pinned by `spawn-gate.test.sh`) |
| `MEM_MIN_AVAIL_MB` | **derived**: `MEM_LANE_RESERVE_MB * MEM_SPAWN_RESERVE_LANES` = `1024 * 2` = `2048` | MB of available memory the SPAWN gate requires before it starts any agent (`spawn-gate.sh`, agent-infra#2387 — **fail-CLOSED**, unlike the disk and load probes). The reserve is MEASURED, not chosen: a lane's peak is `pi` PLUS the pytest shard it runs, and both halves were measured on a 10-core/32 GB box — all 54 resident `pi` processes (mean 56 MB, max **449 MB** RSS) and four EXECUTING shards against a private FalkorDB (`/usr/bin/time -l` max RSS: 151 / 164 / 359 / **564** MB). 449 + 564 = 1013 MB, so the reserve is **1024 MB**, and the ×2 pays for the lane being spawned AND a peer already inside its own peak window — the allocation that lands on a peaking box. ⛔ Both figures are SAMPLE MAXIMA (n=54, n=4) and a sample maximum is a LOWER bound on the real peak, which is why the floor carries two. The refusal prints all three numbers so it can be re-computed against the box (`mem_min_avail_mb=2048M = mem_lane_reserve_mb=1024M x mem_spawn_reserve_lanes=2`). ⚠️ It is a capacity POLICY knob, not a lane cap: raising it refuses earlier, lowering it refuses later, and neither changes how many lanes may run. ⚠️ A floor is a floor, not a headroom policy — see the #2387 note below for what it does and does not refuse |
| `BATCH` | `2` | issues dispatched per cycle |
| `PRODUCT_FLOOR` | `1` | how many slots of each batch are filled from `candidates.product.txt` FIRST (§2 "State files (`$O/`)" `candidates.txt` row, agent-infra#2054). Clamped to `[0, BATCH]`; `0` **disables** the floor and is a legitimate setting. A missing or non-numeric value falls back to the default `1` — never to `0`, which would silently switch the guarantee off. An UNMET floor LOGS AND DEGRADES (`product-floor unmet … queue=<state>`), and it never refuses a batch or caps the fleet, because a floor is not a quota. The report names its verdict either way — `product-floor MET product=<n> batch=<n> floor=<n>` on a batch that met it, `product-floor unmet (product=… batch=… floor=…) queue=<state>` on one that did not, `product-floor N/A` where no product channel exists — so "the floor worked" is never inferred from silence. ⛔ **THE FLOOR YIELDS TO AN EMERGENCY, AND SAYS SO.** Before it reorders, `floor_emergency` asks two questions of state already on disk: is a `P0-blocker` candidate inside the batch window (`candidates.emergency.txt`, derived from the item's own label), and is there a `red-tree` rail refusal for a PR that is not parked? Either one — or an emergency class that could not be read (`p0-unknown`) — stands the floor down for that cycle and logs `product-floor OVERRIDDEN emergency=<reason>` with the counts the batch actually got. The floor reorders a SEVERITY-ordered queue, so this is the one failure it must never cause; a missed product slot re-asserts itself next cycle, a P0 delayed behind a share target does not. Its intake side (`refresh-candidates.sh` → `write_product_queues`) classifies by PRODUCT_REPOS + the `harness` LABEL and records what it decided in `state/product-class`, which the dispatch line repeats: `NOT-A-PRODUCT-REPO` / `BUDGET-SKIPPED` / `LISTING-FAILED` / `LISTING-TRUNCATED` / `WRITE-FAILED` / `OK product=<n> harness=<m>`. ⛔ THE RECORD DESCRIBES THE TWO QUEUE FILES, so only the function that WRITES them invalidates it: `write_product_queues` writes `PENDING …` as its first action and every arm below overwrites it, while a pass that refuses before reaching the writer (the environment check, the budget, the pool read) or SKIPS because the pool is unchanged (#1984) leaves the previous record alone — it is still true, because neither queue file changed. `PENDING` therefore means *a split started and did not record a class*, and the loop reports it as an UNKNOWN class, never as `the split RAN and found none`. A SHORTFALL is unmet too — `PB < PRODUCT_FLOOR`, not only `PB = 0` — so a floor of 2 that fills one slot still logs `product-floor unmet … queue=<state>` |
| `PRODUCT_REPOS` | `daniel-ospina/tortoise` | **comma-separated** `owner/repo` list (no spaces, matched as an element — `$(printf '%s' "$PRODUCT_REPOS" | tr ',' ' ')` then `*" $repo "*`), read by `refresh-candidates.sh` and deciding **which repo counts as PRODUCT**: an issue is product work when its repo is in this list AND it does not carry the `harness` label. ⛔ **TODAY ONLY THE ENTRY EQUAL TO `$OR` CAN EVER MATCH**: the backlog is read from `$OR` alone, and the intake is called with `$OR`, so every other element in the list is inert until a pass spans more than one repo. The list form is kept because that is the shape the decision has; it is not a multi-repo queue. If `$OR` is absent from the list, EVERY candidate is harness and the loop prints `product-floor N/A` — which is how a box says "no product channel here", not an error. This is the single input the whole floor rests on, so it is documented here rather than only in `ARCHITECTURE.md`: a repo **outside** the list reports `NOT-A-PRODUCT-REPO` and the loop prints `product-floor N/A`, which is **not** an unmet floor and **not** a finding about product work. ⛔ **`$ENV_FILE`-only: `install.sh` neither renders nor validates it** (its numeric `[`-based validator would reject a list, so a `__PRODUCT_REPOS__` placeholder is deliberately absent), which means exporting it and re-running `install.sh` has no effect, and a hand-added plist key is overwritten by the next render — set it in `$ENV_FILE` on a cell, or edit the `PRODUCT_REPOS=` default in `refresh-candidates.sh` (search the assignment, not a line number — it moved once already) |
| `CYC` | `240` | seconds between cycles |
| `STALE_MIN` | `40` | a worker whose log has not grown in this many minutes is presumed hung and its session is killed (§6) |
| `LANE_TIMEOUT` | `3300` | wall-clock limit on a lane's `pi` run (s). Raised from 2400 when a lane took ownership of its merge (#2029) — the issue-claim lease `CLAIM_ISSUE_TTL` must cover it plus the chain's waits; see `claims.sh`'s arithmetic block |
| `REVIEW_TIMEOUT` | `1800` | wall-clock limit on a reviewer `pi` run (s) |
| `FIX_TIMEOUT` | `2400` | wall-clock limit on a fixer `pi` run (s) |
| `SWEEP_MAX_AGE` | `600` | (s) the longest a `304 Not Modified` may reuse the cached PR listing before the sweep forces a full one. A completed check run does **not** reliably change the listing's ETag, so this floor is what stops a green PR sitting behind a cached "unchanged" forever (#1762) |
| `SWEEP_MIN_REMAIN` | `20` | when `x-ratelimit-remaining` is at or below this, the **next** sweep is deferred to the reset rather than hammering the shared bucket (#1762) |
| `SWEEP_ROWS_PER_CYCLE` | `8` | the sweep's per-cycle **window**: how many swept PRs are read per cycle, rotating via `state/sweep-cursor`. A full 70-row pass costs minutes (≥2 `gh pr view` per row) and the controller is relaunched every 12–45 s, so an unbounded pass was torn down before the arms at its end — measured: 0 dispatches in 555 cycles (#2640). The cursor advances AFTER the pass, by the rows that actually produced a disposition, so an interrupted window resumes at its unfinished row instead of stepping over its tail |

⛔ **`PRODUCT_REPOS`, `STALE_MIN`, `SWEEP_MAX_AGE`, `SWEEP_MIN_REMAIN`, `SWEEP_ROWS_PER_CYCLE`, `MERGE_STALL_MIN`, `MAX_REVIEW_TRIES` and the three wall-clock timeouts are NOT rendered into the plist** — and no `__STALE_MIN__`/`__SWEEP_MAX_AGE__`/`__SWEEP_MIN_REMAIN__`/`__SWEEP_ROWS_PER_CYCLE__`/`__LANE_TIMEOUT__`/`__REVIEW_TIMEOUT__`/`__FIX_TIMEOUT__` exists in `launchd.plist.template`. So exporting one of these and re-running `install.sh` silently has no effect, and a hand-added plist key is overwritten by the next render. Set them through `$ENV_FILE` on a cell, or edit the defaults in the scripts.
Everything ELSE in the table above IS rendered, and that includes the three memory knobs (`MEM_MIN_AVAIL_MB`, `MEM_LANE_RESERVE_MB`, `MEM_SPAWN_RESERVE_LANES`). ⛔ THEY USED TO BE THE COUNTER-EXAMPLE AND THIS PARAGRAPH IS WHY IT HAD TO CHANGE (#2387): `spawn-gate.sh`'s own refusal line and the section below tell an operator to raise `MEM_MIN_AVAIL_MB`, so a floor that was NOT in the template made that advice silently do nothing — every lane kept 2048 while the operator believed they had raised the floor protecting the box. A knob the docs name as a remedy must be a knob the installer renders.
The template also carries the non-limit tokens `SCOPE`, `O`, `REPO`, `OR`, `PATH`, `HOME`, `LABEL`, `ENTRY`, `CYC`, `BATCH` and the `HARNESS*` identity tokens.
(This list is not trusted by eye: `product-floor.test.sh`'s P12 arm RECOMPUTES it — every knob in the table above that has no `__NAME__` placeholder in `launchd.plist.template` must be named here, except the three wall-clock timeouts (named as a phrase in the first sentence) and the `AGENT_GH_GATE_*` family, which is documented in its own gate section. A knob added to the table without a placeholder, or a placeholder removed from the template, reddens that arm.)

⛔ **And every limit that IS rendered must be a whole number, in range, and not a template token.**
They are substituted verbatim — deliberately not routed through the escaping path, since a whole
number has nothing to escape — so `install.sh` validates each before rendering: digits only, at most
nine of them (`[` errors at or above 2**63, and an errored test reads FALSE, which OPENS the gate it
configures), `CYC` additionally at least 5 (see below), and no `__…__` pattern, because the sed rules run in order and `OR=__MAX_LANES__`
therefore rendered as the default (then `4`, now 2.5× cores) and still exited 0. It then renders to a **temp file**, lints that, asserts
no placeholder survived, and only then moves it into place — the redirect truncates its target before
`sed` runs, so rejecting after writing straight to `$PLIST` left the live plist empty and the next
`launchctl unload && load` failed. The loop coerces the same values on its own, so a bad plist is
refused at both ends, and every limit is coerced *before* its first arithmetic read, because `[ -ge ]`
on a non-number is FALSE and a false test in the gate chain OPENS the gate.

⚠️ **`0` is a valid integer for most limits** — for `MIN_SWAP_FREE`/`MIN_MEM_FREE_MB` it means the
gate can never bind (disabled). Set one of those only when that is what you mean.
⛔ **`CYC` is the exception: it has a 5-second floor.** It is the one limit where `0` is not merely
useless but harmful — `sleep $(( CYC - JIT + RANDOM % (2*JIT+1) ))` becomes `sleep 0` or a negative
argument, so the controller revisits every cycle with no delay and hammers the GitHub API.
`install.sh` refuses `CYC<5` at render time and `orch-loop.sh` floors a zero/bad value to its 240s
default, so the two ends cannot disagree. `CYC=5` (a deliberately fast cycle) is still accepted.

**The CONTROLLER's spawn decisions are load- AND memory-gated — not just lane dispatch.** A Mac reboot lands in an indexing
storm (Spotlight, `PerfPowerServices`, `duetexpertd`) that routinely pushes 1-min load past 200. The
lane gate already respected `MAX_LOAD`; the merge sweep did not, so a fresh boot got six reviewers
piled onto the spike. `can_spawn()` now guards the six spawn sites in `orch-loop.sh` — conflict
fixer, rail merge worker (GREEN), re-record fixer, re-record merge worker, CI-red fixer, red-fixer —
while the
cheap actions (`gh pr ready`, `gh run rerun`, and `gh pr merge` in *gate* mode) stay ungated, so
**gate-mode** merges keep flowing during a spike and nothing is
starved. ⚠️ **On a rail-mode repo the merge is itself a gated worker, so it does NOT keep flowing.**
agent-infra#1764 moved the rail into a `merge-<PR>` worker (the inline rail run measured ~27 s of
BLOCKED controller cycle, halting dispatch); that worker is slot- and load-gated like every other
spawn, so a spike holds rail merges back with the rest. That is the intended trade, not an
oversight. ⛔ **That is the controller's *decisions*, not every spawn.** Three worker entry points
spawn a `pi` agent with no `MAX_LOAD` read of their own — `chain-<N>` → `merge-one.sh` (the
first-review path for every own-lane PR), `fix-one.sh` → `merge-one.sh`, and `adopt-fix.sh` →
`fix-one.sh`; tracked as agent-infra#1720.

**The controller's spawn gate has TWO dimensions — load AND available memory (agent-infra#1732).**
The six spawn sites above used to be load-gated only, while lane dispatch was bounded by load + lanes
+ swap + available memory: two gates over two different populations, with the resource that actually
kills this box consulted on only one of them. `can_spawn()` now ANDs `mem_spawn_ok()`, which refuses at
`mem_avail <= MIN_MEM_FREE_MB` — the dispatch gate's own boundary **for that one arm**, so the two
cannot disagree about the `mem_avail` reading itself — and refuses when the probe is UNKNOWN:
**fail-CLOSED, unlike the load reading's fail-open** (the note below, "A load reading that is
*unreadable* stays the documented fail-open"). A probe we could not take is not evidence of
capacity. ⚠️ The dispatch gate carries arms the spawn gate does not (`lanes=`, `swap_free=`, and the
swap-joint `mem_avail <= 2*MIN_MEM_FREE_MB` that only arms when swap is also tight), so a box in the
swap-joint band can still be refused a *dispatch* while the spawn sites proceed — those are different
populations' decisions, and sharing them is not this change's scope. The reading is taken in the cycle
prologue (`measure_mem`), BEFORE the first spawn site; the `[cap]` block re-measures because a dispatch
decision must see the present. `MEM_UNKNOWN`/`MEMAVAIL_MB` are set in ONE place (`measure_mem`), so
neither reading can be derived differently from the other, and `selftest.sh` pins the ORDER — a gate
that consults the pair only where the `[cap]` block reads it decides on the PREVIOUS cycle's figure,
and on cycle 1 on nothing. Each slot refusal now prints `mem-gate=<reading>M/<floor>M` beside
`load-gate=`, so a spawn held back by memory no longer reads as a load refusal.

⛔ **WHAT THIS DOES NOT BUY: a floor is a floor, not a headroom policy.** Measured 2026-10-22 on
cell-3, `MemAvailable` reached **653 MB** with 14 lanes and the box OOM-killed its own runners (the
pool oscillated 12→8 three times in one night). At 653 MB **the new gate is still TRUE** — 653 > 512
— so that exact reading remains permitted by both gates. What the change removes is the structural
gap: the spawn sites previously read *no* memory figure at all, so no floor — not even a raised
`MIN_MEM_FREE_MB` — could bind them, while the dispatch gate below was already honouring one (the
pre-fix inline read sat ~620 lines below the FIRST spawn site, ~225 below the last, and ~2,000 below
`can_spawn()`'s own definition — measured on `origin/main`, not estimated). An operator who wants
653 MB to refuse now sets `MIN_MEM_FREE_MB` above it and BOTH populations
obey; raising the default floor is a separate decision (it is a capacity policy, not a wiring bug)
and is deliberately not made here.

✅ **The SPAWN POPULATION is memory-gated too** (agent-infra#2387 **FIXED**). It used to be the one
gap: `spawn-gate.sh`'s `run_agent()` gated on load, the disk floor and the land ratio and consulted
**no memory probe at all**, so a worker started by `lane.sh`/`fix-one.sh`/`nonblocking-dispatch.sh`,
by `merge-one.sh`'s own unported `run_agent` (the `chain-<N>` first review of every own-lane PR), by a
hand-written `tmux new-session … pi` runner, or by an interactive session was bounded by memory only
through the controller's decision to start it. Both of that file's spawn surfaces now read it —
`run_agent()` (after the disk gate, before the load gate) and the installed-`pi` SHIM — with the
`mem_avail_mb` probe this file already carries, and the polarity is the DISPATCH gate's, not the disk
gate's: **fail-CLOSED**, verdict `UNREADABLE`, spawn refused. That is a deliberate divergence from
the disk gate's fail-open, and the reason is structural rather than stylistic — an unreadable `df` is
a per-volume nuisance on a live path, while an unreadable memory probe is indistinguishable from "the
box is fine" and treating it as capacity is exactly how a box talks itself into an OOM. Refusals are
`AGENT_MEM_REFUSED` (81) from `run_agent` and `PI_GATE_MEM_REFUSED` (82) at the spawn point, the
latter translated into the former so no caller learns a new code; `lane.sh` records the capacity
yield with `gate=mem` and `fix-one.sh` names the memory gate rather than the load one.

⛔ **WHAT THIS DOES NOT BUY, again stated rather than implied.** The floor is `2048 MB` by default
(see the `MEM_MIN_AVAIL_MB` row) and it is a HEADROOM floor, not a headroom policy: a box reading
`available=8379 MB` clears it. So the cell-4 figures in #2387 are NOT all refused by the shipped
default, and the note in that issue deserves one correction: `rc=143` is SIGTERM — this harness's own
wall-clock watchdog, or the stale-worker reaper — and NOT the OOM killer's SIGKILL (137), so those
eight lane deaths are evidence that lanes died, not evidence that memory killed them. The memory
evidence is the six `dmesg` OOM lines, and the surviving `free -m` snapshot cannot be dated against
them (memory freed by the dead lanes is indistinguishable from memory that was free throughout). What
the change removes is the STRUCTURAL gap: no floor — not even a raised one — could bind a spawn path
that read no memory figure. What would have refused the documented cell-3 reading (`653 MB`) is the
shipped default, and an operator who wants a higher floor sets `MEM_MIN_AVAIL_MB` — a capacity
policy, deliberately not made here.

⚠️ **The account's CONCURRENCY cap is a shared FLEET resource — the ceiling on parallelism is
neither CPU, RAM nor disk.** Every limit in the table above bounds *this box*: load, lanes, swap,
memory. None of them bounds the account. GitHub's **secondary** limit is a **concurrency** limit
(documented at no more than 100 requests in flight, **shared across REST and GraphQL**), and
`GET /rate_limit` **cannot see it** — it reports the primary budget only, and a refusal may carry
no `retry-after` at all. So a healthy `graphql.remaining` next to a refused call is the documented
blind spot, not a contradiction, and **it is not evidence that the fleet is healthy**. Measured
2026-10-17: five boxes' controllers plus hand-dispatched workers, each issuing `gh` calls with
nothing coordinating them, refused on every GraphQL call while the counter read `used: 541` of
5000 (agent-infra#1910, superseding the point-budget framing of agent-infra#1762).

The defence is a **fleet-wide courtesy gate in the `gh` shim** (`scripts/gh-shim/gh`), which is why
it is not a harness variable: it applies to every `gh` call a pi session makes, not only to the
controller's. It bounds concurrent `gh` processes per machine, spaces call starts, and on a
rate-limit refusal writes a **shared cooldown** so the next call waits instead of walking into the
same burst — one refusal-and-wait per burst rather than one per lane.

| Var (shim env) | Default | Why |
|---|---|---|
| `AGENT_GH_GATE_MAX_INFLIGHT` | `2` | concurrent `gh` processes **per machine**. The account ceiling is 100 *shared across all machines*, so a per-machine cap must be well under it — 2 leaves room for ~50 boxes. Raising it multiplies across the fleet, not just here |
| `AGENT_GH_GATE_INTERVAL_MS` | `250` | minimum ms between call **starts**. Adds latency by design: that spacing alone is ~12 s over 50 calls, and the gate's own bookkeeping adds ~0.5–0.9 s per call on bash 3.2 (no `EPOCHREALTIME`, so `perl` supplies the ms clock), so budget **~55–60 s** for a 50-call sweep, not ~12 s. `0` trades the burst protection for throughput |
| `AGENT_GH_GATE_MAX_ATTEMPTS` | `3` | total attempts on a rate-limit refusal, including the first. ⛔ **per WHOLE COMMAND, and it MULTIPLIES with gh-limit's 4:** one call can execute the same argv up to 12 times, including non-idempotent creates and comments. "The tighter layer wins" holds for concurrency and for a single wait, and is **false** for attempts — a caller that declared its own bound must suppress the sleep (`AGENT_GH_GATE_NO_WAIT=1`, or gh-limit's `GH_LIMIT_NO_WAIT=1`) |
| `AGENT_GH_GATE_RETRY_BASE` | `60` | seconds to wait when a refusal carries **no** `retry-after` (GitHub's own guidance is "at least one minute"). Floor 1 s: an immediate identical retry cannot succeed by construction |
| `AGENT_GH_GATE_RETRY_MAX` | `900` | ceiling on any single wait, including a server-supplied `retry-after` (a value too large for the shell to hold is treated as **absent**, not clamped — a wrapped value would be written into the shared cooldown and park the box) |
| `AGENT_GH_GATE_ACQUIRE_TIMEOUT` | `300` | seconds to wait for a free slot before running the call **UNGATED** (announced). This is the knob that decides the fail-open behaviour: the gate is a courtesy, so its own failure must not become a fleet stall |
| `AGENT_GH_GATE_LOCK_TIMEOUT_MS` | `2000` | ms to wait for the gate's own mutex. Keep it above `MAX_INFLIGHT × INTERVAL_MS`: nested and ungated calls can exceed the slot cap, and a timed-out tick is skipped (announced, fail-open) |
| `AGENT_GH_GATE_DIR` | `~/.pi/agent/gh-gate` | the per-machine gate state (`slots/`, `cooldown.*`). One *user's* count — two users on one box do not share it |

⛔ **`MAX_LANES` is not the lever for this.** Adding lanes adds `gh` callers, and a lane that
blocks on the gate is a lane that is not producing. The only true capacity increase is a separate
rate-limit pool — GitHub App **installation** tokens have their own budget (5,000/h per
installation) — and that is a decision, not a tuning change.

**Swap, not lanes, is what actually throttles an 8 GB box.** Observed at 15 concurrent workers on the
original 8 GB host: `swap_free=588M` → dispatch correctly refused. On THAT host raising `MAX_LANES`
alone buys nothing; it just moves the pressure into the compressor. It is not a general rule, and the
lane ceiling was a second, independent cap: on today's 32 GB host capacity was available (21 points
of `MAX_LOAD` headroom, comfortable swap and memory) while dispatch was refused by a lane count —
which is why `MAX_LANES` is now derived from cores instead of pinned to a small literal (§4).
`swap_total=0` right after boot is treated as
*uninitialised*, not as pressure (that bug silently blocked all dispatch for the first minutes
after a restart until it was fixed) — and that same rule makes the gate **inert for ever** on a host
that never has swap, which is a fact to know rather than a defect to fix here (agent-infra#1961).

**The capacity probes are portable: Linux cell + macOS host.** `#1702`. Every probe used to be a
macOS primitive, so on a Linux cell `load1()` returned empty (the `MAX_LOAD` gate could never bind),
swap read as `0` (the gate skipped by its own "uninitialised" rule), and the reaper's
`stat -f '%m'` became an arithmetic error that killed the controller one cycle after its first
dispatch — every lane/merge/fix writes the log the reaper stats. Each probe now has a Linux path
(`/proc/loadavg`, `/proc/meminfo`, `nproc`) and a macOS one (`sysctl`, `vm_stat`), and the reaper's
mtime probe is a GNU-then-BSD `stat` ladder with a numeric guard (GNU first on purpose: GNU
`stat -f` writes the filesystem listing to **stdout** before exiting 1, so a BSD-first `||` ladder is
the bug itself).

⚠️ **Available memory was the fifth macOS-only probe, and the only one that fails CLOSED.** The gate
is deliberately "UNKNOWN is not ample" (`mem_probe_failed` → do not add work), so with a `vm_stat`-only
probe every Linux cell set `MEM_UNKNOWN=1` on every cycle: load, lanes and swap could all be healthy
and the memory gate still bound — the controller completed cycles, logged `mem_probe_failed` and
dispatched nothing, which is a *different* false green from the one #1702 removes. `mem_avail_mb()`
therefore reads `/proc/meminfo` (`MemAvailable`, else `MemFree`+`Cached`) on a cell and keeps the
`vm_stat` `free`+`inactive` parse on macOS. The fail-closed ruling for a genuinely unreadable probe is
unchanged — only its Linux measurability is.

A load reading that is *unreadable* stays the documented **fail-open** (`can_spawn()` defaults it to
`0`): both supported platforms are measurable now, and failing closed on an unreadable probe would
turn "no load back-pressure" into a permanent controller outage. ⛔ **That licence covers LOAD ONLY.**
The memory half of the same gate is fail-**CLOSED**: a memory probe that cannot answer refuses
the spawn, because the cost of a wrong "ample" is the box OOM-killing its own runners. Do not read
`can_spawn()`'s load default as covering the memory arm, and do not "fix" a refusing memory gate by
making `MEMAVAIL_MB` default to a large number — `measure_mem()` zeroes it on a failed probe for
exactly that reason. `install.sh` still refuses to run
off macOS (it renders a launchd plist) — the portability that matters is `orch-loop.sh`, the file
`cloud-cell-supervisor.sh` starts.

---

## 5. Merge policy and safety invariants

1. **The gate is never bypassed — but WHICH gate is the repo's own answer (agent-infra#1764).**
   The required-check list is read from the target repo's branch protection, not hardcoded. A repo
   that requires `ai-review-gate` (tortoise) must have it `<SUCCESS>` —
   `SKIPPED`/`NEUTRAL`/absent do **not** count, because that means no signed review exists — and
   `merge-one.sh` additionally refuses to merge if the recorded head ≠ the current head, so a
   post-review push invalidates the evidence automatically. A repo that does NOT require it
   (agent-infra: `pipeline-compliance`) is merged through its **own rail**
   (`scripts/admin-merge.sh`), which posts its own head-bound evidence; the harness never falls back
   to a raw `gh pr merge` there. Either way the fail-closed rule holds *inside* the repo's own
   required set: a required check that has not reported is `PENDING`, never green, and an
   unreadable protection endpoint uses `FALLBACK_REQ` (non-empty), never an empty set.
1b. **One owner per PR, per box — and, for LANDING, one owner per PR ACROSS boxes.** Every path
   into `merge-one.sh` (the lane's `chain-<N>`, a `fix-<PR>`, and the controller's sweep) takes the
   same atomic `state/mergeclaim-<PR>.lock` first, then `refs/claims/pr-<PR>` (**before** the paid
   reviewer) and `refs/claims/<PR>-<head-sha12>` (§7.2b).
   Without the local lock a freshly opened PR gets two concurrent reviewers racing one head: duplicate
   evidence
   comments, duplicate `record-review` writes, and an `ISSUES`/`CLEAN` interleaving.
   **The lock is a local file, so it serialises one box only** — two boxes sharing a repo are not
   coordinated by it (§7.2b, tortoise#5052). The per-head claim coordinates them per HEAD; the
   per-PR claim coordinates them per PR, which is the only key that can express "one lander".
2. **The reviewer must state a plain outcome.** Its final line is exactly `CLEAN <comment-url>`
   or `ISSUES <n>`. A CLEAN comment may not assert an unresolved outcome. The enforcer is the
   evidence veto in `scripts/record-review.sh`, and its vocabulary is `NOT CLEAN`, "requires human
   attention/input/review", "unresolved issues",
   "auto-fix stalled/failed/reached/converged/aborted/stuck", "test review capped",
   `[ADVERSARIAL-BOUND]`, and a **counted** `N issues remain`. The count is
   deliberate: a bare "issues remain" is NOT matched, because the veto must not false-refuse the
   legitimate clean phrasing "No issues remain after the fixes" — which also means a CLEAN comment
   whose body says (uncounted) that issues remain does pass the veto. Quote the gate's list, not a
   wider one.
3. **Scope adapts to the queue — and can be pinned.** `open PRs > 10` → **broad** mode: the sweep
   covers every non-draft PR in the repo except the branch classes it deliberately never touches
   (`design/`, `scope/`, `dependabot/` — the selector is
   `select(.headRefName|test("^design/|^scope/|^dependabot/")|not)`), not just this box's. `≤ 10` →
   own branches only (`*-tm`, `*-cap`, `fix/*`). Broad mode is how this box drains a peer's queue;
   it is also how two boxes accidentally duplicate work if they both run broad. `SCOPE` overrides
   the count: `auto`
   (default — the rule above), `own` (own-only even above the threshold), `broad` (broad even below
   it); any other value is fatal, so a typo cannot silently pick a scope. In a multi-box fleet
   **exactly one box takes `broad` and the rest pin `SCOPE=own`** (measured 2026-10-13: a freshly
   started cell logged `[scope] open=14 -> BROAD` and auto-armed #8425/#8420 within ~25s).
   ⛔ **This is a partition, not coordination.** `SCOPE` decides which *names* a box looks at; it says
   nothing about who is working them, so on its own two `own`-pinned boxes can still race the same PR
   (§7.2b, tortoise#5052). What excludes a concurrent holder is the **claim registry, consulted by
   selection** (agent-infra#2466): `pr_owned()` / `claim_live()` read ONE snapshot verdict, and the
   sweep prints the decision for every PR — `claim-held` → skipped, `claim-absent` → free,
   `claim-unreadable` → nothing acted on. Since that landed a second and third controller are safe by
   COUNTER, not by permission: two cells may see the same candidate, and exactly one wins the CAS. The
   pin remains the cheapest way to avoid paying twice for the same verdict.
   ⛔ **And it is not the cross-box barrier for any operation.** `SCOPE` selects PR branches by naming
   convention, which every box shares; what excludes a concurrent holder is the claim registry, now
   measured per operation in **§7.2d** (agent-infra#1908). That measurement retires the pin's
   *safety* role for dispatch and review and keeps an exclusion requirement on the landing row.
4. **Drafts are deliberately excluded** from the sweep — a peer's draft PR is not yours to
   merge. The cost is that a *peer's* draft stalls until they ready it. Our **own** lanes' drafts do
   not: the sweep selects drafts whose branch matches the harness's own patterns (`*-tm`, `*-cap`,
   `fix/*`), readies them once, and sweeps them from the next cycle (see §7.2).
5. **Workers never touch the main checkout.** Every lane runs in `.worktrees/tm-<N>`; the
   controller only reads. `lane.sh` instructs its agent not to create or remove worktrees.
6. **No `task` sub-agents.** Extensions that would gate a nested agent (`review-enforcer`,
   `verification-gate`, `loop-enforcer`, `sequence-enforcer`) are explicitly disabled for
   workers, and the *harness* is the review gate instead.
7. **The key is the crown jewel.** The box that holds `AI_REVIEW_GATE_KEY` can authorise
   merges. It lives at `~/.pi/agent/.ai-review-gate-key`, is never written to logs, and is
   never copied into this bundle.
8. **One controller.** `.orch.lock` is created with `set -o noclobber`; a second start exits
   immediately, and a lock whose PID is dead is reclaimed.
9. **GitHub data never reaches a shell.** Inputs from the API are validated before use:
   `safe_ref` admits only `[A-Za-z0-9._/-]` **and** requires `git check-ref-format --branch`; PR ids
   must be all digits (`is_num`); worker arguments travel in a file and the daemon launches
   `merge-one.sh --argv <file>`, so no PR-derived value is embedded in the command string the launcher
   (`worker-terminal.sh`: a durable terminal where the cmux daemon answers, otherwise `tmux new-session`
   with the HOME+keys.env contract) executes **on any live path**. (`retired/auto-loop.sh` still contains the old
   unsafe interpolation, annotated in place — it is unreachable from the live scripts and exists
   only as history; do not reuse it.) Branch names were the hole: git **permits** `'` `;` `$` `` ` `` `&` `|`
   `(` `)` `{` `}` `"` `<` `>` `#` in a ref (only spaces are forbidden, and `${IFS}` supplies
   those), so a fork PR on `fix/x';touch${IFS}/tmp/x;#` achieved arbitrary command execution on the
   host holding the merge key. Reproduced before the fix; the self-test now pins the validator.

### 5.3 Untrusted input and worker containment — read before running this unattended

This harness passes **attacker-controlled text** to language-model agents with shell access. Be
clear about what is and is not enforced:

- **Not sandboxed.** The spawned reviewer and fixer run with `AGENT_ALLOW_MAIN_EDITS=1`,
  `SKILL_ENFORCER_DISABLED=1` and `LOOP_ENFORCER_DISABLED=1`, with `bash` and `gh` on `PATH`.
  Whether `AGENT_SKIP_REVIEW_GATE`/`ELDATO_SKIP_VGATE` are also set is DECIDED AT STARTUP by
  `gate-policy.sh` (§5.4) and recorded in `logs/gate-policy.jsonl` — never assumed. "Do NOT merge"
  and "do not touch the main checkout" are **prompt instructions, not controls**.
- **Prompt injection is possible.** `fix-one.sh` reads the PR's comments into the fixer prompt as
  the authoritative review, and `merge-one.sh` feeds the reviewer the PR title, body and diff. A
  malicious PR body can therefore attempt to steer an agent that has shell access.
- **What actually constrains it.** `gh pr merge` is reached only on a **gate-mode** repo (one whose
  branch protection requires `ai-review-gate`), and only after `record-review.sh` has written a
  signed marker for the exact head (§5.1), with `merge-one.sh` additionally waiting for
  `ai-review-gate` to read `SUCCESS`. On a **rail-mode** repo (agent-infra) the harness instead
  invokes `scripts/admin-merge.sh`, which posts its own head-bound evidence and merges with
  `--admin`; the harness does not call `gh pr merge` there at all, and auto-merge is deliberately
  never armed. The same refusal is one layer deeper: a merge worker whose OWN branch-protection
  read fails (REQ_SOURCE=fallback, no REQ override) exits 5 before reviewing or merging anything
  — which covers every ingress, including `chain-merge.sh` and `fix-one.sh`. A rogue *agent* cannot merge through the harness path; it could still `gh pr merge`
  or `git push` directly if the token permits, which is a property of the token, not this code.
- **What is deliberately not done:** the gate key is never placed in a prompt, a plist, a log or a
  command line, and no script creates a secret-bearing file.
- **Open item (tortoise#8246):** contain the workers properly — a read-only key path, no
  merge-scoped token during review, and treating PR content as delimited data rather than
  instructions. Until then, run this on a box whose GitHub token you would accept being used by an
  agent that has read a hostile PR body.

### 5.4 The gate decision is MEASURED: `gate-policy.sh` (agent-infra#2319)

Five carriers (`orch-loop.sh`, `lane.sh`, `fix-one.sh`, `merge-one.sh`, `nonblocking-dispatch.sh`)
used to `export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1` unconditionally. The canon calls both
flags emergency-only (`skills/commit-workflow/SKILL.md:102,:111`) and a lane collected without review
is "UNREVIEWED CODE BY DEFAULT" (`skills/parallel-orchestrator/SKILL.md:150`), so a permanent export was
a **defect**, and dangerous in one direction only: the permissive side was the machine that lands the
most work.

It could not be deleted in one line, because a lane **cannot** satisfy the review gate by itself —
`lane.sh` says so to the lane's face: it has no `task` tool, so the parent/harness must obtain the
head-bound review. So the decision moved into ONE probe:

| probe | asked | today |
|---|---|---|
| review | is there a recorder for the head-bound record **and** a seam a non-interactive lane can call to obtain it? | **satisfiable.** `record-review.sh` yes, `review-pr.sh` (#2288, landed 9b80ee4c) yes — `--probe` on this checkout prints `review_satisfiable=1` (pinned by `gate-policy.test.sh` "live-tree") |
| VGATE | can a non-interactive session record verification where the gate reads it? | **not satisfiable.** no `record` verb, no lane-satisfiable acceptance (#2313) — so the bypass below is still ACTIVE, on the VGATE half alone |

- **Both satisfiable** → nothing is exported, and any INHERITED skip flag is removed from the carrier's
  environment (a daemon captures its environment once; that is how a stale hatch outlives its reason).
- **Either missing** → the two flags ARE exported, and **one** audit line naming #2319, the carrier and
  the missing component is appended to `logs/gate-policy.jsonl`.

⛔ **The `today` column above is MEASURED, not remembered (review round 6).** It once said `review-pr.sh`
was missing while the file had already been in this tree for weeks — so a reader diagnosing "why is the
bypass still on" was pointed at a component that had shipped. `gate-policy.test.sh`'s "live-tree" arm now
probes THIS checkout and asserts the pair the table states, so the table cannot drift again: **when either
half flips, that arm goes RED until the doc changes with it.** The bypass today is carried by the VGATE
half alone — that is the sequencing #2319 asks for, and the reason nothing fleet-stopping follows from the
review half being satisfied.

⛔ There is no third state: `gate-policy.test.sh` fails if any live carrier exports either flag
outside the policy, so a silent reintroduction is RED. When the satisfier merges, the probe flips and
the bypass ends — **no second change and no forgotten flip**. This is the sequencing #2319 asks for:
the removals are wired, but they take effect when the gate path can satisfy them, because deleting
them first stops every lane at its first push.

### 5.5 The pin's cleanliness is ONE predicate: `pin_dirty` (agent-infra#2271 review)

Four readers ask "is the pinned harness dir the bytes the commit carries": the runtime resolver
(`scripts/harness-exec.sh`), the cell supervisor's DRIFT check, its provenance stamp, and the
installer's. For one review round three of them asked a **weaker** question than the resolver did, so
`check` reported a pin CLEAN that `harness-exec.sh` refused — and `apply` then took
`HARNESS_APPLIED=unchanged` over the very tree the controller would not start. An instrument that
certifies the state it exists to catch is worse than no instrument.

`pin_dirty` in `scripts/lib/box.sh` is the single answer: `0` clean, `1` dirty (entries printed), `2`
**cannot verify** (`git status` itself failed — never a pass). It reads
`git status --porcelain --ignored=matching`, because a **gitignored** file cannot be committed and is
therefore never part of the pin — and `tmp/`, `dist/` and `*.log` are all ignored here, so a local
hotfix sat inside the pin and `--entry tmp/x.sh` passed every check. It also **tolerates** the
`.DS_Store` / `._*` REGULAR droppings, reusing the ruling the pin-root guard already made: one Finder
visit must not brick a cell, and bash cannot execute a `.DS_Store`. Two conditions keep that tolerance
honest, and both were review findings: entries are resolved against the repository **toplevel**
(porcelain prints top-relative paths even when the caller passes the harness subdir — the production
convention — so resolving against `$repo` made the tolerance unreachable exactly where it is needed),
and only **untracked/ignored** entries are tolerated (a tracked file named `._x` is part of the pin, so
a modification to it must read DIRTY: the name is not the property).

The supervisor and the installer are deployed standalone and cannot source a sibling library, so they
carry the body as a **pinned mirror** — compared byte-for-byte, comments excluded, by
`cloud-cell-supervisor.test.sh` §(p3), which then RUNS the mirror against a clean pin, a gitignored
hotfix and a `.DS_Store`. **Known residual (P2):** the probe's bars are *shape* checks (executable,
non-empty, parseable, with a real `record)` dispatch arm), so a satisfier that exists but does nothing
satisfies them. A capability sentinel (`review-pr.sh --capability`) belongs to #2288/#2313 — the
scripts that do not exist yet — and inventing its interface here would make the flip unreachable
rather than safer. Until then the failure direction is **loud**: enforced gates with a broken
satisfier stop lanes visibly, where a bypass lands unreviewed code silently.

---

### 5.4 A lane owns its merge — bounded, in code (2026-10-18)

**The failure this closes.** Measured 2026-10-18: **22 open PRs against 3 merged**. Every lane treated
"PR opened" as success and exited, so the merge work queued behind the running lanes and the backlog grew
while the fleet looked busy. The instruction alone was not enough — a brief that says "keep merging" leaves
each lane to invent its own polling loop, and an invented loop is **unbounded**.

**What the lane does now.** After the PR exists, the lane runs

```
bash $O/lane-merge.sh <PR> --issue <n> --repo OWNER/REPO --branch <br>
```

and the exit code **is** the next action (0 MERGED · 10 FIX_REQUIRED · 15 FIX_CONFLICT · 11 WAITING ·
12/13/14 BLOCKED_*). One round is: wait for THIS head's checks to be terminal (bounded) → read the failing
NAMES → fix, push, repeat; when green, launch the harness's per-PR chain **detached** and supervise it with
`--watch` (short chunks — a lane blocked for 20 minutes inside one shell call reads as wedged to every
liveness instrument we have). Supervision is **bounded and sized to what the lane can actually spend**:
`WAIT_S + MAX_WATCH × POLL + IMPL_RESERVE ≤ LANE_TIMEOUT` (1500 + 7 × 120 + 900 = 3240 of the 3300 s
clock), so the merge phase can never consume the implementation time the same clock pays for — a bound
the lane itself reaches before its own kill, not one only a later lane could inherit.

**The cap is 3 fix rounds, enforced by the tool**, not by the brief: a lane that would start round 4 is
refused, the verdict becomes `BLOCKED_ATTEMPTS`, and a **PR comment names the exact blocker**. A lane stuck
in round 5 is a failure, not thoroughness.

**Why the lane does not review itself.** The merge path is `$O/merge-one.sh`, unchanged: in a *rail* repo it
runs the repo's own `scripts/admin-merge.sh`; in a *gate* repo it dispatches a **fresh-context** reviewer,
then `record-review.sh` (which verifies the evidence comment) signs the record, and only then does it merge.
`lane-merge.sh` contains **zero** calls to `record-review.sh` — a lane that attested to its own review would
be a review that did not happen, and the suite pins that as a property.

**Two more rules the brief states, because each has a real incident behind it:**
- **never edit the PR body once a review is recorded** — the attestation lives in that body and an unrelated
  edit wipes the proof the gate reads (twice measured: agent-infra #1209, premise-labs #3788);
- **a dirty PR** means re-apply the lane's own change onto current main and force-push ITS OWN branch;
  never resolve a **generated** file's conflict by picking a side — regenerate it.

**The controller's chain yields to it.** `chain-merge.sh` waits for `state/lanemerge-<PR>.phase` (a local
file — **zero GitHub calls**) and then for that lane's verdict before it reviews, because a review recorded
at T while the lane pushes a fix at T+1 strands the attestation: the gate reddens on an unchanged verdict,
the review is paid for twice, and `admin-merge.sh` refuses to move a branch carrying a record bound to it.
A lane that predates this writes no phase marker, so the chain proceeds after a short grace exactly as it
always did — the live fleet is not delayed by a template it never received.

**The measurement.** `merge-rate.sh [--hours N] [--json]` counts lane END states from durable artifacts
only (zero GitHub calls): the last status token in `logs/lane-<n>.log`, plus the machine-written verdicts
and `merged-*` markers as cross-checks. A lane with no status line is counted as **UNKNOWN and printed**,
never dropped and never folded into the rate; an empty population prints `n/a`, never a flattering 0% or
100%. Before this change the fleet measured **191 lane logs: 99 ended at `PR_OPENED`, 2 at `MERGED` → a
1.9% merge rate**, with 61 `merged-<PR>.done` markers showing the *controller* was carrying the merging.

## 6. Operating notes

### ONE launcher: `scripts/harness-up` (and `-down` / `-status`)

Before #2231 a box was started by hand, in the right order, from the right directory, with the right
quarter of about a dozen entry points — `pi-bootstrap/setup.sh`, `cloud-cell-bringup.sh`,
`orchestrator-harness/install.sh`, `deploy-mac-orchestrator.sh`, `cloud-cell-supervisor.sh apply|start`,
`harness-refresh.sh`, `orch-loop.sh`, `claims.sh`, `cloud-cell-doctor.sh`, `install-launchd.sh`,
`install-disk-reaper-timer.sh`, `orchestrator-bringup.sh`. Nothing tied them together, so "is this box
up?" had as many answers as there are components, and a start could be half-done without saying so.

```bash
scripts/harness-up                 # start this box, in dependency order
scripts/harness-status             # one line per component + ONE verdict; exit 0/1/2 = HEALTHY/DEGRADED/BROKEN
scripts/harness-down               # stop it via the platform authority (never a bare pkill)
```

⛔ `harness-status` IS A READ; `harness-up status` HEALS. The launcher repairs by default (`--no-heal`
for a pure read): it starts a controller that is not running and re-pins a pin that is behind. The thin
`harness-status` name keeps the read-only contract it has always documented and passes `--no-heal`, so
`harness-down` followed by a status read (or a monitoring poll) cannot silently restart a stack an
operator deliberately stopped; ask for the repairs with `harness-status --heal` or `harness-up status`.
Neither verb kills a duplicate or cycles a live-but-late controller — those are labelled
`NOT HEALED` with whose decision they are.

**What `harness-status` answers, row by row** — and what each row READS, because a health check that
only passes by remembering is a defect. Every row below is a live read of an artefact, never a record
of a previous run:

| row | the question | read from |
|---|---|---|
| `exec` | which sha is **EXECUTING** (not which is pinned) | the RUNNING controller's own argv → the tree that path lives in → that tree's `HEAD`, compared with the pin |
| `loop` | is the loop alive | the process census (ARGV-shape match) + `$O/heartbeat` age |
| `capacity` | is **placement** healthy | fork headroom → free disk → load, in that order (below), each printed with the number it contributed and the one that BOUND |
| `lanes` | how many lanes, and are they **advancing** | the launcher's own live worker records (`$O/state/run-*.sh`, removed by `wt_close`) × their `$O/logs/<name>.log` mtime, against the controller's own `STALE_MIN` (40 min). Finished logs are counted and IGNORED, never judged |
| `selftest` | does this tree survive its own probes | `bash -n` over the live `$HARNESS/*.sh`, plus each platform probe in the shim called NOW |
| `next` | what would it do next | the controller's own `[select]` decision line, with the log's age (LATE rather than "the current plan") |
| `launchd` / `supervisor` / `refresh` / `claims` / `drift` | the supporting components | each component's own authority, or `SKIPPED` with its reason when the platform has no such component |

**The capacity order is the failure order**: fork headroom first (a box can fork *nothing* at 0.32x
load — #2293 — while load and disk read healthy), then disk (what breaks a box first in practice),
then load. `lanes_by_fork` / `lanes_by_disk` / `lanes_by_load` are all computed and the smallest wins;
`binding=` names which one did, so "the box could not fork" and "the box is busy" stop printing as one
lane count. `capacity.sh` (the fleet instrument) answers the `fork` verb with `headroom=` and
`min_fork_headroom=` (plus `src=` naming the limit that bounded it: `uid`/`cgroup`/`unbounded`), and
those are the only fork names it publishes; `harness-up` re-labels them `fork_headroom`/
`fork_source` in its OWN decision record, which is a launcher field, not a capacity one. A box where
no ceiling could be found reads `unbounded`, which prints as `unbounded` — never as `0`, which would
say no ceiling permits no lanes. The shim in `harness-up` is the documented fallback when
`capacity.sh` is not beside the launcher, and the row names which one answered (`via=`). An
**unmeasurable** fork limit refuses the start — "I could not look" is never spent as "there is room"
— and a box that could not fork at all is refused by name (`fork_exhausted`), because its remedy is
external to it.

**Status heals**, by default (`--no-heal` for a pure read), and only the two repairs that are safe
while lanes work: a controller that is **not running** is started (nothing live is interrupted), and a
pin that is **BEHIND** is re-pinned (`harness-refresh.sh`'s advance kills nothing, #2278). It never
kills a **duplicate** controller (a human decision) and never cycles a live-but-**LATE** one (that
would drop in-flight lanes); `restart-pending` is reported with its deliberate remedy (`harness-down`
then `harness-up`) and left alone. The rows are re-read after a repair, so the table an operator reads
is the POST-heal state.

`harness-up` does four things, in this order, and refuses rather than starting something wrong:

1. **Resolves the pin** (`HARNESS-PIN`, else `origin/main`) and then **verifies the resolved pin
directory is the directory the controller will actually READ**. A pin under the pin root that has not
been materialised, and a read dir that is a DIFFERENT tree, both refuse the start with `rc=3` and both
paths printed — this is the #2216 failure (a re-pin lands in a worktree nobody reads) caught before any
process exists. A pin root that matches but whose ancestor is the live dir is accepted as
`restart-pending` and **re-verified after the start**, so a start that silently kept reading the old
tree still fails.
2. **Runs the existing self-tests** (`check-single-source.sh`, `selftest.sh`,
`check-deployed-drift.sh --surface --no-fetch`) and **refuses to start on failure, naming the failing
test** — with one recorded carve-out: `check-deployed-drift.sh` exiting **1 (DRIFT)** is *reported and
the start continues*, because `start` itself deploys the harness and drift is the state it repairs
(`orchestrator-bringup.sh:563-567`); its exit **2 (cannot-verify)** still refuses with rc=3.
`HARNESS_UP_SELFTESTS` narrows the set for a test.
3. **Starts the components in dependency order** — `refresh → claims → loop → supervisor` — declaring
that order in exactly one place (`HU_COMPONENTS`).
4. **Puts the configuration INSIDE each process** (`hu_run`): a tmux server does not inherit the
caller's exports, and a child that re-derives a default is how the wrong tree gets read.

Two platform rules are enforced by the suite, not by convention: **no `timeout`/`gtimeout`** (absent on
macOS — the bound is `perl -e 'alarm N; exec @ARGV'`, fail-closed when perl is absent) and **no
`pgrep -c`/`pgrep -f`** (the process census is `ps -eo pid=,command=` + an ARGV-shape match — `pid` then
the whole command line, split on spaces — the `fleet_ps_snapshot` precedent). `gh` is probed ONLY through a bounded `gh auth status`: a plain
`gh auth token` can hang for the life of the shell (rc=142 measured).

**Divergence between boxes** is `check-deployed-drift.sh --surface` (see §11): it compares the harness
scripts the RUNNING controller uses — and every home-dir harness dir on the box — against `origin/main`
**file by file** (`*.sh` blobs), and names files that differ (**exit 1, DRIFT**), files that exist only
in a home dir (1), and files main carries that a deployed dir is MISSING (1). It is **exit 2 (BROKEN)**
for what it could not look at: a candidate that is unreadable, unlistable, behind an unsearchable
ancestor at any depth, or an unresolvable/looping symlink — and when no candidate directory exists at
all. A path is not failed for being a path main does not carry; it is failed for the bytes in it.
`harness-status` runs it as its fifth row, so every status call is also a divergence check.

### 6.1 The roles — the component table, and the ONE command that installs them

`harness-up` could START a box and could not SET ONE UP. The install half lived in three other places
(`cloud-cell-bringup.sh` on a cell, `pi-bootstrap/setup.sh` on a Mac, and a hand-run installer per
component), so the launcher's own answer to "is this box up?" was only true about a box somebody had
already installed by hand. Measured on 2026-10-25, in one night, three ways:

* **the merge role was INSTALLED AND NEVER STARTED.** `cloud-cell-doctor.sh` owns the reap / doctor /
  merge / hygiene passes; `cloud-cell-supervisor.sh start` opens its session. Nothing anywhere said
  "the merge role has never run", so the box looked installed and the queue did not move.
* **a unit pointed at a `/tmp` cwd DIED EVERY TEN MINUTES** for as long as a reclaim stood. The
  installers that remember to check the path (`install-repair-service.sh` refuses the #2697
  lane-scratch shape) cannot help a unit installed EARLIER, when the path existed — nothing re-read an
  installed unit's own `ExecStart`/`WorkingDirectory`.
* **`status` read "installed" as if it were "ok"** on three components that were dead. A unit file, a
  loaded plist and a session name are all permissions to run, never evidence that anything ran.

So the roles are now declared in **one place**, `scripts/orchestrator-harness/harness-roles.sh`
(sourced by `scripts/harness-up` — still the only entry point), and `up` installs before it starts.

#### One command, both platforms

```bash
# from an agent-infra checkout — the SAME command on a cell and on a Mac:
scripts/harness-up up        # preflight -> install the roles this box is configured for -> start
scripts/harness-up status    # the component rows + the ROLE rows, ONE verdict (heals by default)
scripts/harness-up roles     # the role rows only — a pure READ (status also heals)
scripts/harness-up heal      # re-drive what is dead; NOT HEALED names what it could not fix (exit 1)
scripts/harness-up logs <role> [n]        # the role's OWN log
scripts/harness-up dispatch <role> [pass] # run ONE role once, in the FOREGROUND
```

Linux → **systemd** (system scope via passwordless sudo, else `systemctl --user`); macOS → **launchd**
(`~/Library/LaunchAgents`). One detection path (`hr_platform`), no GNU-only flags, no `timeout`
(macOS has none). `up` is idempotent: a role already RUNNING is left alone and its installer is not
re-run (re-running one can cycle a live unit).

The roster is the box's own configuration — `HR_ROLES`, else `$O/harness-roles.conf` (one role per
line, `#` comments), else the platform default (`controller apply watchdog reminder`, plus `doctor`
on a cell). A name outside the registry is an ERROR, not a silent no-op: a typo must not leave a role
the operator believes is up with nothing watching it.

| verb | what it GUARANTEES | what it will NOT do |
|---|---|---|
| `up` | every configured role is preflighted **before anything is written**; each missing unit is installed idempotently; the component stack starts in dependency order; the run ends with the measured state | it will not install a role whose program or working directory is missing (refuses, writes nothing); will not run `cloud-cell-bringup.sh` (provisioning, not convergence); will not run `install-launchd.sh` (it renders EVERY plist); will not re-install a role that is already running |
| `status` | one line per role with its MEASURED state and the artefact's own last error line, folded into the ONE verdict | it does not believe a unit file, a loaded plist or a session name; it does not heal a DUPLICATE or cycle a live-but-LATE role |
| `roles` | the same table, read-only | — |
| `heal` | installs what is missing, starts what is stopped, and the verdict is the **re-read** | it will not restart a DANGLING unit (the target is gone — restarting cannot work), will not repair a role it could not measure, and exits non-zero when anything remains |
| `logs` | the role's own log, tailed | it reports NO LOG as a state, never as an empty healthy one |
| `dispatch` | ONE role, once, foreground, the role's own argv and output | no session, no scheduler, no retry |

#### The roles

Declared once, in `harness-roles.sh`. `doctor` is a pass-set, not a unit: it takes a pass name
(`reap|doctor|merge|hygiene`).

| role | program | Linux unit | macOS unit | the state is read from |
|---|---|---|---|---|
| `controller` | `orch-loop.sh` | `eldato-orchestrator.service` (`Restart=always`) | `com.eldato.orchestrator-loop` | the unit's live state + the unit's own journal line, then `$O/heartbeat` age |
| `apply` | `harness-apply-pass.sh` | `eldato-harness-apply.timer` | `com.eldato.harness-apply` | the timer/job state + `$HARNESS_APPLY_STATE_DIR/harness-apply.status` |
| `watchdog` | `watchdog-loop.sh` | `eldato-controller-watchdog.timer` | `com.eldato.controller-watchdog` | the timer/job state, and a periodic job's **last exit status** (0 = fine between ticks) |
| `reminder` | `objective-reminder.sh` | `eldato-objective-reminder.timer` | `com.eldato.objective-reminder` | the same |
| `doctor` | `cloud-cell-doctor.sh` | a tmux session (no unit of its own) | **none — no macOS unit exists** | `$O/state/roles/*` (`last_pass_epoch` / `last_rc` / `last_result`) + the session → `NEVER-STARTED` when not one pass ever completed |

**Eight states, and they are deliberately not one word:** `RUNNING`; `FAILED` (with the artefact's own
last error line); `DEAD` (installed and not running); `NEVER-INSTALLED` (nothing on this box would ever
run it); `NEVER-STARTED` (the doctor's own case — installed, and no pass ever completed); `DANGLING`
(installed, and the program or directory it execs no longer exists — the `/tmp`-cwd class, whose remedy
is to re-point rather than to restart); `SKIPPED` (not applicable here, always with a reason, never
rendered as RUNNING); and `UNKNOWN` (the read could not be taken — never a pass).

#### The components — what each is, and which one is current

Every entry point this directory's consolidation carried, classified against the code at this head.
"Status" says which one is CURRENT, which is SUPERSEDED, and which was NEVER STARTED anywhere.

| component | purpose | installed / started today | Linux unit | macOS unit | status |
|---|---|---|---|---|---|
| `scripts/harness-up` (+ `harness-status`, `harness-down`) | THE entry point: preflight/install the roles, start the stack in dependency order, status/heal/logs/dispatch | run by hand (neither starter calls it) | n/a | n/a | **current** — extended here: `up` installs, and `roles`/`heal`/`logs`/`dispatch` are new |
| `scripts/orchestrator-bringup.sh` + `scripts/lib/fleet-inventory.sh` | the fleet inventory and the platform START verbs; the `(machine, repo)` duplicate guard | called BY `harness-up` | n/a | n/a | current — owns starting, not installing |
| `scripts/orchestrator-harness/orch-loop.sh` | the controller | `harness-up up` → bringup → the platform's unit | `eldato-orchestrator.service` | `com.eldato.orchestrator-loop` | current |
| `scripts/cloud-cell-supervisor.sh` | cell supervisor: pin/seed, controller verb, doctor session, prune/hygiene | its `start` IS the systemd unit's `ExecStart`; `stop` stops the unit | via that unit | **refuses on Darwin** | current, with one SUPERSEDED shape: the controller's **tmux session** is gone by design (#2402 — a tmux session has nothing above it and died with the last one). It still owns the DOCTOR session and is the fallback when no unit is enabled |
| `scripts/orchestrator-harness/cloud-cell-doctor.sh` | the repair/land/reap/hygiene passes and their own per-role status | `cloud-cell-supervisor.sh start` opens the `cell-doctor` session | no unit of its own (a session) | **NONE — never started on any Mac** | current on a cell; the Mac gap is now REPORTED (`harness-up status` prints its role row) instead of invisible |
| `scripts/install-cell-timers.sh` | renders + enables the reminder and watchdog timers | `cloud-cell-bringup.sh`; `harness-up up` (roles `watchdog`, `reminder`) | `eldato-objective-reminder.timer`, `eldato-controller-watchdog.timer` | **REFUSES (Darwin)** — the macOS pair is `templates/launchd/` via `install-launchd.sh` | current (Linux) |
| `scripts/install-controller-service.sh` | the controller's systemd unit | `cloud-cell-bringup.sh`; `harness-up up` (role `controller`) | `eldato-orchestrator.service` | **REFUSES on Darwin** (a Mac's controller is launchd) | current |
| `scripts/orchestrator-harness/install.sh` | renders/installs/starts the launchd agent (and enforces the pin records) | `harness-up up` (role `controller`, macOS); by hand | **REFUSES off Darwin** | `com.eldato.orchestrator-loop` | current (macOS) |
| `scripts/install-harness-apply-timer.sh` | the harness-apply clock (converge this box on `origin/main`) | `cloud-cell-bringup.sh` on a cell; **NOTHING on a Mac** — `setup.sh` installs only `install-launchd.sh` | `eldato-harness-apply.timer` | `com.eldato.harness-apply` | current — ONE installer, both platforms; **never installed by the Mac starter**, which is why `apply` reads `NEVER-INSTALLED` on a Mac until `harness-up up` |
| `scripts/install-launchd.sh` | renders EVERY `templates/launchd/*.plist` | `pi-bootstrap/setup.sh` on every Darwin box | — | ~19 jobs (watchdog, reminder, reapers, drainer, canary…) | current — but it installs the WHOLE set, so it is not a per-role installer and `up` will not run it (it says so) |
| `scripts/install-repair-service.sh` | the pr-repair loop's unit | by hand / provisioning | `eldato-pr-repair.service` | **REFUSES (Linux only)** | current — and the ONE installer that already refuses the lane-scratch `/tmp` shape (#2697); the launcher now refuses that shape for every role |
| `scripts/merge-queue.py` | the DRAIN line for the heartbeat (open PRs vs merged-today, and which lane is on it) | runs INSIDE `orchestrator-heartbeat.sh` | no unit of its own | no unit of its own | current — but it is **not a merge-queue runner**, despite the name: landings are performed by `cloud-cell-doctor.sh merge` (cell) and `orch-loop.sh`'s own sweep (Mac) |
| `scripts/orchestrator-harness/claims.sh` | cross-box claim registry — a **LIBRARY** (sourced by the controller and the lanes) | sourced; the registry itself is DATA on the remote (`refs/claims/*`) | none needed | none needed | current (not a service: `up` never installs it) |
| `scripts/orchestrator-harness/capacity.sh` | measured placement — a **LIBRARY** plus a `probe` CLI | sourced per dispatch | none needed | none needed | current |
| `scripts/orchestrator-harness/ci-queue.sh` | CI back-pressure — a **LIBRARY** plus a `status` CLI | sourced before dispatch of NEW-PR work and before a CI rerun — **never** by a repair push (#2927) | none needed | none needed | current |
| `scripts/orchestrator-harness/disk-floor.sh` | the pre-dispatch disk floor — a **LIBRARY** | sourced by the controller | none needed | none needed | current |
| `scripts/deploy-mac-orchestrator.sh` | copies the harness into `$O` and stamps the commit | by hand (§4 step 1) | — | — | current for the DEPLOY; ACTIVATION is `install.sh --start` / `harness-up up` |
| `scripts/cloud-cell-bringup.sh` | full cell PROVISIONING (clone, keys, farm, units) | by hand, once per cell | installs several units | — | current — provisioning is not convergence: `up` does not run it |
| `pi-bootstrap/setup.sh` (+ `SETUP-NEW-MACHINE.md`) | the Mac starter: config farm + `install-launchd.sh` | by hand, once per Mac | — | `install-launchd.sh`'s set | current for CONFIG; **incomplete for the harness** — it installs no controller and no apply timer, and `SETUP-NEW-MACHINE.md` described it only as "the scheduled jobs", which is why this went unnoticed |
| `pi-bootstrap/cell-install.sh` | the cell starter: farms scripts/keys/shims into the layer | by hand, once per cell | — | — | current |

#### What self-heals, and what does not

`heal` (and `status`, which heals by default) re-drives **two kinds of thing, both of them safe while
lanes are working**:

1. **A role that is not running** — it installs what is missing, then starts it, then RE-READS the
   state. The exit code is the re-read, never the installer's, because a start that returns 0 and
   leaves the role dead is the defect this exists to end.
2. **A pin that is BEHIND** (`harness-refresh.sh`'s advance kills nothing, #2278).

**It never repairs the following, by design** — each is reported, with whose decision it is:

* a **DANGLING** unit (its program or cwd was reaped). Restarting cannot fix a path that does not
  exist, and inventing a new path is a decision: `heal` prints the missing path and stops.
* a **DUPLICATE** (two controllers for one repo/state dir). Which one to stop is a human decision, and
  a health verb that kills a controller is a lane-killer.
* a **live-but-LATE** role. Cycling it would drop in-flight lanes.
* a role the read **could not measure** (`UNKNOWN`). Cannot-verify is never repaired by guessing.
* **anything the box has no mechanism for** (the `doctor` role on macOS). `SKIPPED` with a reason, never
  a green line.

#### Two documents this section corrects

* `pi-bootstrap/SETUP-NEW-MACHINE.md` said macOS setup "also installs the scheduled jobs via
  `scripts/install-launchd.sh`". That is true and it is not the whole harness: a Mac got NO controller
  and NO apply timer from the starter, and nothing said so. The doc now names `harness-up up` as the
  second step.
* `ARCHITECTURE.md` §7 (triage) told the reader to check `launchctl list | grep orchestrator` for a
  queue that is not moving. That check answers "is a job loaded"; it cannot answer "is the apply clock
  even installed", which is the state that was measured. It now points at `harness-up status` and its
  role rows as well.

### Deliberate stop (handing the laptop to a human)

The ritual, in order — the point is that **no uncommitted work is lost**:

1. `bash scripts/orchestrator-harness/install.sh --uninstall` (from the checkout root, as §4): the
   installer resolves `launchd-cycle.sh` and `launchd.plist.template` from its OWN directory, so the
   CHECKOUT's copy is the guarded one — a copy that lacks `launchd-cycle.sh` refuses with "missing
   …launchd-cycle.sh" (fail closed, never a silent degrade to the legacy verbs), while a pre-#1975
   `install.sh` still sitting under `$O` has no guard at all, so never run that one — `bootout` + remove
   the plist, so it does
   not restart on boot and no persistent Disabled override is written (which is what `unload -w` did;
   agent-infra#1975). It READS THE DOMAIN BACK afterwards — "is the label still loaded", not "does it
   have a pid", because a `KeepAlive` job inside its 10s respawn throttle is loaded with no pid — and
   fails if the job is still there.
2. `pkill -f "[b]ash $O/orch-loop.sh"` — SCOPED on purpose: an unscoped `-f orch-loop.sh` also
   matches peer controllers, fixtures and tests (`deploy-mac-orchestrator.sh:51-56` measured four),
   and `[b]` keeps the pattern from matching the pkill command line itself. ⛔ **Verify before you
   delete the lock:** the scoped pattern does NOT match a `cd ~/orchestrator && ./orch-loop.sh`
   start (`bash ./orch-loop.sh`), so run `pgrep -fl '[o]rch-loop'` and confirm YOUR controller is
   gone. Removing the lock while it still sweeps lets the next start pass `acq()` — two autonomous
   controllers on one PR queue, which §5.2/§5.3 assume cannot happen. Then `rm -f $O/.orch.lock`.
3. Freeze workers: `tmux kill-server` (or kill sessions individually) and check for strays.
4. Capture every dirty worktree: `git -C <wt> diff HEAD > $O/wip/<name>.patch`, plus a
   copy of untracked files and a `.status` file recording `git status --porcelain`.
5. Post a note on the coordination issue naming the open PRs, so a peer box keeps draining.

Durable state survives a reboot regardless: the signing key, review records, the worktrees'
`.git`, and every PR on GitHub.

### Restart recovery (what has to be re-derived by hand)

Workers do not survive a reboot and their surfaces are gone, so the controller has no
record that they existed. Today this is recovered by reading `git worktree list`, the
`$O/logs/*.log` tails, and the `wip/` patches. **This is the main operational weakness — see
§7.1.**

### Detecting a hung worker (do this first if the queue stops moving)

`pi -p` has no internal timeout, so a reviewer or fixer can hang indefinitely — and because the
concurrency caps count **live workers** (from the launcher's census: `wt-*` workspaces where the cmux
daemon answers, tmux sessions where it does not — on a Mac or a cell, §2.1), one hang permanently
occupies a slot. Observed
2026-10-12: three merge workers hung for 6–9 hours (one had spawned a `find /` that ran for 8
hours), so half the merge capacity was dead weight overnight while the queue looked busy.

```bash
# a worker whose log has not grown in 40+ minutes is hung. ⛔ READ THE CENSUS, NOT `tmux ls`: where
# the cmux daemon answers the workers are `wt-*` workspaces, so `tmux ls` answers EMPTY while every
# lane runs; where the launcher is tmux (a Mac, or a cell whose guest cmux cannot answer — #2210) that
# listing DOES name them, and an empty one then means no workers at all (§2.1). `wt_table` prints
# `<worker>` TAB `<alive|dead|unknown>`; `unknown` means the census could not
# be read and counts as ALIVE (fail-closed), which is the safe reading for a human too.
bash -c '. "$HOME/orchestrator/worker-terminal.sh"; wt_table' | while IFS="$(printf '\t')" read -r s st; do
  [ "$st" = "dead" ] && continue
  f=~/orchestrator/logs/$s.log
  [ -f "$f" ] || { printf '%s %s (no log)\n' "$s" "$st"; continue; }
  # ⛔ A FAILED mtime READ IS NOT 0 SILENCE, AND BASH WILL NOT SAY SO: in `$(( … - mt ))` an EMPTY
  # value reads as 0 (bash does not error on a nulled variable name), so an unreadable log would print
  # as ~56 years of silence and sort to the TOP — the prime reap candidate. The `case` below is what
  # prevents that; the reaper (`file_mtime_epoch`) likewise returns non-zero and SKIPS the worker.
  mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
  case "$mt" in ''|*[!0-9]*) printf '%s %s (unreadable log)\n' "$s" "$st"; continue ;; esac
  printf '%s %s silent %ss\n' "$s" "$st" "$(( $(date +%s) - mt ))"
done | sort -k4 -n -r | head
```

(`stat -c %Y` first with `stat -f %m` as the macOS shape: that is `file_mtime_epoch`'s own GNU-then-BSD
ladder in `orch-loop.sh`, and the order matters — GNU `stat -f` writes a filesystem listing to **stdout**
before exiting 1, so a BSD-first ladder is the bug itself. See §4's "capacity probes are portable".)

`orch-loop.sh` now reaps these itself (`STALE_MIN`, default 40): the session is killed and the PR
is re-dispatched on the next sweep, with `claim_live()` freeing the dead owner's claim.

⛔ **That is ONE signal over ONE population** — the controller's own workers (`wt-*` workspaces where
cmux answers, tmux sessions where it does not), judged on log mtime, and only while the controller itself is alive. It
also decides on a **single** mtime sample, with no CPU tolerance and no second observation. A lane on a
box with no controller, or a process that left no log, is outside it too. §6.5.1 states the requirement; do not read this paragraph as
satisfying it.

⛔ **The complement for the population that paragraph cannot see is `lane-reap.sh` (#2163).** A lane
whose tmux session died with its pane — or whose wrapper outlived a finished turn — is invisible to
`tmux ls`, and that was the measured shape: **76 `pi`-shaped processes for 14 working lanes**. The
process reaper judges a `pi` process tree (the `pi` and its immediate shell wrapper) whose **own
`pi`** — or a pipe-fed `tee` beside it — holds a fleet-namespace log open as stdout/stderr, and reaps
it only when ALL THREE hold: zero CPU delta over a sample window summed over the whole tree; **positive
fleet ancestry** (a human terminal/ssh ancestor refuses, and so does an ancestry that is neither —
`unknown` used to permit and TERMed live trees; on a systemd-scoped cell the supervisor's
cgroup/environ marker — `cell_fleet_marker`, #2868 — supplies the positive fleet evidence that was
previously missing, so the armed reaper is no longer inert there); and either the log is untouched
past 2h or (the log resolved but is
gone) the process has been up past 12h. It is **dry run by default**; arming is the operator's call,
like every other deletion tool here. ⛔ Its hardest rule
is the one a first dry run got wrong: **an unresolvable log is `no-log-evidence` and is NEVER read as
staleness** — that reading flagged 69 lanes and would have killed one that was 7 minutes old. A log
that cannot be READ is `log-evidence-unreadable`, a tree presenting two distinct lane logs is
`ambiguous-log-evidence`, and both are refusals too: evidence must belong to the lane it judges, never
to a sibling that happens to share the wrapper. See §6.5.1b.

### Reading the logs

`$O/logs/orch-loop.log` is the controller's decision log; every line is prefixed by a tag:

```text
[scope] open=24 -> BROAD (auto)             ← or (pinned SCOPE=own) / (pinned SCOPE=broad)
[cap] load=7/100 lanes=4/12 max_lanes=25 zombie=0 lanes_src=census mem_avail=11761M/512M swap_free=588M/600M   ← every gate names its ceiling
[dispatch] load=7 lanes=4 -> 4429 4489
[refresh] queue=READ(7) — every priority tier was READ; 7 candidate(s) listed (agent-infra#1931)
[refresh] +#4508 CLEAN -> backlog
#8219 FAILED:ai-review-gate          ← per-PR verdict for the required checks
#8192 fixer attempt 1                ← routed to a fixer, not a re-record
...
[cap] load=104/100 lanes=4/12 max_lanes=25 zombie=8 lanes_src=census mem_avail=11890M/512M swap_free=588M/600M
[dispatch] skipped (load=104>=max_load=100)   ← and WHY, naming the binding gate
```

⛔ **`backlog=0` alone is never a clearance** (agent-infra#1931). The cycle line carries the pool's
READ state beside it, and `EMPTY` is the only form that means "no work":

```text
=== <date> load=2 lanes=0 backlog=0 queue=UNREADABLE(3m) ===     ← BLIND: the last pool read FAILED
=== <date> load=2 lanes=0 backlog=0 queue=PARTIAL(P0-blocker)(3m) ===  ← a SUBSET, not a pool
=== <date> load=2 lanes=0 backlog=0 queue=EMPTY(12s) ===          ← read successfully, genuinely empty
[dispatch] 223 candidates -> 0 queued, 0 peer-owned (claim), 0 already landed, 6 unjudged (pre-flight), 0 blacklisted (checked), 0 already dispatched, 0 peer-held (ledger skip), 217 not reached (run budget: 12 pre-flight run(s) spent, 6 unjudged) -> 0 dispatched (backlog=0, queue=READ(223)(9m))
```

The age is part of the token on purpose: a value frozen by a refresh that stopped writing cannot pass
as a fresh reading. `UNKNOWN` means no pass has EVER recorded a read — it is not `EMPTY`.

⛔ **A FILTERED-TO-ZERO FUNNEL IS NOT A CLEARANCE EITHER** (agent-infra#2040). The line above used
to read `[dispatch] backlog empty queue=READ(223)` — the pool was read (223 candidates) and the
backlog was empty, and nothing said which step ate the 223. That contradiction idled all three cloud
cells for hours. The dispatch line is now a DECOMPOSITION, and its parts reconcile with the pool
(`listed = queued + peer-owned + landed + unjudged + blacklisted + already-dispatched + peer-held(skipped) + not-reached`):

```text
[dispatch] 223 candidates -> 0 queued, 0 peer-owned (claim), 0 already landed, 6 unjudged (pre-flight), 0 blacklisted (checked), 0 already dispatched, 0 peer-held (ledger skip), 217 not reached (run budget: 12 pre-flight run(s) spent, 6 unjudged) -> 0 dispatched (backlog=0, queue=READ(223)(9m))
[dispatch] 223 candidates -> 0 queued, … , 154 not reached (slot limit: 6 slot(s) filled) -> 2 dispatched | held: … ← `held:` names the gate when one blocks
[dispatch] DRAIN STALLED — no PR merged in 359m while 52 un-owned remain. The issue path stays CLOSED
           (un-owned PRs first): this is a land/capacity problem to fix, not a reason to open new work.
```

⛔ **`peer-held (ledger skip)` IS NOT `not reached (limit)`** (review finding P2-1). A candidate a recent
pass recorded as held by a peer is walked past at no network cost, and it used to be counted NOWHERE — so
it inflated the DERIVED `not_reached` part, the one an operator reads as "raise `LIMIT`", printed beside a
`limit=` at its real value. On a four-box fleet with a fresh collision ledger that is the ordinary case,
not an edge case. A record written before the key existed simply omits the part (no invented zero).

`unjudged` is the one to read first: it means the pre-flight could not JUDGE, which is not "no work".
`UNRECORDED` (no `state/refresh-funnel` yet) is never rendered as an empty funnel.

⛔ **THE LARGEST PART NAMES ITS CAUSE, AND THE FAILING SURFACE, OR SAYS IT HAS NONE** (agent-infra#2183).
`not reached (limit)` was an assertion, not a measurement: the refresh recorded no stop reason, so the line
told an operator to raise `LIMIT` about a pass whose `limit=` it printed at its real value in the same
sentence — and whose actual stop was usually the RUN BUDGET (pre-flight runs, a different budget). Measured
on cell-1, 2026-10-20: `195 candidates -> 0 queued, … 12 unjudged (pre-flight), …, 183 not reached (limit)`
where twelve pre-flight runs had spent the run budget on a board the pre-flight could not read. The part now
reads one of:

```
217 not reached (slot limit: 6 slot(s) filled)          ← the SLOT budget filled
217 not reached (run budget: 12 pre-flight run(s) …)    ← the RUN budget was spent (raise LIMIT and it recurs)
221 not reached (REST spend reserve)                    ← the core budget hit its reserve
  0 not reached (the walk reached the end of the pool)  ← the pool was swept
217 not reached (cause not recorded)                    ← an older writer: no invented reason
```

and the line then appends `— failing surface: <surface>:<n>`. That field is **fixed-point logged, never
guessed**: the names come from the pre-flight's own `INCOMPLETE SURFACES` block where it printed one, and
from this script's own verdict arms where the unanswerable surface is local — `issue-claim-registry` (the claim
registry could not answer), `unrecognised-verdict` (a `VERDICT:` line this reader does not know), and
`unknown:<n>` (the producer printed no block at all, so a parse failure is never "no surface"). The line also
appends `— K released from checked` (or `— released from checked: UNKNOWN (the count was not recorded — see the
refresh log)` when the count could not be recorded: the `checked.txt` rewrite failed, the
`state/checked-release` publish did not land, or the record predates the pass — the entries are then in
fact still suppressed),
`— UNPROVEN suppression: K checked entr(ies) with no proven fact`,
`— K of the N blacklisted are the DISPATCH BACKLOG (CLEAN-judged, awaiting the issue path), not suppressed`
(the `queued` keep-fact means "still in `candidates.txt`", i.e. waiting for the ISSUE PATH — `checked.txt`
stops a re-pre-flight, never a dispatch — so these are work the box has already judged CLEAN, not
suppression, and the two need different repairs; #3110),
`— K checked entr(ies) deferred by the release cap` (a STANDING residue means `CHECKED_RELEASE_MAX` is too
small for this cell — it accepts up to **96** asks per pass, four times the default; above that the value is
coerced to 96 with a WARN, because each ask is an un-timeouted `git` call), `— checked classification REFUSED this pass (<slug>): nothing could be released`
(a refusal repeats every pass until the fact it names is readable), `— checked release DID NOT RUN (the
release sort failed)` (not a cap that bound — the wrong knob to raise), and
`— STOP CONTRADICTION (…)` / `— CHECKED BREAKDOWN DOES NOT SUM (…)` as their own statements — neither of
which touches `reconciled`, because in both cases the pool's parts DO sum.

`N blacklisted (checked)` likewise says WHY: `(checked: queued 7, dispatched 20, pr 3, lane 2, claim 5,
claim-unknown 1, deferred 1, unknown 1)`. `checked.txt` short-circuits a candidate before any network call,
so without the breakdown an operator could not tell a healthy suppression from work hidden for ever — and
until #2183 nothing revalidated those entries at all.

---

## 6.5 Self-healing: wedges

> ⛔ **REQUIREMENTS, not a description of this tree.** Each item is what a conforming install MUST
> do, with the measurement that motivates it, and each ends with the honest status of the shipped
> code today — `IMPLEMENTED` with its `file:line`, `PARTIAL` (naming which half is missing), or
> `GAP` with the tracker. Read it as the standard a box is judged against. A requirement nothing
> implements must never read as a feature, because the whole class it describes is INVISIBLE: the
> box looks alive and does nothing. Line numbers are as of this commit — a `file:line` here is a
> pointer to the code that exists NOW, and a rewrite (agent-infra#1976 rewrites §6.5.6's) moves it.
>
> The owner requirement, verbatim: *"the harness must automatically un-wedge lanes, automatically fix
> PRs, and automatically dispatch issues."* Those are one requirement seen from three sides —
> something must NOTICE, DECIDE and ACT on a schedule that does not depend on the controller being
> healthy. **THIS section specifies the first side — un-wedging — in full.** The other two are
> specified where they are built and are not repeated here: fixing a PR is §5 (`merge-one.sh` marks
> `needsfix-*`, `fix-one.sh` fixes and re-runs the chain) and dispatching issues is §2/§7.2d
> (capacity-gated dispatch against the claimed backlog). Both are IMPLEMENTED; neither is
> re-specified below, so do not read this section's statuses as verdicts on them.

### 6.5.1 A stuck lane is reaped, on a bound that is a number

**MUST.** Every lane in the fleet's own enumeration whose progress signal has not advanced for a
stated bound is reaped with no human. The bound is a **number**; it is judged against the lane's
**OWN** expected duration (never another class of process's); and the decision takes **two
consecutive observations**, or an explicit CPU tolerance, never one reading — a single sample cannot
tell a long model call from a freeze.

**Why (measured).** One **4-core cell** — §4's derivation gives that box `MAX_LANES=10` — held **10
lanes aged 17–29 hours**, each with *minutes* of CPU and no progress, plus a **5.8 GB** abandoned
worktree. That is a box at its lane ceiling, with a full disk, producing nothing — and nothing reaped
any of them. A human found it by reading a report, which is the gap stated exactly: the condition had
no signal of its own.

**Status: PARTIAL — the cell's own doctor now reaps the fleet's harness namespace with two
observations, a CPU tolerance and a human-ancestry gate (§6.5.7), and the controller's own lanes are
still reaped by `orch-loop.sh` with the older one-sample rule. What is NOT met: the doctor exists
only where `cloud-cell-supervisor.sh start` launched it (a Mac cell's launchd job still does not run
it), and the controller's own `reap_stale_workers()` — which runs only while the controller is alive
— still uses one mtime sample, no CPU tolerance, and one 40-minute bound for `lane`, `merge` and
`fix` alike. The doctor's bound is per-run and requires the lane's subtree to show no CPU delta, so
the two in-tree reapers disagree; the doctor is the one this MUST is being met by.**
`reap_stale_workers()` reaps only the controller's OWN
`lane|merge|fix` workers — through the launcher's census, so they are `wt-*` workspaces where the cmux
daemon answers and tmux sessions where it does not (§2.1) — on log-mtime staleness past `STALE_MIN` (default 40) —
one signal, one population, and only while a controller is alive. The fleet-level reapers are
launchd jobs (`templates/launchd/com.tortoise.worktree-reaper.plist`,
`com.eldato.pi-session-reaper.plist`), i.e. **absent on a Linux cell** (agent-infra#1864, #1927).
`tools/fleet/lane_liveness.py:68` deliberately REPORTS `dead` and files an issue, and reaps nothing.
The worktree reaper ships **dry-run** and preserves anything with uncommitted work
(`pi-reap-worktrees.sh:8-32,194`). What is missing is not another kill. The process reaper in §6.5.3
already exists — and #1859, closed 2026-10-16, found it **dead because its script had been recovered
and was never reinstalled**: it survived only as
`~/.pi/agent/state/recovered-1161/pi-reap-orphans.sh.with-ancestry-gate`, with no job pointing at it
(its last run was Sep 16, as of that close). That is the same defect as §6.5.6, stated twice in three
days: **a fix that exists is not a fix.** So the live trackers are agent-infra#1244 (the lane-level
rule exists only as prose), #1862/#1863 (restore the orphan reaper **and schedule it**), and #1927 (a
scheduler the cells run). The INSIDE half — a lane ending on its own silence with a reported verdict —
is §6.5.1c: a different mechanism (a bound in the wrapper), not a third reaper.

### 6.5.1b The leak a session count cannot see, and the reading that replaces it (#2163)

`[cap]` used to print `lanes=<tmux lane sessions>/<MAX_LANES>`. Two failures were baked into that:
a leaked lane whose tmux pane died was **uncounted**, and the obvious replacement —
`ps -eo command | grep -c 'pi --model'` — counted the **wrapper bash**, not `pi`: measured
2026-10-19, it said **76 pi processes for 14 working lanes** while the box carried ~60 finished
residents. The pair is worse than a wrong number: a cell was filled on it and OOM-killed 37 processes
plus its tmux server (agent-infra#2159).

`[cap]` now carries the census, measured by `lane-reap.sh count`:

```text
lanes=<live>/<total> max_lanes=<ceiling> zombie=<n> lanes_src=<census|terminals|unknown>
```

* **live** — the process tree exists AND its log/turn advanced inside `LANE_REAP_LIVE_MIN` (45 min,
  deliberately ABOVE `lane.sh`'s 2400 s wall limit: a live lane inside one long silent tool call must
  not read as dead and license extra dispatch). A lane whose log was **deleted** (a `/tmp` prune can
  do that to a working lane) also counts as live: it may still be working, and for a capacity gate
  "possibly live" must never be counted `0`. This is the number `MAX_LANES` gates.
* **total** — every resident lane tree THE CENSUS CAN ATTRIBUTE: a `pi` tree whose root or a direct
  child holds a fleet-namespace log open. `lanes=14/76` is the reading that makes 62 finished
  residents visible; `lanes=14/25` could not. ⛔ A leaked lane whose stdout is a pty/pipe (no log
  name in the fleet namespace) is outside BOTH numbers — it has no artefact to judge, which is the
  same fail-closed rule as `no-log-evidence`, and the reason the census never claims to be total.
* **zombie** — the box's `Z`-state processes. A box full of corpses otherwise reads as busy.
* **`lanes_src=`** — where the number came from: `census` (this instrument), `unknown` (it ran but
  could not answer), `terminals` (the LAUNCH SURFACE's own worker census — `wt_count lane-` from
  `worker-terminal.sh`, launcher-agnostic: durable cmux terminals AND tmux sessions (launchd Mac or
  cell, #2210), used only
  while a `$O` predates `lane-reap.sh`; named once in the controller log and labelled here, never
  printed as if it were a census). ⛔ The transition value is NOT `tmux ls | grep -c '^lane-'`: that
  sees ONE of the TWO launch surfaces, so on a box where the cmux daemon answers (`wt_launcher` selects
  the `terminal` surface) it reads **0 on a busy box** and the `MAX_LANES` gate stops binding, which is
  the #2159 OOM direction. (tmux IS the launcher where the cmux daemon does not answer — on a launchd
  Mac AND on a cell, #2210 — so the defect is the single surface, not tmux itself.)
* **`lanes=?/?`** — the census cannot be verified: unreadable (`ps`/`lsof` failed), ambiguous (two
  distinct lane logs), or an unidentifiable pipe identity (the reads succeeded but the platform
  prints no per-pipe name, so a `tee` cannot be shown to be the lane's own writer). `?` is not `0`: "ps is broken" and "nothing is
  running" must not render identically. ⛔ The polarity here is the OPPOSITE of what an earlier
  version of this section said: an under-count of live lanes makes the `lanes >= max_lanes` gate
  FALSE and **dispatches more**, so it is a fail-OPEN on capacity. An unreadable census therefore
  sets `LANES_UNKNOWN=1` and the gate REFUSES to add work with that reason (`lanes_unknown (the lane
  census could not be read -> do not add work)`), on the same doctrine as an unreadable memory
  probe — on BOTH add-work paths: the issue batch's dispatch gate AND the PR path's
  `merge-`/`fix-`/review spawns, whose `can_spawn()` carries the same abstention beside the load gate
  and names it in the per-PR refusal line. `[cap]` and both `[dispatch]` lines print `?` for that read
  (`LANES_DISPLAY`); the internal `LANES` keeps the launcher census as a lower bound ONLY so the
  numeric consumers stay numeric, and it is never displayed or used as a licence to dispatch. A `?`
  NUMERATOR with readable totals (`lanes=?/11 zombie=0`) is the same abstention one lane at a time —
  a liveness age that could not be read — and `count` exits 3 for it.

The `reap` pass in `cloud-cell-doctor.sh` runs the same tool in process mode (dry under `--dry-run`,
armed otherwise) and puts `lanes=… zombie=…` in its own pass line, so a cell's `status` answers
"what is this box actually carrying" without reading a process table by hand. ⛔ The reaper's
**policy-inert** pass (it COMPLETED and judged nothing because gate 2 refuses this surface's lanes —
the Linux-cell steady state, `docs/ops/fleet-liveness.md` §11.4) is recorded as **`rc=4`** and the
`status` row says **`INERT`**: named, and **not** a failed pass. Recording it as `cannot-verify`
(`rc=3`) made the operator's health verb exit 1 for ever on a healthy cell, and collapsed a genuine
controller-restart failure (`rc=1`) into the same number — so `doctor` keeps the supervision verdict
in its own rc and a failed restart stays `rc=1`.

### 6.5.1c Every lane is bounded from the INSIDE, and the bound is a reported outcome

**MUST.** A lane ends on EITHER of two limits, and the limit that ended it is **reported with the
measurements behind it**, never inferred from an exit status.

| limit | default | what it is | what it is NOT |
|---|---|---|---|
| wall clock | `LANE_TIMEOUT`, 3300 s | a hard ceiling on the lane's total duration | not a progress signal: it cannot tell SLOW from STALLED, so alone it either kills a lane mid-merge or holds a corpse |
| **silence** | `LANE_BOUND_IDLE_S`, **1200 s** (20 min) | **no output growth AND no CPU delta** (subtree, tolerance 0.10 s), confirmed on **two consecutive samples** | not a byte counter and not a CPU vote: **both** must be quiet, and either one advancing keeps the lane alive however long it runs |

**Why (measured 2026-10-27).** Nine lanes across two cloud cells parked with **0 bytes** of output and
**`00:00:00` CPU**, the oldest for **3 h 32 m** — every one a `pi` in `ep_poll`, an event-loop wait
with no bound of any kind. The trigger was transient (`dial tcp … i/o timeout` against api.github.com,
healthy again 0.26 s later), and a transient becomes a multi-hour corpse only because nothing bounded
the lane's **silence**. Two further dispatch attempts then sat at 0 bytes for 5–15 minutes and were
killed by hand. The same asymmetry was already visible in this tree's own instruments: the builtin
`task` tool bounds a SUB-AGENT on `TASK_STREAM_STALL_MS` (20 min) and `TASK_CPU_STALL_MS` (30 min),
while a lane — a strictly more expensive process, holding a worktree, a claim and a concurrency slot —
had one axis, the wall clock. `mac-lane.sh --status` even states the reason a naive detector had been
deleted: *"bytes is NOT progress for a `-p` lane … reading either — or both — made ten healthy lanes
look dead"*. A `-p` lane prints nothing until it finishes, so a **silence-only** bound would kill every
healthy lane; the CPU delta is the second signal that makes the pair safe.

**Status: IMPLEMENTED** — `lane-bound.sh:309` (`supervise`, the one loop both modes run) with the two
signals at `lane-bound.sh:169` (`pid_alive`, zombie-aware) and `lane-bound.sh:216` (`cpu_cs_of`, the
subtree sum) and the verdict at `lane-bound.sh:255` (`verdict_line`, written from `lane-bound.sh:271`'s
`enforce` BEFORE the kill); wired into the ONE agent invocation at `spawn-gate.sh:1531` (`run_agent`
starts `lane-bound.sh watch`), so it covers every lane, fixer and background worker. Not a rewrite of
§6.5.1: the OUTSIDE reapers are unchanged and that section's `PARTIAL` still stands (two in-tree
reapers disagree). This is the other half — the lane can no longer outlive its own progress, so the
reaper is the backstop for a lane whose wrapper is gone, rather than the only thing standing between a
stalled fleet and a human reading a report.

**How to see why a lane died** — one line, three surfaces (the lane log, stdout, and
`<lane log>.lanebound`):

```text
[lane-bound] VERDICT verdict=stalled tag=lane-42 pid=4242 rc=143 elapsed=1204s wall_bound=3300s
  idle_bound=1200s silent=1204s bytes=0 bytes_delta=0 cpu_cs=7 cpu_delta_cs=0 tol_cs=10
  cpu_unreadable=0 signal=TERM log=/home/cmux/orchestrator/logs/lane-42.log
```

Read it left to right: the **verdict** is `stalled` (the silence limit fired), `exceeded-wallclock`
(the ceiling fired — even on a lane that was still producing) or `finished`; `silent` is how long BOTH
signals were quiet; `bytes` / `bytes_delta` and `cpu_cs` / `cpu_delta_cs` are the two signals at the
decision; `cpu_unreadable` counts samples where the CPU could not be read — an `ps` that failed, AND a
snapshot in which the lane's own pid is absent (a truncated table reads as "0 CPU" if it is trusted,
which is a healthy lane killed) — and every such sample **stands the idle clause down** rather than
arming a kill on absent evidence, with the wall clock still bounding the lane; `signal` is what was
sent (`TERM`, or a following `[lane-bound] KILL` line if the lane ignored the 15 s grace).
`grep '\[lane-bound\] VERDICT' $O/logs/lane-<N>.log` answers "was this lane wedged or slow?"
without re-reading a transcript — the question that previously had no answer at all, because the log is
truncated on rerun and the CPU counter dies with the process.

**Two observations, and when to expect the kill.** A lane is judged on the sample interval
`--poll`, default `min(60 s, idle/4)` — ~3 `ps` calls a minute per lane, because on this box the FLEET
is the load. The silence limit needs **two consecutive confirming samples**, so it fires between
`LANE_BOUND_IDLE_S` and `LANE_BOUND_IDLE_S + 2 x poll` (20–22 min at the defaults); the wall ceiling is
exact to the sample interval it is not allowed to overrun. One sample is never enough: a single reading
cannot tell a freeze from a missed measurement, which is the same rule §6.5.1 states for the outside
reapers.

**Operating it.** `LANE_BOUND_IDLE_S=0` disables the silence limit (and `LANE_BOUND_WALL_S=0` the
ceiling) — an explicit `0` only: a blank or malformed value takes the DEFAULT, because an
`LANE_BOUND_IDLE_S="${UNSET}"` in a launcher must not disarm the bound, and a typo must never read as
"off". Both off prints an `UNBOUNDED by construction` WARN. The same contract as `task`'s
`getCpuStallMs`. Tuning is per dispatch: a lane class that legitimately sits silent for longer (a long
model call with no tool activity) raises `LANE_BOUND_IDLE_S` rather than removing the limit.

⛔ **STATED RESIDUAL.** A lane whose model call takes longer than the silence limit with no output and
no tool CPU is killed as `stalled`. That is the same bound `task` applies to a sub-agent
(`TASK_STREAM_STALL_MS` = 20 min) and the same window a human used by hand (5–15 min) — but it IS a
bound on a legitimate-but-pathological case, and the verdict line says so instead of hiding it, because
`silent=1204s bytes=0 cpu_delta_cs=0` is exactly what a 20-minute model call looks like from outside.

### 6.5.2 The instrument that decides must itself be bounded

**MUST.** The read that decides whether a lane is wedged has an **overall wall-clock budget for the
whole read** — not a per-call one, which bounds each `cmux`/`ps` call and lets total cost grow with
the number of lanes. When the budget expires the read returns **FAILED**. "Cannot read" and "nothing
there" must never render identically, and a timeout must never become an empty successful result.

**Why (measured).** The lane snapshot took **>60 s under load**, and its caller — `pr-doctor`, the
pass whose whole job is un-wedging lanes — refused itself. The whole failure is ONE log line, wrapped
here for width with the interpreter path elided (the log carries this box's home):

```text
[<ts>] pr-doctor: LANE READ FAILED -- cannot dispatch this pass: lane-actions read failed rc=1:
  lane-actions: lane-status.py failed: TimeoutExpired(['/usr/bin/python3', '<…>/lane-status.py',
  '--json', '--sample', '12.0'], …)
```

Five message variants carry that one line. Counted over the **distinct failed passes** in the log
(log-LINE counts in brackets, because a wrapped line is not a second pass) at the 2026-10-18T00:42Z
read — **800** passes, 1318 lines: `lane-status.py failed: TimeoutExpired` **483** (798), `REFUSING a
DEGRADED snapshot` **247** (425), `snapshot UNVERIFIABLE (N of an unknown fleet size) -- re-scanning
without the cache` **61** (80), and **9** in two rarer forms (`TIMEOUT … no answer within 300s`, 1
pass / 2 lines; and `rc=-1: TimeoutExpired` under a CommandLineTools interpreter, 8 passes / 13
lines). In the third the cached scan
declines to vouch for a roster it cannot see whole, so it re-scans uncached, which is the read that
times out in the first; in the second the reader refuses a snapshot it can see is degraded. Either way
the cost grows with the number of lanes, the only bound on the WHOLE read is a CALLER's, and the pass
dies instead of returning a verdict. The log keeps growing, so treat these as a dated snapshot, not a
constant.

Measured in `~/.pi/agent/state/pr-doctor.log`, read 2026-10-18T00:42Z:

| day | failed passes | successful passes | share failed |
|---|---|---|---|
| 2026-10-16 | 148 | 192 | **44%** — the “every other run” figure |
| 2026-10-17 | 47 | 149 | 24% |

Counted as distinct timestamps, with `pass:` lines as the successes. The un-wedger could not read the
thing it un-wedges for a large share of a day, and each failed pass dispatched nothing.

**Status: PARTIAL — a WHOLE-READ budget now exists for the lane roster, and the reader it wraps
still has none of its own.** The polarity is IMPLEMENTED: `lane-status.py` raises `SystemExit(3)`
rather than publish an empty roster; `lane-actions.py` refuses a `degraded` snapshot
(`_refuse_if_degraded`); the retired `retired/queue-dispatch.py` raised `LaneReadError` naming the
timeout instead of returning `[]` (a record of the polarity, not a live reader — agent-infra#1874);
`pr-doctor.py` refuses the pass **when it has work to place** — and deliberately
stays exit 0 on a blind read with nothing classified, because manufacturing a failure out of an idle
beat is its own defect (`:812-819`).

New as of 2026-10-18: `lane-actions.py` takes **one deadline for the whole read** (`--budget`) and
splits it across its two attempts, so the cached pass can no longer consume the retry's allowance and
the tool cannot outlive the caller waiting on it; a failed re-scan returns the roster already read
with `COMPLETENESS UNMEASURED` on stderr instead of discarding a readable datum. `pr-doctor.py`
consumes the **published** roster (`$STATE/lane-status.last.json` via `lane-actions.py --stdin`,
**2.8 s measured**) instead of paying a scan on every pass, and falls back to a bounded scan when that
file is absent, stale, degraded, partition-less or unreadable — saying which happened.

What does NOT exist: a deadline inside `lane-status.py` itself. Every remaining bound on the whole
read is a CALLER's — `pr-doctor.py`'s `LANE_BUDGET_S + margin` on the fallback scan. (The reader does
hold per-CALL bounds — 60 s, 45 s, 45 s — and that is exactly the shape this MUST rules out: it bounds
each probe and lets their SUM grow with the fleet.) The retired `retired/queue-dispatch.py` was the
other bound — 600 s on its direct `lane-status.py` call — and it printed the residual: *"lane-status.py
has no internal deadline, so this is the only stop between a stalled scan and an unbounded wait"*.
That caller is gone (agent-infra#1874), so the sole remaining caller bound is `pr-doctor.py`'s.

⛔ AND THE PASS MUST SAY WHAT IT DID. A dispatcher that refuses is a failure the fleet can see: every
exit of `pr-doctor.py` writes `$STATE/pr-doctor.status.json` (`rc`, a one-line reason, the PRs that
went out) and prints `dispatched N of M queued — <why>`, so `dispatched 0` is never healthy while the
queue has runnable items; `objective.py` renders the last pass's verdict as `PR-DOCTOR(last run):
RED rc=N Nm ago — <reason>` beside the queue's own shape, and `heartbeat-loop.sh` prints the same
verdict and launchd's last exit. ⛔ AND "RED rc=N" IS NOT THE WHOLE VOCABULARY (review P3, #2291): a
pass that consumed nothing because the BOX's own spawn gate refused every order is
`WAITING (no capacity) rc=6` (on the load axis; a disk/fork/land-backlog refusal is a repair, never a
wait — the axis and its remedy ride the same line), so a reader keyed on `RED` alone does not see it. The `issue_work` field is **PUBLISHED AND UNREAD**: the retired
`retired/queue-dispatch.py` was its only consumer — it SKIPPED new issue work while un-owned PRs
existed, refusing only on a positive, FRESH reading (a missing, stale, unreadable or refused record
blocked nothing and said so).
⛔ DO NOT READ THIS AS A LIVE GATE (agent-infra#1874 retired the dispatcher): nothing consults
`issue_work` today. The owner's PR-first selection now lives in
`scripts/orchestrator-harness/live-ownership.sh` — the shell half of the same rule, landed in
agent-infra#2129 and called from `orch-loop.sh` by that same commit (NOT by #1894, which wired the
`pr-doctor` SPAWN path and never touches this module) — and that module does not read `issue_work`
either, which is what makes the field PUBLISHED AND UNREAD rather than merely re-homed. The orphan is
disclosed in `scripts/heartbeat-loop.sh` and in the retirement note at the foot of this file.

### WHICH REPO A PASS GRADES — evidence, never a default (2026-10-21)

`pr-doctor.py` used to carry `REPO = "daniel-ospina/tortoise"` and `REPO_DIR =
$HOME/Documents/GitHub/tortoise` as module constants, so every pass spoke for ONE repo whichever
repo it had been started for. MEASURED: the installed `com.tortoise.pr-doctor` printed a clean
`nothing to do` while `daniel-ospina/agent-infra` held 52 open PRs (the 9 tortoise PRs were all in
cooldown). The verdict was true about tortoise and false about the machine, and nothing in the line
said which repo it was about.

`resolve_repo()` now decides the target from evidence, highest first, and REFUSES (exit 2) rather
than defaulting:

| rank | source | why it ranks there |
|---|---|---|
| 1 | `--repo OWNER/NAME` | the operator's explicit word for THIS invocation |
| 2 | `PR_DOCTOR_REPO` (+ `PR_DOCTOR_REPO_DIR` as its checkout) | the JOB's seam — what `pr-repair-loop.sh`, `install-repair-service.sh` and `repo-target.sh` set for this invocation. Honoured as EVIDENCE, never as a default: an empty seam answers nothing (#2716, reconciled) |
| 3 | `OR` | the slug the LAUNCHER resolved and passed — `orch-loop.sh`, the cell session strings and `install.sh`'s rendered plist all carry `OR` + `REPO` + `O` as per-invocation state |
| 4 | `REPO`'s `origin` remote | the checkout the launcher named, read for what it PROVES it is |
| 5 | the cwd's `origin` remote | the weakest evidence: whatever checkout the process happens to be in |
| 6 | REFUSE | exit 2, naming every source it looked at |

⛔ THE macOS LITERALS ARE GONE, and that is the deliberate part: `daniel-ospina/tortoise` and
`$HOME/Documents/GitHub/tortoise` were the fallback when no seam was set, so a pass that named no
repo graded tortoise and reported `nothing to do` while another repo's queue sat open (#2235). A
cell sets the seam pair (rank 2); a caller that sets NOTHING gets a refusal, not a default.
`pr-repair-loop.sh` and `install-repair-service.sh` therefore refuse too when they cannot compute
the pair — a seam with no value is a launcher bug to be seen.

`GH_REPO` and `TORTOISE_REPO` are deliberately NOT sources: both are global on a fleet box (a
pushed `keys.env` exported `GH_REPO=daniel-ospina/tortoise` and `gh` honoured it for every command
— #2235; an ambient `TORTOISE_REPO` outranked a launchd entry point's own directory — #9388), so
inheriting one grades a repo nobody named. Once the target is resolved, `GH_REPO` is PINNED to it,
so a worker this pass spawns cannot have its own rail answer about another repo.

The checkout is used only when its `origin` proves the resolved repo: a pass launched for A from
B's checkout grades A, reads B's checkout only for the identity probe, and cannot `git -C` B, add
B's worktrees, or read B's branches. A launcher that names two repos (`OR=A` with a `REPO` checkout
of B) is refused, naming both. With no checkout the queue is still graded and the pass says
`checkout: NONE … NOTHING will be spawned` — deliberately, because a 52-PR queue must not go
unreported just because this box has no worktree for it.

`--all-repos` (set from `PR_DOCTOR_REPOS='owner/name[=checkout],…'` or repeated `--repo`) grades
the whole set and prints ONE ROW PER REPO:

```text
repo=daniel-ospina/agent-infra          open_prs=52    unplaced=52    dispatched=0     verdict=REFUSING rc=2
repo=daniel-ospina/tortoise             open_prs=0     unplaced=0     dispatched=0     verdict=clean rc=0
```

The verdict words are the exit codes' own vocabulary and stay distinct: `clean` (`0`), `REFUSING`
(`2` — I could not READ the queue), `UNPLACED` (`3` — I read it, placed the work, no worker took it),
`CRASH` (`4`), `NO-CAPACITY` (`6` — the BOX's own spawn gate refused the order, so nothing was
consumed; never `RED`, which is the generic unknown-code fallback). Each entry is `owner/name`, or
`owner/name=<checkout>` when the checkout is not the one
`REPO` names; `?` in a column means the pass never got far enough to count it. Repeated `--repo`
flags REPLACE the `PR_DOCTOR_REPOS` default rather than joining it (a named list is the narrower
instruction), and a checkout is only used when its `origin` proves the resolved repo — a remote on
another host, a local path or a `file://` URL proves nothing.

The aggregate exit is non-clean when ANY repo is (precedence `4` crash > `2` could-not-read > `3`
nobody-took-it), the canonical `pr-doctor.status.json` names every repo and carries a `repos` list,
and each repo also writes its own `pr-doctor-<owner>-<name>.json` register (plus
`pr-doctor.<owner>-<name>.{status.json,log}` in `--all-repos` mode) — so the beat's single line can
no longer launder a stuck repo behind a quiet one. ⛔ THE REGISTER IS REPO-SCOPED FOR A SINGLE-REPO
PASS TOO (#2700: one shared `pr-doctor.json` let one repo's in-flight rows consume another's budget,
reporting `budget fix=0` for hours), and `_state_file()` is its ONE naming authority — the writer and
`--status` both call it, so the file a pass writes is the file an operator reads. There is
deliberately no default set: `--all-repos` with no `PR_DOCTOR_REPOS` refuses, because a filesystem
scan would answer with whatever checkouts happen to exist, which is a default by another name.

Two repo slugs may also collide on the tag that names their state: `acme/tools-api` and
`acme-tools/api` both derive `acme-tools-api`, which would make one repo's cooldown rows decide
the other's budget slots — a set with a colliding tag is refused before anything is read, and
`repo_tag()` is the one spelling both the register name and that guard agree on.

⚠️ **Declared residual — the dispatch ceiling is per REPO, not per pass.** `capacity()` and
`pass_budgets()` are computed from the state of the repo being graded, so a `K`-repo set may place up
to `K × (MAX_FIX + MAX_REVIEW)` in one invocation, and `--max N` means `N` per repo. It is bounded by
finite `K` and by `spawn-gate.sh`'s own load and disk gates (every spawn still passes through
`nonblocking-dispatch.sh` → `run_agent`), and one pass per repo is **#2281**'s subject, not this
mode's. Said here because this section is where the next reader of the mode looks.

### The SUPPLY half — a pool that refills itself (`worker-supply.sh`)

`pr-doctor` CLASSIFIES the open-PR queue and places at most one pass worth of orders. **Nothing
supplied the workers those orders needed**, and the measured shape is a pass that grades work and can
place none of it (2026-10-27T03:30Z–03:45Z, three consecutive passes on the operator's Mac):

```
pass: 22 open PRs :: rerun-checks=6 resolve-conflict=10 skipped-running=6
      (capacity fix=16 review=12, inflight=0 (alive=0 unknown=0), budget fix=16 review=12 total=28)
REFUSING: 16 order(s) no worker accepted and nothing was dispatched -- not a clean pass
EXIT rc=3
```

Capacity was configured, orders were graded, workers were zero — and five hours earlier the same daemon
logged `dispatched 3 of 4 queued — ok`, so the pool EXISTED and EMPTIED. Dispatch was the only thing
that had ever created a repair worker: supply existed exactly as often as a pass found actionable PRs
*and* could place them. A worker killed mid-order (a machine sleep, a cap kill, an OOM) leaves
`$O/bg/<name>.started` behind with no process, and its PR then waits for the doctor's own 45-minute
cooldown and for a later pass that can still place work.

`worker-supply.sh` is that supply half and nothing else. It walks the ORDER POPULATION
(`$O/bg/prd-*.started`, the dispatcher's own acceptance record), asks the HARNESS for each order's
liveness (`nonblocking-dispatch.sh --status <name>` — the same reader `pr-doctor.worker_live()` asks, so
the two cannot disagree), and re-offers the DEAD ones **through the one dispatcher, with the argv that
dispatcher itself recorded** (`name worktree prompt cap kind`).

⛔ **AND THE LIVENESS QUESTION IS ASKED OF THE WORKTREE, NOT OF ONE NAME.** `pr-doctor.worker_name()`
is REPO-QUALIFIED (`prd-<repo-tag>-42`, in **every** mode since #2725) while the worktree is
`prd-42` in **both** modes, so two orders can name one directory — the #2280 defect, which
`worker_live_for()` (`pr-doctor.py:3637`) fixes on the doctor's side and which this supervisor must
not reintroduce one
layer down (`nonblocking-dispatch.sh` performs **no** liveness check of its own, so this is the only
guard there is). Before every re-offer it asks `--status` for **every order that records the same
worktree**, plus the doctor's own alias `prd-<n>` when that differs from the order's name: a `running`
holder refuses the re-offer (`live`, the slot is held), and an unanswerable holder refuses it too
(`unknown`) — an unreadable other name is never a licence to spawn blind. `worker-supply.test.sh`
case (d2) pins all three arms and reddens when the guard is removed.

```bash
bash worker-supply.sh status     # the last pass record + a FRESH live count — the record is not the reading
bash worker-supply.sh heal       # one pass, now (`refill` / `--once` are the same verb)
bash worker-supply.sh --dry-run  # decide and print; spawn nothing, write no ledger row
bash worker-supply.sh --loop     # what the service runs: pass, sleep INTERVAL, repeat
```

⛔ **THE KNOBS ARE VALIDATED WHERE THEY ARE ENFORCED, NOT ONLY WHERE THEY ARE RENDERED.** Both units
render `WORKER_SUPPLY_INTERVAL_S` / `WORKER_SUPPLY_PREFIX` / `WORKER_SUPPLY_MAX_REFILLS` into `Environment=`,
but the environment is not the only way in (an operator, a shell profile, or a hand-edited unit can set
them directly), so `worker-supply.sh` re-validates **every numeric knob** at startup against `valid_num()`
and falls back to the shipped default with a `knob:` line — `status` prints the resolved values
(`knobs: interval_s=… max_refills=… prefix=…`), because what the unit renders and what is enforced are
different facts once an override is rejected. Every one of these failure modes is FAIL-OPEN and was
found by review: a non-numeric `MAX_REFILLS` makes the per-order crash-loop bound INERT (`[ <n> -ge two
]` never parses, so every dead order is re-offered for ever); a non-numeric or zero `INTERVAL_S` makes
`sleep` return at once, i.e. a hot loop rather than a cadence; a non-numeric `LOCK_MAX_S` makes the lock
age test fail to parse, so a **pid-less lock is taken over while its holder is alive** — the double
supervisor the guard exists to refuse; a non-numeric `STALE_SLACK_S` names a variable under `set -u` and
kills the probe; and `SPAWN_TIMEOUT_S` / `PROBE_TIMEOUT_S` / `LOG_MAX_BYTES` lose their bound silently.
The INSTALLER refuses the same values at render time instead — refusing is right for an install question
and wrong for an already-running supervisor, which must keep supplying.

⛔ **AND A PASS THAT COULD NOT READ THE POOL DOES NOT CALL ITSELF CLEAN.** `live=0 dead=0 unknown>0` with
nothing refilled is `decision=unreadable`, rc=2 ("a read a pass needs could not be taken") — the same law
as the doctor's `REFUSING` line, not a green tick over a pool nobody could read. A worktree holder whose
liveness is unreadable keeps its order counted as dead; it is not quietly subtracted from the census.

**A worker is ACCEPTED by a FILE, never by a return code.** The dispatcher writes `$O/bg/<name>.pid`
and `.started`; `--status` then answers `running`, and `pr-doctor.worker_live_for()` — the doctor's own
accept check — returns `True`, so the order stops being `undeliverable`. The supervisor therefore
re-asks `--status` after every re-offer and records nothing on an unconfirmed one: `running` is LIVE
(holds a slot, never re-offered), `done` is COMPLETE (the brief RAN — the doctor's next pass re-grades
that PR against its new head, checks and cooldown, and replaying a finished order would bypass that),
`failed|lost` is DEAD (re-offerable, bounded by `MAX_REFILLS`), and **anything unreadable is
UNKNOWN and spawns nothing** — a second worker into one deterministic worktree destroys the first one's
log/.rc/.pid, which is the doctor's own measurement, not a style preference. A `running` past the
order's cap+slack is reported as `stale-claim` and acted on by nothing, because a late refill costs an
interval while a double spawn destroys a live worker.

| self-heals | does NOT self-heal |
|---|---|
| a DEAD order (the worker crashed `failed`, or died `lost`) — re-offered within one interval | an order that COMPLETED (`done`): the doctor re-grades that PR on its next pass, and a replay would re-execute a finished brief |
| a supervisor that crashed, was killed, or exited 0 (both units `Restart=always` / `KeepAlive`) | a `contract_note()` refusal (#2518): the repo's required-check/human-gated declaration is a HUMAN's to supply |
| a stale lock whose holder is gone (CAS takeover, bounded by `LOCK_MAX_S`) | a checkout it cannot read (`has no readable 'origin' remote`) — no worktree can be materialised |
| a loop that stops on SIGTERM (the trap EXITS; the interval is `wait`ed, not `sleep`t through) | an order whose recorded worktree is gone or now on ANOTHER branch — the PR must be re-classified, not replayed |
| an unchanged unit re-installed (byte-identical ⇒ no reload, no restart of a healthy supervisor) | an order that spent `MAX_REFILLS` (2): a worker that keeps dying is a DIAGNOSIS, and the pass names it |

Anti-goals, stated so they are not "fixed" later: it spawns `pi` never, calls `gh` never, records no
review and lands no PR. It pre-empts nothing — when the pool is full it DEFERS and says so. And
`fix + review` is the machine's ONE budget (`MAX_FIX`/`MAX_REVIEW`, read from the orchestrator plist, the
same source `pr-doctor.capacity()` reads) — neither shipped unit sets it, so there is no second copy to
drift.

**Install — one command per platform, and it converges (re-run it after a merge, it is idempotent):**

```bash
# Linux (systemd) — renders the unit from machine state and enables it; `--status` reports installed/enabled/active
bash scripts/install-worker-supply.sh --install

# macOS (launchd) — the ONE launchd installer; it renders templates/launchd/*.plist, including
# com.eldato.worker-supply.plist, and reloads only on change (scripts/install-worker-supply.sh REFUSES on
# Darwin and names this command rather than shipping a second launchd path)
bash scripts/install-launchd.sh
```

⛔ **`KillMode=process` in the systemd unit is load-bearing, not tidiness.** A pass re-offers an order by
BACKGROUNDING a worker and returning; under the default cgroup teardown the end of that pass SIGTERMs
the worker it just started — the measured #2716 shape (two workers "launched, running", 0-byte logs,
`is-active=active`). `worker-supply.test.sh` pins it, along with `Restart=always` (the measured failure
is an ORDERLY exit with nothing coming back, which `on-failure` reproduces byte for byte) and the
absence of a rendered `MAX_FIX`/`MAX_REVIEW`.

```bash
bash scripts/orchestrator-harness/worker-supply.test.sh   # hermetic; asserts its own wall-clock bound
```

The suite grades the shipped supervisor against a stub dispatcher that mirrors the real one's grammar
AND its file-descriptor discipline (`exec >/dev/null 2>&1` in the worker), asserts the doctor's OWN
reader flips `absent → live`, and carries two mutations — neuter the refill step and the refill case
reddens; delete the single-instance guard and the two-supervisor case reddens.

### WHICH CONTRACT A PASS JUDGES BY — resolved, or refused (agent-infra#2518)

Resolving the repo is not the whole decision: `objective.py` also holds the **contract** a PR is
judged by — the REQUIRED check contexts (minus `ai-review-gate` for the gated set) and the
human-gated SURFACE paths. Those are `objective.py`'s built-ins, and they describe exactly one repo.
A pass for any other repo reads ITS queue and would judge it by a declaration nobody wrote for it:
**measured** on `daniel-ospina/agent-infra` with an all-green, clean-attested check list, that
classifies `rerun-checks` (every green PR re-triggered, its attestation staled) and
`touches_surface()` is always `False` (a surface-touching diff handed to the automated lander).

So the contract's scope is decided per pass and **fails closed**:

* The contract is the repo's own when the operator supplied it through `objective.py`'s existing
  seams — `OBJECTIVE_REQUIRED='<ctx>,<ctx>'` and `OBJECTIVE_SURFACE='<path>,<path>'`. Both must be
  non-empty: an empty value is "not supplied", never "this repo requires nothing".
* It is also the repo's own for the **one** repo the built-ins describe (`REQUIRED_DEFAULT`) —
  refusing that one would kill the shipped single-repo doctor.
* Otherwise the pass **refuses to dispatch** and says so in its log. It still grades the queue and
  prints the row — `open_prs`/`unplaced` are the measurement the fleet keeps losing — but an
  unplaceable queue reports `UNPLACED` (`3`), not a confident order derived from another repo.

⛔ The refusal is DERIVED from the resolved slug on every call, never stored: a module flag left over
from the previous repo in an `--all-repos` set would refuse (or, worse, allow) the next one's
dispatch for a reason about a different repo. ⚠️ **Declared residual:** the seams are machine-wide,
so one `--all-repos` set cannot describe two repos at once — a set grading a repo whose contract was
not supplied is read-only by design. Per-repo contract wiring is **agent-infra#2518**, and one doctor
instance per repo is **#2281**.

agent-infra#1774, #1788, #2281, #2518.

### 6.5.3 Ancestry is the safety rail

**MUST.** Any process whose chain reaches a human terminal (`Terminal.app`, `iTerm`, a login shell)
is never touched, however parked it looks. `ppid 1` proves nothing on its own: a daemonising service
reparents to 1 **by design**. If either read is ambiguous, REPORT and do not reap.

**Why.** It is the one gate that stops a reaper destroying a human's work, and both failure
directions have already been measured: too little reaping (the ≈22 CPU-hours across six undetected
runaways recorded on #1142) and too much (#1393 deleted a live worktree). A reaper that skips this
gate is a lane-killer, not a reaper.

**Status: IMPLEMENTED** — by FOUR carriers that do NOT carry the same gates, so say which one you
mean. The table below is the per-carrier gate inventory this section asks for; a carrier that ships
with a weaker set says so here rather than being discovered at arming time.

⛔ **`orphan-reap.py` is cited by SYMBOL, not by line** — except the header's numbered gates, which
are pinned as a RANGE (`:13-34`) because the header is where a reader starts. `--pool pi`
(2026-10-22) added ~700 lines above these definitions, so every `:`-citation into that file that
this section used to carry had become wrong: a doc that names `:175` for `ancestry()` now points
into an unrelated function.

| carrier | scheduled by | ancestry | gate 4 launchd-registered | gate 5 designed-daemon | gate order |
|---|---|---|---|---|---|
| `orphan-reap.py --pool orphan` (`ancestry()`, rule at `:13-34`) | **nothing** (§6.5.1); ships dry-run (`--apply` opt-in) | walk to the top | yes (`registered_launchd_pids()`) | yes — pidfile / daemon argv / recently-touched output / live holder of a socket it owns (`designed_daemon()`) | the sanctioned owner — the reference set |
| `orphan-reap.py --pool pi` (2026-10-22) | **nothing** (§6.5.1); ships dry-run (`--apply` opt-in) | walk to the top, **and an unparseable walk or a chain carrying NO host app is NOT rejected as "no human" — it is `unknown` and abstains** (`gate2_host_decision()`) | **NO** | **NO** | ⚠️ a WEAKER gate set than the row above, stated here because that is what this table is for: no launchd or designed-daemon gate, so its safety rests on gate 2 plus the canon's own `idle` verdict. Under the recorded rule (#1207, owner-approved option A on #1297) the hostless chain — this pool's TARGET population, since a reparented `pi` has no ancestry left — is `unknown` and **report-only**, so the census ships and the reapable set is EMPTY BY DECISION until that decision is reopened (`AUTHORISE_HOSTLESS_CHAINS`) |
| `lane-watchdog.py` (`human_above()`, `:467`) | `heartbeat-loop.sh:365-368` (armed) | walk only | no | no | two-gate carrier; ARMED |
| `pi-reap-idle.sh` (`:55`, `:381-429`) | hourly job, ships armed | additive third gate, can only REFUSE | no | no | REFUSE-only |
| `pi-reap-orphans.sh` (this restore, #1862) | `com.eldato.pi-reap-orphans.plist`, hourly, ships **DISARMED** (`REAP_ORPHAN_DRY_RUN=1`) | candidate's OWN command must not be an anchor — a `ppid==1` candidate has no observable ancestor above launchd, so a reparented **descendant** of a human session is NOT detectable here | yes (`launchd_pids_load`; unreadable/unshaped probe aborts the pass, a host without `launchctl` logs the gate INERT) | argv + pidfile arms only — the socket-holder arm is deliberately NOT carried (it needs a second fleet-wide `lsof` pass on a host this tool exists to unload) | listed in the script header |

`orphan-reap.py` walks to the top (`ancestry()`) **and** adds the two gates `ppid 1` cannot
express: launchd registration (gate 4 — a managed daemon has an owner) and designed-daemon (gate 5 —
pidfile, daemon flag, recently-touched output, or any live holder of a socket it owns). Gate 5 was
added AFTER a dry run passed gates 1-4 on three processes and all three were wrong to reap (gate 4
came earlier, after the reaper killed the owner's own UI). It ships **dry-run** (`--apply` is the
opt-in) and nothing schedules it today (§6.5.1).
`lane-watchdog.py:467` (`human_above()`) has the ancestry walk only — armed by
`heartbeat-loop.sh:365-368`, and one of the two carriers that actually RUN. `pi-reap-idle.sh` carries
the same idea as an ADDITIVE third gate that can only REFUSE (`:55`, `:381-429`), and its hourly job
ships armed. ⛔ Note what is NOT that guard:
`reap_stale_workers()` closes a worker **through the launcher's census**
(`wt_table` → `wt_close`), which is safe for the workers the harness itself created and is not an
ancestry test — do not read one as the other. Since the launcher change it targets the worker's own
surface (a durable terminal, or a tmux session — see §2.1), never a session NAME alone.

⛔ **The ancestry row is where arms get lost.** `ppid==1` is both this section's warning and
`pi-reap-orphans.sh`'s candidate filter: once the kernel reparents a process, `ps` no longer holds
the pre-reparent chain, so for that carrier an ancestor ABOVE launchd is not observable and its
ancestry gate reduces to "the candidate must not BE a terminal / login shell / multiplexer". That is
stated in the script header, in the plist's arming note, and pinned by a suite leg — do not read the
narrower guarantee as the wider one when deciding whether to arm a job.

### 6.5.4 Reaping releases what the lane held

**MUST.** A reap returns the lane's resources: its worktree, its branches, and its test container.
Otherwise "reaped" means "the process is gone and the disk is still full", which is the state the
5.8 GB measurement is actually about.

**Status: GAP** on all three — but for three different reasons, and only the first is by design:

- **Worktree.** Removed only when it is clean, unreferenced, reachable and **7 days** old
  (`pi-reap-worktrees.sh:8-32`, and the job ships dry-run, `:194`), so an abandoned worktree holding
  any uncommitted work is PRESERVE by construction. Correct, and not a release.
- **Branches.** A deleter exists and is fenced — `cleanup-stale-branches.sh` runs `git branch -d`, then
  falls back to a compare-and-swap only for the `merged` class (`:2044`, `:102-110`), and its remote
  leg is `git push origin --delete --force-with-lease=<ref>:<oid>` (`:1546`, again `:1657`). Nothing in
  the harness invokes it: the reapers here never delete a branch, and its own job ships with NO
  execute flag, so the pass "classifies and reports and deletes nothing"
  (`templates/launchd/com.tortoise.branch-reaper.plist:40-43`).
- **Test container.** **No harness code manages one.** On a Mac cell the heaviest disposable thing a
  lane owns is its `.venv` — agent-infra#1949 exists to reap exactly that and is still open; a Linux
  cell has no container lifecycle here at all.

agent-infra#1858 (disk measurement), #1864/#1927 (scheduling).

### 6.5.5 What is deliberately NOT automatic

**MUST.** The following stay out of automation, with the reason stated rather than assumed:

- **A candidate with diagnostic value stays.** Evidence beats tidiness — the `orphan-reap.py`
  header line "Reapable != right to reap" (cited by symbol, per the rule above), and
  `pi-reap-worktrees.sh`'s PRESERVE verdicts.
- **Arming is a per-machine operator decision, and the shipped default DIFFERS by job — say which
  one you mean.** The worktree reaper ships DRY-RUN (`pi-reap-worktrees.sh:194`), and so does
  `orphan-reap.py` (its `--apply` default, cited by symbol) — with nothing scheduling it. The process reaper restored by
  #1862/#1863 (`pi-reap-orphans.sh`) is now SCHEDULED (hourly
  `com.eldato.pi-reap-orphans.plist`) **and ships DISARMED**
  (`REAP_ORPHAN_DRY_RUN=1`, pinned by `install-launchd.test.sh`), so the schedule and the arming
  decision are deliberately separable — a template bump that armed it would red CI. **Arming it is
  a REACHABLE, dated, reversible step** (#1863 review ISSUE 2): the template renders the placeholder
  `{{REAP_ORPHAN_MODE}}`, and the installer writes the dated record that renders `0` —
  `scripts/install-launchd.sh --arm-orphan-reaper --reason '<why, dated trigger>'` / reverse it with
  `--disarm-orphan-reaper`; `--status` prints which state the box is in, and a half-written record
  renders DISARMED (fail-closed). Hand-editing the installed plist is NOT the route — the next
  render reverts it silently, leaving an installed-but-inert killer. The two that
  actually run are ARMED: `heartbeat-loop.sh:365-368` passes `--apply` unless
  `LANE_WATCHDOG_APPLY=0`, and `com.eldato.pi-session-reaper.plist:30,49-50` sets `REAP_DRY_RUN=0`
  "by design". The rule that decides it is the same either way: a wrong reap destroys work, a wrong
  non-reap only costs disk.
- **`lane_liveness.py` never acts on `wedged`/`idle`** — it escalates `dead` only (`:68`). The one kill
  on a wedge signal is `lane-watchdog.py` (`os.kill`, `:623`), and it targets a frozen CHILD process,
  never the lane.
- **A P0-consequence action stays human** (data loss, deletion, spend) — the standing rule in
  `AGENTS.md`. Automatic reaping is bounded by exactly that line.

**Status: PARTIAL — three of the four exclusions are code; the fourth is prose only.** Each bullet
names where its exclusion actually lives; there is no single file that says "these four stay human".
`orphan-reap.py`'s five gates and `pi-reap-worktrees.sh`'s PRESERVE verdicts are real checks;
"P0-consequence" is an instruction to whoever arms the job, and nothing verifies it.

### 6.5.6 The controller must be un-removable by a routine install

**MUST.** `install.sh --start` / `--restart` must **enable and load** the job (`launchctl enable` → `bootout` →
`bootstrap`, falling back to legacy `load`, and saying which path ran), **assert** the outcome (the
label loaded with a pid, and the heartbeat file advancing within ~30 s), and exit **non-zero** if
either fails. A **watchdog** must restore a REMOVED service: `KeepAlive` relaunches a job that EXITS
(a bare `<true/>` on ANY exit, not only a crash — `launchd.plist.template:15-18`), and does nothing
for a job that is no longer loaded.

**Why (measured).** `launchctl unload -w` **writes a persistent Disabled override**, and the `load -w`
that follows has to bootstrap to clear it — and that bootstrap is what failed on 2026-10-17
(`Bootstrap failed: 5: Input/output error`). launchd's own log:

```text
15:21:41  Setting service com.eldato.orchestrator-loop to disabled
15:21:41  removing service: com.eldato.orchestrator-loop
```

The controller was **absent**, not crashed, and it dispatched nothing for 48 minutes and then 19,
with the heartbeat simply gone — the only signal that it had happened.

**Status: the installer half is CLOSED (#1975).** Every requirement in the list above is now either
implemented or explicitly not claimed:

| requirement | where |
|---|---|
| never write a persistent Disabled override | no shipped line invokes `disable`, `unload`, or `-w` (asserted from the stub's argv log wherever the path runs, **and** from a source scan of every TOP-LEVEL `*.sh`/`*.template` in `scripts/orchestrator-harness/` where it cannot (`*.test.sh` excluded — its fixtures must be free to contain those verbs; subdirectories such as `retired/` and the rest of the repo are not reached by the glob — hand-checked at the time of writing, not by a test)); `--uninstall` uses `bootout` only |
| clear a disable a previous flow already wrote | `lc_start` runs `enable` before `bootout`/`bootstrap`; the status it writes is read back with `print-disabled` |
| actually load the job (not just PRINT the command) | `install.sh --start` / `--restart` call `lc_start`; a plain run never starts anything |
| assert the job came back | `lc_assert_running`: new pid + heartbeat strictly advanced + `runs` did not move across the settle window |
| remove by proof, not by label | `lc_guard_mutate` reads the loaded job's `path =` and refuses unless it is this plist |
| an unreadable domain is UNKNOWN | `lc_probe` is the tri-state read, and every DECISION POINT that must distinguish 'not loaded' from 'could not read' re-probes with it: `lc_ensure`, the `--uninstall` read-back in `install.sh` (`block="$(lc_probe "$LABEL")"` — its verdict is the probe's own status, not a derived second read), `lc_guard_mutate`, `lc_assert_running`, `lc_assert_stable`, and `lc_bootout` (which refuses to treat a label as 'not loaded' rather than removing by a failed read). The thin wrappers `lc_pid` and `lc_runs` fold UNKNOWN into empty, so their callers must not read empty as 'not loaded'. Those decisions re-probe — **except `lc_restart`, and that is a hole this row names rather than hides**: a restart is unconditional, so it needs no probe to decide *whether* to act, but the folded `lc_pid` read it takes BEFORE the start is passed into `lc_assert_running` as `replaced`, so when that read is UNREADABLE (rather than 'not loaded') `replaced` is empty and the "the old process survived the start" check is silently SKIPPED. Not every read in the file is tri-state: `lc_min_runtime` falls back to launchd's own 10 s default, and a successful-but-empty `print-disabled` reads as `unset` (no override), because that is exactly what it means |

**Status: the DETECTION/reporting half is now CLOSED too (agent-infra#1986), inside the tracked
watchdog.** The paragraph that used to sit here said *"a watchdog that runs `enable` + `bootstrap`
when the label is absent, and reports it, is the missing piece — agent-infra#1860"*. The gap it named
was measured: on 2026-10-17 the label was disabled twice more *during that PR's own review* by agent
sessions running the pre-#1975 flow from other checkouts, and both times a human reading
`launchctl print` found it, not an instrument — `KeepAlive`/`RunAtLoad` relaunch a job that EXITS,
which is not the same state as one launchd no longer has. That arm now
lives in the ONE tracked watchdog, `scripts/orchestrator-harness/watchdog-loop.sh` (launchd job
`com.eldato.controller-watchdog`, `StartInterval` 300; the cell timer runs the same file):

| state, MEASURED with `launchctl print` in **both** `gui/` and `user/` | the ONE verb the loop issues |
|---|---|
| loaded (rc 0) | `launchctl kickstart -k gui/<uid>/<label>` — the wedge cure it always had |
| **REMOVED** (absent from every domain) | `launchctl enable` then `launchctl bootstrap gui/<uid> <plist>` — the state `KeepAlive` cannot reach, and the one a routine `-w`/`bootout` flow leaves behind |
| **UNREADABLE** (`Bad request.`, a silent non-zero read) | `kickstart` only — never a bootstrap, because that action must not re-load a job that may exist |
| REMOVED **with no plist on disk** | nothing; `verdict=RESTART-UNAVAILABLE` names the install that renders it |

⛔ IT IS NOT A SECOND AGENT, AND THAT IS THE WHOLE POINT. A second launchd watchdog was proposed and
reviewed (#1986) and the review rejected it on this repo's own recorded decision: `templates/launchd/RETIRED`
(#2303) retires the hand-provisioned `com.eldato.orchestrator-watchdog` **because two loaded watchdogs
are two MUTATING actors restarting one controller**, and `docs/ops/fleet-liveness.md` names
`watchdog-loop.sh` as its replacement. The capability was folded into that file instead: one actor, one
`controller-watchdog.streak` budget, no label for `install-launchd.sh`'s `retire_pass` to fight and no
second plist for `install.sh` to render. Proven by `watchdog-loop.test.sh` §8b (a stubbed `uname` +
`launchctl` argv log: REMOVED → `enable`+`bootstrap`, loaded → `kickstart -k`, unreadable →
`kickstart`, no-plist → `RESTART-UNAVAILABLE`), which reddens on the pre-fold script.

### 6.5.7 The cell's own roles run on a schedule, not when someone looks

**MUST.** A cell that can dispatch must also **land**, **repair** and **un-wedge** without a human,
and its `status` must be able to say **"this role has never run"** — because a cell that dispatched
its backlog and then did nothing prints exactly what a working cell prints (`controller: RUNNING`,
`lanes: 0`).

**Why (measured 2026-10-18, pi-cell-2/pi-cell-3).** A cloud cell ran exactly one loop
(`orch-loop.sh`). A green PR with a clean review record at its head sat **unlanded** until a human
ran the rail, and a wedged `lane-*` session held its slot until someone noticed — and the supervisor
could only answer *"is the tmux session up?"*. `status` reported `controller: RUNNING`, so the box
looked healthy while producing nothing. This is the §6.5 opening requirement's *"something must
NOTICE, DECIDE and ACT on a schedule that does not depend on the controller being healthy"* applied
to the cell, and the doctor is the something.

**Implementation: `cloud-cell-doctor.sh`**, launched as tmux session `cell-doctor` (the
`$DOCTOR_SESSION` default — a fixed name, not derived from `$SESSION`) by
`cloud-cell-supervisor.sh start` (removed by `stop`; `.desired` in `state/roles/` records the
intent so a `stop` is not undone by the next pass). **A `stop` always WINS over an in-flight
`start`**: `stop` bumps a generation counter (`state/roles/.stop-generation`) as its first action,
and `start` snapshots it on entry and tears down whatever it created if it moved — the doctor's own
`supervisor start` restart can take minutes, and process-group signalling cannot close that window
(its recorded pid is a `timeout` wrapper, so killing it orphans the real child). The doctor loop's
command string carries the operator's `DOCTOR_SESSION`, `SESSION`, `SCOPE`, `HARNESS_REF` and pin
paths for the same reason it re-sources `ENV_FILE`: a tmux session is served from the server's
environment, and a restart that re-derives the defaults would come back under a *second* doctor
session (two loops on one state dir) or under the wrong scope. Roles, each idempotent with its own lock and
its own `state/roles/<role>.state` last-pass record:

| Role | Interval | What it ACTUALLY does |
|---|---|---|
| `reap` | 120 s | one wedged-session pass over the HARNESS namespace only (`lane-*`, `chain-*`, `merge-*`, `fix-*`); see the decision below |
| `doctor` | 120 s | `reap` + controller supervision: restart `orch-loop.sh` when its session is **gone** and the cell is `.desired`; a **stale-but-present** controller is reported, never killed |
| `merge` | 300 s | land PRs that already have a **clean attestation at THIS head** by EXECUTING `scripts/admin-merge.sh` — the standard rail, never a re-implementation |
| `hygiene` | 3600 s | `uv cache prune` (not `cache clean`), worktree-root caches, and the **shipped** `pi-reap-worktrees.sh` (dry-run unless `HYGIENE_WORKTREES=apply`, or `auto` + the box is under disk pressure) |
| `loop` | 10 s tick | the timer; every role also runs once immediately on start |
| `status` | — | the liveness table; the stale bounds account for every role that runs BETWEEN two passes of the same role (the roles run in sequence in one loop), so a busy-but-healthy cell is not reported STALE; **exit 1** when a started cell has a role that never ran, went stale, or whose LAST pass failed (`rc≠0` — a failed controller restart, a cannot-verify read), or whose record carries **no readable `rc`** at all (`FAILED  the record holds no readable rc` — a truncated or hand-edited state file; an unreadable verdict is cannot-verify, never a clean pass). One clean pass clears it, so a transient failure reads as one failing pass, not as a dead cell. A loop younger than `DOCTOR_GRACE_S` (300 s) — or a role whose FIRST pass is still running (`state/roles/.<role>.running`, what `run_role_pass` writes, bounded by `ALL_PASSES_S` so a killed loop's leftover cannot hide a dead role for ever) — prints `WAITING` instead — its first doctor pass samples every lane, so `start && status` must not call a healthy cell dead; a cell with no loop-age record is judged immediately (fail-closed). ⛔ **`WAITING`/`RUNNING` are printed ONLY under a PROVEN-ALIVE loop** (#2306): the loop's liveness is `alive` / `dead:<reason>` / `unknown:<reason>` / `absent:<reason>` (`loop_state`, identity-verified — `pid-gone`, `identity-mismatch`, `pid-unparseable`, `no-identity-record`…), decided ONCE and used by every row. A dead loop makes every row read `DEAD  the loop is not running (<reason>)` and the verb exit non-zero; an unreadable record abstains as `UNKNOWN  the loop has no verifiable liveness (<reason>)` with **exit 3**, and is never reported as `DEAD` (an unreadable read is not a death witness) nor as `WAITING` (a promise). `WAITING` inside the grace also requires the loop's own transcript (`logs/doctor.log` / `logs/cell-doctor.log`) to have moved inside `ALL_PASSES_S`: a live pid is a process, not a scheduler. Before #2306 a SIGKILLed loop printed `NOT RUNNING` beside four `WAITING … 274s ago` rows — the scheduler was gone and nothing would ever complete |

**The reap decision is the safety core**, and it is the §6.5.1 rules applied to the fleet
namespace: a session is a candidate only if its log has not grown for `REAP_MIN_S` (**2700 s**, above
the controller's own `STALE_MIN=40` and the harness stall bound); the decision then takes **two
observations** `REAP_SAMPLE_S` apart; and the lane's **subtree must show no CPU delta**, because a
long model call is not a wedge. The whole read has an **overall** budget (`REAP_TIMEOUT`, 300 s) —
a per-call bound would let the total grow with the fleet — and each `tmux`/`ps`/`gh` call is
separately bounded (`READ_CALL_TIMEOUT` for tmux/ps, `MERGE_READ_TIMEOUT` for the queue listing;
without `timeout(1)` the bound is enforced by the shell itself, so its absence cannot silently
re-open an unbounded read, and a configured bound of `0` is REFUSED at startup because `timeout 0`
runs the command with *no* timeout at all — a bound that silently removes itself under the name of a
bound). A pass that spends the budget STOPS at the lane it reached and
records `rc=3 cannot-verify`; it never acts on a partial read and never reports the lanes it did not
reach as quiet (§6.5.2, and the 800-failed-passes measurement there). Three exclusions are hard: a session with an **attached client**, a
session whose ancestry reaches a **human terminal**, and a session with **no log** are reported and
skipped. A read that cannot be taken is `SKIP ... cannot-verify` — never a reap, and never a pass.

**A `stop` is honoured MID-PASS too.** `stop` TERMs the loop and KILLs it if it does not go, but the
loop's destructive steps (the merge rail, `uv cache prune`, the worktree sweep/reaper) run in the
FOREGROUND, and bash defers a TERM trap while it waits on a foreground child — so a TERM+KILL lands on
a loop that was mid-rail and orphans that child, which then finishes (a merge that lands, a reaper
that keeps deleting) after `stop` returned 0. Each pass therefore snapshots `.desired` and the stop
generation on entry and re-checks them immediately before every destructive call: once a stop has
arrived, nothing NEW is started. (A stop that lands *inside* an already-running rail still lets that
rail finish — killing a merge mid-flight is worse — and that residual is named here, not hidden.)

**An unreadable read is never an empty one.** A missing `tmux`, or a `tmux ls` that fails for any
reason other than "no server running", makes `reap` record `rc=3 cannot-verify` instead of a clean
pass over zero lanes; the same unreadable list makes `hygiene` SKIP the worktree-cache sweep (its
"no workers are live" guard fails closed). `hygiene` records `rc=3` when `uv cache prune` itself fails (or is
cut at `HYGIENE_TIMEOUT`), when it cannot run the cache sweep, and when it cannot find the
shipped worktree reaper at all — "could not find the tool" was the silent no-op this role exists to
remove. The loop's own liveness is identity-fenced (`state/roles/loop.ident` = `pid|<identity>`, `/proc` start time where the kernel offers one), so a
recycled pid cannot make a dead loop read as RUNNING.

**The merge role only offers a PR to the rail when the cell holds its OWN clean attestation for the
HEAD it is looking at** (`~/.pi/agent/reviews/<owner>-<repo>-<pr>.json` at `$CELL_HOME`, so a cell's
review state is not the Mac's). It does not review, classify checks or merge on its own evidence —
that is `merge-one.sh`'s job, and #1872 measured two classifiers disagreeing on 4 of 11 live PRs.
A refusal is recorded **verbatim** (with its reason), the pass still exits 0 (a refusal is data, not
a failed read), and the same head is not retried for `MERGE_RETRY_S` (**3600 s**) — a new push moves
the head and re-arms it. An unreadable open-PR listing is `rc=3`, never an empty queue. **It takes the same per-PR link the
controller's `merge-one.sh` takes** (`$O/state/mergeclaim-<pr>.lock`, noclobber + a live-owner test):
without it the doctor could rail a head that a `merge-one.sh` worker is already reviewing on the same
box — duplicate evidence, duplicate record-review writes, one worker's needsfix landing after the
other merged. **`fix-one.sh` takes the same lock** (agent-infra#2574): it is the one worker whose
product is a PUSH, so a lander that could not see it could re-resolve a head the fixer then moved
under it — the rail then refuses and the attestation the review chain had just minted is stale. A
fixer that finds a live holder defers refundably instead; one that finds a claim whose pid is
demonstrably gone TAKES IT OVER (measured, by rename-and-verify rather than `rm` + write, so a peer's
live lock cannot be deleted between two syscalls). A claim held by a live worker is a clean
skip that names the holder; a stale claim is
reclaimed; only the claim the pass took is released. **So is an
unreadable review STORE**: a permissions failure on `~/.pi/agent/reviews`, or an attestation file
that is present but unparseable, is `rc=3 cannot-verify` for that candidate — it used to render exactly
like "no attestation", so every candidate was skipped and the pass reported a clean *nothing to
land* while reviewed PRs silently never landed. A store that simply has no attestation for a PR is
still an ordinary, clean skip. The rail runs
FROM `$REPO` (a subshell `cd`, as `merge-one.sh` does), because its flake reproduction is
`git -C "$PWD" worktree add … <base>` and the loop's own cwd is the harness. The whole pass is
bounded by `MERGE_BUDGET_S` (**2400 s**), checked before each candidate: a spent budget ends the pass
`rc=3` and names the PRs it never tried.

**Status: IMPLEMENTED for a cell started by the current supervisor.** Three residuals, named:

- **It runs only where `start` launched it.** The supervisor starts the loop, so a cloud cell gets it;
  a Mac cell's `orch-loop.sh` launchd job does not, and nothing schedules the doctor there.
- **`cmd_check` now refuses a cell without it** (it is in the required-worker list in `cmd_check`), so a cell
  pinned to an older harness fails `check`/`start` loudly instead of silently running one loop — the
  correct direction, but it means the pin must be moved before those cells can start again.
- **Landing is not releasing.** The merge role gets a PR merged; it does not delete branches, reap a
  merged PR's worktree, or manage a test container — §6.5.4 stays GAP.

---

### 6.5.8 The box re-pins ITSELF once per cycle, and names a stale checkout on every spawn line

**MUST.** A cell must not run code simply because nobody pulled. Once per cycle `orch-loop.sh`
calls **`harness-refresh.sh`**, which fetches the ref, compares this box's **pin** with its tip by
**hash equality / `merge-base --is-ancestor`** (never a commit count), and either advances the pin or
**refuses loudly** and names which relation blocked it: `dirty`, `ahead`, `diverged`, `unknown`.

**Why (measured 2026-10-20).** Three cells sat on a checkout **27 commits behind `origin/main` with
an EMPTY `HARNESS-PIN`**, so fixes that had landed hours earlier were running nowhere. Nothing
fetched, nothing compared, and an empty pin was indistinguishable from a current one because no
reader ever refused it. Separately, a live-tested patch existed only as a working-tree edit and was
lost to the next pull — which is why `dirty` REFUSES rather than adopting over it.

**The relations, and what a caller may assume.** `current` (pin == tip) · `restart-pending` (pin ==
tip, the running controller still executes the previous commit — NOT a failure and NOT a reason to
re-deploy) · `behind` (+`repinned` when this box has a materialiser) · `dirty`/`ahead`/`diverged`/
`unknown` (all refusals; nothing is touched), and `blocked` (exit `26` — a destructive advance was
refused). Exit: `0` current, `10` the materialiser ran — its result is recorded as `action=repinned`
(the pin record or the deployed tree moved) or `action=reseeded` (`--re-seed` from a pin whose sha record **and** path
record already named the tip, so nothing moved), `11` pin mended
(empty/absent/not-a-commit pin repaired from what the box actually runs), `20` dirty, `21` ahead,
`22` diverged, `23` unknown/un-adoptable (also: a requested `--re-seed` this box cannot carry out — the record keeps the relation it computed), `25` behind with no materialiser, `26` blocked (the
destructive `--re-seed` was asked for while a controller or a lane is in flight — nothing is touched).
One machine line first —
`harness relation=… running=… ref=… pin=… action=… fetch=… lanes=…` — then prose; the controller parses
the record, never the wording. `lanes` is how many lane processes were IN FLIGHT at the verdict
(`unknown` when `$O`/`ps` cannot be read — never a silent `0`), so the deferral of a restart is
readable rather than assumed. `fetch` is the **freshness of the comparison itself** (`ok`, `stale` — the
fetch failed or timed out, `local` — the ref is not an `origin/*` ref, `notfetched` — `--no-fetch`), and
a `current` against a comparison that is not `ok` is **cannot-verify**: the controller turns it into the
token `stale:<sha12>` rather than going silent, and `status` says so beside the relation. A fetch that
cannot complete is not a comparison, and the box must not read as current because the network was down.

**It does not fast-forward the tree it is running from, and it is not a second seeder.** The advance
is delegated to the box's own materialiser (`cloud-cell-supervisor.sh apply --force --pin-only`),
which creates the per-commit pin worktree and leaves the tree being executed alone. `--pin-only`
skips `seed_and_stamp` **on purpose**: seeding `$O` under a live controller would swap the helpers
(`lane.sh`, `claims.sh`, …) a loop calls while the loop itself is still the old `orch-loop.sh` — a
version skew no other path produces. The next `start` re-seeds `$O` from the new pin, so the box
moves as one piece and the window in between is reported as `restart-pending`.

**The advance kills nothing, and that is why it is safe to run mid-turn (and every cycle).** Because
the pin is per-commit, a re-pin creates a NEW worktree and writes the pin: a lane that is mid-turn keeps
executing the tree and commit it started with, and only the *restart* is deferred. So the refresh
enumerates what is in flight (`lanes=N`) and never signals it, the already-current case stays a no-op
exit `0`, and the ONE advance that would change code under a live process — `--re-seed`, i.e. `apply`
without `--pin-only` — REFUSES with exit `26`, naming the controller/lane pids and the remedy, until an
operator passes `--force`. `--force` overrides nothing else: a dirty tree, an `ahead`/off-line tree and
a current pin keep their verdicts. Two consequences are stated rather than assumed: an explicit
`--re-seed` is **not** swallowed by the current-pin no-op, **nor by the mend arm** (a stale/absent pin
with the deployed tree at the tip), **nor answered as a plain `behind`** — every one of those falls
through to the same exit-`26` gate, or refuses (exit `23`) when the box has no materialiser, so the flag
is never silently dropped; when it runs, it re-seeds `$O` from the pin, which is exactly the
`restart-pending` box this script creates. A re-seed that moved nothing records `action=reseeded`, never
`repinned` — and "moved" means the **deployed** commit, so a pin whose sha record and path record
disagree (a real advance, `apply` rewrites the path record) is recorded as one and printed with `->`;
two identical shas never get an arrow or an `==` between different commits. The verdict is **one** prose
line, because `orch-loop.sh` keeps only the last non-record line: the in-flight disclosure is folded into
it so `$LOG` still carries old → new, the materialiser and `lanes`.

**A hand-launched cell resolves its materialiser from the CELL POSTURE.** The launcher exports
`HARNESS_MATERIALISER`; a controller started by hand does not inherit it — MEASURED 2026-10-21 on all
three cells, whose controllers carried `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE`/`CELL_HOME` and no
`HARNESS_MATERIALISER`, so **every cycle exited `25` `unmaterialised` and the pin could not advance at
all**, however often the refresh ran (the five-hour undeployed-fix shape: `ce987bb2` running while
`origin/main` was `15f9262a`). `HARNESS_PIN_FILE` + `CELL_HOME` IS the pin-per-commit posture — the
laptop path (`install.sh`) sets neither — so their presence licenses `$REPO/scripts/cloud-cell-supervisor.sh`
and the prose names it (`via … [auto:pin-per-commit-cell]`). The presence of a supervisor script alone
still licenses nothing: without the posture the verdict is `25`.

**A lane is never spawned from a behind checkout without that fact on the spawn line.**
`HARNESS_TOKEN` is empty only for `current`; otherwise it is `<relation>:<sha12>` and it is appended to
**every** dispatch row (`disp`) and to the `lane-`/`chain-` spawn line in `dispatch-merge.sh`
(`[harness=…]`). ⛔ ONE EXCEPTION, and the sha stays LAST so `${TOKEN##*:}` still reads it:
`restart-pending` carries WHY it is pending between the two — `<relation>:<pending>:<sha12>`, where
`<pending>` is `deferred` / `safe` / `inert` / `unprovable` (agent-infra#2641). A bare
`restart-pending` was the always-on alarm that change removed, so the token now says which pending
state the box is in instead of repeating one word for ever. Consumers that only DISPLAY the token are
unaffected; a consumer that PARSES it must read the sha from the LAST field, not the second.
An absent token reads `unknown`, never `current`. Refusals go to `$LOG` **and** to
stderr, once per cycle — a warning that prints on every tool call is how #1140's noise hid a signal.
`HARNESS_REFRESH=off` disables the re-pin and says, once per cycle, that a stale checkout will now go
unnamed (a pinned-build escape hatch, not a way to avoid a red line).

**Status: IMPLEMENTED.** Residual, named: a re-pin changes what the box will run, not what it is
running — `$O` and the controller both move at the next `start` (which re-seeds `$O` from the pin),
and until then every spawn line says `restart-pending`. The controller does not restart *itself*
onto the new pin, deliberately: a self-restart mid-cycle is a liveness risk this PR does not take.
⛔ **The DETECTION half named above is not in this PR** — the agent that repairs a removed or disabled
job (`enable` + `bootstrap`, and `kickstart` for a loaded-but-dead one) is PR **#1986**, which owns it
along with its plist, its disarm sentinel and its suite. It is referenced here and not restated:
one description of one agent, and a second copy is how a fleet ends up with two sentinels.


### 6.5.9 The reminder's actuator arm: a GO is a claim about evidence

**The reminder.** One timer, every 600 s, answering **the owner's two goals first**, then three
questions: what is closest to landing, what merged but is **not live** on a box, and what is red for
the SAME reason across many PRs. It writes `$O/MERGE-REMINDER.md` and prints ONE line. Until #2603 that line read
`#2579 (?) reds=0 [GREEN(wait:21)] :: …` — `(?)` for priority, and `GREEN` for a surface with
twenty-one checks still in flight. Both read better than reality, so both are gone: every value is
MEASURED, and an unread value says `UNREADABLE <reason>`.

**The goals, and why they come FIRST.** The owner's ask (2026-10-24T04:10Z) was *"improve the reminder
message so it reminds you of the goals properly"*, naming two: **(1) tortoise P0+P1 are DONE and
MERGED** — a fix without a merged PR is not done — and **(2) the agent-infra harness runs
AUTONOMOUSLY** — the full lifecycle on the local box AND all three cmux cells, the SAME harness
version in main/local/every cell **deployed AND activated**, on both repos, with the PR queue not
behind. So `## GOALS` states them, `## Where the goals stand this run` MEASURES them, and
`## What to do (in GOAL order)` turns the readings into the next action.

⛔ **The ORDER is the change, not the wording.** `main()` measures drift → the goals → the PR reads,
in that order. The failure it fixes is measured: the PR reads ran first on 2026-10-24, spent the whole
core budget (`8/8` at 04:22Z), and every goal line said *not measured* — a reminder that reported on
PRs and forgot what the PRs are for. Drift is a LOCAL artifact read (no REST) and the goals spend the
SEARCH quota, so this order cannot starve the landing arm.

⛔ **A count that does not come back is `NOT-MEASURED`, never `0`** — zero is the claim that the goal
is met.

⛔ **GOAL 2 HAS TWO MAINS AND TWO HALVES, AND BOTH WERE MEASURED WRONG ON THE LIVE FLEET (#2679, #2680).**

- **The harness main.** A box's harness sha is an *agent-infra* commit, so "the same version
  everywhere" can only be judged against **the harness repo's** `origin/main` — not the `origin/main`
  of the repo this cycle SWEEPS (the value the PR and claim gates correctly use, because those refs
  live there). The harness repo is resolved in four steps, because the FIRST TWO are absent in the
  configuration this file installs: `HARNESS_REPO`, then the checkout containing `$O`, then **the
  checkout containing this script** (in a repo checkout that is the repo root; a FLAT deploy —
  `deploy-harness.sh`/an operator's `cp`, not `install.sh`, puts `merge-reminder.py` straight into `$O`
  — makes `parents[2]` the payload's grandparent, which is NOT the payload, so a flat deploy depends on
  `HARNESS_REPO`/`$O`), then
  `$HOME/orchestrator`. Every candidate must CARRY the
  harness — `scripts/orchestrator-harness/box-status.sh` **tracked as a regular file by that candidate's
  own repo**, as an index ENTRY rather than a path (`git ls-files -s`: mode `100644`/`100755` **and** the
  recorded path equal to `scripts/orchestrator-harness/box-status.sh`, so a prefix match is not the file) —
  so a checkout that is merely *some* repo, one that only *reaches* the harness through the gitignored
  `scripts -> $AGENT_INFRA_PATH/scripts` pointer (#9475, the canonical tortoise/eldato shape), one that
  tracks a SYMLINK (mode `120000`) or a GITLINK (`160000`) at the marker path, and one whose marker path is
  a DIRECTORY (the index records a nested file) are all skipped rather than taken for the harness repo. Measured (PR #2683 round 1): the
  timer exports only `O`/`HOME`/`PATH`, `--o` defaults to `$HOME/orchestrator`, and on the hub that path
  is not a checkout — so a two-candidate resolution returned None, the caller fell back to the swept
  repo's main, and the header printed `**harness main:** 5f40d832c254`, a tortoise sha, under a
  `harness main` label. That is why an UNRESOLVED harness repo is `""` and prints `UNRESOLVED` — never
  the swept repo's main, which is a value no harness comparison may use. Measured 2026-10-24 with the sweep repo on a tortoise checkout (`REPO=/tmp/cell-t3`, the
  fleet's shape for two of its cells): goal 2 read `local=f9381dae2ee5 [unknown] — a different commit
  from this cycle's main (0/1 …)` and ordered a deploy against `main=5f40d832c254`, a **tortoise** sha
  — an instruction to deploy the harness at a commit that does not exist in agent-infra. The harness
  repo is resolved from `HARNESS_REPO` / the payload's own checkout (`$O`), the read is REUSED when it
  is the same repo as the sweep (so the one-read rule is untouched), and the resolved repo is exported
  as `REPO=` **into each status command** — a status command otherwise inherits the swept repo and
  compares against the wrong main by itself, which is what produced the `[unknown]`. `--json` publishes
  both as `main` and `harness_main`; the header names the harness main whenever they differ.
- **Activated.** The pin names what the **next** launch runs (`harness-refresh.sh` says so in its own
  verdict: an advance is `restart-pending` until the controller restarts). So `controller: RUNNING` read
  off the pin is **not** activation: measured on the hub, the pin and payload named `f9381dae2ee5`
  while the live controller still exec'd `harness/f6a1a01772bd/orch-loop.sh`, and the goal certified
  `1/1 box(es) … deployed AND activated`. `box-status.sh` now also answers `running: <sha12>` — the
  commit the controller's **own argv** resolves to — and the marker requires it to EQUAL the box's
  harness sha. A mismatch is `restart-pending(running=<sha>)`, which counts for nothing; a status
  command that does not answer at all is `running=NOT-REPORTED` (silence is not activation); a
  controller mid-restart on two trees is `running=MIXED`; no controller is `running=NONE`. The deploy
  table calls the same state `deployed-but-NOT-activated` and does **not** restart it (the pin already
  names the target; a restart there would kill whatever the live controller is mid-flight on to gain a
  deploy the next launch gets anyway). ⛔ THE VERIFY LOOP USES THE SAME PREDICATE. Its `VERIFIED` used
  to check main + relation + controller + a NEW pid and never the executed tree, so a controller that
  survived a failed `stop` (old tree) plus a started replacement (new pid) satisfied every term while
  `box-status.sh` reported `running: MIXED` — a false `VERIFIED` written into the deploy LEDGER and later
  quoted back as *"our activation at this pin VERIFIED"*, the sentence that stops the arm repairing a box
  it itself broke. `activation_gap()` is now a conjunct there too, and an `UNVERIFIED` names the gap.

⛔ The cycle's `origin/main` is read ONCE, with a REAL backoff retry (`MAIN_READ_ATTEMPTS` / `MAIN_READ_BACKOFF_S` — two calls issued back to back fail together, and a later read gave the header a sha the goals had never compared against), and every consumer uses that one value. ⛔ THE BOX INVENTORY HAS FOUR STATES and each is reported as itself: `absent` (a probed LOCAL-ONLY row, announced in the goal-2 READINGS by a `⚠️` line and a `⛔ LOCAL ONLY` line — never in the action, and never in a report whose inventory file exists), `unread` (the file exists and could not be read — including a non-UTF-8 file), `empty` (it exists and lists NO boxes) and `noprobe` (no file and no `box-status.sh`, so nothing could be probed). None of the last three is a box: no fraction, no marker word, no deploy instruction, and the standing is `NOT-MEASURED`. The local-only fallback otherwise printed a fleet marker over a one-box read. And the label filter must run SERVER-SIDE: `gh issue list --label P0 --json number` returns
ONE PAGE, so a local `len()` counts the page and not the population. Measured on tortoise: a slice
said `P0=4 · P1=5` while the label query answered **7 and 20** (>300 open issues). `_count` therefore
asks `search/issues` for `total_count`, with the filter already applied by the server.

**The arm.** The owner's ask (2026-10-23) was that the reminder lead to automated dispatch of the
needed action, on the stated risk: *"we can merge and if it breaks then it's fast to repair, as long
as it's not a catastrophic break."* So a GO dispatches the repo's own rail
(`scripts/admin-merge.sh <PR> --repo …`, backgrounded, its own log) when — and only when — ALL of
these were read at the moment of action:

| gate | reading | what a failure means |
|---|---|---|
| open, not draft, MERGEABLE | `pr=OPEN draft=no mergeable=MERGEABLE` | re-read from the SINGLE-PR endpoint, because the LIST endpoint answers `mergeable: null` for every PR (that inert gate is what made the arm never fire); `mergeable: null`/`NOT-READ` is a WAIT — `REFUSE(mergeable=unknown)` |
| a record at the LIVE head | `attested@head=yes` | a record bound to an older head is `REFUSE(attested=stale)`; six PRs were caught in exactly that state |
| quiet surface | `reds=0 in-flight=0` | `reds=0` with 21 in flight is a **WAIT** (`REFUSE(in-flight=21)` — #2522/#2592). The combined commit-status `state` is cross-checked against the entries READ — but `pending` with **zero** statuses is GitHub's EMPTY state for a check-run-only head, not truncation, and treating it as truncation made every real head UNREADABLE. The combined token is read with an ALLOW-LIST (`success` / `pending` / `failure`): `error` is a red-class value and an unnamed future token is never green, because a value this reader cannot classify must abstain rather than pass |
| no live claim | `claim=none` | `refs/claims/pr-<N>`, `refs/claims/<N>-<head12>`; an unreadable claim store is an ABSTENTION |
| a surface that was actually READ | `reds=0 in-flight=0` | a surface of ZERO groups is `REFUSE(surface=empty)`: a head pushed moments ago has no check runs and no commit statuses, and a review record can precede CI — **absence of evidence is not evidence of green** |
| no rail running | `rail=idle` | the local landing lock with a LIVE pid, or ANY live `admin-merge.sh` / `merge-one.sh` naming the PR — re-read AT THE MOMENT OF ACTION, not only from the pre-REST snapshot. ⛔ Our OWN process is never that rail: `--rail <path>/admin-merge.sh` puts the rail's name in this timer's own argv, so a process whose pid is this process (or its parent) is skipped, as is any row running `merge-reminder.py` — counting them made the arm refuse itself every cycle, blaming a rail that did not exist |

⛔ **The rail is the authority and this file never merges.** `admin-merge.sh` re-reads the surface
with its own allow-list polarity, binds its evidence to one SHA, refuses a moved head and classifies
main's reds by event. The reminder's check read is a COST gate — "is it worth spending a rail
attempt?" — and, **unlike the cell doctor's `merge` role, it reads the check surface itself**. That
divergence is deliberate and worth stating plainly rather than dressing as precedent: the doctor
refuses to classify checks at all ("a second opinion here is the two-readers defect", #1872/#1714),
whereas the reminder does, because an unread surface costs a rail attempt every cycle. It is
acceptable only because the reminder can do nothing but REFUSE — the rail re-reads everything and a
wrong refusal dispatches nothing — and it is a **drift risk**: this classifier has to track
`admin-merge.sh`'s grouping/polarity rule, and nothing pins the two together. It is a cost gate the
doctor deliberately omits, not an endorsement of the doctor's division of labour.

⛔ **A stale record is not a record, and a threshold is not a gate.** `merge-one.sh` and the doctor
take the local landing lock (`$O/state/mergeclaim-<PR>.lock`) before racing a head; the reminder
takes the SAME lock with `O_EXCL` immediately before the spawn, so the first lander on this box wins
and the loser refuses `rail=running`. The reap of a dead lock runs **under its own mutex**
(`<lock>.reap`) — `unlink` + `O_EXCL`-create is not atomic against a second reaper, and two reapers
can otherwise both return "taken" and run two rails for one PR. It then WAITS (bounded, default
900 s) for the rail's own exit
so the cycle reports the rail's rc rather than assuming its spawn was a success; **past the bound it
LEAVES the lock in place** (the fence survives the rail, which the process scan alone would not
cover), and a later cycle reaps a DEAD-pid lock **only when no landing attempt is live** — the dead
pid proves nobody holds the lock, not that no rail is in flight. A live pid is never reaped or taken
over. The same re-verification applies to claims: an **expired lease is free**, exactly as
`claims.sh`'s `_lease_is_live` defines it, because a box that died mid-review would otherwise block
the PR forever; an unparseable lease stays LIVE (fail-closed), matching `_lease_unparseable` — **including the
`0` sentinel**, which `test-claims.sh` pins as "UNPARSEABLE => LIVE". The claim message is read from a
PRIVATE ref, never `FETCH_HEAD` (one per `.git`, rewritten by any concurrent fetch), and its shape is
`claims.sh`'s (`claim owner=… lease_until=<epoch> nonce=…`).
Stated residual: two REMINDERS on two boxes with no claim held can both dispatch; the rail's
`--match-head-commit` keeps that from landing an unanalysed head, and closing it properly means
minting the cross-box claim — which is `merge-one.sh`'s job, not this timer's.

**The deploy half.** A merged fix that never reached a box has fixed nothing, so drift is
ACTIONABLE: after the landing decision (never instead of it), a drifted box is restarted with ITS OWN
verb — on a cell, `cloud-cell-supervisor.sh stop → apply → start` — and only when no role pass is
mid-flight (a restart inside a reap kills work no later pass re-runs). It is VERIFIED BY ARTIFACT,
never by the command's exit code: `harness: <sha> [current]` **and** `controller: RUNNING` **with a
pid that is NEW relative to the pre-activation read**, re-probed until `--verify-deploy-s` expires,
else `deploy=<box>:UNVERIFIED` with the readings. The new pid is load-bearing: `stop → apply → start`
is one shell chain whose exit code is never read, so a controller that survived a failed stop would
otherwise satisfy "RUNNING" while executing the old tree — and a `source=stamp` identity is rewritten
by `apply` BEFORE `start`. When the BEFORE read carries no pid at all (a box one deploy behind with an
older status command), a restart cannot be proven and the deploy is `UNVERIFIED` — never a fallback
to "any pid", which would accept exactly the pre-existing controller the rule excludes. ⛔ A box
whose pin agrees but whose controller is not RUNNING is `deployed-but-NOT-activated`, never
`current`: the arm does not start it, and it reads the LEDGER's last verdict — `our activation
at this pin VERIFIED and the controller has been stopped since (an operator's stop)` when that
row says VERIFIED, `OUR last activation of this box did not verify (N unverified attempt(s);
last verdict: …)` otherwise, and `no activation of this box is recorded at this pin` when the
ledger is empty. The drifted `controller=STOPPED` branch makes the same three-way reading. ⛔ The
deploy BOUND is the CURRENT streak — unverified attempts since the box last provably reached
this pin — so an arrival clears it; a lifetime total refused every later, legitimate attempt
while quoting a count the ledger's own last row denied. A status command that never answered the controller question is
`UNPROVEN controller=UNREADABLE`, never `deployed-but-NOT-activated`. Calling that row `current` made the table contradict the goals
block one section above it, which reads the same box as `MARKERS-BROKEN — controller=STOPPED`. The boxes are an
inventory (`$O/state/boxes.tsv`: `name<TAB>status-cmd<TAB>activate-cmd`), so a cell is driven through
whatever remote path that box already uses — no new control surface is invented here.

It is also **bounded**: every activation is recorded (`state/merge-reminder.deploys`,
TAB-separated — a box name may contain a space, and a whitespace split would key on the first word and
never bind), a repeat of
the same **box + target sha** inside `--retry-s` is a `WAIT(deploy-retry-after=…)`, and once
three unverified attempts are ON RECORD the NEXT cycle refuses by count (`REFUSE(deploy-attempts=3
…)`) naming a human — three restarts happen; the fourth cycle is the one that stops. ⛔ The bound keys
on the TARGET, not on the `from`→`to` pair: `from` is a value the activation itself changes, so a box
that creeps forward without arriving (`diverged` → `behind`, a partial `apply`) missed its own row and
was restarted every 600 s forever. Without the bound at all a box that cannot reach `origin/main` —
pinned `ahead`, `diverged`, or an `apply` that never
advances the pin — would be stopped and started every cycle forever, because every gate that could
stop it re-opens 600 s later. If the ledger cannot be WRITTEN the verdict says so
(`⚠️ the deploy ledger could NOT be written — the attempt bound is inert until $O/state is writable`): an unrecorded attempt is
still an attempt, so the bound must not report itself satisfied while bounding nothing.

It refuses five things, each one a way an actuator becomes an incident (the code's own docstring
counts the same five):

* **an UNREADABLE `origin/main`** — with an empty main every box reads as drifted, and the verify
  loop compares against the same empty value and could never pass: a restart every cycle, forever;
* **`--no-act`** — the reminder-only mode covers BOTH arms, because a controller restart is more
  disruptive than the landing that mode already suppresses, and `--no-act` is how a human INSPECTS
  the file before trusting it;
* **a landing attempt live ANYWHERE on this box** — not only one this cycle dispatched. `--interval`
  (600 s) is shorter than `--rail-wait-s` (900 s), so overlapping cycles are reachable by
  construction and the second would restart the controller under the first one's rail. The deploy
  arm also takes its own `state/merge-reminder-deploy.lock`, so two cycles never deploy at once;
* **a STOPPED controller** — but this arm cannot tell an operator's stop from its OWN failed
  activation (a `stop → apply → start` whose `apply` failed leaves the cell down), so it reports
  `activate=skipped(controller=STOPPED …)` and, when the deploy ledger shows our own unverified
  attempt, says so instead of blaming the operator;
* **a `source=stamp` identity reported as `current`** — `harness-refresh.sh` states the stamp records
  what was SEEDED, not what is RUNNING, so a matching stamp reads `UNPROVEN` and activates nothing.

**Costs, and how a skipped run is never an empty one.** `GET /rate_limit` FIRST (it is unmetered),
then at most `REST_BUDGET = 9` metered core calls: one open-PR listing, then per candidate three
surface reads (workflow runs, `check-runs?filter=all`, legacy statuses) plus one **single-PR read for
mergeability** — the LIST endpoint never computes it (every one of agent-infra's ten open PRs answered
`null` in a 2026-10-24 reading), and reading that `null` as `REFUSE(mergeable=unknown)` made the whole
arm INERT. A single-PR read that the budget cannot afford says `NOT-READ`, never an inherited value. The
listing itself is one page of 100 and a FULL page is UNREADABLE by name, because it carries no
`total_count` to prove it was not truncated (70 open PRs against a 30-row page hid 40 of them).
The goal readings spend the SEARCH quota instead (`GOAL_SEARCH_BUDGET = 8`, counted in
`budget.search_calls`) — a different limit on GitHub, so measuring the goals never spends a call the
landing arm needed, and `REST_BUDGET` stays what this document says it is. Under
`REST_RESERVE = 200` core calls the run is SKIPPED and SAYS SO (`skipped=rate-limited core=12/5000`,
exit 3) — never `nothing to do`. The same exit and the same wording cover an unreadable PR listing.

**Timers.** `merge-reminder.py --install-timer [--interval S]` renders and LOADS the platform's own
schedule and verifies it: launchd (`com.tortoise.merge-reminder`, `StartInterval`) on macOS, a
systemd USER timer (`merge-reminder.timer`) on Linux, else a crontab entry — and a box with NONE of
them exits 3 naming the remedy rather than installing nothing quietly. Every arm is verified by the
ARTIFACT that schedules it (`launchctl print`, `systemctl is-active`, `crontab -l`) — a successful
write is not a timer. `--uninstall-timer` removes **every** arm install can create (the unit, and
the crontab entry on a box with no systemd) and verifies the removal. Our crontab entry is identified by the tag AND our command AND the
`$O` it serves, compared both literally and as RESOLVED paths (so `--o /o`, `--o /link/to/o`, `--o .`
and an `$O` containing a quote are each one arm, not several) — not by the script path alone — `$O/<script>` and the checkout copy are the same script to
`install.sh`, and keying on the path made a cross-copy uninstall match nothing ("nothing to remove",
exit 0, arm still firing) while keying on the script NAME made one `$O`'s uninstall delete a peer's
arm and an operator line that merely mentioned the script. An entry written before the token existed
is still matched by its script path, and that legacy fallback is the only place the path is a key. An unreadable crontab is an
abstention (exit 3) that rewrites nothing, rather than an empty crontab it would overwrite.

**Status: IMPLEMENTED and TESTED.** `merge-reminder.test.sh` is a shard in both lanes (§1–§28,
337 assertions) and drives ALL THREE timer arms end-to-end with stubbed schedulers — systemd (the
unit is rendered and its `ExecStart` is asserted to start with the interpreter exactly once, which is
how the duplicated-`argv[0]` defect was caught), crontab (quoted, `%`-escaped, verified by `crontab
-l`, and removable without deleting an operator line that merely mentions the tag), and launchd (the
plist is rendered, `bootout` is asserted to precede `bootstrap`, and uninstall removes it) — plus
`box-status.sh` including a RIGHT-PADDED `ps` line (whose parse once reported a live controller as
`STOPPED`), every landing and deploy gate, the deploy attempt bound, and two mutation controls that
require the mutant to have RUN. Residual, named: the arm is ON by default (`--no-act` / `MERGE_REMINDER_ACT=0` for
reminder-only), so a box that runs the timer WILL dispatch a rail on complete evidence — that is the
feature, and the gate list above is what makes it safe; the review-record store it reads is this
box's `~/.pi/agent/reviews`, so a peer box's verdict reaches it only through `registry-sync.sh`.

---

## 7. Gaps: what is fixed, what is not

Details and evidence for the remaining items: tortoise#8246. Same failure class in the fleet rail:
agent-infra#1678, #1680, #1683.

### 7.1 Dispatch bookkeeping never expires — **FIXED in this PR**

`orch-loop.sh` prunes `candidates.txt` against `dispatched.txt`, so an issue number is recorded as
"handled" the first time it is handed to a lane, and nothing re-checked whether that dispatch
**delivered**. A lane that dies (reboot, OOM, crash) stranded its issue permanently — invisible to
both the loop and to issue-triage, because the issue stays open with no PR.

Observed: **#4114, #4095, #3554** were dispatched 2026-10-10, their lanes died in a shutdown, and
each sat with a dirty worktree, no PR, and no re-attempt for >24 h.

**Fix:** the background refresh now runs a reaper — for each `dispatched.txt` entry, if the issue is
still open **and** no PR branch matches the number **and** no `lane-<N>` session is live, the entry
is removed from `dispatched.txt` **and** `checked.txt` so the pre-flight re-queues it. Four of the
self-test's checks pin exactly this decision table (`4114` reaped, `8888` kept for its PR, `9999`
kept because it is closed, `7777` kept for its live lane).

⛔ **A failed listing is not an empty one.** The reaper refuses the part that depends on a listing
unless that listing is **present**; the capture deletes a list when `gh` fails, so "the read failed"
(absent) is distinguishable from "the answer is none" (present but empty). ⛔ **AND THE GUARD IS SPLIT
BY WHAT EACH PART READS** (agent-infra#2183): an absent `.open_iss` disables only the `dispatched.txt`
reap (which needs the open/closed fact), while the `checked.txt` classification still runs, because it
reads `candidates.txt`, `dispatched.txt`, `.pr_brs`, the live lanes and the claim registry — none of
which is `.open_iss`. Joining the guards (refusing both on either listing) left a suppression that no
pass could release for as long as one unrelated listing was unreadable, and it was invisible to every
assertion except the one on the artifact (`selftest.sh` pins that split with a checked number that has
no local keep-fact). Before the
guard, a failed `gh pr list` left an empty `.pr_brs`, `has_pr` was false for every issue, and
`dispatched.txt` was cleared — so `orch-loop.sh` re-spawned a lane for an issue that already had a
PR (duplicate work against the shared queue, agent-infra#1705). The self-test's failure-path checks
pin both halves (absent → nothing reaped and `checked.txt` untouched; empty-but-readable → still
reaps), and the capture site is driven directly with a stub `gh`.

### 7.2 Draft PRs are invisible to the sweep — **FIXED in this PR**

The selector was `select(.isDraft|not)` and nothing readied our own lanes' drafts, so a draft ran
its checks, failed `ai-review-gate`, and no worker ever touched it. Observed: **#8219**
(`feat/3524-tm`) and **#8085** (`feat/1037-tm`) sat with failed gates and an already-recorded
`ISSUES` verdict, stranded purely by the flag.

**Fix:** the sweep now includes drafts that match the harness's **own** branch patterns
(`*-tm`, `*-cap`, `fix/*`) and readies them once (`gh pr ready`) before the next cycle processes
them. Foreign drafts are excluded exactly as before — #4212 (`scope/w6b-graph-candidate`) is
another box's draft and is correctly left alone. (Note the two exclusions are independent: a PR on
`design/`, `scope/` or `dependabot/` is never swept even when it is not a draft — see §5.)

### 7.2c Conflicted PRs — **FIXED in this PR**

A CONFLICTING PR can never merge, but the sweep classified it GREEN/PENDING and called `gh pr merge`
on it every cycle, so the queue looked busy while nothing moved (observed: #8245, #8226, #8193, #8104). They are now routed to `fix-one.sh`, which integrates `origin/main`, resolves the conflict, and re-runs the review chain — capped by `MAX_FIX_TRIES` and parkable like any other fix loop. The
fixer prompt states that when a PR is CONFLICTING the conflict *is* the task.

### 7.2b Cross-box duplicate work — **FIXED in this PR**

The per-PR claim (§5.1b) is a **local file**, so it makes concurrency safe *within one box*. Two
boxes sweeping the same repo still both evaluate the same PR and the same issue, and the boxes
share GitHub, not a coordinator. The registry is now `refs/claims/<PR>-<head-sha12>` in the
repository the boxes already share (`<head-sha12>` because the key is `claim_key()`, which truncates
the head sha to its first 12 characters): `git push` to a ref is an **atomic create-or-fail** (a
CAS), so it needs no broker and no service, and the namespace is **outside `refs/heads/*`**, so it
triggers no workflow and never appears as a branch. **Verified empirically** on both
`daniel-ospina/agent-infra` and `daniel-ospina/tortoise`: pushing a probe ref to `refs/claims/*`
created **zero** workflow runs and **zero** check-runs, matching the static picture (every
`on: push` in both repos is filtered to `branches: [main]` or `tags`). `claims.sh` holds the
primitive; `merge-one.sh` resolves HEAD **before** claiming and exits 0 when another box owns that
head; `fix-one.sh` takes the **same** claim on the current head for the fixer's duration and
releases it before re-entering `merge-one.sh` (otherwise the reviewer-only claim left two boxes free
to spawn a fixer for the same PR); `orch-loop.sh` refreshes **every** claim in **one** fetch per
cycle into `state/claims-snapshot`, so `claim_live()` costs no per-PR network call. The lease is
**data, not liveness** (a remote pid cannot be probed), derived as `REVIEW_TIMEOUT + 1200` for the
reviewer and `FIX_TIMEOUT + 1200` for the fixer, and carried in the claim commit.

#### Selection consults the registry, and an unreadable registry is not freedom (agent-infra#2466)

The registry alone does not make two cells safe: what a cell *selects* has to consult it. Before #2466 the sweep read the snapshot with a bare `awk` and answered "not owned" whenever the file was
**absent**, so every way a registry READ can fail reported as "nobody holds it" — no registry
provisioned, a snapshot written from a failed fetch (the fetch's `|| true` leaves the previous cache in
place, so the file is a stale read presented as current), or a snapshot older than the cycle reading it.
Those are exactly the states in which two cells disagree. Measured 2026-10-23 with the registry's own
writer (`CLAIM_OWNER_HOST=cell-2`, `refs/claims/9777-abc123def456`, live 1800 s lease): a fresh snapshot
read OWNED; an **absent** snapshot and an **empty** one both read UNOWNED.

One reader now answers — `claims.sh`'s `claim_snapshot_verdict`, which calls `_lease_is_live` and
`claim_orphan_reason` (no second verdict path). It publishes five words:

| verdict | rc | meaning for SELECTION |
|---|---|---|
| `claim-absent` | 0 | the registry was READ, is FRESH, and holds nothing for this key → free |
| `claim-expired` | 0 | an entry whose lease window has passed → free |
| `claim-orphaned` | 0 | a live window whose holder cannot be a live lane (agent-infra#2094) → free |
| `claim-held` | 1 | a live, non-orphaned window → **skip** (owner + `until` in the log line) |
| `claim-unreadable` | 2 | the registry could not answer → **nothing is spawned, armed or merged** |

Freshness is part of the verdict, not a separate guard: `claim_snapshot` writes a
`#claim-snapshot\t<read_at>\t<ok|failed>\t<refs>` header, and a snapshot older than
`CLAIM_SNAPSHOT_MAX_AGE` (900 s, ≈3.75 cycles at the shipped `CYC=240`) or written from a failed
fetch reads `claim-unreadable`. A snapshot whose WRITE failed is never published at all: the
previous one is left in place **with its own header**, so it keeps answering only while that header
says `ok` and it is inside `CLAIM_SNAPSHOT_MAX_AGE` — and it is `claim-unreadable` otherwise, or
when there is no previous snapshot at all. A failed publish is therefore not automatically a
stand-down, and it is reported separately (`CLAIM_SNAPSHOT_WRITE`) from a failed fetch. Publishing a 0-byte
snapshot instead would read as "nothing is claimed", which is why that is refused.

**Two signals, merged, never intersected.** Selection keeps the LOCAL evidence it always had — a live
process whose cwd is the head's checkout, a live merge lock — and adds the registry. Either one can
BLOCK; neither can cancel the other. Conflict resolution is therefore a **union**: a local live holder
with no claim blocks (that is the #4256 class — work the registry cannot see, e.g. a branch never
pushed), and a foreign live claim blocks even where no local process exists (the cross-box case).
The one asymmetry is deliberate and pre-existing: a claim held by THIS box does not by itself count as
ownership for selection — a live process must prove it (`claim-own` is free for selection, HELD for the
spawn guard). And `SCOPE` is untouched: it decides which names a box looks at, not who owns them.

**A claim can also be DEAD while its term is not (#2094).** Renaming a machine used to orphan every
lease it held: `claim_owner()` stamped `$(hostname -s):$$`, liveness was "`lease_until` is in the
future", and `claim_prune` reaped by expiry alone — so the old host name never matched again and a
future-stamped lease was immune for its whole term (measured: 14 leases, **14 held by dead pids, 0
alive**; the dispatcher printed `held by …` for each and then `backlog empty queue=READ(192)`).
`claims.sh` now answers a second question — `claim_orphan_reason(owner[, ref])` — and `claim_acquire`,
`claim_issue_preflight`, `claim_prune` and `orch-loop.sh`'s `claim_live()` all consult it:

| rule | when it fires | why it cannot steal a live peer |
|---|---|---|
| **own former names** | the owner host is a name THIS box has carried (`state/claim-hosts`) | the list only ever holds names this box answered to (written from the real `hostname -s`, never from a seam), and it requires the `hostname` probe to answer — a blind probe abstains. Nothing ships a roster, so this is what makes a rename self-heal. ⚠️ **Read the residual in the next paragraph: this rule runs for EVERY keying, so it can free an in-flight ISSUE claim.** |
| **local pid** | the owner host IS this host, **one of its former names**, or **the machine's own probed `hostname -s`** (which stays local even when a `CLAIM_OWNER_HOST` seam is set — otherwise a seam-presenting box cannot judge a claim it stamped with its real name) — and `ps -p <pid>` says the pid is gone | **PR claims ONLY.** A PR claim is minted by the worker (`merge-one`/`fix-one`), so its pid IS the worker. An ISSUE claim is minted by the CONTROLLER and released by the CHAIN, so a controller restart (every deploy) would have this delete a live lane’s barrier and re-open the duplicate — the rule is keyed, not global. A LIVE local pid therefore OUTRANKS the host name — that ordering is the P0 fixed in `720e780d`, where the former-name rule reaped a renamed box’s own live merge/fix claim. It also needs a control probe (`ps -p $$`) to prove `ps` can answer at all; an instrument failure abstains, never steals. ⛔ AND IT REQUIRES `hostname -s` TO BE **UNIQUE ACROSS THE FLEET**: the premise above is that the owner's host naming this box proves the pid is local, and nothing asserts that premise. Two boxes sharing a short name (cells provisioned from one image) each mint `<sameName>:<pid>`, and each then probes the OTHER's live worker pid locally, reads an absence and returns ORPHANED — `claim_prune` deletes it and the pre-flight reports CLEAN, the steal direction this column says cannot happen. The `state/claim-hosts` remedy below does NOT cover it (no history line is involved, and the shared name is the box's CURRENT name), so set a unique hostname before a cloned cell image mints its first claim |
| **`CLAIM_DEAD_HOSTS`** | the owner host is listed | an explicit deny list — a mis-entry over-reaps only the host it names |
| **`CLAIM_KNOWN_HOSTS`** | the roster is SET, **names this box**, and does not list the owner host | a roster that does not name this box is stale (its usual cause is the very rename) and **abstains**; an unset roster never means "every peer is dead" |

⛔ **THE SELF-HEAL ASSUMES A FREED NAME IS NEVER REASSIGNED.** `state/claim-hosts` is a list of names
THIS MACHINE owns, so a name handed to another box afterwards makes every claim that box mints read as
this box's own dead claim — for every keying — and the local-pid rule then probes the foreign pid HERE,
reads a local absence, and calls a LIVE remote worker's PR claim orphaned: the steal direction, from a
name that is no longer ours. The self-limiting claim holds only while the name is exclusive to this
box. Remedy: once no outstanding claim can still carry the name (after `CLAIM_TTL_MAX` / `CLAIM_ISSUE_TTL`),
delete the line from `state/claim-hosts` before the name is reused elsewhere.

⚠️ **The roster is an allow list, so an INCOMPLETE one over-reaps**: a roster that names this box and merely omits a live peer declares that peer dead and re-dispatches its unexpired work across two boxes — the failure this registry exists to prevent, reached from the opposite direction. It must be COMPLETE and authoritative, which is why the deny list (`CLAIM_DEAD_HOSTS`) is the safer knob for a one-off dead host and is checked first.

⚠️ **`CLAIM_OWNER_HOST` (the test/simulation seam) is honest about its cost, once per process.** It
stamps claims with a name the **HOST** rules cannot judge, so an ISSUE claim minted here cannot be
reclaimed by this box (a PR claim still can, via its pid — the local-pid rule judges the seam name fine,
because it probes the process rather than trusting the name) — and it
**suppresses `state/claim-hosts` recording**, which silently disables the rename self-heal. It is still
supported (the harnesses and cross-box simulations need it), but it warns on stderr when it differs
from the running host. Nothing in a deployed cell sets it.

⚠️ **The self-heal covers renames AFTER this ships, not the leases a rename already stranded.** A
name can only be recognised as *former* if the box recorded it while that name was still current, and
the recorder did not exist before this change — so the leases the incident measured (including the
literal `9768s left` line above) need a ONE-TIME cleanup, after which the mechanism holds. Stated
because "self-healing" reads as "retroactive".

⚠️ **Use the pid-preserving remedy, not `CLAIM_DEAD_HOSTS`.** Append the old name to
`state/claim-hosts` (“this box wore it”) — the former-name rule then probes the pid, so a
`<oldName>:<live pid>` PR claim reads held-by-live and a dead one is reclaimed. `CLAIM_DEAD_HOSTS=<old-name>`
instead declares the name dead *outright*, and the deny list is checked on the host rules only — it
never consults a pid. What it reaps is therefore: an **ISSUE** claim from that name (whose chain may
be running — see the residual above), and a **PR** claim whose host was never recorded in
`state/claim-hosts`. On a PR claim minted by this box the pid rule answers FIRST — the name is in the
history, so the pid is probed and a live worker returns `held-by-live` (rc=1) before the deny list is
reached (measured at head). So the deny list is safe for PR claims this box minted, and is NOT safe
for the ISSUE claims of a lane that is still in flight: apply it only when no lane is mid-merge.

⛔ **THE PID REMEDY IS THE SAFER ONE FOR *PR* KEYS ONLY — IT DOES NOT PRESERVE AN ISSUE CLAIM EITHER**
(cycle-11 review: an earlier version of this paragraph offered it as the way to *avoid* the hazard just
described, which sent the operator straight into it). For an **ISSUE** key the local-pid arm is
skipped entirely — an issue claim is minted by the controller, not by the lane — so the former-name
**host rule** is reached and fires, and a live lane's barrier is freed exactly as the deny list frees
it (pinned by O10(e), which measures an ISSUE claim stamped `<former name>:<live pid>` → ORPHANED and
the same owner on a PR ref → held-by-live, in one pair; O10(b) pins the end-to-end reclaim). The difference is
strictly that a **PR** claim stamped `<oldName>:<live pid>` returns `held-by-live` under the pid remedy
and is reaped under the deny list. **Neither remedy preserves an in-flight ISSUE claim**, so the only
mitigation for those is the condition both share: do not rename — or run the one-time cleanup — while
lanes are in flight; otherwise let the next prune free their issue claims and let them finish.

⚠️ **THE HOST RULES RUN FOR EVERY KEYING, AND THAT HAS A CONSEQUENCE WORTH STATING PLAINLY.** They
answer "is the holder a live LANE?", and a name that no box answers to is dead *as an identity* — but
the holder and the work are different processes for an ISSUE claim (the controller mints it, the lane's
chain works and releases it). So after a rename, the first hourly `claim_prune` on the renamed box
**frees its own in-flight ISSUE claims while their chains keep running**, and a peer may then dispatch
the same issue. That is accepted rather than fixed: a barrier held by a name nobody answers to is
indistinguishable from an abandoned one for every peer, so the alternative is a claim nothing can ever
reclaim (the incident). The guarantee is therefore **"the claim is safe until the next prune"**, not
"until the lease expires" — and `dispatched.txt` protects only the box that wrote it. If you rename a
box with lanes in flight, expect the next prune to free their issue claims and let them finish; the PR
keying (where the minting pid IS the worker) is unaffected.

An orphaned holder is reclaimable **regardless of `lease_until`**, the pre-flight reports it CLEAN
(the CAS still has to be won), and `claim_prune` reaps it. An **unparseable** lease keeps its
existing polarity — LIVE — and is never re-examined for orphanhood: those rules are a reason to stop
trusting a *term*, not evidence about a *holder*. Every `held by …` hold reason and every pre-flight
COLLISION carries a machine-readable token, `held-by-live` or `held-by-orphan` (the lost-CAS refusal
`lost the reclaim race for <ref>` carries neither — it reports a race, not a hold), and
`refresh-candidates.sh` reports how many candidates a live
claim withheld and how many were queued *although a claim existed* (its only claim is orphaned), so a
claim-driven empty backlog can no longer read as "no work".

**The lease has a CEILING as well as a default.** `CLAIM_TTL` (1800s) and `CLAIM_ISSUE_TTL`
(14400s — raised from 10800s by #2029, whose merge phase lengthened the wait the lease must outlive)
are *defaults* for their keying; `CLAIM_TTL_MAX` (7200s) and `CLAIM_ISSUE_TTL` bound what a
caller may stamp. Above the ceiling a ttl is **clamped to the ceiling** (never to the shorter
default — that would expire merge-one's deliberate 3000s mid-merge) and the clamp **says so on
stderr**, because `CLAIM_LEASE = REVIEW_TIMEOUT + 1200` and `FIX_LEASE = FIX_TIMEOUT + 1200`: raising
either timeout past `CLAIM_TTL_MAX - 1200` requires raising `CLAIM_TTL_MAX` in the same change, or
the claim expires before the review it was taken for. The verification is `claim-orphan.test.sh`,
which reads the stamped term back out of the **pushed claim commit**. Both tunables are
validated with `is_limit` (digits **and** at most nine of them) **before** that arithmetic, and
`claims.sh` clamps the ttl again at its own arithmetic site — because an overflowed lease is the
worst kind of failure: it goes **negative**, `_lease_of`'s `[0-9]*` cannot parse the minus sign, an
unparseable lease is read as **LIVE**, and `claim_prune` can never reap it, so that PR/head is frozen
across every box with no automatic recovery. Every
release/reclaim is `--force-with-lease`, so a box holding a **stale** commit (one that is no longer
the ref's tip) cannot release the winner's claim. Three hardening points from the adversarial
review of this PR: a **read-back failure on the create path still surfaces the commit we pushed**,
so the caller can fenced-release a claim that did exist instead of orphaning it for the whole lease;
a **failed reclaim push is classified by re-reading the ref** — unchanged or unreadable is an
infrastructure failure (rc=2, fail-open), a moved ref is a genuine lost race (rc=1) — rather than
reporting every transient error as a lost race and failing closed; and worker lease-read temp refs
live under `refs/claims-tmp/*`, **not** the pruned `refs/claims-cache/*` namespace, so
`claim_snapshot --prune` can no longer delete a concurrent read mid-flight. It **fails open on
purpose** — if the claim store is unreachable the harness proceeds and logs it — because
agent-infra#1709's headline finding is that duplicate execution is unavoidable and the side effects
must be idempotent per head, so failing closed would stall the whole fleet on one transient error.
`SCOPE=own` (§5, item 3) remains a useful partition but is no longer the only cross-box barrier —
§7.2d *Does a claim EXCLUDE?* measures what the barrier actually covers, per operation, and that
measurement is what retired the pin's *safety* role for **dispatch and review** — while keeping the
exclusion requirement on the **landing** row, which it does not measure (§0.5, #1908).

#### `claim-reaper.sh` — a claim is released only when its holder is demonstrably GONE

A claim can outlive the lane that took it, and the fleet then originates nothing: measured
2026-10-21, `refs/claims` held **7 claim refs, the oldest 25 hours old, on a box with 0 live lane
processes**, and every candidate the refresh reached answered *"a peer owns it, retried next pass"*
(#9077, #9097, #9202 in consecutive passes). `claim_prune` reaps by expiry and by orphaned host, but
it deletes with no dry run, no per-claim evidence, no age threshold, no per-pass bound and no
record — and its orphan rules are deliberately narrow (the local-pid rule is PR-only; the host rules
only fire for a name this box no longer answers to), so a claim stamped by THIS box on an ISSUE, whose
controller and chain are both gone, stays `held-by-live` until its lease runs out.

`claim-reaper.sh` supplies that half. It is **report-only by default** and releases only with
`--release`:

```bash
claim-reaper.sh                       # per claim: holder, age, the evidence for/against liveness, verdict
claim-reaper.sh --release --max 3     # release the RELEASABLE ones (bounded, recorded)
claim-reaper.sh --records             # what this box has reclaimed, and why
```

Every claim passes the same ladder, each rung FAIL-CLOSED: **identity** (the claim names a
`<box>:<pid>`) → **lease** (it parses: an unparseable lease is LIVE and is never re-examined for
orphanhood, per `_claim_acquire_at`) → **age** (the claim's own commit time is older than `--min-age`,
default 10800s = `CLAIM_ISSUE_TTL`) → **host** (the holder is this box, one of its former names, or a
host declared on `CLAIM_DEAD_HOSTS` **with an expired lease**) → **pid** (`ps` first proves it can see
*this* process, then reports the holder absent) → **work** (ISSUE claims only: no live process
references the issue and none sits in a checkout carrying it — because an issue claim is minted by the
controller and released by the chain, so a vanished pid is NOT a vanished lane) → `--release` → bound.
Verdicts: `RELEASABLE`, `HOLDER-ALIVE`, `WORK-LIVE`, `HOLDER-BOX-UNREACHABLE`, `PROBE-BLIND`,
`WORK-UNMEASURED`, `UNIDENTIFIABLE`, `UNREADABLE-LEASE`, `TOO-YOUNG`, `UNMEASURABLE`.
⚠️ **Stated residual:** the control probe that proves an instrument works is the PER-PID one
(`ps -p $$`, gate 5). It does not prove the whole process table or cwd census is complete — under a
hardened `/proc` a partial table can be returned with a live chain's row missing, exactly the residual
`live-ownership.sh` already declares ("a floor on visible work, never a claim of completeness"). The
absence evidence is a floor; the age threshold and the lease state are what bound the damage.

A release is `--force-with-lease` on the observed sha, and its record is written **before** the claim
is deleted — an `intent` record first (that write is what proves the record can be written at all),
then the fenced delete, then the record finalized as `released` (or `refused` when the fence moved).
`state/claim-reaper.log` carries one TSV row per release; `state/reclaimed/<ref>` is the readable
record, for a lane that comes back to a claim it still thinks it holds. With no writable record
directory the pass **refuses and deletes nothing** — an unrecorded release can be neither audited nor
protested. It is deliberately NOT
scheduled by the loop: releasing is the operator's word, and the dry run is safe to run at any time.
⛔ Its observation seams (`CR_PS`, `CR_PROC_TABLE`, `CR_LIVE_ROWS`) SUBSTITUTE the evidence that
authorises a release, so they are refused unless the caller declares `CR_TEST_SEAMS=1` (a test run) —
an ambient value must never be able to free a live lane's claim.
⚠️ Two things it will NOT fix for you, by recorded decision: an unparseable lease (reported as
`UNREADABLE-LEASE`, `claims.sh`'s rule) and a holder on a box this process cannot query (reported as
`HOLDER-BOX-UNREACHABLE`) — a claim whose 25-hour age comes from either is an operator decision, not
a reaper's.

#### The landing key `refs/claims/pr-<N>` — the per-head key cannot answer "is one box landing this PR?" (agent-infra#1952)

The registry above is **content-addressed on the head sha**, so `refs/claims/<PR>-<head-sha12>` says
*"another box is working THIS HEAD"*. That is the right question for a **review** — a pushed update is
legitimately new work, and a duplicate review costs one duplicate comment. It is the wrong question
for **landing a merge**, which is the one operation #1908's per-operation table records as *not*
tolerating at-least-once: `gh pr merge` is **not pinned to a sha**, so the second lander merges
whatever head is current at the moment it runs, against a signed marker bound to the head *it*
reviewed. Two boxes that see one PR at two different heads mint **two distinct keys** and each wins
its own CAS; that was measured — do not take it from this paragraph (row **M3** of
`claim-exclusion.test.sh`, recorded in the per-operation table).

So landing takes a **second, coarser ref, `refs/claims/pr-<N>`**, *in addition to* the head key — the
head key is **not** re-keyed, because that would reverse rec 1 (`claims.sh`'s "KEY =
<PR>-<head-sha12>, NOT <PR>") and make a pushed update wait behind a stale claim for its predecessor
head. `merge-one.sh` takes `pr-<N>` **first** and `<N>-<sha12>` **second**, at every ingress (the
lane's `chain-<N>`, a `fix-<PR>`, and the sweep), so the two refs have one total order and cannot be
taken in opposite orders by two boxes. The landing claim is taken **before the paid reviewer runs**,
so the losing box pays nothing, and it is released by the `EXIT` trap after the merge — both releases
bounded (~20 s each), head first and the PR-wide ref second, so the coarser ref — the one every box
must see free — is the last to be dropped. A refusal (`rc=1`) exits **before** the review; an
**unreachable** registry (`rc=2`) fails **open** and logs it, the same policy the head claim uses
(§7.2b above), and a box whose `$O/claims.sh` predates `claim_pr_acquire` is a **named** log state,
not a silent degradation.

⛔ **What is measured, and what is not.** `test-gates.sh` §"THE LANDING CLAIM" pins the mechanism
hermetically against a throwaway bare origin: the second box is **refused the same PR** (L1), the
three keys stay independent and the head key stays per-head (L2), a non-holder's fenced release is
refused (L3), a release genuinely frees the PR (L4), the row is non-vacuous — a forced create push
makes both boxes win, so L1 can go red (L5) — and `merge-one.sh` acquires before the reviewer,
widens its trap **before** the acquire, and releases on every exit (L6–L8); L9 pins that a failed
head acquire cannot carry the landing commit into the head release. `claim-exclusion.test.sh` **M6**
is the concurrency measurement of the same key, and its row is recorded in §7.2d. What is **not**
measured is the merge itself: `gh pr merge` on a moved
head needs GitHub, so the residual — a head that moves inside the marker-check→merge window — is
closed only to the extent that a second **lander** is excluded; a push that races an in-flight merge
from elsewhere is still possible and is why the marker is re-read at the live head.

### 7.2d ISSUE dispatch was the uncovered window — **FIXED in agent-infra#1850**

`refs/claims/<PR>-<head-sha12>` is **content-addressed on a head sha**, so it cannot express an
issue at all: `claim_ref <pr> <sha>` has no sha to address, `claim_live()` returns 1 on an empty
one, and the whole registry was therefore **bypassed for issue dispatch**. That is the longest
exposure the fleet has, because it is the *whole working period of a lane before its first push*:
the pre-flight's own surfaces are immutable history (open/closed PRs, `gh` assignee) plus
**per-machine** git state (`git worktree list`, local branches), and `refresh-candidates.sh` selects
issues where `(.assignees|length)==0` while **nothing assigns on dispatch** — so every box reads
every issue as free. Measured 2026-10-16: two cells were pointed at `daniel-ospina/tortoise`, whose
pool held six P0 blockers with no PR for any of them.

The extension is a **key, not a mechanism**: `refs/claims/issue-<N>` uses the same CAS (a ref push),
the same lease-as-data commit, the same `--force-with-lease` fencing and the same `claim_prune`
reap. The decisions that are not obvious:

- **The key is `issue-<N>`, and the box id stays in the commit's `owner=` field.** `issue-<N>-<box>`
  was rejected deliberately: a per-box key is not a CAS — two boxes mint two distinct refs and both
  pushes succeed, so the ref can only be *read*, never *won*, and the pre-flight read alone cannot
  close the gap (it runs **before** the claim, so both boxes can read CLEAN and then both claim).
  `issue-<N>` is also idempotent for the same work, and its `issue-` prefix is disjoint from the PR
  key `<N>-<sha12>`, so a PR claim for the same number neither blocks nor is blocked.
- **The ref's home is the TARGET repo's origin** (`CLAIM_REPO`, i.e. the repo whose issue number is
  claimed) — never the harness repo. Every would-be dispatcher of that issue already resolves
  `$REPO`/`--repo` to it, so it is the one namespace all of them read; a claim pushed into
  agent-infra would be invisible to a peer dispatching tortoise, which is exactly the collision that
  was measured.
- **Claimed by `orch-loop.sh` when it forms its dispatch batch**, not by `dispatch-merge.sh`: a
  refused issue is then not written to `dispatched.txt` and not put in `.batch`, so it stays in
  `candidates.txt` and is re-attempted next cycle — no blacklist for the reaper to undo, and no
  worktree, lane or chain spawned for work another box owns. **Re-leased by `chain-merge.sh` on
  every exit path** (clean merge, failed merge, the 90-minute "no PR appeared" timeout, and — see
  §7.2d — a capacity refusal, where it exits at once rather than waiting) through
  a trap, fenced on the commit this box pushed; a box that dies mid-lane leaves it to the lease,
  which is sized (`CLAIM_ISSUE_TTL`, default 4 h since #2029) to cover lane + chain — releasing early is the
  normal path, so the lease only runs its full length when the box is gone.
- **The pre-flight now CONSULTS it, and fails CLOSED.** `refresh-candidates.sh` calls
  `claim_issue_preflight` after a clean tool verdict and branches on its **exit code**, never on
  output text: **0 CLEAN** (no claim, the only claim expired, **or the only claim is ORPHANED** —
  #2094: its holder cannot be a live lane, so the pre-flight reports what the acquire will do and the
  acquire still has to win the CAS) queues the issue; **1 COLLISION**
  (a live claim, or a lease that cannot be parsed — a lease nobody can read is treated as live) is
  left unchecked, so the window is re-attempted when it closes; **2 INCOMPLETE** (the registry could
  not be READ — `git ls-remote` failed, or the local clock is unreadable) is never queued and counts
  toward the run's aggregate `INCOMPLETE=n` line, and a pass that produced **no usable verdict at
  all** exits transient (rc=1) — so an unreadable registry that queues nothing is a red run, not a
  quiet one; **3 NOT PROVISIONABLE** (the registry is present but
  predates the issue key — an `$O/claims.sh` with no `claim_issue_*` functions, i.e. the drift
  `install.sh` reports) refuses the issue the same way, and rc=3 also earns a **`.refresh-blocked`**
  marker (the provisioning channel: `orch-loop.sh` stops retrying and `status` names the reason), so a
  persistent condition is visible rather than a silent no-queue. rc=2 does **not** write that marker —
  it is transient by construction, so the pass exits 1 and the cycle is logged `FAILED rc=1` and
  retried; the marker would make a network blip look like a broken cell. This
  is the opposite polarity from the PR claim's ACQUISITION fail-open, and it was applied to **every**
  exit, not just the obvious one: an unrecognised status is treated as INCOMPLETE, so no future code
  path can widen the CLEAN arm by accident.
  ⛔ **A MISSING registry file REFUSES TOO (agent-infra#2466, reversing the earlier "loud fallthrough").**
  The old rule let an unprovisioned box keep dispatching unclaimed, on the argument that refusing would
  make it merge-only. Two things invalidated that: the PR path now also abstains on an unreadable
  registry (so such a box is not "merge-only", it is SILENT), and the fallthrough was never loud where
  it mattered — `issue_claim_verdict` already answered INCOMPLETE for a missing file and the call site
  simply did not ask it. Missing, unreadable and stale are therefore ONE polarity: refuse, publish
  `claim-unreadable`, and name the one-line remedy (`deploy-harness.sh`); `refresh-candidates.sh
  --check` refuses the same state up front, because a check that blesses what the run refuses is a
  false PASS. (The file reaches `$O` by `cp -p "$H"/*.sh "$O"/` in `scripts/deploy-crossbox.sh` —
  `install.sh` itself only diffs and reports drift; it does not copy.)

Two incidental defects are fixed with it: `claim_release` read its third/fourth arguments **bare**
under `set -u`, so a caller with no commit to fence on aborted with
`line 260: $4: unbound variable` instead of taking the documented refusal — a release that **errors**
leaves the claim held for the whole lease (3 h of a free issue, for the issue key).

The registry now carries **three** keys, one question each, and none is a re-keying of another:
`<PR>-<sha12>` ("this head", review/evidence), `issue-<N>` ("this issue", dispatch), and
`pr-<N>` ("this PR", **landing** — §7.2b). They cannot collide: the `issue-` and `pr-` prefixes
put them in their own families, and `<N>-<sha12>` always carries a dash, so a PR number alone never
addresses a head.

`test-claims.sh` (I1–I10) pins the issue key against live origin from two scratch repositories (each
`git init` + `remote add origin <bare repo>` — **not** clones), including the **non-vacuity case for
this defect**: A claims an issue with **no branch, no PR and no push of anything but the claim ref**,
and B's pre-flight read must not be CLEAN — a test that only passes after a push does not test it.
Its keys are random per run (`PR`/`ISSUE` overridable), because two concurrent runs of the suite used
to collide on one fixed pair of refs in the **production** `refs/claims` namespace and delete each
other's refs mid-CAS — a green suite then reported 15–19 false failures, and the fleet runs several
reviewers of one PR at once. Measured (reproduce with the base commit of this PR as `<rev>`):

```bash
T=$(mktemp -d); cp scripts/orchestrator-harness/*.sh "$T/"
git show <rev>:scripts/orchestrator-harness/claims.sh > "$T/claims.sh"
CLAIMS_SH="$T/claims.sh" bash scripts/orchestrator-harness/test-claims.sh   # 65 passed, 45 failed
```

`claim-cwd.test.sh` pins the claim builder's **cwd independence** — the property a redeploy silently
took away on 2026-10-18, when the launchd cell (whose WorkingDirectory is **not** a repository)
refused every candidate in the queue while the controller looked alive:

```
[dispatch] #4513 NOT dispatched — could not build claim commit
```

The builder returned an EMPTY hash, so nothing entered the batch — a total dispatch stall that emits
no error of its own. Two independent hunks, each with its OWN discriminator:

- **`_git` must `cd` into `CLAIM_REPO` in a subshell, not hand git `-C`.** The `-C` form still STARTS
  in the caller's cwd and has to resolve it, which is exactly what the affected cells deny
  (`fatal: Unable to read current working directory: Operation not permitted`). The check runs the
  SHIPPED builder with its cwd set to a directory that cannot be resolved at all, and asserts a claim
  commit is produced and the ref lands on the target origin. **This is the hunk that unblocked
  dispatch.**
- **`CLAIM_REPO` must derive from `REPO`, not `.`** — hardening, not the incident's cause: the
  controller assigns `CLAIM_REPO="$REPO"` itself (`orch-loop.sh`), and every other shipped caller
  sets it explicitly. An ABSOLUTE `$REPO` is used as named (it needs no resolution, so no cwd can
  make it wrong); a RELATIVE one is used only when the cwd is not already a work-tree root, and
  otherwise `.` wins — see the six `cd` hazards below, which is why the simple form is not enough.

⛔ **`cd` IS NOT A FREE SWAP FOR `-C` — six defects found in the first three versions of this fix**,
each measured and each now pinned by the suite. `-C` treats its argument literally; `cd` is a builtin
with its own resolution rules:

- **an EMPTY `CLAIM_REPO`** — `cd ""` SUCCEEDS and leaves the cwd alone, so `|| return 1` never fired
  and a full acquire pushed `refs/claims/…` into the **caller's** repo, a repository nobody named.
  Closed in both orderings: the value that reaches `_git`, and an empty value that is already SET
  when the file is sourced (kept refused instead of being coerced into a default);
- **`$CDPATH`** — the builtin searches it for a relative path, and a same-named directory there WINS
  over the local one (measured), so a relative `CLAIM_REPO` ran every git call — and pushed the claim
  — in a repo the caller never named. `-C` never did that;
- **a RELATIVE `$REPO` from a caller already inside it** — `fix-one.sh` and `merge-one.sh` `cd "$REPO"`
  and then source this file with no `CLAIM_REPO`, so `$REPO` resolved from inside `$REPO` names
  `$REPO/$REPO`, which does not exist: every claim refused with the SAME `could not build claim
  commit` the fix exists to remove;
- **a same-named SUBDIRECTORY that is itself a repo** — the same caller shape, where `$REPO/$REPO`
  does exist. A default keyed on `[ -d "$REPO" ]` then ran every git call in the INNER repo and
  acquired with `RESULT=acquired` on an origin nobody named — a wrong-repo claim, silently, which is
  the duplicate dispatch this registry exists to prevent. Hence the cwd-work-tree-root test;
- **a BARE `cd` OPTION** — `CLAIM_REPO=-P` is not a path: `cd -P` takes NO operand and SUCCEEDS into
  `$HOME` (measured), so without the `--` a bare-option value claims into whatever repo `$HOME`
  happens to be. `-C` read it as a directory name and failed;
- **an ABSOLUTE `$REPO` while standing in ANOTHER repo's root** — the cwd-root test alone answers `.`
  there, so a caller naming repo B absolutely got `RESULT=acquired` with the ref on repo A's origin,
  silently: the same wrong-repo class one shape over. An absolute path needs no resolution, so it is
  used as named and the heuristic is left to the relative case.

Measured, which is what the suite is for (four baselines, `/tmp` copies via the `CLAIMS_SH` seam):

```bash
CLAIMS_SH=<pre-fix main>            bash …/claim-cwd.test.sh   # 19 passed, 17 FAILED (C1, C2, C5, C10)
CLAIMS_SH=<the two hunks alone>     bash …/claim-cwd.test.sh   # 20 passed, 16 FAILED (C5–C9)
CLAIMS_SH=<round-1 fixes, no cwd test / no SET test>          # 31 passed, 5 FAILED (C5 pre-set, C8)
CLAIMS_SH=<round-2 fixes, no absolute-REPO branch>            # 33 passed, 3 FAILED (C10)
CLAIMS_SH=<shipped, with `cd --` removed>                     # 33 passed, 3 FAILED (C9)
```

Each guard is pinned by exactly ONE check, so a later "simplification" of any single one of them
reddens the suite on its own:

```bash
CLAIMS_SH=<shipped, `cd --` removed>      bash …/claim-cwd.test.sh  # C9 reds alone — fail-open into $HOME
CLAIMS_SH=<shipped, absolute branch gone> bash …/claim-cwd.test.sh  # C10 reds alone — claims on the cwd repo
```

⛔ **The stand-in, stated**: the OS denial (TCC/EPERM on the process cwd) cannot be constructed
hermetically, so the first check puts a `git` shim first on PATH whose only job is that read
(`/bin/pwd -P` on the cwd it was STARTED in) before exec'ing the real git. The DENIAL is modelled;
`claims.sh`, the commit, the acquisition and the assertion are real. Non-vacuity is measured against
the pre-fix file, and the RED run fails with the incident's own log line:

```bash
CLAIMS_SH=<pre-fix main> bash scripts/orchestrator-harness/claim-cwd.test.sh  # 19 passed, 17 failed
bash scripts/orchestrator-harness/claim-cwd.test.sh                           # 36 passed, 0 failed
```

To reproduce `<pre-fix main>`: `git show <main>:scripts/orchestrator-harness/claims.sh > $TMP/claims.sh`.

`refresh-scout.test.sh` drives the **shipped** refresh step and the **shipped** dispatch block against
a real local origin for the collision, unreachable, absent, stale-registry and unrecognised-status
verdicts, plus the fenced release on the chain's exit path and the generation guard. Measured (the
counts cover the whole #1850 change — the feature and this fix round — not the fix alone):

```bash
cp scripts/orchestrator-harness/*.sh "$T/"
for f in claims refresh-candidates orch-loop chain-merge dispatch-merge; do
  git show <rev>:scripts/orchestrator-harness/$f.sh > "$T/$f.sh"; done
( cd "$T" && bash ./refresh-scout.test.sh )                                  # PASS=72 FAIL=67
```

Three further defects in the same family are fixed and pinned with it, all fail-**open** directions:

- **The pre-flight's clock is guarded.** `date +%s` is a *second* input to the same decision, and if
it cannot be read the old comparison `[ "$now" -le "$until" ]` was neither true nor an error the
code handled — bash prints `integer expression expected` and the test is FALSE, so the reader fell
through to CLEAN. An unreadable clock is now rc=2 INCOMPLETE, alongside an unreadable registry.
- **The release record is generation-guarded.** A chain captures the commit it pushed when it becomes
the holder; the record file is keyed on the **issue**, so if the same box re-acquires after its lease
lapses, a newer generation overwrites it. A release that read the file when its trap fired would
fence on the new commit — which **is** the ref tip — delete the live holder's claim and free a busy
issue for a peer. The captured generation is compared and a mismatch **refuses** the release (naming
it), leaving the newer record for its own release. ⚠️ The guard is deliberately **inert on the
no-chain path** in `dispatch-merge.sh`: that release runs seconds after the record was written, so
the record *is* that dispatch's generation — there is no older holder to refuse, and the fence is the
record's value. It earns its keep in `chain-merge.sh`, whose trap can fire hours later, after the same
box has re-acquired and overwritten the record.
- **The lease polarity has ONE implementation** (`_lease_unparseable` / `_lease_is_live`) shared by
`claim_acquire`, `claim_issue_preflight` and `claim_prune` — three copies of the same comparison, and
"a lease that cannot be read is live" is exactly the predicate they must not answer differently.
(`orch-loop.sh`'s `claim_live` keeps a fourth deliberately: it reads the local SNAPSHOT rather than a
ref and `selftest.sh` extracts it standalone, so it cannot share an in-process helper.)

### 7.2d Does a claim EXCLUDE? — **MEASURED, per operation** (agent-infra#1908)

agent-infra#1908 held the retirement of the `SCOPE=own` partition **conditional**: retire it only
once a claim is *demonstrated* to exclude a concurrent holder, and only for the operations that
tolerate at-least-once. A registry that exists is not that demonstration — #1850 landed the **code**,
and a claim had never been observed refusing anything under real contention. `claim-exclusion.test.sh`
is the measurement, and this section is its recorded output. **This table is copied from that suite**;
if a row changes polarity the suite goes red and names the row, so it cannot go stale silently.

```bash
./claim-exclusion.test.sh                 # hermetic: a throwaway bare origin, the CI form
./claim-exclusion.test.sh --origin live   # THIS checkout's origin, in a $$-scoped namespace
```

**What it actually does, and its limit.** It releases **N independent processes** (default 6) at a
barrier against a **real `git receive-pack`**, each presenting as a different box through
`CLAIM_OWNER_HOST`, so the CAS is genuinely raced rather than replayed sequentially. (It was
`CLAIM_OWNER_ID`; #2094 renamed the seam to the HOST so the owner's `<pid>` stays the racing
process's own, and `claim_owner` now REJECTS a `CLAIM_OWNER_ID` whose host is not the running host —
a claim stamped under a host that no longer exists is unreclaimable for its whole lease.) Each racer waits
`n × 3 ms` after the barrier: released in the same microsecond, every push contends for the same
`<ref>.lock` and the losers are refused by **git's ref lock** before they ever reach the CAS —
measured by forcing the create push and still getting exactly one winner, which would have let a
defeated CAS report EXCLUDES. Two boxes are never that synchronised, so the stagger measures the case
the CAS has to handle. **Non-vacuity, measured:** with the stagger in place, pointing `CLAIMS_SH` at
a copy of `claims.sh` whose create push is forced (`push -q --force`) reddens **M2** with
`2 winners in one lap`, while the shipped `claims.sh` passes the whole suite (20/20) — so the suite
discriminates a
defeated CAS from an exclusive one. The same mutation applied to the **landing** key —
`claim_pr_acquire` replaced by a fail-open `return 0` — reddens **M6** three ways (six winners in a
lap, the second holder at another head *acquiring*, and the refusal naming no holder), so the per-PR
row cannot pass on a registry that excludes nothing. **Limit, stated:** the default origin is a bare
repo in the sandbox, so this measures ref-update atomicity, not the network. `--origin live` closes
that gap on demand (it leaves no claim ref and no probe branch behind — the trap deletes both).

| operation | claim key | duplicate behaviour MEASURED | tolerates at-least-once? |
|---|---|---|---|
| **dispatch** (start a fixer/reviewer) | `refs/claims/issue-<N>` | 3/3 laps × 6 racers: **exactly one** winner per lap; every loser gets rc=1 and is told *who* holds it (`held by box2:1529071 until …`) | **yes** — side effects are idempotent |
| **review / record evidence** | `refs/claims/<PR>-<sha12>` | 3/3 laps × 6 racers: **exactly one** winner; loser refused | **yes** — the cost of a duplicate is a duplicate comment |
| **landing: the same head** (per-head key) | `refs/claims/<PR>-<sha12>` | the same CAS as review; the second worker exits **before** it reviews or merges (`merge-one.sh`, `CROSS_RC=1`) | **only for that head** |
| **landing: the PR moved to a new head** (per-head key) | `<PR>-<sha12>` — **a different key** | **both acquire.** Measured (M3): an issue/PR claim is content-addressed on the HEAD, so two heads of ONE PR are two distinct CASes and the per-head claim cannot express *"this PR"* | **NO** — which is why landing ALSO takes the key below |
| **landing: one PR at ANY head** (the **LANDING key**, agent-infra#1952) | `refs/claims/pr-<N>` (`claim_pr_acquire`) | **M6: exactly one winner per PR** (3/3 laps × 6 racers), and a sequential second holder at a **different head** of the same PR is **refused** (rc=1, names the holder) — the exact case M3 measures as *allowed* on the per-head key | **NO** — so it must EXCLUDE, and per PR it now does |
| **fencing** (release / stale write) | the ref's **value** | a loser's release is refused (rc=1, ref unchanged); a **fast-forwardable** push leased on a stale base is refused — by the lease, not by non-fast-forward | n/a — a fence, not a claim |

**So, per operation:**

- **Dispatch and review are retired from the `SCOPE=own` question.** The measurement shows the claim
excludes, on both keys, under real concurrency — and `SCOPE=own` was **never** what excluded them:
it selects which *PR branches* this box's **sweep** looks at (`*-tm`, `*-cap`, `fix/*`), by a naming
convention every box shares, so two `own`-pinned boxes select the same PRs. The code has said so
since the pin was added (§5 item 3, "a partition, not coordination"); the measurement now says the
claim covers those two classes without it.
- **Landing was NOT retired on the per-head key — and the decision that row pointed at has since
been TAKEN, in the direction of adding the exclusion.** The per-head rows are unchanged and still
measured: two boxes at two heads of one PR hold **two live claims**, so that key cannot be the landing
fence, and `SCOPE=own` does not cover it either (it is a selection filter, and the PR is in both
boxes' selection). agent-infra#1952 answered *landing: the PR moved to a new head* by adding a
**per-PR** key rather than exempting the row: landing also takes `refs/claims/pr-<N>` (§7.2b), and
**M6 measures that key** — one winner per PR across racers, and a second holder at a different head
**refused**. So the landing *claim* now has an observed exclusion, and the two per-head rows stay in
this table as the reason the second key exists (M3 stays green *because* the review key was
 deliberately not re-keyed). What M6 still does not measure is the merge itself: `gh pr merge` is not
pinned to a sha, so the marker-read→merge window is covered only to the extent that a second
**lander** is excluded (§7.2b, "What is measured, and what is not").
- **What the merge path does have, and what it does not.** `merge-one.sh` re-reads `LIVE_HEAD` before
merging and requires a **signed marker for that live head**, so the merged content is at least the
head some reviewer signed. It does **not** pin `gh pr merge` to a sha, so the guard is a read, not a
fence, and the window between the two is real. ⛔ **That last sentence is read from the code, not
measured** — exercising `gh pr merge` on a moved head needs GitHub, so it is not claimed as a
measured merge outcome here.

**For §0.3/§0.4/§0.5 when they land.** Those sections (the requirements and the keep/legacy
inventory, agent-infra#1905) are not on `main` yet, so this section — not them — is the source of
record for the measurement today. §0.4's "at-least-once with idempotent side effects" is accurate for
the **dispatch** and **review** rows and **not** for the landing row; §0.5's `SCOPE=own` row may move
from *retired* to *retired, see measurement* for the first two and must not for the third.

### 7.2e A refresh that cannot READ the pool reported an empty queue — **FIXED in agent-infra#1931**

`backlog=0` was the same line whether the pool had been read and was empty or the pool listing had
**failed**. Measured 2026-10-17: a cell refused on **131 consecutive passes** (its abort was correct)
and dispatched nothing while 15 PRs were open; on every one of those cycles the controller's line
read `backlog=0`, which is what a fleet with nothing to do also reads. The abort named the tiers in
prose, but nothing carried a *state* an operator or an instrument could key on, and a **partial**
read was reported with the identical sentence as a total one.

**Fix:** the pool read is now ONE of four named outcomes, in one vocabulary: `EMPTY` (every tier was
read and listed nothing — the only answer that may mean "no work"), `READ(<n>)` (every tier read,
n candidates), `PARTIAL(<tiers>)` (some tiers could not be read, so the survivors are a subset and
nothing is queued from it — #1736's rule, kept), and `UNREADABLE` (no tier could be read: the fleet
is blind). The state is persisted to `state/queue-state` with the epoch of the read, and
`orch-loop.sh` prints it as `queue=$(queue_state_token)` in the per-cycle heartbeat line and at the
end of the `[dispatch]` funnel line, with the age of the reading (a frozen value cannot pass as a
fresh one).
An absent or unparseable record prints `UNKNOWN`, never `EMPTY`. The refusal polarity is unchanged
and still fail-closed: a failed read exits TRANSIENT, never a green "nothing to do".

⚠️ **Deliberately NOT fixed here** — this is the *reporting contract*, not the transport, and not the
provisioning verdict: the fleet's shared gh backoff for GitHub's secondary (concurrency) limit is
agent-infra#1910, and a refresh whose resolved tool directory is behind `origin/main` still says so
only through its own existing refusals (issue #1931's directions 1 and 3, which this change does not
touch). A pass that cannot read the pool now says `queue=UNREADABLE` while it refuses.

### 7.2d A capacity refusal consumed the item's turn — FIXED in agent-infra#1909

**The defect.** R1 (a box dispatches only when it has capacity) worked exactly as designed on
2026-10-17 and that is why the queue stalled: the Mac refused at load 98→180 while cell-2 sat at
0.29 load with 14.5 GB free and cell-3 at 0.04. Nothing turned a refusal into "another box may take
this", because the refusal's consequences were invisible and **long-lived**:

1. `lane.sh`'s gate refused, so no agent ran and no PR could ever appear.
2. `chain-merge.sh` then waited its full **90 minutes** for that PR — holding `refs/claims/issue-<N>`
   the whole time, because releasing it is its EXIT trap's job.
3. Every peer's `claim_issue_preflight` reads a live claim as **COLLISION**, so ONE box's capacity
   decision made the issue ineligible on **all five** boxes for 90 minutes (up to `CLAIM_ISSUE_TTL`,
   3 h, if the chain were killed). That is the `parked-*` failure R8 forbids, arrived at by a
   different route: the item's turn was consumed by a machine that did no work.
4. Nothing stopped the refusing box from re-winning the claim next cycle and being refused again —
   starving the peers it had just yielded to.

**The mechanism**, three parts and no new network traffic (it rides the claim the refusal was
already holding):

| part | where | what it does |
|---|---|---|
| the **record** | `lane.sh` writes `state/capacity-refused-<N>`, one line: `<refused_epoch>\t<yield_until>\t<load\|mem\|disk\|land>` (`mem` = the SPAWN gate's memory refusal, #2387; `land` = the creation back-pressure refusal, §7.2g) | the refusal becomes durable and readable. Cleared when a lane actually runs, so a stale record cannot outlive its dispatch |
| the **release** | `chain-merge.sh` reads field 1 and exits **at once** with the gate's own code (75 load / 73 memory / 77 disk / 74 land-backlog) | the EXIT trap does the FENCED release it already did — so peers see CLEAN within one poll interval instead of after 90 minutes. Field 1 is what makes it per-dispatch: a record from an earlier run cannot end a LIVE lane's wait, which would let a peer open a second lane for the same issue — and the bound needs ORDERING SLACK, because `dispatch-merge.sh` spawns the LANE first: the record is written ~4 ms after the lane's fork while the chain reads its start ~8-15 ms after its own, so the record is normally a fraction of a second to a second OLDER than `CHAIN_START`. A bare `epoch >= CHAIN_START` therefore discards real refusals whenever a second boundary falls between the two, which is precisely when the box is loaded enough to refuse. `CAPACITY_REFUSAL_GRACE_SECS` (default 60) supplies the slack, capped by the record's OWN yield window (`until - epoch`), so it still cannot admit a record older than the stand-down it declares. ⛔ **the cap is STRICTLY shorter than that window, and that is load-bearing:** this box may not re-dispatch before `until`, so every legitimately-arriving chain has `epoch <= CHAIN_START - win`; a slack equal to `win` would then admit the single second `epoch == CHAIN_START - win` — an EARLIER dispatch's record ending a LIVE lane's wait — so the effective slack is `min(CAPACITY_REFUSAL_GRACE_SECS, win - 1)`. **Required relation: `CAPACITY_REFUSAL_GRACE_SECS < CAPACITY_YIELD_SECS`** (the shipped defaults satisfy it, 60 < 900, and the clamp holds the bound for every other pairing); re-read this line before tuning either knob |
| the **stand-down** | `orch-loop.sh`'s `capacity_yield_live()` reads field 2 and the dispatch loop `continue`s before the claim | releasing the claim makes the issue *eligible* on a peer; it does not make the peer *win* the CAS. While the yield is live this box leaves the issue **unconsumed** (no `dispatched.txt` row, no claim ref), so it stays a candidate here *and* free for every peer; when the yield expires the ordinary path resumes |

**Decisions worth not re-litigating.**

- **The signal is the gate's own refusal, not load average.** Whatever actually bound is named
  (`load`, `mem` or `disk` — three readings with three different remedies — and, since #2409,
  `land`: the creation gate's refusal, whose remedy is on neither this box nor any peer's; since
  #2293, `fork`: a box out of PROCESSES, whose remedy is a restart or a drain from OUTSIDE, never a
  wait; and since #2935, `capability`: the box could not complete one model call and RETURN, whose
  remedy is to repair or replace the box, never to wait). The transfer is driven by the refusal
  event. Load is a symptom of contention rather than a measure of capacity
  (`docs/ops/load-policy.md`), which is also why a lowering of `MAX_LOAD` — the ×8 change proposed in
  #1907, closed unmerged 2026-10-22 — could not have moved a single item. ⚠️ NOTE what the record
  can carry: the WORKER gate binds on **fork, load, memory, disk, capability or land**
  (`spawn-gate.sh`), so those are the values field 3 can ever hold, each with its own code
  (73 fork / 74 land / 75 load / 77 disk / 81 memory / 71 capability — `mem` is #2387's memory
  refusal). The lanes/swap terms — and the CONTROLLER's own memory arm, which compares `mem_avail`
  against `MIN_MEM_FREE_MB`, a different floor for a different population (§7) — belong to the
  CONTROLLER's own gate, which
  refuses *before* any claim is taken and therefore writes no record at all (§1 above). A reader that
  predates #2409 and knows only `load`/`disk` must treat `land` as `load` (it is non-numeric for its
  purposes, and `chain-merge.sh` maps an unrecognised value the same way) rather than as "no refusal";
  a reader that predates #2293 must treat `fork` the same way, and it will then publish the LOAD remedy
  for a box that cannot spawn the retry — which is exactly why the two codes were given distinct values
  (73 fork / 74 land / 75 load / 77 disk) rather than shared.
- **The yield is gate-independent, deliberately.** `load` clears when the box quietens and `disk`
  never does, but both produce the same `CAPACITY_YIELD_SECS` stand-down: the field names the remedy
  for whoever reads the record, and it must not shorten the transfer window (a disk refusal is not
  evidence that a peer is free *now*). Residual, named rather than hidden: a box whose disk is full
  re-attempts each candidate once the yield expires, because the controller's gate has no disk term
  to stop it earlier — bounded by the yield (900 s), not parked for ever.
- **The controller-level gate needs nothing.** It refuses *before* any claim is taken, so nothing is
  held and nothing consumes the item's turn; the transfer machinery exists only for the worker-level
  refusal, where an issue has already been claimed and a chain is waiting for it.
- **Every reader fails OPEN — and the two readers do NOT check the same thing.** A missing, empty,
  garbled, non-numeric or wrong-shaped record is **not** a refusal in either reader: treating one as
  a refusal would suppress dispatch, which is the fleet-wide idleness R8 removes, re-introduced by a
  corrupt byte. Past that, each consumes the fields it needs and no others:
  - `chain-merge.sh` uses **field 1** (numeric, and inside this dispatch's window: `epoch` at or after
    this chain's start minus the ordering slack, and not older than the record's own yield window).
    It reports **field 3** as the exit code (75 load / 73 memory / 77 disk / 74 land) and maps an unrecognised value
    to `load`, because the refusal itself is already proven by field 1 and refusing to end the wait over
    one corrupt byte is the behaviour this section forbids. It never reads field 2: an incoherent
    yield window must not make a proven refusal unreadable.
  - `orch-loop.sh`'s `capacity_yield_live()` uses **fields 1 and 2 together**, and only a COHERENT pair
    (`epoch < until`, `until` in the future) is a yield; an incoherent one is not, because it would
    park the item.
- **`CAPACITY_YIELD_SECS` (default 900) is clamped to 1..86400 and `0` is REFUSED**, not honoured:
  a zero-length yield would silently restore the defect while looking configured.
- **A rejected record is now VISIBLE.** `chain-merge.sh` logs, once per run, when a record is present
  but not admitted as this dispatch's. Before that it was indistinguishable from a lane that had
  simply not opened its PR yet — a discarded refusal cost the whole 90-minute wait and read as an
  ordinary timeout.
- **A YIELDED backlog no longer reads as stillness — and it now says so through the FUNNEL.** A
  cycle in which every candidate sits inside its yield window leaves `.batch` empty. The pre-#2040
  sentence then printed `backlog empty queue=READ(3)` and the cycle stayed that way for as long as the
  yield (up to 24 h at the clamp) — self-contradictory on the one line an operator reads to answer "is
  there work?". ⛔ #2040 later proved that SENTENCE itself was the defect (`backlog empty
  queue=READ(223)` while 223 candidates had been read and every one filtered away), so resolving this
  branch against it does **not** resurrect the claim: the yield count rides the funnel that replaced it
  (`dispatch_funnel`'s `yields=<n>`, in words: "this is NOT \"the fleet has nothing to do\""). The note
  is **additive** — measured by the loop, never one of the refresh's reconciled buckets — so a yielded
  backlog is visible on the no-dispatch line AND a yields note can never make an unreconciled funnel
  read as summed. With no yields the line is byte-for-byte the #2040 shape, so nothing that parses it
  changes.

`capacity-transfer.test.sh` drives the shipped `lane.sh` and `chain-merge.sh` and extracts
`capacity_yield_live()`, `dispatch_funnel()` and `cap_refusal_gate()` from the live scripts, with a
**local bare repo** as the shared origin so the released claim is a real fenced push.

⛔ **THE TWO MEASUREMENTS ARE NOT THE SAME RUN, AND THEY DO NOT HAVE THE SAME TOTAL** — quote them
per side, never as one:

| tree | `bash scripts/orchestrator-harness/capacity-transfer.test.sh` |
|---|---|
| **this suite's own tree** (post-fix) — `52 / 0` at the round-2 boundary fix; the same tree reported `46 / 0` at `b9f7633f`/`dcc24feb`, before §2b3's 6 sites existed | `passed: 52   failed: 0` — all 52 assertion sites |
| **the pre-change scripts** (`origin/main`'s `lane.sh`/`chain-merge.sh`/`orch-loop.sh`/`claims.sh` beside the new suite) | `passed: 10   failed: 28` — **38** sites reached |

The 14-site gap is two extraction-gated blocks that skip LOUDLY when the function they drive does
not exist: §3's **9** behavioural checks (`capacity_yield_live()` is absent from the pre-change
controller) and §2b3's **5** boundary checks (`cap_refusal_gate()` is absent from the pre-change
chain; the section's own "present" check is reached there and reds).
**52 is therefore unreachable on the pre-change tree and 38 is unreachable on this one** — a
pre-change run that reports 52, or a post-change run that reports 38, is measuring the wrong tree.
The pre-change passes are the checks that assert a refusal *didn't* happen and the ones pinning
behaviour this change leaves alone (§1 x3, §2 x3, §5 x4; e.g. "no `yields=` with no yields"). Per
section, pre-change → post-change: §1 10 → 10, §2 15 → 20, §3 1 → 10, §4 5 → 5, §5 7 → 7, so only
the two extraction-gated blocks move. The suite's `pi`/`gh`/`df` stubs are
**exported bash functions**, not files on PATH: both tested scripts re-prepend absolute dirs
(`/opt/homebrew/bin:/usr/local/bin`), so a PATH stub loses to the machine's real binary — measured on
the writing runner, where `/usr/local/bin/pi` beat the stub, and on any macOS deployment box, where
`/opt/homebrew/bin/gh` would have made `gh pr list` a real authenticated call from a suite that
promises no network. Residuals, named rather than hidden: the
review/fix path's load refusal (`merge-one.sh` returning 75) is re-dispatched by the sweep and is
**not** transferred, because it is work on an existing PR rather than an un-owned queue item; and
the stand-down is per **issue**, so a box at capacity still holds no view of *which* peer is idle —
peers take refused work by the ordinary severity-ordered pool, not by being told to.

### 7.2f PRs before issues — the dispatch ORDER, and ownership as a LIVE fact (owner ruling, 2026-10-18)

**The rule, as the owner stated it:** (1) take on UN-OWNED PRs first — "owned" means a LIVE PROCESS is
working that PR, not "someone intended to"; (2) fixing/salvaging a PR counts as taking it on, so a
conflicted or red PR is exactly the work; (3) only when NO un-owned PR remains may the dispatcher
create new work by picking issues; (4) and only if spare capacity remains; (5) never cap lanes to a
trickle to avoid this — the bottleneck is the queue, not the lane count.

**What was measured, and why the old gate could not see it:** 25 open non-draft PRs, **0** owned by a
live process, 25 un-owned. Nothing was working them. `pr-doctor` reported 21 "running" lanes while a
live-cwd scan found **none** of them holding a PR branch — its notion of "running" was not ownership.
Meanwhile `orch-loop.sh` gated issue dispatch on `unowned > MERGE_PRIORITY_AT` (**25**), so exactly
that state read as "not a backlog" and the box opened MORE work from issues: throughput stalled at
~4 merges/hour while the queue grew.

**The predicate is now a live fact** (`live-ownership.sh`, one probe per cycle):
a PR is owned **iff** some running process's cwd is inside a checkout whose checked-out branch is that
PR's `head.ref`, **or** inside a worktree whose PATH carries the PR number (`aig-wt-2001`,
`pr1963`, `1730-fix` — anchored on a marker token, so a date directory `2026-10-17` is not mistaken
for PR #2026). Cell ownership is the same predicate one level up: a process cwd under that box's
clone. Process cwd is read with ONE probe (`lsof -a -d cwd -Fpn`; `ls -l /proc/*/cwd` on Linux) and
joined against `git worktree list --porcelain` by LONGEST prefix, so a worktree under
`.worktrees/x` names its own branch rather than the repo's.

⛔ **What no longer counts as ownership, and it is the point:** a `fix-<PR>`/`merge-<PR>` **worker
surface name** (a durable terminal where the cmux daemon answers, otherwise a tmux session with the
HOME+keys.env contract — a reviewer reads the PR through `gh` and holds no branch; a session outlives its
work), a **`needsfix-<PR>-<head>` marker** (it *authorises* a spawn, it does not prove one ran), and a
**local claim ref whose holder died** (the lease outlives the process by design — `claims.sh`:
"LEASE = DATA, NOT LIVENESS"). Each of those is a record of INTENT, and reading intent as work is what
produced the measurement above.

**Five guards make the predicate hard to fool, each added after a review that falsified the earlier
version** (`test-gates.sh` pins all five, `live-ownership.test.sh` drives four of them against real
processes):

* **A shared ref is not PR identity.** A fork PR's `headRefName` is only a branch name, so branch
  equality alone let any PR whose head ref was `main`/`master`/`patch-1` read OWNED because some
  process was merely *sitting* on that branch. Refs every repo has are refused; only the path rule may
  decide them.
* **A leftover cwd is not a branch.** A process whose cwd is in a deleted/unregistered
  `.worktrees/<x>` fell back to the ROOT checkout by longest prefix and reported the root's branch.
  Such rows are marked `(stale)` and match no PR. (Measured on this box: two `main` rows, one from a
  deleted `.worktrees/fix/1712-…/scripts/…` cwd.)
* **A live pid is not a worker.** `merge-one.sh` writes nothing but `$$` into its lock, so a recycled
  pid would keep a PR "owned" for ever — self-reinforcing, because the controller then never spawns
  the worker that would delete the lock. Ownership now requires the pid's **command line** to be the
  merge worker *and* to name that PR — in **both** spawn forms: positional (`merge-one.sh <repo> <or>
  <pr> <branch>`) and the rail's `--argv state/argv-<PR>`, where the number appears only inside a
  filename. (`claim_live` deliberately keeps the looser any-live-pid test: there the direction is "do
  not spawn", and a stricter test would `rm -f` a live worker's lock.)
* **Ownership never inherits the spawn guard's looseness.** The cross-box arm used to delegate to
  `claim_live`, whose first arm is that loose lock test — so a stale `mergeclaim-<PR>.lock` with a
  recycled pid lent liveness to an **expired** foreign lease, and the PR left the queue for ever. The
  lease reader is now its own function (`claim_lease_live`): two callers, two questions, one reader
  each.
* **A `(stale)`/`(cell)` row matches no PR — by PATH as well as by branch.** Marking the branch was
  half a fix: the path arm never read it, so one leftover process in a deleted
  `.worktrees/fix/1712-abc` still owned PR #1712. Both arms refuse those rows, and `lo_select_rows`
  applies the same shared-ref list as `lo_owns_branch` so the funnel's marks cannot disagree with the
  gate inside one cycle.
* **A quiet box is an ANSWER; a failed census is UNKNOWN.** `lo_scan` returns 0 when the census read
  the process table — including when no process is inside this repo (that means *everything is
  un-owned*, the drain direction) — and 2 only when the probe itself failed or read nothing. Before
  this, a healthy idle box reported `UNREADABLE` every cycle, which is how a real alarm stops being
  one. The probe is captured before it is parsed, so an absent/broken `lsof` cannot look like a
  successful empty census. And when the scan does fail, the loop BLANKS `LO_LIVE`: the module cannot
  always delete its own output (an unwritable `state/` cannot be written to *or* cleaned), so a stale
  table must be made unreadable rather than trusted.
* **A fallback may not LOWER the gate.** When the per-PR rows are gone, the count is the whole open
  listing ("assume nothing is owned"), and the scope-filtered swept set can read fully owned. The floor
  is applied (`⚠️ fail-closed floor: …`) so the smaller number can never open the issue path.
  ⛔ `SWEEP_LIST` survives a **304** and nothing else (#2640). It is reset every cycle
  (`SWEEP_LIST=""` before the request); a **200** fills it AND persists it to
  `state/sweep-rows.tsv` / `state/sweep-meta.tsv`, and a **304** restores it from that cache — because
  a 304 is GitHub asserting "identical to what you cached", so the cached rows ARE that cycle's read.
  The restore is bounded by `SWEEP_MAX_AGE` (the conditional header is only sent while the last full
  sweep is younger than that), so it can never act on rows older than the floor. A **deferral** or a
  **failed listing** leaves the sweep with ZERO rows — it made no request, and a failure is not an
  assertion of "unchanged" — and it does NOT serve the cache. In all three no-read cases the only
  honest thing the cycle can do is NAME the cause (`[pr] PR path: NO UNIT SPAWNED this cycle — …
  no per-PR read this cycle (<cause>)`), never imply a dispatch. An earlier version of this paragraph
  claimed the opposite for the 304 case in the other direction (that `SWEEP_LIST` never survives);
  that was true of the shipped code until #2640 and was itself a defect: the box ran one cycle per
  process, so a 304 cycle had no memory to inherit, and 152 of 221 measured cycles acted on nothing.

⚠️ **Three residuals, stated rather than hidden.** (a) A *reviewer* in flight holds no branch, so its
PR reads un-owned: that over-counts the work queue — the safe direction here (take on MORE PR work,
never less) — and the unchanged `sess`/`claim_live` spawn guards still refuse to double-work a PR. (b)
A claim held by **another box** *is* counted, because a remote pid cannot be probed and the lease is
the only evidence that can exist; a claim held by **this** box is not (only a live process is). (c)
The sweep's own `OWN`/`UNOWNED` marks come from ONE awk pass over branch+path, while the gate's count
also applies the merge-lock and foreign-claim arms — so the funnel's `owned` figure can UNDER-count
by those two (a PR another box is merging still reads `UNOWNED` there, and can be named as `first`).
The gate's number is unaffected, the shared-ref list is now the same in both (so they cannot disagree
in the dangerous direction), and the spawn guards still refuse the double work; unifying them into one
pass is a follow-up, not a silent gap.

**The reviewer/fixer headroom now follows the gate's predicate too** (`unowned > 0`, not
`unowned > MERGE_PRIORITY_AT`): with the gate blocking on ONE un-owned PR, keeping the old size
threshold would have drained the measured 25-PR queue at the pre-change WIP — the "capped to a trickle"
shape the ruling forbids. `is_num` guards the count, because an errored `[ … -gt … ]` is FALSE and
would silently pick the smaller budget.

**The order is printed every cycle, and the choice is auditable in one line:**

```
[select] population=swept (open-rows=0 swept=61 fallback_open=26)
[select] 61 PRs: 56 un-owned (5 owned, 0 parked/needs-human excluded) -> dispatching PR-takeover (first #1161 — conflicted before pending, oldest first) ; issues: SKIPPED (un-owned PRs exist)
[dispatch] issues BLOCKED — 56 un-owned PR(s) remain; this cycle's work is the PR queue (first #1161)
[dispatch] drain alive — last land 12m ago (#9065); 56 un-owned remain
```

(The first two lines are a REAL cycle on this repo's live queue; the third is that cycle's next line
when `state/merged-*.done` exists — `population=` says which of the three sources answered, so a
degraded population is visible rather than inferred. `open-rows=0` there is the GraphQL listing having
been rate-limited while the REST sweep succeeded: exactly the fallback this design exists for.)

* **Conflicted before merely-pending, oldest first**, and the sweep now ACTS in that order, so a
  scarce fixer/reviewer slot goes to the PR that unblocks the queue rather than to whichever PR
  GitHub listed last (REST lists newest-first). Classes come from the last observation the sweep
  made (`state/prclass.tsv`, folded to one row per PR per cycle); the age comes from the listing's
  `created_at`, which rides the SAME request.
* **`issues: SKIPPED` has a reason, always.** An un-owned set that is non-empty, an unreadable
  count, or a capacity gate: `busy` and `draining` must never be the same reading of the log.
* The funnel's verdict **gates** the issue path (`LO_CHOICE`), so a printed decision cannot be
  ignored by the code that acts on it.
* **No threshold and no lane cap.** `MERGE_PRIORITY_AT` survives only as the reviewer/fixer headroom
  trigger (a backlog SIZE, which is what it actually measured); `MAX_LANES` and the capacity gates are
  untouched.
* **A lost funnel line is a HOLD, not a re-decision.** The fallback used to key on the line being
  empty, so a failed write to `state/` silently re-decided the cycle from the capacity gate — and with
  nothing binding that gate, that OPENS the issue path while the funnel had chosen PR work. The
  fallback now keys on **availability** (is `lo_select` defined?): module present but silent ⇒ issue
  path closed and the reason named; module absent ⇒ the documented registry-only degrade.
* **The parked subtraction is over UN-OWNED PRs only.** The count already excludes owned PRs, so
  subtracting a PR that was both parked and owned removed a unit that was never in the minuend — with
  exactly one un-owned PR left that floored the gate to 0 and opened the issue path.
* **There is NO release arm, and there will not be one.** A drain that stops landing prints
  `DRAIN STALLED — no PR merged in <n>m (last #<pr>) while <n> un-owned remain` and the issue path
  stays closed. The temptation — "nothing has landed in 4h, so let issues through" — converts *PRs are
  not landing* into *dispatch more issues*, which is how a stall hides behind fresh activity. The
  ruling is unconditional (`Only when NO un-owned PR remains may the dispatcher create new work`), so a
  stall is a LAND/CAPACITY problem to fix, and the line exists to name it. `test-gates.sh` pins the
  absence of such an arm, and pins that the stall AGE is printed only — never handed to the gate.
* **`acted` IS NOT `spawned`, SO THE PASS MUST SAY WHAT IT STARTED (agent-infra#2590).** A disposition
  row is `act` for a spawned worker, for `gh pr merge`, for `gh run rerun`, for a draft-ready and for an
  auto-merge **arm** — and an arm starts nothing. Measured on a live box: `[pr] PR path: 2 acted
  (#9812,#9528)` beside `#9528 auto-armed`, and the funnel then claimed "dispatching PR-takeover" on the
  strength of a button press. So every pass now emits exactly ONE terminal spawn line, read from an
  ARTIFACT (`state/worker-<tag>` records, written by `wt_spawn` and by nothing else) rather than from a
  count of claims:

  ```
  [spawn] SPAWNED 2 worker(s) this pass: fix-9813,merge-9818
  [spawn] NONE — no worker was started by this pass (…); 3 act row(s) may still exist — an arm, a rerun or a draft-ready — and those start nothing
  [spawn] UNMEASURED — this pass cannot say what it started (state/ cannot be enumerated …)
  ```

  Three readings, kept apart: a measured positive, a **measured zero**, and no measurement at all —
  collapsing the third into the second is the same defect sign-reversed, and a zero from an unread
  directory would be a claim with nothing behind it. The funnel's `dispatching PR-takeover` wording now
  requires `spawned > 0`; an acts-only pass says `NO WORKER SPAWNED this cycle (N action(s) recorded, 0
  worker records created)`. An absent spawn count (an older caller) leaves the old wording alone.
* **A STALL IS AN ESCALATION, NOT A LOG LINE (agent-infra#2590).** `DRAIN STALLED` printed 8 times on a
  box that sat at `lanes=0`, 9 un-owned and nothing landing for 3.4h, and read as normal. When a stall
  coincides with **zero spawns** it is now `DRAIN DEADLOCK`, it writes `state/drain-stall`
  (`at= passes= age= unowned= spawns= acts=`) so it OUTLIVES the pass, and the cycle status line carries
  `drain=DEADLOCK(passes=…,unowned=…,no_land=…m,spawns=…)` — the one line every reader already parses.
  The token self-heals: a land newer than the marker deletes it, so it cannot become the stale flag it
  replaces. ⛔ It still opens NOTHING: the escalation exists to make the policy's promise *verifiable*,
  never to add the release valve the ruling forbids.
  ⛔ The land age is measured from `state/merged-<PR>.done`, and `merge-one.sh` is its only writer — so
  the age answers "when did **this box** last land", not "when did the queue last move". Measured
  2026-10-23: 7 PRs merged on the repo between 21:31Z and 22:40Z while the line said "no PR merged in
  264m", because a PEER box held the landing claims. Both stall lines therefore name their population
  and quote the pass's own dominant NAMED wait (the reason it spawned nothing), so an escalation cannot
  misdiagnose a box whose only "problem" is that it is not the lander.
* **Parked PRs are excluded from the gate's number** — a PR parked at `MAX_FIX_TRIES` is one the
  harness itself declared needs-a-human, and letting it hold the issue path shut forever would be the
  "stale flag that latches a gate" failure. The count is printed so the subtraction is visible.

Proof: `live-ownership.test.sh` spawns REAL processes in REAL worktrees and asserts owned / un-owned
/ stale-registry-claiming-owned-but-dead, plus the four selection cases (3 un-owned; 0 un-owned +
capacity; 0 un-owned + no capacity; registry-says-owned-but-process-dead). It was mutation-tested:
disabling the branch arm, inverting the conflict rank, and removing the PR-first block each turn it
RED (the first version of the suite did NOT catch a disabled branch arm — the fixture's worktree path
answered through the path rule — which is why §1b of that suite isolates the branch arm).

⛔ **A BROKEN ORIGINATION IS NOT A PRIORITY DECISION (agent-infra#2229).** The ruling above closes the
issue path *because a PR queue exists*. It says nothing about a box whose refresh **cannot run at
all** — and the beat could not tell the two apart. `refresh-candidates.sh` is the only thing that puts
an issue into `candidates.txt`, and `orch-loop.sh` runs it in a **backgrounded** subshell, so a failure
was one line in an append-only log (`[refresh] FAILED rc=1 (transient — retried next cycle)`) or an
abort whose derived sentence was true of every possible cause (`none of the 12 candidate(s) … produced
a usable verdict`). The gate then printed, unconditionally:

```
[dispatch] skipped (merge-priority (2 un-owned of 5 open PR(s) — PRs before issues)) lanes=0 workers=…
```

Measured 2026-10-21 on all three cells: the pre-flight's holder surface could not read the fleet
board's lane registry, so every candidate came back `INCOMPLETE`, so every pass aborted `judged 12 /
usable 0`, so nothing was ever queued — and the same line said "merge priority" for it. The priority
order was never wrong; the **reading** was. `[dispatch] skipped (…)` may now only mean *a usable
candidate existed and was deliberately deferred*, and the pass records its own outcome so the caller
cannot guess:

* `state/refresh-last` — `result=ok|fail|running`, `stage=` (which phase the pass reached), `rc=`, `at=`,
  `repo=`, `why=`, `cmd=` (the command that failed), plus `judged=`/`queued=`/`backlog=`/`handed=`/
  `unusable=`. Written as a `result=running` tombstone at entry and then the outcome at most once —
  including for an exit nobody converted, which the pass's own `EXIT` trap records as a FAILURE (rc=0
  included). It is the only thing the caller reads; a log line scrolls away. If the write itself fails
  (`state/` unwritable) the pass leaves `$O/.refresh-unrecorded` instead, and the caller reports THAT.
* `[refresh] FAILED stage=<stage> rc=<rc> cmd=<command> — <cause>`, and the cause carries the surface
  the pre-flight itself reported (`issue-assignee-holder:12`), not a count. The failing surface was in
  the tool's own output all along and was being discarded.
* `[refresh] handed to dispatch: #N — <judged CLEAN by THIS pass|carried over from an earlier pass>
  (queue depth M; orch-loop.sh takes the head first)` — a successful pass ENDS by naming its choice,
  and says `NONE` with the reason when it judged nothing.
* the caller prints exactly ONE of the outcomes below — the guide is the table, deliberately without a
  count (a first draft said "four" when the code had six; a count in prose drifts, the table does not):

  | line | when | the prefix MEANS |
  |---|---|---|
  | ⛔ FIRST, FOR EVERY ROW BELOW EXCEPT THE FALLBACK-MARKER ROW: a refresh on this box **can record a pass outcome**, or the record is younger than the 20 min in-flight bound. When no `refresh-candidates.sh` on the box can write the record and the record is absent, unageable or past that bound, **every** row below is pre-empted by the SEED-SKEW row — the reader does not trust a record nothing can advance, whatever it says. (The fallback-marker row is read FIRST, before this test: `$O/.refresh-unrecorded` exists only when a writer RAN and could not store its result, so it is evidence the SEED-SKEW row cannot see.) | | |
  | `[dispatch] skipped (…) … — deferred: N usable candidate(s) queued, head #N (refresh ok, <age>)` | `result=ok` **and** a usable candidate is queued, **and** no fallback marker is present | origination WORKS and the gate is holding real work |
  | `[dispatch] nothing to defer (…) … queued=<recorded> and handed #N` (or `handed nothing`) | `result=ok` and the queue is now empty | the work was queued and has been dispatched/landed — **not** a stalled origin (the numbers are the pass's own `queued=`/`handed=`, never inferred from the empty queue; `handed nothing` means the pass queued nothing, and its `handed to dispatch: NONE` line says why) |
  | `[dispatch] deferred (…) … wrote its start marker <age> ago and has recorded no outcome yet` | `result=running`, **younger** than the in-flight bound, and a usable candidate is queued | work is deferred, but no pass has finished — do not read it as health |
  | `[dispatch] nothing to defer (…) … the queue is EMPTY; a refresh pass wrote its start marker <age> ago` | `result=running`, younger than the bound, empty queue | the ordinary state of a healthy pass on a short backlog: work in progress, **not** a drained queue and **not** a death |
  | `[dispatch] deferred (…) … NO refresh outcome is on record yet` | no record at all, usable candidate queued | the queue predates this controller (or no pass was needed) — **not** evidence that origination works |
  | `[dispatch] BLOCKED: refresh failed — stage=…: <cause> (<age>)` | `result=fail` | origination is BROKEN, and the stage/cause/surface are named |
  | `[dispatch] BLOCKED: a refresh pass finished and could not record its outcome (stage=… rc=… why=…)` | `$O/.refresh-unrecorded` exists | `state/` was unwritable when the pass tried to record, so the record on disk is an EARLIER pass — read the marker, not the record. `rc=0` there is a SUCCESS whose write failed; non-zero is the failure |
  | `[dispatch] BLOCKED: a refresh pass wrote its start marker <age> and has recorded no outcome since` / `BLOCKED: a refresh pass left a start marker that cannot be aged — <why>` | `result=running` **past** the in-flight bound (20 min, the controller's own stale-lock bound), or a marker whose `at=` is unreadable, **and** a refresh script on this box can record a pass outcome | the pass DIED (SIGKILL, OOM, cycle timeout, uncaught error) — and an unreadable stamp is never read as a fresh one |
  | `[dispatch] BLOCKED (SEED-SKEW): no refresh script on this box can RECORD a pass outcome` | **no** `refresh-candidates.sh` on this box can write `state/refresh-last` (the seeded `$O` copy predates the record, or none was found at all) and the record is absent, unageable, or past the in-flight bound | the record's age is **NOT** evidence about any pass: nothing here can advance it, so it must never be read as a death. The seeded copy is stale — re-seed `$O` from the shipped scripts (agent-infra#2308) |
  | `[dispatch] BLOCKED: the refresh outcome record is UNREADABLE (result=<what it read>)` / `BLOCKED: no refresh pass has completed on this box` | the record exists but its verdict is not one this reader knows; or no record and no queue | stale or absent evidence — never a healthy pass |

  The FIRST row is not a line the reader prints — it is the precondition the rest are read under, which is
  why it is stated once rather than appended to eight `when` columns (agent-infra#2308).

  ⛔ The in-flight bound is what stops the other direction of the same error: a pass whose tombstone is
  a few seconds old is RUNNING, not broken, so a healthy box is never reported `BLOCKED` for the
  duration of its own pass. The bound is the controller's, not a new one — `orch-loop.sh` stops
  trusting the same pass at 20 minutes.

  So the invariant is the PREFIX, not a sentence: **`skipped (` is printed if and only if a pass
  SUCCEEDED and a usable candidate is deferred.** `deferred (` marks a real deferral whose
  origination health is unproven, and `BLOCKED` marks broken origination. `nothing to defer` is the
  healthy idle state and is deliberately its own word, so it can never be read as the mask.

  Two of those rows are separated by a question the record cannot answer by itself — **can anything on
  this box write it?** `orch-loop.sh --check-refresh` answers that in exit codes, for a monitor or a
  CI job that cannot read prose: `0` the seeded `$O` copy can record (no skew), `1` DIVERGENCE — the
  seeded copy is MISSING or cannot record, so the controller would run a different copy, `2` no script
  here can record (or none was found), so origination cannot be proven. It takes no lock and writes no record, but it is
  not inert: like every invocation it may create `$O/logs`, `$O/state` and the queue files, append
  the `[startup]` line to `$O/logs/orch-loop.log`, and `chmod +x "$O"/*.sh` — so point it at a box's own
  `$O`. `78` means the controller could not start at all (a startup guard fired), which is never
  "healthy" (agent-infra#2308).
* `state/refresh-last` also carries a TOMBSTONE: every pass writes `result=running` **before** it does
  any work, so a pass killed by SIGKILL, the OOM killer, the cycle timeout, or an uncaught error in a
  subshell cannot leave the PREVIOUS pass's `result=ok` on disk to be read as this cycle's health. The
  only way to leave an `ok` behind is for that pass to have written one — and if the record cannot be
  written at all (`state/` unwritable), `$O/.refresh-unrecorded` is written instead and the reader
  treats it as a failure, so "the record could not be stored" is loud rather than silently stale. (`stage=` is therefore always
  one of `startup|provision|list|persist|preflight|budget|judge|skip|handoff`, with `running` as the
  tombstone's verdict and `skip` the #1984 unchanged-input pass, which is a success.)

`origination-funnel.test.sh` pins all of it, including the anti-mask assertion: a planted failure at
**every** stage — and a failure with a leftover queue — must produce no `skipped (` line at all, and the
assertion is paired with a POSITIVE one (`BLOCKED: refresh failed — stage=<that stage>`) so a driven
block that silently does nothing reads RED rather than vacuously green.


### 7.2g Creation back-pressure — the fleet opens PRs faster than it lands them — **FIXED in agent-infra#2409**

Every capacity gate this harness had measures **the box**: `MAX_LOAD`, `MIN_MEM_FREE_MB`,
`MIN_SWAP_FREE`, `DISK_MIN_FREE_MB`, the pi spawn point. A box with 20 free lane slots in front of an
81-PR queue therefore reads perfectly healthy — and opens the 82nd PR. Measured 2026-10-23T11:50Z over
a trailing 48h, both repos, from REST:

| repo | opened | merged | ratio | open |
|---|---|---|---|---|
| `daniel-ospina/agent-infra` | 73 (**1.52/h**) | 25 (**0.52/h**) | **2.9 : 1** | **81** |
| `daniel-ospina/tortoise` | 131 (2.73/h) | 115 (2.40/h) | 1.1 : 1 | 19 |

So the same harness is roughly balanced on one repo and accumulating ~24 PRs a day on the other. The
difference is throughput, not capacity — which is why a COUNT is the wrong threshold: 19 open is a
healthy queue on tortoise and would be a catastrophe on a repo landing 0.1/h. **The sizing rule is
Little's law, L = λW**: the ceiling is the repo's OWN measured landing rate times the lead time we accept
(`λ` from the better of the two trailing 24h windows, floor 5, so a suppressed day cannot shrink the
ceiling and a repo that has landed nothing cannot collapse to zero).

Where it acts: `run_agent` (spawn-gate.sh), **after** the disk and load gates and **for every KIND
except `fixer`, `reviewer` and `prfix`** — a deny-list, so `lane.sh` (KIND=lane) *and*
`nonblocking-dispatch.sh` (KIND=bg) are both measured, and a KIND nobody has written yet is gated by
default rather than silently exempt. It acts at the moment a CREATION worker is spawned, before any work
exists.

⛔ **`KIND` IS NOT A CREATION/REPAIR DISCRIMINATOR, WHICH IS WHY THE EXEMPT SET HAS `prfix`.**
`pr-doctor` dispatches every PR repair through `nonblocking-dispatch.sh`, so a hardcoded `KIND=bg` put
those repairs under the gate in exactly the state that triggers it (review cycle 2, P1: the gate held
the work that drains it). The dispatcher now takes the kind as an **argument** —
`nonblocking-dispatch.sh <name> <wt> <brief> <timeout> [bg|prfix]`, default `bg` — and refuses any other
value, so a caller DECLARES what it spawns and an undeclared caller still gets the refusing default.
The exempt set is therefore: `fixer` (fix-one.sh: pushes to an open PR), `reviewer` (merge-one.sh: the
verdict that lets one land), `prfix` (pr-doctor: rebases/fixes an already-open PR — **PROVEN from
GitHub**, see below). No merge path calls `run_agent`, so a deep backlog can never stop the work that
drains it (`capacity-transfer.test.sh` asserts the shell paths AND the non-shell ones — the pr-doctor
declaration, its argv, and the dispatcher's closed vocabulary).

⛔ **A DECLARED KIND IS NOT EVIDENCE, SO `prfix` IS PROVEN.** `fixer`/`reviewer` are set by the two
scripts that do the work; `prfix` arrives in an argv a **lane can type** (`bash $O/nonblocking-dispatch.sh
… 300 prfix`), so exempting it on the caller's word was a one-argument bypass — reproduced in review
cycle 4: a worker started on a repo 5.4× over its ceiling. The gate now proves it from GitHub: an OPEN
PR must be **this worktree**, by one of two rules, and the exemption line names the PR it proved —

- the **branch** rule: the PR whose head ref is this worktree's checked-out branch, **and** whose
  `headRefOid` IS this worktree's `HEAD` (a branch NAME alone is satisfiable by a stale local branch or
  by a name that collides with some other PR's head, so it is not accepted on its own);
- the **commit** rule: the base repo's PAGED open-PR listing holds an OPEN PR whose `head.sha` is this
  worktree's `HEAD` — the only rule that can answer for a FORK PR, whose worktree is a detached
  `refs/pull/<n>/head`. Two shapes are rejected on measurement, not taste: `gh api
  repos/<r>/commits/<sha>/pulls` (cycle 6) answers `[]` for a fork head — a fork PR's commit lives in the
  FORK's network, so the base repo cannot see it: 12 of 12 measured fork PRs (cli/cli, pydantic,
  home-assistant, vscode) were invisible to it and visible to the listing, which would have made every
  fork repair unprovable and therefore held on exactly the deep repos this gate exists for. And a bare
  `pr list` (cycle 5) is newest-first with a silently truncating `--limit`, so an older PR would be
  unprovable — permanently held — as the backlog deepens. The listing is paged (5 × 100) and a page that
  comes back exactly full is walked rather than read as “no match”.

Unprovable is **not** a hold by itself: the claim falls through to the ordinary measurement, so under
the ceiling it runs (nothing is being exempted from anything), over the ceiling the real backlog reason
is reported, and a P0-blocker / base-red issue keeps its documented precedence. The log says `NOTE … not
provably an OPEN PR`, never "unprovable, so refused" — a proof failure must not halt the drain on a
healthy repo.

⚠️ **THE NAMED RESIDUAL, BECAUSE THE EVIDENCE DOES NOT MEAN WHAT IT IS TEMPTING TO CLAIM.** These rules
prove *"this worktree is an open PR"*, not *"this work is repair"*. A lane standing in a worktree that
IS an open PR can still spawn arbitrary work there with `prfix`, and the gate will not see it. That is
accepted rather than closed: the alternative is an ambient switch or a caller-set flag, which is exactly
what review cycle 4 found opening this gate, and the gate's job is back-pressure on the fleet's DEFAULT
behaviour, not a security boundary against a lane that already owns a PR. What the rules do close is the
case that was measured — a lane with no PR at all naming itself `prfix` to skip the gate.

⚠️ **AND A STALE `$O` COPY WOULD SILENTLY UNDO THE EXEMPTION**, so `pr-doctor` refuses its whole pass
when the deployed dispatcher predates the kind argument (it would ignore the extra argv and spawn every
repair as `KIND=bg`): `REFUSING: $O/nonblocking-dispatch.sh predates the repair kind … refresh with
install.sh`, exit 2, recorded. A drift instrument can see that the copy differs; none of them can say
“the drain is now gated”, which is what this refusal says.

The verdict is a **named state, never a silent pass** — exactly one line, first word the state:

| state | when | what happens |
|---|---|---|
| `LAND-BACKLOG <n> open / <r> landings per hour (ceiling …)` | `open > ceiling` | **held**: no agent starts, exit **74**, the issue stays in the pool, `state/capacity-refused-<N>` records `land` so `chain-merge.sh` stops waiting and releases the claim |
| `OK <n> open / <r> landings per hour (ceiling …)` | `open <= ceiling` | the lane starts |
| `UNREADABLE <reason>` | any read failed, or the worktree's origin is not a GitHub slug | **held** (exit 74). A measurement that cannot be read is never the default that reads as OK; the safe direction is the cheap one (a false hold costs one re-dispatch, a false OK costs 1.5 PRs/hour that nothing lands) |

Two **evidence** exemptions, both read from GitHub so a lane cannot mint one: an issue labelled
`P0-blocker`, and a `base-red`/`main-red` repair detected in the issue title. Both REDUCE the backlog,
so holding them would be backwards. They are evaluated **before** the verdict, so a readable call never
holds a P0. A TOTAL `gh` outage fails the exemption read too — an exemption that cannot be read cannot
be proven — and then a P0 lane IS held; the refusal line says `EXEMPTION-UNREADABLE` so the operator
fixes the gh chain instead of concluding the issue was judged non-urgent. There is deliberately **no
env bypass** (`LB_SKIP`, `LB_GH` or similar): an ambient switch that opens a gate is not a gate, and a
`gh` seam was measured opening this one on an 82-PR repo before it was removed.

The refusal is a *different* refusal from a capacity one, and the vocabulary says so: exit **74**
(`AGENT_LAND_BACKLOG`), the record's field 3 is `land`, `chain-merge.sh` maps it to 74 and states in its
own words that it is **not** a capacity transfer (the backlog is repo-wide, so handing the issue to a
peer box cannot clear it — the remedy is to LAND). Full contract and the four cases: 
`capacity-transfer.test.sh` §LB.

---

### 7.2h Every gate measured THE BOX — none measured the CI QUEUE (agent-infra#2296)

A box with 20 free lane slots and a 90-deep CI queue measures as **healthy** on every gate this
harness had (`load=`, `mem_avail=`, `swap_free=`, `capacity-placement`). Measured 2026-10-22 13:40
UTC: tortoise `queued=92 in_progress=6` on 5 runners, agent-infra `queued=97 in_progress=7`. Nothing
finished because everything started, and every push in that state buys a verdict that arrives after
the lane has stopped waiting for it — while DESTROYING the head-bound review attestation of the PR it
touched (a record certifies exactly one revision, agent-infra#2148).

The remedy is `ci-queue.sh`: one sourced module (also runnable standalone —
`bash ci-queue.sh status --repo owner/name`) that reads the queue over REST (`gh` through the same
`gh-rest`/`gh-limit` shims as every other read: no GraphQL, no new credential) and answers ONE
question — may this box send more CI-spending work yet. The ceiling is **derived**, not a constant:
`ceil(runners × horizon_min ÷ job_p90_min)`, and it is a **measured queue read, NOT a lane cap**: the
owner ruling of 2026-10-17 ("dispatch should be gated on capacity, not on number of lanes") is why
nothing here re-states a lane ceiling. ⛔ **Repair does not read it at all (#2927).** The two actions
that DO — the two that add a run to the queue — are `orch-loop.sh` (one read per PASS — the sweep's
and the dispatch block's, so at most TWO live reads per cycle — in-shell, before the ISSUE dispatch,
plus the CI RERUN site, which queues a fresh run for the same head) and `dispatch-merge.sh` (the batch
that stampedes, issue→PR). ⛔ THE FIXER ARMS AND `fix-one.sh` ARE NO LONGER ON THAT LIST, AND THAT IS
THE CHANGE: a fixer is REPAIR on a PR that already exists, bounded by lane slots, the cross-box claim
and the load/disk gate. The depth this module prices is CI concurrency belonging to NEW-PR work; gating
repair with it skipped 41 consecutive repair dispatches while 8 runners and ~11 lane slots sat idle.
The former FOURTH-arm disclosure (the RED-TREE fixer spawning before any `ciq_push_ok` call, home
#2408) is therefore moot — nothing on the repair path reads this module, so a started lane pushes
instead of being turned away. ⛔ That census is the SWEEP's, not the fleet's: `pr-doctor`'s `prfix`
workers remain an **ungated** pusher and are not an orch-loop arm at all — `pr-doctor.py` spawns up to
`MAX_FIX` of them to `fetch -> rebase -> fix -> push` (or `gh run rerun`) with no queue read
(`rg -c 'ciq|ci-queue' scripts/pr-doctor.py` = 0), so a launchd job still adds CI behind a deep queue.
⚠️ #2540 asked for the OPPOSITE — more gating on repair pushes — and #2927 records why its premise (a
fixer push is the queue pressure) is what the measurement contradicts; wiring that surface is a
re-open of #2927, not an execution of #2540.

Two properties are the point, and both are pinned by `ci-queue.test.sh` (wired into
`run-bash-shards.sh`): an **UNREADABLE** queue is UNKNOWN and UNKNOWN defers CI-spending work
(fail-closed, because the alternative makes a `gh` outage indistinguishable from an empty queue),
and every deferral emits ONE line naming the depth, the runners, the ceiling and WHAT was deferred —
silence is what makes a deferral look like a bug. A deferral consumes no attempt: the ISSUE-batch
arm releases its claims and drops its rows, and the CI-rerun arm withholds the rerun and records why
(`state/rerun-<PR>-<RID>` is not written). The `fixbail-*` marker is NOT written by either — it
belongs to `fix-one.sh`'s own three pre-agent deferrals (the cross-box refusal, the PR-OWNER lock, and a
PR-owner takeover that could not complete), which is where it is written.


### 7.3 The harness is unversioned (this directory is the remedy)

Until now it existed only as `~/orchestrator/*.sh` on one machine: no history, no review,
no way to hand it to another box, and no way to know which of the 14 scripts were live. §9
records which are live and which are retired.

### 7.4 Defects found in the first review of this artifact (all fixed here)

These are kept as a record because each one is a *failure mode of the design*, not a typo.
(`retired/` fixes are annotated in place and only parsed — the retired tree is dead code.)

| Defect | Impact | Fix |
|---|---|---|
| `MAX_LOAD` was rendered into the plist and documented as live back-pressure, but never compared to anything | the load ceiling did not exist; a lanes-bound stall logged itself as a load stall | the dispatch gate now tests load first and names the binding gate in `[dispatch] skipped (…)` |
| `SKIPPED`/`NEUTRAL` counted as satisfying **every** required check, including the merge authority | a skipped `ai-review-gate` read as `GREEN` and the PR merged **without any signed review** — a fail-open on the one gate that matters | the classifier requires explicit `SUCCESS` for `ai-review-gate` (absent counts as failed) |
| A lane's PR is driven by `chain-<N>`, whose session name the controller's in-flight guard could not see | two concurrent `merge-one.sh` runs per PR: duplicate evidence comments, duplicate `record-review` writes, `ISSUES`/`CLEAN` interleaving | atomic per-PR claim file, honoured by all three paths |
| `fixcount` was incremented and the findings marker deleted *before* the fixer spawn was attempted | a killed/failed spawn consumed one of `MAX_FIX_TRIES` and destroyed the findings, so no fixer ever ran | spawn first; bookkeep only on success, message the failure otherwise |
| Reaching `MAX_FIX_TRIES` fell through to the re-record branch | an unfixable PR burned a full fresh-context review **every cycle, forever** | terminal `state/parked-<PR>` state, keyed to the head so a new push re-arms it |
| `tmux has-session -t fix-82` prefix-matches `fix-820` | PRs whose number prefixes a running worker's were starved of attention for as long as it lived | exact session-name matching (`tmux ls -F … \| grep -qx`) |
| `refresh-candidates.sh` `cd`-ed into a scout worktree nothing ever created | on a fresh box the refresh exited 1 every cycle and the backlog silently never refilled | provision the worktree and its venv on first use, or fail loudly |
| **the scout worktree was created once and never updated** — the pass pre-flighted with whatever copy `chore/dispatch-scout` froze at (measured 2026-10-19: **191** commits behind `origin/main`; re-measured 2026-10-20 on a cell: **258** behind, the branch tip still `430ff7cce` from 2026-10-16) | a fix to the gate could not reach the harness that runs it: the cell pre-flighted with a lane-liveness reader whose cmux verb that build no longer has, so **every** candidate came back `INCOMPLETE`, the pass ABORTED `judged 12 / usable 0`, and the cell dispatched nothing behind a log line that read `FAILED rc=1 (transient — retried next cycle)` (agent-infra#2174) | the pass now `git fetch` es `main` into `refs/remotes/origin/main` (destination named, so a mis-mapped `remote.origin.fetch` cannot make a no-op fetch look like currency) and moves the scout to that tip **on every pass**, logging the gate it judged with (`[refresh] gate: <path> cksum=<n>`, plus `unversioned=1` when the gate lives in a tree this pass cannot version); a scout that cannot be refreshed **refuses to judge**, naming the sha and the failed step, with rc=3 (`NOT PROVISIONABLE`: `.git` link that does not resolve, no `origin`, no `main`, no `origin/main` after a fetch, a gate whose bytes are not the ones at the checked-out commit) or rc=1 (`TRANSIENT`: network, uncommitted tracked work, commits not in `origin/main`, an untracked file in the way) — so the loop writes a MERGE-ONLY marker only for the permanent causes, quoting the refusal; `--check` refuses the offline-judgeable causes too, read-only: a scout whose `.git` link does not resolve, a worktree with no `origin`, an UNRELATED history that shares no ancestor with `origin/main` (a fetch cannot connect it), or (when a move is needed) uncommitted tracked work — those as rc=1 with a `TRANSIENT: scout` token, so the two consumers' diagnosis follows the refusal instead of always naming a provisioning defect — plus, for a scout that is its own worktree, a gate that is untracked or edited relative to `HEAD`; `--check` **WARNS** instead of refusing when it holds a count it cannot ATTRIBUTE offline — a SHALLOW checkout whose graph does not connect to the trunk (#2953), and a CONNECTED count in a FULL checkout, which reads identically for local commits and for commits a STALE `refs/remotes/origin/main` has not fetched (#2956) — because the run path fetches before it decides and a false FAIL there refuses to START a cell (`cloud-cell-bringup.sh` `die`s on a non-zero `--check`); remote reachability, a trunk that is not `main`, and that byte test on a NON-worktree scout are deliberately left to nobody: the byte test is skipped on both paths for that shape, whose whole protection is the announced `unversioned=1` (#2217); uncommitted work in the scout is never discarded |
| `install.sh` reported an env-only gate key as present | the daemon silently started without it and the "merge role" install.sh just blessed did not work | only a key *file* is authoritative; env-only is reported as insufficient |
| **`refresh-candidates.sh` hardcoded a tortoise/Python shape** (`uv sync --extra embeddings --extra parity` and tortoise's `tools/collision_preflight.py`) | a cell pointed at a non-Python repo (agent-infra has no `pyproject.toml`) aborted **every** cycle, and because `orch-loop.sh` runs the refresh in a **backgrounded subshell** the non-zero exit could not fail the loop: the controller reported `RUNNING` with `lanes: 0` **forever** — a cell that looks alive and can only merge (agent-infra#1736) | the venv step is skipped only when it is genuinely **not applicable** (no `pyproject.toml`) — a real `uv sync` failure is still fatal, loud, and prints uv's own output; the extras are read from the project; the tool is resolved per repo (own copy, else a `TORTOISE_REPO` checkout) and its absence is a **permanent** `rc=3`; `--check` gives the same verdict read-only so `cloud-cell-supervisor.sh check`/`start` refuse a merge-only repo with the reason; and `orch-loop.sh` now reads the rc — permanent writes a `MERGE-ONLY` marker and stops retrying, transient still retries |
| **the merge-key preflight asked "is there a key?" in four mutually inconsistent ways** | every divergence is a false green on the one check that decides whether a cell signs its reviews: `install.sh` and `cmd_check` tested the key **file** by *size*, and a 1-byte newline — exactly what `echo "$KEY" > file` writes for an unset variable — read as present; `cmd_check` tested the **`keys.env` value** for raw non-emptiness, while the consumer strips whitespace and treats the result as absent; the **precedence was file-first** while the consumer is env-first, so a whitespace-only value shadowed a valid file (its fallback never runs on a non-empty raw value); and the file was read from `$HOME`, which `keys.env` may repoint while the session forces `HOME` back to `$CELL_HOME` after the source | both the file and the value are tested for **normalized content** at every site, the order matches the consumer (env first, the file as its fallback), the file is read from `$CELL_HOME` — the home the session actually uses (`keyfile_has_key` states it explicitly, and the supervisor re-exports `HOME=$CELL_HOME` after sourcing so both agree on every path) — and each of the four cases has a check that a mutation turns red, except that the two HOME guards are now equivalent: with the re-export in place, reading `$HOME` or `$CELL_HOME` gives the same answer, so the behavioural pin is the check that a keys.env `HOME=` cannot change the verdict. |
| Plist rendered with unescaped `sed` replacements | a `&` in a path expanded to the matched placeholder, producing a *valid* plist pointing at wrong paths (so `plutil -lint` cannot catch it) | escape `\`, `&` and `\|` in every substituted value |
| `retired/do-merge.sh` logged `rc=$?` after an unquoted `$(date)` | every merge failure logged as `rc=0` | capture the status first |
| `retired/watch-one.sh` built the fixer prompt from a log the reviewer had not written yet | the fixer always ran against an empty FINDINGS section | build the prompt after the reviewer run |
| the pre-fix sweep logged `#<PR> re-record` even when the concurrency cap suppressed the spawn (`{A\|\|B\|\|C;} \|\| D && echo` parses as `({A\|\|B\|\|C} \|\| D) && echo`) | a stalled drain looked busy | explicit `if/elif` branches |
| **this file's own self-test** re-implemented the fixed logic instead of reading the shipped scripts | it passed on the broken copy, so it pinned nothing | every check now extracts and drives the real classifier, `sess()`, claim block and reaper, or runs `install.sh`; §9/§7 claims corrected |
| `MAX_REVIEW` defaulted to 2 in `orch-loop.sh` but 4 in `install.sh`, the plist it renders, and §4 | running the loop directly (not via the plist) silently halved reviewer concurrency against the documented value; the `${MAX_REVIEW:-4}` fallback was dead code | default is 4 everywhere, and the self-test resolves all 10 limit defaults in both scripts and asserts they agree — including with the limits supplied via the environment, which is how the plist delivers them |
| the live sweep dropped the `CLOSED` guard that `retired/sweep.sh` had, keeping only `MERGED` | a PR listed open that closed in between fell through to `gh pr ready` + `gh pr merge` every cycle and logged `#<PR> merge fail` forever | `case "$PR_ST" in MERGED\|CLOSED) continue ;;` |
| `retired/auto-loop.sh` and `retired/sweep.sh` still carried the fail-open `ai-review-gate` classifier | shipping "the record" with the very bug being fixed invites reuse of it | both annotated in place as retired-with-known-fail-open |
| §3 and §8 admitted cross-box duplication while §5.1b said "one owner per PR" | the invariant was stated more strongly than the code delivers | §5.1b scoped to per-box; §7.2b states the open cross-box gap |
| **a PR branch name was interpolated into the `sh -c` string `tmux new-session` executes** | **arbitrary command execution on the unattended host that holds the merge key.** git permits `'` `;` `$` `` ` `` `&` `\|` `(` `)` `{` `}` `"` `<` `>` `#` in a ref name, so a fork PR on `fix/x';touch${IFS}/tmp/x;#` broke out of the quotes. Reproduced end-to-end before fixing | `safe_ref` allowlist + `check-ref-format`; numeric-only PR ids; and worker args now travel in a file (`--argv`) so no PR-derived value is interpolated at all |
| **the check classifier was a deny-list** (`bad = FAILURE\|ERROR\|CANCELLED\|TIMED_OUT\|ACTION_REQUIRED`) | a conclusion in **neither** list — one GitHub has not documented, or a **null** one — read `PENDING`, and `PENDING` arms the merge (`gh pr merge --auto`): the merge decision failed **open**. At the same time `CANCELLED` was named *red*, so a normally-superseded run (`cancel-in-progress: true`) was routed to `fix-one.sh` or to `gh run rerun` — failing **closed** on a green PR. `fix-one.sh`'s failing-check list named `CANCELLED` too, so such a run burned a capped fixer attempt (agent-infra#1714) | the classifier is an **allow-list with polarity**, the rule `admin-merge.sh` and `record-review.sh` already implement: non-red only for a NAMED conclusion (`success`/`neutral`/`skipped`/`cancelled`/`stale`), in-flight only for a NAMED status, and **everything else RED** — so an unrecognised or null conclusion blocks instead of arming; grouping is per `(app, name)` (newest attempt by `id`) so one app cannot mask another's — ⚠️ but the only call site feeds it `gh pr checks --json name,state,workflow`, which carries neither `id` nor `app`, so the grouping is in force only for a surface that carries them (agent-infra#1733); and an **empty** surface is `NOCHECKS`, never `GREEN`. `fix-one.sh` uses the same allow-list (agent-infra#1714) |
| the claim-file guard added in the first fix round introduced a permanent stall | the controller treated *the existence of* `mergeclaim-<PR>.lock` as "in flight", but only `merge-one.sh` removes it — a SIGKILLed worker or a reboot mid-merge left the PR skipped forever with no fixer and no re-record | `claim_live()` tests the recorded pid with `kill -0` and removes a dead owner's claim |
| 6 self-test checks passed vacuously because an empty extraction did not fail the check | the round-1 vacuity fix was incomplete: checks depending on `sess()`, the claim block or the reaper passed when the shipped script had no such code | `need()` turns a missing extraction into a FAIL |
| **a hung worker held a concurrency slot for 9 hours** | `pi -p` has no timeout and the caps count **tmux sessions**, so a hung reviewer (or a runaway `find /` it spawned) permanently reduced merge throughput while the queue looked busy — three slots were dead weight overnight on 2026-10-12 | portable `run_agent()` wall-clock limit (bash `wait` + watchdog subshell, since macOS ships no `timeout`) plus a `reap_stale_workers()` sweep that kills any worker silent for `STALE_MIN` minutes |
| **only `ai-review-gate` and `python-ci-gate` failures had a remediation path** | a PR red on any *other* required check (`docs`, `test-isolation`, `license-surface`, `legal-e2e`, `pricing-artifact`) was merely logged, so it sat red forever with **no worker at all**. Observed: #8278 carried two new `docs`-lint findings (MD056, an unescaped `\|` in a table row; MD046, fence style — fixed in `f15923b`) and #8193 a new `MD018` finding — both with zero workers for hours. ⛔ **And the name list was itself a tortoise constant (#1764):** on agent-infra a red `pipeline-compliance` matched none of those five, so the fix reappeared there | those checks now route to `fix-one.sh` too — but the arm is now **derived from the repo's own required set** (#1764), so a red required check routes on *any* repo (agent-infra's `pipeline-compliance` included) — capped and parkable like every other fix loop; and `fix-one.sh` fetches the failing check's **log** into the prompt, because it previously only ever read a reviewer comment — for a CI failure there may be no comment at all. ⚠️ **Known residual (agent-infra#1703):** that fetch reads the workflow RUN's `--log-failed` and `tail -80`, so a multi-failed-job run can hand the fixer the wrong job's log; tracked, not fixed here. |

### 7.4b Defects found in the agent-infra#1700 review (fixed here)

| Defect | Impact | Fix |
|---|---|---|
| **`cmd_check` never tested `record-review.sh`, and neither cell script provisioned it (agent-infra#1717)** | `merge-one.sh` executes `$HOME/.pi/agent/scripts/record-review.sh` to mint the signed marker, and a fresh cell has no such file. `cmd_check` printed `CELL CAN RUN A CONTROLLER` anyway (a false PASS on the only question that verdict answers), the cell ran a full fresh-context review — up to `REVIEW_TIMEOUT` = 1800 s, **paid** — and only then hit 127. The pre-fix `exit 3` left no terminal state at all — nothing was recorded and nothing was parked: it returns from the `CLEAN*)` arm, and the `*)` arm that writes the fixer marker is reached only for a non-CLEAN verdict, so the marker was never written on this path either way: the next cycle saw an unmarked `FAILED:ai-review-gate` and spawned another review, **one paid review per cycle, forever** | `cmd_check` probes the runtime dependencies the loop actually invokes — `git`, `python3`, `pi` (`uv` warns, matching `install.sh`) and the recorder path it reads from `$CELL_HOME` — and refuses to print the verdict without them; `start` provisions the recorder from the checkout. The record step is also checked **before** the paid review in `merge-one.sh`, and any of its failures (absent, empty, non-executable, non-regular-file, non-zero rc, an `rc=0` record that posted **no signed marker** into the PR body, or a CLEAN verdict that named no comment) writes the controller's own terminal `state/parked-<PR>` marker at the reviewed head plus a `state/parkreason-<PR>` naming why — and the worker itself refuses to re-review a head it has already parked, so the `chain-<N>`/`fix-<one.sh>` paths that never consult the controller cannot re-pay either. The controller's own park sites (`orch-loop.sh`, conflict/fix/CI caps) write the same `parkreason-<PR>` pair through `park_ctrl()`, so a **controller** park at a moved head never leaves the previous head's reason behind for the exit-5 refusal to misreport. ⚠️ **Residual:** `merge-one.sh`'s own rail cap writes `state/parked-<PR>` directly and no `parkreason-<PR>`; that site `exit 0`s before the exit-5 refusal can print a reason, so it cannot itself misreport — but a human reading `state/parkreason-<PR>` beside a newer marker still can. A later push changes the head and re-arms the PR by construction |

### 7.4c Defects found in the agent-infra#1850 review (fixed here)

Eight of the ten are fail-**open** in a gate whose whole purpose is to refuse: each certifies a busy or
unverifiable issue as free, hands it to a second box, or lets a release run without its fence. (The two
that are not: the silent-release row, which leaves the claim **held**, and the `CLAIM_COMMIT` row, which
is state hygiene.) Pinned
by `test-claims.sh` (I10, I9(5), I9(7)) and `refresh-scout.test.sh` §8(g) (unrecognised status),
§9(iii) (stale-registry dispatch), §10 (fenced + generation-guarded release, the CAPTURE that wires
it, and the no-generation refusal) and §11 (the chain-failure branch). The last three were found in
the later review cycles, precisely by asking what each new assertion would do if the line it protects
were deleted.

| Defect | Impact | Fix |
|---|---|---|
| **the CLEAN arm was a wildcard** (`case $rc in 0) queue;; 1) COLLISION;; *) INCOMPLETE`) | the intended set is {0,1,2}; `*)` silently absorbed everything else, so a **stale** registry (`rc=3`) and an unexecutable `claims.sh` (`rc=127`) both queued the issue — the pre-flight asking its question and then ignoring a "cannot answer" | explicit `0` / `1` / `2`+`*` / `3` arms; anything unrecognised is INCOMPLETE, so no future status widens CLEAN by default |
| **`claim_issue_preflight`'s clock was unguarded** | `date +%s` is a *second* input to the same decision — the `ls-remote` read that proves "no claim ref exists" does not need it, but the lease comparison does. On an unreadable clock `[ "$now" -le "$until" ]` is FALSE (bash prints `integer expression expected`), so a **held** claim's reader fell through to `return 0` — a **false CLEAN** in the one direction the gate exists to prevent | a non-numeric/empty `now` is rc=2 INCOMPLETE, alongside an unreadable registry |
| **the release record was read when the trap FIRED, not when the claim was taken** | the record file is keyed on the **issue**, so a box that re-acquires after its lease lapses overwrites it. The older chain's trap then fenced on the *new* commit — which **is** the ref tip — and deleted the live holder's claim, freeing a busy issue for a peer: the exact duplicate the key exists to prevent | `chain-merge.sh` captures the commit at chain start (`claim_issue_record_commit`) and `claim_issue_release_record` refuses on a generation mismatch, naming it and leaving the newer record intact |
| **a registry too old to take a claim still dispatched** | `refresh-candidates.sh` refused every issue on such a box (`rc=3`) while `orch-loop.sh` acquired anyway, found no `claim_issue_acquire`, and **dispatched unclaimed** — the fail-open half of the same condition, and the collision on two boxes | present-but-stale is now split from genuinely-absent: the loop refuses the dispatch and names the fix; only a **missing** `claims.sh` (pre-registry box) falls through, loudly |
| **release failures were silent** (`>/dev/null 2>&1 && echo`) | a refused or failed release left the claim held for its whole lease (3 h of a free issue) with nothing in the log to say so — and `CLAIM_RESULT` was lost because the helper ran in a subshell | the helper `declare -f`s the function, sources `claims.sh` into the **current** shell, passes the captured commit, and logs the reason on every failure branch |
| **the chain-failure arm released a claim whose LANE was still running** | the lane is spawned *before* the chain in the same loop body, so "no chain will ever run" was true while "nothing is running" was **not**: the release declared an issue this box was actively implementing free, a peer claimed it and duplicated the work, and this box still opened a PR nothing would merge | stop the lane first (exact session match) and release only once it is confirmed gone; if it cannot be stopped, **keep** the claim — the lease expiring it is the safe direction |
| **a chain with NO captured generation still released** | the capture is empty when the handover record was absent at chain start (`orch-loop.sh`'s `claim_issue_record` failed) or `$O/claims.sh` predates the reader. `claim_issue_release_record` treats an empty expectation as "read the record now" — right for `dispatch-merge.sh`, whose release is milliseconds after the write, but WRONG for a trap that can fire **hours** later: the record then holds the newer holder's own commit, which **is** the ref tip, so the stale chain deleted a live claim | `chain-merge.sh` refuses the release when it has no captured generation, names the reason and lets the lease reap it (one lease lost vs duplicated work on two boxes) |
| **`CLAIM_COMMIT` was a per-CYCLE global** (not fail-open — state hygiene) | `claims.sh` reset it only when sourced, so an acquire that failed *before* any push (`rc=2`: unreadable ref, unfetchable claim) left the **previous** issue's commit in it. `orch-loop.sh`'s "rc=2 with a claim commit → record it and try a fenced release" then wrote a handover record for an issue this box never claimed, consumed it, and logged a release that never happened — the fence keeps the registry safe, but the *log* is what an operator reads | cleared at the top of `_claim_acquire_at`, so the value always means "what THIS attempt may have pushed" |
| **a chain RE-RUN by hand captured a generation it never took** | the capture read the handover record, and the same box can hold the same issue twice (its lease lapsed and the loop re-acquired while the old chain still waited). A re-run starts *after* the re-acquire, so it captured the NEWER generation — the one on the ref tip — and its trap deleted the live holder's claim. Both this file's timeout message and `nonblocking-dispatch.sh` invite exactly that re-run | the generation is now **injected by the spawning process** (`dispatch-merge.sh`, in the loop body that wrote the record) and inherited by `chain-merge.sh`, which never re-derives it. A chain started any other way has none and refuses, leaving the claim to its lease |
| **the suite's other two teardowns leased on the OBSERVED tip** | `--force-with-lease=<ref>:<observed>` is a conditional *write*, not an ownership check (it refuses only if the ref moves in the microseconds between the `ls-remote` and the push), so `cleanup_issue_ref` deleted whatever was at `issue-<N>` — reachable with the documented `ISSUE=` override, and with `PR`/`ISSUE` equal. The probe was fixed; these two were not | ownership now comes from the **registry's own lease** (`<id>:<pid>`, and the suite runs all boxes from one process), plus a whitelist of the synthetic lease ids the sections hand-build. A claim this run did not create is left alone and named |

### 7.5 Still open, deliberately not fixed here

> **Eight entries that were here are now FIXED**; all but two have been removed from this list: the
> fail-open reaper when the PR listing fails (agent-infra#1705, tortoise#8519), `checked.txt`
> written before the pre-flight verdict (agent-infra#1716, tortoise#8515), the returning INT/TERM
> trap in `orch-loop.sh` and `merge-one.sh` (agent-infra#1715, tortoise#8516), the controller's
> macOS-only capacity probes (agent-infra#1702, tortoise#8514), the deny-list check classifier in
> `orch-loop.sh` (agent-infra#1714, tortoise#8518), this directory being older than its source
> (agent-infra#1712 — see the provenance note at the top of this file), and
> `cloud-cell-bringup.sh` deleting the pushed gh token only on the success branch
> (agent-infra#1718 — fixed in this branch, independent of the #1712 port), and
> `cmd_check` never testing `record-review.sh` (agent-infra#1717 — fixed in this branch; see §7.4b).
>
> The two that keep a bullet below do so as the *record* of the failure mode, not as open defects:
> agent-infra#1705 (the fail-open reaper) and agent-infra#1712 (this directory's provenance pin) —
> both closed.

- ~~**`can_spawn()` gates on load only, so the memory ceiling does not cover the controller spawn
  sites**~~ (agent-infra#1732 — **FIXED**, this branch). The six spawn sites now AND a memory arm
  (`mem_spawn_ok()`, measured once per cycle by `measure_mem` before the first site) with the load
  arm, refusing at `mem_avail <= MIN_MEM_FREE_MB` and on an UNKNOWN probe. It is recorded here rather
  than deleted because the failure mode is the point: two gates over two populations, the resource
  that actually kills the box consulted on one of them. ✅ The **spawn point** (`spawn-gate.sh`'s
  `run_agent`, and the installed-`pi` shim beside it) was still memory-blind at the time — a
  different population, tracked as agent-infra#2387 and fixed since (`MEM_MIN_AVAIL_MB`).
- **The check classifier's `(app, name)` grouping and its newest-by-`id` selection cannot take effect
  at the call site** (agent-infra#1733). `gh pr checks --json name,state,workflow` carries no `id` and
  no `app`, so the newest attempt is decided by row order, and two non-Actions checks that share a
  name collapse into one bucket — the masking the grouping exists to prevent. §7.4's grouping claim
  holds only for a surface that carries `id`/`app`.

- **`state/` and `wip/` grow without bound.** There is no time- or size-based retention: nothing
  expires `merged-*.done`, `fixcount-*`, `parked-*` or stale `rerun-*`. (`mergeclaim-*.lock` and
  `needsfix-*` are pruned when they are consumed or their owner dies — `merge-one.sh`'s `trap`, the
  controller's `claim_live()`, and the successful-fixer path — so they are bounded by traffic, not by
  time.) Needs a retention rule rather than an ad-hoc `find -mtime`.
- **`[ -z "$WT" ] && { … }` as a script's last statement** makes the exit status that of the
  test. The shipped `fix-one.sh` ends with a positive `echo` so it no longer leaks a non-zero
  status, but the pattern is easy to reintroduce — a `exit 0` at the end of each script would pin it.
- **Worktree reaping.** Every dispatch and every foreign-branch fixer adds a worktree; the box
  carried ~150 by the end of the run. Nothing removes them after their PR merges.
- **A persistently-colliding issue can consume the whole refresh window (agent-infra#1729).**
  `refresh-candidates.sh` spends its pre-flight budget *before* it reads the verdict, and since
  agent-infra#1716 a `COLLISION`/no-verdict pre-flight writes no `checked.txt` — so while the first
  `LIMIT` pool entries keep colliding, the entries behind them are never pre-flighted and the
  backlog silently stops refilling (the log still reports a normal `checked N; backlog now M`).
  Faithful to upstream tortoise#8515, not a porting defect; bounded by `LIMIT` (6 from the loop).
- **The fixer's CI-log fetch (agent-infra#1703).** `fix-one.sh` reads the workflow run's
  `--log-failed | tail -80` rather than the failed *job's* log, so a multi-failed-job run can feed
  the fixer the wrong check's output. Raised as a P1 in the tortoise#8298 review and never applied.
- **The capacity gate was SOURCE-ONLY (agent-infra#1884) — the spawn point now owns it.** The load
  gate was a library a caller had to SOURCE, so the control was exactly as strong as the weakest
  caller, and a caller that omitted it was not merely ungated but INVISIBLE: no refusal, no log line,
  no count. Measured 2026-10-16: the orchestrator started three lanes from
  `tmux new-session -d -s <name> "… pi -p …"`, no `lane.sh`, so `MAX_LOAD` was never read — on a box
  at load 258 on 10 cores against its own ceiling of 100. **✔ FIXED** — `spawn-gate.sh` is also an
  executable installed as `$HOME/.pi/agent/bin/pi` (first on PATH), so every `pi` resolves the gate; a
  refusal names the reading/ceiling/item/caller (or, for memory, the reading/floor/item/caller — #2387), is
  counted in `~/.pi/agent/state/spawn-gate.tsv`, and exits 76 for load or 72 for memory (translated to the
  callers' 75 / 73). Named residuals: an invocation that bypasses PATH
  (absolute path, `env -i`, a `PATH` reset) is not gated — that is the operator's documented rescue,
  and `MAX_LOAD` stays the operator's own tunable — and the **`task`/sub-agent dispatch does not pass
  through PATH at all** (`getPiInvocation` spawns `process.execPath` + the entry script so a truncated
  PATH cannot cause ENOENT), so a `task` child is a SECOND spawn point this gate does not cover
  (agent-infra#1920).
- **The runner-label gate reports success on values it never read (agent-infra#1704).** In
  `ci_runner_gate.sh`, an unreadable queue count falls through to "healthy" (the integer test
  errors and the `||` chain reads that as false) and `set_labels()` reports success when the runner
  enumeration fails (the loop runs zero times and `[ "$fail" -eq 0 ]` succeeds). Both are false
  PASSes on a gate that changes runner labels.
  **✔ FIXED in agent-infra** — both now return 2 (could-not-measure), name the failure, and leave the
  state file and the notification untouched; pinned by `scripts/ci_runner_gate.test.sh` (a bash shard
  in both CI lanes), which is red on the pre-fix tree.
- **The reaper fails open when the PR listing fails (agent-infra#1705).** `refresh-candidates.sh`
  writes an empty `.pr_brs` on a failed listing, so `has_pr` is false for every issue and PR-bearing
  issues are un-blacklisted and re-dispatched. Same class as the `open_pr_count()` fail-closed fix
  in §7.4, in a file that fix did not reach.
- **`dispatch-merge.sh` interpolates `$REPO`/`$OR` unguarded (agent-infra#1710).** Both are built into
  a tmux `sh -c` lane/chain command with no metacharacter guard — the class closed for `$O` in
  `orch-loop.sh` and for six values in `cloud-cell-supervisor.sh`. A `'` in either closes the quoted
  span; separately, a lane that dies instantly is still logged as a successful spawn.
- **The merge key reaches the controller but not the merge workers (agent-infra#1711).** The workers
  are spawned through a second tmux boundary, and a tmux session is served from the SERVER's
  environment, so with a pre-existing server a keys.env key is reported present by `cmd_check` while
  every merge runs keyless (a false PASS; `record-review.sh` then posts an UNSIGNED marker). The
  same boundary also drops `$O`, so under a non-default `$O` the workers write `state/` the
  controller never reads — recorded with the measurements on that issue.
- **This directory was older than its source (agent-infra#1712) — ported, and now pinned.** Seven
  commits merged on tortoise `main` after the copy was taken (2026-10-13 10:50Z, `eda7df136`); all
  seven are ported here, listed in the provenance note at the top. `port-provenance.txt` pins every
  file's tortoise blob hash at that sync point and `check-port-drift.sh` fails if the tortoise tree
  moves again. tortoise's `fix/8468-closure-linkage` branch rewrote this same directory (P0 bypass,
  `.prio`, `merged-not-closed.sh`, lane brief); this PR ports it, minus the P0 bypass, which main's
  unconditional drain rule supersedes.
- **A keys.env with a top-level `exit` disables the supervisor silently (agent-infra#1713).** The
  file is sourced in the supervisor's own shell, so `exit`/`exec` ends the script: `start` returns 0
  having created no session.
- **`ci_runner_gate.sh` is versioned here but wired to nothing (agent-infra#1719).** No
  `templates/launchd/` job renders it and `pi-bootstrap/setup.sh`'s farm lists omit it, so this box
  still executes a hand-made duplicate at `~/.pi/agent/scripts/` — a fix here never reaches the copy
  that runs — and a second box has no fallback gate at all.
  **✔ FIXED in agent-infra** — `templates/launchd/com.tortoise.ci-runner-gate.plist` renders the job
  under the label the hand-made duplicate already used (so the installer converges that machine
  rather than stranding a duplicate), and `pi-bootstrap/setup.sh` (fleet_srcs) farms the script to
  the path the plist executes.
- **Two worker launch paths still spawn ungated (agent-infra#1720, partly fixed).** `merge-one.sh`'s
own `run_agent` (reached by `chain-<N>` — the first-review path for every own-lane PR — and by
  `fix-one.sh`) and `cloud-cell-bringup.sh:278` read no `MAX_LOAD`. `lane.sh`, `fix-one.sh` and
  (through it) `adopt-fix.sh` now call the shared `run_agent()` in `spawn-gate.sh`, which is what this
  entry used to list as ungated; both residuals are asserted BY NAME in `spawn-gate.test.sh:125-140`
  (§9).

---

## 8. Measured results

Branch-signature proxy: this box opens `*-tm` / `*-cap` / `*-night` / `*-evening` branches;
everything else in these counts is a peer box. Attribution by branch name is a proxy, not a
certificate — but the split is unambiguous.

| Window | This box | Peer | Notes |
|---|---|---|---|
| 2026-10-10 → 2026-10-12 (48 h) | **94 merged** | 41 merged | |
| 2026-10-11T04Z → 2026-10-12T05Z (24 h) | 51 merged | 27 merged | hour-by-hour below |
| Peak hour (2026-10-11T18Z) | **8 merged** | 0 | 8 PRs in 60 minutes |
| The 2026-10-10T23:45Z → 2026-10-11T21:22Z run | 77 → **99 merged** | — | this box's own handover record |

Hourly histogram (00:00Z–23:00Z on 2026-10-11, merged / this-box):

```text
04: 1/1   05: 4/3   06: 3/2   07: 5/5   09: 3/3   10: 3/2   11: 3/3
13: 2/1   14: 3/2   15: 4/2   16: 6/5   17: 7/5   18: 8/8   19: 3/3
20: 3/1   21: 3/1   22: 5/4   23: 2/1
```

Observed steady state on the original 8 GB host: 15 concurrent workers (4 lanes + 4 chains + 3 fixers +
4 reviewers), load 7–18, swap 588 M–832 M free, dispatch throttled by the swap gate.

**Honest caveat on the comparison.** Two boxes running this harness against one repo
duplicate work unless they coordinate: both may pick the same issue, and both run the merge
sweep over the *same* PR queue. A large part of the throughput above is the harness keeping
a box saturated for hours with no human, plus the box holding the merge key — not an
algorithmic advantage. The claim worth evaluating is *utilisation*, not *efficiency per PR*.

---

## 9. What is shipped

**Live** (reachable from `orch-loop.sh`):

| Script | Role |
|---|---|
| `orch-loop.sh` | the controller: merge sweep → capacity-gated dispatch → backlog refresh |
| `claims.sh` | cross-box claim registry: `refs/claims/<PR>-<head-sha12>` for PRs and `refs/claims/issue-<N>` for issues (agent-infra#1850), same CAS, lease-as-data and `--force-with-lease` fencing. Sourced by `orch-loop.sh`, `refresh-candidates.sh`, `chain-merge.sh`, `dispatch-merge.sh`, `merge-one.sh` and `fix-one.sh` |
| `repo-authority.sh` | **the per-repo merge contract** (agent-infra#1764): reads THIS repo's required status checks and derives whether the review gate applies to it, so the controller no longer enforces tortoise's check names on every repo. Fail-closed — an unreadable or unrepresentable set refuses. Sourced by `orch-loop.sh` and `merge-one.sh` |
| `spawn-gate.sh` | the load, memory, disk and land gate (`disk_free_mb`/`disk_ok` `:200-243`, `mem_avail_mb` `:334`, `mem_gate_verdict` `:366`, `can_spawn` `:440`) plus the ONE `run_agent()` (`:781`) used by `lane.sh` and `fix-one.sh`, so a `lane`/`fix` worker started by hand is gated exactly like one the controller spawned. ⚠️ Line numbers drift — search the function names, not the numbers. ⛔ Not every spawn goes through it: `merge-one.sh` defines its own `run_agent` (`:74`, called `:461`) for the reviewer, and `cloud-cell-bringup.sh:278` invokes `pi -p` with no gate at all (`agent-infra#1720`). Both residuals are asserted **by name** in `spawn-gate.test.sh:125-140`, whose census is an EQUALITY over `scripts/` — so a new ungated invoker fails the suite instead of arriving unannounced, within that census's three declared limits (`spawn-gate.test.sh:98-106`) |
| `dispatch-merge.sh` | creates the worktree and starts the `lane-*` + `chain-*` pair for an issue |
| `lane.sh` | the implementation worker (prompt template included). Since agent-infra#2148 it hard-requires `reviewer-preflight.sh`, prints the reviewer requirement once **before** any work, and splices the reviewer step into the generated brief — the requirement is no longer discovered by being refused at the rail. Since agent-infra#2258 it ALSO splices the canonical `RESEARCH FIRST` block (from `brief-gate.sh --section lane`) and refuses (78) if the brief it just generated fails the validator, so a brief that lost the contract cannot reach a lane |
| `brief-gate.sh` | the RESEARCH contract, enforced at the dispatch seam (agent-infra#2258): a brief must carry a `RESEARCH FIRST` section (`INTERNAL:` + `EXTERNAL:` + a `RUNG:`/tool line) and a `CONTRADICTION TEST:` line, or the dispatch is REFUSED with **80** — nothing consumed — by a message that names every missing element and prints the block to paste. `--check <file\|-> [role]` · `--section [role]` (the ONE source of the block every generated brief splices and `templates/LANE-BRIEF.md` copies) · `--missing` · `--line`. Executed by `spawn-gate.sh::run_agent`, `lane.sh`, `fix-one.sh`, `merge-one.sh`, `nonblocking-dispatch.sh`, `orch-send.sh`, `safe-send.sh` and `pr-doctor.py`; `0` pass / `80` refused / `78` cannot-verify (missing, empty, unknown role, or an unresolvable validator — never a pass). Presence and shape only: it cannot judge the research itself, and its own refusal says so |
| `reviewer-preflight.sh` | the reviewer requirement, disclosed up front (agent-infra#2148): `reviewer_preflight_line` / `reviewer_brief_section` for the three audiences (`self` = the lane lands through the rail; `harness` = a worker that pushes code while `merge-one.sh` mints the attestation; `reviewer` = merge-one.sh's own reviewer session, which posts the verdict comment and must not push, record or merge — no brief section, by design). The `self` line also names the override for a launcher that exports no `KIND` ("if your brief says you have no `task` tool, that overrides this") — the content-repo copy of `lane.sh` is in that state today (tortoise#8432). Sourced by `lane.sh`; also `--line`/`--brief`. Its wording is drift-pinned against the pi side (`extensions/shared/reviewer-preflight.ts`) and carried by `templates/LANE-BRIEF.md` |
| `chain-merge.sh` | waits for the lane's PR **and its merge-phase verdict** (zero GitHub calls), then runs the merge chain if the lane did not merge it — and exits at once, releasing its issue claim, when the lane recorded a capacity refusal (agent-infra#1909) |
| `lane-merge.sh` | **the lane's bounded merge loop** (#2029): wait for its own checks → fix rounds (cap 3, enforced here) → launch the harness chain detached → `--watch`. Emits `MERGED` / `FIX_REQUIRED` / `FIX_CONFLICT` / `BLOCKED_ATTESTATION` / `BLOCKED_ATTEMPTS` / `BLOCKED`, and posts the handoff comment |
| `merge-rate.sh` | the before/after measurement (#2029): lane END states (`PR_OPENED` vs `MERGED`) from durable artifacts only — zero GitHub calls. `--hours`, `--json` |
| `merge-one.sh` | fresh review → signed record → wait green → merge; marks `needsfix-*` for a verdict with findings, `needsreview-*` for no usable verdict (#2132) |
| `fix-one.sh` | fixes a reviewer's findings, pushes, re-runs the merge chain |
| `refresh-candidates.sh` | pre-flights issues (collision check) into the backlog |
| `deploy-harness.sh` | **the supported manual redeploy path** (§4.1) — copies every file the SOURCE ships (recursively), verifies each byte against its source, and emits success/failure from its own copy ledger. Exit `0` = deployed and verified, `1` = copy/verify failed, `78` = refused before touching the target. Refuses a truncated inventory, a source symlink, a source/target overlap, and a source missing any of the five identity anchors. Writes `$O/.deploy-ledger.tsv`. Not part of the loop, and it never restarts the controller |
| `deploy-harness.test.sh` | the agent-infra#2041 contract — the measured false PASS (an absent source against a target pre-seeded with 30 scripts), partial-is-not-success, verification-not-the-copy decides, a truncated inventory, a stale-but-real harness, source symlinks, a self-deploy, the documented `--repo` + `$O/bg/notify.sh` call shape, destination symlinks, the ledger shape, the executable bit, and the stale identity record. Hermetic (scratch sources/runtimes, notifier and `cp` stubs), a CI shard |
| `capacity.sh` | **MEASURED cross-box placement** (2026-10-21): `cap_probe_local` (load-per-CPU, lanes, free disk, free memory, with the epoch), `cap_publish`/`cap_read_fleet` (one `refs/boxes/<host>/<reading>` per box on the shared origin, read with ONE `ls-remote`), and `cap_place` — the least-loaded ELIGIBLE box, with an 8.00 load-per-cpu ceiling (refuse), a 4.00 prefer-elsewhere line (which is what stops a healthy fleet standing down for a peer that is 1% idler), disk/memory floors, and a REFUSAL that names the bound it hit. An unreadable, absent or stale box is never eligible; with no eligible box the dispatch is refused, never placed blind. `lanes` is REPORTED and is not a ceiling (owner ruling 2026-10-17: capacity, not lane count). Sourced by `orch-loop.sh`, also runnable: `bash capacity.sh probe`. See `docs/ops/fleet-capacity.md` |
| `cycle-record.sh` | **the self-dispatch proof** (2026-10-21): one record per cycle (`start`, `selected`, `dispatched`, `nothing=`, `placement=`, `bound=`) and the verdict over the newest one — `HEALTHY` younger than TWO of the box's own cycles, `DEGRADED` older, `ABSENT`/`UNREADABLE` rc 2. Read by `bin/harness status`; a record COUNT is never freshness. Written by `orch-loop.sh`, so the writer and the reader are one module |
| `repo-authority.sh` — the LANDING READ | **can this box land anything at all?** (agent-infra#2320, measured 2026-10-22): `gh_chain_read` (does the gh chain reach a REAL binary — `AGENT_GH_REAL` first, then a PATH walk mirroring `find_real_gh`, confirmed by ONE `--version` probe; a chain that cannot land is `CANNOT-REACH-REAL-GH`, naming the layer identified statically as a wrapper/shim — or, when the refusing candidate is an UNMARKED wrapper that had to be PROBED, quoting that wrapper's own words verbatim; a probed refusal STOPS the walk), `merge_contract_read` (`required_checks` — an EMPTY read is `UNREADABLE`, never "requires nothing"; `why=` separates that from a chain that could not ASK), and `ensure_agent_gh_real` (export a DISCOVERED **compiled binary** as the pin — `_gh_is_binary`, magic bytes, so a script can never be pinned because that re-enters the chain, #2266). Rendered by `bin/harness status` as its own dimension beside the cycle verdict — a landing blocker is NOT a load/capacity `bound=` and does NOT change the exit code |
| `landing-read.test.sh` | the #2320 contract, driven over stub PATHs: a shim-only PATH is `CANNOT-REACH-REAL-GH` with no load claim and no readable contract; a self-resolving wrapper carries the depth-guard message verbatim; a REFUSING candidate ENDS the walk (a healthy gh behind it does not turn it into an `OK`); a real gh + a non-empty protection read is `OK` with the resolved path printed; an EMPTY read is `UNREADABLE why=empty_or_unreadable`, and a chain that cannot ASK is `UNREADABLE why=no_real_gh` — the machine surface carries the token; load and landing are distinguished in both directions; a wrapper is never exported as `AGENT_GH_REAL`, and an INHERITED pin is probed before it is honoured (`/usr/bin/false` is replaced); the probe is BOUNDED with neither `timeout` nor `gtimeout` on PATH (the macOS shape). Two MUTATION controls (the read deleted → §1 RED; the empty contract made a pass → §5 RED). Hermetic: stub gh, `OR` pinned, `AGENT_GH_REAL` cleared, no network, no repo. A CI shard |
| `pi-done-not-exited.py` | **a finished lane's `pi` that never exited** (agent-infra#2163): a lane's reader treats a missing `<tag>.rc` as RUNNING, and a print-mode `pi` whose turn ended can sit for hours with its launcher blocked in `wait`. Classifies every bare `pi` from its OWN evidence — the canon's turn boundary (`liveness.turn_from_jsonl`; an abstention authorises nothing), an exclusively-held log whose last line is a SUCCESSFUL `[reflect-hook]` completion (a `Failed:` hook, a shared log and an `EXIT rc=`-reused log each authorise nothing), a frozen CPU over a sampled window, and launcher ownership in two named rungs (`tag`: the launcher names the `TAG` in the process's environ — as a whole argument on its OWN ARGV, the shipped `lane.sh <N>` / `nonblocking-dispatch.sh <NAME>` shape, or by assigning it, writing `<tag>.rc`, or redirecting into the log this process holds; `launcher`: no TAG, but the launcher redirects into that log — a TAG neither ties is `weak-owner`, report-only). It also requires PRINT MODE in the launcher's text (`pi -p`/`--print`/`run_agent`): an interactive agent at a prompt also reaches turn-ended and frozen CPU, and is never signalled — and `--apply` SIGTERMs ONLY that class, re-verifying identity, ancestry, children and the liveness channels per target immediately before each signal. `HUNG` (turn open), `LIVE`, `KEEP-HUMAN` and `UNATTRIBUTABLE` (named refusals) are never touched. Linux-only (`/proc`); dry run by default; exit 3 when a read did not happen or every candidate abstained, and exit 4 when DONE rows were found but `--authorise-hostless` was not passed (a cell lane's chain is `hostless`, which agent-infra#2391 — an OPEN owner reopen of #1207/#1297 option A — keeps report-only). Not part of the loop — nothing schedules it yet (§6.5.1). See `docs/ops/fleet-liveness.md` |
| `selftest.sh` | offline checks; each one drives the shipped code. Not part of the loop |
| `install.sh` / `launchd-cycle.sh` | the installer, and the ONE implementation of stop/enable/(re)start/verify for the launchd job (§4). A plain `install.sh` never touches a loaded job; `--start`/`--restart` harness the loop and PROVE it started. The library never writes a persistent disable and never mutates a job that was not loaded from this plist |
| `install-launchd-durability.test.sh` | the agent-infra#1975 contract — no persistent-disable verb in code or in a copyable README command, `bootstrap`→`load` fallback, the ownership guard, and "not running AND (disabled OR exit 0)" as a FAILURE. Hermetic (`launchctl` stub first on `PATH`, throwaway `$HOME`/`$O`), and a CI shard via `scripts/run-bash-shards.sh` |
| `pr-review-order.test.sh` | **agent-infra#2971 — the answer to `NEEDS-REVIEW` is a REVIEW ORDER.** The PR path printed the correct remedy (`NEEDS-REVIEW … the remedy is another review`) and then spawned `merge-<PR>` — the same tag a LANDING worker carries — so a pass that did the right thing read as a re-run of the thing that had just been refused, for ever. Driven against the SHIPPED fragments: a `NEEDS-REVIEW` head with capacity dispatches `review-<PR>` and NO `merge-10213`, the order is recorded on the `(PR, head)` key it was ordered for, and its spawn carries `REV_PAID=1`; the `(PR, head)` review budget is ONE record (`state/reviewdisp-<PR>`) spent by the controller's dispatch AND by `merge-one.sh`'s verdict-less run — counted once, never twice — and a reviewer run that ends WITHOUT a `CLEAN`/`ISSUES` marker is a COUNTED failed attempt carrying its exit code and last line instead of leaving a log that simply stops (the 2026-10-28 silence at 23:30). Mutation: put the spawn tag back to `merge-$PR` and D1 reddens naming `merge-10213`. Hermetic (stub cmux/gh, no network, no tmux) |
| `test-gates.sh` | the `mp_reason` dispatch-gate rule table, extracted from the shipped `orch-loop.sh`; the repo-authority contract and the rail branch driven from `merge-one.sh`; and (agent-infra#1952) the **landing claim** — a second box refused the same PR, three independent keys, fenced release, release frees the PR, non-vacuity, and `merge-one.sh`'s acquire-before-the-review ordering. Hermetic. Not part of the loop |
| `test-claims.sh` | the PR **and issue** claim CAS against live origin from two scratch repos (`git init` + `remote add`, not clones; random keys per run so concurrent runs cannot collide). Not the cross-box proof (one machine), but red on a defeated CAS. Not part of the loop |
| `claim-exclusion.test.sh` | **the measurement:** N processes released at a barrier against a real (bare) origin, per operation class, answering *does a duplicate holder get refused*. Prints the table §7.2d records; hermetic, a CI shard |
| `lane-merge.test.sh` | #2029 **the lane's own merge loop under test**, offline with a stub `gh` and a stub chain: the bounded wait (a queued run is never green), the red NAMES published for the handoff, the (app, name) grouping that keeps one workflow from masking another, the **round cap enforced where the fix is emitted** (a pre-check cannot verify the last allowed fix), the exit-code contract (`10/11/12/13/14/15/0`) with the **one blocker a lane cannot supply** on its own code, the detach + refusal to select the merge authority from a lane's own branch — **including the hand-off's printed remedy, which must hand over that same trusted checkout or refuse** — the derived supervision budget that leaves the lane its implementation time, and the failed-read guard (an unreadable PR is a WAIT, never an attestation). Hermetic, a CI shard |
| `merge-rate.test.sh` | #2029 **the measurement's own honesty:** last status token per lane wins, `ALREADY_FIXED`/`OUT-OF-REPO` are `other` and never "an opened PR", a lane with no status line is `unknown` and printed, an empty population is `n/a` (never 0% or 100%), the PR-keyed and issue-keyed verdicts are ONE outcome, `lane-merge-*.log` is not a lane, and a merge attested only by `state/merged-<PR>.done` is attributed and reported as an inference — **only for a lane whose own deliverable named that PR and whose own last word was `PR_OPENED`/`UNKNOWN`** (a `BLOCKED*` lane is never upgraded, and a mid-transcript mention of another lane's PR is not this lane's). Hermetic, a CI shard |
| `chain-merge-verdict.test.sh` | #2029 **the controller's chain yields to the lane:** no phase marker → review now (a lane that predates the change is not delayed), a current `FIX_REQUIRED` → keep waiting (reviewing early strands the attestation), a `MERGED` marker → exit 0 without reviewing, a current `BLOCKED_*` → review, a STALE verdict ignored by mtime. Drives the shipped `chain-merge.sh`. Hermetic, a CI shard |
| `gh-limit.test.sh` | #1988 the layer UNDER every gh call: one call in flight per box — the retry path AND the `/rate_limit` probe (measured from the stub's own timestamps, with an unserialised control that MUST overlap), the documented backoff order (`retry-after` → the bucket's reset → ≥60s doubling, 4 attempts, then a loud failure), the failing bucket NAMED, `>= 1s` between mutations, conditional REST (`if-none-match` → a 304 replayed byte-exactly from a bounded cache), and the shim surviving the `/opt/homebrew` PATH prepend in every gh-calling script. **Plus #2243's coalescing**: 5 identical concurrent reads ⇒ 1 load (byte-identical bodies carrying the first call's answer), 5 different reads ⇒ 5 loads still serialised, a failing leader's error reaching every follower (none seeing success), 2 concurrent mutations ⇒ 2 loads, a waiter past the bound getting `busy` (75) with the holder's age, a stale answer served during a refresh carrying its age, and a dead leader's key taken over with no orphan claim. #2137 ACCOUNT scope: the share is the account budget ÷ declared fleet (N=1,2,4), enforced on the wire; an `unclassified` refusal is classified, waits the ≥60s curve and records a ~60 s window instead of the 43-minute reset; a stale marker is revalidated with one exempt `/rate_limit` read, cleared and annotated; a marker older than the window it recorded (or than `MARKER_MAX_AGE`) blocks nothing and spends no probe; a genuinely exhausted bucket still waits for its reset. Fake clock, stub gh, hermetic, a CI shard |
| `gh-rest.test.sh` | the `gh` REST adapter's argv-to-argv **TRANSLATION**, offline against a stub `gh`: `pr list --head` must not widen to the newest open PR and `pr comment` must print a URL (both shipped green once, as P0s, when nothing asserted them). Hermetic, a CI shard |
| `test-crossbox.sh` | drives the real `merge-one.sh` claim acquire + trap release with `gh` stubbed. Not part of the loop |
| `refresh-scout.test.sh` | the agent-infra#1736 contract — repo-aware scout provisioning, per-repo tool resolution, the permanent/transient refresh split — plus the agent-infra#1850 issue-claim pre-flight verdict table (CLEAN/COLLISION/INCOMPLETE/NOT PROVISIONABLE/unrecognised), the dispatch-side claim, and the fenced + generation-guarded release. Also the agent-infra#1729 pass budget: a blocked pool HEAD does not consume the window, the collision ledger defers (never drops) a held candidate, and ONLY a COLLISION is recorded — a DEGRADED answer never is. Not part of the loop |
| `refresh-quota.test.sh` | the per-pass API **spend** contract (agent-infra#2022 / #1736 follow-up): the board cache is enabled under the TOOL's own seam (`COLLISION_PREFLIGHT_BOARD_CACHE`, not the legacy no-op name the tool treats as a caller-named-cache attack), so one pass rebuilds the board once instead of once per candidate; a pass that can only afford SOME of its window judges those completely, queues work and NAMES the stop; a pass that can afford none refuses TRANSIENTLY — after the `dispatched.txt` reaper has run — rather than reporting an empty backlog. Charges a modeled core budget from a stub `gh`, so it needs no network. A CI shard |
| `check-port-drift.sh` | gates the tortoise-side removal: fails if the tortoise harness moved past the pinned sync point (`port-provenance.txt`). Not part of the loop |
| `lane-reap.sh` | the EVIDENCE census (`count` → `lanes=<live>/<total> zombie=<n>`, §6.5.1b) and the conservative finished-lane process reaper (zero CPU over a sampled window + positive fleet ancestry + a stale log the lane's OWN `pi` holds, dry run by default). ONE population PREDICATE for both (a `pi` tree whose own `pi`, or a pipe-fed `tee` beside it, holds a fleet log open), so the `[cap]` number and the reaper cannot disagree about what a lane IS; the two audiences differ only in their filters — `count` excludes `fix-`/`merge-`/`chain-` workers (they are `workers=`) and applies no ancestry gate, while `reap` refuses a human/unknown-ancestry tree BEFORE it is counted. A census whose descriptors cannot be read at all is `lanes=?/?` + exit 3, never `0/0`. Called by `orch-loop.sh` and the doctor's `reap` role |
| `lane-exec.sh` | the wrapper-free launcher (#2163): `exec pi …`, so a finished lane leaves NO process behind. The canonical replacement for an ad-hoc `bash -c '… nohup pi … &'`; the persistent-wrapper case is `lane.sh`, which `wait`s and exits on child exit |
| `lane-reap.test.sh` | the #2163 contract, hermetic (fake `ps`/`kill`/`sleep`, fake `/proc`, pinned clock): a LIVE lane is never signalled, a FINISHED one always is (children first, TERM then KILL), an unresolvable log is REFUSED, a deleted log is judged by the 12h bound only, a human ancestor refuses (and so does an `unknown` or truncated ancestry), a SIBLING's log never judges the lane, a working subtree is spared, the census counts by evidence and abstains on a blind box, an abstaining pass counts itself and exits 3, and an unreadable table is `?`/exit 3. A CI shard |
| `cloud-cell-doctor.sh` | the cell's scheduled roles — `reap` / `doctor` / `merge` / `hygiene` / `status` (§6.5.7). Launched as tmux `cell-doctor` (`$DOCTOR_SESSION`) by `cloud-cell-supervisor.sh start`; `merge` EXECUTES `scripts/admin-merge.sh` and never re-implements it |
| `cloud-cell-doctor.test.sh` | #1989: drives the shipped doctor and the supervisor's role verbs against stubbed tmux/ps/rail — a lane whose child is still writing is NOT reaped, an attached/human-tty lane is NOT touched, the rail is gated on a clean attestation at the head, a refusal is recorded and not retried at the same head, `status` FAILS a started cell whose roles never ran, a DEAD loop is never reported `WAITING` (`DEAD` in every row, non-zero), and an unverifiable loop record abstains as `UNKNOWN` with exit 3 (#2306). A CI shard |
| `cloud-cell-doctor.hardening.test.sh` | #1989, the HARDENING half (a separate suite, not a fork of the one above): every read the doctor acts on must be classified, so an unreadable session list / client list / ancestry walk / pane read / log mtime / process table / open-PR read / review record is cannot-verify rather than an answer, while a benign non-answer (a fresh box with no server, a lane that ended between reads) is not; an action that did not take (a refused or unverifiable kill, cpu that went DOWN) is never a reap; the rail's rc classifier is a PREDICATE (`124..127`, any `128+N`); and a REHEARSAL IS NOT A VERDICT — `--dry-run` keeps the worse of (stored verdict, its own) and says in the record that it was a rehearsal, on every role. A CI shard |
| `cloud-cell-record-dep.test.sh` | #1717: drives `cloud-cell-supervisor.sh check/start` and `merge-one.sh` against a stubbed toolchain — the recorder is a checked, provisioned dependency, and a record failure parks. Registered in `scripts/run-bash-shards.sh`, so both CI lanes run it |
| `check-deployed-drift.sh` | answers whether the DEPLOYED `$O` matches the repo: the recorded commit against the live ref (`merge-base --is-ancestor`, never a commit count), the recorded payload hash against the deployed bytes, and every repo-shipped `*.sh` blob against its `$O` copy. Exit 0 match / 1 drift / **2 UNKNOWN — never a pass** (agent-infra#1745). Not part of the loop |
| `merge-reminder.py` | the fleet's **10-minute merge reminder, with a narrow evidence-gated ACTUATOR arm** (#2603, §6.5.9). Answers three questions — closest to landing, merged-but-not-LIVE, and one red shared across PRs — and on a complete-evidence GO dispatches `scripts/admin-merge.sh <PR> --repo …` (never a merge of its own, never an override). Its emitted line carries the MEASURED readings (`reds=0 in-flight=21 attested@head=no claim=none rail=idle`); an unread value is `UNREADABLE` and dispatches nothing. Cost-bounded: `rate_limit` FIRST, ≤9 metered REST calls (the 9th is the per-candidate mergeability read, which the LIST endpoint does not compute), a thin budget SKIPS the cycle by name. Runs from launchd (macOS) or a systemd-user/cron timer (Linux): `--install-timer` / `--uninstall-timer`. Not part of the loop |
| `box-status.sh` | ONE box's harness identity (`harness: <sha> [current|behind|ahead|diverged|unknown] source=<pin|stamp|none>`), the stamp and pin beside it, `controller: RUNNING(pid …)|STOPPED`, **`running: <sha12>|NONE|UNREADABLE|MIXED`** — the commit the RUNNING controller's own argv resolves to, which is what "activated" means (`harness-refresh.sh` calls the pin-ahead-of-process state `restart-pending`; the pin alone certified a box as `deployed AND activated` while it executed pre-fix code, #2680) — the repo it compares against is resolved `HARNESS_REPO`-first / the payload's own checkout / this script's own checkout / the conventional `$HOME/orchestrator` — and every candidate must CARRY the harness — `scripts/orchestrator-harness/box-status.sh` **tracked as a regular file at exactly that path by the candidate's own repo** (`git ls-files -s`: index mode `100644`/`100755` **and** the recorded path equal to the marker, so a prefix match is not the file), which skips a checkout that is merely *some* repo, one that only reaches the harness through the gitignored `scripts -> $AGENT_INFRA_PATH/scripts` pointer every tortoise/eldato checkout carries (#9475), one that tracks a SYMLINK (mode `120000`) or a GITLINK (`160000`) at the marker path and so ships no harness bytes, and one whose marker path is a DIRECTORY (the index records a nested file) — none of them can be read as the harness repo (#2679); a subdirectory candidate is ACCEPTED, the same as `harness_repo_of()` (a literal-path test refused what `harness-refresh.sh` and `check-deployed-drift.sh` accept), and a refused candidate is NAMED on `ref:` (`ref: UNRESOLVED (--repo: … has NO INDEX ENTRY for …)` / `(… not a TRACKED REGULAR FILE there (mode …))` / `(… records … instead …)`) instead of leaving the line out, because an absent line reads as "no opinion" when the answer is "compared against nothing" — and `roles: idle|busy:<role>(pid=…,age=…)` from the doctor's own role locks. Exit 2 = CANNOT VERIFY — an unanswered identity is never `current`. This is the deploy arm's evidence, so it refuses to answer from an unread process table — and it reads the controller's argv as NUL-separated fields (`/proc/<pid>/cmdline`, `mapfile -d ''`), not a whitespace split, because a harness path may contain a space and a split one answered `running: UNREADABLE` for an ACTIVATED box; the `ps` fallback has no NUL-preserving form, so a space there yields UNREADABLE rather than a wrong tree, never a guess. `MIXED` is driven directly by two real trees in the suite, not only reached through a stub |
| `merge-reminder.test.sh` | #2603: drives the shipped reminder through EVERY gate with a fixture reviews dir, a stub `gh`/`ps`/rail and a REAL `refs/claims/*` ref — attested+quiet dispatches; `attested=stale`, `in-flight=3`, `reds=1`, a held claim, a live rail and a `mergeable=null` each refuse BY NAME and dispatch nothing; `rate_limit` is the FIRST call and a thin budget spends nothing else; the grouping rule is pinned both ways (a re-run to success is not red; a same-named job in another workflow cannot mask a red); the deploy arm refuses a mid-flight role pass and otherwise dispatches the box's own verb and VERIFIES it by artifact; two MUTANTS prove the gates are live. A CI shard |
| `worker-supply.sh` | **the SUPPLY half of the repair pool** (agent-infra#2700, §"The SUPPLY half"): walks the ORDER POPULATION (`$O/bg/prd-*.started`, the dispatcher's own acceptance record), asks the HARNESS for each order's liveness (`nonblocking-dispatch.sh --status` — the reader `pr-doctor.worker_live()` asks, so the two cannot disagree), and re-offers the DEAD ones **through that same dispatcher with the argv it recorded** (`name worktree prompt cap kind`), never spawning `pi` and never calling `gh`. Polarity: `running` LIVE · `done` COMPLETE (the brief ran; the doctor re-grades the PR — supply never replays finished work) · `failed|lost` DEAD · unreadable UNKNOWN (spawns nothing — a second worker in one deterministic worktree destroys the first's log/.rc/.pid) · `running` past cap+slack is a REPORT (`stale-claim`), never an action. ⛔ The liveness question is asked of the **WORKTREE, not of one name** (#2280): `pr-doctor.worker_name()` is repo-qualified (`prd-<repo-tag>-<n>`, in EVERY mode since #2725) while the worktree is `prd-<n>`, so before re-offering an order the supervisor asks `--status` for every order recording the same worktree PLUS the unqualified `prd-<n>` back-compat alias (the PRE-#2725 worker's name; the doctor no longer writes it, and — unlike the doctor's own read — this arm is not attributed to a checkout, so another repo's pre-rename worker can hold the order `live`, which is the safe direction) — a `running` holder refuses (`live`, slot held) and an unanswerable holder refuses too (`unknown`). A re-offer ACCEPTED but already ENDED (a fast-failing worker that left a `.rc`) is written to the ledger and is **not** counted as a live slot. One pass = `refill`/`heal`; `--loop` is the service, `status` prints the last record PLUS a fresh count, `--dry-run` writes NOTHING (no ledger row and no pass record — the record is the last REAL pass's evidence). Single-instance guard is an atomic `mkdir` + pid + CAS takeover, and SIGTERM EXITS (a trap that only released the lock left the loop running without its guard). Budget = `fix + review` from the orchestrator plist — the ONE source `pr-doctor.capacity()` reads, never rendered into a unit. Exit `0` pass · `2` refusing · `3` undelivered · `4` already-running · `6` deferred (dead orders remain — a pass that re-offered SOME is still a `6`, because a bounded pass is not a clean one). Installed by `scripts/install-worker-supply.sh` (Linux/systemd) or `scripts/install-launchd.sh` (macOS) |
| `worker-supply.test.sh` | the #2700 contract, DRIVEN (not grepped): a stub dispatcher that shares the REAL one's grammar **and its fd discipline** (`exec >/dev/null 2>&1` in the worker — without it the supervisor's captured call blocks for the worker's whole life, which is how the first attempt at this fix died inside its own suite at 45+ minutes), the doctor's OWN `worker_live_for()` imported from the shipped `pr-doctor.py` and asked before/after as the accept check (`absent → live`), the single-instance guard BOTH ways (a second supervisor exits 4 and touches no worker; a stale lock is taken over), the bounded SIGTERM stop, the budget (2 spawns for `1+1` against 4 dead orders, `rc=6` and the bound named), mid-order death re-offered EXACTLY once (then twice, then stopped at `MAX_REFILLS`), the plist/env precedence pinned against `pr-doctor.capacity()`, the unit/plist properties (`--loop`, `KillMode=process`, `Restart=always`, no rendered `MAX_FIX`), the installer's one-command render + its Darwin refusal, **two MUTATIONS** (neuter the refill → the refill case reddens; delete the lock → the two-supervisor case reddens) and **its own wall-clock bound** (asserted ≤60 s, measured ~27 s). Hermetic, a CI shard |
| `report.sh` | read-only operator summary: merges in a window, per-kind agent wall-time and cap-hit rate from `state/walltime.tsv`, live `refs/claims/*`, queue health, and the last dispatch decisions. Safe to run while the loop is working. Not part of the loop |

**Manual utility:** `adopt-fix.sh` — run `fix-one.sh` against a specific PR by hand;
`nonblocking-dispatch.sh` — launch a headless worker in the background and return immediately (§2);
`lane-exec.sh` — launch ONE lane with `exec pi` so no wrapper survives the turn (#2163, §6.5.1b).
None is part of the loop.

**Retired** (`retired/`, kept so nothing is lost): `auto-loop.sh`, `dispatch.sh`,
`do-merge.sh`, `refix.sh`, `sweep.sh`, `watch-one.sh`. These are earlier iterations of the
same idea and are no longer invoked; they are included for the record, not for use.

**Retired from the heartbeat, kept here for the record:** `retired/queue-dispatch.py` — the
lane-table dispatcher the beat ran until 2026-10-17 (agent-infra#1874, the retirement half of
#1890). It fed work only to lanes that already existed and were DONE-IDLE, so it could not start
work that had no lane; `pr-doctor.py` replaced it and is now the beat's only dispatch entry point.
Its SPAWN path is switched on: #1894 (#1890) pointed `pr-doctor.py` at `nonblocking-dispatch.sh`
(§2 above), so a dispatch starts a fresh worker in the PR's own worktree and no longer needs a
pre-existing idle lane — `idle_lanes()` is gone from the file. (This paragraph read "NOT SWITCHED
ON YET … CALLED BY NOTHING" until #1894 merged; that was true when the dispatcher was retired and
is false now.)
⛔ It is wired to nothing and farmed by nothing — re-arming it would restore a SECOND dispatch
path, which is the divergence #1890 exists to remove.

### Which harness commit is this box running? (agent-infra#1745)

On the deployed laptop box the question had **no answer**: the daemon executes `$O/<script>` and
`~/orchestrator` is not a git checkout at all (`git rev-parse --show-toplevel` → `fatal: not a git
repository`). `install.sh` now records the source identity into `$O/.agent-infra-stamp.json` — the
SAME cell-shaped record `cloud-cell-supervisor.sh` writes on a cmux cell, so there is one stamp
concept, not two. `commit` names the source tree, `payloadSha256` covers the `*.sh` the daemon
actually executes (the commit cannot see a post-install hand edit to `$O`; the hash cannot say
whether the commit is on the repo's line), and `agentInfraDirty` says whether that source tree was
clean when it was copied. The answer is a file read, not a `git` call.

```bash
sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json"
```

`check-deployed-drift.sh` answers the next question — does the deployed `$O` actually match the repo?

```bash
./check-deployed-drift.sh            # 0 = match, 1 = drift, 2 = UNKNOWN (cannot verify)
./check-deployed-drift.sh --surface  # the same question WITHOUT a record: which deployed dirs
                                     # carry harness scripts `origin/main` does not (see §6)
```

`--surface` is the record-free half (#2231): it enumerates the harness directory the RUNNING
controller actually executes, plus every home-dir harness dir on the box (`$HOME/orchestrator`,
`$CELL_HOME/harness` and its per-commit children, `$HARNESS_PIN_FILE`, `$CELL_HOME/orchestrator`,
the `$HARNESS` this box was handed) and compares every `*.sh` basename against `origin/main`'s
`scripts/orchestrator-harness/`. It reports files that **differ**, files that exist **only** in a home
dir, and files main ships that a deployed dir is **missing** — and it exits **2 (BROKEN)** when a
candidate cannot be examined (unreadable, unlistable, an unsearchable ancestor, an unresolvable link),
when the pin DIR record it would read cannot be examined, or when no candidate directory exists at all.
With `--surface` and **no usable record on the box** — no `$O`, a `$O` with no readable
`.harness-provenance` **and** no readable `.agent-infra-stamp.json` — the record-based halves print
`SKIPPED` and the surface answer still arrives; that is the point, because a box with no record is
exactly the class whose harness may have diverged. A record that is present but *unusable* is not a
reason to skip the surface pass either: a readable stamp answers the record halves instead (and the run
says so), and only when neither record can be read does the identity half abstain.
(`--o` still selects the deployed dir; the default is `$HOME/orchestrator`.)
It is runnable from any box (it reads `origin/main` from the hub checkout it is given, never from the
box it inspects) and `scripts/harness-status` runs it as its fifth row.

⛔ **`UNKNOWN` is never a pass.** A missing record, an unreadable one, `commit: UNKNOWN` (the source
was not a checkout), or an unresolvable ref exits **2**, not 0. That is the rule #1790 measured on
the cells: `check` printed `CELL CAN RUN A CONTROLLER` over a tree that was not on `main`'s line,
and over a copy whose bytes matched `main` but which carried no git identity. The laptop is the
same class with a worse starting point — no record at all — so its absence fails the check loudly
instead of reading as healthy.

### The Mac runs the PIN, not a home-dir copy (agent-infra#2231)

**The defect, in one line.** The launchd job exec'd `$O/orch-loop.sh` — `~/orchestrator/orch-loop.sh`,
a **copy** of a script this repo carries, in a directory that is not a git checkout at all
(`git rev-parse --show-toplevel` there → `fatal: not a git repository`). The cells never had it: they
exec `<pin root>/<sha12>/scripts/orchestrator-harness/orch-loop.sh`, a detached worktree **at the
pinned commit**, recorded in `HARNESS-PIN`. So the Mac was the one machine whose harness identity had
no answer — and the one whose fixes could vanish.

**The parity table, as measured against the paths the Mac was configured to exec.** "In the repo" is
a `file:line` for the *content*; the third column is the question that matters — whether the path the
job NAMES is a tree the repo can be pinned to.

| what the Mac runs | path it was configured with | the same content in the repo? | repo version vs the Mac's copy |
|---|---|---|---|
| controller program (`com.eldato.orchestrator-loop`) | `~/orchestrator/orch-loop.sh` | yes — `scripts/orchestrator-harness/orch-loop.sh` (named by `launchd.plist.template:11` **before** this change) | **stale**: `$O` is a deploy snapshot with no commit; the deployed copy measured behind main in `check-deployed-drift.sh` |
| the controller's entrypoint *on this box's installed plist* | `~/orchestrator/launchd-controller.sh` | **NO — absent from every commit** (`docs/ops/ACTIVATION-MATRIX.md:43`, `git ls-tree origin/main` → absent) | home-only; the tmux/Full-Disk-Access wrapper §3.1 of `docs/ops/fleet-harness-baseline.md` describes; lifted by **PR #2020 (open, conflicting)** |
| the 21 helpers the controller sources (`claims.sh`, `merge-one.sh`, …) | `~/orchestrator/<name>.sh` | yes — same directory | **stale** in both directions; `install.sh`'s `DRIFTED` list names them, and it only WARNS |
| `~/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist` → `~/orchestrator/watchdog.sh` | absolute home path in the plist | **NO template ships it** — `git grep -l orchestrator-watchdog -- templates/launchd` → 0 (`ACTIVATION-MATRIX.md:44`) | home-only |
| the beat's classifier | `~/.pi/agent/scripts/lane-status.py` | yes — `scripts/lane-status.py`, which now **carries the #1777 liveness text** (commit `7728022e`) | repo **current**; the farm exemption that says the live copy is ahead (`pi-bootstrap/setup.sh:394`, `tests/test-setup-no-nesting.sh:423`) is **stale in its reason** |
| the beat loop / pr-doctor | `~/.pi/agent/scripts/heartbeat-loop.sh`, `pr-doctor.py` | yes — `scripts/heartbeat-loop.sh`, `scripts/pr-doctor.py` | byte-identical at the last measurement (`test-setup-no-nesting.sh:427`) |
| `~/orchestrator/orchestrator-heartbeat.sh` (`com.eldato.harness-heartbeat`) | resolved from `$O` first (`RESOLVER_SET` in `scripts/orchestrator-bringup.sh`) | yes — `scripts/orchestrator-heartbeat.sh` | **stale** whenever `$O` is |
| **`~/.cache/orc/main-orch-loop.sh`** | outside any `$O`, any pin and any installer | **NO — ZERO references in the repo** (`grep -rn 'main-orch-loop' .` → 0) | **worst row**: a controller-shaped script nothing in the repo creates, names, or replaces |

**The two halves of the fix, and why it is not a second launcher.**

1. **`install.sh` resolves the PIN and refuses anything else.** Before rendering, it reads the two
   records the cells read — `.harness-path` (the dir) and `~/.pi/agent/state/HARNESS-PIN` (the sha) —
   and requires the resolved directory to be a **`git worktree` at that commit** carrying
   `orch-loop.sh`. When no pin is recorded it **materialises one through the cells' own materialiser**
   (`cloud-cell-supervisor.sh apply --force --pin-only`); when the resolved dir is a copy, a different
   commit, unreadable, or unexaminable, it **refuses (rc=78) naming both paths**. After rendering it
   parses the plist back and refuses unless the `ProgramArguments` program IS
   `<pin>/<entrypoint>`. The render therefore cannot name `$O`, `~/orchestrator` or `~/.cache/orc`,
   and `$O` keeps its real job — the **worker** surface, exactly as on a cell.
2. **`scripts/harness-up` gained a `box` row**, so `harness-status` names the machine AND the pin sha it
   runs (`box | <host> | <sha12> | OK (darwin via scutil ComputerName; harness <pin dir>)`). The Mac is
   now one of the boxes that answers "which harness?" in the same shape as a cell, instead of the
   exception that printed `pin: SKIPPED (no pin machinery on this box)`.

**What is deliberately NOT done here.** `deploy-mac-orchestrator.sh` still copies a staged tree into
`$O` by `git archive` — it is the *worker* seed and it is idempotent; the controller no longer reads
`$O`, so it can no longer be the thing that runs. And when a box's live entrypoint
(`launchd-controller.sh`) is not in the pinned tree, the installer **refuses** rather than rendering
the pin's `orch-loop.sh`: moving a Mac off that wrapper would silently drop the TCC workaround, so the
content has to land (PR #2020) before the pin may replace it — the "do not delete before it is landed"
rule, enforced mechanically.

**Portability edits applied to the shipped loop.** Three per-box constants became overridable — with
this box's values still the default for `OR` and `O`, and **no default in the scripts that refuse
their own REPO**; SEVEN shipped shell scripts still carry one, plus an eighth instance in a `.py`
(#1935/#1977, enumerated in §4 step 2). The launchd
`PATH` is no longer one of them: `install.sh` renders the `__PATH__` placeholder from the directories
`tmux`/`gh`/`uv`/`pi` actually resolve to, refusing any `*/shims`, `*/shims/*` or `*/.pi/*` directory
because macOS TCC makes such a symlink EPERM under launchd, and then probes each tool by executing it.
⛔ Cite the two helper defaults by SYMBOL (`REPO="${REPO:-…}"`), not by line: #1977 deletes those
exact lines.

```bash
OR=                     # ⛔ DERIVED from $REPO's origin (repo-slug.sh); an explicit value wins
REPO="${REPO:-}"        # ⛔ REQUIRED, no default — the loop refuses it by name (above;
                        # refresh-candidates.sh:18 and cloud-cell-supervisor.sh:93 are
                        # #1977's; five more carry one, listed in step 2)
O="${O:-$HOME/orchestrator}"
```

The shipped copies are **not** byte-identical to the ones running on the original box: they are
those copies **plus every §7.4 fix** (and the §7.4b and §7.4c ones). `install.sh` compares the scripts it invokes — the ten loop
scripts in §9 plus the manual `adopt-fix.sh`, and `gh-rest/gh` — against the running copies at `$O` and warns loudly
on drift, because the daemon executes `$O/<script>` — a fix that only lands in this directory is not
in effect. That set is the one `install.sh`'s drift loop lists; `selftest.sh` is shipped but not
compared, since the daemon does not run it. If you are adopting this onto an existing box, sync
them (`cp <harness>/*.sh $O/`) and restart the loop before trusting any §5 invariant.

⛔ **Copying the scripts is not enough when a *limit* changed.** The launchd plist carries its own
environment block, rendered by `install.sh` from these defaults, and that environment **overrides the
script's own**. A job already loaded with `MAX_LOAD=16` keeps `16` no matter what `orch-loop.sh` now
defaults to. `install.sh` overwrites the plist *file* but does not reload an already-loaded job, and
`launchctl load -w` on a job that is already loaded does not reliably re-read it. So for a limits
change: re-run `bash scripts/orchestrator-harness/install.sh --restart` — it re-renders, `bootout`s,
`bootstrap`s and then verifies pid + heartbeat. (Plain `… install.sh --start` also reloads, but only when
the loaded job was NOT recorded as this render — the render launchd was last seen loading is written to
`$O/state/launchd-loaded.sha256` at every successful start, because "the file did not change" is not the
question: a plain run overwrites the plist without reloading it. An absent record is reported as
UNKNOWN, not as "the old settings are live", and unknown reloads once. So a validation run cannot
disturb a healthy controller, and the first `--start` after upgrading records the render. A plain
`… install.sh` never touches a loaded job; it warns, naming `--restart` only when it can show the loaded
job is on an older render.)

⚠️ **And `launchctl bootout` touches nothing when the controller was not started by launchd.** A loop
started as `nohup … orch-loop.sh` from a session has no launchd job at all, so a bootout/bootstrap pair
is a no-op *for that process* and the old controller keeps the old limits: the operator believes a
limits change took effect when it did not. The two reads that answer it are
`launchctl print gui/$(id -u)/com.eldato.orchestrator-loop` (its `path` and `pid` — or `rc=113` when
there is no job) and `cat ~/orchestrator/.orch.lock`; `install.sh --start`/`--restart` **refuse** to
start while `$O/.orch.lock` holds a live pid that launchd is not running (launchd's copy would exit at
once on that lock and `KeepAlive` would relaunch it forever) and tell you to stop it first. Stop a
session-started controller with `pkill -f "[b]ash $O/orch-loop.sh"` (§6) rather than with `launchctl`.

> Do not record "on this box the loop runs under nohup" as a fact — it is a state, and it changes: on
> 2026-10-17 this box was launchd-owned for part of the day and session-owned for another part. Read
> the two commands above at the moment you care.

Everything else is still tortoise-shaped and must be changed on another target: the branch
suffix (`tm`), `feat/<N>-tm` naming, `lane.sh`'s `uv sync --extra embeddings --extra parity`, the
`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest` invocation.
The required-check list is NOW repo-aware: it is read from the target repo's branch protection
(`gh api repos/$OR/branches/main/protection/required_status_checks`), `REQ=…` overrides the read,
and `FALLBACK_REQ` in `repo-authority.sh` is the non-empty fail-closed last resort when protection
cannot be read. The merge authority follows from that set: a repo requiring the review gate merges
via `gh pr merge` after the gate goes green, and a repo that does not is merged through its own
`scripts/admin-merge.sh` (agent-infra#1764).
Two things that were on this list are now repo-aware: the collision pre-flight tool is resolved per
repo (the target repo's own copy, else a `TORTOISE_REPO` checkout) and the scout venv step is skipped for
a repo with no `pyproject.toml` — and a repo that can be provisioned is verified at `check` time —
agent-infra#1736.

---

## 10. Open questions for the evaluator

1. ~~Does this belong in `agent-infra` (symlink-distributed via `manifest.json` + `sync.sh`,
   pull-only) rather than in a repo's `operations/`?~~ **Answered 2026-10-13:** moved to
   `agent-infra/scripts/orchestrator-harness/` (agent-infra#1700).
2. Should the two boxes coordinate through an explicit claim registry instead of branch-name
   heuristics? tortoise#5052 already proposes "an authoritative, expiring claim registry" —
   §7.1 is the same problem seen from the dispatcher's side. **Partly answered 2026-10-15/16:**
   both keys now exist (`refs/claims/<PR>-<head-sha12>` for merges, `refs/claims/issue-<N>` for
   dispatch — §7.2b/§7.2d). What is still open is **coverage, not mechanism**: every path that can
   take work must remember to acquire, and an issue claim is still no proof of life.
3. Is a `~/`-rooted bash harness the right shape at all, or should this fold into the fleet
   rail's cmux workspaces (agent-infra#1683)?

---

## 11. Single source of truth: this directory

**This directory is the ONLY copy of the harness.** Measured 2026-10-19 (blob hashes, 8 chars), before
consolidation the same eight files existed in three places:

| file | agent-infra `main` | tortoise `main` | live `~/orchestrator` | classes | fix preserved / file retired |
|---|---|---|---|---|---|
| `orch-loop.sh` | `e069af29` | `a1ffab3d` | `b4b89547` | (a) + (b) | (a) `P0_BYPASS_MERGE_PRIORITY` + `p0_merge_priority_override` → **NOT PORTED: superseded by main's unconditional drain rule (owner ruling 2026-10-18), see the reconcile note below**; (b) tortoise + live are older generations → replaced |
| `spawn-gate.sh` | `a7dba947` | `f7af7919` | `a7dba947` | (b) | tortoise carried no fix; it lacked the shared-gate refactor → replaced |
| `refresh-candidates.sh` | `a3ac5019` | `facc9a1d` | `a3ac5019` | (a) + (b) | (a) `landed.txt` (skip/write/prune/report), `RETRY_MAX` → ported; (b) otherwise older → replaced |
| `claims.sh` | `d1604686` | **absent** | `d1604686` | (b) | tortoise fork never had it → retired |
| `nonblocking-dispatch.sh` | `5e3fe2b1` | **absent** | `5e3fe2b1` | (b) | tortoise fork never had it → retired |
| `lane.sh` | `3dc22993` | `03400e8d` | `3dc22993` | (a) + (b) | (a) `Closes #N` required / bare `Refs` refused → ported; (b) tortoise lacked the PATH/source-order fix → replaced |
| `install.sh` | `3c0d14a8` | `de2ce83a` | `db02dfb3` | (a) + (b) + (c) | (a) `merged-not-closed.sh`/`spawn-gate.sh` drift list → ported (the `P0_BYPASS` render is **NOT** ported, same reason as `orch-loop.sh`); (b) tortoise lacked `SCOPE`/key-file validation; (c) macOS-only **by design** — Linux names `scripts/cloud-cell-supervisor.sh` |
| `selftest.sh` | `2318d1e0` | `04174f50` | `5675377c` | (a) + (b) | (a) tortoise's landed/RETRY_MAX checks → ported (adapted); (b) otherwise older → replaced |

The live copy was **not** a hand-fork: it was an untracked copy of agent-infra generation
`2ddd5b5a1` (blob-identical on all eight files), one commit behind `main`. That is the same defect
by another route — an unversioned copy cannot be updated, audited, or healed — so it was converted
to symlinks into a git checkout rather than deleted. Its one-generation lag is what `doctor` reports
as `deployed bytes=DIFFERS` on the SYMLINK-into-checkout arm (it reads the target checkout's git
identity, so a lagging checkout is visible) — and NOT via the stamp arm, which needs
`.agent-infra-stamp.json`: an un-stamped conversion reads `check-deployed-drift.sh` = 2 UNKNOWN, by
design (see "which instrument answers which question" below).

The consequence was structural, not cosmetic: every fix had to be applied by hand in three places,
each box ran a different generation, and "self-healing" was impossible because there was no authority
to heal *toward*. And it was actively losing work: the `landed.txt` / `RETRY_MAX` half of
`refresh-candidates.sh` (tortoise#8560/#8625/#8469) was **deleted** by the tortoise retirement before
this pass ported it — the retirement's own premise, "every fix was ported first", was false for that
file.

**The rule.** A fix is ported HERE first. `operations/orchestrator-harness/` in tortoise is retired
to a pointer, and **tortoise CI fails if a harness script reappears there** — that check is
tortoise's `tools/check-harness-fork.sh`, run as a step of the `manifest-integrity` job in tortoise's
`.github/workflows/python-ci.yml` (a `needs:` of its required `python-ci-gate`), because it is
tortoise's tree that must stay retired. ⛔ **NOT** a `.github/workflows/harness-single-source.yml` in
tortoise — that file does not exist: it was removed on purpose, because a path-scoped workflow is not
a required context (the guard's own header records that). The same filename HERE is a different
check (canonical completeness + non-vacuity of this repo's copy, not the retired tortoise path). The
live copy is a versioned checkout of this repo rather than an orphan directory of hand-copied files.

**The instrument.** `check-single-source.sh` asserts all three halves and FAILS on any of them:

```bash
./check-single-source.sh                                  # canonical completeness
./check-single-source.sh --fork ../tortoise/operations/orchestrator-harness
./check-single-source.sh --o ~/orchestrator               # deployed bytes == canonical bytes
./check-single-source.sh --require-target --o ~/orchestrator # the CI form: checking nothing is a failure
```

⚠️ `--require-target` counts a target only when at least one file was ACTUALLY compared. With
`--fork <dir>` on the CORRECT retired state (the directory absent, or holding only a pointer README)
nothing is compared, so `--require-target --fork <dir>` exits **2 UNKNOWN** — by design, and it prints
`ok: retired location is absent (<dir>)` (an absent path) or `ok: <dir> holds none of the 8 fork-arm
files (…)` (a directory that exists but carries none of them) immediately before it. The CI form
therefore passes `--o` (a real comparison), and the fork step of that job plants a fixture without
`--require-target`.

Three shapes are now UNKNOWN rather than a clean answer, in BOTH arms: a path that exists but does not
resolve (a dangling symlink — `-e` is false for it, so it used to read as "absent"), a path that exists
but is not a directory, and a directory that cannot be searched (`-f` is false for every file inside,
which used to read as "no fork" / "eight files missing"). And asking either arm to compare canonical
with ITSELF (`--o <this directory>`, or `--fork <this directory>`, which includes the symlink farm
README §11 recommends) is UNKNOWN: a self-comparison proves nothing and its "delete it" message would
name the source of truth.

**The fork arm's file list is curated and its one exclusion is named.** It looks for the `SHARED`
set (the eight files whose divergence caused the measured incident) plus a printed note naming
`merge-one.sh` as deliberately excluded — tortoise still holds the only copy of the unported
#8484/#8589 fix, so a fork arm covering it would fail the real retired location. Everything else is
covered by the deployed arm, which byte-compares every SHIPPED file — `*.sh`, `gh-limit.py`,
`gh-rest/gh` and `gh-limit/gh` (a `*.sh` glob excluded the last three, which is the very file the
arm's header claims it caught) — and by `check-deployed-drift.sh`'s shipped-surface half.

**Scope of what is observed, stated honestly:** the check only looks where it is told. The fork arm
observes the paths passed via `--fork` (or the colon-separated `HARNESS_FORK_PATHS` that
`bin/harness doctor` uses), and the deployed arm observes `$O`/`--o`. Nothing walks the filesystem
looking for copies — an ignore-blind walk is the fleet's most expensive habit (#1069), so a fork
check must be explicit about what it looked at. The CI job proves the check is **non-vacuous** with
a planted fixture; *watching the real tortoise path* is the tortoise-side job.

⛔ **`HARNESS_FORK_PATHS` is unset by default, so `doctor`'s fork arm does not run until an operator
names the retired locations** — and its `--json` surface says which it was: `"forksChecked": false`
with `"forks": "not checked"`, never a bare `OK` that a consumer could read as "no fork found". Set
it in the shell you run `doctor` from (it is an OPERATOR setting, not a daemon one: launchd inherits
no shell environment and the plist does not render it, so putting it there would change nothing):

```bash
export HARNESS_FORK_PATHS=$HOME/eldato/tortoise/operations/orchestrator-harness   # colon-separated
bin/harness doctor        # the forks line now names a verdict for that path
```

A path containing a space is fine — it is used verbatim (it used to be rewritten by a whitespace
strip, which made a spaced path report `ok` for a directory that did not exist).

Exit `2` is `UNKNOWN` — "could not verify" is never a pass, the same doctrine as
`check-deployed-drift.sh`.

### Platform differences are NAMED, not accidental

The harness runs on two platforms with two supervisors. This is a legitimate difference and it is
expressed as **a shared code path plus an explicit platform branch**, never as two drifting copies:

| | macOS (darwin) | cloud cells (linux) |
|---|---|---|
| supervisor | launchd | systemd unit **or** a running `cloud-cell-supervisor.sh` process |
| installer | `scripts/orchestrator-harness/install.sh` | `scripts/cloud-cell-supervisor.sh` |
| job label/unit | `com.eldato.orchestrator-loop` | an `orchestrator-*`/`com.eldato.orchestrator-*` unit |
| status verb | `launchctl print gui/$UID/<label>` | `<repo>/scripts/cloud-cell-supervisor.sh status` (the supervisor's own verb — NOT a `pgrep -f` match) |
| `timeout(1)` | absent — `run_agent` uses a bash `wait` + watchdog | present, but the same fallback is used |

⚠️ The Linux supervisor probe is NAMED and STATE-CHECKED, not a substring match (review P1).
Measured on a cell 2026-10-19: `systemctl list-units` contained `eldato-disk-reaper.service` in state
`failed`, and an `eldato|orchestr` grep reported `supervisor systemd … verdict OK` for a box with no
harness supervisor at all — a false answer to the one question the verb exists to answer. The probe
now requires (a) an ORCHESTRATOR unit name, (b) ACTIVE state, and (c) never treats a unit FILE on
disk as evidence that one is loaded (the macOS arm already refused that inference). A cell whose
supervisor is the process (tmux + process table, which is how `cloud-cell-supervisor.sh` works) is
reported as `supervisor process`, with the evidence named.

#### The five primitives that differ — `scripts/lib/box.sh` (agent-infra#2271)

Each of these had already been discovered separately, in a different script, AFTER it failed there:

| primitive | BSD (macOS) | GNU (Linux) | why the wrong spelling is dangerous |
|---|---|---|---|
| in-place edit | `sed -i '' -e …` | `sed -i'' -e …` | `sed -i 's/a/b/' f` on BSD treats the SCRIPT as the backup suffix: it edits **nothing** and exits **0** |
| epoch → date | `date -r <epoch>` | `date -d @<epoch>` | the wrong flag is a usage error, so a "timestamp" is silently empty |
| CPU count | `sysctl -n hw.ncpu` | `nproc` / `getconf _NPROCESSORS_ONLN` | resolved at SOURCE time, so a wrong PATH pinned `_NCPU=4`/`MAX_LOAD=40` for every cell (#1702) |
| mtime | `stat -f %m` | `stat -c %Y` | `stat -c` on macOS means filesystem status and prints the WRONG NUMBER |
| supervisor | launchd | systemd unit or a supervisor process | already in the table above |

**One shim, probed, never assumed from `uname`:** every primitive tries its mechanisms in order and
records which one answered (`box_provenance`), so a Homebrew GNU-userland on macOS or a BSD-flavoured
container still gets the right answer. `bash scripts/lib/box.sh --selftest` prints the provenance and
reproduces the BSD `sed -i` hazard as a live assertion; `scripts/lib/box.test.sh` runs on both
platforms.

#### `scripts/harness-exec.sh` — the RUNTIME half of "the Mac runs from the pin"

`install.sh` refuses to render a plist whose program is not inside the pin (#2271, install time).
`harness-exec.sh` is the same refusal on every START, for both platforms: it resolves the two pin
records (`HARNESS-PIN` = commit, `HARNESS_PIN_FILE` = the harness directory the controller execs),
requires the recorded directory to BE a clean checkout at that commit inside `<pin root>/<sha12>`,
requires the entrypoint to exist **and to resolve inside the tree**, and `exec`s it. **There is no
fallback** — not `$O`, not `~/orchestrator`, not `origin/main` — because running an unpinned copy
INSTEAD of the pin is exactly how three fixes existed only in a home-directory copy for weeks
(#2231). Every refusal is a named `rc=78` and is asserted by name in `scripts/harness-exec.test.sh`:
not-a-checkout, the two records DISAGREE, EMPTY, not a commit id, not a directory (pruned), the pin
layout (`<root>/<sha12>`, proven from the records when `HARNESS_PIN_DIR` is unset), UNCOMMITTED
CHANGES in the pinned harness dir, an entrypoint that walks out with `..` or through a symlink, and an
entrypoint the pin does not carry.

⛔ **IT IS NOT THE START PATH YET, AND THIS FILE WILL NOT PRETEND OTHERWISE.** Nothing renders or
execs it today (`rg -ln harness-exec` finds only this shim, its suite and the shard list), so the Mac's
launchd job still execs `~/orchestrator/launchd-controller.sh` — the home-dir copy #2231 names as its
worst row. The two changes that put this shim on the start path are **#2271** (install resolves the
pin and parses `ProgramArguments` back out of the rendered plist) and **#2020** (the TCC wrapper's
content lifted into a commit). Until both land, the shim is inert: on this Mac it REFUSES (there is no
pin — measured 2026-10-22), and `harness-exec.test.sh` arm 10 asserts exactly that rather than
pretending the box is fixed.

### Which instrument answers which question (all three, and they DISAGREE by design)

| question | instrument | what it needs | its `2` means |
|---|---|---|---|
| is the harness ONE source — canonical complete, no re-fork, deployed bytes equal? | `check-single-source.sh` | a repo (and optionally `--o`/`--fork`) | nothing was compared |
| which commit is this box RUNNING, and does it match the record? | `check-deployed-drift.sh` | the deployment's `.agent-infra-stamp.json` | no record → cannot answer (the #1745 laptop state) |
| what is this box (platform, supervisor, installer, canonical vs deployed kind)? | `bin/harness doctor` | nothing but a shell; read-only | some field could not be read |
| **is the controller SELF-DISPATCHING** — what did the last cycles select, dispatch, and why did a cycle dispatch nothing? | `bin/harness status` | the cycle record `$O/state/cycles` that `orch-loop.sh` appends (`cycle-record.sh`) | **no record at all** — and an absent record is never "nothing to do" |

⛔ THEY DISAGREE ON PURPOSE, AND NO ONE OF THEM IS "the" answer (review P2). On an un-stamped
symlink-into-checkout box — the shape this section recommends — `check-single-source --o` says 0,
`doctor` says 0, and `check-deployed-drift` says **2**, because only the last one requires a RECORD
of what was installed. On a box with no deployment at all the same three read 0 / 0 / **2**. That is
not a contradiction to be papered over: each `2` means "this instrument cannot answer", and the
reader must take the answer from the instrument that CAN. A future consumer should read
`doctor` for the box's shape, `check-single-source` for the bytes, and `check-deployed-drift` for
the audited history — and if a green verdict is needed from all three, deploy with a STAMP: `install.sh`
writes `.agent-infra-stamp.json` on the Mac (`STAMP="$O/.agent-infra-stamp.json"`), and the cell's
`seed_and_stamp` → `stamp_write` writes the same record. ⚠️ The Mac copier
(`deploy-mac-orchestrator.sh`) does NOT write one — it copies bytes, so a box deployed only by it leaves
`check-deployed-drift.sh` at 2 (measured: `UNKNOWN: no harness record … this is NOT a pass`), which is
the honest answer to "which commit is this box running?" when nothing recorded it.
⛔ AND THIS SCRIPT CANNOT ANSWER ITS OWN DEPLOYMENT QUESTION (corrected review P2, cycle 7): it ships to
`$O`, so `$O/check-single-source.sh --o $O` is canonical compared with itself — it now refuses
(`UNKNOWN: … a self-comparison proves nothing`) instead of reporting `targets compared: 1` and staying
green over a stale edit.

`install.sh` is macOS-only **on purpose** and says so; on Linux it names the cell supervisor rather
than dying with no next step. Ask any box which branch it is on:

```bash
bin/harness doctor          # platform, supervisor + evidence, canonical commit, deployed kind, fork state
bin/harness doctor --json   # the same, machine-readable
bin/harness status          # IS IT SELF-DISPATCHING? the last 10 cycle records + a verdict
```

`doctor` exits `0` healthy, `1` drift, `2` UNKNOWN.

`status` answers the question no pane can: a live pane proves a PROCESS, a fresh **cycle record**
proves a CYCLE. It grades the NEWEST record in `$O/state/cycles` — `HEALTHY` (younger than two of the
box's own cycles, rc 0), `DEGRADED` (older, rc 1), `ABSENT` (no record at all, rc 2 — never healthy),
`UNREADABLE` (rc 2) — and prints each cycle's `selected=`, `dispatched=`, `nothing=` (the gate and the
capacity `bound=` when nothing was placed) and `placement=`. Measured 2026-10-21: the controller log on
cell-1 was 37h stale and on two cells no log existed at its expected path, so "the controller is
looping" was UNPROVEN — every reader had been treating an absent record as silence, i.e. as fine.

### `status` ALSO answers "can this box LAND anything?" (agent-infra#2320)

A second dimension sits beside the cycle verdict, and it is deliberately NOT folded into it:

| line | what it reads | what a negative means |
|---|---|---|
| `landing gh=OK path=<gh> …` | `gh_chain_read` — `AGENT_GH_REAL` first, then a PATH walk that mirrors `find_real_gh` in `scripts/gh-shim/gh` (skips the shim itself and any layer by its OWN sentinel, `-ef`-deduped through symlinks), CONFIRMED by one `--version` probe on a FRESH hop budget (the shim's admission capped at 5 s, its mutex at 1 s) and WALL-CLOCK BOUNDED ON EVERY HOST — `timeout`, then `gtimeout`, then a bash-native watchdog, because macOS ships neither binary and a direct call there left the ONE probe this read exists to bound unbounded. `path=` is the LAST field, so a resolved path containing a space survives | `CANNOT-REACH-REAL-GH` (a wrapper/shim identified statically by its own sentinel, or a PROBED candidate that refused — its own words are quoted verbatim, and a refusal STOPS the walk, because the box's `gh` is shadowed by it and a later PATH entry is not reachable from a `gh` the box cannot shadow) or `UNVERIFIABLE` — **and a box without a real gh cannot land anything, so every lane it runs is wasted work** |
| `landing contract=OK required=[…]` | `merge_contract_read` → `required_checks` (the SAME rule `merge-one.sh` uses) | `UNREADABLE why=<token>` — the token is the diagnosis: `empty_or_unreadable` means the read was made and came back EMPTY (never "this repo requires nothing"), `no_real_gh` means the chain could not ASK and no read was made (the remedy is the gh chain above); either way the contract falls back and every merge is REFUSED (`merge-one.sh` exit 5) |

⛔ WHY IT IS ITS OWN DIMENSION. Measured 2026-10-22 on the owner's Mac: the wrapper chain
`gh-limit -> gh-rest -> .pi/agent/shims/gh` resolved to ITSELF, gh-limit refused at depth 2
("the shims are resolving to each other and no real gh is reachable"), EVERY gh call returned EMPTY,
and the box silently stopped merging for hours while the reported cause pointed at permissions. The
cycle record cannot see that — it only knows the controller ran and dispatched nothing — so a landing
blocker is reported on its own line with its own consequence, and is never confused with a load or
capacity `bound=` (which is a different failure with a different remedy). A landing blocker does NOT
change the exit code: that code is the CYCLE verdict's contract, and re-purposing one number for two
dimensions is exactly the ambiguity this section removes. Machine readers use `landing.ok` (a real
JSON boolean, `false` for `UNVERIFIABLE` too). `AGENT_GH_REAL` is exported per box by
`ensure_agent_gh_real` (`orch-loop.sh`, `merge-one.sh`) from a DISCOVERED **compiled binary** — never
a script, which would re-enter the chain (#2266) — so the cycle cannot re-form; an INHERITED pin is
kept only when that same `--version` probe answers as a gh (a harness layer, the agent shim, or a
file that does not answer is dropped and re-resolved, so the pin can never be a value the read calls
`CANNOT-REACH-REAL-GH`); `bin/harness status`
itself never exports one (it asks through the chain, which it has just proved answers).

A known platform with **no** supervisor loaded is
reported as drift: "no job loaded" is exactly the state an operator mistakes for a quiet box. The
supervisor label must be the ORCHESTRATOR's on both platforms (`HARNESS_UNIT_RE`, one anchored
pattern): a `com.eldato.*` unit belongs to some other job, and a `com.tortoise.*` launchd job belongs
to another repo, so neither answers "is THIS box supervised". ⛔ The same pattern, byte for byte, is
what `report.sh`'s macOS controller line matches with: `doctor` and the operator report answer the
same question, so a looseness on either side is a false liveness claim on that side alone (measured:
the report called a box whose own job was LOADED-but-not-running `UP (pid 999)` on another repo's
pid, while `doctor` said `supervisor: none`). The pattern is duplicated rather than sourced because
`bin/harness` ships from `bin/` and the `$O` copier would not carry a shared file to both — so
`selftest.sh` asserts the two literals are IDENTICAL, and a loosening on one side reds the suite.

### Ports taken from the retired fork

The tortoise copy was an old generation — except for fixes it received after the handover that never
came back. Those were ported IN, not discarded:

| fix | why it mattered | where |
|---|---|---|
| `Closes #N` required; a bare `Refs` is refused | a finished lane writing `Refs` never closes its issue, and nothing re-reads it: 25 of 36 open P0-blockers already had merged PRs (tortoise#8468) | `lane.sh` — the brief text, i.e. an instruction to the lane, NOT a gate: `check-pipeline-compliance.sh` accepts the `Still open: <indicator>` traceability form for any diff, so the backstop is a reviewer and `merged-not-closed.sh`, not a refusal |
| `merged-not-closed.sh` | the fleet could not answer "which open issues already have a merged PR?" — no tool existed | new file |
| `landed.txt` (skip / write / prune / report) + `RETRY_MAX` | a LANDED verdict written to `checked.txt` retires an OPEN issue from the backlog permanently and invisibly; and an entry that never answers starves the whole pool behind it (tortoise#8560/#8625/#8629/#8469 P2) | `refresh-candidates.sh` (reaper) + `selftest.sh` |
| `verdict_kind()` / `apply_verdict_marker()` | a verdict-LESS reviewer run (stall/crash/timeout) must not authorise a fixer: 7 of 7 cap-hits in one window were verdict-less and 4 were parked "needs a human", never reviewed | `merge-one.sh` — ⛔ SUPERSEDED by agent-infra#2132's `verdict_class()` / `review_state_record()` (the same contract, plus the missing half: a verdict-less run now records `needsreview-<PR>-<head>`, so its remedy is another REVIEW instead of being indistinguishable from a genuine rejection). The names above are the fork port this table recorded; the shipped pair is the #2132 one |
| ⛔ a P0-blocker outranks the merge-priority gate (BP0, `P0_BYPASS_MERGE_PRIORITY`, `.prio` map) | **NOT carried — reconciled onto main and superseded.** The fork's measurement (19 open PRs, 0 lanes, 33 P0-blockers, 0 closed in 12h) was taken against a gate that closed *below* `MERGE_PRIORITY_AT`; main's rule is unconditional (owner ruling, 2026-10-18: "while ONE un-owned PR remains, it is the work"), so a P0 exception would reopen new issue work on top of an un-worked PR queue — the defect that ruling ends. Nothing reads `.prio` on main | `orch-loop.sh` (rebase: hunk dropped), `refresh-candidates.sh`, `install.sh`, plist |

Everything else the fork carried is here. The BP0 override and its `.prio` rank map are the ONE
part of it that is not: main reached the same goal by removing the threshold outright, and keeping
the override would let a P0 dispatch while un-owned PRs sit unworked — the exact behaviour the owner
ruling forbids. If BP0 is wanted back, it is a **reopen of that ruling**, argued where the ruling
lives — not a merge-time default.

**One fix is still unported, and one file is still in tortoise because of it:** `merge-one.sh`'s
#8484/#8589 detached-reviewer checkout (the reviewer should run in its own tree, and the
`AGENT_ALLOW_MAIN_EDITS` export withdrawn). Deleting the only copy of an unported fix is the silent
destruction this consolidation must not commit, so that file stays, tortoise's guard allows it **by
name** and says so in its output, and this paragraph is the record. Port it, then delete it and drop
it from that guard's `ALLOWED` list.

⛔ **tortoise's `ALLOWED` names TWO scripts, not one** — `ALLOWED="README.md merge-one.sh
merged-not-closed.sh"`. `merge-one.sh` is the unported #8484/#8589 fix above. `merged-not-closed.sh`
is **this PR's** file, still carried in tortoise until #2160 lands: once it has landed there, delete
that copy **and** drop it from `ALLOWED` too, or the guard keeps an exception for a file whose only
supposed home is here. (`README.md` is the pointer itself.) The follow-up is two deletions, not one.
