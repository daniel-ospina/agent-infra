---
title: "Plan — agent-infra#1777: the orchestrator's own lanes are in NO liveness population"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-10-15
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1777, refs-claims, lane-liveness, fleet-liveness, orchestrator-harness
---

# Plan — agent-infra#1777: the orchestrator's own lanes are in NO liveness population

**Issue:** agent-infra#1777 (moved from tortoise#8706) · **Level:** task · **Complexity:** standard
**Branch:** `fix/orchestrator-lane-visibility` · **Base:** `origin/main` @ `934f883a`
**Scoping:** `issue-scoping` v5.1 double diamond, Standard tier (problem-verify 2 cycles; solution-verify 1 cycle + a duplication/architecture reviewer)

---

## 1. Confirmed problem

> The fleet answers **"who holds this?"** only from **reader-side** surfaces (session transcripts, the
> cmux hook store, GitHub comment-claims) that structurally cannot contain a `pi -p --no-session`
> orchestrator lane, and it reports the resulting **emptiness as a positive answer** (`CLEAN` / `free`
> / `PASS`) because a surface declares the read set it *did* consult but never the coverage gaps it
> *cannot* see — while the one **holder-authored durable record** that would answer it
> (`refs/claims/<pr>-<sha12>`, carrying `owner=<host>:<pid>` and `lease_until`) is read by nothing in
> `tools/fleet/`.

One defect: **an undeclared-coverage inference**. The missing source binding is its load-bearing
instance, and `refs/claims`' own absence must **abstain**, never mean "free".

**NOT the fix:** adding the process table as a lane population (that is the defect #1178 closed).

### 1.1 Measured basis (this host, 2026-10-15)

| datum | measurement |
|---|---|
| orchestrator lanes are invisible | `lane_liveness.py --dry-run` → `PASS lanes=22` (cmux population); the live `fix-8721` lane is absent |
| `refs/claims` has no fleet reader | `git grep -ln 'refs/claims'` → 6 files, all under `scripts/orchestrator-harness/`; **0** under `tools/fleet/` |
| the datum exists and is live | tortoise `refs/claims/8721-3aa6548fbc18`, `owner=Daniels-MacBook-Air-new:56807` (the running `fix-one.sh`), lease live |
| the incident's own ref is gone | `refs/claims/8697-f5282009634e` absent from tortoise — the *live analogue* is what remains demonstrable |
| owner host is often FOREIGN | agent-infra's 2 refs are `owner=cmux:<pid>` while local `hostname -s` is `Daniels-MacBook-Air-new` |
| local refs are stale | local `refs/claims/*` = 7 loose refs, **disjoint** from origin's 2 ⇒ never read local refs |
| a claim cannot be process-probed | `bash scripts/lib/pid-identity.sh probe <live pid> ""` → rc 2 `unusable-start-seconds`; `probe-argv` returns `holder` for **any** live pid (pure presence, no identity) |
| the snapshot is not there | `~/orchestrator/state/claims-snapshot` absent; the deployed `~/orchestrator/orch-loop.sh` is 498 lines vs the repo's 889 (`install.sh`'s drift check is warn-only) |
| the steering sentence is unversioned | `"…the only reliable signal"` exists only at `~/.pi/agent/AGENTS.md:83-84` **and** `~/.pi/agent/scripts/lane-status.py:5,105` — **not** in the repo `AGENTS.md` or `templates/AGENTS.base.md` |

### 1.2 Corrections to the issue's own evidence (the conclusion survives)

* `"cmux hook store — 4 records total, 0 mention the worktree"` does not reproduce (2551 records; 11
  name the incident worktree, **all task children**). The mechanism holds: the workspace's single
  non-child lane record carries a sibling `cwd`, so the **lane** record cannot be attributed to the
  branch.
* The `.jsonl mtime/size is the only reliable signal` sentence is **not** in the repo — so the base ⊆
  `AGENTS.md` pin is irrelevant to *that line*. Both facts are still fixed (see §5).
* `refs/claims` supplies **live holder identity**; it does **not** supply the durable "lane registry"
  `collision_preflight.py` names (it is head-keyed, deleted on release, pruned on expiry, released
  mid-lane, and absent when `HEAD` is unresolvable).

---

## 2. Design

Three layers. **Durable store answers *which*; the one verdict function answers *what state*; nothing
re-derives a verdict.**

### 2.1 `tools/fleet/liveness.py` (modify — the ONE verdict function)

* `__all__` += `"Claim"`, `"ClaimRead"`.
* New frozen dataclasses `Claim` and `ClaimRead` (immediately before `Evidence`).
* `Evidence.claim_read: Optional[ClaimRead] = None` (appended, defaulted — both existing construction
  sites are keyword-only: `liveness.py:985` and `liveness.test.py:100`).
* **One insertion, inside the existing abstention branch** — the claim refines
  `unknown/no-holder-record`, it does not precede the ladder:

  ```python
          if not cands:
              if ev.claim_read is not None:
                  return claim_verdict(ev.claim_read)
              return Verdict("unknown", "no-holder-record")
  ```

  Consequences, all **structural** rather than by convention:
  * the documented ordering ("identity first; growth before identity") is untouched; a
    claim-bearing query that *also* carries a growing transcript still reads `running-quiet/jsonl-grew`;
  * `dead` stays unreachable for a claim because `is_dead_evidence` requires a **non-empty** candidate
    set and a claim-shaped `Evidence` carries **none** (the C4 vacuity guard does the work);
  * `holder_pid` is never set on a claim verdict — a claim has no recorded process start, so it can
    never be probed (see §1.1), and setting the field would be read as an incarnation claim.
* New pure helper `claim_verdict(cr: ClaimRead) -> Verdict` with a **declared ordered cascade** (total,
  mutually exclusive — the partition is asserted by a test):
  `claims-unreadable` → `no-claim-visible` → `claim-owner-unparseable` → `claim-held` →
  `holder-on-foreign-box` → `claim-holder-unverifiable`. All six reasons are `unknown`; the owner
  identity/lease/age is carried in `Verdict.detail` (non-liveness detail), so "who holds this?" is
  answered without asserting process liveness.
* Module docstring: a CLAIMS section stating the ownership-vs-incarnation split, the cardinality
  ("a claim can never be probed"), the ordering-neutrality, and the citation `#1777` / `#1709 rec 3`.

**What the reasons assert (and do NOT assert):**

| reason | asserts | does NOT assert |
|---|---|---|
| `claims-unreadable` | the namespace read failed (git rc≠0 / timeout / git missing / snapshot missing, stale, drifting) | anything about any holder |
| `no-claim-visible` | this HEAD key is absent from a **successfully read** registry | that the head is free (HEAD-scoped key; designed no-claim window) |
| `claim-owner-unparseable` | a claim exists, its owner string is unusable | who owns it; any liveness |
| `claim-held` | **ownership liveness**: the declared lease window is open (read exactly as `claims.sh`/`claim_live` read it) | that any process is alive |
| `holder-on-foreign-box` | a claim exists whose owner host is not this host (provenance) | the foreign holder's process liveness (never probed) |
| `claim-holder-unverifiable` | no open lease and no probeable incarnation | that the holder is gone or dead |

### 2.2 `tools/fleet/claim_lanes.py` (new — acquisition only, NO verdict)

* Reads the ref-claim registry; **never** emits a state. `ClaimRead` in, `liveness.Evidence` out via
  `to_evidence()`; the CLI renders `liveness.evaluate(ev)`.
* **Two drivers, one contract.** The normalized record is the same three fields the shipped
  `claim_snapshot` already writes — `<ref>\t<owner>\t<lease_until>`:
  * PULL: `git ls-remote origin '<CLAIM_NS>/*'` is the **authority on presence**; rc≠0 ⇒
    `readable=False` (**never** "no claim visible"); rc=0 + zero refs ⇒ `present=False`,
    `readable=True`; otherwise each commit is fetched into an **isolated temp bare repo** and
    `cat-file commit` supplies the message. A per-claim metadata failure keeps `present=True` with
    `owner="?"` ⇒ `claim-owner-unparseable` (**presence alone refutes free**).
  * FILE: `--snapshot PATH` **requires** a caller-stated `--max-age-s` (no invented bound); missing,
    stale, or shape-drifted ⇒ `readable=False` with the cause named.
* **Grammar + policy, declared once** in `claim_lanes.py` (and cited to the shipped call sites, not to
  `_lease_of` alone): `owner=<host>:<pid>`, `lease_until=<digits>`, and
  `lease_state ∈ {live, expired, unknown}` where **absent / `0` / non-digit / length > 18 digits ⇒
  `unknown`, and `unknown` is NOT expired** — the fleet's own conservative polarity
  (`claims.sh:200`, `claims.sh:331`, `orch-loop.sh:273`).
* Env seams **reuse the harness names** (`CLAIM_NS`, `CLAIM_REPO`) so a test that isolates the
  namespace isolates the Python reader too. `--repo PATH` / `--remote-url URL` is explicit; the cwd is
  never an implicit target. `GIT_TERMINAL_PROMPT=0`; every `subprocess.run` carries a timeout.
* Exit codes (**tightened at verify-gate cycle 1** — see §4): `0` a claim **IS VISIBLE** for the
  queried head (the positive answer; the fail-closed direction) · `3` **nothing established** —
  unreadable, **or no claim visible for this head** — never to be read as freedom · `2` usage/env.
  The original text here read `0` = "readable", which made the incident's exact input
  (`no-claim-visible`) a machine-visible success while `liveness.py`'s own CLI returns 3 for every
  `unknown`. Both renderings carry the fixed advisory: *the claim registry does not decide freedom;
  every claim verdict is an abstention (#1777)*.
* Output is sanitized (control chars, `|`, backticks) — same rationale as `_md_cell` (#1272).

### 2.3 `tools/fleet/lane_liveness.py` (modify — disclosure only)

* `COVERAGE_GAPS` tuple rendered as a paragraph in the report and exposed in `--json`; the population
  sentence names the gap. **No new input, no claims read, no escalation change** (the scheduled job is
  TCC-walled and must not gain a network read; `lane_liveness` never escalates on a claim).
* Module docstring: the population is the cmux population; orchestrator lanes are absent **by
  construction** and that gap is now *declared*.

### 2.4 What is deliberately NOT built (declared, with a re-check mechanism)

* **The harness's local durable state** (`~/orchestrator/state/mergeclaim-<PR>.lock`, tmux `lane-*` /
  `fix-<PR>`, `fixbail-<PR>-<sha40>`) — a genuine on-box population, deferred because its layout is
  unversioned (#1552) and tmux is not reliably readable from launchd. **Trigger:** promote it only
  when (a) the snapshot exists, (b) its mtime is younger than 2× the orch-loop cycle on two consecutive
  passes, (c) it parses under the strict 3-field rule, and (d) `install.sh` reports no drift. Until
  then the reader declares the gap and abstains.
* **The tortoise consumer** (`collision_preflight.py` / `who_is_on.py`) — the *measured* CLEAN came
  from a product-repo tool that cannot import agent-infra's tools. Its existing root is
  **tortoise#4761** (OPEN: *"a live lane pushing to a PR's head branch reads CLEAN — the verdict has no
  'is anyone doing this right now' surface"*); evidence is recorded there, not as a peer issue.
* **Branch resolution from a claim key** (sha12 → branch) — a convenience; head + PR + owner answers
  the incident's question. A/B: "nothing but time" ⇒ not filed.
* **The designed no-claim window** — with this change it produces a *correct* abstention; disclosed in
  docs, not filed.

### 2.5 Disambiguation (`ref-claim`, not "claim")

"Claim" already carries two shipped senses: the **comment-claim** (a GitHub issue comment a lane takes
ownership with — `collision_preflight.py`'s JEV `claim-ownership-v1` surface) and the **ref-claim**
(`refs/claims/<pr>-<sha12>`, owner + lease). This change adds a *reader* of the second and must not
collide with the first: the docs name the ref sense explicitly and record the separation.

---

## 3. Tests (every claimed behaviour needs a test that fails without the change)

### `tools/fleet/liveness.test.py` — T21–T27 + 6 paired mutations

| id | assertion | mutation (must go RED) |
|---|---|---|
| T21 | `claims-unreadable` ⇒ `unknown`, never `dead`, named reason | `if not cr.readable` → `if False` ⇒ falls to `no-claim-visible` |
| T22 | no claim visible ⇒ `unknown/no-claim-visible`, detail names HEAD-scoping + the no-claim window | delete the absent branch ⇒ `no-holder-record` (the defect: absence stops abstaining) |
| T23 | a claim verdict never sets `holder_pid`; owner identity is in `detail` | `detail` → `holder_pid=claim.owner_pid` |
| T24 | **enumerated invariant**: over the cross-product of {readable T/F}×{present T/F}×{scope local/foreign/unknown}×{lease live/expired/unknown} every verdict is `unknown`, reason ∈ the six-name set, `holder_pid is None`, and `lane_liveness.escalatable` is False | any claim reason → `Verdict("running-quiet", …)` |
| T25 | a claim-bearing `Evidence` that ALSO carries a growing transcript still reads `running-quiet/jsonl-grew` (session evidence outranks a claim); and `dead` is unreachable for a claim-shaped `Evidence` | move the claim block **above** the growth step |
| T26 | **inertness pin**: with `claim_read=None` the verdict is identical to the pre-change module over the existing `ev()` shapes | remove the `if ev.claim_read is not None` guard |

### `tools/fleet/claim_lanes.test.py` (new, stdlib-only) — legs + paired mutations

L1 pull-present (local + foreign, live + expired) · L2 pull-unreadable (rc≠0 / timeout / git absent) →
`claims-unreadable`, **never** empty · L3 pull-empty (rc=0, zero refs) ⇒ `readable=True, present=False`
· L4 presence-only (metadata fetch fails) ⇒ `present=True, owner="?"` ⇒ `claim-owner-unparseable` ·
L5 sibling heads disclosed · L6 snapshot missing ⇒ unreadable · L7 snapshot stale ⇒ unreadable ·
L8 snapshot drift (≠3 fields) ⇒ unreadable · L9 snapshot empty (0 bytes) ⇒ readable, 0 claims ·
**L10 lease parity**: drive the **shipped** `claims.sh` (`_claim_commit` + `_lease_of`, the
`selftest.sh:893` extraction technique) to produce real messages and assert the Python parser agrees
across {future, past, `0`, `-5`, 19-digit, non-digit, absent} · L11 reader emits no state (no
`STATES`/verdict names in `__all__`) · L12 local refs are never read (a bogus local ref beside an empty
origin still reads absent) · L13 output hygiene (hostile owner string neutralized in the text
rendering **and** in the JSON verdict `detail`/`witnesses`, the path a downstream consumer may
re-render) · L14 per-repo
binding: cwd repo ≠ target repo ⇒ reads the target · L15 multi-claim precedence: the cascade is total
and mutually exclusive · L16 the PR is bound from the **match**, never the `ls-remote` order ·
L17 a short `--sha` is a **prefix union**, so a decoy cannot consume the query · L18 two PRs on one
head sha return **every** match, order-independently · L19 CLI usage exits 2 and FILE mode reads a
snapshot end-to-end · L20 the default output is the TEXT report and declares the coverage gap ·
L21 a relative `origin` resolves to ONE absolute target, from any cwd · L22 a credential in the
remote URL never reaches `source`, text or JSON · L23 the mutation harness cannot read a
non-running test as "caught".

### `tools/fleet/lane_liveness.test.py` — DISCLOSURE leg + mutation

A CLEAN fixture rendered with a failing `git` shim on `PATH`: exit unchanged, the gap paragraph present
in the body **and** in `--json`'s `coverage_gaps`, and **no git/network call**. Mutation:
`COVERAGE_GAPS = (...)` → `COVERAGE_GAPS = ()` must go RED (one line re-creates the whole defect).

### Non-vacuity

Every mutation is run by the suite's own `--mutations` mode; a mutant that stays GREEN fails the suite.
The acceptance run additionally reverts the change in a scratch checkout and shows the new tests fail.

---

## 4. Wiring

| surface | change |
|---|---|
| `pi-bootstrap/setup.sh` | `fleet_tools=(liveness.py lane_liveness.py claim_lanes.py fleet-health.py map-sessions.py)` |
| `pi-bootstrap/tests/test-setup-no-nesting.sh` | the farm count string (4 → 5) and the per-file loop must be updated, plus a `diff` pin for the new copy |
| `tools/fleet/lane_liveness.py` | the farm-fatal message names the co-located siblings |
| `.github/workflows/ci.yml` (job `verify`) | two explicit steps: `python3.12 tools/fleet/claim_lanes.test.py` and `... --mutations` (nothing auto-discovers fleet suites) |
| `docs/ops/fleet-liveness.md` | artifact table; §4 reason table; §5 boundary row + **"the inputs are now FOUR"**; new §7 claim registry |
| `AGENTS.md` + `templates/AGENTS.base.md` | a base-owned liveness rule (twin edit; the base ⊆ AGENTS.md line-subsequence pin) |
| `~/.pi/agent/AGENTS.md` | the steering sentence itself (unversioned; the file the lane loads) |
| #1552 | comment: the second occurrence (`~/.pi/agent/scripts/lane-status.py:5,105`), the harness duplication (measured), and the deployed-vs-repo drift |
| tortoise#4761 | comment: this is the local-visibility half; the preflight-consumption half is that issue |
| `pi-bootstrap/setup.sh`'s farm path | **no circular import**: `Claim`/`ClaimRead` live in `liveness.py`; `claim_lanes.py` imports `liveness`; `liveness` never imports `claim_lanes` |

### Integration Docs

**New third-party dependencies: none** (stdlib only: `json os re socket subprocess sys tempfile shutil
time dataclasses typing`). Python floor: none enforced in-repo; CI pins 3.12. `git` is required only for
the PULL transport. API surface: `evaluate(Evidence) -> Verdict` stays pure and its signature is
unchanged; `Evidence` gains one defaulted keyword field; `Verdict` is unchanged. Adoption risk: none
for existing callers.

### Adversarial Threat Surface — DECLARED

Correctness claim: *an unreadable, foreign, absent, or hostile input can never become a false* **free**
(and never a `dead` escalation). Inputs are attacker-influencable (any box that can push to the repo
mints a claim with an arbitrary owner/lease; the snapshot is a file; the hostname is ambient).

| class | adversarial input | required behaviour | test |
|---|---|---|---|
| B1 head-scoped absence | a claim exists on another head of the same PR | `no-claim-visible` + siblings named; never free | L5 |
| B2 failed/unauthenticated/black-holed read | git rc≠0, auth failure, timeout, git missing | `claims-unreadable`; never empty | L2 |
| B3 missing/stale/drifting snapshot | absent file, mtime past the stated max age, ≠3 fields | `claims-unreadable` with the cause | L6/L7/L8 |
| B4 malformed lease | absent, `0`, negative, non-numeric, ≥19 digits | `lease_state="unknown"`, treated as **not** expired | L10 |
| B5 hostile owner | `?`, empty, no colon, non-numeric pid, newline/`\|`/backtick/ESC | `claim-owner-unparseable`, scope unknown, never probed, output sanitized | L4/L13 |
| B6 foreign pid reuse | a foreign owner whose pid exists locally | never probed; `holder_pid` stays `None` | T23 |
| B7 a claim must not mask a lane's death | claim + all-absent candidates + `jsonl_grew=False` | the claim abstains; the session path's `dead` semantics untouched | T25 |
| B8 stale local refs | a local `refs/claims/*` disjoint from origin | local refs never consulted | L12 |
| B9 precedence ambiguity | 2+ claims for one PR (live+expired, local+foreign) | the declared cascade: exactly one, deterministic reason | L15 |
| **B10 ref-order binding** (added by the VERIFY gate, **extended at cycle 2**) | a `--sha`-only read with a lower-sorting decoy claim in the namespace (`refs/claims/0-…`); a short `--sha` whose whole value equals another PR's `sha12`; two PRs carrying the **same** head `sha12` | the PR is bound from the **match**, never from `git ls-remote`'s order (which is lexicographic and attacker-influencable); a live holder must not be reported as absent; a short sha is a **prefix union** (a decoy cannot consume it); a multi-PR head returns **every** match and declares the ambiguity rather than indexing one by order; the sha is compared case-insensitively; the sibling disclosure must never name another PR's heads | L16, L17, L18 (+4 mutations) |

**Out of scope (declared):** whether the *remote* registry is honest (a box lying about its own lease is
#1709's duplicate-execution matter); session-lane verdicts (T1–T20, unchanged); git transport integrity
(TLS — delegated to git); drift between the versioned harness source and the installed `$O` copy
(#1552, and made irrelevant to the scheduled path by not reading the snapshot there); markdown/terminal
injection into an escalation issue body (claims never reach `render_report`'s escalation body — if the
deferred snapshot rows are ever added, `_md_cell` escaping is a precondition of that change).

**Bound:** 2 cycles (adversarial domain). Acceptance = **every declared class covered by a test + green
CI**; residuals filed from cycle 1, not chased.

### VERIFY-gate cycle 1 — one in-scope bypass found, fixed, and now declared

The verifier constructed a bypass the original surface did not cover: with `--sha` and no `--pr`, the
reader inferred the PR from `claims[0].pr` — the **lexicographically-first** ref — so a box pushing a
lower-sorting key made every `--sha`-only read search the wrong PR, report a live holder as
`no-claim-visible`, and name the wrong PR's heads as siblings. **Fixed** by matching the sha across the
registry first and binding the PR from the match (above), with case normalisation; **declared** as
**B10** and pinned by **L16** + 2 mutations (the ref-order revert, and dropping case normalisation).
Two secondary corrections from the same cycle: the CLI exit code was tightened from "0 = readable" to
**0 = a claim is visible, 3 = nothing established** (a readable absence exiting 0 is the incident's
exact input reported as machine-visible success), and the rendering now distinguishes
`present(namespace)` from `present_for_target` (`present=yes claims=0` could be read as one fact).

### VERIFY-gate cycle 2 — two further B10 instances found, fixed, declared, and pinned

Cycle 2 (same scope, fresh context) confirmed the cycle-1 bypass closed and the L16 mutation RED, then
constructed two further instances of the same root (the sha match was under-determined) — both now
fixed and pinned, so **B10 is a class, not a single input**:

* **N1 (P1)** — a **short** `--sha` whose whole value equalled a decoy's `sha12`: the exact-match set
  was non-empty, so a "fallback" prefix search never ran, the decoy consumed the query, and the real
  head was dropped even when the correct `--pr` was named (reported `no-claim-visible` while the real
  claim appeared as a *sibling*). **Fixed:** a short sha is a **prefix union**, and the union runs
  *before* the `--pr` filter. → **L17** + mutation.
* **N2 (P2)** — two PRs carrying the **same** head `sha12`: `pr = targets[0].pr` still let
  `ls-remote` order pick the PR, and the published sibling list suppressed the other PR's heads.
  **Fixed:** every match is returned and the ambiguity is declared in `detail`; no sibling list is
  invented across PRs. → **L18** + mutation.

⚠️ **BOUND REACHED — disclosed, not glossed.** The adversarial bound is **2 cycles**, and both were
spent (`[ADVERSARIAL-BOUND] cycles=2 threats=10 covered=10 residuals=none`). The cycle-2 fixes were
not re-reviewed by a third fresh reviewer; what stands behind them instead is that each is pinned by a
mutation-proven test (24 mutations, all RED-required) plus green suites. Any third-party doubt about
`_select` should be directed at L16–L18 rather than at this prose.

---

## 5. The rule correction (the real steering line)

The sentence that steered the controller — *"Session `.jsonl` mtime/size is the only reliable signal"* —
for a `--no-session` lane is not a weaker signal but **no signal**, and it actively steers the reader
away from the process/registry view. Corrected in all four places it belongs:

1. `~/.pi/agent/AGENTS.md` — the always-loaded copy (the file the lane actually reads);
2. `templates/AGENTS.base.md` — as a base-owned rule, so *every* materialized repo receives it;
3. `AGENTS.md` — mirrored verbatim-in-order (the base ⊆ AGENTS.md line-subsequence pin);
4. `docs/ops/fleet-liveness.md` — the versioned statement.

The named inference to kill: **"no session mentions it" ⇒ "nobody is on it"** is an argument from
absence on a **non-exhaustive** surface (epistemic coverage: absence is evidence of absence only in
proportion to how strongly the evidence was *expected*; for a lane class the surface cannot contain, the
weight is zero).

---

## 6. Acceptance criteria

1. `python3.12 tools/fleet/liveness.test.py` green (27 tests) and `--mutations` all RED-as-required.
2. `python3.12 tools/fleet/claim_lanes.test.py` green (23 tests) and `--mutations` all caught (24).
3. `python3.12 tools/fleet/lane_liveness.test.py` green with the DISCLOSURE leg and its red control.
4. **Headline invariant:** T24 proves every claim-shaped verdict is `unknown`, named, `holder_pid is
   None`, and `escalatable(...) is False`; T25/T26 prove the existing ordering and existing verdicts are
   unchanged.
5. `pi-bootstrap/tests/test-setup-no-nesting.sh` green (the new farm copy pinned).
6. **Live smoke (read-only, non-hermetic):** `claim_lanes.py --repo . --pr 1525` names
   `owner=cmux:2774092`, `lease=expired`, and abstains `unknown/holder-on-foreign-box` (the owner host
   is not this host, so the rung that fires is the provenance one — **corrected after the run**: this
   criterion originally predicted `claim-holder-unverifiable`, which is the rung for an *expired*
   **local** claim; both are abstentions, and the foreign rung is the more informative one); `--pr
   999999` prints `unknown/no-claim-visible` with the disclosure. `--pr 8697` (the incident's PR, whose
   ref is now gone) prints `no-claim-visible` too — the case that was read as free.
7. **Evidence artifact in-repo:** a demonstration that the pre-fix surfaces are blind and the post-fix
   reader names the holder (pid + lease age), plus the mutation proof.
8. `git grep -n 'refs/claims' -- tools/fleet/` is non-empty (the datum is read where it was not).
