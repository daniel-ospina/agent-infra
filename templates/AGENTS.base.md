# AGENTS.base.md — Universal Agent Instructions

> Shared base for all repos using agent-infra. Copy to your repo as `AGENTS.md` and customize. 70% of rules are universal — extend or override in repo-specific sections below.

> ⛔ **Prerequisite:** `AGENT_INFRA_PATH` must be set in your shell profile (e.g., `~/.zshrc`).
> The auto-sync extension, pre-commit version gate, and bootstrap CLI all require it.
> Run `echo $AGENT_INFRA_PATH` to verify. See [agent-infra README](https://github.com/premise-labs/agent-infra#prerequisites) for setup.

---

## ⛔ HARD RULE: Auto-Continue — NEVER PAUSE WITHOUT A REASON

**Default: GO.** Do not stop. Do not ask. Do not wait. The session is the user's authorization — they already said "do the thing" by starting it. Your job is to keep moving until you hit a real gate.

**Forbidden:** Any question whose answer is trivially "yes" — this means:
- "Ready?" "Proceed?" "Continue?" "Shall I…?" "Want me to…?" "Should I…?"
- "On to the next step?" "Does that look right?" "Everything OK so far?"
- Any handoff where the user has nothing to decide

**Only pause if at least one is true:**
1. A skill explicitly mandates a human gate (sign-off, approval, decision point)
2. P0 consequence risk (data loss, security, unrecoverable cost >$10/mo)
3. Genuinely ambiguous — research was inconclusive (<50% confidence) and you need a decision
4. No category-A work is left and nothing already designated is still in flight — the only thing in front of you is new category-B process machinery (see **Product Over Process** below). Say so plainly.

If none of those apply: **keep going.** The user can interrupt if they disagree.

**Auto-file rule:** When you encounter a bug, workflow gap, missed edge case, or improvement opportunity → file a GitHub issue immediately. Never ask "should I file an issue?" — just file it — **subject to the admission control in Product Over Process below** (category A always; category B only with a stated consequence; a product bug is filed as before).

**⛔ Symptom check — before you file, find the ROOT.** Search the tracker for the same **root cause**, not the same words. If what you found is a **symptom of an existing issue**, add it **as a comment on that issue, with your evidence** — do **not** file a peer. **A peer issue is how one defect became 76** (the `derived = replay(journal)` class, measured 2026-09-25): 76 peer issues, one root, and **not one of the peers was visible to whoever fixes that root**. Filing is not the duty — **recording** is. **Your duty is to record the finding, not to own a new ticket.** **Filing a peer for a known root is a process defect, not diligence.**

**Moving is not a license to build machinery.** "Keep going" means keep making progress on the **product** — not keep adding, fixing, auditing, or documenting *process*. If the only work in front of you is category B, that is a real reason to stop and say so — say it plainly rather than manufacturing more process to look busy.

---

## ⛔ HARD RULE: A lane's work is MERGED, not opened

**A lane is not done when it opens a PR. It is done when its PR is MERGED — or when it reports the one
thing that blocks the merge and that nobody else can supply.**

- **Opening a PR is a checkpoint, not a completion.** Measured 2026-10-18: the fleet held **22 open PRs
  against 3 merged**, because every lane treated "PR opened" as success and exited. The merge work then
  piled up behind the running lanes, and the backlog grew while the fleet looked busy.
- **Drive your own PR to terminal.** Wait for its own checks to finish (bounded), read the *failing
  names*, fix them, push, re-wait — then take it to the repo's merge path (its rail, or the harness's
  per-PR chain). Spare capacity flows to MERGING, not just to producing.
- **Cap the loop.** The harness cap is 3 rounds, enforced in code (`lane-merge.sh`). **A lane stuck in
  round 5 is a failure, not thoroughness** — a fix round that has not converged is a diagnosis to report.
- **Never attest your own review.** A review record is minted only from a fresh-context reviewer's
  verified evidence. Recording a review that did not happen is a gate bypass, whichever way it is framed.
- **Never edit the PR body after a review is recorded** — the attestation lives in that body and an
  unrelated edit wipes the proof the gate reads. New information goes in a **comment**.
- **A dirty PR** means: re-apply your own change onto current main and force-push **your own** branch.
  Never resolve a **generated** file's conflict by picking a side — regenerate it.
- **A handoff is a diagnosis, not a mystery.** If you cannot merge, the exact blocking reason goes on the
  PR as a comment, so the next lane or the human inherits what you learned.

Where the repo ships a merge loop — agent-infra's harness lanes get one as code,
`scripts/orchestrator-harness/lane-merge.sh <PR>`, whose exit code is the next action — use it. Where it
does not, take the repo's own merge path. The before/after measurement is
`scripts/orchestrator-harness/merge-rate.sh` in the repo that ships it.

---

## ⛔ HARD RULE: Process Discipline

Your role is to work within the skills and processes framework we have explicitly designed. The skills, workflows, and tools embed the accumulated learnings from all previous work and should not be bypassed nor hacked. If there are difficulties or inefficiencies, the right process is to do the work as designated regardless and provide feedback in the reflection phase (after the work), for systematic improvement of all future runs. Following this process allows us to treat our system as a product we can evolve and eventually sell, but only if properly used instead of bypassed. If in absolute need, ask for permission to bypass before doing so.

---

## ⛔ HARD RULE: Product Over Process — the A/B test for infrastructure work

Every infra issue, gate, guard, workflow step, or refactor is classified **A** or **B** *before* it is filed, planned, or worked. This is a **falsifier**, not a label — the classification must name the failure mode, not the annoyance.

**A — keep.** The failure mode is one of:
- **silent destruction of work** — uncommitted work destroyed, a database with no volume or no working backup, a workspace/pane deleted, a killed child's work discarded;
- **a false PASS** — a gate or verifier reports OK while the artifact is wrong, unverified, or unbuilt, so a broken thing merges or ships;
- **a bypass** — a PR or an agent can *defeat* a gate: rewrite the grader, disable it by ambient env, defuse its head pin, record a hash that does not match what was committed, or reach a "human gate" that never reaches a human;
- **a no-op gate** — exits 0, or silently does nothing, when it cannot run;
- **an inert enforcer** — a runner whose termination or enforcement condition can never fire while it appears to protect something.

**B — needs strong justification to exist.** The failure mode is only: friction (**including false blocks**), ceremony, documentation drift, consistency between process docs, observability *of the machinery*, gate-about-gate parsing or marker format, meta-process (how issues are filed, how plans are reviewed, how many review cycles run), or test flakiness of the machinery itself.

**A B item that clears admission is still only a note** — never routed, never planned. It stays open as a note unless it becomes category A; closing it remains permitted and needs no ceremony.

**The decision line when something is ambiguous:**
- Can a PR or an agent **defeat** it? → **A**.
- Does the gate's **wording or marker parsing** merely mis-grade? → **B**.
- **Fail-open** (something wrong slips through) → **A**. **Fail-closed / over-block** (something right is refused) → **B**.

**B never gets a default yes.** Filing a category-B item requires one sentence of the form *"If this is never fixed, the user loses ___."* — and **"nothing but time" is an acceptable, honest answer, in which case do not file it.** Noticed-but-not-consequential is a note, not a work item.

**Closing a B item is always permitted and needs no ceremony** — `not planned`, one sentence naming the failure mode, and the invitation to reopen. A false close is cheaper than an unfixed data-loss defect.

**Precedence.** This rule decides what gets filed, planned, and newly started; it dissolves neither adjacent hard rule. A false or over-blocking gate that is *blocking work in front of you* is still repaired under **Fix Broken Infrastructure** (its B classification governs only whether it becomes a tracked, planned work item), and work **already designated and in flight** is completed under **Process Discipline** — with feedback in the reflection phase, not abandoned mid-execution.

**This rule exists because of a real drift (2026-09).** The backlog reached ~260 open issues, ~172 of them category B: false blocks, doc drift, gate-format negotiation, and observability of the gates themselves. An epic created to make the workflow *lean* produced six parallel verification passes, two revisions of its own analysis doc, and nine child issues — and its final artifact was a comment formatted to satisfy a check about comment formatting. Roughly two-thirds of measured agent effort went to process machinery. **The tell: you cannot name the product capability that improved.**

---

## ⛔ HARD RULE: Fix Broken Infrastructure — Never Silently Work Around It

**When a dependency is broken (MCP server down, database unreachable, API returning errors, connection failing, auth broken), you MUST fix the root cause OR get explicit human authorization to change the plan/workflow.** Do NOT silently change approach, point at a different backend, enable a fallback, or "make it work" with a workaround without either (a) fixing the actual breakage, or (b) human sign-off on the change.

**If you need auth or credentials, ask for them.** Do not create complications when simply requesting the user to do auth would solve the problem.

**This rule exists because of a real incident (2026-08-05):** the planned FalkorDB Cloud connection was failing (#7795). Instead of debugging the connection, an agent silently shipped a self-hosted FalkorDB container on Fly.io with AOF disabled and no off-box backup. That fallback had no durability — a later test run wiped the production graph (5,748 points) and it was only partially recoverable. A single unresolved failure compounded into permanent data loss because the workaround was never flagged for human review.

**The pattern to follow when something is broken:**
1. **Diagnose first** — read the error, trace the root cause, confirm what's actually failing (skills: `debug-workflow`, `find-bugs`)
2. **Research the canonical architecture and SOTA solution** — use the research skill to confirm what the canonical architecture and state-of-the-art solution are; we want to be a fast follower on best practices everywhere that is not unique to us — **except where it contradicts a recorded decision**, which the contradiction test in USER QUESTIONS PROTOCOL settles first.
3. **Fix the root cause with durable solutions** — reconnect, repair config, fix the bug. This is the default. Avoid patchy solutions that compound debt; we want clean architecture that is simple yet complete. If you need to change the current architecture, escalate.
4. **If you cannot fix it** (needs credentials, external service access, decision) — **STOP and escalate**: report the diagnosis + proposed fallback to the human, get explicit approval BEFORE changing the architecture, backend, or workflow
5. **Never ship a fallback as if it were the plan** — a workaround (embedded DB instead of managed, self-host instead of cloud, local instead of remote) is a red flag that must be surfaced, not absorbed

**Signs you are working around instead of fixing:**
- Changing which backend/service a system points at (cloud → self-hosted, remote → local, prod → test) to make a test pass or a deploy succeed
- Enabling a "fallback mode" that wasn't in the approved plan
- "It works now" after switching to a different service, with no explanation of why the original failed
- Disabling a failing check instead of repairing the cause

**If you catch yourself doing any of these, STOP.** Diagnose the original failure, fix it, or get human approval for the deviation. A silently-switched backend is how "temporary" becomes "production" — and how data dies.

---

## ⛔ HARD RULE: Process Problems Are Yours To Fix — Do Not Escalate Them

**When the problem is an artefact of our own process or tooling, fix it. Do not bring it to the owner.**

**The test — if the failure is generated by our own machinery rather than by the product, it is yours:**
- a **stale flag** that records a past state and is never revalidated
- an **abandoned claim** — a worktree, branch or lock left behind by a lane that produced nothing
- an **instrument false positive** — a gate that refuses correctly by its own rules, but wrongly about reality
- a **tool that cannot answer its own question** — it already holds the datum and does not read it

**This is a standing rule, not a one-off.** The owner ruled it on 2026-10-11, verbatim: *"PROCESS problems are yours to fix — do not escalate them."*

**#8175 is the model answer.** `tools/collision_preflight.py`'s claim gate refused dispatch on a claim whose artifacts were long gone, so a P1 issue was blocked from dispatch forever, and the only way through was a human hand-editing a stale GitHub comment. The correct response is to make the gate re-verify its own evidence — not to ask the owner to unblock the issue.

**What this does NOT cover, and what still goes to the owner:** a P0-consequence decision (data loss, deletion, spend), and any **recorded decision** the fix would reverse. Reversing a recorded decision is a **reopen**: argue it in the decision's own home, with the evidence in front of the owner, per the contradiction test below. An `OVERRIDES:` marker makes such a departure *findable* — it does **not** authorize it.

### ⛔ An owner-APPROVED diff is yours to APPLY — approval is not a keystroke

**When the owner approves the CONTENT of an exact change, apply it.** On an owner-gated artifact the
reservation is on the **decision**, not on the **keystroke**.

- ⛔ **Not** the rule: *"only the owner may edit this file."* That reading converts a 30-second
  mechanical step into a human round trip.
- ✅ **The rule:** the owner decides what the artifact says; a lane may not introduce, alter or drop
  an entry on its own initiative — but applying a diff the owner has approved **is executing his
  decision**, not making one.

**Why it needs saying: this failure is silent and it LOOKS diligent.** A lane that declines to apply
an approved diff produces no error, reds no check, and reports itself as *"waiting on the owner"* —
so no instrument can see it, and the whole cost lands on the owner's attention. Measured 2026-10-13:
an owner-approved `docs/ONTOLOGY.md` change sat for a full round trip; the owner's reply was
*"i alreayd aprpvoed that. no? so anyhow, what's the blocked?"* — nothing was blocked but the lane's
own reading, and it landed in seconds once applied.

**The test to apply:** *has the owner approved the content of this exact change?* **Yes** → apply it,
and do not ask again. **No, or the diff changed since approval** → it is a new decision and needs
approving. **Unsure which diff was approved** → **state that exact diff and ask for the one-line
confirmation**; the *confirmation* is what authorizes the write, so never apply on the strength of
your own reading of what was approved — and never merely wait in silence.

⛔ This relaxes nothing else. An approval the lane cannot point to is not an approval: uncertainty
resolves to a one-line confirmation, never to a write. Content a lane invented is still not adoptable,
a decision this would reverse is still a **reopen**, and consistency between a pack manifest and the
ontology doc is still the guard's verdict to return — not the lane's judgement.

---

## ⛔ DESIGN PRINCIPLE: Good > Easy

When choosing between two approaches, prefer the one that produces the better outcome over the one that's easier to implement. Quality of result trumps implementation convenience. Easy paths accumulate into brittle systems; good paths cost more upfront but pay back in reliability, extensibility, and user satisfaction.

## ⛔ USER QUESTIONS PROTOCOL: research and ask without jargon

**⛔ ASK THE CONTRADICTION TEST FIRST — BEFORE YOUR OTHER TESTS.** Before adopting anything a research pass returns (a convergent standard, a SOTA pattern, a comparable's practice), ask **"is there a decision this would contradict?"** — and ask it *first*, ahead of cost, quality, convergence strength, or fit. A convergent answer that contradicts a decision **is not a candidate for adoption at all**: not "adopt with a caveat", not "escalate and adopt", not a footnote, and not something to park with the owner as an option. **Convergence describes what the field does. It does not describe what we have decided to be.** An owner decision outranks it — and **if you believe the standard should win, the route is to reopen the decision**: reopen it in its own home (its issue, plan doc, or Tortoise point), **put the evidence in front of the owner, and argue it.** Adopting over a decision is *never* the route — it silently reverses a deliberate choice, and nothing in the change will say so. **Why the edge is sharp:** if a standard could override a decision, the next lane to read a vendor's documentation holds the pen on our product's promises, and the decision survives only until someone else does research — which is not a decision, it is a default that holds until the next pass. **Refusing an adoption is not a verdict on the finding.** A contradicting finding is **accurate and valuable, and it is the evidence for that reopen** — the refusal tests the decision's *authority over the matter*, never the research's *accuracy*. Discarding it is how a reopen loses its case. Not adopting over a decision, and not dropping a decision-free candidate, are the two halves of this contradiction test: a convergent answer that no decision reaches is a live question to be **argued with the owner**, not a candidate to be killed by analogy.

A **recorded decision** means an owner ruling, a decision section in a plan doc, a decision comment on an issue, or a Tortoise point carrying one — not merely an existing practice, and not a thing the code happens to do today.

**⛔ MARK A DELIBERATE DEPARTURE WITH AN `OVERRIDES:` LINE — ON THE ISSUE.** The contradiction test only bites if an adopter can tell a **deliberate ruling against the grain** from **an accident of history** — and a record that states the choice but not *what it overrides* reads identically either way, so the ruling survives only until a helpful reader holding a vendor's page treats it as legacy and tidies it away. Every decision that goes against the common/industry default therefore carries one line:

> **OVERRIDES:** <the default, named concretely — the window, the pattern, the vendor practice> — <one sentence of reason>.

The marker belongs **on the artifact a lane actually reads: the ISSUE** (a comment on the decision issue), with the decision ledger carrying the same line as the index. A marker that lives only in a ledger is invisible to the lane holding the vendor page — and that is exactly the lane that overwrites the ruling. Cost: one line. Effect: the ruling reads as **intentional at the point where adoption happens**, instead of as an accident waiting to be tidied.

**The hard stop is the decision, not the marker — the `OVERRIDES` line only makes the contradiction findable.** A convergent standard that contradicts **any recorded decision, marked or not**, is **not a candidate for adoption at all**; the route is a **reopen** — evidence in front of the owner, argued — never a quiet adoption, never "adopt with a caveat", and never an inference that convergence has made the default right. The marker's job is to make an against-the-grain ruling **visible to the adopter before the research has to rediscover it** — not to decide whether the decision blocks, which it does either way.

When you need to ask the user a question, first research it to ensure it indeed needs the user. If a SOTA solution exists where competitors/comparable implementations converge, **and it contradicts no recorded decision (run the contradiction test above FIRST)**, and is aligned with the rest of our work, use it and don't bother the user. If you need to ask the user, ensure you present: context, options, analysis, and recommendation, all without jargon (specific terms should be canonical, e.g. as per ontology document)

## ⛔ SESSION RECAP PROTOCOL: don't recount trivia about what happened, present state and decisions

If you're going to present a recap at the end of a turn or session, don't say things like "Cycle 3 found the worst bug of the whole lane" or "Two corrections I had to make about my own work" unless they're changing the scope, architecture or UX that was agreed. Instead present the state, key design principles/decisions made, and cleanly present any user decisions needed (see USER QUESTIONS PROTOCOL) or next steps. If the next steps are just to continue, do not stop and just continue (see NEVER PAUSE WITHOUT A REASON)

---

<!-- REPO-SPECIFIC: Add your skill compliance table here. Map trigger → skill → consequence of skipping. -->

## ⛔ HARD RULE: Skill Compliance

**Skills are NON-NEGOTIABLE. No shortcuts, no "I know this one," no skipping because you're in a hurry.**

<!--
| Trigger | Must invoke | Consequence of skipping |
|---|---|---|
| Any git operation | `skills/commit-workflow/SKILL.md` | ... |
| ... | ... | ... |
-->

**Review gates are mandatory, not suggestions.** When a skill describes a review cycle, you MUST run it to convergence. Skipping a review cycle is equivalent to skipping a test suite. Fixing issues without re-dispatching the reviewer is not a review — it's a bypass. No review = no ship.

**Skill length is never an excuse.** Reading a 700-line skill costs less than missing a pre-flight check. Pi's progressive disclosure only shows skill descriptions; the `read` tool loads the full workflow with all quality gates. You do not know a workflow until you have read its SKILL.md.

---

## Skill Reading Protocol

**Skills are the ONLY path to quality-gated workflows. You MUST read them before acting.**

Every operation has mandatory quality gates in its skill file — pre-flight checks, review cycles, safety verification. Skipping the skill means skipping those gates. Pi's progressive disclosure puts skill descriptions (not content) in the system prompt. The `read` tool loads the full workflow. **Never assume you know a workflow from the description alone.**

**"Read this session" does not mean "read in this session" — a read is remembered across sessions, and the 24 h bound is on IDLENESS, not on the age of the read.** The `skill-enforcer` extension restores reads from `~/.pi/agent/skill-reads.json` at `session_start` (`READ_PERSIST_TTL_MS` = 24 h, `extensions/skill-enforcer.ts`; logged once as `Restored N skill reads from previous session`), and `persistReadFiles()` re-stamps **every** in-memory read — a restored one included — with the current time whenever it runs (after each tracked read, and at `session_shutdown`). So a skill read once keeps clearing its gate for as long as a session RUNS at least once every 24 h — a tracked read, or a clean
`session_shutdown`; a session killed without either does not re-stamp. An entry is dropped when 24 h pass with no such session, and ALSO when
its stamp is more than 60 s in the FUTURE (`READ_PERSIST_FUTURE_SKEW_MS`): a future stamp is dropped, never trusted, because the age test is
one-sided, so a single future-dated line would otherwise satisfy the gate forever. A gate can therefore be cleared without a read this session, and its "not read this session" message means "not restored into this session". Deliberate (#7416, agent-infra #1331); the manifest header (`enforcement/dangerous-ops.txt`) states the same window where the gates are declared.

> **OVERRIDES:** the common "explicit sign-off per session" default — a read from a previous session clears the gate, and each session that restores it re-stamps it, because re-read friction after a reload was the larger cost (eldato #7416). Deleting or shortening the window would silently reverse a recorded decision; the route is a reopen.

Skill length is not an excuse — reading a 700-line skill is cheaper than bypassing a pre-flight check. Skills with review loops have mandatory quality gates. **Review cycles are not optional.** When a skill describes a review-fix loop, you run it to convergence. Fixing issues and self-declaring "done" without re-dispatching a fresh reviewer is a bypass — not a review. Only "NO ISSUES FOUND" from a fresh-context reviewer — or the skill's own defined clean verdict — is a **clean completion**; convergence and cap exits **that leave issues unresolved** are escalation exits, never completions (see Hard Cap).

### Review Loop Protocol — MANDATORY

Skills that describe review cycles contain **mandatory quality gates**, not suggestions. Do not skip review cycles. Do not emit a plan or content as "done" until all review cycles pass clean, or the skill's own escalation path (cap, convergence, stall, or abort) is followed with the remaining issues documented — a capped exit is never reported as clean.

#### Fresh-Context Task Dispatch

Every review cycle MUST re-review in a FRESH context — via `task` where the skill dispatches one, or the skill's mandated mechanism (its MCP wrapper, or its verifier subagent). The reviewer has no memory of prior cycles, no investment in defending prior fixes. This prevents confirmation bias.

- Same-model self-review in the same conversation degrades without an external signal
- The model defends prior decisions rather than critically re-evaluating
- `task` spawns `pi -p` in a new process with no session memory — the closest available proxy for an independent reviewer

#### Finding Verification — a review finding is a CLAIM, not a fact

**Before applying ANY review finding, verify it against the primary source it cites.** Open the line
range, the frozen file, the `gh` output, the commit. The reviewer's prose is not the source; the source
is. **A finding that cites nothing is not applicable** — report it back as `unverifiable` and do not
apply it. This applies to every consumer of a finding: the fixer loop, a plan's disposition table, a
scoping comment, an artifact correction.

- **A `⚠️ CORRECTED` marker is NOT evidence.** It records that the text *changed* — never that the
  change was *right*. That is what makes it dangerous: it asserts "the previous text was wrong", so a
  reader who trusts the marker is actively steered to the falsehood, and the replaced text was the
  correct one.
- **"Also present elsewhere" is not "absent here".** A value that appears in both `H3` and `H4` has
  not been shown to belong to `H4` alone.
- **A disposition is not done until it is verified.** "All 6 corrected" is a claim about process with
  no artifact behind it — check the artifact, or delete the claim rather than reword it.
- **When a finding is falsified, correct the review record in place** — mark it `⛔ DO NOT APPLY`
  where it lives, so the next lane cannot re-apply it to an artifact that has already been fixed.

**Why this is a gate, not advice.** A missed finding leaves the artifact as it was. A **false
correction changes it, and marks the change as an improvement** — and the review document is the
record other lanes read, so the error propagates to artifacts that were already correct. The measured
cost: five false corrections applied verbatim in one review cycle, three originating in the review
document itself, and one of them moved a pipeline order so that entity resolution would have degraded
to the ambiguous bare-form path — **a false correction was one merge away from shipping the exact
duplicate-manufacturing failure the design exists to prevent** (`tortoise#5014`; mechanism:
`tortoise`'s `docs/architecture/EXTRACTOR-V4-ARCHITECTURE.md` §16.2 — the section whose four binding
rules this one is taken from — and its evidence record, `tortoise`'s
`docs/architecture/REVIEW-CONSOLIDATED-2026-09-23.md` B2.1).

#### Exit Conditions — ALL Must Be True (Clean Completion)

- [ ] Last reviewer response was the skill's clean verdict — `NO ISSUES FOUND`, or the skill's defined equivalent (e.g. the verifier's `PASS`, the loop's `CLEAN`) — verbatim, not paraphrased
- [ ] If cycle 1 found any issues → at least 1 re-review cycle completed
- [ ] Cycle log posted: each cycle's issues and fixes documented

These conditions define a **clean completion** only. A convergence, stall, abort, or cap exit **that leaves issues unresolved** cannot satisfy them: it is an **escalation** exit — document the remaining issues and escalate (see Hard Cap). Such an exit may still be handed on where the skill's own path says so, but it is never reported as clean.

#### Hard Cap

**The skill's own bound always governs — this file only supplies a fallback.** The `proportional-gates` skill holds the **canonical** proportional table. A skill that says "no hard cap" but states a safety cap is **still governed by that cap** — "no hard cap" means no quality-gate ceiling, not no runaway guard. Only when a skill states no bound of any kind does the fallback **10** apply, and a skill that **explicitly declares itself uncapped** (`carousel-designer` — "No Cycle Cap … No arbitrary cap") is never capped by this file, and its own stop rules govern.

**One domain bounds by surface, not by count: the adversarial domain** (gate/enforcement code whose correctness is "an attacker cannot make it fail open" — argv/path/symlink resolution, working-tree discard, merge and verification gates). Its bound is **the declared threat surface, not reviewer exhaustion: 2 cycles** — the skill's own bound for that domain, canonical in `proportional-gates`, so the paragraph above still governs (this file imposes nothing tighter). Scoping declares the in-scope bypass classes and the classes explicitly out of scope; acceptance is **every declared class covered by a test + green CI**, not "the reviewer ran out of ideas". Residuals are **filed from cycle 1, not chased** — findings outside the declared surface are follow-up issues by default. A fresh reviewer that reproduces no in-scope bypass and confirms the declaration is covered exits `THREAT SURFACE COVERED` — this domain's defined clean equivalent. **When a merge rests on threat-list coverage rather than a literal `NO ISSUES FOUND`, say so plainly** in the PR body and the report (`[ADVERSARIAL-BOUND] cycles=<N> threats=<K> covered=<K> residuals=<#N,…|none>`); never present a bounded exit as an unbounded clean one. <!-- adversarial-bound: cap=2 -->

This is a **runaway guard, not a quality gate** — review cycles are how quality gets produced, so do not treat the cap as a target, and do not stop early because the count "feels high". Stop on (a) a clean exit (the skill's clean verdict — `NO ISSUES FOUND`, or its defined equivalent), (b) **convergence as the running skill defines it** (issues are a strict subset of the previous cycle's — no new dimensions or files; some skills define this only at their safety cap, e.g. `epic-plan`), (c) a stall signal the skill defines (`fingerprint-stall`, `honest-stuck`, `zero-progress`), (d) an abort the skill defines (`tool-unavailable`, `git-error`, `pr-closed`, fixer push failure), or (e) the bound. Never apply a bound tighter than the skill's own.

The bound applies to the **gate** — the loop, or the area under review — not to an individual reviewer process. Count every cycle (review round) for that gate — not every reviewer process: **dispatching a fresh reviewer does not reset, extend, or replenish the budget.** The fresh-context rule exists to defeat confirmation bias, not to hand the loop a new counter — a gate that has spent its bound has spent it no matter how many distinct reviewer processes were involved. A fresh reviewer is a new *reviewer*, never a new *loop*.

**(b)–(e) are escalation exits, not completions.** They do not satisfy the Exit Conditions above, and the loop must never be reported or handed off as clean or complete **while issues remain** (if the skill's own recovery path resolves them all and a fresh reviewer returns the clean verdict, that is a clean completion under (a)). (Where a skill labels its *zero-issue* exit "convergence" — e.g. `prototype-review` — that is a clean exit under (a), not this rule.) On a non-clean exit → **escalate** — to the orchestrator agent, or to a human wherever a skill requires one (the Auto-Continue pause conditions apply in addition). Document the remaining issues, then follow the skill's own path for that exit **first** — including any mandatory orchestrator recovery (`code-review` Step 6.5, `plan-review`'s deep-fix attempt) — and post **the exact marker the skill's own exit table defines at the point that path specifies**, where it defines one (`code-review` cap → `⚠️ Auto-fix reached this change's proportional cycle ceiling (N of B cycles) — blocking issues remain; escalate to a human`, and at the High row, whose cap is the canonical 10, `⚠️ Auto-fix reached the 10-cycle safety cap — unresolved issues remain; escalate to a human`; `test-review` cap → `⚠️ Test review capped at 10 cycles — N issues remain:`). Where the skill defines no marker for that exit, post `⚠️ <the skill's own name for the exit> after N cycles — M issues remain` and record the exit under the skill's own name. Use the skill's own label verbatim — do not invent a cap label for a convergence or stall exit, and do not relabel an exit the skill itself names otherwise:

- **Paths that require a human** (non-exhaustive: `plan-review` → Requires Human Input; `carousel-b2b-copy` → BLOCKED; `code-review` → its convergence exit needs human acknowledgement and its cap/stall exit surfaces to a human via its Step 6.5 recovery; `test-writing` → halts while a P0 remains): **do not proceed past that skill's own halt point.**
- **Paths that log-and-proceed** (`epic-plan`, `test-review`, `meta-framework-research`'s 3-cycle stall rule, `code-review`'s `adversarial-capped` exit — bounded by the declared threat surface, its `[ADVERSARIAL-BOUND]` disclosure being the marker — `test-writing` when only P1/P2 remain — **non-exhaustive**): continue **only** with the skill's own marker posted where it defines one, and the remaining issues — including any P0 — recorded in the artifact, exactly as the skill directs. A capped exit is never described as clean or complete.

#### FORBIDDEN — These Bypass the Quality Gate Entirely

- ❌ Run review → get issues → fix → declare done without re-dispatching reviewer
  This IS skipping the review. Fixing without re-reviewing = no review.

- ❌ Self-declare "I addressed the feedback" as completion
  Only "NO ISSUES FOUND" (or the skill's own clean verdict) from a fresh reviewer is a valid **clean-completion** signal. Convergence, stall, abort, and cap exits **that leave issues unresolved** close the loop only with the remaining issues documented and the skill's own path for that exit followed (see Hard Cap); a skill labelling its *zero-issue* exit "convergence" (e.g. `prototype-review`) is a clean exit.

- ❌ Re-review in the same conversation context
  Confirmation bias makes same-context re-review unreliable.
  Use the skill's mandated fresh-context dispatch (`task`, its MCP wrapper, or its verifier subagent).

---

## Response Conventions

- Begin every response with current time in `[HH:MM AM/PM]` format
- Announce skill invocations: "I'm using the [skill-name] skill to [purpose]."
- Announce sub-agent dispatches: "Dispatching sub-agent for [purpose]..."
- Announce data access before hitting external services / files outside the repo / sensitive files

---

## Research Discipline

**⛔ DO NOT call `web_search` directly. Route through the `research` skill instead.**

`research` is non-optional for any investigation that involves comparing, evaluating, deciding, or understanding something new. It provides problem reframing, adversarial queries, domain detection, and — critically — the cost gate. `web_search` has `sonar-deep-research` and `sonar-reasoning-pro` which cost $5–40+/call. The `research` skill defaults to $0.005 tools. Calling `web_search` directly bypasses this gate.

**Only exception — trivial single-fact lookup:** "What version is X?" "What port does Y use?" One answer, no analysis needed. For everything else: `research`.

**⛔ RESEARCH FIRST is a DISPATCH CONTRACT, not a habit — the dispatch path REFUSES a brief without it.**
A brief handed to a lane, a fixer, a reviewer, a background worker or a pane order must carry a
`RESEARCH FIRST` section (`INTERNAL:` + `EXTERNAL:` + a `RUNG:` line naming the tool) and a
`CONTRADICTION TEST:` line. Absent any of them the dispatch is refused with exit 80 by
`scripts/orchestrator-harness/brief-gate.sh` — no model call, no session, no claim — and the refusal
names every missing element and prints the block to paste. The canonical block is
`brief-gate.sh --section <lane|fixer|reviewer|worker>`; `templates/LANE-BRIEF.md` carries it for
controller-written briefs. If YOUR brief is refused, add what it names; do not route around the gate
(agent-infra#2258: two lanes in one day acted on a false premise — one re-derived a root the tracker
already held, one opened a duplicate PR — both brief defects, not lane defects).

**Sub-agents inherit this rule.** When dispatching sub-agents, instruct them to use the `research` skill — never let a sub-agent call `web_search` directly.

---

## Debugging Discipline

When encountering any bug, test failure, or unexpected behavior:

1. **Stop.** Do not attempt to fix it. Do not run commands to "investigate." Invoke the `debug-workflow` skill first — this applies systematic root-cause methodology. Guessing at a fix without structured diagnosis is the #1 source of regressions.
2. Present the diagnosed root cause and proposed fix for explicit approval **before writing any code.**
3. Do not proceed to implementation until the user confirms the diagnosis and approach.

This applies even for "obvious" fixes — the cost of a wrong diagnosis is higher than the cost of verification. Apparent symptoms routinely mislead; the skill enforces the methodology that finds what actually broke.

---

## ⛔ Reading verification state — a rollup is not a result

**A check-run rollup is NOT "is main green".** GitHub keeps every attempt (up to 1,000 per name per check suite, after which older ones are auto-deleted), so one commit can carry dozens of check-runs and the SAME job can hold both `failure` and `success`. **A re-run ADDS a red — it does not clear one** — so the more a flaky check is retried, the redder a green commit looks. Retrying is the correct response to flake and it makes the aggregate worse. (One commit carried dozens of check-runs, one job holding 10 attempts at measurement. Every re-run grows these counts — re-measure before quoting a number, or cite the mechanism and not the integers.)

Read the RUNS, on the EXACT sha, newest attempt per check:

1. `git fetch origin main && git rev-parse origin/main` — a bare `rev-parse` reads the LOCAL remote-tracking ref, only as fresh as the last fetch, and a stale sha yields a false **green** (the inverse error, and the more dangerous one). `git ls-remote origin refs/heads/main` needs no fetch.
2. `gh api "repos/<o>/<r>/commits/<SHA>/check-runs?per_page=100&filter=all" --paginate --jq '.check_runs[]'` — pin `filter=all` (the default is not all: on real commits it returned 26 of 40), and merge every page, because `--paginate` emits one JSON object PER PAGE.
3. **Resolve the workflow before grouping.** A check-run's `name` is the JOB name, not the workflow's, and two workflows can publish the same job name — grouping on the name alone merges them, so the newest of one masks the other (measured: two `packaging-smoke` runs, one `cancelled`, the other `success`). Take the run id from `details_url`, resolve its workflow, and group by **(app.slug, workflow, job name)**, newest attempt per group ordered by **`id`** — `started_at` is nullable (a queued attempt has none) and is a tiebreak only. A check-run with no resolvable Actions workflow groups under its `app.slug` alone; leaving any check-run ungrouped is unsafe, because a check that forms no group can never make the verdict red. Do not group by `check_suite.id`: every re-run gets its own suite, which would shatter one check into one group per attempt.
4. **Decide the verdict by POLARITY, not by vocabulary.** A group whose newest attempt is not `completed` is **in flight** (`queued`, `in_progress`, `waiting`, `requested`, `pending`). Of the completed ones, only `success`, `neutral` and `skipped` are green; `cancelled` and `stale` are non-red. **EVERY OTHER CONCLUSION IS RED — including one GitHub has not documented yet, and a null one.** That allow-list polarity is not invented here: it is the merge rail's, adopted after a real incident in which an unrecognised conclusion was neither red nor pending and a merge went ahead on it — so an unnamed value must never be allowed to fall through a gap.
   Read the surface in this order: **RED if any group is red** — a completed red is final, and nothing in flight can un-fail it; **otherwise NOT YET KNOWN while any group is in flight**; **otherwise GREEN only if the surface is non-empty and every group is non-red.** A missing check is not a green check: if the surface is empty, report that you read nothing there and stop — never extrapolate from absence to green.
5. Never `/commits/<sha>/status` — legacy endpoint: where CI is check-runs it returns `state=pending` with `statuses=0`, which reads as "not green" from a field that was never populated.

**What this rule does NOT decide: mergeability — and step 4's verdict is not a merge gate.** For "may I merge", read the rail, not this rule: `scripts/admin-merge.sh` groups checks by **`(app, name)`** and treats `{success, neutral, skipped, cancelled, stale}` as non-red. Its key merges two workflows that share a job name — the conflation step 3 above separates — and the rail states that as an accepted residual, so it is referenced here, not overridden. **Read the rail to merge; read this rule to know whether the tree is healthy.**

A per-name rollup answers *"has main EVER been red?"* — almost always yes — not *"is main green now?"*. **This false red has already produced a wrong "main is red" conclusion that stalled work on a green main** — the defect is `tortoise#4877`, and the instruction-file divergence it exposed is `agent-infra#1399`.

**⛔ WHEN THE QUEUE — NOT THE CODE — IS THE BLOCKER, REPRODUCE THE LANE AND MERGE ON THAT EVIDENCE.**
Owner ruling, 2026-10-27 (`agent-infra#2936`), first exercised on `tortoise#10184`, whose `docs` lane sat
`queued` behind 98 other runs while the repo held 6 in progress and `ci-queue-health` was *itself* pending.
An indefinite wait for a run the queue has not started is not a gate, it is an outage — so the lane's own
steps are run **locally**, and their output is posted as the evidence the merge rests on.
**OVERRIDES:** the rail's precondition that a merge wait for a run that TESTED the head (`admin-merge.sh`,
*"no run of the lane actually TESTED head"*) — when the queue is the ONLY reason no such run exists, local
reproduction of that lane is the substitute, and the PR states it rather than implying it.
It is bounded hard, and a lane that reads it as a general licence has read it wrong:

- **Review evidence stays mandatory and HEAD-BOUND.** The substitute replaces a *lane*, never the review
  gate: `record-review.sh` at the final head is what makes such a merge legitimate. A push invalidates it,
  so re-record after every fix.
- **Reproduce THAT lane's own steps and post their output.** *"It's docs-only"* is not evidence; the four
  `docs` steps are. A step that cannot be reproduced on this host is **declared, not skipped** — the pinned
  `lychee` has no arm64 build, so the link check was replaced by the three measurements that decide its
  verdict (no new links added, the one external URL resolves, the relative targets exist), and the PR says
  exactly that.
- **A check the change class CAN fail is not droppable.** The ruling names CI-only jobs of the `legal-e2e`
  class as bureaucracy *for a diff they cannot test*; it does not license skipping a check that could catch
  this change.
- **Do not make bypassing a local safety gate a habit.** The ruling names the QUEUE as the blocker, never the
  `#1484` script-backdoor guard or the admin-merge evidence gate. Where those cannot be satisfied inside a
  session, say so in the PR and record why — do not quietly route around them and report a clean run.

- **⛔ A MEASUREMENT ARTIFACT IS NOT A STATE — never take a destructive action from a FIRST-MATCH
  reading.** This has now happened **three times on healthy systems**, each caught only because the
  read was re-measured before acting: (1) a compaction **summary** — a cache of a past read, not a
  measurement — nearly got a *healthy* Tortoise graph rebuilt; (2) `pgrep -f '[o]rch-loop\.sh' |
  head -1` produced "**6 controllers for 3 cells**" and nearly got healthy controllers killed (the
  identical bug had **already** been fixed once in `deploy-mac-orchestrator.sh`); (3) the first
  `pgrep` match kept returning a **stale `tmux new-session` client** that lingered ~35 min carrying
  an *old* `MAX_LANES`, making a correctly-configured controller read as misconfigured. In all three
  the datum was real and the **inference** was wrong — which is why the rule is about the read, not
  the number. Before ANY kill / reap / rebuild / prune / reset / relabel: enumerate **every** match
  with its `ppid` **and** `cmdline` (a harness controller is a **3-deep chain** — `tmux client →
  bash -c → orch-loop.sh` — and the DEEPEST process is the controller), prefer the tool's **own
  status verb** over your own count, state **what would be lost if the reading is stale**, and
  re-measure **at the moment of action**. **A failure that repeats inside one short window is the
  signature of an artifact, not a durable state** — and an over-read symptom plus a
  plausible-sounding remedy is exactly how an agent talks a human into a destructive action on a
  healthy system.

## ⛔ Reading lane liveness — an ABSENCE is not a verdict

**A lane can be live and absent from every population the fleet can enumerate.** An orchestrator
lane runs `pi -p --no-session` (`lane.sh` / `fix-one.sh` / `merge-one.sh`), so it writes **no
transcript and no cmux store record**: no session id to enumerate, no JSONL to grow, and no place in
any population built from the cmux hook store or `~/.pi/agent/sessions/`. Measured 2026-10-15: the
scheduled report listed `lanes=22` with the live `fix-<pr>` lane absent, and a controller read
`grep -l <branch> ~/.pi/agent/sessions/*/*.jsonl` returning nothing as CLEAN — over a fixer that was
committing to that branch.

So **grepping the sessions directory for a branch is not a liveness test**, and "the report does not
list it" is not "nobody is on it". For *which lanes exist*, read the durable, holder-authored
**ref-claim registry** — `refs/claims/<pr>-<sha12>`, written by agent-infra's
`scripts/orchestrator-harness/claims.sh` and read by its `tools/fleet/claim_lanes.py`. **Every claim
verdict is an abstention**: `claim-held` asserts a declared **ownership** window, never that a process
is alive, and `claims-unreadable` / `no-claim-visible` / `claim-owner-unparseable` /
`holder-on-foreign-box` / `claim-holder-unverifiable` are **not** freedom — an absent key is a
HEAD-scoped, transient fact (refs are deleted on release and pruned on expiry, and a live lane has a
*designed* no-claim window between `fix-one.sh`'s release and `merge-one.sh`'s re-claim).

**One verdict function** (agent-infra's `tools/fleet/liveness.py`), never a second: a reader acquires
evidence, it does not decide a state. The five states, the ordering, the abstention doctrine, and the
four inputs: agent-infra's `docs/ops/fleet-liveness.md`.

The paths above are **agent-infra's**; a consumer repo that has not materialized that tree still owes
the RULE — an absence is not a verdict, and a lane's absence from a population is not evidence about
the lane.

## Sub-agent Dispatch

Use Pi's `task` tool for all sub-agent work. Sub-agents have isolated context → construct their prompts with exactly what they need.

**⛔ Model override prohibition:** Do NOT pass `model: "claude-sonnet"` or any non-DeepSeek model to the `task` tool. Only DeepSeek is configured for general use. Overriding will cause the sub-agent to fail with "No API key found for anthropic."

<!-- REPO-SPECIFIC: Add tool-specific exceptions here (e.g., design_reviewer for Claude Opus) -->

## Batch Implementation & Parallel Dispatch

**Never ask "sequential or parallel?" — always plan the optimal parallelization yourself.** The default is maximum parallelism. The user started the session to get work done, not to manage a task queue.

### Decomposition maps parallelism

When decomposing work (epic or multi-issue batch), explicitly map what can run in parallel:
- Scope/plan multiple independent issues simultaneously via sub-agents
- Run one issue end-to-end while scoping others in parallel
- Launch an issue as soon as its blocker is done — don't wait for the full batch

### Maximize sub-agent utilization

- While waiting for a human gate (UX approval, design review) → dispatch sub-agents for other independent work
- Non-blocking research, scoping, or implementation on unrelated issues runs in background
- The controller (you) handles human interaction; sub-agents handle everything else

### Dependency-aware launch

The `**Depends on:**` field in any child issue body (or the `Depends on` column in `epic-decompose` output) is the parallelism map — if no dependency is listed, the issue is safe for parallel dispatch.
When issue B depends on issue A's scoping/plan but not its implementation:
1. Launch issue A's scoping + issues C, D, E scoping in parallel
2. As soon as issue A's scoping returns → immediately launch issue B
3. Don't wait for C/D/E to finish — B's blocker is gone, B starts now

Implement issues directly inline where practical. Group related micro-issues into a single batch PR. For cross-session epic batches, use `epic-executor/SKILL.md`.

---

## Data Access Transparency

Announce with a brief FYI **before** accessing:

1. **External services** — MCP servers, web searches, API calls
2. **Files outside the project directory** — anything not under the current repo
3. **Sensitive files** — `.env`, credentials, keys, tokens, secrets

Format: `📡 [source] — [what] — [why]`

Does **not** apply to: routine project file reads, git operations, local shell commands, context7 doc lookups.

---

## File Pre-Existing Bugs

When you encounter a **pre-existing bug** (not introduced by your current work), **file a GitHub issue for it.** Do not treat "out of scope" as a reason to skip. Known bugs carried silently forward accumulate into build rot. **Unless the symptom check above shows it is a symptom of an existing issue** — then add your evidence as a comment on that issue instead; filing is the duty only when no root already exists.

**Admission control applies to machinery findings — see Product Over Process.** Classify the *machinery* finding A or B *before* filing. **A** — file it, always (unless the symptom check above shows it is a symptom of an existing root). **B** — file it only with a stated consequence; if the honest answer is "nothing but time", do not file it. A pre-existing **product** bug is filed as before — **unless the symptom check above shows it is a symptom of an existing issue** — the A/B test governs machinery, not the product.

---

## Editing Rules

- **Never use sed for multi-line code changes.**
- **Never use `git add -A`** — always stage specific files.
- **Prefer the `edit` tool over `write`** for targeted changes to existing files.
- **Commit messages: always `git commit -F <file>` — never `-m`, never a heredoc.** The message
  message file goes in a **repo- and worktree-unique temp directory**, never a shared
  `/tmp/commit-msg-<branch>.md` — a branch name is unique per repo, not globally, so concurrent
  sessions in different repos silently overwrite each other's message (#729). The path is
  `${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md` —
  `write` the message there (the write tool creates the directory), then commit with `-F`.
  `--absolute-git-dir` is per-repo AND worktree-aware — a linked worktree gets *its own* gitdir —
  and its `cksum` names the directory, so cross-repo and cross-worktree collisions cannot happen
  in practice — a 32-bit digest makes a clash a ~1-in-4-billion coincidence rather than the
  *guaranteed* clash the old fixed path produced.
  ⛔ **Never put it under `.git/`.** That was the first attempt and it is refused: the
  `main-worktree-guard` extension freezes any `.git/…` write as *hub git-metadata* for every
  unhatched session — the fleet default for `task` children — so the mandated `write` would be
  blocked and the agent left to improvise. `$TMPDIR` keyed by the git-dir checksum gives the same
  uniqueness, entirely outside every checkout. (Two sessions in the *same* worktree on the *same*
  branch still share the file; that case was always racy at the index level anyway.)
  ⛔ **Every bash tool call is a FRESH SHELL, and one call must not both assign and commit.** A
  `MSG=…` set in one call is **unset** in the next, so a later `git commit -F "$MSG"` commits from
  an **empty path** and `rm -f "$MSG"` silently removes nothing (both verified). Assigning `MSG`
  in the same call as the commit is *also* refused by the verification gate ("in-batch mutation
  chain"). So put the substitution **inline in the commit command** — no variable:
  `git commit -F "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"`,
  then delete the message file in a **separate** call, re-deriving the path the same way.
  Both `-m "…"` and heredocs pass the message
  through the shell first — backticked spans run as command substitution, `$VAR`/`$(…)` expand,
  `${…}`/`{{ }}` break — and the failure is **silent**: the substitution yields an empty string,
  git accepts the mangled result, and only a human reading the log sees the hole. The
  `commit-msg` hook warns on the signature (unbalanced backticks, or a doubled space where inline
  code should be) when husky hooks are installed — do not rely on it running (#672). On a hit:
  amend **before** pushing; if it is already pushed, post a correction note instead of silently
  force-pushing. Worked example: `skills/commit-workflow/workflow/02-commit-pr.md`.

## Search

A recursive search is the fleet's most expensive habit. An ignore-blind walk started at a repo root
descends into `.worktrees/*/node_modules` — 169 GB in one checkout — and the #1069 live evidence shows
three concurrent sessions holding load ~18 on 10 CPUs for 80 minutes. See `docs/ops/load-policy.md`.

**Rule: never start a recursive search at a root you have not bounded.** Prefer an index-bounded
primitive; if you must walk, bound the walk explicitly.

### Use

Every command here is bounded — by the index, by an explicit non-root start point, or by an explicit
exclusion.

```bash
rg -n 'pattern' -g '*.py'                 # honours .gitignore; .worktrees/ is skipped as a hidden path
git grep -n -e 'pattern' -- '*.py'        # reads the repo index; the fallback when `rg` is absent
git ls-files --others --exclude-standard  # the untracked files `git grep` cannot see
rg --files -g '*.ts'                      # enumerate files instead of searching them

# Explicitly bounded walking, for the questions the primitives above cannot answer
grep -rn 'pattern' --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.worktrees
find src/ -name '*.ts'                    # an explicit, non-root start point
find . -maxdepth 3 -name '*.ts'           # a depth bound
find . \( -name node_modules -o -name .worktrees \) -prune -o -name '*.ts' -print
```

`git grep` and `git ls-files` see **tracked** files only — pair them with
`git ls-files --others --exclude-standard` when untracked files matter, and note that `git grep`
requires a git work tree. `rg`'s dialect is Rust, not BRE: alternation is `|`, not `\|`, and
`--include` is spelled `-g`. Re-check a translated pattern against that switch.

### Avoid

These shapes walk the whole tree. A runtime guard (`extensions/search-guard`) refuses them and names a
replacement.

```bash
grep -r 'pattern'
grep -rn 'pattern' .
find . -name '*.ts'
find / -name '*.ts'
```

If the guard blocks a search you believe was legitimate, the block reason names the bounded form to use
instead. `SEARCH_GUARD_DISABLED=1` is the documented escape hatch and should stay rare.

## Tool Quality & Retirement

- **Two-strikes rule:** If any pipeline tool or script requires >1 manual-fix cycle per use, file a retirement issue. Don't accumulate patches.

---

## Documentation Filing Protocol

Before recording any information, find the correct home first:

1. **Behavioral rule for agents?** → in this file (`AGENTS.md`)
2. **Does a `docs/` file already cover this topic?** → Check your docs index and update that file
3. **New concept with no existing doc?** → Prefer extending an existing `docs/` file over creating a new one. If a new file is genuinely needed, register it in your docs index
4. **Raw coding gotcha** (trips you up mid-code, no natural docs home)? → One concise line in `MEMORY.md`

<!-- REPO-SPECIFIC: Add your doc routing rules (e.g., "For topic-to-file routing, see docs/00_index.md") -->

### Entity Annotation

When writing or updating any doc in `docs/`, auto-populate entity metadata from session context:

- `aboutSubjects` — from session team context, `ownedBy` in frontmatter, team detected from file path
- `aboutObjects` — from governing agreement, parent epic reference, repo name
- If ambiguous, ask: "This doc references entity X — is that correct?"
- Never leave entity fields empty when context is available

<!-- REPO-SPECIFIC: Reference your ontology doc for entity types and predicates. Canonical ontology: tortoise repo `docs/ONTOLOGY.md` (v3.1) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§1.1 types, §2.2 predicates). In repos that keep a docs/teams tree (eldato layout), reference `docs/teams/<team>/domains (S1)/<domain>/ONTOLOGY.md` if present. -->

## Memory Hygiene

- `MEMORY.md` must stay under 150 lines.
- `MEMORY.md` = raw coding gotchas only (things that bite mid-code). Not an implementation log, not a docs index.
- Format: `[category]: [what broke] → [root cause] → [the fix]`

## Memory Contracts

After key triggers, write back to the correct target. **Verifier-triggered, not agent-triggered.** Append, never rewrite. Contradictions escalate via `⚠️ CONTRADICTION:` prefix. Cross-domain: explicit only.

Format: `[category]: [what broke] → [root cause] → [the fix]`

<!-- REPO-SPECIFIC: Add your repo's triggers/targets here.
| Trigger | Target |
|---------|--------|
| Task complete (code gotcha) | `MEMORY.md` (cap 150 lines) |
| Task complete (no gotcha) | Plan doc `## Learnings` |
| Bug fixed | `docs/teams/<team>/domains (S1)/<domain>/gotchas.md` (eldato layout) + `MEMORY.md` |
| Session complete | Your session postmortem + `MEMORY.md` for friction patterns |
-->

<!-- REPO-SPECIFIC: Add human-gated vs agent-autonomous filing rules here -->

## Key Differences from Claude Code

| Claude Code | Pi |
|---|---|
| Agent tool / Skill tool | `task` tool for sub-agents, skills loaded from files |
| `model: sonnet/opus` frontmatter | Ignored — Pi uses its own model selection |
| `allowed-tools` with granular Bash | Use Pi's tool names: `read write edit bash grep find web_search web_fetch todo_write task` |
| MCP servers via `.mcp.json` | MCP tools available via mcp-client extension |
| `superpowers:skill-name` references | Use skill name directly (e.g., `commit-workflow`) |

---

<!-- 
REPO-SPECIFIC — Add below this line:
- Skill compliance table (trigger | skill | consequence)
- Repo-specific gates (Tortoise, DB migrations, deploys, worktrees)
- Component catalog references
- UX design gate
- Migration conventions
- CI pipeline references
- Tool-specific exceptions (design_reviewer, etc.)
- Memory contracts and filing targets
- Ponytail mode / session hooks
-->
