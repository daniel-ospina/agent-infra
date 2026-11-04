# Orchestrator MCP server — Phase 1 inventory (agent-infra #3382)

**Status:** Phase 1 deliverable. Ships **no code**. Phase 2 (14 tools, one PR, one CI run) does not
start until this document is reviewed.

> **Phase 2 has started, and it started somewhere other than tool 1 (2026-11-04).** The owner steer recorded
> on #3382 puts the **lane state primitive** first: an orchestration MCP whose tools cannot answer *"did it
> finish"* is a typed façade over blindness, and this fleet ran 26 lanes without being able to answer it for
> any one of them. That primitive is [`lane-registry.md`](lane-registry.md) — `refs/lanes/*`, four states
> (`RUNNING` / `DONE` / `FAILED` / `EXPIRED`), written by `spawn-gate.sh::run_agent`, read by two MCP tools
> (`lane.list`, `lane.show`). It is **additive** to the 14 rows below rather than a replacement: it is the
> evidence axis those rows have no access to, and `tools/fleet/liveness.py` remains the one liveness verdict.
> **Every other tool in this inventory is still unimplemented, and the surface beyond the two read-only tools
> is a contract change awaiting owner approval** (named in `lane-registry.md` §6).

**The test this document must pass:** every proposed tool names an existing implementation as
`file` + `function`; every tool that is *not* a wrapper names why no existing tool can serve; and a
tool that duplicates an existing script without saying why is **deleted from the list** (see
[§6](#6-deletions--what-this-inventory-removed-from-the-list)).

---

## 1. O / I / T restated as an inventory obligation

- **Objective.** One MCP server exposing the orchestrator's recurring operations as typed tools with
  stable names, so the knowledge survives a session restart, is identical on every box, and is never
  re-written as a one-off script again.
- **Indicator.** (a) every beat's number comes from a tool, timestamped, with `UNMEASURED(...)` where
  a figure could not be read; (b) a fresh box after bootstrap reaches the same answers with zero local
  scripts; (c) **this inventory has no unexplained `NEW` row**.
- **Target.** 14 tool surfaces, one PR, one CI run, `instrument_versions()` reporting each wrapped
  module's sha256.

**Why the inventory is the gate, measured on 2026-11-03 (one session):** the orchestrator hand-wrote
an open-PR census **87** times, a P0/P1 census **22** times and an issue→PR linkage **37** times, while
`fleet-report.py` already had `section_pipeline` and `beta-progress.py` already had the P0/P1 counts.
The instruments existed and the orchestrator stopped trusting them, because they lied in six measured
ways ([§9](#9-the-six-measured-failures--fixture-status)). Duplicating a liar is cheaper than debugging
one, which is exactly the behaviour this issue exists to end.

---

## 2. Method, and the reads this document could not make

### 2.1 What was read, with counts

| Surface | Size measured on this box (2026-11-03) | How read |
|---|---|---|
| `scripts/` (agent-infra) | **482** tracked files — 335 `.sh`, 70 `.py` | full listing; every module named in §5 read at least to its docstring + CLI, and the 20 modules a tool actually wraps read in full or to their contract block |
| `scripts/orchestrator-harness/` | **173** tracked files, **87** non-test modules (excluding the `.test.` files and the six `test-*`/`selftest` helpers) | same |
| `tools/fleet/` | **9** non-test modules (+**8** `*.test.py` modules) | 6 read in full (`liveness.py` 1632 lines, `pr_state.py` 1034, `claim_lanes.py` 1019, `lane_liveness.py` 735, `fleet-health.py` 739, `map-sessions.py` 81) |
| `$HOME/.pi/agent/scripts/` | **101** non-`.bak` entries (96 files + 5 directories: `fleet/`, `gh-shim/`, `lib/`, `checkout-hygiene/`, `__pycache__/`) | listed; every entry in the issue read |
| `$HOME/.pi/agent/scripts/fleet/` | 6 modules | diffed against `tools/fleet/` — **the deployed `fleet/` is a COPY of tracked `tools/fleet/`** (`liveness.py`, `claim_lanes.py`, `lane_liveness.py`, `pr_state.py`, `fleet-health.py`, `map-sessions.py` all match by name), so it adds no surface, only a second copy that can drift |
| `extensions/` | **47** entries | listed; the ones that bear on the decision (`task-heartbeat.ts`, `builtin-tools/`, `mcp-client/`, `review-enforcer/`, `task-signal-forensics.ts`) read to contract level |
| `tortoise/tools/` | `who_is_on.py`, **`who-is-on.sh`**, `cmux_dispatch.py`, `collision_preflight.py`, `lane_stash.py`, `worktree_report.py`, `test_lane.py`, `run_reaper.py`, `attest_census.py` | docstrings + CLI of each. **Corrected:** the first draft missed `who-is-on.sh` and wrongly concluded it did not exist — see F7 |
| `$HOME/.pi/agent/state/` notes | **29** `FINDING-*` files, `LANE-STATE-DECISION-TREE.md` (173 lines, read in full), `BEAT-CHECKLIST.md` (37 lines, read in full), `LANE-BRIEF-PREAMBLE.md` | 8 `FINDING-*` notes read in full (the ones naming a classifier, actuator, aggregate or death defect); the rest listed |
| **`$HOME/.pi/agent/` and the rest of `$HOME/.pi/agent/state/`** | not enumerated in the first two passes | ⚠️ **Declared gap — it produced two false "does not exist" findings.** An earlier draft listed only the *notes* under `state/`, so searches for `instabox` never touched `INSTABOX-OPERATING-PROMPT.md`, `instabox-setup.sh` or `PAT-INSTABOX.md` sitting there — and concluded the procedure did not exist twice (F8). The whole directory is now read; §5 row 11 and F8 record what it contains |
| `git log --all` over `scripts/` + `tools/` | **605** files ever *added* to those two trees | `--diff-filter=A --name-only`; the newest 40 inspected |
| `gh search code` | 1 query, 8 results | returned only this repo's files. ⚠️ It is **not** evidence about other checkouts: the `who-is-on.sh` miss in the first draft came from an `rg` scoped to agent-infra whose conclusion was then written as "every checkout" (F7). One `find -maxdepth 3` across `~/Documents/GitHub` would have caught it, and did, on review |
| **`skills/cmux-cells/SKILL.md`** | **756** lines | **read in full**, and it changed four tool rows — see [F13](#f13--the-cmux-cells-skill-had-to-be-reconciled-with-four-rows-and-one-of-them-kills-a-tool-as-designed) and [§5.7](#57-semantics-authority--the-governing-skill-section-per-tool). It is the **semantics authority** for these operations, so it was read as a source of record, not as background |
| **external prior art** | 6 sources, URLs in [§8](#8-external-prior-art) | `research` skill; graph queried first (`tortoise_search`) |

### 2.2 Reads this document could NOT make — declared, not skipped

The fleet's own doctrine is that a surface must declare the read set it **could not** consult; a
silence about a gap is indistinguishable from a clean bill of health.

1. **No cloud cell was touched.** Three lanes died silently on the cells tonight (agent-infra#3331 is
   the fix), so cell-only state was not read. Consequence: the cell *branch* of
   `box_exec`/`lane_artifact`/`lane_dispatch` is specified from source (which is portable by
   construction, §10) and **not** demonstrated against a live cell in Phase 1.
2. **`ps`-level CPU sampling was not re-measured.** The tree's Step 2 instrument
   (`ps -o time` cumulative, two samples) is read from source; the 2026-09-30 measurement
   (3 of 73 processes moving by `pcpu`) is **cited, not re-derived**. Phase 2's fixture for Step 2
   must measure it again on the box it runs on.
3. **Load was ~25 on 10 CPUs** during this pass (measured `14:33 up 8 days, 22 users, load averages:
   25.41 22.22 23.15`). Per the lane's own constraint that is *at* the ceiling, so this inventory was
   produced **serially** — no parallel fan-out of sub-agents. Consequence: some modules were read to
   contract level rather than line-by-line, and where that matters the row in §5 says so.
4. **External prior art is a 6-source pass**, not a systematic review. It was enough to settle the
   MCP-vs-extension question and to name the one comparable (a Kubernetes MCP server) whose published
   regret applies to us. It is not a survey.

---

## 3. Headline findings (each one changes a Phase 2 decision)

Each finding below is a fact about *today's* code, not a preference.

### F1 — The liveness decision tree is implemented in **three** modules, and **`liveness.py` alone does not implement it**

The issue says `lane_status`, `lane_tree` and `lane_artifact` "MUST implement the existing decision
tree", and that `fleet/liveness.py` is the ONE verdict function. Both statements are true as
*intent*; the tree's steps are in fact split across three files, and `liveness.py` implements a
**subset**. Full matrix in [§4](#4-where-the-liveness-tree-actually-is-today). Consequence: **the missing steps get implemented INSIDE `liveness.py`** — the plan issue §1.2 already fixes
(§4.2); an earlier draft's "compose the three CLIs" was the wrong remedy. The doc that says "`lane-status.py` …
`tools/fleet/liveness.py` stays the ONE verdict function" is currently a *claim* the code does not honour
(`scripts/lane-status.py:126`) — which is why the work exists, not a licence to leave the split.

### F2 — The issue's five surface states have **no slot for `dead`**, which is the state `liveness.py` exists for

`liveness.py`'s vocabulary is `dead | running-quiet | wedged | idle | unknown`. The issue's surface
vocabulary is `alive | working | frozen | finished | no-verdict`. Mapping the second onto the first
loses `dead` — the one state whose invisibility cost five hours (the module's own header) and whose
detection is the whole point of #1178. **Recommendation: six states, `dead` added** — put to the
owner as a **reopen** (the five states are the issue body's own Phase-2 table), with invariant 3
("a finished lane is never reported dead" presupposes `dead` is a reportable value) as the *evidence
for* the reopen, not as a licence to skip it. See
[§4.3](#43-the-vocabulary-gap-requires-a-decision-in-phase-2).

### F3 — Three modules a tool is meant to wrap are **untracked** — they exist only on this box

`"Deploy path, not copy path"` is a constraint in the issue. Three wrapped modules **fail** it today:

| file | tracked? | deployed copy | consequence |
|---|---|---|---|
| `fleet-report.py` (census `section_capacity`/`section_pipeline`/`classify`) | **0 files in git** | `~/.pi/agent/scripts/fleet-report.py`, 200 lines | cannot be deployed by bootstrap at all; a fix applied on this box is lost on redeploy. Its own comment shows a *fix that lives only here*: the `lanes=` counter corrected to `lane.sh` + `pi` after the "**LANE COUNTER ZERO**" failure |
| `orch-checkpoint.sh` (beat checkpoint / 20-min nudge) | **0 files in git** | `~/.pi/agent/scripts/orch-checkpoint.sh`, 86 lines | same |
| `state/lane-verdict.py` (the JEV Step-5 verdict module `lane-actions.py` imports, and one of the **five** `jev-latest` pins AGENTS.md enumerates) | **0 files in git** | `~/.pi/agent/state/lane-verdict.py` | a model pin lives in an untracked file; a re-pin sweep cannot see it |

**Consequence for Phase 2:** `fleet_census` and `beat_checkpoint` cannot be wrappers over code that is
not in the repo. Their first step is to **land those bytes into `scripts/`** (tracked), then wrap the
tracked copy. That is work inside this issue, not a follow-up, because otherwise the tool wraps a
file that the fleet's own deploy cannot reproduce.

### F4 — The **FALSE MERGED** root cause is a *mention* counted as a *closure*

`fleet-report.py::section_p0p1` builds `merged_refs` from **regex `#(\d{4,5})` matches in merged PRs'
`title`/`body`/`headRefName`**, intersects it with the open P0/P1 issue numbers, and prints the
intersection as `merged last hour`. The regex requires a literal `#`, so the trigger is a **`#N`
occurrence anywhere in the title, body or branch name** — a branch named `p0-10000` matches nothing
(verified: `[]`), while a title saying `fixes #10000` matches, and so does a branch containing
`#10000`. The first draft's `p0-10000` example was wrong and is corrected here, because a fixture
author would have written a branch-only case that can never go red. That is the measured "**all seven were `open`**": the number was printed from a **keyword**,
never from a close event. (Verified by reading the function; the sibling `section_pipeline`'s merged
list *does* filter on `mergedAt` from a `--state merged` query, which returns `state: MERGED` when
queried live — so the defect is specific to §3, not to §2.)

This is precisely what tool #12 `closure_audit(pr)` must answer, and it is why `closure_audit` is a
**wrapper of `gh`'s closing references**, not of `beta-progress.py`: there is no existing
implementation of "what did this merge actually close".

### F5 — The **FALSE UNMEASURED** root cause is a two-way conflation, plus a crash path

`fleet-report.py::gh_json` returns `None` for (i) `rc != 0` and (ii) a JSON parse failure — and the
callers print a reason naming **only** the first (`UNMEASURED(gh issue list failed …)`). So a run where
`gh` **succeeded** and the payload did not parse reported "gh failed". The failure was measured as a
*false* statement about the cause, not as a missing number. A third outcome is not even a `None`:
`sh()` calls `subprocess.run(..., timeout=120)` with no `try/except`, so a timeout raises
`TimeoutExpired` and takes the whole section down with a traceback instead of reporting anything.
Invariant 1's test must therefore assert on the **string inside** `UNMEASURED(...)`, not merely that
`UNMEASURED` appeared: `UNMEASURED` with the wrong cause is still a lie. (Corrected from a first draft
that called this a three-way conflation — the timeout does not reach the `None` path; it is a crash,
which the same fix must also cover.)

### F6 — `pr_state.py` already **supersedes** `fleet-report.py::classify`, so the census must not wrap both

`tools/fleet/pr_state.py` (1034 lines, #2866) implements the same one-cause-per-row table plus a
head-bound attestation fidelity (`at-head` / `carried` / `owes-review` / `diff-unreadable`) and the
`(app, workflow, job)` grouping with the polarity rule. It is the newer, reviewed, tracked
implementation. Wrapping `fleet-report.py::classify` alongside it would create a second PR classifier —
the exact duplication the issue exists to prevent. See deletion **D1**.

### F7 — `who-is-on.sh` **does exist** — in the product repo, not in agent-infra

**Corrected.** A first draft of this document said the file does not exist. That was **wrong**, and
the way it was wrong is worth recording: the search was scoped to agent-infra while the sentence
claimed "every checkout" — an undeclared-coverage inference, the exact defect class this fleet's own
liveness doctrine names.

`tortoise/tools/who-is-on.sh` is **tracked** (1954 bytes, `git ls-files tools/` returns it alongside
`tools/who_is_on.py`), and four copies sit across this box's checkouts. It is **a 35-line file whose
last three lines are the whole of its body** — a shim, not an implementation: that body `exec`s
`who_is_on.py` (953 lines), which in turn
`import collision_preflight as cp` (9132 lines) — "importing it keeps ONE implementation of matching
and git enumeration". Its header answers #6's exact
question — *"`tools/who-is-on.sh <N> [--repo <path|owner/name>]` — who holds issue #N (local +
remote)"* — with the same fail-closed doctrine (`0` = complete answer, `2` = a surface could not be
read, never a bare `1`).

What this changes is **not** whether #6 has a wrap target — it does — but **which repo it lives in**:
the server ships from agent-infra and is materialised into every installation by bootstrap, so it
cannot invoke a path in the product repo (a box without tortoise checked out, or with a different
revision of it, would silently get a different answer). Row 6 and deletion **D2** are rewritten
accordingly: `claim_lanes.py` is the *registry* axis (server-side, `refs/claims/`, HEAD- and
issue-keyed) and `who-is-on.sh` is the *local-checkout* axis (unpushed branches, dirty worktrees, work
that exists only on this disk). They are different questions and #6 must say which one it answers —
and the port is not one file: the shim plus `who_is_on.py` plus a decision about its
`collision_preflight` dependency. See row 6, D2 and Appendix A.

### F7b — The **local-checkout** axis has a second owner too: `collision_preflight.py`

`tortoise/tools/collision_preflight.py` (9132 lines, #3061) is the "fail-loud, all-surface in-flight
work pre-flight" and `who_is_on.py` **imports it deliberately** rather than re-enumerating git state.
So the honest count for #6 is **three** existing implementations across **two** axes —
`claim_lanes.py` (registry), `who-is-on.sh` + `who_is_on.py` (local+remote, human-facing) and their
`collision_preflight` dependency (pre-dispatch pre-flight) — and Phase 2 must name which one it wraps
per axis rather than inventing a fourth. See row 6 and D2, which carry the decision.

### F8 — `InstaBox` **is documented, installed and warmed** — tool #11 is a `PARTIAL` wrapper, not a `NEW` tool

**Corrected twice, and the second correction is the one that matters.** A first draft said the
InstaBox procedure does not exist. A second draft repeated it after widening the search to "all 20
checkouts, `docs/`, `skills/`, `$HOME/.pi/agent/scripts/`" — which still omitted **`$HOME/.pi/agent/`
and `$HOME/.pi/agent/state/`**, the two directories the procedure actually lives in. That is the same
undeclared-coverage inference as F7, reintroduced one finding later, and it is the reason §2.1's read
scope is now written out field by field rather than summarised.

What is actually on the box:

| artefact | what it is |
|---|---|
| `~/.local/share/pi-node/current/bin/instabox` | the installed CLI (v0.8.125) |
| `~/.pi/agent/instabox.json` | the key — `machines:read/write/delete`, `images:read`, expiring 2027-01-31, **already 0600 in a 0700 dir** |
| `~/.pi/agent/instabox-setup.sh` | the setup implementation (1473 B): toolchain, `--setup-file` trap, health check |
| `~/.pi/agent/state/INSTABOX-OPERATING-PROMPT.md` | **the documented procedure** (6283 B, 2026-11-02): create / start / stop / exec / rm recipes, the `--setup-file` toolchain trap, guard gotchas, health check, budget and kill-switch, and the standing rule *"InstaBox is NOT a CI runner for us — never change `runs-on:`"* |
| `~/.pi/agent/state/PAT-INSTABOX.md` (+ `PAT-INSTABOX-BRIEF.md`) | 14739 B: a falsifiable independent-verification protocol — `SCOPE(...)`, a negative write test, `INSTALLED(mode,path)`, `PROVEN(before,after)` |
| `~/.pi/agent/state/poke-loop-inner.sh` | the live poke already tells the orchestrator to use it as an independent verifier: *`instabox start …`, then `instabox exec … -- git clone --depth 1 --branch <head-branch> <repo> …`* |

So the create→clone-at-ref→run-the-lane's-steps→stop procedure §7.3 was written to supply **already
exists and is already in the orchestrator's own instructions**. What does not exist is the **typed
surface**: `{rc, stdout, timed_out, truncated}`, an MCP tool name, and a teardown that is guaranteed
rather than remembered. #11 is therefore `PARTIAL` (wrap the CLI + `instabox-setup.sh` + the operating
prompt), it is not `NEW`, and `~/.pi/agent/instabox.json` being unconsumed **by a script** is not a
security finding — it is a working credential whose consumer is the agent itself.

### F9 — `harness-provenance.sh` already answers invariant 5; `instrument_versions()` must not grow a second hasher

`scripts/orchestrator-harness/harness-provenance.sh` writes/checks a provenance record of the deployed
tree (`write` / `check` / `show`, **exit 2 = UNKNOWN, never a pass**), and
`check-deployed-drift.sh --surface` compares every place a harness script lives on this box against a
ref. `instrument_versions()` is therefore a **wrapper + a startup gate** (refuse to start on exit 1 or
2), not new machinery. This is the single biggest saving in the whole inventory: invariant 5 is
already implemented and merely not *consulted at startup*.

### F10 — The module the liveness matrix rests on is **stale on this box**, and the stale copy is the one that runs

Tracked `scripts/lane-status.py` is **2528** lines. The deployed `~/.pi/agent/scripts/lane-status.py`
is **2046**, and it contains **zero** occurrences of `lane_cpu_progress` or `UNATTRIBUTED_WORKING` —
both of which the tracked copy carries, and the second of which `docs/ops/fleet-liveness.md` §11
describes as now enforced. `scripts/lane-actions.py` invokes the **deployed** copy by absolute path
(`LS_PATH = os.path.join(SCRIPTS, "lane-status.py")`), so the classifier chain that actually runs on
this box is older than the repo.

This is the deploy-drift failure F9 exists to detect, measured **on the very module §4.1's matrix
describes** — so the matrix must say which copy it describes. It describes the **tracked** copy, and
Phase 2 must do one of two things explicitly: call the tracked/pinned copy, or report the deployed
copy's identity as part of every verdict. Silently calling whichever copy `$HOME` happens to hold is
the "stale deployed copy must be detectable, not silent" failure invariant 5 exists for.

### F11 — There are **two** cumulative-CPU implementations and **two** JEV content callers, not one

Corollary of F10, found while verifying the §4.1 matrix and missed by its first draft:

- `tools/fleet/fleet-health.py::cputime_secs` runs `ps -o cputime=` and deltas it against
  `fleet-health-prev.json` (`quiet 1s, CPU +0.5s -> working`) — a **second** implementation of tree
  step 2's cumulative-CPU instrument, whose own header calls it the "strongest cheap 'is it actually
  running' signal".
- `scripts/turn-classify.py` makes a JEV call over a lane's own last text — a **second** caller of the
  step-5 content layer, beside `scripts/lane-actions.py`'s batched per-fleet call.

So "one home per step" is **false today**. The consequences for Phase 2 are explicit: the tool must
pick **one** CPU reader (`lane-status.py`'s, which carries the exactly-one-lane-to-one-process
attribution guard — `fleet-health.py`'s does not) and **one** JEV caller (`lane-actions.py`'s batched
call, which is one round trip for the fleet), and the other two are deletions (**D7**), not alternatives
to re-derive.

### F12 — The issue's own six measured failures are **not all reproducible today**

**None is red-first against today's shipped code.** Two are red-first only against their **replacement** (their
mechanism lives in an untracked file, so no repo test can exercise it), one is repaired in tracked code **and**
mutation-testable from history, two need a composition or a mapping that does not exist yet, and one is blocked
on landing untracked bytes. The per-failure allocation is §9's; do not re-derive a count from this sentence. Table with per-failure status and
what the red-first fixture must target: [§9](#9-the-six-measured-failures--fixture-status). A "red-first" fixture written
against already-fixed behaviour passes on the broken version and proves nothing — the very thing
invariant 6 forbids.

### F13 — The `cmux-cells` skill had to be reconciled with four rows, and one of them **kills a tool as designed**

`skills/cmux-cells/SKILL.md` is the semantics authority for the operations these tools expose
([§5.7](#57-semantics-authority--the-governing-skill-section-per-tool)). Reading it against the 14 rows
changed four of them, and one change is not cosmetic:

1. **`lane_message` (#8) must be able to REFUSE.** Skill §5: *"⛔ A LANE LAUNCHED WITH `pi -p` CANNOT BE
   STEERED"* — print mode takes its prompt from argv and never reads stdin, so a message to such a lane
   is text nothing consumes. Measured in the skill: 9 lanes ordered to stop producing, `order-seen=0` on
   **every one**. My row treated delivery semantics (`cmux_dispatch.py`'s five exits) as the whole
   problem. It is not: the tool needs a **precondition** — is this lane steerable at all — or it
   becomes a very precise instrument for delivering into a void. The skill also names the remedy
   (kill and relaunch with a new brief; a steerable session is an *interactive* one).
2. **`fleet_census` (#4) must not carry one load threshold.** Two calibrations, opposite directions
   (§10.1). This is the change most likely to have shipped as a plausible-looking bug: a cell number
   applied to the laptop calls a dying box healthy, and the census is exactly the tool the beat trusts.
3. **`box_exec` (#9) must keep `timed_out` away from `box-unreachable`.** Skill §3: unreachable is a
   claim about the CHANNEL. A disk-full guest answers `running` while every `exec` times out — the exact
   case that would be misreported as a dead box.
4. **`closure_audit` (#12) must not reason from ancestry.** The rail squashes (skill §6.5), so
   constituents of a batch stay **open**; an ancestry check reports false *not merged* for every batched
   PR. That is the FALSE MERGED defect mirrored — the same failure family, in the opposite direction.

**The general lesson, recorded because it is the argument for this whole section:** every one of those
four is a rule that *already had an owner*, and in each case the skill's version was sharper than the one
I would have re-derived. A tool that restates an owned rule does not merely duplicate it — it replaces a
measured version with a remembered one.

---

## 4. Where the liveness tree actually is today

### 4.1 Step-by-step, by module

Sources: `$HOME/.pi/agent/state/LANE-STATE-DECISION-TREE.md` (the tree),
`docs/ops/fleet-liveness.md` (the five states and the ordering), `docs/ops/lane-signal-forensics.md`
(what the instrument cannot answer), `docs/ops/fleet-capacity.md` (placement, not liveness).

| Tree step | `tools/fleet/liveness.py` | `scripts/lane-status.py` | `scripts/lane-actions.py` | Verdict |
|---|---|---|---|---|
| **0 — identity** (label→session; PROTECTED; AMBIGUOUS-IDENT; `UNBOUND`) | store record + argv candidates + the #1777 claim axis; unbound ⇒ `unknown/no-holder-record` | `resolve_session_ex`, `workspace_cwds`, `_pi_cwd_map` — the *evidence* (identity, PROTECTED default, unreadable-cwd ⇒ PROTECTED) | `lane_identity`, `lane_cwd`; and the **tokens** `PROTECTED` / `AMBIGUOUS-IDENT` are emitted here (`:1667`, `:917`) | **implemented twice**, different predicates — the tree's "use a predicate, not a name list" lesson lives in `lane-actions.py` |
| **1 — process exists** ⇒ `DEAD` | ✅ `collect_candidates` + `is_dead_evidence` + probe exit 1 vs 2 (`scripts/lib/pid-identity.sh`) | ✅ `child_process_alive`, pid files | consumes | ✅ both, fail-closed in both |
| **2 — CPU-time delta** (cumulative CPU time, two samples, stated tolerance) | ❌ **not sampled here** — consumes already-computed `cpu_advanced`/`cpu_stall_ms` tick fields | ✅ `lane_cpu_busy()` diffs cumulative `ps -o time`, and refuses attribution unless exactly one lane maps to exactly one process | consumes (`classify_row`) | ✅ here **and** in `tools/fleet/fleet-health.py::cputime_secs` (`ps -o cputime=` delta vs `fleet-health-prev.json`) — **two** implementations, only this one has the attribution guard (F11) |
| **3 — child in flight** | ❌ no child field in `Evidence` | ✅ `child_suppresses()`, `child_activity()`, `declared_children()`, `lane_child_prefixes()` | consumes (`child_evidence`) | ✅ **only** in `lane-status.py` |
| **4 — last tool call + its age** | ✅ `tool_from_jsonl` → `Tool.tool_age_ms`/`silence_age_ms`; `tool_veto_expired` | ✅ `last_tool_call`, `LONG-TOOL` | consumes | ✅ both |
| **5 — read what it said** (the ONLY step that yields meaning) | ❌ (by design — a pure mechanical verdict) | ❌ | ✅ `classify_row` + one batched JEV call (`state/lane-verdict.py`); `UNCLASSIFIED(JEV-DOWN)` when unread | ✅ here **and** in `scripts/turn-classify.py` (a JEV call over one lane's last text) — **two** callers, this one is one round trip for the fleet (F11) |
| **6 — hard cases by RECURSION** (CHILD-OVERDUE ⇒ apply THIS SAME TREE to the child) | ❌ | partial: `child_suppresses` suppresses parent verdicts to `WAITING`, does not verdict the child | ❌ | ❌ **nowhere** — see §7.1 |
| `finished` (§11, #2163) | not a `STATES` member; `running-quiet` + resident | `DONE-IDLE`-family | `DONE_READY` (Step-5 words) | partial — the gates are `lane-reap.sh`'s, but its `--json` is **aggregate-only**, so per-lane `finished` has no typed source today (§4.2). ⛔ **NOT `count`**: that verb is the capacity census — "live iff the process tree exists AND its log advanced within `LANE_REAP_LIVE_MIN`" — with **no CPU gate and no ancestry gate**, so wrapping it would call any silent lane `finished` |

### 4.2 What this means for the tool — and the plan the issue already fixed

⛔ **The issue already decided this, and an earlier draft of this document departed from it.**
Section 1.2 of issue 3382, verbatim:

> **One verdict function.** `fleet/liveness.py` (with `lane_liveness.py` as its reader) is the only
> classification logic. Do not write a second. **If the tree is not fully implemented there today,
> implement the tree in it and say so.**

F1 says the tree is **not** fully implemented there. The issue's instruction for that case is
therefore explicit and unambiguous: **the missing steps get implemented inside `liveness.py`.** An
earlier draft of this section instead re-homed each step to whichever module happens to already have it
— `lane-status.py` for steps 0–4, `lane-actions.py` for step 5, `lane-reap.sh` for `finished` — and left
`liveness.py` consulted "for identity/abstention, not for the whole verdict". That is the opposite
remedy, and it would have produced a **fifth place** where lane classification lives, permanently,
while the design document was the thing that skipped the question.

**The corrected Phase-2 plan, in the issue's own terms:** `liveness.py::evaluate` becomes the tree.

| tree step | Phase 2 |
|---|---|
| 0 identity, 1 exists | already there — unchanged (`collect_candidates`, `is_dead_evidence`, the claim axis) |
| **2 CPU-time delta** | **new `Evidence` field + sampler call**, using `lane-status.py::lane_cpu_busy` as the *sampler* (it carries the exactly-one-lane-to-one-process attribution guard, which is the whole value) — `fleet-health.py::cputime_secs` is the loser (D7) |
| **3 child in flight** | **new `Evidence` field** + attribution (`ambiguous` must stay an abstention) |
| 4 last tool / age | already there (`tool_from_jsonl`, `tool_veto_expired`) |
| **5 read what it said** | **new, and optional by construction**: a content provider the caller supplies (`lane-actions.py`'s single batched JEV call). Unread ⇒ `UNCLASSIFIED(JEV-DOWN)`, never a guess — the ladder must reach Step 5 only when steps 2–4 did not decide |
| **6 recurse into the child** | **new**: `evaluate` applied to the child, per the tree's own instruction ("apply THIS SAME TREE to the CHILD") |
| `finished` | **new state — and it needs a SURFACE CHANGE upstream, not a wrapper.** ⛔ `lane-reap.sh reap --json` emits **one aggregate object** (`trees`, `zombie`, `candidates`, `reaped`, `refused`, `inert`, `unidentifiable`, `abstained`, `apply`) with **no per-lane row and no lane identity**; its per-tree decisions exist only as prose keyed by process root (`REFUSE root=<pid> …`, `WOULD REAP root=…`, `SKIP root=…`). So there is today **no per-lane machine-readable source for `finished`**. Phase 2 does one of exactly two things, and says which: **(a)** extend `reap --json` with one row per tree carrying `{root, lane, log, gates{cpu,ancestry,stale}, verdict, reason}` — the right place, because the reaper owns the three gates (§4.1) — or **(b)** report `finished` per lane as `UNMEASURED(lane-reap-has-no-per-lane-output)`. What it must NOT do is parse the prose or read the aggregate `trees=` count as a per-lane answer; and it must not call the pass per lane (a full pass costs `LANE_REAP_WINDOW`, default 30 s) |

So the other modules are **evidence suppliers to one classifier**, never parallel ladders. That is what
makes `lane_tree` (#2) safe to build: the recursion is a call to the same function, not a second rule.
And it makes **D8** a real deletion rather than a preference: `lane-status.py`'s own verdict ladder
(`WORKING` / `WIP-IDLE` / `DONE-IDLE` / `WEDGED` / `CHILD-STUCK` / `UNATTRIBUTED-WORKING` …) must be
retired or reduced to narration, because after Phase 2 `liveness.py` is the classification logic and
two ladders answering "is this lane stuck" is precisely the defect #1178 closed.

**Why this is more work than wrapping, stated plainly:** the issue asked for a façade, and its own
§1.2 forbids the cheap version of one here. Phase 2's slice for tools 1–3 is therefore *finishing the
tree in `liveness.py`* plus the typed surface — not a composition of three CLIs. The composition plan
is kept below as the **evidence map** it still is, and each arrow now points at an input to one
function rather than at a verdict:

```
liveness.py::evaluate            ← the ONLY classifier (the tree, all six steps)
  ├─ lane-status.py --json         → evidence: CPU delta (attribution-guarded), children, tool age
  ├─ lane-actions.py / lane-verdict → evidence: Step-5 words (one batched JEV call) — optional
  ├─ lane-reap.sh reap --json       → evidence: the three gates that make `finished` a state — **only after (a) adds a
  │                                     per-lane row; before that this input is absent and `finished` is
  │                                     UNMEASURED (b)**
  └─ claim_lanes.py                 → evidence: the ref-claim axis (unchanged, already inside)
```

**The copy question is answered, not inherited:** every input resolves to the **tracked** module, or the
tool reports which copy it read. Today `lane-actions.py` inherits whatever
`$HOME/.pi/agent/scripts/lane-status.py` holds, and that copy is stale (F10).

### 4.3 The vocabulary gap requires a decision in Phase 2

| issue surface state | from which existing source | note |
|---|---|---|
| `alive` | `liveness.py:running-quiet` (live holder) | NOT "a process exists" — day-1 `liveness.py` state names |
| `working` | `lane-status.py:WORKING` / `UNATTRIBUTED-WORKING` (Tree step 2) | only `lane-status.py` can produce it today |
| `frozen` | `liveness.py:wedged` **only** on a positively open turn | never on a frozen file alone (#1254) |
| `finished` | `docs/ops/fleet-liveness.md` §11's three gates, which live in `lane-reap.sh` (**not** its `count` verb) — with no per-lane typed output today (§4.2) | **not a `STATES` member** today |
| `no-verdict` | `liveness.py:unknown` + its named reason (`ps-unreadable`, `no-holder-record`, `off-fence`, `turn-state-unknown`, `claims-unreadable`, …) | the reason string is part of the contract, never optional |
| **`dead`** | `liveness.py:dead` (`incarnations-absent`) | **missing from the issue's list** — see F2 |

**⚠️ This is a REOPEN, not a design choice inside Phase 2, and it is put to the owner rather than
assumed.** The five states are stated in the issue body's own Phase-2 table, which makes them a
recorded decision; the fleet rule is that a recorded decision is not quietly amended by the lane
implementing it. The evidence for reopening is specific:

- tree **Step 1** emits `DEAD` as a verdict, and `liveness.py` has `dead` in its `STATES` tuple;
- the issue's **own invariant 3** says "a finished lane is never reported **dead**" — a sentence that
  presupposes `dead` is a reportable value;
- `docs/ops/fleet-liveness.md` §1 treats `dead` as a distinct conclusion resting on distinct evidence
  (non-empty candidate set, every candidate positively absent or zombie, non-growth positively known);
- collapsing it either way is a known failure: into `finished` and invariant 3 is violated; into
  `no-verdict` and a positive finding reads as an abstention — the false negative #1178 existed to
  remove, whose cost was a five-hour loss.

**The ask, in one line, on the issue:** *may `lane_status` return six values rather than five, adding
`dead`?* Until the owner answers, **Phase 2 implements the five states as written** and carries the
`dead` finding in a separate field (`dead: true` + the existing `incarnations-absent` reason), so the
information is not lost and the naming decision stays the owner's. That satisfies both directions:
the contract is not silently changed, and a positive death finding is never reported as `no-verdict`.

---

## 5. The 14 tools

Legend — **Class:** `WRAPPER` (an existing implementation answers the question; the tool adds typing,
one stable name and the `UNMEASURED` contract) · `PARTIAL` (an existing implementation answers part of
it) · `NEW` (nothing does; justified in §7).

### 5.1 Liveness (tools 1–3)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 1 | `lane_status(lane\|box\|all)` | `scripts/lane-status.py` (`lane_cpu_busy`, `child_suppresses`, `last_tool_call`, `resolve_session_ex`, 2528 lines) + `scripts/lane-actions.py::classify_row` (Step 5, JEV) + `tools/fleet/liveness.py::evaluate`/`gather` (identity, `dead`, abstentions) + `scripts/orchestrator-harness/lane-reap.sh` (**owns the three gates that make `finished` a state, but emits no per-lane output — §4.2**) | one typed answer over all four; a stable state vocabulary across them; `dead` absent from the issue's list; `reason` string not surfaced | **`liveness.py::evaluate` becomes the tree (§4.2)** — steps 2, 3, 5, 6 and `finished` are added to it, per issue §1.2; the other modules become evidence suppliers to that one function. Concretely, four inputs, each with its own output shape: `lane-status.py`, `lane-actions.py` and `liveness.py` take `--json`; **`lane-reap.sh` exposes `--json` only on `reap`, not on `count`, and that JSON is aggregate-only — no per-lane row and no lane identity — so per-lane `finished` is `UNMEASURED(lane-reap-has-no-per-lane-output)` until the reaper's surface carries one (§4.2 (a)/(b))**. `count` serves the capacity census only, its `lanes=<live>/<total> zombie=<n>` line (or `lanes=?/?` + exit 3) carried as the abstention. ⛔ Wrapping `count` as the verdict would call every lane silent past `LANE_REAP_LIVE_MIN` `finished`: that verb has no CPU gate and no ancestry gate. State mapping: the **five** states as the issue writes them, with `dead` carried in a separate `dead: true` field until the owner answers the reopen (§4.3) | **PARTIAL** — the tree's missing steps are written, then the surface is typed (§4.2) |
| 2 | `lane_tree(lane)` | `tools/fleet/lane_liveness.py::child_sids` + `enumerate_lanes(…, children)`; `scripts/orchestrator-harness/lane-artifacts.sh` (cell artifacts); `~/.pi/agent/task-sessions/<uuid>/` | **Applying the tree to the CHILD** (Step 6). `child_suppresses` only demotes the parent's verdict; `enumerate_lanes` lists child sessions but does not verdict them. Measured consequence: `state/FINDING-lane-classifier-ignores-task-children-2026-10-11.md` — **four** lanes tabulated as false `IDLE`/`WEDGED`/`STALL` verdicts (one of them marked "presumed"), plus a fifth entry under a fourth label (`WIP`), every one a lane holding or presumed to hold a `task` child | compose: `lane_status` per node (this is Step 6's own instruction) + `child_sids` for the edge set; the recursion is the tool, not a new rule | **PARTIAL** (§7.1) |
| 3 | `lane_artifact(lane)` | `scripts/lane-read.py` (`sid_for`, `files_for` — last N assistant messages by pane); `scripts/orchestrator-harness/lane-artifacts.sh` (verbs, exit `0 found · 3 ABSENT-EVERYWHERE · 4 UNMEASURED · 5 PULL-FAILED`); `BEAT-CHECKLIST.md`'s `## LANE-DONE <verdict> <ts>` line | one answer over *both* axes: a session lane's words AND a **cell** lane's file (the 2026-11-01 measurement: four mandated artifacts existed, each on a different box, none reachable from the mac); size/age/terminal-line in one shape | wrap `lane-read.py` for words, `lane-artifacts.sh` for files; read the `## LANE-DONE` line as the terminal verdict; "none written" is a value, not an error | **WRAPPER** (two implementations, one answer) |

### 5.2 Census and PR surface (tools 4–6)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 4 | `fleet_census(repos)` | `scripts/beta-progress.py::compute`/`main` (P0/P1 open·with-PR·NONE, age printed, cache validator, `DELIVERY [as of …]` line); `scripts/orchestrator-harness/capacity.sh probe` (measured placement: refuses to ADD work at `CAP_LPC_CEILING` = **8.00 load-per-CPU**, `>=`, which is a placement gate and NOT the platform's tolerance — see [§10.1](#101-the-two-capacity-calibrations--the-trap-that-would-call-a-dying-mac-healthy)); `scripts/orchestrator-harness/box-status.sh` (**six** machine-parsable lines on exit 0: `harness:`, `stamp:`/`pin:`, `ref:`, `controller:`, `running:`, `roles:` — `ref:` is `UNRESOLVED(…)` or absent when it exits **2**); `tools/fleet/fleet-health.py`; `scripts/fleet-schedule.py --status`; `BEAT-CHECKLIST.md` checks 1-3 | one typed object per box+repo; **`fleet-report.py` is untracked (F3)** and its §3 "merged" is a keyword mention (F4); no `measured_at` field (the text line has one, the bytes do not) | wrap `beta-progress.py --json`-shaped output + `capacity.sh probe` + `box-status.sh`; **land `fleet-report.py` into `scripts/`** or drop its dependency (D3); every figure carries `value`, `measured_at`, `age_ms`, `source` | **WRAPPER** (tracked modules only) |
| 5 | `pr_queue(repo)` | `tools/fleet/pr_state.py` — `action_for`, `row_action`, `fidelity`, `inherited_reds`, `verdict`; rows `CLOSE-STALE`/`WAIT:draft`/`REPAIR-CONFLICT`/`FIX-RED`/`RERUN-FLAKE`/`WAIT:inherited-red`/`REVIEW`/`WAIT:attested-elsewhere`/`WAIT:owes-review`/`WAIT:diff-unreadable`/`WAIT:in-flight`/`WAIT:no-check-surface`/`WAIT:mergeable-unknown`/`WAIT:authority-unreadable`/`LAND`; exit **2 = the pass could not be made** | the issue's vocabulary is coarser (`CONFLICT`/`STALE-ATTESTATION`/`NO-ATTESTATION`/`READY`/`INHERITED-RED`/`DRAFT`); **closing issues** are not attached to a row; `--json` exists but there is no MCP-typed shape with a `measured_at` | wrap `pr_state.py --json` (never `fleet-report.py::classify` — D1); map its 15 actions onto the issue's 6 classes **lossily in one direction only** (the 6 are a view; the 15 remain the answer); join closing issues per row | **WRAPPER** |
| 6 | `claim_check(issue, repo)` | **registry axis:** `tools/fleet/claim_lanes.py` (`read_registry`, `read_pull`, `read_snapshot`, `parse_key`, `parse_owner`, `parse_lease`, `to_evidence`) + `tools/fleet/liveness.py::claim_verdict` + `CLAIM_REASONS` (6 named abstentions) + `scripts/orchestrator-harness/claims.sh`. **local-checkout axis:** `tortoise/tools/who-is-on.sh` (tracked, 1954 B — `0` complete answer, `2` a surface could not be read) — a **3-line body** (35 lines with its header) that `exec`s `who_is_on.py` (953 lines), which imports `collision_preflight` (9132 lines) for its git enumeration | one answer across both axes; the registry axis answers "does a claim exist for this issue/head", the local axis answers "is work in flight on this disk". Today they are two tools in two repos and neither names the gap | wrap `claim_lanes.py` for the registry axis (`--json` + exit 3 = nothing established, never freedom) and **port the local axis** — which is **three files, not one**: `who-is-on.sh` + `who_is_on.py` + a declared decision on its `collision_preflight` import (port the gate, or keep the local axis `UNMEASURED(<why>)` rather than a second enumerator). Carry `ClaimRead.readable` and `siblings` into the payload so an absent key can never read as "free" | **WRAPPER** (two axes, both existing) |

### 5.3 Actuation (tools 7–9)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 7 | `lane_dispatch(box, repo, name, brief, env)` | `scripts/orchestrator-harness/nonblocking-dispatch.sh` (**typed exits: 2 = caller bug, 78 = validator stale/absent, 80 = brief-gate refused**); `lane.sh` (+ teardown trap); `lane-exec.sh` (launch so no wrapper survives — #2163); `spawn-gate.sh::run_agent` (load gate, watchdog, walltime row); `brief-gate.sh` (exit 80); `tools/fleet/dispatch_preflight.py` (refuse a dispatch with nothing to land); `tools/fleet/successor_preflight.py` (prove a predecessor is gone); `branch-claim.sh` / `branch-claim-hook.sh` (`refs/claims/branch-<slug>`, single-owner) | `env` into the agent's **process** environment (`cmux new-workspace --env KEY=VALUE` — an export inside a tool call does not reach the gates); `pid/log/worktree` in one typed reply; the two measured silent-actuator failures as **typed refusals** (`no-pid`, `branch-exists`) instead of stderr the caller must parse. ⛔ **The refusals are a MAPPING onto the EXISTING vocabulary, not a new one.** The order lives in `skills/cmux-cells` **§2** ("brief admission answers first, then the capacity refusals in this order (fork → disk → load)"), with **§5** owning the dispatch shape — not the reverse. The existing codes: **80** brief refusal (`AGENT_BRIEF_REFUSED`, before fork and before any disk/load read), **73** fork, **77** disk headroom, **75** load, **74** land backlog, **76**, **78** cannot-verify, and **72** `REPO_TARGET_REFUSED`. Phase 2 adds only the two that have no code today (`no-pid`, `branch-exists`) and must not collapse 73 ("does NOT clear by waiting") into 75 (load). And **`box-unreachable` is not synthesised from a timeout** (skill §3): the tool returns the channel read that answered, plus the ladder step it reached | subprocess the launcher, map exit 2/78/80 + the two extra codes to typed refusals; read `pid` from the `.pid` file, never from the launcher's own stdout (the `launcher did not report a pid: ''` failure); pre-check `refs/claims/branch-<slug>` and the local branch/remote ref for `branch-exists` | **WRAPPER + PARTIAL** (`env`, typed refusals are the added surface — §7.2) |
| 8 | `lane_message(lane, text)` | `tortoise/tools/cmux_dispatch.py` — **exit 0 = consumed, 1 = sent-but-not-consumed / never-became-ready, 2 = usage error, 3 = cmux transport error, 4 = queued (DELIVERED, not consumed)**; its own header states *"A transport failure (exit 3) is NOT a consumption failure (exit 1)"*; `scripts/objective-reminder.sh` (byte budget, `latest_submitted_at` turn-boundary confirmation, backend-aware cmux-vs-tmux) | MCP-typed delivery semantics over a *lane*, the `\n` discipline as a parameter, and — **materially** — the refusal of an unsteerable lane: a lane launched with `pi -p` does not read stdin, so a message to it types text nothing consumes (skill §5, measured `order-seen=0` on 9 lanes; F13). Today nothing stops a caller doing it | wrap `cmux_dispatch.py`, preserving **all five** exits as distinct typed results — collapsing 3 into 1 would report a refused socket as a message that failed to land | **WRAPPER** |
| 9 | `box_exec(box, cmd)` | `cmux vm exec --timeout` (the transport `lane-artifacts.sh` already pulls over); `cloud-cell-doctor.sh`; `scripts/orchestrator-harness/box-status.sh` | a typed `{rc, stdout, timed_out, truncated}` — today every caller re-invents truncation and timeout handling; ⛔ **and the distinction skill §3 makes**: `timed_out` is a CHANNEL fact, never a box verdict (a disk-full guest answers `running` while every `exec` times out). The tool must not turn a timeout into `box-unreachable` | thin wrapper over the transport; **truncate explicitly and say so** — the fleet's own doctrine is that a capped read which NAMES its cap is usable evidence while a silent one is a lower bound published as the fleet (`scripts/lane-actions.py::_SAMPLED_NOTE`); never infer a lane count from a process-name pattern | **WRAPPER** (external CLI verb — §7.4) |

### 5.4 Verification and closure (tools 10–12)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 10 | `review_record(pr)` | `scripts/record-review.sh --check-carry` (**positional** `<pr> [owner/repo]`; `--repo` exits 2); one tab-separated line `<verdict>\t<record digest\|->\t<live digest\|status>`; its full verdict set is **`head` (0) / `carry` (0) / `carry-patch` (6) / `fresh` (1) / `unreadable` (3) / `norecord` (4) / `nodigest` (5)**; `--print-diff-hash` (read-only seam `pr_state.py` already uses) | a typed `{current \| stale \| absent}` + **the head the record is bound to** in one reply; seven verdicts mapped onto three states without losing `carry-patch` (RE-RECORD, not a review cycle) or `unreadable` (RETRY, not re-review) | wrap `record-review.sh --check-carry` positionally **as step 1/4 of skill §6's five-step contract** (diff hash → ONE fresh review → verdict comment → record `--evidence` → rail), never as a substitute for the review; map `head`→current; `carry`/`carry-patch`→stale-with-head; `norecord`→absent; `fresh`/`unreadable`/`nodigest` keep their own names (they are three different next actions). **Pass the repo positionally** (the `--repo` refusal is documented) | **WRAPPER** |
| 11 | `verify_independent(repo, ref)` | `~/.local/share/pi-node/current/bin/instabox` (the CLI, v0.8.125) + `~/.pi/agent/instabox-setup.sh` (toolchain + health check) + `~/.pi/agent/state/INSTABOX-OPERATING-PROMPT.md` (**the documented procedure**: create/start/stop/exec/rm, the `--setup-file` trap, budget, kill-switch) + `~/.pi/agent/state/PAT-INSTABOX.md` (the falsifiable protocol: `SCOPE(...)`, negative write test, `INSTALLED(mode,path)`, `PROVEN(before,after)`). `scripts/scratch-worktree.sh` and the `verifier` agent are the same-box answers and are **not** substitutes | the **typed surface**: `{rc, stdout, timed_out, truncated}`, a stable tool name, and a teardown that is *guaranteed* rather than remembered — plus the standing rule the operating prompt already states (`never change runs-on:`) in a form the tool cannot violate | wrap the CLI and the operating prompt: create → clone at `ref` → run the lane's own steps → post evidence → **stop in a `finally`**; refuse any command the prompt forbids; `INSTALLED`/`PROVEN` lines read from `PAT-INSTABOX.md`'s protocol rather than invented | **PARTIAL** (§7.3) — corrected twice from `NEW`, see F8 |
| 12 | `closure_audit(pr)` | `gh`'s `closingIssuesReferences` — **already consumed by `scripts/review-pr.sh:501`** (`gh pr view … --json closingIssuesReferences`) and adapted by the `scripts/orchestrator-harness/gh-rest/gh` shim as the GraphQL-only field; `scripts/beta-progress.py::compute`'s `covered()` (open-or-merged PR naming the issue, boundary-exact); `scripts/orchestrator-harness/merged-not-closed.sh`; `tools/fleet/outcome_canary.py` | "what did this merge ACTUALLY close" as a typed fact, and **prose-keyword false closes** — the census counts a `#N` mention in a title/body/branch as merged (F4). No existing tool **compares** the closing references against the prose mentions against the issue's own live `state`. ⛔ **And ancestry is not available**: the rail defaults to **squash** (skill §6.5), so a batched PR's constituents stay **open** — a closure audit that asked "is this commit an ancestor of main" would report a false *not merged* for every batched PR | wrap `gh api` `closingIssuesReferences` + re-read each issue's `state`; name `review-pr.sh:501` as the existing consumer of the field rather than claiming it is unused; emit the closed/mentioned/still-open triple | **PARTIAL→WRAPPER** of `gh` (§7.5) |

### 5.5 Durability (tools 13–14)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 13 | `reminder_set` / `reminder_list` / `reminder_cancel` | **the verbs do not exist.** The *hard* half does: `scripts/objective-reminder.sh` (byte budget with a LOUD refusal over budget at `:168`; delivery confirmed by `latest_submitted_at` advancing, explicitly *not* by the send's exit status, `:25-27`; backend-aware cmux-vs-tmux; plus its `.test.sh`) and `scripts/fleet-schedule.py` (`--check`/`--status`/`--verify`/`--install`/`--start`/`--stop`, plist-parsed, portable to cells without launchd) | a **settable, listable, cancellable** reminder that survives a session restart, with the owner-confirmed server-owned queue + timer | wrap `objective-reminder.sh` for the delivery contract and `fleet-schedule.py` for the timer; the queue is a **file** under `$HOME/.pi/agent/state/` (as `beta-progress.json`, `NEEDS-ACTION.md` already are) because a server-owned queue that lives only in server memory dies with the server — and "survives session restart" is the requirement | **PARTIAL** (§7.6) |
| 14 | `beat_checkpoint(state)` | `scripts/orchestrator-harness/cycle-record.sh`; `scripts/goal-state.py` (queries the graph, writes nothing); `scripts/orchestrator-heartbeat.sh` + `BEAT-CHECKLIST.md` (the six checks and their order); `~/.pi/agent/state/ORCHESTRATION-BOARD-<date>.md` (the board AGENTS.md mandates) | the durable write path as one typed call; `orch-checkpoint.sh` (the 20-min nudge) is **untracked** (F3); `goal-state.py` is graph-read-only by design and must stay so | wrap the board/heartbeat artifacts; **land `orch-checkpoint.sh` into `scripts/`**; the graph axis stays the Tortoise MCP (D5). ⛔ **`GOAL.last` is removed from the wrap set** (the issue's table names it): it does not exist on this box, and `scripts/goal-state.py` records why — the goal map was moved INTO the graph, so a file is the one thing that must not come back | **WRAPPER + PARTIAL** |

### 5.6 Counts

| class | tools |
|---|---|
| **WRAPPER** (existing implementation answers it) | 3, 4, 5, 6, 8, 9, 10, 14 (8 tools) |
| **PARTIAL** (existing implementation answers part) | 1, 2, 7, 11, 12, 13 (6 tools) |
| **NEW** (nothing answers it) | **none** |

**How a compound label resolves, stated because three rows carry one.** A row gets **one** bucket, by
this rule: *the class of the nearest existing implementation it wraps.* Row 1 counts PARTIAL because §4.2 asks it to **write** tree steps 2/3/5/6 and a `finished` state, not to relocate them; row 7 (`WRAPPER + PARTIAL`)
counts PARTIAL for the same reason — the `env` argument and the typed refusals have no implementation at all; row 14
(`WRAPPER + PARTIAL`) counts WRAPPER because every element of its answer exists and only the
`orch-checkpoint.sh` landing is missing — a *deployment* gap, not a missing capability; row 12
(`PARTIAL→WRAPPER`) counts PARTIAL because the field is consumed but the comparison is not written.
Applying the rule the other way is what makes the partition meaningful: a `PARTIAL` here means "someone
must write something", never "something must be relocated".

**`NEW` rows: 0 — and this time literally.** Every one of the 14 tools wraps something that exists.
The last row to fall was #11, and it fell twice: the first draft said the InstaBox procedure did not
exist, the second said it still did not after a search that omitted `$HOME/.pi/agent/state/` (F8).
Both were the same error, and both are left in the document rather than tidied away, because a
Phase-1 inventory that quietly reports "nothing exists" is the failure this phase is designed to
catch — **three times in one document is a method problem, not three unlucky searches.**

### 5.7 Semantics authority — the governing skill section per tool

`skills/cmux-cells/SKILL.md` (756 lines, merged; read in full for this inventory) already owns the
semantics of every operation below. **Where a tool re-states a rule the skill owns, the SKILL is the
authority and the tool is the typed access path to it.** An MCP server that restates a rule becomes a
second, silently divergent definition — the failure mode this issue exists to prevent, wearing a
different hat.

| # | tool | governing skill section | what the MCP deliberately does **NOT** decide |
|---|---|---|---|
| 1, 2, 3 | `lane_status`, `lane_tree`, `lane_artifact` | **§4** "Liveness of a LANE, and the reaping rule" | the verdict, and the reaping rule — the tool reports the three gates **or declares them `UNMEASURED`** (§4.2 b). The "ONE classifier" rule is **issue #3382 §1.2's**, not the skill's (the skill states the liveness/reap *rule* and names no classifier); the **state vocabulary** is `docs/ops/fleet-liveness.md` §1's. §4.1 shows two ladders exist upstream — that is what §4.2's plan fixes rather than repeats. Also not decided: the three reaping gates — the tool reports them, `lane-reap.sh` owns them |
| 4 | `fleet_census` | **§2** "Capacity is RAM and DISK — load is a distant third" + **§7** "TWO DIFFERENT CEILINGS" | the capacity rule, **and critically the platform calibration**. See [§10.1](#101-the-two-capacity-calibrations--the-trap-that-would-call-a-dying-mac-healthy) — a census that applies the cell tolerance to the laptop reports a dying box as healthy |
| 5 | `pr_queue` | **§6** (the landing contract) + **§6.5** (`--check-carry` verdicts) | which verdict a PR is in. The seven `--check-carry` verdicts and their next actions are skill §6.5's. ⛔ **`pr_state.py` does NOT consume them** — it carries its own four-state predicate, `fidelity()` (`at-head`/`carried`/`owes-review`/`diff-unreadable`) over `--print-diff-hash`, and it **disagrees with `--check-carry` on exactly the two cases skill §6.5 calls the expensive mistakes**: a record with no usable digest is `owes-review` to `pr_state.py` but `nodigest` (a CARRY) to `--check-carry`; a byte-identical patch on a moved diff is `owes-review` to `pr_state.py` but `carry-patch` (re-record, no review cycle) to `--check-carry`. See **D9** — the server must not answer one PR with two different verdicts |
| 6 | `claim_check` | **§4** ("an absent artefact fails closed"); the pre-flight **order** is code, not skill: `brief-gate.sh` (80) → `repo-target.sh` (72) → `collision_preflight.py` / `claim_lanes.py` | whether an absence is freedom. It is not: every claim verdict is an abstention |
| 7 | `lane_dispatch` | **§2** (the refusal order: brief → fork → disk → load) + **§5** (the dispatch shape) | the refusal vocabulary and the pre-flight order. The tool's typed refusals are a **mapping onto** what already exists — `brief-gate.sh` exit 80, the repo-target assertion, `spawn-gate.sh`'s load/disk gates, `branch-claim.sh` — never a replacement. It must not re-implement a gate to produce a nicer error |
| 8 | `lane_message` | **§5** "⛔ A LANE LAUNCHED WITH `pi -p` CANNOT BE STEERED" | **whether the lane can be steered at all.** This one changes the tool: see F13 — a `-p` lane does not read stdin, so messaging it types text nothing consumes (measured: 9 lanes ordered to stop, `order-seen=0` on every one). The tool must **refuse** a print-mode lane, not deliver into the void |
| 9 | `box_exec` | **§3** "'Unreachable' is a claim about the CHANNEL, not the box" | what "unreachable" means. `timed_out` / `truncated` are **channel** facts; they are never evidence about the box, and the tool must not synthesise a box verdict from one (§3's measured case: a disk-full guest answers `running` while every `exec` times out) |
| 10 | `review_record` | **§6** "Landing work from a lane — the five-step contract" | the landing order: diff hash → ONE fresh review → verdict comment → record with `--evidence` → rail. The tool **exposes** that order and reports where a PR sits in it; it does not invent a shorter path, and it may not present `--check-carry` as a substitute for step 2 |
| 11 | `verify_independent` | **§3** (channel vs box) + **§1** ("verify activation by **artifact**, never by a banner") + **§8** (the work-at-risk block before anything destructive) | what counts as evidence, and what must be preserved before a machine is destroyed. The tool does not define "proven"; `PAT-INSTABOX.md`'s `SCOPE`/`INSTALLED`/`PROVEN` shape does |
| 12 | `closure_audit` | **§6.5** "⛔ The constituents will NOT close as merged" | whether ancestry can be assumed. The rail defaults to **squash**, so a batched PR's constituents stay **open** and a closure audit that assumes ancestry reports a false "not merged" for every batched PR. See the row's own note |
| 13 | `reminder_*` | **§8** ("a stale heartbeat file does not mean the loop is dead"); the delivery contract is `objective-reminder.sh`'s own header (§5 row 13) | whether silence is a state. A reminder that did not send and a reminder that had nothing to say are indistinguishable in a log — the tool reports the delivery verdict, not the absence |
| 14 | `beat_checkpoint` | **§8** ("a readiness banner is a claim; `git rev-parse`, `ls` of the artifact … are facts") | whether a banner or a heartbeat is a state. It records artifacts and their sha256, never a claim |
| **all** | — | **§8** "Traps that produced wrong conclusions today" — which covers **three** of the six measured failures: FALSE UNMEASURED (`d=$(... \| wc -l)` cannot fail; UNKNOWN is an error, not a zero), FALSE DEATH ≈ (a stale heartbeat is not a dead loop), SILENT ACTUATOR (a silent exit 0 is unreachable, never "no fleet"). | the rest are NOT in §8, so a fixture author must not be sent there for them: **LANE COUNTER ZERO**'s mechanism is §**4** (`pi` rewrites its process title, so `args` is `pi` alone); **FALSE MERGED** and **STALE CLOCK** have no trap in the skill at all — they are this issue's own measured failures (F4, and §9 rows 1 and 3) |

**A row that cannot name a governing section either duplicates something or is a new capability — and
both need the justification §7 already demands.** All 14 name one; none is a new capability.

**Divergence risk, recorded because it has already been hit (lane measurements, not claims from the
skill):** three lanes died silently on the cells while `pgrep` reported them alive (agent-infra#3331 is
the fix), and `cmux workspace close` needs `--force` for a running process. Any tool that shells out to
`cmux` inherits those failure modes, and they therefore appear in the affected rows — #7 (dispatch: a
launcher that exits 0 while the lane is already gone), #8 (message: delivery is bytes, not a turn), #9
(exec: a channel timeout is not a box verdict) — plus §10's trap table.

---

## 6. Deletions — what this inventory removed from the list

The issue's rule: *"A tool that duplicates an existing script without saying why must be deleted from
the list in that document."* These are removals of **wrap targets and named dependencies**, not of
tools the issue requires. Each one is a sentence the code made unavoidable.

| ID | Deleted | Why |
|---|---|---|
| **D1** | `fleet-report.py::classify` as the implementation of `pr_queue` (#5) | `tools/fleet/pr_state.py` implements the same one-cause-per-row table, tracked and reviewed, plus head-bound attestation fidelity that `classify` lacks. Wrapping both is a second PR classifier — the duplication this issue exists to prevent (F6). `classify` stays in `fleet-report.py` until that file is either landed and reduced or retired; it is **not** an MCP wrap target. |
| **D2** | Wrapping `claim_lanes.py` **alone** for `claim_check` (#6) | **Corrected.** The first draft deleted `who-is-on.sh` on the claim that it does not exist; it does (F7), and deleting a wrap target the issue names *on a false premise* is the worst version of this deletion rule. What survives is narrower and evidence-backed: `claim_lanes.py` answers the **registry** axis and cannot answer the **local-checkout** axis, and the local axis is not one file — `who-is-on.sh` is a 3-line body (35 lines incl. header) that `exec`s `who_is_on.py` (953 lines), which imports `collision_preflight` (9132 lines) for its enumeration. Phase 2 therefore **ports the local axis or declares it `UNMEASURED`** — it does not drop it, and it does not pretend a one-file copy is the port. |
| **D3** | A required dependency on `fleet-report.py` for `fleet_census` (#4) | Untracked (F3): it cannot be deployed by bootstrap, so making the MCP server depend on it makes the server unreproducible on a fresh box — a direct violation of Indicator (b). Either its bytes land in `scripts/` (preferred: it carries a fix that exists nowhere else) or `fleet_census` uses `beta-progress.py` + `capacity.sh` + `box-status.sh` only. **Not** a duplicate-wrap: the wiring is one or the other, never both. |
| **D4** | `fleet-report.py`'s §3 "merged last hour" as a closure source for `closure_audit` (#12) | It is a keyword mention (F4), i.e. it is the *defect*, not the implementation. `closure_audit` exists to replace it. |
| **D5** | Any Tortoise-graph verb | Out of scope by the issue: the graph is reached through the Tortoise MCP and the `how-to-use-tortoise` skill. `scripts/tortoise-graph.sh` + `scripts/tortoise_graph_client.py` exist and are the **CLI** path; the MCP server must not add a third. Only the `GRAPH-UNREACHABLE(<cmd> + <error>)` convention is recorded. |
| **D6** | A second PR-state classifier, second lane classifier, second liveness verdict, second hasher | The structural deletion. `pr_state.py` (PR), **`liveness.py`** (lane — per §4.2 and issue §1.2, with the other modules as evidence suppliers), and `harness-provenance.sh` (versions) each own their question. Every would-be "NEW" tool in §5 was one of these — and **none of the 14 turned out to be NEW at all**. |
| **D7** | `tools/fleet/fleet-health.py::cputime_secs` and `scripts/turn-classify.py` **as second homes** for tree steps 2 and 5 | Both exist and both work; neither becomes the wrapper's implementation (F11). The CPU reader must be `lane-status.py::lane_cpu_busy` (the only one with the exactly-one-lane-to-one-process attribution guard); the content reader must be `lane-actions.py`'s single batched JEV call (N round trips for one beat is not an option at ~29 lanes). They are not deleted from the repo — `fleet-health.py` and `turn-classify.py` have their own callers — but they are **deleted from consideration**, so Phase 2 cannot silently pick a second one and produce a verdict that disagrees with the beat's. |
| **D8** | **The second verdict ladder** in `scripts/lane-status.py` (`WORKING` / `WIP-IDLE` / `DONE-IDLE` / `WEDGED` / `CHILD-STUCK` / `UNATTRIBUTED-WORKING` …, 12+ verdicts and its own `VERDICT_RANK`) | Once §4.2's plan lands, `liveness.py` is the classification logic the issue names and the skill §4 rule implies; two ladders answering "is this lane stuck" is the defect #1178 closed, and today both run. `lane-status.py` survives as the **sampler** (`lane_cpu_busy`'s attribution guard, the transcript tail) and its ladder is retired or reduced to narration. Phase 2 is where that happens, because Phase 2 is what makes the single classifier complete |
| **D9** | **A second carry predicate** — `pr_state.py::fidelity` alongside `record-review.sh --check-carry` | Both answer "may this record carry?". `pr_state.py`'s is its own four-state predicate over `--print-diff-hash` (it never calls `--check-carry`); the skill's §6.5 table is the authority and it distinguishes seven verdicts where `pr_state.py` has four. The disagreements are measured, not hypothetical: **`nodigest`** and **`carry-patch`** both read `owes-review` to `pr_state.py` and something else to the tool, and both are cases where the wrong answer **costs a full review cycle**. Phase 2 names ONE of them for the MCP surface (#10 = `--check-carry`, per the issue's own row) and #5 maps its own row to that verdict rather than restating a fourth state machine |

---

## 7. Non-wrapper justifications (what each `PARTIAL` adds, and why it is not already covered)

The six `PARTIAL` rows are **1, 2, 7, 11, 12, 13**. Five are justified below (§7.1 #2, §7.2 #7, §7.3 #11,
§7.5 #12, §7.6 #13); **#1's justification is §4.2**, where the missing half of the decision tree is specified — it
is a write, not a convenience, and the largest one in the batch. §7.4 is the exception the section title promises:
**#9 is a WRAPPER**, and its entry exists only because wrapping an external CLI verb rather than a repo script
needed saying. This section names the thing, and for each one says why no existing tool already supplies it —
the test the issue's deletion rule applies in the other direction.

### 7.1 `lane_tree` (#2) — PARTIAL

`lane-status.py::child_suppresses` and `lane_liveness.py::child_sids` both **know** a parent lane can
delegate into a `task` child; neither *verdicts the child*. The tree's Step 6 is explicit: *"Do NOT
special-case it. Apply THIS SAME TREE to the CHILD — it is a lane too."* The measured cost of not
doing that is on file: **four** lanes tabulated as false `IDLE`/`WEDGED`/`STALL` verdicts in one
evening (one of the four marked "presumed"), plus a fifth entry under a fourth label (`WIP`), every
one a lane holding or presumed to hold a `task` child
(`state/FINDING-lane-classifier-ignores-task-children-2026-10-11.md`), and
the corollary that the classifier *selected against* exactly the lanes doing the most valuable work.

No existing tool can serve because the recursion is the missing thing — and it must recurse by
**calling the same verdict function**, not by adding a rule. That is why this is `PARTIAL` and why
Phase 2 implements it as `map(lane_status, tree_nodes)` rather than as new logic.

### 7.2 `lane_dispatch` (#7) — the added surface, named

Two surfaces are genuinely absent from every existing launcher:

1. **`env` into the agent's process environment.** `cmux new-workspace --env KEY=VALUE` is the only
   path that reaches the agent's own gates; an `export` inside a tool call does not (the gates read
   the *agent process*, not the shell). No launcher in `scripts/orchestrator-harness/` takes an env
   argument; `lane-env.sh` writes files for the lane, which is not the same thing.
2. **Typed refusals.** `nonblocking-dispatch.sh` already has excellent exit codes (2/78/80), which is
   most of the win. The two measured silent-actuator failures are *not* codes: `launcher did not
   report a pid: ''` and `fatal: a branch named 'p0-10000' already exists` both reached the caller as
   stderr prose. `branch-claim.sh` and `spawn-gate.sh` know how to **detect** both; nothing maps them
   to a machine-readable refusal. The tool adds the mapping, not the detection.

### 7.3 `verify_independent` (#11) — `PARTIAL`: the procedure exists, the typed surface does not

**This row is the document's own worst moment and is kept as one.** Two drafts called it `NEW` on the
claim that no InstaBox procedure existed. Both searches omitted `$HOME/.pi/agent/` and
`$HOME/.pi/agent/state/`, where the procedure, the setup script and the verification protocol live, and
where the **live poke** already instructs the orchestrator to use the machine as an independent
verifier (F8). The claim was false; the file table in F8 is what replaced it.

So #11 is `PARTIAL`, and the split is precise:

| exists | does not exist |
|---|---|
| the CLI (`instabox`, v0.8.125), the setup (`instabox-setup.sh`), the **operating procedure** (`INSTABOX-OPERATING-PROMPT.md`), and a falsifiable evidence protocol (`PAT-INSTABOX.md`: `SCOPE(...)`, negative write test, `INSTALLED(mode,path)`, `PROVEN(before,after)`) | a **typed** surface — `{rc, stdout, timed_out, truncated}`, a stable tool name, and a teardown that is *guaranteed* rather than remembered |

Phase 2 therefore ships a **wrapper**, not a procedure:

- call the CLI; read `INSTALLED`/`PROVEN` from the protocol rather than inventing a second evidence
  format; carry every step's `{rc, stdout, timed_out, truncated}`;
- **teardown in a `finally`** — the one part of the existing procedure that is a human habit and must
  become a code path, because a created machine that is not stopped is a spend that outlives the lane;
- and honour the operating prompt's standing rule (*"InstaBox is NOT a CI runner for us — never change
  `runs-on:`"*) in a way the tool cannot violate, rather than in a paragraph the next reader may skip.

**Not a security finding:** `~/.pi/agent/instabox.json` is a live key carrying `machines:delete`, and
it is **already 0600 inside a 0700 directory**. A middle draft of this section claimed a
world-readable key and would have filed a no-op issue on a false premise; that claim is withdrawn. The
residual is scope, not permissions: the tool must never pass `machines:delete` through, and the key's
blast radius is bounded by what the wrapper will call.

If the reviewer judges that a cloud-machine wrapper is too much for a "wrap the existing thing" phase,
the defensible reduction is: **#11 out of Phase 2, into its own issue, with the 13 remaining tools
landing together** — the batching rule is about CI cost, and a 13-tool PR pays the same CI run.

### 7.4 `box_exec` (#9) — a WRAPPER, included only because the wrapped thing is an external CLI verb

`cmux vm exec` is the transport (`lane-artifacts.sh` already pulls cell artifacts over it). What no
script provides is the **typed shape**: `{rc, stdout, timed_out, truncated}`, with truncation
declared rather than silently clipped. Every current caller re-invents it, and the failure mode is
recorded: a lower-bound read published as a census is the fail-open `docs/ops/fleet-liveness.md`
**§11.3** closes ("a lower-bound terminal count … is never printed as a census"; a census with no
eyes says `?`, not `0/0`), and the cap-naming half is `scripts/lane-actions.py::_SAMPLED_NOTE`.
Wrapping an external verb is still a wrapper by
the issue's own standard (`#9 | box_exec(box, cmd) | cmux vm exec`).

### 7.5 `closure_audit` (#12) — the `gh` API is the implementation

No existing tool answers "what did this merge close" **as a typed fact**. The field itself is already
consumed once — `scripts/review-pr.sh:501` reads `gh pr view … --json closingIssuesReferences` when it
posts a review — so the claim is not that nothing uses it, it is that nothing **compares** it:
`beta-progress.py::covered()` answers a different question (does *any* PR name this issue),
`merged-not-closed.sh` detects a symptom, and `fleet-report.py`'s §3 is the defect (F4). `gh`'s
`closingIssuesReferences` plus a re-read of each issue's own `state` is the implementation; the
prose-keyword scan is a **comparison** the tool performs, never the answer it reports.

### 7.6 `reminder_set/list/cancel` (#13) — the verbs are new, the hard part is not

The owner-confirmed decision is **a server-owned queue plus a launchd/systemd timer**; that is a
recorded decision and is not reopened here. Two implementation constraints follow from existing,
measured code, and the inventory records them so Phase 2 does not re-derive them:

1. **The queue must be a file** under `$HOME/.pi/agent/state/` (like `beta-progress.json` and
   `NEEDS-ACTION.md`). A queue held only in server memory dies with the server, and the requirement
   is that it survives a session restart.
2. **Delivery confirmation is the turn boundary, not the send's exit status** —
   `objective-reminder.sh`'s measured rule (`latest_submitted_at` advances when the text becomes a
   turn; `latest_submitted_message` lags and produced a false `UNSENT`). And the payload has a byte
   budget with a **loud refusal** over budget, because the measured failure was three consecutive
   ticks that silently delivered nothing while the log looked like a channel with nothing to say.
3. The timer is `fleet-schedule.py`, not a hand-installed plist — it is the one runtime that works on
   the cells (no launchd, no `crontab`, no user bus; measured on Ubuntu 24.04 with
   `HOME=/tmp/cell-home`).

No existing tool does set/list/cancel; that is why it is `PARTIAL` rather than a wrapper.

---

## 8. External prior art

Cited with URLs; each row says what it implies **for this server**, not just what it says.

| Source | What it establishes | Implication here |
|---|---|---|
| [Anthropic — Writing effective tools for agents](https://www.anthropic.com/research/writing-tools-for-agents) | Give each tool a clear, distinct purpose; **avoid overlapping tools**; namespace related functionality; page/filter/truncate responses. Too many tools distracts the agent and impairs strategy selection. | 14 is already at the edge. This is the argument for the deletion rule and for **namespacing** (`lane.*`, `fleet.*`, `pr.*`). It is also why `pr_queue`'s 15 `pr_state` actions must **not** become 15 tools. |
| [MCP Tools Are Not Endpoints](https://agenticthinking.ai/blog/mcp-tools-are-not-endpoints/) | A tool should be a **user-level job**, not an API endpoint; tool bloat comes from 1:1 endpoint wrapping. | `pr_queue`, `fleet_census` and `lane_status` are jobs ("what needs doing next"), not endpoints. `box_exec` is the one deliberate endpoint-shaped escape hatch and it is named as such. |
| [Your API Is Not Your MCP Tool](https://ro14nd.de/mcp-tool-design-patterns/) | Raw APIs produce context bloat and selection confusion; prefer higher-level workflow tools and concise responses. | The typed payloads in §5 are deliberately small (`state` + `reason` + `measured_at`), with detail behind a `detail` field. |
| [AWS — MCP tool design: practical approaches and tradeoffs](https://aws.amazon.com/blogs/machine-learning/mcp-tool-design-practical-approaches-and-tradeoffs/) | Granularity, naming, semantic overlap and context consumption are the real tradeoffs; progressive disclosure for large collections. | Supports one tool with a `box\|lane\|all` **argument** over three tools; supports `reminder_*` as three verbs of one family. |
| [kubernetes-mcp-server configuration](https://github.com/containers/kubernetes-mcp-server/blob/fcd9bbe672c98bb81c2ce93da8c0add548023672/docs/configuration.md) · [Qovery: the k8s MCP server I'd trust](https://www.qovery.com/blog/kubernetes-mcp-server-agent-namespace-guardrails) · [go-kubernetes-mcp-server](https://github.com/langazov/go-kubernetes-mcp-server) | The closest comparable (an agent controlling a **fleet of machines** through MCP). Separate read-only from destructive modes (`--read-only`, `--disable-destructive`); prefer intent-level tools over raw `kubectl`; **blast radius is decided by the credentials granted**, so scope them and use short-lived identities. | This is the one comparable whose regret applies directly. Two consequences for Phase 2: (i) mark every tool read-only vs mutating in its schema, and default the server to **read-only** unless a mutation flag is set; (ii) `verify_independent`'s `machines:delete` credential is the blast radius — scoped down in the tool, and the credential itself is a follow-up (§7.3). |
| [Forget MCPs, use CLI tools instead](https://kfchou.github.io/forget-mcps/) | The counter-position: when a CLI already exists, an MCP schema can be pure token overhead; MCP earns its place for stateful workflows and non-CLI surfaces. | Taken seriously, and it is why **every** tool here is a wrapper: the CLI stays the implementation and the MCP server is the stable, typed name. It is also the argument for the pi-extension question (§8.1) — the answer cannot be "MCP because MCP". |

### 8.1 MCP server vs pi extension — the decision, reasoned

**Decision: an MCP server, and it is not close — but for two reasons that are specific to this fleet,
not to fashion.**

1. **The requirement is "reaches the same answer on a fresh box with zero local scripts", and the
   fleet is multi-harness by construction.** `extensions/` holds **47** in-process pi extensions. They
   are excellent at what they do (gating, heartbeat, review enforcement) and they are **pi-only**: a
   harness that is not pi cannot call one. The orchestrator runs in pi today *and* the fleet already
   reaches a second MCP surface (Tortoise) from the same session. A typed tool surface that only pi
   can call re-creates the lock-in this issue is trying to end.
2. **A separate process is what makes invariant 5 possible.** "The server refuses to start if a
   wrapped module's sha256 is missing" presupposes a **start-up**. An extension is loaded *into* a
   session that is already running — it has no start gate to refuse at, and its version is whatever
   the session's `--extension` set resolved to. `harness-provenance.sh`'s own incident (a redeploy
   reverting a hand-applied fix twice, while every instrument said the box was fine) is a *deploy*
   failure and needs a *deploy*-time gate.

**Where an extension is the right answer, stated so this is not a blanket ruling:** anything that must
be true *inside* a turn and cannot tolerate a process boundary — the sequence-enforcer, the
skill-enforcer, the review gate, the search guard, `task-heartbeat` — stays an extension. The
dividing line is **"does this need to refuse a session that is already running?"** If yes, extension.
If it needs to *answer a question on demand, identically everywhere*, MCP server.

**Cost of the decision, stated:** an MCP server has a per-call process/serialisation cost that an
in-process extension does not, and a schema that occupies context. Both are accepted, and mitigated by
the prior-art rules above (small payloads, one tool per job, namespace, read-only by default).

---

## 9. The six measured failures — fixture status

Red-first means: the fixture must **fail** against today's behaviour and pass after the fix. A test
that passes against the broken version proves nothing, and a test written against already-repaired
code is a regression pin — valuable, but it must be **labelled** as one, or it silently weakens the
gate.

| # | Measured failure | Status on this box (2026-11-03) | Where the live defect is | Red-first target for Phase 2 |
|---|---|---|---|---|
| 1 | **FALSE MERGED** — 7 PRs printed as merged, all `open` | **LIVE, in an untracked file** | `fleet-report.py::section_p0p1` — `merged_refs` from a `#(\d{4,5})` **regex over title/body/branch** (F4). `section_pipeline`'s merged list is correct (verified live: `--state merged --search 'merged:>=<iso>'` returns `state: MERGED`) | write the fixture against `closure_audit`'s replacement: a merged PR **mentioning** `#N` must not report `#N` closed. Two fixtures: mention-only ⇒ not closed; `closes #N` ⇒ closed |
| 2 | **FALSE UNMEASURED** — `UNMEASURED(gh issue list failed …)` while the same query returned rc=0 | **LIVE** (mechanism), untracked file | `gh_json` returns `None` for **two** causes — `rc != 0` and an unparseable payload — and the caller's message names only `rc != 0` (F5). A third outcome is a crash, not a `None`: `sh()` passes `timeout=120` with no `try/except`, so a timeout raises out of the section | fixture: a payload that is not JSON ⇒ the string inside `UNMEASURED(...)` must name **parse**, not `gh failed`; and a timeout ⇒ `UNMEASURED(timeout)`, not a traceback. Assert on the **reason**, not on the token |
| 3 | **STALE CLOCK** — `as of 14:16, 0m ago` for a five-hour-old stamp | **REPAIRED in tracked code** (`scripts/beta-progress.py` clamps the age, rejects a future `ts` beyond `CACHE_TS_SKEW_S`, and re-validates every field the render dereferences) | — | **mutation-testable from history**: `git show b54b117fc:scripts/beta-progress.py` renders `ts` / `age_m = int((time.time() - ts) / 60)` with neither the bound nor the validation, so the harness can check that blob out and require a red. Keep the HEAD regression pin as well |
| 4 | **LANE COUNTER ZERO** — `pi-cell-1: lanes=0 pi=9` | **LIVE in the fleet, fixed only in an untracked file** | `fleet-report.py::section_capacity` now greps `[l]ane.sh` + `^pi$` **in the deployed copy only** (F3). A redeploy deletes the fix | fixture: a `ps` fixture where lanes run argv `pi` (the cell shape) must count them; a wrapper-bash line must not be counted as `pi`. Red-first requires the fix to **land in `scripts/`** first |
| 5 | **FALSE DEATH ×3** — three **finished** lanes reported dead and re-dispatched | **Largely CLOSED in `liveness.py`** (a resident finished lane is a fenced holder ⇒ `running-quiet`; `dead` needs a non-empty candidate set, every candidate positively absent, and non-growth positively known). Still reachable at the **composition** layer: `liveness.py` has no `finished` state, so a caller that maps `running-quiet` ⇒ "dead" re-creates it | composition, not `evaluate` | fixture at the `lane_status` boundary: a lane whose turn ended, whose process is resident, and whose log is stale ≥ 2 h must read `finished` — **never** `dead`. Three fixtures, one per measured lane shape (27 turns/2 PRs; 7 files verified + 3 reviewer dispatches; 383 B artifact + merged PR) |
| 6 | **SILENT ACTUATOR** — `launcher did not report a pid: ''`; `fatal: a branch named 'p0-10000' already exists` | **PARTIALLY closed** — `nonblocking-dispatch.sh` now has typed exits 2/78/80; the two measured failures were **stderr prose**, and `queue-dispatch.py` (which produced the pid message) is no longer deployed (only `.bak` files remain) | the launcher→typed-refusal mapping (§7.2) | fixture: a launcher that exits 0 and writes no `.pid` ⇒ `no-pid`; a branch that already exists ⇒ `branch-exists`. Both must be **returned**, not raised as text |

**Honest summary — corrected, because the first draft's accounting contradicted its own table:**

| # | status | what Phase 2 does |
|---|---|---|
| 1 FALSE MERGED | live, in an **untracked** file | land the bytes **or** replace the source; fixture targets `closure_audit` |
| 2 FALSE UNMEASURED | live as a **mechanism**, in the same untracked file | same; fixture asserts the reason string |
| 3 STALE CLOCK | **already repaired** in tracked `beta-progress.py` | **mutation test from the pre-fix blob** (`git show b54b117fc:scripts/beta-progress.py`) **plus** the HEAD regression pin — that blob is the easiest red in the set, not a fixture to skip |
| 4 LANE COUNTER ZERO | live on the box, fix exists only in the untracked copy | land the bytes first, then fixture |
| 5 FALSE DEATH ×3 | **largely closed** in `liveness.py`; reachable only through a composition that does not exist yet | **pin at the `evaluate` level**, red-first at the `lane_status` boundary once the composition exists |
| 6 SILENT ACTUATOR | **half-closed** (typed exits landed; the two measured failures were prose) | red-first on the mapping half only |

So, with each failure in exactly **one** bucket:

| bucket | failures | why |
|---|---|---|
| red-first once the mapping exists | #6 | for #6, the two measured failures were **stderr prose** (`queue-dispatch.py`, no longer deployed; git's own `fatal:`) and `nonblocking-dispatch.sh` has only 2/78/80, **none of which is `no-pid` or `branch-exists`** — so those two have no code to fail against yet |
| red-first **against its replacement** (the mechanism lives only in the untracked `fleet-report.py`, so no repo test can exercise it today) | #1, #2 | a fixture written now has nothing to run against |
| red-first once the composition exists | #5 | `evaluate` is already correct; the boundary is what is missing |
| **mutation-testable from history** (the pre-fix line IS in git) | #3 | `git show b54b117fc:scripts/beta-progress.py` renders `ts`/`age_m` with no clamp and no future-stamp validation; HEAD carries both — so §12's method (a) can check that blob out |
| blocked on landing untracked bytes | #4 | its only copy is untracked, **and** the fix exists only in that copy |

So: **0 red-first against today's shipped code**, **2 red-first against a replacement** (#1, #2),
**1 mutation-testable from history** (#3, the pre-fix blob), **2 red-first once the composition/mapping
exists** (#5, #6), **1 blocked on landing untracked bytes** (#4) — and **0 that are merely pinned**. Phase 2's test plan states this per fixture rather than claiming six red-first tests.
(Corrected twice, and the second correction matters: an earlier tally said "1 pure pin (#3)", which was
wrong — the pre-fix line for #3 is retrievable, so #3 is the *easiest* mutation test here, not the
hardest.)

---

## 10. Portability traps (the list the issue asks for)

Measured/read, not assumed. Each row is a thing that breaks a wrapper on a box where the tool is
supposed to work.

| Trap | Where | What breaks | Guard |
|---|---|---|---|
| **no `timeout(1)`** on macOS | any `timeout 25 cmux vm exec` | exit 127 / a hang | implement the bound in-process (Python `subprocess(timeout=)` / bash `&`+`wait` loop), never `timeout` |
| **no `/proc`** on macOS | `/proc/loadavg`, `pipe:[N]` identities | load reads and pipe identity both absent | `os.getloadavg()` / `lsof`; the pipe-identity abstention is already specified in `fleet-liveness.md` §11.2 — reuse it, do not re-derive |
| **no `bc`** | arithmetic in bash wrappers | silent empty result | integer arithmetic, or Python |
| **`CELL_HOME`** set on cells | `$HOME/.pi/agent/...` paths | a lane's state is under `$CELL_HOME`, not `$HOME` | resolve `CELL_HOME` first, then `HOME`; state the resolution in the payload |
| **cmux binary path** | `/Applications/cmux.app/...` hardcoded in `fleet-report.py` | absent on a Linux cell | resolve the binary, and `UNMEASURED(...)` when it is absent — never 0 |
| **`cmux vm exec` addresses a box by VM NAME**, not by label | `fleet-report.py::section_capacity`'s own comment | an opaque `Reference: <hash>` error | resolve label→name first and report the resolution |
| **a cell lane's argv is literally `pi`** | `BEAT-CHECKLIST.md`; `fleet-report.py` | `grep 'pi -p'` returns 0 while lanes run; `pgrep -x pi` is the reliable probe | count lanes from `lane.sh` + `pi`, never from a `--print` pattern |
| **`grep -r` from a repo root is refused** | agent shell guards | a tool that shells out to `grep -r` fails for the caller | `git grep` / `rg`; the server should not depend on a shell guard's allowance |
| **`cmux send` must end with `\n`** | `lane_message` (#8) | text sits unsent in the editor and concatenates with the next message | always send the terminating newline as its own step; `--paste` for multi-line |
| **`ps -o pcpu` is a lifetime average** | Tree step 2 | a long-lived working session reads ~flat (measured: 3 of 73 processes moved) | cumulative `ps -o time`, two samples, **stated tolerance** |
| **`ps` unreadable ≠ `ps` empty** | `scripts/lib/pid-identity.sh` exit 1 vs 2 | a failed read becomes `dead` | already encoded: exit 1 = positively absent, exit 2 = unknown. Preserve it |
| **an `exec` timeout is a CHANNEL reading, not a box reading** | `skills/cmux-cells` §3 | a disk-full guest answers `running` while every `exec` times out; a 502 or a silent empty is the channel | carry `timed_out` as its own field; never synthesise `box-unreachable` from it |
| **`cmux vm <verb>` takes the NAME column, not the LABEL** | `skills/cmux-cells` opening + §3 | `cmux vm stats pi-cell-4` returns a 404 whose own advice is "start a new one" — a spend-flavoured remedy for a running box | resolve LABEL→NAME from `cmux vm ls` and report the resolution |
| **`cmux workspace close` needs `--force`** for a running process | lane measurement (this brief) | the close appears to succeed while the lane keeps running | pass `--force` when the process is live, and re-read the process afterwards |

### 10.1 The two capacity calibrations — the trap that would call a dying Mac healthy

⛔ **This is the most dangerous single line in the whole inventory**, which is why it gets its own
subsection rather than a table row. There are **two** load rules on this fleet and they point in
opposite directions:

| platform | rule | owner / source | what a wrong read costs |
|---|---|---|---|
| **Linux cells** | load up to **8–10× the CPU count is normal** — a load of 80 on 10 CPUs is neither a wedge nor grounds to reap a lane | owner ruling 2026-11-02, `skills/cmux-cells` §2 (and the skill is explicit that this is a **CELLS** rule) | applying the laptop rule here refuses healthy dispatches (the skill records the earlier version of §2 doing exactly that, and the opposite error — filling a cell to 23 lanes — OOM-killed 37 processes, agent-infra#2159) |
| **macOS laptop** | **`load` ≲ 12 on 10 CPUs (≈1.2 load-per-CPU)**, and separately **≲ ~12 concurrent workstreams** — above either, sessions become unreachable | `AGENTS.md`, "Load, not context, is the concurrency ceiling" (which states both quantities) | applying the cell tolerance here **calls a dying box healthy**: the fleet IS the load, the remedy is fewer workstreams, and a census that reads load 80 as fine will keep dispatching into a box whose sessions cannot answer. ⛔ The two quantities are not interchangeable: the Mac legitimately runs ~22–29 lanes (measured on this box: `pgrep -x pi` = 22 while load read 45.76, so a load-threshold rule and a lane-count rule diverge exactly here — and note the load figure is itself a moment's reading, not a state), so a census comparing LANE COUNT to 12 reports it permanently over capacity and never states the load reading that means "dying". **The Mac branch must compare `load`, and report the lane count as context** |

Two further numbers that sit **between** those, and must not be confused with either:

- **`CAP_LPC_CEILING` = 8.00 load-per-CPU** (`capacity.sh:100`, default `:235`, enforced `:890`) and
  `ai-drainer.sh`'s `LPC_CEILING=8` are **placement** gates: they refuse to **ADD** work. Both compare
  `>=`, so exactly 8.00 already refuses. This is a *policy floor for new work*, not the tolerance for
  work already running, and not a statement about any platform's health.
- **`MAX_LANES` = 2.5 × cores when unset**, and the **cells pin `MAX_LANES=20`** in `keys.env`
  (operator-pushed — re-read it). All three cells enforce 20 regardless of core count, so on
  `pi-cell-3` (8 GB / 4 vCPU) it admits 20 lanes into 8 GB. The skill's own conclusion, which this
  inventory adopts: **`MAX_LANES` is an upper bound, never capacity** — the binding constraint is free
  disk vs one lane's tree+reserve (§2), then free RAM against the per-lane peak, then load.

**What this obliges the tool to do:** `fleet_census` reports **per box**, with the box's *platform* named
in the payload, and it must not emit one fleet-wide "load is fine / load is bad" verdict. Concretely, for
each box it reports `platform: macos|linux`, `load`, `lpc`, the **applicable** threshold with its
source, and free RAM + free disk (which §2 says are the real capacity terms). A single threshold
applied across boxes is the defect, and it fails in the direction that looks reassuring.

⛔ The skill also records that **`docs/ops/fleet-capacity.md` states the contrary twice** (**`:186`** "there is
deliberately no lane ceiling tied to cpu count", and **`:315`** restating it — the line numbers the skill
quotes for these had already moved, which is the skill's own reason for citing phrases) while the code implements the
2.5× rule — **two recorded positions, unresolved**, and the skill explicitly does not claim the doc is
wrong. This inventory does not settle it either: the tool reports the code's behaviour and the doc's
rule **as they are**, and the resolution belongs in `fleet-capacity.md` with an `OVERRIDES:` marker.
A census that silently picked one would be the "helpful reader tidies away a ruling" failure.

---

## 11. `instrument_versions()` — a wrapper, and a start gate

**Implementation:** `scripts/orchestrator-harness/harness-provenance.sh` (`write` / `check` / `show`,
exit `0` = no uncommitted edit, `1` = edit found, `2` = **UNKNOWN, never a pass**) plus
`scripts/orchestrator-harness/check-deployed-drift.sh --surface` (every place a harness script lives
on a box, including the directory the **running** controller executes).

**Why this is not new machinery (F9):** the measured failure behind invariant 5 is *"`--pin-check`
exit 1, checkout 151 commits behind the pin, so `scripts/` on that box — including the merge rail —
was older than the box claimed"*. That is exactly what `harness-provenance.sh::check` and
`check-deployed-drift.sh --surface` detect, and `harness-provenance.sh`'s own header records the twin
incident (a hand-applied fix reverted **twice** by a redeploy while every instrument said the box was
fine). Building a hasher inside the MCP server would be a second implementation of a question already
answered.

**The tool's contract:**

- `instrument_versions()` → one row per **wrapped module**: `path`, `sha256`, `commit` (from
  provenance), `deployed_dir`, `running_from` (drift's `--surface`), `ok|drift|unknown`.
- **Start-up gate:** the server runs `harness-provenance.sh check` **before it serves any tool**. Exit
  1 or 2 ⇒ **refuse to start**, naming the module and the reason. Exit 2 must refuse — treating
  "cannot verify" as a pass is the `no-op gate` failure class.
- **Per-module sha256 is a LOOKUP, not new code** — the record format already carries it:
  `harness-provenance.sh` documents `    <sha256>  <relpath>    one line per regular file the source
  shipped`, written per file via `sha_of()` and compared per file by `check`. **Corrected:** a first
  draft said provenance is file-granular "with a `--skip` list" and implied per-module hashing was
  missing; it is not, and building a hasher in the server would have used a second implementation.
- **The real gap, and it is a scope question, not code:** *which* deployed directories the record
  covers. `$O` is covered; `$HOME/.pi/agent/scripts/` (where `lane-status.py` actually runs from —
  F10) and `tools/fleet/` are not obviously in it. Phase 2's job is to make
  `instrument_versions()` answer **"is the copy that RUNS the one that was verified"** for the
  wrapped modules, by reading provenance and `check-deployed-drift.sh --surface` — and to report
  `unknown` where the record does not reach, rather than widening the hasher.

---

## 12. Invariants → the test each one must have

Each invariant is a test, not prose. The column that matters is the last one: what the test must
assert, because the obvious assertion is the one that passes on the broken version.

| # | Invariant | Fixture | What it must assert (the non-obvious part) |
|---|---|---|---|
| 1 | Unknown ≠ zero | a read that fails three different ways | the token `UNMEASURED(...)` **and the reason inside it** names the right cause. `UNMEASURED` with the wrong cause is still a lie (F5). Never assert merely "not 0" |
| 2 | An `open` issue is never merged/closed/done | a merged PR that **mentions** `#N`; a stale cache; a partial response; an unreachable API | the issue's own re-read `state` decides. A mention, a keyword, a cached value and a failed read all yield **not closed** — four separate fixtures, because they fail for four different reasons |
| 3 | A finished lane is never `dead`; no verdict ⇒ `no-verdict`, not `frozen` | the three measured finished shapes (§9 #5) + a lane with no readable evidence | `finished` and `no-verdict` are **two distinct values**, and `no-verdict` carries its reason. Also assert `frozen` is **unreachable** without a positively open turn (#1254) |
| 4 | Every number carries its measurement time and a correctly-computed age | a figure from 5 hours ago; a figure with a **future** stamp; a figure with an unparseable stamp | the age is computed at **render** time from the stamp, the future stamp is refused or clamped (as `beta-progress.py` now does), and the unparseable one is `UNMEASURED`, not `0m ago` |
| 5 | `instrument_versions()` lists each wrapped module's sha256; refuse to start if one is missing | a module deleted from the deployed tree; a drifted module; an unreadable record (exit 2) | the server **does not start** in all three, and the refusal names the module. The exit-2 case is the one a naive implementation passes |
| 6 | Mutation tests, red first | the six failures in §9 | the runner must **demonstrate the red**: apply the pre-fix behaviour to the fixture and show the test fails, then show it passes after. A test file that merely exists proves nothing |

**Mutation-testing note (this is the invariant most likely to be faked):** the honest form is a small
harness that (a) checks out the pre-fix line or injects the pre-fix branch, (b) runs the fixture, (c)
requires a non-zero exit, (d) restores, (e) requires zero. **Three** of the six failures have no
pre-fix line in git — #1, #2 and #4 all live in `fleet-report.py`, which **git has never held**
(`git ls-files | grep -c fleet-report.py` = 0). Of those three, #1 and #2 are red-first **against their
replacement** (no landing required) and only #4 is genuinely blocked until its bytes are tracked. One
more, #5, is reachable only through a composition that does not exist yet, so it is red-first at the
`lane_status` boundary once that exists and a pin at `evaluate` until then.

**And do not over-claim in the other direction** — #3 is *not* a mere pin: the pre-fix blob is in
git (`git show b54b117fc:scripts/beta-progress.py`), so it is the easiest mutation test in the set.
A Phase 2 that hunts a pre-fix line for #1/#2 would be performing the mutation theatre this invariant
exists to stop; one that refuses to look for #3's pre-fix line is leaving a real mutation test on the
table.

---

## 13. Open questions for the reviewer (decide before Phase 2)

1. **§4.3 — six states, `dead` included?** This inventory says yes, because the issue's invariant 3
   presupposes it. A five-state surface can only satisfy invariant 3 by dropping the positive `dead`
   finding, which reverses #1178's purpose.
2. **§7.3 — is `verify_independent` in Phase 2 or its own issue?** Its **procedure does exist** (F8:
   operating prompt + setup + evidence protocol, and the live poke already invokes it); what is
   missing is only the typed surface. **It is not unique in that** — #13 `reminder_*` is the same
   shape ("the verbs do not exist", §5 row 13), and it is not being proposed for splitting. So the
   real question is about **blast radius**, not about novelty: #11 is the only tool in the batch that
   creates and destroys cloud machines, which is why it is the one worth isolating. Reducing to 13
   tools costs the same CI run.
3. **F3 — do the three untracked modules get landed in this issue?** `orch-checkpoint.sh` is wrapped by
   #14. `fleet-report.py` is **not** a wrap target (D3) — it lands only if its `lanes=` fix is worth
   keeping, and #4 stays on tracked modules either way. `state/lane-verdict.py` is wrapped by neither,
   yet it holds one of the five `jev-latest` pins — which is reason enough on its own. Landing them is prerequisites, not scope creep — but it is bytes landing in
   `scripts/` inside a PR whose stated deliverable is a new server.
4. **§5 tool 5 — is the issue's 6-class PR vocabulary the *contract* or a *view*?** `pr_state.py`
   answers with 15 actions that carry strictly more information (`carry-patch` vs `carry` changes what
   the operator does). This inventory maps the 6 as a view and keeps the 15 as the answer.
5. **§8.1 — read-only by default?** The Kubernetes comparable's strongest published lesson is
   `--read-only` / `--disable-destructive`. **8 of the 14 tools are read-only**; #7, #8, #9, #11, #13
   and #14 are mutating (**6**), and 14 − 6 = 8. `box_exec` is the awkward one and must not be waved
   through: it runs an arbitrary command over `cmux vm exec`, so under "read-only unless a flag is set"
   it is the tool that defeats the control. Recommend: the server starts read-only unless a mutation
   flag is set; every mutating tool declares it in its schema; **#9 is gated hardest of all** — it is
   refused in read-only mode, and outside it, a declared command allowlist (never a free-form string)
   is what makes the mode mean anything.
6. **§4.2 + D8 — is retiring `lane-status.py`'s ladder in scope?** Following issue §1.2 means Phase 2
   **implements tree steps 2/3/5/6 inside `liveness.py`**, which is more work than wrapping three CLIs, and it makes
   `lane-status.py`'s 12-verdict ladder a second classifier that must then be retired or reduced to narration. That is
   the honest consequence of the issue's own instruction, not a scope grab — but it is a bigger Phase-2 than "14
   wrappers", and the reviewer should decide whether D8 lands in this PR or in a named follow-up with the ladder
   quarantined (one caller, one release) meanwhile. Doing neither leaves two ladders running, which is today's state and
   #1178's defect.
7. **F10 is a PROCESS problem, so it is not put to the owner — but it is not fixed inside a Phase-1
doc-only PR either.** The deployed `lane-status.py` is 2046 lines against the tracked 2528 and lacks
   `lane_cpu_progress`/`UNATTRIBUTED_WORKING`; the deployed `fleet-report.py`/`orch-checkpoint.sh` have
   no tracked counterpart at all. The remedies are `scripts/orchestrator-harness/harness-refresh.sh`
   (or `deploy-harness.sh`) for the first and landing the bytes for the rest — both of which change
   what the running controller executes, so neither belongs to a lane whose deliverable is one
   document. **Phase 2's first commit is the landing; the refresh runs in the same beat, verified by
   `harness-provenance.sh check` returning 0 rather than 1 or 2.** Until then every number in this
   document describes the **tracked** tree, and says so.

---

## Appendix A — exhaustive census (what exists, so nothing is re-derived)

**`scripts/` — 482 tracked files.** Named in this inventory because a tool wraps or must not
duplicate them: `admin-merge.sh`, `atomic-land.sh`, `beta-progress.py`, `ask-owner.py`,
`record-review.sh`, `lane-status.py`, `lane-actions.py`, `lane-read.py`, `lane-guard.py`,
`lane-arm.sh`, `lane-watchdog.py`, `lane-wip.py`, `child-check.py`, `tree-cpu.py`, `goal-state.py`,
`fleet-schedule.py`, `live-workspaces-publisher.py`, `objective-reminder.sh`, `orchestrator-heartbeat.sh`,
`heartbeat-loop.sh`, `scratch-worktree.sh`, `lib/pid-identity.sh`, `lib/lane-ceiling.sh`,
`lib/fleet-inventory.sh`, `tortoise-graph.sh`, `tortoise_graph_client.py`.

**`scripts/orchestrator-harness/` — 173 tracked files, 87 non-test modules.** Wrapped or
cross-referenced: `lane.sh`, `fix-one.sh`, `merge-one.sh`, `lane-exec.sh`, `lane-env.sh`,
`nonblocking-dispatch.sh`, `spawn-gate.sh`, `brief-gate.sh`, `claims.sh`, `branch-claim.sh`,
`branch-claim-hook.sh`, `capacity.sh`, `box-status.sh`, `check-deployed-drift.sh`,
`harness-provenance.sh`, `cycle-record.sh`, `lane-artifacts.sh`,
`lane-reap.sh`, `lane-bound.sh`, `merged-not-closed.sh`, `merge-rate.sh`, `orch-loop.sh`,
`worker-terminal.sh`, `auto-rail.sh`, `chain-merge.sh`, `dispatch-merge.sh`, `rail-refusal.sh`,
`reviewer-preflight.sh`, `pr-sickness.sh`, `pr-state.sh`, `stall-fix.sh`, `worker-supply.sh`.

**`tools/fleet/` — 9 non-test modules:** `liveness.py` (1632), `pr_state.py` (1034),
`claim_lanes.py` (1019), `lane_liveness.py` (735), `fleet-health.py` (739), `map-sessions.py` (81),
`dispatch_preflight.py` (530), `successor_preflight.py` (678), `outcome_canary.py` (5007).
`$HOME/.pi/agent/scripts/fleet/` is a **copy** of this tree (6 of the 9), i.e. a drift surface, not a
new surface.

**`$HOME/.pi/agent/scripts/` — 101 non-`.bak` entries (96 files + 5 directories).** The subset a tool
wraps: `lane-status.py` (**deployed copy is 2046 lines and stale — F10**),
`lane-actions.py`, `lane-read.py`, `beta-progress.py`, `fleet-schedule.py`, `goal-state.py`,
`record-review.sh`, `objective.py`, `turn-classify.py`, `ask-owner.py`,
`live-workspaces-publisher.py` — plus **three deployed-but-untracked** modules, `fleet-report.py` (here,
200 lines; D3 keeps it out of the wrapped set but it is still untracked bytes), `orch-checkpoint.sh`
(here) and `lane-verdict.py` (under `$HOME/.pi/agent/state/`) — the same three F3 names, because an
appendix that says "two" invites landing two of three.
**53 `.bak` files** sit beside them (`lane-actions.py` ×7, `objective.py` ×6, `lane-status.py` ×6,
`heartbeat-loop.sh` ×5, `ci_runner_gate.sh` ×3, …) — a note on how the fleet currently versions a
deployed script, not a tool surface. (The total is the measured one; three per-file exemplars were
transcribed one low and are corrected here.)

**`extensions/` — 47 entries.** Relevant to §8.1: `task-heartbeat.ts` (the `CPU_LIVENESS_TOOL_NAMES`
allowlist and the #512/#476/#783 ledgers), `builtin-tools/` (`DEFAULT_STREAM_STALL_MS`,
`DEFAULT_CPU_STALL_MS`, `TASK_TOOL_STALL_FRACTION`, `DEFAULT_HARD_CAP_MS` — every bound
`liveness.py` copies), `mcp-client/` (how an MCP server is loaded), `review-enforcer/` (the `carried`
arm), `task-signal-forensics.ts` (the signal-attribution instrument),
`sequence-enforcer`/`skill-enforcer`/`search-guard` (the "must refuse a running session" class).

**`tortoise/tools/`:** `cmux_dispatch.py` (wrapped by #8), `who_is-on.sh` + `who_is_on.py` (the local+remote
axis — `who_is_on.py` is the implementation, the `.sh` is a 3-line body behind a header; it imports
`collision_preflight` for its git enumeration, so a port is three files or a declared `UNMEASURED`),
`collision_preflight.py` (pre-dispatch in-flight work — **overlaps `claim_check`
deliberately and must not be re-wrapped**: it answers "is this issue already in flight on any
surface", #6 answers "does a ref-claim exist for this head"), `attest_census.py` (an independent read
of review proof — **not** wrapped by #10, which uses the local record; worth a note in Phase 2 so the
two never disagree silently), `lane_stash.py`, `worktree_report.py`, `test_lane.py`, `run_reaper.py`.

**`$HOME/.pi/agent/state/` — 29 `FINDING-*` notes.** Read in full for this inventory (each names a
classifier/actuator/aggregate defect a tool must not reproduce):
`FINDING-lane-classifier-both-directions-2026-10-11.md`,
`FINDING-lane-classifier-ignores-task-children-2026-10-11.md` (→ §7.1),
`FINDING-actuator-gap-concrete-2026-10-11.md`, `FINDING-aggregate-hides-the-step-2026-10-11.md`,
`FINDING-lane-death-orphan-watchdog-2026-11-02.md`, `FINDING-merge-deadlock-2026-11-01.md`,
`FINDING-lanes-shared-one-checkout-2026-10-22.md`, `FINDING-cell-auth-is-HOME-2026-10-22.md` (→ §10).
Also read in full: `LANE-STATE-DECISION-TREE.md` (the tree), `BEAT-CHECKLIST.md` (the six beat checks →
checks #4 and #14), `LANE-BRIEF-PREAMBLE.md`, and `skills/cmux-cells/SKILL.md` (756 lines — the semantics authority,
§5.7).

**Not a surface:** nothing. Both artefacts an earlier draft called phantom **exist** — the InstaBox
procedure (F8: `$HOME/.pi/agent/state/INSTABOX-OPERATING-PROMPT.md` + `instabox-setup.sh` +
`PAT-INSTABOX.md`) and `tortoise/tools/who-is-on.sh` (F7). Each was reported absent from a search that
omitted the directory it lived in.

---

## Appendix B — graph write-back

`tortoise_search` was run before this inventory (per the `research` skill) for
`orchestrator MCP typed facade / tool inventory duplication`. It returned **no relevant point** — only
unrelated `:Source` points about `scripts/admin-merge.sh`, with its relationship decoration
unavailable (`Query timed out`). So this inventory is not re-deriving a recorded conclusion, and the
findings that *are* durable conclusions (F1–F13, F7b included) are filed to the graph at the end of this lane,
one claim per point, `evidence`-shaped with their numbers.
