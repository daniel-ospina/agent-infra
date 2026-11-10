# Orchestrator MCP server — Phase 1 inventory (agent-infra #3382)

**Status:** Phase 1 deliverable. Ships **no code**. Phase 2 does not start until this document is
reviewed. **What Phase 2 actually ships is 11 tools expressed as 12 MCP names** — 10 new names plus an
*extension* of the two already-shipped ones (§5.9) — in one PR, one CI run. The 14 rows below are the
issue's original list; three of them do not ship as tools (#8 dropped, #2 merged into #1, #11 deferred)
and the reasons are file evidence, not preference.

> **Phase 2 has started, and it started somewhere other than tool 1 (2026-11-04).** The owner steer recorded
> on #3382 puts the **lane state primitive** first: an orchestration MCP whose tools cannot answer *"did it
> finish"* is a typed façade over blindness, and this fleet ran 26 lanes without being able to answer it for
> any one of them. That primitive is [`lane-registry.md`](lane-registry.md) — `refs/lanes/*`, four states
> (`RUNNING` / `DONE` / `FAILED` / `EXPIRED`), written by `spawn-gate.sh::run_agent`, read by two MCP tools
> (`lane.list`, `lane.show`). It is **additive** to the 14 rows below rather than a replacement: it is the
> evidence axis those rows have no access to, and `tools/fleet/liveness.py` remains the one liveness verdict.
> **Every other tool in this inventory is still unimplemented, and the surface beyond the two read-only tools
> is a contract change awaiting owner approval** (named in `lane-registry.md` §6).

> **⛔ PHASE 1.5 — THE EXISTENCE MAP WAS VERIFIED AGAINST THE CODE (2026-11-05).** §5 below was written from
> a research pass, so its `Existing implementation (file + function)` column was a **claim about code, not
> evidence of it**. Every one of the 14 rows has now been opened and checked: see [§5.0](#50-verified-existence-map-phase-15--every-row-opened-and-checked).
> **Three rows were wrong in a way that changes the plan: #8 is falsified outright (an existing tracked script
> already answers it end to end, *and* its claimed wrap target lives in the product repo), #4 changes bucket
> (the wrapper it claims takes no arguments at all), and #1's `finished` state — which §4.2 declares has no
> source — now has one.** Four more name an implementation that is real but not the best one (#3, #12, #13
> amend the wrap target; #14's ship-block is larger than stated).
> [§5.8](#58-missed-existing-work--what-the-inventory-did-not-find) records **20** pieces of existing work the
> inventory missed — including **the orchestrator MCP server itself**, which already exists, is registered in
> `.mcp.json`, and ships two tools. §5.6's counts are corrected from 8 WRAPPER / 6 PARTIAL / 0 NEW to
> **5 WRAPPER / 8 PARTIAL / 1 ALREADY-SERVED / 0 NEW** (#4 and #3 both move `WRAPPER → PARTIAL`, on file
> evidence: `beta-progress.py` parses no argv, and `lane-wip.py` has no `--json`), and the smallest correct Phase-2 set is **11 tools,
> not 14** (§5.9).

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
| `finished` | **new state — and it needs a SURFACE CHANGE upstream, not a wrapper.** ⛔ `lane-reap.sh reap --json` emits **one aggregate object** (`trees`, `zombie`, `candidates`, `reaped`, `refused`, `inert`, `unidentifiable`, `abstained`, `apply`) with **no per-lane row and no lane identity**; its per-tree decisions exist only as prose keyed by process root (`REFUSE root=<pid> …`, `WOULD REAP root=…`, `SKIP root=…`). ⛔ **THIS SENTENCE WAS TRUE WHEN IT WAS WRITTEN AND IS FALSIFIED AT HEAD (Phase 1.5, §5.0 V1).** It read *"so there is today no per-lane machine-readable source for `finished`"* — and the [lane state registry](lane-registry.md) now **is** one: `scripts/orchestrator-harness/lane_registry.py` (`STATES = ("RUNNING","DONE","FAILED","EXPIRED")` at `:137`, `collect()` at `:979`, `list_payload()` at `:1046`), written by the launcher (`spawn-gate.sh:2355` begin / `:2472` end), and exposed as the MCP tools `lane.list`/`lane.show` (§5.8 M1) with `EXPIRED` **derived, never written**. So the choice below is **narrower than stated**: `finished` has a per-lane source for registry-instrumented lanes, and what remains unmeasured is `finished` for a lane the registry never saw. Phase 2 does one of exactly two things, and says which: **(a)** extend `reap --json` with one row per tree carrying `{root, lane, log, gates{cpu,ancestry,stale}, verdict, reason}` — the right place, because the reaper owns the three gates (§4.1) — or **(b)** report `finished` per lane as `UNMEASURED(lane-reap-has-no-per-lane-output)`. What it must NOT do is parse the prose or read the aggregate `trees=` count as a per-lane answer; and it must not call the pass per lane (a full pass costs `LANE_REAP_WINDOW`, default 30 s) |

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
| `finished` | **`lane_registry.py`'s per-lane TERMINAL record** — `DONE`/`FAILED` written by the launcher that owns the lane (`spawn-gate.sh:2355`/`:2472`), already surfaced by `lane.list`/`lane.show`; `docs/ops/fleet-liveness.md` §11's three gates live in `lane-reap.sh` (**not** its `count` verb) but the reaper's `reap --json` is aggregate-only and is **not** this state's source (§4.2) | **not a `liveness.STATES` member** — it is a registry state, which is why the mapping happens on this surface and not in `evaluate()` |
| `no-verdict` | `liveness.py:unknown` + its named reason (`ps-unreadable`, `no-holder-record`, `off-fence`, `turn-state-unknown`, `claims-unreadable`, …) | the reason string is part of the contract, never optional |
| **`dead`** | `liveness.py:dead` (`incarnations-absent`) | **missing from the issue's list** — see F2 |

**What Phase 2 does, stated so the reading is not left to the implementer** (issue's §13 Q1 is still open):
a lane whose record is `RUNNING` and whose evidence positively says `dead` reports `state: "dead"` **plus**
`dead: true` **plus** `pending_owner_decision` naming §13 Q1. The five-state enum is preserved for every
other lane; `dead` is emitted only on positive death evidence, never synthesised. Mislabelling it
`no-verdict` is forbidden by this section ("a positive death finding is never reported as `no-verdict`"), and
mislabelling it `finished` is invariant 3's exact failure — so the sixth value is used, labelled, and the
contract question stays the owner's. **A lane whose terminal record is `DONE`/`FAILED` is `finished` whatever
the process table says** — that is invariant 3, and it is a mapping rule, not a classifier rule.

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

## 5. The 14 candidate tools (11 of which ship — §5.9)

Legend — **Class:** `WRAPPER` (an existing implementation answers the question; the tool adds typing,
one stable name and the `UNMEASURED` contract) · `PARTIAL` (an existing implementation answers part of
it) · `NEW` (nothing does; justified in §7) · **`ALREADY-SERVED`** (an existing script answers it **end to
end** with a typed contract, so an MCP tool adds no typed value and the row is deleted — the issue's own
rule, §6).

---

## 5.0 VERIFIED EXISTENCE MAP (Phase 1.5) — every row opened and checked

**Why this section exists.** §5's rows are a research pass's *claims*. This pass opened every named file,
falsified what was wrong, and searched beyond the inventory for work it did not find. Nothing here is taken
from §5 on trust; where §5 and the code disagree, the code is quoted.

**Method (all run in this worktree, `mcp-3382-phase2` @ `2577715cd`):**

| read | command / scope |
|---|---|
| every module named in §5 | `grep -n '^def \|^class \|^[A-Z_]* = ('` over each, then the named function read in context; line counts via `wc -l` |
| tracked-or-not | `git ls-files --error-unmatch <path>` per file; untracked repo files via `git ls-files --others --exclude-standard` (**0**) |
| the deployed population | `$HOME/.pi/agent/scripts/` diffed against tracked `scripts/` by name; `$HOME/.pi/agent/scripts/fleet/` byte-compared against `tools/fleet/` (`cmp -s`) |
| the beat's real call list | `grep -n 'beta-progress\|lane-status\|lane-actions\|merge-queue\|objective.py\|box-status\|lane-reap' scripts/orchestrator-heartbeat.sh` |
| search beyond the inventory | full tracked listings of `scripts/` and `scripts/orchestrator-harness/` (every non-test module, by name), `tools/fleet/`, `templates/launchd/`, `$HOME/Library/LaunchAgents/*.plist` (47), and the header of every candidate §5.8 names |
| the existing MCP surface | `mcp-servers/orchestrator/server.py` read in full (335 lines), `.mcp.json` read |

**Summary. `tracked?` is a deployment fact, not a style point: an untracked wrap target cannot ship.**

| # | tool | claimed impl (from §5) | claimed impl exists? | tracked? | **class (verified)** | changed? | already answers end-to-end + beat-wired? |
|---|---|---|---|---|---|---|---|
| 1 | `lane_status` | `lane-status.py` + `lane-actions.py` + `liveness.py` + `lane-reap.sh` | ✅ all four, all functions present | ✅ tracked (2528 / 2347 / 1632 / 1427) | **PARTIAL** | no | **YES** — `lane-status.py --json` is the heartbeat's own call |
| 2 | `lane_tree` | `lane_liveness.py::child_sids`/`enumerate_lanes` | ✅ (`:355`, `:378`) | ✅ tracked (735) | **PARTIAL** | no | no |
| 3 | `lane_artifact` | `lane-read.py::sid_for`/`files_for` + `lane-artifacts.sh` | ✅ **but `lane-read.py` has no `--json` and no exit contract**, and `lane-wip.py` has neither | ✅ tracked (68 / 862 / 121) | ⛔ **PARTIAL** | ⛔ **WRAPPER → PARTIAL** (V3) | partly — `lane-wip.py` is the better words axis, and it needs `--json` |
| 4 | `fleet_census` | `beta-progress.py::compute`/`main`, `capacity.sh probe`, `box-status.sh` | ✅ all present — **but `beta-progress.py` takes NO arguments and hardcodes one repo** | ✅ tracked | **PARTIAL** | ⛔ **WRAPPER → PARTIAL** | **YES** — `beta-progress.py`, `merge-queue.py`, `objective.py`, `fleet-inventory.sh` are all heartbeat calls |
| 5 | `pr_queue` | `pr_state.py::{verdict,action_for,row_action,fidelity,inherited_reds}` | ✅ all five (`:156`,`:290`,`:375`,`:248`,`:283`) | ✅ tracked (1034) | **WRAPPER** | a second existing seam was missed (M7) | **YES** — via `pr-state.sh`, consumed by 4 actors |
| 6 | `claim_check` | `claim_lanes.py` (7 fns) + `liveness.py::claim_verdict` + `claims.sh` + `who-is-on.sh` | ✅ all present; `--json` exists (`render_json` `:889`) | ✅ here; **`who-is-on.sh` is in the tortoise repo** | **WRAPPER** | two further claim surfaces missed (M19, M12) | **YES** — `claim_lanes` is imported by `liveness.py`/`lane_liveness.py`/`lane-status.py` |
| 7 | `lane_dispatch` | `nonblocking-dispatch.sh`, `lane.sh`, `lane-exec.sh`, `spawn-gate.sh::run_agent`, `brief-gate.sh`, `dispatch_preflight.py`, `successor_preflight.py` | ✅ all — exits 2/78/80 verified | ✅ tracked | **PARTIAL** | no | **YES** — the controller path |
| 8 | `lane_message` | `tortoise/tools/cmux_dispatch.py` + `objective-reminder.sh` | ✅ — **but the file is in the product repo, so it cannot ship from agent-infra** | ❌ **wrap target absent here** | ⛔ **ALREADY-SERVED → DELETE** | ⛔ **WRAPPER → ALREADY-SERVED** | **YES** — `scripts/safe-send.sh` wraps all five exits today |
| 9 | `box_exec` | `cmux vm exec`, `cloud-cell-doctor.sh`, `box-status.sh` | ✅ (external verb + tracked scripts) | ✅ tracked | **WRAPPER** | `lib/bounded.sh` must be reused (M14) | no |
| 10 | `review_record` | `record-review.sh --check-carry` (7 verdicts) + `--print-diff-hash` | ✅ verdict table at `:40-67`, block at `:2243+` | ✅ tracked (4467) | **WRAPPER** | no | partly — `pr_state.py` uses its own predicate (D9 stands) |
| 11 | `verify_independent` | instabox CLI + `instabox-setup.sh` + operating prompt + `PAT-INSTABOX.md` | ✅ **all six artefacts present** (22661 / 1473 / 6283 / 14739 / 11746 bytes) | ❌ **all outside the repo** | **PARTIAL** | no | no |
| 12 | `closure_audit` | gh `closingIssuesReferences` (`review-pr.sh:501`), `beta-progress.py::covered`, `merged-not-closed.sh`, `outcome_canary.py` | ✅ field consumed at `:501`; **`outcome_canary.py` answers fleet OUTCOMES, not closures** | ✅ tracked | **PARTIAL** | wrap target amended (V12) | **partly** — `merged-not-closed.sh --json` answers merged→open end to end |
| 13 | `reminder_*` | `objective-reminder.sh` + `fleet-schedule.py` | ✅ both present — **but `merge-reminder.py` already has `--install-timer`/`--uninstall-timer`/`--json`** | ✅ tracked (262 / 1841 / **3014**) | **PARTIAL** | delta much smaller (V13) | **YES** — cadence timer + heartbeat are wired |
| 14 | `beat_checkpoint` | `cycle-record.sh`, `goal-state.py`, `orchestrator-heartbeat.sh`, `orch-checkpoint.sh` | ✅ all present; **`orch-checkpoint.sh` is untracked, and so is its launchd plist** | ⛔ **`orch-checkpoint.sh` TRACKED: NO** | **WRAPPER + PARTIAL** (bucket: WRAPPER) | ship-block bigger than stated (V14) | **YES** — `com.tortoise.orch-checkpoint.plist` is loaded |

### 5.0.1 Per-row verification, with the signatures

Each block gives: what §5 claimed · the real `file:line`, signature and return shape · tracked? · the delta an MCP tool
must add · what it does NOT answer.

**V1 — `lane_status(lane|box|all)` · PARTIAL (unchanged) · the delta shrinks, and §4.2's `finished` claim is falsified.**

| field | verified |
|---|---|
| claimed | `lane-status.py` (`lane_cpu_busy`, `child_suppresses`, `last_tool_call`, `resolve_session_ex`), `lane-actions.py::classify_row`, `liveness.py::evaluate`/`gather`, `lane-reap.sh`'s three gates |
| **verified** | `scripts/lane-status.py:520 def lane_cpu_busy(label, session_file, dir_lanes, dir_pids, cpu0, cpu1)`; `:242 def child_suppresses(verdict, declared, pane_kids, child, child_stale, abandon_s=None)`; `:1483 def last_tool_call(path)`; `:944 def resolve_session_ex(ws)`; `:177 VERDICT_RANK`; **2528 lines**. `scripts/lane-actions.py:872 def classify_row(row, dead, files, LS)`; `:1306 def jev_step5(rows, LV, enabled=True)`; **2347 lines**. `tools/fleet/liveness.py:225 STATES = ("dead", "running-quiet", "wedged", "idle", "unknown")`; `:874 def evaluate(ev: Evidence) -> Verdict`; `:1501 def gather(...)`; **1632 lines**. `lane-reap.sh:989 --json) json=1` — **reap only**; its payload (`:1285`) is **one aggregate line with no lane identity** |
| tracked | ✅ all four |
| return shape | `evaluate` → `Verdict` (a `state` from `STATES` + a `reason` citing its numbers); `classify_row` → a 12+-verdict row; `lane-reap.sh reap --json` → one summary with `trees/zombie/candidates/reaped/refused/inert/unidentifiable/abstained/mode`, exit 3 (cannot-verify) or 4 (judged nothing by policy) |
| **what it does NOT answer** | one vocabulary across four modules; `dead` on the surface (issue's five states, §4.3); the CPU/child/tool-age steps **at the `liveness.py` layer**; Step-6 recursion; and **`finished` no longer has no source** — see the correction below |
| **`finished` — §4.2 FALSIFIED, AND §4.3/§5.1 CORRECTED TO MATCH** | §4.2 (and, until this correction, §4.3's `finished` cell and §5.1's row-1 plan cell) said there is **no per-lane machine-readable source for `finished`**. That was true when written and is **not true at HEAD**: `scripts/orchestrator-harness/lane_registry.py:137 STATES = ("RUNNING", "DONE", "FAILED", "EXPIRED")`, `:979 def collect(args) -> (ok, detail, rows, code, applied, extra)`, `:1046 def list_payload(...)` — a per-lane **terminal record**, written by the launcher that owns the lane (`spawn-gate.sh:2355 lane_registry_begin`, `:2472 lane_registry_end`), already exposed as MCP tools `lane.list` / `lane.show` (§5.8 M1), with `EXPIRED` **derived, never written**. So §4.2's choice **(a) extend `reap --json` / (b) `UNMEASURED`** is **stale for registry-instrumented lanes**. What the registry does **not** say is anything about the process: a `DONE` record does not mean nothing is alive, and a `RUNNING` record asserts no progress |
| **class** | **PARTIAL** — confirmed. The remaining write is: bring steps 2/3/5/6 into `liveness.py` per issue §1.2, and **map `lane_status` onto the registry's four states rather than inventing a fifth vocabulary** |
| **already end-to-end + beat-wired?** | **YES.** `scripts/orchestrator-heartbeat.sh:521` runs `lane-status.py --json --sample 12` and publishes `state/lane-status.last.json`, which `lane-actions.py` consumes. The beat's lane answer is already one call — the gap is the vocabulary, not the wiring |

**V2 — `lane_tree(lane)` · PARTIAL (unchanged) · and two child-signal modules exist that §5 never names.**

| field | verified |
|---|---|
| claimed | `lane_liveness.py::child_sids` + `enumerate_lanes(…, children)`; `lane-artifacts.sh`; `~/.pi/agent/task-sessions/<uuid>/` |
| **verified** | `tools/fleet/lane_liveness.py:355 def child_sids(task_sessions_dir: str) -> frozenset`; `:378 def enumerate_lanes(sessions: Dict[str, dict], children) -> List[Lane]`; `:402 def verdict_for(lane, *, store_path, sessions_dir, lib, now_ms)`; **735 lines**. **Missed:** `scripts/child-check.py:1` (104 lines) — *"the three-signal read on `task` children. REPORTS; never kills"*; `scripts/lane-watchdog.py` (**825 lines**) — frozen-child detection under three all-required gates; `scripts/tree-cpu.py` (124) — own-CPU-flat vs descendants working |
| tracked | ✅ all |
| return shape | `child_sids` → a `frozenset` of child session ids (the **edge set only**); `enumerate_lanes` → `List[Lane]`; `verdict_for` → a `Verdict` for a LANE |
| **what it does NOT answer** | the recursion. `verdict_for` verdicts whatever `Lane` you hand it and `child_sids` never calls it — so **nothing applies the tree to the child**, which is Step 6's own instruction. Confirmed by reading both: neither references the other's verdict path |
| **class** | **PARTIAL** — confirmed. The write is `map(lane_status, tree_nodes)` where `lane_status` is the same function, exactly as §7.1 says |
| **already end-to-end + beat-wired?** | no — `lane_watchdog.py` runs on its own schedule for a different question (reaping a frozen child, not verdicting it) |

**V3 — `lane_artifact(lane)` · WRAPPER (unchanged) · but `lane-read.py` is not a wrapper-grade module.**

| field | verified |
|---|---|
| claimed | `lane-read.py` (`sid_for`, `files_for` — last N assistant messages by pane); `lane-artifacts.sh` (verbs, exits); `BEAT-CHECKLIST.md`'s `## LANE-DONE <verdict> <ts>` |
| **verified** | `scripts/lane-read.py:22 def sid_for(ws)`, `:31 def files_for(sid)` — **68 lines, a SCRIPT not a module**: it parses `sys.argv` at import (`N = int(sys.argv[2]) if len(sys.argv) > 2 else 3`), prints prose, and has **no `--json`, no exit contract**. `lane-artifacts.sh:73 Exit: 0 found · 3 ABSENT-EVERYWHERE · 4 UNMEASURED (absent NOT claimed) · 5 PULL-FAILED · 64 usage` — a real typed contract, 862 lines. The `## LANE-DONE` line is real (`BEAT-CHECKLIST.md`, check #4 and the abandonment rule) |
| tracked | ✅ both |
| **what it does NOT answer** | any machine-readable shape on the words axis (`lane-read.py` cannot be subprocessed for a payload without parsing prose); the cell-artifact axis is `lane-artifacts.sh`'s and is already typed; **and the better words-axis tool was missed** — `scripts/lane-wip.py` (121 lines, tracked) answers "WHAT is this lane's work in progress" with a discriminating rule (*"A verdict (DONE-IDLE / WIP-IDLE) cannot tell 'finished' from 'stopped with work left'. The LAST ASSISTANT TURN can"*), which is the actual question §5 row 3 states |
| **class** | ⛔ **PARTIAL** — corrected from `WRAPPER`, and the reason is the wrap target itself: `lane-wip.py` was chosen because it **answers row 3's question** (*"a verdict (DONE-IDLE / WIP-IDLE) cannot tell 'finished' from 'stopped with work left'. The LAST ASSISTANT TURN can"*), **not** because it has a payload — it has none. So the write is **`lane-wip.py --json` + a stated exit contract** (today: prose on stdout, and the only non-zero exit is `2` for usage/no-match/`lane-status` unreadable, which collapses three different outcomes into one), plus the files axis (`lane-artifacts.sh`, already typed). `lane-read.py` keeps `sid_for` and is not itself a payload source |
| **already end-to-end + beat-wired?** | no. `lane-actions.py` reads the transcript directly (`_wide_last_text` `:1380`) rather than shelling out to `lane-read.py` — i.e. **there are already two transcript readers**, and a third would be the duplication this issue exists to stop |

**V4 — `fleet_census(repos)` · ⛔ WRAPPER → PARTIAL · the claimed wrapper takes no arguments at all.**

| field | verified |
|---|---|
| claimed | `beta-progress.py::compute`/`main`; `capacity.sh probe` (refuses at `CAP_LPC_CEILING` = 8.00, `>=`); `box-status.sh` (**six** lines on exit 0); `fleet-health.py`; `fleet-schedule.py --status`; `BEAT-CHECKLIST.md` checks 1-3 |
| **verified** | `scripts/beta-progress.py:472 def compute()` → `{ts, open_prs, merged_today, p0:{open,with_pr,without}, p1:{…}}` or **`None`**; `:522 def main()` → prints one `DELIVERY [as of …]` line. ⛔ **`REPO = "daniel-ospina/tortoise"` at `:35`, and `main()` parses NO argv** — the module's only trailer is `sys.exit(main())` and `main()` never reads `sys.argv`. **There is no `--json` and no repo parameter.** `capacity.sh:1329 cap_cli()` — verbs `probe\|fork\|place\|fleet\|publish`; `CAP_LPC_CEILING="${CAP_LPC_CEILING:-800}"` `:235`; the `>=` refusal at `:890`. ⛔ **`probe` is not the only relevant verb: `cap_read_fleet()` `:1129` reads the fleet-wide `refs/capacity/*` channel and `cap_publish()` `:1270` writes it** — neither is named in §5. `box-status.sh:320-338` emits `harness:`, `stamp:`+`pin:`, `ref:`, `controller:`, `running:`, `roles:` (six on exit 0, exit 2 = cannot-verify) — ⚠️ **but the file's own header `:2` says "five machine-parsable lines" and lists five, omitting `ref:`: behaviour has six, the header has five, and §5's "six" matches the behaviour.** `tools/fleet/fleet-health.py:126 def cputime_secs(pid)`; `:614 def main()`. `scripts/fleet-schedule.py:1365 def cmd_status()` |
| tracked | ✅ all |
| **what it does NOT answer** | (i) **a repo argument** — `fleet_census(repos)` cannot be a wrapper of a module with no parameter, so multi-repo is a **write**; (ii) a typed payload with `measured_at` (the text line has an age, the bytes do not); (iii) the **platform-named threshold** (§10.1) — no module carries `platform: macos\|linux`; (iv) ⛔ **`fleet-report.py` is still untracked** (200 lines on this box, `git ls-files` count **0**) |
| **class** | ⛔ **PARTIAL**, corrected from WRAPPER. The named modules exist and three are beat-wired, but the tool's own signature (a repo list) is not answerable by any of them |
| **already end-to-end + beat-wired?** | **YES, for the single-repo case and for capacity.** `orchestrator-heartbeat.sh:411` calls `beta-progress.py`, `:425` `merge-queue.py`, `:454` `objective.py`; `lib/fleet-inventory.sh` is called by the heartbeat, `heartbeat-loop.sh`, `lane-actions.py`, `objective-reminder.sh`, `fleet-health.py` and `watchdog-loop.sh` |

**V5 — `pr_queue(repo)` · WRAPPER (unchanged) · and a second seam already solved the "don't parse the JSON" problem.**

| field | verified |
|---|---|
| claimed | `pr_state.py` — `action_for`, `row_action`, `fidelity`, `inherited_reds`, `verdict`; 15 actions; exit 2 = the pass could not be made |
| **verified** | `tools/fleet/pr_state.py:156 def verdict(rows)`; `:290 def action_for(ev)`; `:375 def row_action(ev)`; `:248 def fidelity(record, head, diff_read)`; `:283 def inherited_reds(pr_reds, main_reds)`; `:595 def read_local_record(repo, pr)`; `:915 def main(argv)`; **1034 lines**. **Missed:** `scripts/orchestrator-harness/pr-state.sh:1-10` (72 lines) — *"THE ROUTER SEAM… `prstate_row <owner/repo> <pr>` → `ACTION<TAB>rerun_run<TAB>reason` (rc 0) / `unavailable<TAB>-<TAB>why` (rc 2)… an actor that re-derives the answer is the defect #2866"* — already consumed by `admin-merge.sh`, `pr-doctor.py`, `refresh-candidates.sh`, `pr-sickness.sh`, `lane-merge.sh` |
| tracked | ✅ |
| return shape | `pr_state.py` → rows with the 15 actions + `fidelity` + `REASON`, exit 2 when the pass could not be made; `pr-state.sh` → **three tab-separated fields and rc 0/2** |
| **what it does NOT answer** | closing issues per row (only `review-pr.sh:501` consumes `closingIssuesReferences`); and §5's D9 stands — `pr_state.py::fidelity` and `--check-carry` **genuinely disagree** on `nodigest` and `carry-patch` (confirmed: `fidelity()` is a four-state predicate over `--print-diff-hash` and never calls `--check-carry`) |
| **class** | **WRAPPER** — confirmed, and **`pr-state.sh` is the shape to copy**: it already answers the MCP payload question in three fields with an abstention return code, which is §5's own `UNMEASURED` contract written in shell |
| **already end-to-end + beat-wired?** | **YES** — through `pr-state.sh` into four actors, and `merge-queue.py` turns the raw count into a verdict on the heartbeat |

**V6 — `claim_check(issue, repo)` · WRAPPER (unchanged) · but F7b's "three implementations" undercounts by at least two.**

| field | verified |
|---|---|
| claimed | `claim_lanes.py` (`read_registry`, `read_pull`, `read_snapshot`, `parse_key`, `parse_owner`, `parse_lease`, `to_evidence`); `liveness.py::claim_verdict` + `CLAIM_REASONS`; `claims.sh`; local axis `tortoise/tools/who-is-on.sh` |
| **verified** | `tools/fleet/claim_lanes.py:856 def read_registry(*, repo, remote_url, …)`; `:488 def read_pull(remote, *, repo, ns, …)`; `:744 def read_snapshot(path, *, max_age_s, ns, …)`; `:621 def parse_key(key)`; `:369 def parse_owner(owner, host)`; `:387 def parse_lease(raw, now)`; `:876 def to_evidence(cr, **kw) -> liveness.Evidence`; **`:889 def render_json(cr, verdict)`** (so `--json` EXISTS, as §5 said); 1019 lines. `tools/fleet/liveness.py:830 def claim_verdict(cr: ClaimRead) -> Verdict`; `:785 CLAIM_REASONS = (…)`. `scripts/orchestrator-harness/claims.sh` tracked. `tortoise/tools/who-is-on.sh` **present** (1954 bytes, also in 4+ worktrees) |
| tracked | ✅ in `tools/fleet`; **`who-is-on.sh` is NOT in this repo** |
| **what it does NOT answer** | the two axes joined; and **two further claim surfaces exist that F7b's count of three misses** — (i) `scripts/orchestrator-harness/lane_registry.py` — the per-lane state record, i.e. an *identity* claim with a lease (§5.8 M19); (ii) `scripts/orchestrator-harness/provision-lane-registry.py` (743 lines), which derives the box's lane roster into `lane-registry.tsv`, the **fleet-board holder surface** `tortoise/tools/collision_preflight.py:5693 def _board_can_answer(state)` gates on — plus `scripts/orchestrator-harness/live-ownership.sh` (422), which answers "is a LIVE PROCESS working this PR". F7b's "three implementations across two axes" is really **five across three** (ref-claims · local-checkout · live-process ownership) |
| **class** | **WRAPPER** — confirmed |
| **already end-to-end + beat-wired?** | **YES** — `claim_lanes` is imported by `tools/fleet/liveness.py`, `lane_liveness.py` and `scripts/lane-status.py`, so the claim axis already rides the beat's lane scan |

**V7 — `lane_dispatch(...)` · PARTIAL (unchanged) · every named module exists and the exit codes are exactly as claimed.**

| field | verified |
|---|---|
| claimed | `nonblocking-dispatch.sh` (2 = caller bug, 78 = validator stale/absent, 80 = brief-gate); `lane.sh`; `lane-exec.sh`; `spawn-gate.sh::run_agent`; `brief-gate.sh`; `dispatch_preflight.py`; `successor_preflight.py`; `branch-claim.sh`/`branch-claim-hook.sh` (`refs/claims/branch-<slug>`) |
| **verified** | `nonblocking-dispatch.sh` (473) — `exit 2` at `:34,:89,:97,:134,:136,:137`; `exit 78` at `:120,:123,:132,:168,:208`; `exit 80` at `:194`. `spawn-gate.sh:1840 run_agent() { # run_agent <seconds> <logfile> <promptfile> [label]` — **and `merge-one.sh:136 run_agent()` is a SECOND copy**, a declared residual at `spawn-gate.sh:736`. `lane-exec.sh:1` — *"launch ONE lane so that NO WRAPPER SURVIVES it (#2163)"*. `branch-claim.sh:14` — *"the lock is `refs/claims/branch-<slug>` … IT EXTENDS `claims.sh`, IT DOES NOT ADD A REGISTRY"*. `dispatch_preflight.py` (530) refuses a dispatch into a worktree with **nothing to land**; `successor_preflight.py` (678) |
| tracked | ✅ all |
| **what it does NOT answer** | `env` into the agent's **process** environment; and the two measured silent-actuator failures as typed codes (`no-pid`, `branch-exists`) — **confirmed absent**: neither string appears as an exit code anywhere in `nonblocking-dispatch.sh` |
| **class** | **PARTIAL** — confirmed |
| **already end-to-end + beat-wired?** | **YES** — controller → `orch-loop.sh` → `lane.sh`/`fix-one.sh`/`merge-one.sh` |

**V8 — `lane_message(lane, text)` · ⛔ WRAPPER → ALREADY-SERVED → DELETE.**

| field | verified |
|---|---|
| claimed | `tortoise/tools/cmux_dispatch.py` (exits 0 consumed / 1 sent-not-consumed / 2 usage / 3 transport / 4 queued); `objective-reminder.sh` (byte budget, `latest_submitted_at`, backend-aware) |
| **verified** | The five exits are as claimed — **and the file is in the product repo**, so like F7's `who-is-on.sh` it **cannot ship from agent-infra** (§5 never applied F7's own lesson to this row). ⛔ **And the surface already exists here:** `scripts/safe-send.sh` (233 lines, **tracked**) — `:8` *"dispatch to a lane ONLY if it can actually READ the message"*; `:38` *"Exit: 0 sent+consumed · 3 REFUSED (lane busy) · 78/80 REFUSED by the brief gate · anything else from the dispatcher"*; `:206-232` shells out to `cmux_dispatch.py` and **maps all five exits to distinct typed ones**. So do **`scripts/orch-send.sh`** (263, tracked) — *"the ONLY safe way to dispatch a lane order from the orchestrator … RULE: a NEGATIVE list fails open. Require a POSITIVE match instead"*, refusing a nonexistent UUID, another repo's lane, and the orchestrator itself — and `scripts/objective-reminder.sh` (262) |
| tracked | ⛔ the wrap target is **not in this repo**; both replacements are tracked |
| **what it does NOT answer** | ⛔ **only one thing, and it is a precondition, not a surface**: nothing refuses a `pi -p` lane. `safe-send.sh`'s refusal paths are brief-gate (`:86-92`), no-pi-in-pane (`:127`), unreadable pane (`:154`) and pane-busy (`:186`) — **no print-mode test** (grep for `pi -p`/`print` in its refusal path returns nothing). So F13's finding is **real but narrower than §5 states**: §5.7 says *"Today nothing stops a caller doing it"*, and **that is false** — `safe-send.sh` and `orch-send.sh` stop most of it and are the sanctioned path |
| **class** | ⛔ **ALREADY-SERVED → DELETE** as an MCP tool. The issue's own rule (§6) deletes a tool that duplicates an existing script without saying why; here the existing script is *better* than the proposed wrapper (typed exits, brief gate, positive pane match). **The F13 fix belongs in `safe-send.sh`** — a print-mode refusal is ~15 lines in a 233-line tracked file that already refuses four other things |
| **already end-to-end + beat-wired?** | **YES** — `safe-send.sh` is invoked by `tools/fleet/outcome_canary.py` and written into the harness install path |
| **⛔ "all five exits as typed ones" is TOO STRONG — corrected** | Read at its `case "$RC"` block (`scripts/safe-send.sh:210-232`), safe-send preserves **three** of the five as distinct results and **collapses the other two into one unknown bucket**: `0 → 0` (sent+consumed), `1 → 4` *AMBIGUOUS* (sent-but-not-consumed, message MAY be in the composer, do not blind-retry) or `5` (failed-to-start, nothing written), `3 → 3` (refused, never became ready), and **`2` and `4` both fall to `*) → 5 UNKNOWN`** (*"state NOT established"*). So `4 = queued / DELIVERED, not consumed` — `cmux_dispatch.py`'s own distinction, `:119-120` and `:2645-2649` in the product repo — is **lost** today, and a queued instruction reads as an unknown one. The deletion of #8 still stands, and on the grounds that survive: the wrap target is in the **product repo** (unshippable from here), and `safe-send.sh` + `orch-send.sh` carry a **stricter precondition set** (brief gate, no-pi guard, positive pane match) than the proposed wrapper. What does not survive is the claim that it already types all five. **Carry this forward as the mapping #8 would have delivered** — ~10 lines, added to the F3 prerequisite list rather than to a tool: |
| **carry-forward mapping (the prerequisite, not the tool)** | `cmux_dispatch` `0 consumed → 0 DELIVERED-CONSUMED` · `1 sent-not-consumed → 4 DELIVERED-NOT-CONSUMED` (keep `AMBIGUOUS` as the message, name the code) · `2 usage → 2 USAGE` (**new**, today it collapses into `5 UNKNOWN`) · `3 transport → 3 REFUSED-TRANSPORT` · `4 queued → 4 DELIVERED-NOT-CONSUMED/QUEUED` (**new** — the exact value being lost today; `4` is the *right* code for both non-consumption shapes and the sub-state is what distinguishes them, so no caller reads a queued order as an unknown one) · anything else → `5`, unchanged |

**V9 — `box_exec(box, cmd)` · WRAPPER (unchanged) · but the timeout discipline already has ONE home.**

| field | verified |
|---|---|
| claimed | `cmux vm exec --timeout` (the transport `lane-artifacts.sh` pulls over); `cloud-cell-doctor.sh`; `box-status.sh` |
| **verified** | `lane-artifacts.sh:73` — `5 = PULL-FAILED`, i.e. the transport *is* wrapped once already with a typed failure. `cloud-cell-doctor.sh` (**3128**); `box-status.sh` (342) |
| tracked | ✅ |
| **what it does NOT answer** | the `{rc, stdout, timed_out, truncated}` shape — genuinely absent |
| **class** | **WRAPPER** — confirmed. ⛔ **But it must not invent a timeout:** `scripts/lib/bounded.sh` (189 lines, tracked) is *"ONE bounded-execution helper … `timeout` -> `gtimeout` -> the internal watchdog"*, written because **macOS has no `timeout` and every class of `disk-reaper.sh` died with rc=127 while the pass printed `verdict=fail-closed`** — the exact false-PASS shape row 9 would reproduce. `watch-truncation.sh` is the truncation-side prior art |
| **already end-to-end + beat-wired?** | no |

**V10 — `review_record(pr)` · WRAPPER (unchanged) · the seven verdicts and their exit codes are exactly as claimed.**

| field | verified |
|---|---|
| claimed | `record-review.sh --check-carry` (**positional** `<pr> [owner/repo]`; `--repo` exits 2); one tab-separated line `<verdict>\t<record digest\|->\t<live digest\|status>`; verdicts `head`(0)/`carry`(0)/`carry-patch`(6)/`fresh`(1)/`unreadable`(3)/`norecord`(4)/`nodigest`(5); `--print-diff-hash` |
| **verified** | `scripts/record-review.sh:36` (usage), `:1226 --print-diff-hash) PRINT_DIFF_HASH=1`, `:1227 --check-carry) CHECK_CARRY=1`, block at `:2243` *"THE LANE'S QUESTION, ANSWERED BY THE GATE'S OWN PREDICATE"*; `:2365 printf 'norecord\t-\t%s\n'`, `:2450 printf 'nodigest\t-\t%s\n'`, `:2488 printf 'carry-patch\t%s\t%s\n'` — the tab-separated **three-field** line is real, and each verdict carries its own next action on stderr. 4467 lines |
| tracked | ✅ |
| **what it does NOT answer** | the head the record is bound to **in one reply**; and §5 misses `scripts/registry-sync.sh` (1089, tracked) — a record may have been minted on **another box** and replicated here, so `norecord` locally is not `no record anywhere` (its exit 4 is *"records were SKIPPED because they could not be read"*, exit 3 is *"CONVERGED WITH DIVERGENCE"*) |
| **class** | **WRAPPER** — confirmed |
| **already end-to-end + beat-wired?** | partly — `pr_state.py::read_local_record` (`:595`) reads the record itself rather than calling `--check-carry` (D9) |

**V11 — `verify_independent(repo, ref)` · PARTIAL (unchanged) · every named artefact verified present, all six outside the repo.**

| field | verified |
|---|---|
| claimed | `instabox` CLI v0.8.125 + `instabox-setup.sh` + `INSTABOX-OPERATING-PROMPT.md` + `PAT-INSTABOX.md`; `scratch-worktree.sh` and the `verifier` agent are not substitutes |
| **verified** | `~/.local/share/pi-node/current/bin/instabox` (**22661 B**), `~/.pi/agent/instabox.json` (354 B), `~/.pi/agent/instabox-setup.sh` (**1473 B**), `~/.pi/agent/state/INSTABOX-OPERATING-PROMPT.md` (**6283 B**), `~/.pi/agent/state/PAT-INSTABOX.md` (**14739 B**), `~/.pi/agent/state/poke-loop-inner.sh` (**11746 B**). `scripts/scratch-worktree.sh` = **709 lines**, tracked, *"the ONE way to get an isolated checkout for a review/probe/verification cycle (#1141)"* |
| tracked | ⛔ **none of the six** — and the CLI lives under a **pi-node-managed path**, not an agent-infra one, so a fresh box has it only if pi-node ships it |
| **what it does NOT answer** | the typed surface; and a **guaranteed** teardown |
| **class** | **PARTIAL** — confirmed |
| **could not verify** | the key's scope (`machines:delete`) was **not read** — it is a live credential and reading it was out of scope for a planning pass. §7.3's scope claim is therefore **unverified here**, not confirmed |

**V12 — `closure_audit(pr)` · PARTIAL (unchanged) · but `outcome_canary.py` is not a closure source, and `merged-not-closed.sh --json` is.**

| field | verified |
|---|---|
| claimed | gh `closingIssuesReferences` (**already consumed by `scripts/review-pr.sh:501`**); `beta-progress.py::compute`'s `covered()`; `merged-not-closed.sh`; `outcome_canary.py` |
| **verified** | `scripts/review-pr.sh:501-502` — `ISSUE_URLS="$(env -u GH_REPO gh pr view "$PR" --repo "$REPO" --json closingIssuesReferences --jq '.closingIssuesReferences[]?.url' …)"` with the fail-closed arm at `:504` (*"an unreadable list is not 'closes no issue'"*). `beta-progress.py:499 def covered(n)` — a **closure inside `compute()`**, not a module-level function, walking `openpr + merged` on `headRefName`+`title`. ⛔ **`tools/fleet/outcome_canary.py` (5007) does NOT contain a closure check** — the real grep is `grep -n 'closure\|closingIssues\|merged-not-closed' tools/fleet/outcome_canary.py`, which returns **three hits and every one is `disclosure`** (`:411`, `:2493`, `:4013`), never `closure` — it asserts fleet **outcomes** (controller cycling, landers, launchd, queue tokens). Naming it as row 12's implementation was wrong. **`scripts/orchestrator-harness/merged-not-closed.sh` (249)** is the real prior art: `--json` → `{"repo", "hits":[{"issue","title","priority","prs":[{"pr","merged_at"}]}], "unqueried":[…]}`; `EXIT: 0 when it ran (an empty result is a real answer, not a failure); 2 when a surface could not be queried — never 1`, and its own stated limit: *"A HIT IS A QUEUE ENTRY, NOT A VERDICT … it finds them, it does not judge them, and it must never be wired to an automatic close"* |
| tracked | ✅ all |
| **what it does NOT answer** | the direction that matters for invariant 2: **what did THIS merge close**, from `closingIssuesReferences` + each issue's live `state`. `merged-not-closed.sh` walks the issue **timeline** for merged PRs referencing it (the other direction), and `covered()` is the prose-keyword defect itself |
| **class** | **PARTIAL** — confirmed, **wrap target amended**: `merged-not-closed.sh --json` is the shape and the evidence ladder to copy; `gh … closingIssuesReferences` is the field; `outcome_canary.py` is **removed** as a closure source |
| **already end-to-end + beat-wired?** | **partly** — `merged-not-closed.sh` answers the merged→open direction end to end with a typed payload; nothing answers closed→what-closed-it |

**V13 — `reminder_set` / `reminder_list` / `reminder_cancel` · PARTIAL (unchanged) · but the timer half already exists, in tracked code, with install/uninstall verbs.**

| field | verified |
|---|---|
| claimed | **the verbs do not exist**; the hard half does — `objective-reminder.sh` (byte budget + `:168` loud refusal; `latest_submitted_at` at `:25-27`; backend-aware) and `fleet-schedule.py` (`--check/--status/--verify/--install/--start/--stop`) |
| **verified** | `scripts/objective-reminder.sh` (262) — claimed lines verified in substance. `scripts/fleet-schedule.py` (1841) — `:1365 def cmd_status()`, modes at `:1748`. ⛔ **`scripts/orchestrator-harness/merge-reminder.py` (3014 lines, tracked) already implements the lifecycle the row says is missing:** `:2796 --interval` (default 600), `:2797 --install-timer`, `:2798 --uninstall-timer`, `:2812 install_timer(o, interval, args.uninstall_timer)`, `:2393 def install_timer(o, interval, uninstall)` — launchd on macOS, **systemd user timer on Linux** — plus `--json`, `--dry-run`, `--act/--no-act`, and a **named skip verdict** (`EXIT: 3 = the cycle was SKIPPED — named, and never passed off as "nothing to do"`). **Also missed:** `scripts/cadence-nudge.sh` (497) + `scripts/cadence-timer.sh` (68) — the cadence machinery, with the measured band (*"in-band 1/13, worst gap 353 min"*); and an **untracked but working** `~/.pi/agent/scripts/autonomy-reminder.sh` (62) + `autonomy-reminder-loop.sh` (14) — a per-surface recurring nudge with 3 retries, a bare-`\n` send, and a log |
| tracked | ✅ the four that can ship; ⛔ `autonomy-reminder*.sh` **cannot** |
| **what it does NOT answer** | a **generic**, file-backed, settable/listable/cancellable reminder for an arbitrary message. What exists is a **specialised** one per concern (objective, cadence, merge, autonomy), each with its own timer |
| **class** | **PARTIAL** — confirmed, **delta much smaller than §5 implies**: `merge-reminder.py` is the timer-and-lifecycle implementation to wrap; the queue remains **the** write, and `merge-reminder.py`'s `state/merge-queue-alert.last` (referenced at `orchestrator-heartbeat.sh:433`) is an existing precedent for the file-backed shape |
| **already end-to-end + beat-wired?** | **YES** — `objective.py` on the heartbeat `:454`, `cadence-timer.sh` on its own launchd job, plus **47 deployed LaunchAgents** |

**V14 — `beat_checkpoint(state)` · WRAPPER + PARTIAL (bucket: WRAPPER) · the ship-block is bigger than §5 says.**

| field | verified |
|---|---|
| claimed | `cycle-record.sh`; `goal-state.py` (graph-read-only); `orchestrator-heartbeat.sh` + `BEAT-CHECKLIST.md`; `ORCHESTRATION-BOARD-<date>.md`; ⛔ `GOAL.last` removed from the wrap set |
| **verified** | `scripts/orchestrator-harness/cycle-record.sh` (226) — *"one record per controller cycle, and a verdict that refuses to call an absent or stale record healthy"*. `scripts/goal-state.py` (145) — *"QUERY the Tortoise graph … It WRITES NOTHING"*, and its header records all **three** wrong attempts, the third being `GOAL.last` → *"Still a DOCUMENT … Deleted"* — §5's removal is **correct and already implemented**. `scripts/orchestrator-heartbeat.sh` tracked. `~/.pi/agent/state/BEAT-CHECKLIST.md` present (5824 B); ⚠️ **its own title says "every beat runs ALL FIVE" and it then lists SIX rows and closes "All six run every beat"** — a doc defect inside the authority the beat obeys; worth a one-line fix, not part of this issue. ⛔ **`~/.pi/agent/state/orch-checkpoint.sh` is 86 lines and untracked — and so is its launchd binding**: `$HOME/Library/LaunchAgents/com.tortoise.orch-checkpoint.plist` is **loaded**, while `templates/launchd/` (**22 entries = 19 plists + `harness-apply` + `reaper` + `RETIRED`**) has **no `orch-checkpoint` template** |
| tracked | ⛔ **NO** for the wrap target, ⛔ **NO** for its timer |
| **what it does NOT answer** | the durable write path as one typed call; and §5's remedy (*"land `orch-checkpoint.sh` into `scripts/`"*) is **half a remedy** — see below |
| **class** | **WRAPPER** (bucket per §5.6's rule) — confirmed, with the landing work now **two** artefacts, not one |
| **already end-to-end + beat-wired?** | **YES** for the nudge (a loaded launchd job) — which is exactly why landing only the script would leave the timer unshipped |

### 5.0.2 Rows I could **not** verify — declared, not skipped

1. **§7.3's `machines:delete` scope (row 11).** `~/.pi/agent/instabox.json` exists (354 B) but was **not read**: it is a live credential, and a planning pass reading it adds nothing the claim already asserts. **Unverified, not confirmed.**
2. **The deployed MCP config.** Repo `.mcp.json` registers the `orchestrator` server (§5.8 M1). Whether the **installed** `~/.pi/agent/` config carries the same entry was **not established** — no config under `~/.pi/agent/` matched `orchestrator`. If the farm does not copy `.mcp.json`, the server ships as a file nothing loads.
3. **`spawn-gate.sh::run_agent` internals.** Read to signature (`:1840`) and to its registry calls (`:2355`, `:2472`) — **not** line-by-line through ~2900 lines. Row 7's exit ladder is verified from `nonblocking-dispatch.sh`, which is the caller.
4. **`safe-send.sh`'s print-mode coverage is a grep-negative, not an exhaustive read.** I confirmed no `pi -p`/print test in its refusal path; I did not read all 233 lines line-by-line. The claim is *"no print-mode refusal found"*, and the recommendation (put the check in `safe-send.sh`) is robust to it being wrong in the safe direction.
5. **No cloud cell was touched**, so `cmux vm exec`'s NAME-vs-LABEL behaviour (§10) remains **cited from the skill, not re-measured**. §2.2's first declared gap stands unchanged.
6. **`beta-progress.py`'s no-argv finding is a `grep`+`sed` read of `main()`**, not an AST check. It is strong (the trailer is `sys.exit(main())` and `main()` never touches `sys.argv`), but if a caller exports an env var the module honours, the row-4 correction narrows rather than reverses.

### 5.0.3 Untracked-or-stale wrappers — what would **not** ship

*A wrapped untracked module is a silent deploy failure: the PR passes CI and the fresh box gets a server whose tool raises `FileNotFoundError`.*

| wrap target | rows | state on this box | what ships it |
|---|---|---|---|
| `~/.pi/agent/scripts/fleet-report.py` | 4 (D3 keeps it out) | 200 lines, **0 tracked files** | nothing — a redeploy **deletes** its `lanes=` fix |
| `~/.pi/agent/scripts/orch-checkpoint.sh` | 14 | 86 lines, **0 tracked files** | nothing |
| `$HOME/Library/LaunchAgents/com.tortoise.orch-checkpoint.plist` | 14 | **loaded**, no `templates/launchd/` entry | nothing — the timer binding is the second half of the F3 defect, and §5 did not name it |
| `~/.pi/agent/state/lane-verdict.py` | — (named by F3, wrapped by neither) | 250 lines, **0 tracked files** | nothing — and it holds one of the five `jev-latest` pins |
| `tortoise/tools/cmux_dispatch.py` | 8 | tracked **in the product repo**, absent here | the tortoise bootstrap, not `pi-bootstrap` |
| `tortoise/tools/who-is-on.sh` + `who_is_on.py` | 6 | tracked **in the product repo** (1954 B shim + 953 lines) | same — hence D2's "port or declare `UNMEASURED`" |
| `instabox` CLI, `instabox-setup.sh`, the operating prompt, `PAT-INSTABOX.md` | 11 | **all six outside the repo**, CLI under a **pi-node** path | pi-node, not agent-infra |
| `~/.pi/agent/scripts/autonomy-reminder.sh` + `-loop.sh` | 13 | 62 + 14 lines, **0 tracked** | nothing |
| **deployed `fleet/` copy** | 1,2,5,6 | `tools/fleet/` vs `~/.pi/agent/scripts/fleet/` — **all 6 byte-identical today** (`cmp -s`) | `pi-bootstrap`'s `fleet_tools` — so **F10's drift is specific to the `.py` files it names, not to `fleet/`**, which is currently in sync |

**⚠️ F10 re-measured, because §5 rests on it:** `scripts/lane-status.py` = **2528** lines tracked. The deployed `~/.pi/agent/scripts/lane-status.py` was **not** re-measured in this pass (only `fleet/` was byte-compared). **F10 is therefore carried, not re-derived** — and the one thing this pass *can* add is that the six `fleet/` modules it might be confused with are in sync. Re-measure F10 before quoting its numbers.

---

### 5.1 Liveness (tools 1–3)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 1 | `lane_status(lane\|box\|all)` | `scripts/lane-status.py` (`lane_cpu_busy`, `child_suppresses`, `last_tool_call`, `resolve_session_ex`, 2528 lines) + `scripts/lane-actions.py::classify_row` (Step 5, JEV) + `tools/fleet/liveness.py::evaluate`/`gather` (identity, `dead`, abstentions) + `scripts/orchestrator-harness/lane-reap.sh` (**owns the three gates that make `finished` a state, but emits no per-lane output — §4.2**) | one typed answer over all four; a stable state vocabulary across them; `dead` absent from the issue's list; `reason` string not surfaced | **`liveness.py::evaluate` becomes the tree (§4.2)** — steps 2, 3, 5, 6 and `finished` are added to it, per issue §1.2; the other modules become evidence suppliers to that one function. Concretely, four inputs, each with its own output shape: `lane-status.py`, `lane-actions.py` and `liveness.py` take `--json`; **`lane-reap.sh` exposes `--json` only on `reap`, not on `count`, and that JSON is aggregate-only — no per-lane row and no lane identity — so per-lane `finished` is **NOT** read from the reaper at all — it is read from the registry's terminal record (`lane_registry.py` `DONE`/`FAILED`), and `UNMEASURED(lane-registry-saw-no-record)` applies **only** to a lane the registry never saw (§4.2, §4.3, corrected from "no per-lane source")**. `count` serves the capacity census only, its `lanes=<live>/<total> zombie=<n>` line (or `lanes=?/?` + exit 3) carried as the abstention. ⛔ Wrapping `count` as the verdict would call every lane silent past `LANE_REAP_LIVE_MIN` `finished`: that verb has no CPU gate and no ancestry gate. State mapping: the **five** states as the issue writes them, with `dead` carried in a separate `dead: true` field until the owner answers the reopen (§4.3) | **PARTIAL** — the tree's missing steps are written, then the surface is typed (§4.2) |
| 2 | `lane_tree(lane)` | `tools/fleet/lane_liveness.py::child_sids` + `enumerate_lanes(…, children)`; `scripts/orchestrator-harness/lane-artifacts.sh` (cell artifacts); `~/.pi/agent/task-sessions/<uuid>/` | **Applying the tree to the CHILD** (Step 6). `child_suppresses` only demotes the parent's verdict; `enumerate_lanes` lists child sessions but does not verdict them. Measured consequence: `state/FINDING-lane-classifier-ignores-task-children-2026-10-11.md` — **four** lanes tabulated as false `IDLE`/`WEDGED`/`STALL` verdicts (one of them marked "presumed"), plus a fifth entry under a fourth label (`WIP`), every one a lane holding or presumed to hold a `task` child | compose: `lane_status` per node (this is Step 6's own instruction) + `child_sids` for the edge set; the recursion is the tool, not a new rule | **PARTIAL** (§7.1) |
| 3 | `lane_artifact(lane)` | **words axis:** `scripts/lane-wip.py` (121 lines, tracked) — the module that answers *row 3's actual question* (*"a verdict cannot tell 'finished' from 'stopped with work left'; the LAST ASSISTANT TURN can"*); `scripts/lane-read.py` supplies only `sid_for` (pane→session id), not a payload. **files axis:** `scripts/orchestrator-harness/lane-artifacts.sh` (verbs, exit `0 found · 3 ABSENT-EVERYWHERE · 4 UNMEASURED · 5 PULL-FAILED`); `BEAT-CHECKLIST.md`'s `## LANE-DONE <verdict> <ts>` line | one answer over *both* axes: a session lane's words AND a **cell** lane's file (the 2026-11-01 measurement: four mandated artifacts existed, each on a different box, none reachable from the mac); size/age/terminal-line in one shape. ⛔ **And `lane-wip.py` has no `--json` and no exit contract** — it prints prose and exits only `0`/`2` — so a machine-readable words axis does not exist yet | wrap `lane-wip.py` for words (**adding `--json` + a stated exit contract — that IS the write**) and `lane-artifacts.sh` for files; read the `## LANE-DONE` line as the terminal verdict; "none written" is a value, not an error | ⛔ **PARTIAL** — corrected from `WRAPPER`: the wrap target was chosen because it answers the question, **not** because it already has a payload. `lane-wip.py --json` + an exit contract is part of the write surface (§5.0 V3) |

### 5.2 Census and PR surface (tools 4–6)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| ⛔ | **Row 4 corrected — see [§5.0 V4](#50-verified-existence-map-phase-15--every-row-opened-and-checked).** `beta-progress.py` parses **no argv** and hardcodes `REPO = "daniel-ospina/tortoise"` (`:35`), so there is no `--json` and no repo parameter; and `capacity.sh`'s `fleet`/`publish` verbs (the fleet-wide `refs/capacity/*` channel, `:1129`/`:1270`) were missed. **Class WRAPPER → PARTIAL.** | | | | ⛔ |
| 4 | `fleet_census(repos)` | `scripts/beta-progress.py::compute`/`main` (P0/P1 open·with-PR·NONE, age printed, cache validator, `DELIVERY [as of …]` line); `scripts/orchestrator-harness/capacity.sh probe` (measured placement: refuses to ADD work at `CAP_LPC_CEILING` = **8.00 load-per-CPU**, `>=`, which is a placement gate and NOT the platform's tolerance — see [§10.1](#101-the-two-capacity-calibrations--the-trap-that-would-call-a-dying-mac-healthy)); `scripts/orchestrator-harness/box-status.sh` (**six** machine-parsable lines on exit 0: `harness:`, `stamp:`/`pin:`, `ref:`, `controller:`, `running:`, `roles:` — `ref:` is `UNRESOLVED(…)` or absent when it exits **2**); `tools/fleet/fleet-health.py`; `scripts/fleet-schedule.py --status`; `BEAT-CHECKLIST.md` checks 1-3 | one typed object per box+repo; **`fleet-report.py` is untracked (F3)** and its §3 "merged" is a keyword mention (F4); no `measured_at` field (the text line has one, the bytes do not) | wrap `beta-progress.py` with a **repo parameter and `--json`** (that pair IS the write — the module parses no argv today), + `capacity.sh probe`/`fleet` (M16) + `box-status.sh` (M2's `lib/fleet-inventory.sh` is the box/`all` half); every figure carries `value`, `measured_at`, `age_ms`, `source`. ⛔ **`fleet-report.py` is NOT a dependency and NOT this row's landing work** — landing it is an **F3 prerequisite** (§5.0.3), tracked separately; D3 stands | ⛔ **PARTIAL** — corrected from `WRAPPER` in Phase 1.5 (§5.0 V4); the §7 justification this row was missing is [§7.7](#77-fleet_census-4--partial-the-write-is-the-repo-parameter-and-the-typed-payload) |
| 5 | `pr_queue(repo)` | `tools/fleet/pr_state.py` — `action_for`, `row_action`, `fidelity`, `inherited_reds`, `verdict`; rows `CLOSE-STALE`/`WAIT:draft`/`REPAIR-CONFLICT`/`FIX-RED`/`RERUN-FLAKE`/`WAIT:inherited-red`/`REVIEW`/`WAIT:attested-elsewhere`/`WAIT:owes-review`/`WAIT:diff-unreadable`/`WAIT:in-flight`/`WAIT:no-check-surface`/`WAIT:mergeable-unknown`/`WAIT:authority-unreadable`/`LAND`; exit **2 = the pass could not be made** | the issue's vocabulary is coarser (`CONFLICT`/`STALE-ATTESTATION`/`NO-ATTESTATION`/`READY`/`INHERITED-RED`/`DRAFT`); **closing issues** are not attached to a row; `--json` exists but there is no MCP-typed shape with a `measured_at` | wrap `pr_state.py --json` (never `fleet-report.py::classify` — D1); map its 15 actions onto the issue's 6 classes **lossily in one direction only** (the 6 are a view; the 15 remain the answer); join closing issues per row | **WRAPPER** |
| 6 | `claim_check(issue, repo)` | **registry axis:** `tools/fleet/claim_lanes.py` (`read_registry`, `read_pull`, `read_snapshot`, `parse_key`, `parse_owner`, `parse_lease`, `to_evidence`) + `tools/fleet/liveness.py::claim_verdict` + `CLAIM_REASONS` (6 named abstentions) + `scripts/orchestrator-harness/claims.sh`. **local-checkout axis:** `tortoise/tools/who-is-on.sh` (tracked, 1954 B — `0` complete answer, `2` a surface could not be read) — a **3-line body** (35 lines with its header) that `exec`s `who_is_on.py` (953 lines), which imports `collision_preflight` (9132 lines) for its git enumeration | one answer across both axes; the registry axis answers "does a claim exist for this issue/head", the local axis answers "is work in flight on this disk". Today they are two tools in two repos and neither names the gap | wrap `claim_lanes.py` for the registry axis (`--json` + exit 3 = nothing established, never freedom) and **port the local axis** — which is **three files, not one**: `who-is-on.sh` + `who_is_on.py` + a declared decision on its `collision_preflight` import (port the gate, or keep the local axis `UNMEASURED(<why>)` rather than a second enumerator). Carry `ClaimRead.readable` and `siblings` into the payload so an absent key can never read as "free" | **WRAPPER** (two axes, both existing) |

### 5.2b `claim.check` answers TWO questions, not one (owner delta, #3382 comment 6662755371)

| field | source | contract |
|---|---|---|
| `claimed` | `refs/claims/issue-N` via `claim_lanes.py` | abstention vocabulary only — a declared OWNERSHIP window, never evidence a process is alive |
| `saved` | **`refs/wip/<slug>`**, read live via `git ls-remote` + `git fetch` | `ref`, `age`, `file_count` per match · **`UNMEASURED(<cmd> + <error>)` when the read fails**, never `none` |

**Why it exists.** 226 snapshots of half-finished work sat on origin under `refs/wip/*` with nothing
pointing at them (measured 2026-11-05; the figure was 222 when the owner raised it). An agent asking
"is this claimed?" was told `free` while a snapshot of the same work existed — which is how one task got
done twice across six worktrees. `claim.check` now reports both axes in one answer.

**Boundaries, both deliberate:**
- **It reads; it never saves.** `scripts/bg-rescue-wip.sh` is the actuator. No tool in this surface writes
  `refs/wip/*` — this is a lookup over work that already exists (#3489's sibling, kept separate).
- **It does not enforce.** A lookup an agent can skip is not a check; the requirement-to-check belongs to
  the brief gate, not here.

**Matching is a heuristic and the payload says so.** The slug is derived from the *branch*
(`refs/wip/mcp-3382-phase2`), not the issue, so a match is a hyphen-delimited slug token equal to the issue
number — `ai-3194` matches 3194, `ai-31940` does not. `match_rule` travels with every payload.

**`none` is never "no work was in progress".** A snapshot exists only when the agent exited normally; an OOM
kill or a reclaimed cell saves nothing (`cloud-cell-quiesce.sh` has no save step). Every payload carries
`save_coverage: normal-exit-only` and a `none_means` sentence, so the absence cannot be read as evidence.

Two tests, each named for the failure it prevents: a snapshot named for the issue is found (and a
near-miss slug is not), and an unreadable registry answers `UNMEASURED` rather than `none`.

### 5.3 Actuation (tools 7–9)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 7 | `lane_dispatch(box, repo, name, brief, env)` | `scripts/orchestrator-harness/nonblocking-dispatch.sh` (**typed exits: 2 = caller bug, 78 = validator stale/absent, 80 = brief-gate refused**); `lane.sh` (+ teardown trap); `lane-exec.sh` (launch so no wrapper survives — #2163); `spawn-gate.sh::run_agent` (load gate, watchdog, walltime row); `brief-gate.sh` (exit 80); `tools/fleet/dispatch_preflight.py` (refuse a dispatch with nothing to land); `tools/fleet/successor_preflight.py` (prove a predecessor is gone); `branch-claim.sh` / `branch-claim-hook.sh` (`refs/claims/branch-<slug>`, single-owner) | `env` into the agent's **process** environment (`cmux new-workspace --env KEY=VALUE` — an export inside a tool call does not reach the gates); `pid/log/worktree` in one typed reply; the two measured silent-actuator failures as **typed refusals** (`no-pid`, `branch-exists`) instead of stderr the caller must parse. ⛔ **The refusals are a MAPPING onto the EXISTING vocabulary, not a new one.** The order lives in `skills/cmux-cells` **§2** ("brief admission answers first, then the capacity refusals in this order (fork → disk → load)"), with **§5** owning the dispatch shape — not the reverse. The existing codes: **80** brief refusal (`AGENT_BRIEF_REFUSED`, before fork and before any disk/load read), **73** fork, **77** disk headroom, **75** load, **74** land backlog, **76**, **78** cannot-verify, and **72** `REPO_TARGET_REFUSED`. Phase 2 adds only the two that have no code today (`no-pid`, `branch-exists`) and must not collapse 73 ("does NOT clear by waiting") into 75 (load). And **`box-unreachable` is not synthesised from a timeout** (skill §3): the tool returns the channel read that answered, plus the ladder step it reached | subprocess the launcher, map exit 2/78/80 + the two extra codes to typed refusals; read `pid` from the `.pid` file, never from the launcher's own stdout (the `launcher did not report a pid: ''` failure); pre-check `refs/claims/branch-<slug>` and the local branch/remote ref for `branch-exists` | **WRAPPER + PARTIAL** (`env`, typed refusals are the added surface — §7.2) |
| 8 | `lane_message(lane, text)` | `tortoise/tools/cmux_dispatch.py` — **exit 0 = consumed, 1 = sent-but-not-consumed / never-became-ready, 2 = usage error, 3 = cmux transport error, 4 = queued (DELIVERED, not consumed)**; its own header states *"A transport failure (exit 3) is NOT a consumption failure (exit 1)"*; `scripts/objective-reminder.sh` (byte budget, `latest_submitted_at` turn-boundary confirmation, backend-aware cmux-vs-tmux) | MCP-typed delivery semantics over a *lane*, the `\n` discipline as a parameter, and — **materially** — the refusal of an unsteerable lane: a lane launched with `pi -p` does not read stdin, so a message to it types text nothing consumes (skill §5, measured `order-seen=0` on 9 lanes; F13). Today nothing stops a caller doing it | wrap `cmux_dispatch.py`, preserving **all five** exits as distinct typed results — collapsing 3 into 1 would report a refused socket as a message that failed to land. ⛔ **FALSIFIED in Phase 1.5 (§5.0 V8):** `scripts/safe-send.sh` (**tracked, 233 lines**) already wraps all five exits as typed ones (`:38` — `0 sent+consumed · 3 REFUSED · 78/80 brief gate`), runs `brief-gate.sh`, and refuses an unreadable pane; `scripts/orch-send.sh` (263) refuses a foreign/unknown pane by POSITIVE match. **And this row's claimed wrap target is in the product repo**, so it carried F7's ship-blocking flaw uncorrected. The one real gap is the `pi -p` precondition (F13), and it belongs in `safe-send.sh` | ⛔ **ALREADY-SERVED → DELETE** |
| 9 | `box_exec(box, cmd)` | `cmux vm exec --timeout` (the transport `lane-artifacts.sh` already pulls over); `cloud-cell-doctor.sh`; `scripts/orchestrator-harness/box-status.sh` | a typed `{rc, stdout, timed_out, truncated}` — today every caller re-invents truncation and timeout handling; ⛔ **and the distinction skill §3 makes**: `timed_out` is a CHANNEL fact, never a box verdict (a disk-full guest answers `running` while every `exec` times out). The tool must not turn a timeout into `box-unreachable` | thin wrapper over the transport; **truncate explicitly and say so** — the fleet's own doctrine is that a capped read which NAMES its cap is usable evidence while a silent one is a lower bound published as the fleet (`scripts/lane-actions.py::_SAMPLED_NOTE`); never infer a lane count from a process-name pattern | **WRAPPER** (external CLI verb — §7.4) |

### 5.4 Verification and closure (tools 10–12)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 10 | `review_record(pr)` | `scripts/record-review.sh --check-carry` (**positional** `<pr> [owner/repo]`; `--repo` exits 2); one tab-separated line `<verdict>\t<record digest\|->\t<live digest\|status>`; its full verdict set is **`head` (0) / `carry` (0) / `carry-patch` (6) / `fresh` (1) / `unreadable` (3) / `norecord` (4) / `nodigest` (5)** plus the three surfaces added by #3440: **`red-surface` (7, the head that would MERGE is red and the PR caused it — NOT mergeable) / `red-base-owned` (0, red but every group reproduces on the base — the record still covers the artifact, and the groups are named) / `surface-unknown` (8, the surface could not be read — RETRY)**; `--print-diff-hash` (read-only seam `pr_state.py` already uses) | a typed `{current \| stale \| absent}` + **the head the record is bound to** in one reply; ten verdicts, each with its own named target — including the three #3440 surface verdicts (`red-surface`→not-mergeable, `surface-unknown`→retry, `red-base-owned`→covered-with-named-red-groups), with `red-surface`/`surface-unknown` never folding into `current` — and without losing `carry-patch` (RE-RECORD, not a review cycle) or `unreadable` (RETRY, not re-review) | wrap `record-review.sh --check-carry` positionally **as step 1/4 of skill §6's five-step contract** (diff hash → ONE fresh review → verdict comment → record `--evidence` → rail), never as a substitute for the review; map `head`→current; `carry`/`carry-patch`→stale-with-head; `norecord`→absent; `fresh`/`unreadable`/`nodigest` keep their own names (they are three different next actions); `red-surface`→not-mergeable and `surface-unknown`→retry (neither ever reaches `current`), `red-base-owned`→`current` annotated with the named base-owned red groups and never reported as green — the exit-0 surface verdict is on the COVERED side (the record still covers what would merge), so it must not be mapped onto the carry axis. **Pass the repo positionally** (the `--repo` refusal is documented) | **WRAPPER** |
| 11 | `verify_independent(repo, ref)` | `~/.local/share/pi-node/current/bin/instabox` (the CLI, v0.8.125) + `~/.pi/agent/instabox-setup.sh` (toolchain + health check) + `~/.pi/agent/state/INSTABOX-OPERATING-PROMPT.md` (**the documented procedure**: create/start/stop/exec/rm, the `--setup-file` trap, budget, kill-switch) + `~/.pi/agent/state/PAT-INSTABOX.md` (the falsifiable protocol: `SCOPE(...)`, negative write test, `INSTALLED(mode,path)`, `PROVEN(before,after)`). `scripts/scratch-worktree.sh` and the `verifier` agent are the same-box answers and are **not** substitutes | the **typed surface**: `{rc, stdout, timed_out, truncated}`, a stable tool name, and a teardown that is *guaranteed* rather than remembered — plus the standing rule the operating prompt already states (`never change runs-on:`) in a form the tool cannot violate | wrap the CLI and the operating prompt: create → clone at `ref` → run the lane's own steps → post evidence → **stop in a `finally`**; refuse any command the prompt forbids; `INSTALLED`/`PROVEN` lines read from `PAT-INSTABOX.md`'s protocol rather than invented | **PARTIAL** (§7.3) — corrected twice from `NEW`, see F8 |
| 12 | `closure_audit(pr)` | `gh`'s `closingIssuesReferences` — **already consumed by `scripts/review-pr.sh:501`** (`gh pr view … --json closingIssuesReferences`) and adapted by the `scripts/orchestrator-harness/gh-rest/gh` shim as the GraphQL-only field; `scripts/beta-progress.py::compute`'s `covered()` (open-or-merged PR naming the issue, boundary-exact); `scripts/orchestrator-harness/merged-not-closed.sh`; `tools/fleet/outcome_canary.py` | "what did this merge ACTUALLY close" as a typed fact, and **prose-keyword false closes** — the census counts a `#N` mention in a title/body/branch as merged (F4). No existing tool **compares** the closing references against the prose mentions against the issue's own live `state`. ⛔ **And ancestry is not available**: the rail defaults to **squash** (skill §6.5), so a batched PR's constituents stay **open** — a closure audit that asked "is this commit an ancestor of main" would report a false *not merged* for every batched PR | wrap `gh api` `closingIssuesReferences` + re-read each issue's `state`; name `review-pr.sh:501` as the existing consumer of the field rather than claiming it is unused; emit the closed/mentioned/still-open triple. ⛔ **Corrected (§5.0 V12):** `outcome_canary.py` is **not a closure source** — it asserts fleet OUTCOMES and contains no closure check; the real prior art is **`merged-not-closed.sh --json`** (typed payload, exit 0-ran / 2-unqueried, and its own rule *"a hit is a queue entry, not a verdict"*), which answers the merged→open direction end to end | **PARTIAL** (§7.5) — the field is consumed, the **comparison** is not written; §5.0 V12's `PARTIAL→WRAPPER` arrow is a note about *what it wraps* (`gh`, an external verb), **not** a reclassification — §5.6 counts row 12 `PARTIAL` and before this correction the two cells disagreed |

### 5.5 Durability (tools 13–14)

| # | Tool | Existing implementation (file + function) | What it does NOT answer today | Wrapper plan | Class |
|---|---|---|---|---|---|
| 13 | `reminder_set` / `reminder_list` / `reminder_cancel` | **the verbs do not exist.** The *hard* half does: `scripts/objective-reminder.sh` (byte budget with a LOUD refusal over budget at `:168`; delivery confirmed by `latest_submitted_at` advancing, explicitly *not* by the send's exit status, `:25-27`; backend-aware cmux-vs-tmux; plus its `.test.sh`) and `scripts/fleet-schedule.py` (`--check`/`--status`/`--verify`/`--install`/`--start`/`--stop`, plist-parsed, portable to cells without launchd) | a **settable, listable, cancellable** reminder that survives a session restart, with the owner-confirmed server-owned queue + timer | wrap `objective-reminder.sh` for the delivery contract and `fleet-schedule.py` for the timer; the queue is a **file** under `$HOME/.pi/agent/state/` (as `beta-progress.json`, `NEEDS-ACTION.md` already are) because a server-owned queue that lives only in server memory dies with the server — and "survives session restart" is the requirement. ⛔ **Corrected (§5.0 V13):** the timer half is **already implemented in tracked code** — `merge-reminder.py` (3014 lines) has `--install-timer/--uninstall-timer/--interval` (`:2796-2798`, `:2393`), launchd **and** systemd, `--json`, and a **named skip verdict** (exit 3). `cadence-nudge.sh`/`cadence-timer.sh` are the cadence machinery, and an untracked `autonomy-reminder.sh` is a working per-surface reminder. Only a **generic** file-backed queue is missing | **PARTIAL** (§7.6) |
| ⛔ | **Row 14 corrected — see [§5.0 V14](#50-verified-existence-map-phase-15--every-row-opened-and-checked).** The **launchd binding is untracked too**: `com.tortoise.orch-checkpoint.plist` is loaded on this box and `templates/launchd/` has no `orch-checkpoint` template, so landing the script alone leaves the timer unshipped. | | | | ⛔ |
| 14 | `beat_checkpoint(state)` | `scripts/orchestrator-harness/cycle-record.sh`; `scripts/goal-state.py` (queries the graph, writes nothing); `scripts/orchestrator-heartbeat.sh` + `BEAT-CHECKLIST.md` (the six checks and their order); `~/.pi/agent/state/ORCHESTRATION-BOARD-<date>.md` (the board AGENTS.md mandates) | the durable write path as one typed call; `orch-checkpoint.sh` (the 20-min nudge) is **untracked** (F3); `goal-state.py` is graph-read-only by design and must stay so | wrap the board/heartbeat artifacts; **land `orch-checkpoint.sh` into `scripts/`**; the graph axis stays the Tortoise MCP (D5). ⛔ **`GOAL.last` is removed from the wrap set** (the issue's table names it): it does not exist on this box, and `scripts/goal-state.py` records why — the goal map was moved INTO the graph, so a file is the one thing that must not come back | **WRAPPER + PARTIAL** |

### 5.6 Counts

| class | tools |
|---|---|
| **WRAPPER** (existing implementation answers it) | 5, 6, 9, 10, 14 (5 tools) |
| **PARTIAL** (existing implementation answers part) | 1, 2, 3, 4, 7, 11, 12, 13 (8 tools) |
| **NEW** (nothing answers it) | **none** |
| **ALREADY-SERVED → DELETE** (an existing script answers it end to end) | 8 (1 tool) |

**⛔ Corrected in Phase 1.5 from `8 / 6 / 0 / 1` to `5 / 8 / 0 / 1`.** Three rows moved, each on file evidence rather than judgement:
**#4 WRAPPER → PARTIAL** because the module it claims to wrap (`beta-progress.py`) takes **no arguments at all** and hardcodes one repo, so `fleet_census(repos)`'s own signature is a write;
**#3 WRAPPER → PARTIAL** because its amended wrap target (`lane-wip.py`) answers the question but has **no `--json` and no exit contract**, so the payload is a write (§5.0 V3); and
**#8 WRAPPER → ALREADY-SERVED** because `scripts/safe-send.sh` (tracked, 233 lines) already types the `cmux_dispatch.py` exits, runs the brief gate and refuses an unreadable pane — while the row's claimed wrap target is in the **product repo**, so it could never have shipped from here. ⚠️ **"all five exits" is too strong and is corrected in §5.0 V8** — safe-send collapses `2` and `4` into one unknown bucket; the deletion stands on tracked-ness and its stricter preconditions, not on a claim it does not honour.

**How a compound label resolves, stated because three rows carry one.** A row gets **one** bucket, by
this rule: *the class of the nearest existing implementation it wraps.* Row 1 counts PARTIAL because §4.2 asks it to **write** tree steps 2/3/5/6 and a `finished` state, not to relocate them; row 3 counts PARTIAL because the module that answers its question (`lane-wip.py`) has no payload; row 4 counts PARTIAL because `beta-progress.py` takes no argv; row 7 (`WRAPPER + PARTIAL`)
counts PARTIAL for the same reason — the `env` argument and the typed refusals have no implementation at all; row 14
(`WRAPPER + PARTIAL`) counts WRAPPER because every element of its answer exists in **tracked** code and only the
`orch-checkpoint.sh` landing is missing — a *deployment* gap, not a missing capability; row 12
(`PARTIAL→WRAPPER`) counts PARTIAL because the field is consumed but the comparison is not written.
Applying the rule the other way is what makes the partition meaningful: a `PARTIAL` here means "someone
must write something", never "something must be relocated".

**`NEW` rows: 0 — verified row by row, not asserted.** Every one of the 14 tools wraps something that exists.

**`ALREADY-SERVED` rows: 1 (#8).** It is not a `NEW` row and it is not a wrapper either: the typed surface
it asks for exists, in this repo, with a stricter contract than the one the row specifies. Deleting it is
the issue's own rule (§6) applied in the direction it was written for, and the *finding* F13 is not
discarded with it — the print-mode refusal it demands moves into `safe-send.sh`, where the other four
refusals already live (§5.0 V8).
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
| 5 | `pr_queue` | **§6** (the landing contract) + **§6.5** (`--check-carry` verdicts) | which verdict a PR is in. The `--check-carry` verdicts and their next actions are skill §6.5's (ten as of #3440 — the three surface verdicts must be mapped too, and `red-surface`/`surface-unknown` must never fold into "current"). ⛔ **`pr_state.py` does NOT consume them** — it carries its own four-state predicate, `fidelity()` (`at-head`/`carried`/`owes-review`/`diff-unreadable`) over `--print-diff-hash`, and it **disagrees with `--check-carry` on exactly the two cases skill §6.5 calls the expensive mistakes**: a record with no usable digest is `owes-review` to `pr_state.py` but `nodigest` (a CARRY) to `--check-carry`; a byte-identical patch on a moved diff is `owes-review` to `pr_state.py` but `carry-patch` (re-record, no review cycle) to `--check-carry`. See **D9** — the server must not answer one PR with two different verdicts |
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

## 5.8 Missed existing work — what the inventory did not find

**This is the point of the Phase-1.5 pass.** The issue names the risk as *"reinventing the wheel"*, and the
inventory's §5 was written from a research pass over directories that were largely named by the issue itself.
A search over the **full tracked module list** (not the issue's list) plus the **deployed-but-untracked**
population plus the **loaded launchd jobs** found **20** pieces of existing work that bear on a tool row
(19 that change a row's content or class — M1–M19 — and one that changes *how* a tool should be written, M20). Each one is given the same fields as §5.0: what it answers, whether it is tracked, whether a beat already
calls it, and **which row it changes**.

### 5.8.1 The one that changes the whole shape of Phase 2

**M1 — ⛔ the orchestrator MCP server already exists, is registered, and ships two tools.**

| field | verified |
|---|---|
| path | `mcp-servers/orchestrator/server.py` — **335 lines**, tracked; `mcp-servers/orchestrator/test_server.py` — **342 lines**, tracked |
| what it answers | `lane.list` / `lane.show` over `refs/lanes/*`: **RUNNING / DONE / FAILED / EXPIRED**, with `EXPIRED` derived from the lease |
| **tracked?** | ✅ — committed under this lane's own Phase-2 start (`bb093a0ac`, `fa3e83bd5`, `2577715cd`) |
| **already wired?** | ⛔ **REGISTERED IN `.mcp.json`** as the `orchestrator` server (`"lazy": true`, purpose *"Lane STATE records … Read-only"*, `whenToLoad` *"whenever the question is 'did this lane finish?'"*). So this is not a proposal — it is a live MCP surface |
| the transport decision, already taken | stdio JSON-RPC 2.0, **zero third-party packages** (*"a server that cannot start on a bare cell is an outage wearing a tool's name"*), `initialize · notifications/initialized · tools/list · tools/call · ping` |
| the read-only decision | ⛔ **IT CHANGED IN PHASE 2, AND THE OLD ROW WAS LEFT ASSERTING THE OPPOSITE.** It said *"both tools are reads, the server never writes a record, and there is no flag that makes it"* — true of the 2-tool slice, FALSE of the 12-name surface: `lane.dispatch`, `box.exec`, `fleet.reminder` and `fleet.beat_checkpoint write` mutate, and the mode is a real switch. What holds today: the server defaults to read-WRITE (the surface is useless otherwise), and `--read-only` / `ORCH_MCP_READ_ONLY=1` refuses **every** mutating tool with a typed `refused: "read-only"` — pinned by `test_T_read_only_mode_refuses_every_mutating_tool`. ⛔ §13 Q5's *recommendation* ("read-only unless a mutation flag is set") is therefore **still open**: the switch exists, the default is the opposite of the recommendation |
| **what changes** | ⛔ **Phase 2's deliverable is not "14 tools in one PR"; it is "10 new MCP names plus an EXTENSION of the two already-shipped ones"** (11 tools, 12 names — §5.9) — and #1 `lane_status` must be expressed as a **delta on `lane.list`/`lane.show`**, not as a new name for the same read. §5's own headline (*"Every other tool in this inventory is still unimplemented"*) remains true; what is false is the framing that Phase 2 starts from nothing |
| invariant-5 note | `Registry.__init__` already computes and reports `registry_sha256` per payload and on `initialize`; the missing half is the **start gate**, not the hasher (§11) |

### 5.8.2 Work that changes a row's class or its wrap target

**M2 — `scripts/lib/fleet-inventory.sh` (1817 lines, tracked): the fleet's declared process inventory.**
The "ONE table that says whether each of them is alive", written on an explicit owner requirement (*"one
script that runs every fleet process and also CHECKS they are all alive — so we get neither broken duplication
nor a component that is silently off, missing, or running twice"*). Rows per component — controller,
watchdog, heartbeat loop, cadence timer, launchd jobs, pr-doctor, objective reminder, reaper, cell supervisor,
**landers**, ai-drainer, **second controller** — via `fleet_row_*` functions (`:470`, `:685`, `:767`, `:964`,
`:987`, `:1044`, `:1069`, `:1136`, `:1175`, `:1224`, `:1253`). **Callers: `orchestrator-heartbeat.sh`,
`heartbeat-loop.sh`, `lane-actions.py`, `objective-reminder.sh`, `fleet-health.py`, `watchdog-loop.sh`.**
**Changes rows 1 and 4** — it is the `box|all` axis of `lane_status` and the health half of `fleet_census`, and
it already answers *"is the harness running"* with a fail-closed verdict. Not named anywhere in §5.

**M3 — `scripts/safe-send.sh` (233 lines, tracked): the typed delivery wrapper.** Exit line `:38`
(`0 sent+consumed · 3 REFUSED · 78/80 brief gate`), maps all five `cmux_dispatch.py` exits, runs
`brief-gate.sh` before sending (`:86-92`), refuses an unreadable pane (`:154`) and a busy one (`:186`).
**This falsifies row 8's class** — see §5.0 V8.

**M4 — `scripts/orch-send.sh` (263 lines, tracked): the positive-match pane guard.** *"the ONLY safe way to
dispatch a lane order from the orchestrator"* — four measured incidents in one night (a wrong-product lane,
the orchestrator itself, a UUID that does not exist, and a **negative guard that failed open** on an empty
footer). Refuses on a POSITIVE match of a known-good repo path; an unreadable pane is refused. **Row 8.**

**M5 — `scripts/merge-queue.py` (377 lines, tracked): the queue verdict.** Turns *"173 open PRs, 8 merged
today"* into a drain verdict and names the constraint; called at `orchestrator-heartbeat.sh:411-425` and
imported by `objective.py`/`beta-progress.py`. **Row 5** — this is the pipeline half of `pr_queue` the
inventory assigned to `pr_state.py` alone.

**M6 — `scripts/objective.py` (4029 lines, tracked): the objective/indicator/target line.** Heartbeat `:454`.
**Rows 4 and 14** — the beat's own one-line state, and the precedent for "indicators carry no pass/fail".

**M7 — `scripts/orchestrator-harness/pr-state.sh` (72 lines, tracked): the router seam.** `prstate_row
<owner/repo> <pr>` → `ACTION<TAB>rerun_run<TAB>reason` (rc 0), `unavailable<TAB>-<TAB>why` (rc 2). Already
consumed by `admin-merge.sh`, `pr-doctor.py`, `refresh-candidates.sh`, `pr-sickness.sh`, `lane-merge.sh`.
**Row 5** — and it is the **shape** an MCP tool should copy, because it already solves "don't make the actor
parse the JSON" and "an unresolved router is a named absence, never an empty row".

**M8 — `scripts/orchestrator-harness/merge-reminder.py` (3014 lines, tracked): the reminder lifecycle, with a
timer.** `--install-timer [--interval S]` / `--uninstall-timer` (`:2796-2798`, `:2393`), launchd on macOS and
a **systemd user timer** on Linux, `--json`, `--dry-run`, `--act/--no-act`, and a **named skip verdict** (exit
3 — *"never passed off as 'nothing to do'"*). **Row 13** — the row says *"the verbs do not exist"*; the
*install/uninstall timer* verbs do, and this file is the implementation to wrap instead of `fleet-schedule.py`.

**M9 — `scripts/cadence-nudge.sh` (497) + `scripts/cadence-timer.sh` (68): the cadence machinery.** The
message cadence is decoupled from the pass cadence on purpose, with the measured band (in-band **1/13**, worst
gap **353 min**) and its own rate-limit off a log. **Row 13.**

**M10 — `~/.pi/agent/scripts/autonomy-reminder.sh` (62) + `autonomy-reminder-loop.sh` (14): an untracked but
working per-surface reminder.** 3 retries 20 s apart, `--paste` + a bare `\n`, a SKIP/FAILED/SENT log line per
attempt, and the measured reason the retry exists (*"the RunAtLoad send failed exactly this way"*). **Row 13** —
and it is **untracked**, so it is both a wrap-target candidate and a deployment liability.

**M11 — `scripts/child-check.py` (104) + `scripts/lane-watchdog.py` (825) + `scripts/tree-cpu.py` (124): the
child/tree signals.** `child-check.py` is *"the three-signal read on `task` children. REPORTS; never kills"*;
`lane-watchdog.py` holds the three all-required gates and the measured 2h28m frozen-dispatch case; `tree-cpu.py`
separates *own-CPU-flat / descendants working* from a real park. **Row 2** — the recursion's evidence suppliers
that §5 never names.

**M12 — `scripts/orchestrator-harness/live-ownership.sh` (422): live-process PR ownership.** Encodes the owner
rule as code (*"owned means a LIVE PROCESS is working that PR — not 'someone intended to', and not 'a registry
says so'"*), with the measured 25-open-PRs / 0-owned / 25-un-owned state. **Rows 5, 6 and 7** — a **third**
ownership axis beside ref-claims and the local checkout, and the input a `pr_queue` needs to say who is on it.

**M13 — `scripts/orchestrator-harness/provision-lane-registry.py` (743) + tortoise's `tools/fleet_state.py`
(`load_registry` `:902`, `REGISTRY = STATE_DIR / "lane-registry.tsv"` `:223`).** The box's lane roster, which is
the **fleet-board holder surface** `collision_preflight.py:5693 def _board_can_answer(state)` gates on —
and `provision-lane-registry.py` exists because a box that never ran the retired dispatcher reported
`measured=False` and so refused **every** candidate. **Row 6** — §5's F7b counts *three* claim implementations;
this is a fourth and a fifth (§5.0 V6).

**M14 — `scripts/lib/bounded.sh` (189): the ONE bounded-execution home.** `timeout` -> `gtimeout` -> an
internal watchdog with a sentinel file, written because **macOS has no `timeout(1)`** and every class of
`disk-reaper.sh` died rc=127 while the pass still printed `verdict=fail-closed`. **Row 9** — `box_exec` must
call this, not write a fourth timeout, and `watch-truncation.sh` is the truncation-side prior art.

**M15 — `scripts/orchestrator-harness/merged-not-closed.sh` (249): the closed-direction closure answer.**
`--json` → `{repo, hits[{issue,title,priority,prs[{pr,merged_at}]}], unqueried[]}`, `exit 0 = ran (an empty
result is a real answer) / 2 = a surface could not be queried — never 1`, and its own stated limit (*"a hit is a
queue entry, not a verdict … never wired to an automatic close"*). **Row 12** — the real prior art, replacing
`outcome_canary.py` (§5.0 V12).

**M16 — `scripts/orchestrator-harness/capacity.sh`'s `fleet` and `publish` verbs** (`cap_read_fleet()`
`:1129`, `cap_publish()` `:1270`): the **fleet-wide** capacity channel over `refs/capacity/*`, with a
per-box authorship ledger and a named UNREADABLE refusal (*"the fleet channel is UNREADABLE"*, rc 2). **Row 4**
— §5 names only `probe`, which is the *placement* gate, and so described the capacity surface as smaller than
it is.

**M17 — `scripts/registry-sync.sh` (1089): review-record replication across boxes.** `pull` / `push` / `union`
/ `status`, exit `3` = *"CONVERGED WITH DIVERGENCE"* and `4` = records that could not be read. **Row 10** — a
record may have been minted on another box, so a local `norecord` is not "no record anywhere".

**M18 — `scripts/orchestrator-harness/report.sh` (309) + `scripts/lib/beat-pair.sh` (63) + `scripts/lane-scan-fallback.sh` (120).**
`report.sh` reads ONLY durable artifacts and is safe to run while the loop works (the `beat_checkpoint` read
path); `beat-pair.sh` is the recap/beat **pair** rule in one place, with the reason it must be shared (*"two
INDEPENDENT atomic writes … a FRESH recap beside a STALE beat … and the beat is the half that gets
published"*); `lane-scan-fallback.sh` refreshes what the tick produces when the tick is killed before reaching
it. **Row 14** — all three are the durability contract `beat_checkpoint` must not re-invent.

**M19 — the lane state registry** (`scripts/orchestrator-harness/lane_registry.py`, 1271 lines; `provision-lane-registry.py`,
743). Four states, `EXPIRED` derived, written by the launcher. **Rows 1, 2, 6 and 14** — the per-lane terminal record,
which §4.2 declared non-existent (§5.0 V1) and which is already behind an MCP tool (M1).

### 5.8.3 Prior art that changes *how* a tool should be written, not *what* it does

**M20 — `scripts/orchestrator-harness/landing/` (`bulk.py`, `landability.py`, `rail-bg.sh`) and
`scripts/lane-guard.py` (242).** `lane-guard.py` is the **inverse-polarity** bracket: not *"is the verdict
DONE-IDLE"* (a stale sample) but *"is there POSITIVE evidence that nothing is in flight"*, lane-local and
re-runnable because the bulk classifier measured **88 s** for 27 lanes. That is the shape any `lane_status`
used as a dispatch precondition needs, and §5's row 1 does not mention it.

**A short list of what was checked and found to be already accounted for**, so the next pass does not
re-audit it: `harness-provenance.sh` and `check-deployed-drift.sh --surface` (F9, correct); `goal-state.py`'s
`GOAL.last` removal (correct and already implemented); `record-review.sh`'s seven verdicts and three-field
line (exact); `lane-artifacts.sh`'s five exits (exact); `nonblocking-dispatch.sh`'s 2/78/80 (exact);
`beta-progress.py`'s age clamp and cache re-validation (F-repaired, matches §9 #3); `box-status.sh`'s six
emitted lines (§5 correct; its own header is the thing that is out of date).

---

## 5.9 The smallest correct implementation set — 11 tools, not 14

**The rule applied:** a tool earns its place only if it adds a **typed value an existing script does not
already produce**, and it must be expressible as a delta rather than a re-implementation.

| action | rows | why |
|---|---|---|
| **DROP** | **8** `lane_message` | `ALREADY-SERVED` (§5.0 V8). `safe-send.sh` + `orch-send.sh` already deliver the typed contract, in-repo, with a stricter guard than the proposed wrapper. **Carry F13 forward as a ~15-line refusal inside `safe-send.sh`**, not as a tool. The MCP tool would be a **third** delivery path to the same five exits |
| **MERGE** | **2 into 1** | Step 6's own instruction is *"apply THIS SAME TREE to the CHILD"* — so `lane_tree` is `lane_status` applied to a set of nodes, not a second tool. Anthropic's guidance (§8 row 1) is explicit that overlapping tools degrade selection. One tool, `tree: true` (or `depth: n`) as an argument |
| **EXPRESS AS A DELTA, not a new name** | **1** | `lane.list` / `lane.show` already exist and are registered (M1). `lane_status` must **extend that payload** with the liveness axis (steps 2/3/5/6) and the `finished`/`dead` mapping (§4.3) — a second tool answering "what state is this lane in" from a different vocabulary is exactly the duplication §8.1 and the issue's deletion rule exist to prevent |
| **AMEND THE WRAP TARGET** | **3, 12, 13** | #3 → `lane-wip.py` + `lane-artifacts.sh`, not the prose-only `lane-read.py`; #12 → `merged-not-closed.sh --json` + `gh closingIssuesReferences`, and **drop `outcome_canary.py`**; #13 → wrap `merge-reminder.py`'s timer lifecycle, and **one tool with an `action` argument** (`set`/`list`/`cancel` are three verbs of one family per §8 row 4), not three tools |
| **DEFER to its own issue** | **11** `verify_independent` | The only tool that creates and destroys cloud machines, all six of its artefacts live outside the repo, and it is the one row whose blast radius (§13 Q2) genuinely differs in kind. Splitting it costs **zero** extra CI runs if the other tools land in one PR (§7.3's own argument, which this reverses: the batching rule is about CI cost, and a 12-tool PR pays the same run) |
| **KEEP, with the §5.8 M-items propagated** | **4, 5, 6, 7, 10, 14** (and **9**, which no M-item changes) | Each adds a named surface no existing script produces (`env` + typed refusals; a repo-parameterised, `--json` census; `{rc, stdout, timed_out, truncated}`; a head-bound record verdict in one reply; a durable typed checkpoint), and each has a tracked, beat-wired implementation to stand on. ⛔ **"as written" was refuted by §5.8's own M-items and is dropped here**: #4 gains a **repo parameter + `--json`** (a write, M2/M16 also supply the box/`all` half), #5 gains `pr-state.sh` as the payload **shape** to copy and `merge-queue.py` as the pipeline half (M5, M7), #6 gains **two further claim surfaces** (M13, M19) and `live-ownership.sh` as the third axis (M12), #7 gains `bundle:`/`live-ownership` evidence for *who is already on this PR*, and **#14 must NOT build a third checkpoint read path** — `report.sh` (M18) is already declared loop-safe and is the read path; only the `cycle-record.sh` **verdict** is new typing, and #10 must carry `registry-sync.sh` (M17) so a local `norecord` is never reported as "no record anywhere" |

**So Phase 2 = 11 tools, expressed as 12 MCP names:** 10 new names — `lane.artifact` · `fleet.census` ·
`pr.queue` · `claim.check` · `lane.dispatch` · `box.exec` · `pr.review_record` · `pr.closure_audit` ·
`fleet.reminder` · `fleet.beat_checkpoint` — plus an **extension of the two already-shipped names**
(`lane.list` / `lane.show` gain the liveness axis, the `finished`/`dead` mapping and the tree recursion).
**Plus, as prerequisites rather than tools:** the F3 landings (`fleet-report.py`, `orch-checkpoint.sh`,
**and its launchd template**, `lane-verdict.py`), and the `safe-send.sh` print-mode refusal plus its
`4 → DELIVERED-NOT-CONSUMED` carry-forward (§5.0 V8). ⛔ **`lane_status` is therefore not a 12th name and
not a 13th tool** — it is the delta on the pair, which is why the counts in this document are "11 tools /
12 names" and never "12 tools" or "13 tools".

**What this saves, stated concretely:** one tool that would have been a third delivery path (#8), one tool
that is a rendering of another (#2), one tool that would have been a second lane-state vocabulary (#1 as a new
name), a 3014-line timer implementation that would have been re-derived (#13), a 5007-line module wrongly named
as a closure source (#12), and a timeout helper that macOS has already broken once across every class of another
reaper (#9).

---

## 5.10 PHASE 2 AS IMPLEMENTED — the mapping, and what it did NOT do

**Shipped surface: 11 tools / 12 MCP names** (§5.9), in `mcp-servers/orchestrator/server.py`, every tool a
wrapper over a tracked implementation. Nothing here re-derives another module's answer; where a module could
not answer the tool's own signature, the missing half was written **into that module**, once.

| tool (MCP name) | wraps | what Phase 2 WROTE (the `PARTIAL` half) |
|---|---|---|
| `lane.list` / `lane.show` (**rows 1 + 2**) | `lane_registry.py` (the four states, `list_payload`), `tools/fleet/liveness.py::evaluate` (**the ONE classifier**), `scripts/lib/pid-identity.sh` (`probe-argv`), `lane-status.py` as the **sampler** (`cpu`, `cpu_any`, `child*`) | **tree steps 2 and 3 into `liveness.py`** — `Evidence.cpu` / `Evidence.child` + two vetoes (§4.2, D8's first half); the `finished`/`dead` **mapping** onto the registry's terminal record; the **step-6 recursion** = `evaluate` applied to the child via the same `gather`; the liveness axis as a **payload extension** (no thirteenth name) |
| `lane.artifact` (**row 3**) | `scripts/lane-wip.py` (words), `lane-artifacts.sh` (files, already typed), the board's `LANE-DONE` line | **`lane-wip.py --json` + a stated exit contract** (`0` answered · `2` usage/no-lane · `3` UNMEASURED) — §5.0 V3 |
| `fleet.census` (**row 4**) | `beta-progress.py::compute`, `capacity.sh` (`probe`), `box-status.sh`, `os.getloadavg()` | **`--repo` and `--json` on `beta-progress.py`** (it parsed no argv at all) — the repo parameter and the typed payload, and nothing else (§7.7) |
| `pr.queue` (**row 5**) | `tools/fleet/pr_state.py --json` (the 15 actions + `fidelity`) | the **6-class VIEW** over the 15, in one direction only (§13 Q4); the `UNMAPPED` count makes a silent loss impossible |
| `claim.check` (**row 6**) | `tools/fleet/claim_lanes.py --json` (the registry axis, `render_json`) | a **typed refusal** when no repo is named, because the reader never uses the cwd implicitly; the abstention doctrine travels in the payload |
| `lane.dispatch` (**row 7**) | `nonblocking-dispatch.sh` (2/72–80), the `.pid` file, `git rev-parse`/`ls-remote` for the branch | the **two measured silent actuators as typed refusals** (`no-pid`, `branch-exists`) and the **mapping** onto the existing vocabulary — no gate re-implemented |
| `box.exec` (**row 9**) | `cmux vm exec --timeout` | the `{rc, stdout, stderr, timed_out, truncated}` shape, an **ARGV-only** surface, and a **fail-closed allowlist** with a typed refusal. ⛔ And, from **#2345**, a **LINK REFUSAL is a CHANNEL fact, not the command's rc**: `outcome: CHANNEL-REFUSED` + `channel_refused` = `link-refused` / `no-known-daemon` / `daemon-binary-absent` and the class's own remedy — the peer never ran anything, so its rc is the TRANSPORT's (a refusal that exits **0** is reported too, as `fail_open`). ⛔ `channel_refused`, **not** `refused`: that key already means "this surface ran nothing" (`read-only`, `command-not-allowlisted`, …), which these classes do not mean. `peer` is carried only for `link-refused` and `peer_log` only where the transport's line names a `…peer-links/…` path — *not* for all three classes |
| `pr.review_record` (**row 10**) | `record-review.sh --check-carry` (positional) | the 7 verdicts → `current`/`stale`/`absent` **with each verdict's own next action kept**, plus the head-bound digests in one reply |
| `pr.closure_audit` (**row 12**) | `gh pr view --json closingIssuesReferences` + each issue's live `state` | the **comparison** nothing else makes: `closed` / `still_open` / `mentioned_but_not_closing`, with “a mention is not a closure” as a field |
| `fleet.reminder` (**row 13**) | `merge-reminder.py` (`--install-timer` / `--uninstall-timer` / `--interval`) | a **file-backed queue** under the state dir (atomic write), `set`/`list`/`cancel` as one tool |
| `fleet.beat_checkpoint` (**row 14**) | `report.sh` (**the loop-safe read path**), `cycle-record.sh::cycle_verdict` / `cycle_record_write` | the typed read (report + verdict, `ABSENT` never `HEALTHY`) and the typed write — **no third checkpoint reader** |

**Declared, not done — with the reason, because a silent omission is the failure this whole issue is about:**

1. **`lane.dispatch`'s `env` argument is NOT implemented.** `nonblocking-dispatch.sh` accepts no `--env`, and
   §7.2 already says the only path that reaches the agent's gates is the launcher's own environment. The tool
   returns a **typed `UNSUPPORTED(env + …)`** and does **not** dispatch — a silently dropped `env` would be a
   lane running without the variable the caller believed it set.
2. **`safe-send.sh`'s `pi -p` refusal and the `4 → DELIVERED-NOT-CONSUMED` carry-forward are NOT in this PR.**
   They are prerequisites in §5.9, in a **different file with its own test suite** (`safe-send`), and F13's
   remedy is a change to the delivery path — not to the MCP surface.
3. **The F3 landings** (`fleet-report.py`, `orch-checkpoint.sh` + its launchd template, `state/lane-verdict.py`)
   are **not** in this PR. The tools do not depend on them (§5.0.3, D3), and landing untracked bytes is its own
   review.
4. **D8's second half — retiring `lane-status.py`'s 12-verdict ladder — is a follow-up.** It is *smaller* after
   this PR, not larger: the MCP surface reads only that module's **sampler fields** (`cpu`, `cpu_any`,
   `child`, `child_stale`, `child_grew`, `cwd`) and **never its verdict**, so the ladder's only remaining
   caller is the
   heartbeat's own `lane-status.last.json`. That is §13 Q6's “quarantined, one caller, one release”.
   ⛔ THE ROW'S KEY IS `cpu` / `cpu_any`, NOT `cpu_busy`: `cpu_busy` exists only as a `classify()` keyword
   (`lane-status.py:1852,2335`), while the emitted row carries `cpu=_cpu, cpu_any=_cpu_any`
   (`:2416-2421`). An earlier revision of this list said `cpu_busy`, an implementation was written from it,
   and step 2 was therefore silently UNMEASURED on the MCP surface — recorded here so the next lane
   implementing against §4.1 does not reproduce it.
5. **Tree step 5's classification is still `lane-actions.py`'s** (one batched JEV call for the fleet, D7). The
   MCP attaches its **input** (`lane.artifact`'s words axis) and never makes a second JEV call.

**Invariants → tests (all in `mcp-servers/orchestrator/test_server.py`, each naming its fixture):**

| # | test | the fixture it reproduces |
|---|---|---|
| 1 | `test_I1_…`, `test_I1b_…` | FALSE UNMEASURED — three ways to fail, and the reason inside `UNMEASURED(...)` must name the right one; a non-JSON payload from a **successful** command is a PARSE failure, never “the command failed” |
| 2 | `test_I2_…` | FALSE MERGED — a `#N` mention is not a closure, an `open` issue is never closed, an unreadable API is neither |
| 3 | `test_I3_…`, `test_I3b_…` | FALSE DEATH ×3 — a terminal record is `finished` whatever the process table says; `dead` needs positive evidence and carries `dead: true`; no verdict is `no-verdict` **with** its reason |
| 4 | `test_I4a_…`, `test_I4b_…` | STALE CLOCK — a future stamp is **clamped** (never `-4m ago`), and every census figure carries `measured_at` + `source` |
| 5 | `test_I5a_…`, `test_I5b_…` | a missing wrapped module **refuses to start** (rc 3, naming it); `deployed_drift` is `unknown`, never a pass; a one-byte change to a module changes its sha256 |
| 6 | `test_I6_…` | MUTATION, **RED FIRST** — `git show b54b117fc:scripts/beta-progress.py` renders a negative age and HEAD clamps it, both executed |
| annotations | `test_S3_…` | every tool declares **all four** annotations; `box.exec` is `destructive + openWorld`; the surface is EXACTLY the approved 12 names |

**The two capacity calibrations are implemented as TWO rows, not one** (§10.1): `fleet.census` reports
`platform` and the **applicable** ceiling with its source (1.2 LPC on macOS, 10.0 on a Linux cell) and states
that load is a *moment's reading*, so a single threshold can never call a dying Mac healthy.

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
| **D9** | **A second carry predicate** — `pr_state.py::fidelity` alongside `record-review.sh --check-carry` | Both answer "may this record carry?". `pr_state.py`'s is its own four-state predicate over `--print-diff-hash` (it never calls `--check-carry`); the skill's §6.5 table is the authority and it distinguishes ten verdicts (three of them — `red-surface`, `red-base-owned`, `surface-unknown` — added by #3440 and off the carry axis entirely) where `pr_state.py` has four. The disagreements are measured, not hypothetical: **`nodigest`** and **`carry-patch`** both read `owes-review` to `pr_state.py` and something else to the tool, and both are cases where the wrong answer **costs a full review cycle**. Phase 2 names ONE of them for the MCP surface (#10 = `--check-carry`, per the issue's own row) and #5 maps its own row to that verdict rather than restating a fourth state machine |
| **D10** | **`lane_message` (#8), as a tool** | Added in Phase 1.5 on file evidence, not preference: `scripts/safe-send.sh` (tracked, 233 lines) already delivers exactly this surface — typed exits `0 sent+consumed · 3 REFUSED · 78/80 brief gate` (`:38`), all five `cmux_dispatch.py` exits preserved, the brief gate run before sending, and an unreadable pane refused — while `scripts/orch-send.sh` refuses a foreign or nonexistent pane by POSITIVE match. An MCP tool here would be a **third** path to the same exits, and its claimed wrap target (`tortoise/tools/cmux_dispatch.py`) is in the **product repo**, so it could never have shipped from agent-infra. ⚠️ **One premise of this deletion was overstated and is corrected in §5.0 V8**: `safe-send.sh` types `0`/`1`/`3` and **collapses `2` and `4` into one `UNKNOWN` bucket**, so `4 = delivered-not-consumed (queued)` is lost today. The deletion stands on the two grounds that survive — the wrap target is unshippable from here, and the existing scripts carry a stricter precondition set — and the missing typing is carried forward as the ~10-line `4 → DELIVERED-NOT-CONSUMED` mapping in the F3 prerequisite list, **not** as a tool. The `pi -p` refusal F13 demands goes into `safe-send.sh`, beside the four refusals it already makes |
| **D11** | **A second lane-state vocabulary** — a new `lane_status` name beside the shipped `lane.list` / `lane.show` | `mcp-servers/orchestrator/server.py` already serves the registry's four states (`RUNNING`/`DONE`/`FAILED`/`EXPIRED`) over `refs/lanes/*`, is registered in `.mcp.json`, and is tested. A second tool answering "what state is this lane in" from `dead \| running-quiet \| wedged \| idle \| unknown` would be two vocabularies on one server — the defect §5.7 and §8.1 name. Phase 2 **extends** `lane.list`'s payload with the liveness axis and the `finished`/`dead` mapping instead of adding a name. **⚠️ This is a contract change on a live tool** and therefore needs the owner's word, not a lane's |

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
3. **The timer is ONE target: `merge-reminder.py::install_timer`** (`:2393`, verbs `:2796-2798`) — it is
the only implementation that owns a *single reminder's* lifecycle (`--install-timer` /
`--uninstall-timer` / `--interval`), emits `--json`, and writes **launchd on macOS and a systemd user
timer on Linux**, which is what makes it work on the cells. ⛔ **`fleet-schedule.py` is NOT the timer
for this tool, and the reason is not preference**: it is a *schedule reader/installer for the box's
already-installed jobs* (`--check`/`--status`/`--verify`/`--install`/`--start`/`--stop`, plist-parsed) —
it enumerates the fleet's existing timers and has no per-reminder lifecycle, no `--interval`, and no
**named skip verdict** (exit 3, *"the cycle was SKIPPED — named, and never passed off as 'nothing to
do'"*), which is exactly the distinction this tool exists to preserve. Naming both (as an earlier draft
did, and as §5.0 V13 and this item did in opposite directions) is how a third installer gets written: one
target, named once.

No existing tool does set/list/cancel; that is why it is `PARTIAL` rather than a wrapper.

### 7.7 `fleet_census` (#4) — `PARTIAL`: the write is the repo parameter and the typed payload

The row was the only one whose class changed without a justification in this section, which is what an
independent review caught. It is supplied here, and it is short because the case is narrow:

- **Every existing implementation answers a narrower question than the row asks.** `beta-progress.py`
  parses **no argv** and hardcodes `REPO = "daniel-ospina/tortoise"` (`:35`), so `fleet_census(repos)` —
  whose whole signature is a repo list — cannot be a wrapper of it. The repo parameter and a `--json`
  payload (today the module prints one prose `DELIVERY [as of …]` line) are therefore **written**, and
  they are the *only* thing written: the P0/P1-with-PR derivation stays `compute()`'s, never re-implemented.
- **`capacity.sh` and `box-status.sh` are wrappers, not writes** — `probe`/`fleet` already answer placement
  and the fleet-wide capacity channel with named refusals, and `box-status.sh` already emits six
  machine-parsable lines with exit 2 = cannot-verify.
- **Why no existing tool can serve as-is:** the three modules answer three *different* questions on three
  *different* surfaces (a prose line, a placement gate, a box's own harness identity), and nothing composes
  them into one object carrying `platform`, `load`, the **applicable** threshold with its source, and
  `measured_at` per figure — which is what §10.1 says the census must carry, because one threshold across
  two platforms fails in the reassuring direction.
- **And the honest scope line:** `fleet-report.py` is **not** part of it (D3) — it is untracked, so making
  the tool depend on it would make the server unreproducible on a fresh box, which is Indicator (b).

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
| **a LINK REFUSAL is a CHANNEL reading too — and the transport can exit 0 while refusing it** | **agent-infra#2345**, measured 2026-11-08 from `pi-cell-5`: `vm ls --json` printed `"reachable":true` for all four peers while `vm exec` refused all four (`cmux: link to '<peer>' exited`) | the peer never ran the command, so the caller reads the transport's rc as a verdict about the command (or about the box's health) and repairs the wrong thing; and a refusal that exits 0 reads as SUCCESS to any caller keying on `rc` (measured on `pi-cell-3`, 2026-10-23) | `box.exec` reports `outcome: CHANNEL-REFUSED` with `channel_refused` = `link-refused` / `no-known-daemon` / `daemon-binary-absent` (three different remedies — the last one is on the CALLING box, #3195), keeps the transport's rc labelled as the channel's, and **carries the peer-log path only where the transport's own line names one** (i.e. `link-refused`; `peer` likewise) — `daemon-binary-absent` instead carries `binary_path` |
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

⛔ **PART OF THIS IS ALREADY SHIPPED (Phase 1.5, §5.8 M1).** `mcp-servers/orchestrator/server.py`'s
`Registry.__init__` hashes the wrapped module and rides `registry_sha256` on **every payload and on
`initialize`** — so invariant 5's *reporting* half exists for the one module this server wraps today
(`lane_registry.py`), with its `_candidate_paths()` resolution order recorded in the answer (including
`CELL_HOME` before `HOME`, §10). What does **not** exist is the **start-up gate**: an unresolvable or
unloadable module degrades to `UNMEASURED(resolve lane_registry.py + …)` and the server **serves anyway**.
That is the `no-op gate` polarity §11 argues against, and it is the one thing Phase 2 adds here — not a
hasher.

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
   missing is only the typed surface. **It is not unique in that** — several rows are "the verbs do not
   exist" shaped. So the real question is about **blast radius**, not about novelty: #11 is the only tool in
the batch that creates and destroys cloud machines, and it is the only row whose six supporting artefacts
live **entirely outside the repo**. Reducing to 11 tools (§5.9) costs the same CI run.
3. **F3 — do the three untracked modules get landed in this issue?** `orch-checkpoint.sh` is wrapped by
   #14. `fleet-report.py` is **not** a wrap target (D3) — it lands only if its `lanes=` fix is worth
   keeping, and #4 stays on tracked modules either way. `state/lane-verdict.py` is wrapped by neither,
   yet it holds one of the five `jev-latest` pins — which is reason enough on its own. Landing them is prerequisites, not scope creep — but it is bytes landing in
   `scripts/` inside a PR whose stated deliverable is a new server.
4. **§5 tool 5 — is the issue's 6-class PR vocabulary the *contract* or a *view*?** `pr_state.py`
   answers with 15 actions that carry strictly more information (`carry-patch` vs `carry` changes what
   the operator does). This inventory maps the 6 as a view and keeps the 15 as the answer.
5. **§8.1 — read-only by default?** The Kubernetes comparable's strongest published lesson is
   `--read-only` / `--disable-destructive`. **8 of the 11 tools are read-only** (`lane_status`,
   `lane_artifact`, `fleet_census`, `pr_queue`, `claim_check`, `review_record`, `closure_audit`, and
   `beat_checkpoint`'s read action); the mutating three are `lane_dispatch` (#7), `box_exec` (#9) and
   `reminder` (#13), and 11 − 3 = 8. ⛔ **The 14-row figures this replaces were 8 read / 6 mutating** —
   they counted #8 and #11, which do not ship. `box_exec` is the awkward one and must not be waved
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
