---
disable-model-invocation: true
name: human-input-framework
description: "Reference taxonomy for when coding workflow skills should pause for human input vs proceed autonomously. Not invoked directly — consumed by other skills."
subjects.team: organisation-design-team
type: reference
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 2.1.1
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

<!-- ported from the primary repo -->
> **Source:** Canonical copy at `skills/human-input-framework/SKILL.md`.

# Human Input Decision Framework

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

## Overview

Shared reference defining when agents should pause for human input during coding workflows. Other skills inline the taxonomy from here — this file is the canonical source of truth.

**This skill is NOT invoked directly.** It exists so there is one authoritative definition that skill authors reference when creating or updating overrides.

**v2.0.0 — Research-Before-Ask Protocol:** Before pausing for ANY taxonomy-matched decision, the agent MUST first research. Many decisions that appear ambiguous have clear answers from internal codebase patterns, existing project conventions, or external best practices. Research resolves most cases; only genuinely ambiguous high-stakes decisions should reach the user.

---

## Research-Before-Ask Protocol (MANDATORY — runs BEFORE any pause)

**When a taxonomy match occurs, do NOT pause immediately. Run this protocol first:**

### Step 1 — Internal Research
Search the codebase for existing patterns, conventions, or prior decisions:
- `grep` for similar implementations, naming conventions, architectural patterns
- Check `docs/` for relevant specs, ADRs, or conventions
- Check `CLAUDE.md` and `MEMORY.md` for documented patterns
- Look at recent PRs or git history for similar decisions

### Step 2 — External Research
If internal research doesn't yield a clear answer, fire targeted Perplexity queries:
- Best practices for this specific pattern/decision
- How comparable products or projects handle it
- Known failure modes or anti-patterns
- Use `perplexity_research` (3+ queries) for medium-impact decisions; `perplexity_search` for quick lookups

### Step 3 — Decision
Based on research:

| Confidence | Action |
|-----------|--------|
| **>80% confidence** — research yields a clear, unambiguous answer | Apply the decision. Note it with a `ponytail:` comment citing the research source. **Do NOT pause.** |
| **50-80% confidence** — research favors one option but alternatives exist | Apply the best-supported option. Note: "Researched [topic]. Chose [X] because [research finding]. Alternative [Y] would [trade-off]." **Do NOT pause.** |
| **<50% confidence** — research is inconclusive or options have equally strong trade-offs | **Pause** with structured question. Present the research findings and the remaining ambiguity. |
| **P0 consequence** — data loss, security breach, irreversible schema change, large cost impact, legal/compliance | **Pause regardless of research confidence.** These gates are absolute. |

### Step 4 — If Pausing
When pausing is necessary, present:
- The research findings (what was found, what remains ambiguous)
- Structured options per `question-format` protocol
- A recommendation with rationale

**Never pause with a bare question.** Every pause must include: what was researched, what was found, and why the decision still needs human input.

---

## Taxonomy — What Requires Human Input (After Research-Before-Ask)

Research first, then pause ONLY if research doesn't yield a clear answer OR the consequence is P0:

1. **Ontology changes** — new tables, columns, relationships, semantic meaning changes
2. **UX changes** — visible user-facing behavior/layout/flow changes not explicitly requested
3. **One-way doors** — destructive operations, data migrations, schema drops, force pushes
4. **Third-party dependencies** — new API integrations, service subscriptions
5. **Cost impact** — changes increasing recurring costs by >$1-3/month
6. **Scope expansion** — implementing beyond what was requested

**Tie-breaking rule (UPDATED):** When uncertain whether a decision matches the taxonomy, RESEARCH FIRST. If research yields a clear answer (>80% confidence), apply it. Only pause if research is inconclusive OR the decision is P0 (data loss, security, irreversible, cost >$10/month, legal/compliance).

**Everything else** → Agent decides autonomously with a brief note explaining the choice, open to iteration if the user disagrees.

---

## "Work On It" Response Protocol

When human input is required (research was inconclusive on a taxonomy-matching decision) and the user says "work on it":

### First "work on it"
Surface each pending decision in structured format:

```
**Decision: [short title]**
- **Research findings:** [what was found — internal patterns, external best practices]
- **Options:** [2-4 concrete choices]
- **Analysis:** [1-2 sentences on trade-offs]
- **Recommendation:** [which option and why, citing research]
```

Wait for user to pick an option or provide custom direction before proceeding.

### Second "work on it" (without answering questions)
Agent picks its own recommendation for each unanswered question, notes the choices clearly with:
> "Proceeding with my recommendations since no specific direction was given. These choices can be revisited — just let me know."

Then continues with implementation.

---

## Examples (Updated for v2.0.0)

| Task | Taxonomy Match? | Research | Behavior |
|---|---|---|---|
| Change a CSS class name | No | — | Proceed, brief note |
| Add a new DB column matching existing pattern | Yes — ontology | Internal: found 3 similar columns in same table | Apply pattern, note: "ponytail: following existing pattern from [table].[col]." Do NOT pause. |
| Add a new DB column with novel semantics | Yes — ontology | Internal: no pattern. External: Perplexity finds clear best practice. | Apply best practice, note: "Researched [topic]. Pattern from [source]." Do NOT pause. |
| Add a new DB column with multiple valid approaches | Yes — ontology | Research inconclusive — 2 valid patterns with different trade-offs | Pause with structured question + research findings |
| Drop a production table | Yes — one-way door (P0) | — | Pause regardless. P0 gate is absolute. |
| Refactor hook to use useCallback | No | — | Proceed, brief note |
| Integrate Stripe for payments | Yes — third-party + cost (P0) | — | Pause regardless. P0 gate is absolute. |
| Change button label text | Yes — UX (tie-breaking) | Internal: check existing button patterns. External: Perplexity for UX best practices. | If research yields clear answer → apply, note. If ambiguous → pause with structured question. |
| Fix a typo in error message | No | — | Proceed, brief note |
| Add retry logic to existing API call | No | — | Proceed, brief note |
| Switch from REST to GraphQL | Yes — one-way door + scope (P0) | — | Pause regardless. P0 gate is absolute. |

---

## P0 Gate — Absolute Stops (Research Cannot Override)

These decisions ALWAYS pause for human input, regardless of research confidence:

| Category | Examples |
|----------|----------|
| **Data loss risk** | Dropping tables/columns, destructive migrations, deleting user data |
| **Security** | Auth model changes, permission grants, credential handling |
| **Irreversible changes** | Schema drops, force pushes, production data modifications |
| **Large cost impact** | New paid services >$10/month, API usage that could spike billing |
| **Legal/compliance** | Data handling changes, privacy implications, terms of service |

When a P0 gate is hit, research is still conducted and presented, but the decision ALWAYS pauses.

---

## Approval Routing — Canonical

> **This is the canonical copy** — consuming skills inline a short operational excerpt and cite this
> section (consumer registry in "Inlining Instructions" at the end of this file).
> Verified against `$SWARM_ROOT/operations/coordination/approval.py` (swarm `origin/main`, 011d69e4)
> and `agent-infra/extensions/slack-bridge/index.ts` + `socket-mode.ts` — 2026-09-13.

When a human gate fires, the agent surfaces the request by invoking the approval router.

### Invocation (portable — works from ANY repo checkout)

```bash
python3 -c "
import os, sys
sys.path.insert(0, os.environ.get('SWARM_ROOT', os.path.expanduser('~/swarm')))
from operations.coordination.approval import request_approval
request_approval('<role>', artifact='<artifact>.md', context='<gate> approval', requires_human=<bool>)
print('Approval request created')
"
```

⛔ The bare `from operations.coordination.approval import …` resolves only when CWD *is* the swarm
checkout — from an agent-infra checkout it raises `ModuleNotFoundError: No module named 'operations'`.
Always use the `sys.path` form above. For escalation-chain routing instead of auto-approval, prefix the
invocation with the env var: `APPROVAL_AUTO_APPROVE=0 python3 -c "…"` (see semantics below).

### One store, two transports

| | |
|---|---|
| **Store** | `~/.swarm/approvals/<slug>.json` (0600, per-repo; `SLACK_APPROVAL_FILE` overrides). ⚠️ **The two sides derive `<slug>` differently, so by default they do NOT share a file** — the Python router uses the `owner/repo` form (`_detect_repo()` → `daniel-ospina/agent-infra` → `daniel-ospina_agent-infra.json`), the slack-bridge uses the bare repo name (`repoNameFromUrl()` → `agent-infra.json`). **Pin `SLACK_APPROVAL_FILE` to one path if you are relying on Slack** — otherwise the bridge never sees the router's request, and the gate stalls (agent-infra #956). |
| **Transport A — file** | `request_approval()` writes the record; `review_approval(id, 'approved'\|'rejected', feedback)` writes the verdict. |
| **Transport B — Slack (optional)** | The slack-bridge approval poller posts `pending` records **whose reviewer is `human` or unset** (`index.ts:855`) to `SLACK_APPROVAL_CHANNEL` / `SLACK_CHANNEL` every `SLACK_APPROVAL_POLL_MS` (default 5000ms) when `SLACK_BOT_TOKEN` is set. A chain-routed pending is Slack-bound only when the role it was assigned *is* `human` — true for a top-of-chain requester like `team-strategist`; one assigned a role (e.g. `product-strategist`) is seen but not posted. Accept/Reject buttons (Socket Mode, needs `SLACK_APP_TOKEN`) write the verdict into the store. Only `pending` records are posted — auto-approved ones never reach Slack. |

The poller starts independently of `SLACK_BRIDGE_DISABLE` (stopped only by `SLACK_APPROVAL_DISABLE=1` or
pi print mode — i.e. task sub-agents get no Slack). The Socket Mode button receiver additionally
requires `SLACK_BRIDGE_DISABLE != 1`.

### Status semantics — what actually gates on a human

| Condition | reviewer / status | Reaches a human? |
|---|---|---|
| `requires_human=True` | `human` / `pending` | **Yes** — hard checkpoint, never auto-approved |
| Escalation keyword (`delete`, `deploy`, `destroy`, `migrate`, `release`) in `artifact`/`context` | `human` / `pending` | **Yes** |
| Default — `APPROVAL_AUTO_APPROVE` unset (it **defaults to `1`**) | `policy:auto` / `approved` | **No** — resolved immediately, at request time |
| `APPROVAL_AUTO_APPROVE=0` | next role in the escalation chain (`chain[1]`) / `pending` | **Depends on the requester** — it pends for `reports_to` (`approval.py:301`): `product-strategist` for `product-implementer`, but **`human` directly** for a top-of-chain role such as `team-strategist`. Only `chain[1]` is ever assigned, so nothing walks the chain further. |

⚠️ **`requires_human=False` under the default config does NOT create a human checkpoint** — it
auto-approves, unless an escalation keyword appears (row above). A gate that must genuinely wait for a
human MUST pass `requires_human=True`. **Human gates are never rate-limited and never auto-approved**:
`requires_human=True` pends unconditionally, and nothing throttles a gate — `_notify()` accepts a
`rate_key` and ignores it.

### The notification is a banner, not a dialog

When — and only when — a record is left `pending`, `_notify()` runs:

```
osascript -e 'display notification "<role> requests approval for <artifact>" with title "Approval Needed"'
```

That is a macOS **notification banner**. It has **no buttons, no "Open"/"Dismiss", and no answer
path**; it is best-effort (`capture_output=True`, exceptions swallowed, 15s timeout) and silently
no-ops on non-macOS/CI/SSH.

A `display dialog … buttons {"Open", "Dismiss"}` **did** exist here (swarm `f1aec8de`, 2026-08-06) and
was replaced by this notification in the swarm #1402 rollout (`4e8a5871`, 2026-08-10) — which is why the
four consumer skills this excerpt replaces described a control that no longer exists, not one that
never did. ⚠️ Verify with the **path filter** — `git log -S "display dialog" --
operations/coordination/approval.py` is empty on the current branch, but that emptiness is an artifact
of squashed history (those commits are unreachable from `origin/main`; `git log --all -S …` shows
them). Drop the path filter and you get a *different* file's hit: `operations/coordination/notify.sh`
still ships a real `display dialog … buttons {"Open", "Dismiss"}` on `origin/main` — that script is
not the approval router and is not covered by this section.

⛔ **Never wait for a dialog. Never treat the banner as the response channel.** An agent waiting for
a click that cannot happen stalls the pipeline (this is the drift this section consolidates).

### How the agent detects the answer

Resolution is a **record read**, never an inference from a shrinking list. The module ships a CLI for
exactly this:

```bash
SWARM="${SWARM_ROOT:-$HOME/swarm}/operations/coordination/approval.py"
python3 "$SWARM" --pending --role human    # what is still open
python3 "$SWARM" --status <req_id>         # this record's status + reviewer
```

⚠️ Two traps, both verified:

- **A shrinking list is NOT proof of approval.** A Slack thread reply sets the record to
  `changes_requested` (`socket-mode.ts:1236` — the bridge's documented feedback path), which removes
  it from `--pending` without approving anything. Read `status`: `changes_requested` means *revise*,
  not *proceed*. It is also an **undeclared** status — the router's model comments only
  `pending | approved | rejected`, while the merged bridge writes it (agent-infra #958).
- **`is_approved(..., requires_human=True)` cannot confirm a Slack *button* approval.** It requires
  `reviewer == 'human'`, and the button path overwrites `reviewer` with the clicking user's Slack id
  (`socket-mode.ts:1186`) — so a genuine button approval leaves it returning `False` forever
  (agent-infra #959). It is authoritative only for `review_approval()`-resolved gates, which preserve
  the `human` marker. For a button approval, read `status == 'approved'` from `--status`.

### Do not use — not in the current router

`approval_feedback()` and the `parent=` / `revision` request fields exist only on **unmerged** swarm
branches. `approval_feedback` is not importable from the router (an
`from … import approval_feedback` raises `ImportError`; attribute access raises `AttributeError`) and
`parent=` raises `TypeError: request_approval() got an unexpected keyword argument 'parent'`. ⚠️ Note
the asymmetry: the **slack-bridge half is merged** (`index.ts` reads `req.parent` / `req.revision` /
`req.thread`; `README.md` documents the loop as shipped), so those fields are not fictional — the
router just cannot write them yet. See agent-infra #958 before reviving any conversation protocol.
Likewise `APPROVAL_NO_NOTIFY` is advertised in swarm's `config/env.hosted.example` but is read by no
code on `origin/main` in the current `$SWARM_ROOT` router — it silences nothing there (an unmerged
daemon-exec worktree copy does read it).

Full API: `$SWARM_ROOT/operations/coordination/approval.py`.

---

## Research Tool Selection (Cost-Ordered)

> **Note:** Tool names vary by agent. Pi: `mcp__seo-intelligence__perplexity_research`, `mcp__seo-intelligence__perplexity_search`, `mcp__context7__query_docs`. Claude Code: `perplexity` CLI or built-in web search. Check your agent's tool manifest for exact names.

| Tool | Cost | Use When |
|------|------|----------|
| Internal codebase search (grep, read) | Free | Always — first step |
| Library docs (context7 MCP or equivalent) | Free | When topic involves a specific library/framework |
| Quick Perplexity lookup | $0.005/query | Simple fact-check, "what is X" |
| Multi-angle Perplexity research | $0.005/query × N | Comparing approaches, "how do others do X" |
| AI-summarized web search | $1/$1 per M tokens | Synthesis of multiple sources |
| Higher-quality web search | $3/$15 per M tokens | Better quality when justified |

**⛔ NEVER use deep-research or reasoning-pro models without EXPLICIT user approval.** These cost $5-40+ per call. Use the cheapest tool that answers the question.

---

## Inlining Instructions

Skills that consume this taxonomy MUST inline:
1. The full taxonomy (6 categories)
2. The Research-Before-Ask Protocol (Steps 1-4)
3. The P0 Gate list
4. The tie-breaking rule

This ensures cross-session resilience — a skill invoked in a fresh session must work without loading this framework skill first.

When updating the taxonomy here, update all consuming skills:
- `agent-infra/skills/brainstorming/SKILL.md`
- `agent-infra/skills/executing-plans/SKILL.md`
- `agent-infra/skills/issue-scoping/SKILL.md`
- `~/.pi/agent/skills/brainstorming/SKILL.md` (Pi symlink)
- `~/.pi/agent/skills/executing-plans/SKILL.md` (Pi symlink)
- `~/.pi/agent/skills/issue-scoping/SKILL.md` (Pi symlink)

### Approval-Routing consumers (canonical block above)

The **Approval Routing — Canonical** block is consumed by, and must be re-synced into, the inline
excerpts in:

- `agent-infra/skills/epic-workflow/SKILL.md`
- `agent-infra/skills/project-workflow/SKILL.md`
- `agent-infra/skills/writing-plans/SKILL.md`
- `agent-infra/skills/verification-before-completion/SKILL.md`
- `agent-infra/skills/executing-plans/SKILL.md`
- `agent-infra/skills/issue-scoping/SKILL.md` — **still carries the stale pre-rollout wording**; it sits
  on the guarded second-model surface, so its re-sync is handled separately (agent-infra #949).

The Pi runtime copies live at `~/.pi/agent/skills/<name>/SKILL.md` for each of the six, and pi
resolves skills from *those* paths. Two layouts exist: a **repo-pointing symlink farm** (a repo fix is
then live immediately — `pi-bootstrap/setup.sh` deliberately preserves that layout, "updates via git
pull"), or a **separate set of regular files** (as on this machine, where they are stale). The
refresher is `pi-bootstrap/setup.sh`, run via `bash sync.sh` (or by the auto-sync extension) — so on a
copy-layout machine a fix landed only in `agent-infra/skills/` is **not live for pi** until that runs.
⚠️ `scripts/link-skills.sh` is a *different* tool: it hard-links skills into a **consumer repo's**
`operations/skills` and refuses to run from agent-infra — it never touches `~/.pi/agent`.
⚠️ A note earlier in this file calls these "(Pi symlink)"; that describes the symlink-farm layout only.

Each consumer inlines only the **operational core** — the portable invocation, "no dialog pops, do
not wait", the record-read detection + its two traps, the `requires_human`/auto-approve caveat, the
one-line Slack/store warning (the #956 divergence is part of the operational core: an agent that does
not know it will wait for a Slack answer that cannot come), and — where the gate's own call omits
`requires_human` — a disclosure of that. What must **not** be restated, and belongs here: the store-slug
**derivation internals** (`_detect_repo` vs `repoNameFromUrl`), the **status table**, and the **Slack
enablement details** (`SLACK_APPROVAL_POLL_MS`, Socket Mode, kill switches). Restating those is how the
original six copies drifted apart.

The five active consumers carry the version pin in their heading (`### Approval Routing (inlined
from human-input-framework v<version>)`) so a stale excerpt is detectable when this file is bumped;
`issue-scoping` does not yet — it sits on the guarded surface, see the registry above.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
