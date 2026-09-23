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

**Moving is not a license to build machinery.** "Keep going" means keep making progress on the **product** — not keep adding, fixing, auditing, or documenting *process*. If the only work in front of you is category B, that is a real reason to stop and say so — say it plainly rather than manufacturing more process to look busy.

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

## ⛔ SESSION RECAP PROTOCOL: don't recount trivia about what happened, present state and decisions.

If you're going to present a recap at the end of a turn or session, don't say things like "Cycle 3 found the worst bug of the whole lane" or "Two corrections I had to make about my own work" unless they're changing the scope, architecture or UX that was agreed. Instead present the state, key design principles/decisions made, and cleanly present any user decisions needed (see USER QUESTIONS PROTOCOL) or next steps. If the next steps are just to continue, do not stop and just continue (see NEVER PAUSE WITHOUT A REASON)

---

<!-- REPO-SPECIFIC: Add your skill compliance table here. Map trigger → skill → consequence of skipping. -->

<!-- REPO-SPECIFIC (agent-infra): vendored swarm artifacts — see VENDOR.md -->
**Vendored swarm artifacts** (scripts/parallel_work_check.*, scripts/checkout_guard.sh, connectors/): see `VENDOR.md` — base rev + patch ledger + drift gate (`scripts/check-vendor-drift.sh --manifest`).

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

Skill length is not an excuse — reading a 700-line skill is cheaper than bypassing a pre-flight check. Skills with review loops have mandatory quality gates. **Review cycles are not optional.** When a skill describes a review-fix loop, you run it to convergence. Fixing issues and self-declaring "done" without re-dispatching a fresh reviewer is a bypass — not a review. Only "NO ISSUES FOUND" from a fresh-context reviewer — or the skill's own defined clean verdict — is a **clean completion**; convergence and cap exits **that leave issues unresolved** are escalation exits, never completions (see Hard Cap).

### Review Loop Protocol — MANDATORY

Skills that describe review cycles contain **mandatory quality gates**, not suggestions. Do not skip review cycles. Do not emit a plan or content as "done" until all review cycles pass clean, or the skill's own escalation path (cap, convergence, stall, or abort) is followed with the remaining issues documented — a capped exit is never reported as clean.

#### Fresh-Context Task Dispatch

Every review cycle MUST re-review in a FRESH context — via `task` where the skill dispatches one, or the skill's mandated mechanism (its MCP wrapper, or its verifier subagent). The reviewer has no memory of prior cycles, no investment in defending prior fixes. This prevents confirmation bias.

- Same-model self-review in the same conversation degrades without an external signal
- The model defends prior decisions rather than critically re-evaluating
- `task` spawns `pi -p` in a new process with no session memory — the closest available proxy for an independent reviewer

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

**(b)–(e) are escalation exits, not completions.** They do not satisfy the Exit Conditions above, and the loop must never be reported or handed off as clean or complete **while issues remain** (if the skill's own recovery path resolves them all and a fresh reviewer returns the clean verdict, that is a clean completion under (a)). (Where a skill labels its *zero-issue* exit "convergence" — e.g. `prototype-review` — that is a clean exit under (a), not this rule.) On a non-clean exit → **escalate** — to the orchestrator agent, or to a human wherever a skill requires one (the Auto-Continue pause conditions apply in addition). Document the remaining issues, then follow the skill's own path for that exit **first** — including any mandatory orchestrator recovery (`code-review` Step 6.5, `plan-review`'s deep-fix attempt) — and post **the exact marker the skill's own exit table defines at the point that path specifies**, where it defines one (`code-review` cap → `⚠️ Auto-fix reached the 10-cycle safety cap — unresolved issues remain; escalate to a human`; `test-review` cap → `⚠️ Test review capped at 10 cycles — N issues remain:`). Where the skill defines no marker for that exit, post `⚠️ <the skill's own name for the exit> after N cycles — M issues remain` and record the exit under the skill's own name. Use the skill's own label verbatim — do not invent a cap label for a convergence or stall exit, and do not relabel an exit the skill itself names otherwise:

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

**A check-run rollup is NOT "is main green".** GitHub KEEPS every attempt, so one commit can carry dozens of check-runs and the SAME workflow can hold both `failure` and `success`. **A re-run ADDS a red — it does not clear one** — so the more a flaky check is retried, the redder a green commit looks. Retrying is the correct response to flake and it makes the aggregate worse. (One commit carried dozens of check-runs, one workflow holding 10 attempts at measurement. Every re-run grows these counts — re-measure before quoting a number, or cite the mechanism and not the integers.)

Read the RUNS, on the EXACT sha, newest attempt per check:

1. `git fetch origin main && git rev-parse origin/main` — a bare `rev-parse` reads the LOCAL remote-tracking ref, only as fresh as the last fetch, and a stale sha yields a false **green** (the inverse error, and the more dangerous one). `git ls-remote origin refs/heads/main` needs no fetch.
2. `gh api "repos/<o>/<r>/commits/<SHA>/check-runs?per_page=100&filter=all" --paginate` — pin `filter=all` so "every attempt" is stated rather than inferred from the default.
3. Group by **app + job name** and take the newest per group, ordered by **`id`** — `started_at` is nullable (a queued attempt has none) and is a tiebreak only.
4. **Decide the verdict, don't infer it.** GREEN means every group's newest attempt is `status == "completed"` AND `conclusion` is one of `success`, `neutral`, `skipped`. NOT green: `failure`, `timed_out`, `action_required`, `cancelled`. **Any newest attempt still queued or in progress means NOT YET KNOWN** — report that. Guessing a verdict from a pending check is the same error as reading a rollup.
5. Never `/commits/<sha>/status` — legacy endpoint: where CI is check-runs it returns `state=pending` with `statuses=0`, which reads as "not green" from a field that was never populated.

A per-name rollup answers *"has main EVER been red?"* — almost always yes — not *"is main green now?"*. **This false red has already produced a wrong "main is red" conclusion that stalled work on a green main** — the defect is `#4877`, and the instruction-file divergence it exposed is `#1399`.

## Sub-agent Dispatch

Use Pi's `task` tool for all sub-agent work. Sub-agents have isolated context → construct their prompts with exactly what they need.

**⛔ Model override prohibition:** Do NOT pass `model: "claude-sonnet"` or any non-DeepSeek model to the `task` tool. Only DeepSeek is configured for general use. Overriding will cause the sub-agent to fail with "No API key found for anthropic."

<!-- REPO-SPECIFIC: Add tool-specific exceptions here (e.g., design_reviewer for Claude Opus) -->

<!-- REPO-SPECIFIC (agent-infra): builtin task-dispatch ledger + task-session retention (#783) -->
## Durable Dispatch Record & Task-Session Retention (#783)

**Every builtin `task` dispatch that settles abnormally writes one immutable outcome row**
— one row per spawn *attempt*, not per dispatch. The row identity is
**`dispatchId` + `childSessionId` + `attempt`** — never `dispatchId` + `attempt`, because
`attempt` is a **per-leg** ordinal: `retry()` restarts it at 1 on every leg (primary, each
failover hop, and the provider-fallback leg), so a multi-leg walk writes several `attempt=1`
rows under one `dispatchId`. (On the `--no-session` degrade, `childSessionId` is null for
every attempt, so the identity degrades to `dispatchId` + `attempt`.) Dispatches that settle
successfully write no row — **except the success-but-silent settle** (exit 0, empty stdout,
no `sessionEnded`), which is recorded as `reason: "clean-empty"` because it is
indistinguishable from a silent loss to a ledger reader. The row lands in the
**existing** dispatch ledger, `~/.pi/agent/audit/provider-failover.jsonl` (JSONL,
`event: "dispatch-outcome"`; gate `DISPATCH_LEDGER`, default ON) — never a new file. Its
`dispatchId` is the dispatch's `TASK_HEARTBEAT_NONCE`, so it joins the #512 usage and #476
failover rows on one key in one file (#796 consumes it). The ledger is **append-only**: a written
row can never be edited, so a reader that needs to **amend** an outcome must append a
**follow-up row keyed by `dispatchId` + `childSessionId` + `attempt`** — never rewrite history.

**Each dispatch also keeps its child's transcript** under `$TASK_SESSION_ROOT` (default
`~/.pi/agent/task-sessions/`), a **mode 0700** root with one `<uuid>/` directory per spawn
attempt.

**Retention is owned, bounded, and dry-run by default.** Owner: **the organisation-design-team
operator on call for agent-infra**. Bounds: `TASK_SESSION_MAX_AGE_DAYS` (7) **or**
`TASK_SESSION_MAX_BYTES` (2 GiB), whichever binds first, evicting oldest-non-live first. The
shipped job (`com.eldato.pi-task-session-prune`) is **DRY-RUN**;
**arming it is a separate manual step owned by that operator** (with a dated trigger). Until it is
armed the bounds do not bind — a known, accepted state, not a silent one.

**Tolerance rule:** rows written by other framework versions may **lack identity fields**
(`dispatchId`, `childSessionId`, `attempt`, `dispatchClass`). Readers must **tolerate absent
fields** and must not throw on a missing one.

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

When you encounter a **pre-existing bug** (not introduced by your current work), **file a GitHub issue for it.** Do not treat "out of scope" as a reason to skip. Known bugs carried silently forward accumulate into build rot.

**Admission control applies to machinery findings — see Product Over Process.** Classify the *machinery* finding A or B *before* filing. **A** — file it, always. **B** — file it only with a stated consequence; if the honest answer is "nothing but time", do not file it. A pre-existing **product** bug is filed as before — the A/B test governs machinery, not the product.

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
<!-- REPO-SPECIFIC (agent-infra): doc routing — this repo has no docs index. -->
**Fleet session liveness** (the five states, the identity ordering, the abstention doctrine): see `docs/ops/fleet-liveness.md`.

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
