# Research — an off-the-shelf founder-comms surface for agent questions (agent-infra#2273)

**Status:** research complete, recommendation below. **Date:** 2026-10-21.
**Scope:** pick an adopted surface so agents can route JEV-filtered questions to the owner, and he
answers them conversationally from **Android** and **laptop**. Not a chat UI we build; not a bot we
maintain.

**Research method (mandatory PREFLIGHT line, `skills/research` Step 0.0):**

```
Search tool: NONE AVAILABLE IN THIS HARNESS — rung 1 (mcp seo-intelligence / perplexity) not
installable here, rung 2 (web_search) is not a tool on this box, rung 3's exa half not loadable;
rung 3's web_fetch half was taken via `curl` to vendors' own docs and via the GitHub REST/GraphQL
API. Queries: 0 search queries attempted; 29 document fetches attempted / 22 returned content
(7 failed: 5×HTTP 404, 2 JS-only shells that returned no body text); 5 GitHub release-API queries.
```

No claim below rests on a search snippet. **Every maintenance claim carries a release date or a URL
that was actually fetched** — where nothing could be fetched, the row says so instead of guessing
(§7 lists the gaps). Internal evidence is from the two repos' code, git history and issue tracker.

---

## 0. Recommendation in one line

**Adopt the Telegram Bot API** (`sendMessage` out, `getUpdates` in) as the delivery and conversation
surface, with the **GitHub issue remaining the system of record** — because Telegram is the only
candidate that is free, needs no server, needs no inbound socket, has native Android push **already
carrying the owner's ops pages in this fleet today**, and returns replies by long-poll over outbound
HTTPS. Runner-up (and the answer if the privacy call goes the other way): **Zulip Cloud**, whose
readback API is the best in the set.

---

## 1. Why the hand-rolled Slack bot failed — the most valuable evidence here

This is not a story about Slack. Slack's API would score near the top of the table in §3. **The
failure is entirely ours, and it was structural** — which is exactly why the replacement has to be
judged on its *coupling*, not its chat features.

### What was built

`extensions/slack-bridge/` in this repo, as of `origin/main` (2026-10-21):

| file | lines |
|---|---|
| `index.ts` | 1,926 |
| `socket-mode.ts` | 1,742 |
| `chunker.ts` | 66 |
| `slack-bridge.test.ts` | 1,885 |
| `socket-mode.test.ts` | 1,514 |
| `chunker.test.ts` | 127 |
| **total** | **7,260** |

20 commits between 2026-08-06 and 2026-08-31 (`git log --oneline -- extensions/slack-bridge`), the
last being `1dba3552 fix(slack-bridge): fence owner lease to stop cross-session ping-pong (#386)`
(2026-08-31 22:52 -0500). It shipped in `manifest.json` (line 36), so every bootstrapped machine
installs it. It is still merged. **And it has never delivered an owner question.** On this cell
(measured 2026-10-21) no `SLACK_*` variable is set and `~/.swarm/approvals/` does not exist — while
the extension's own README still claims "the shell environment has `SLACK_BRIDGE_DISABLE=1` and
`SLACK_BOT_TOKEN` set" (README:43), i.e. the doc describing it is already stale.

### The five root causes, each with its evidence

**(1) It was disabled, and nobody noticed for months** — agent-infra#40: *"The Slack bridge
extension shows as `⏭️ Disabled` … No `SLACK_*` tokens found in `.env`"*, while approvals actually
went out through `osascript` dialogs. A kill switch (`SLACK_BRIDGE_DISABLE=1`) was set in the shell
environment and the approval channel variable was never set. **Root cause: a transport whose
enablement is a pile of optional env vars has a silent "off" state, and "off" is indistinguishable
from "nothing to send".**

**(2) Two repos derived the same file path differently, so it never saw a request** —
agent-infra#956 (found and verified 2026-09-13):

```
router (python) : _detect_repo -> 'daniel-ospina/agent-infra' -> slug 'daniel-ospina_agent-infra'
                  ~/.swarm/approvals/daniel-ospina_agent-infra.json
bridge (ts)     : repoNameFromUrl(...) -> 'agent-infra'  (LAST SEGMENT ONLY)
                  ~/.swarm/approvals/agent-infra.json
```

Verified on disk: the approvals directory held `agent-infra.json`, `swarm.json`, `tortoise.json` —
and **no** `daniel-ospina_agent-infra.json`, "i.e. no router-written request for this repo has ever
been visible to the bridge". **Root cause: one path, two independent derivations, in two repos, with
no test that crossed the boundary.**

**(3) A field meant two things to two writers, so a real human approval could never pass** —
agent-infra#959: the button handler writes the clicking Slack user id into `reviewer`
(`socket-mode.ts:1426`, `:1438`, `:1184`), while the router's human gate requires the literal string
`"human"` (`approval.py::is_approved(..., requires_human=True)`). And the *test asserted the wrong
behaviour* — `socket-mode.test.ts:628` "accept: reviewer = payload.user.id (who clicked)" — so the
suite protected the bridge's meaning of the field, not the consumer's. **Root cause: the same record
had two writers with different semantics, and the tests pinned the producer instead of the
contract.**

**(4) A protocol shipped half-merged and was documented as whole** — agent-infra#958: the
conversation loop (`parent` / `revision` / `thread` / `status = changes_requested`) is merged
bridge-side (`index.ts:779,782,822`, `socket-mode.ts:1236`) but absent from the router
(`request_approval()` has no `parent`; there is no `approval_feedback()`; the status comment reads
`# pending | approved | rejected`). The epic (#155) was closed "complete — both sides shipped".
**Root cause: a state machine split across two repos, one half landed, and the docs described the
target state, not the shipped one.**

**(5) A persistent inbound socket forced leader election among ephemeral agent processes** —
agent-infra#188: every session opened its own Socket Mode connection, hitting
`too_many_websockets` and reconnect loops; the fix was a single-owner lease file, which then
ping-ponged across concurrent sessions and needed a second fix (#386) plus a displaced-owner grace
window, a frozen-owner staleness threshold and a lease-hold failure count (five env knobs, README
table). Plus #172: a noise storm whenever the daemon was down. **Root cause: Slack's interactive
events need a WebSocket owned by exactly one process, so correctness came to depend on leader
election among processes that are born and die constantly — a distributed-systems problem that has
nothing to do with the question being asked.**

### The sixth failure — the one that outlived all five

The bridge polled a **file on a laptop**, so delivery depended on the same machine and the same
daemon as the asking sessions. #158 added a "dead-session recovery — startup sweep + 24h TTL
auto-escalation" precisely because that assumption kept breaking. And the whole class of failure is
invisible: `scripts/undelivered-answers.py` exists because *"every failure of the question-gate's
delivery path is SILENT by construction — an answer that never reached a lane appears nowhere"*
(its docstring; measured 2026-09-26, five lanes stranded behind replies the owner had already
written).

### Current state of the ledger

| issue | state | meaning |
|---|---|---|
| #40 (re-enable Slack as primary approval channel) | CLOSED 2026-08-10 | closed by shipping the forwarder, not by making it deliver |
| #956 (store slug mismatch) | OPEN | the bridge is blind to router-created requests |
| #958 (conversation loop half-merged) | OPEN | the documented loop is unrunnable |
| #959 (button overwrites `reviewer`) | OPEN | a button approval cannot satisfy the human gate |
| #188 / #386 / #172 | CLOSED | fixed by adding lease machinery, not by removing the socket |

**So: months, 7,260 lines, 20 commits, four open defects, zero delivered questions.** The lesson is
not "Slack is bad". It is that **every hop we hand-roll acquires a second contract**, and a second
contract is where the message dies.

### The five rules the replacement must obey (derived from the above, not invented)

- **R1 — one writer per record.** The question, the verdict and the answer live on the GitHub issue.
  The chat surface carries *copies* for attention; it never owns state. (Kills #956 and #959.)
- **R2 — no inbound socket.** Outbound HTTPS only: POST to send, long-poll to receive. No listener,
  no public URL, no WebSocket, no single-owner lease. (Kills #188/#386/#172.)
- **R3 — no duplicated derivation of any path or slug.** One definition, in agent-infra, exercised
  by a test that crosses the boundary. (Kills #956.)
- **R4 — every hop can report its own delivery, and one instrument must be able to see a lost
  answer.** Reuse `undelivered-answers.py`; a "✓ relayed" confirmation in the thread is part of the
  feature, not a nicety. (Kills the #1667 silent-receipt failure.)
- **R5 — the transport must not depend on a laptop daemon.** The sender/poller runs in the heartbeat
  tick (which is already single per machine+repo, agent-infra#1761), not in a per-session process.

---

## 2. What the requirements actually demand (and which one eliminates most candidates)

The hard one is **(3) conversation with programmatic readback** together with **(4) push that
arrives**. Individually many tools do each; the intersection is small:

- A one-way notifier (ntfy) satisfies (4) brilliantly and fails (3) outright.
- A comment system (GitHub Discussions, Notion, Linear) satisfies (2) and (3) but its push is
  "notification for issues/PRs and @-mentions", not "a message addressed to you arrives".
- A self-hosted chat server (Mattermost, Rocket.Chat, Matrix, Zulip self-host) satisfies (2) and (3)
  but buys (4) by making push a *second* service to run (a push proxy/bouncer/gateway) — R5 violated
  and the self-host burden of requirement 6 doubled.

Requirement **(8) carries the JEV verdict** needs no vendor feature at all: the verdict is text we
compose. It matters only that the surface renders it legibly and that **raw questions never reach
the owner** — which the existing `owner-decision` label already guarantees (§5.1).

---

## 3. Comparison table

Costs are at **a few dozen messages/day, one owner**. "Self-host" means *we* run it.
Push column: "proven here" = this fleet already pages the owner over it; otherwise the claim is
limited to what the vendor documents (not measured from this harness).

| Candidate | Mobile quality | Agent posting API | Reply readback | Push reliability | Maintenance signal (date · URL) | Cost @ few dozen msg/day | Self-host burden | Disqualifier |
|---|---|---|---|---|---|---|---|---|
| **Telegram Bot API** | Native Android + desktop apps | `POST /bot<token>/sendMessage` — token in URL path, no interactive login | `getUpdates` long-poll (outbound only, **no public URL**) or webhook; replies carry `reply_to_message`; inline-keyboard taps return `callback_query` with our own `data` string; updates retained ≤24 h | **Proven in this fleet** — the owner's ops pages already ride Telegram: tortoise#310 (billing → Resend + Telegram, 2026-08-08) and #3639 (abuse/security → Telegram only, 2026-09-16), sent by `tortoise/telegram_push.py` | **Bot API 10.3, 2026-08-24** — https://core.telegram.org/bots/api#recent-changes | **$0** — "bots are able to message their users at no cost"; limits 1 msg/s per chat, 20/min in a group (https://core.telegram.org/bots/faq) | **None** | None on the requirements. Risks, not disqualifiers: content transits a third party; no bot-side message export; 24 h update retention ⇒ poller must run at least daily; bot must be in the target chat |
| **Zulip Cloud** | Native Android app, good; push delivered via Zulip's bouncer | `POST /api/v1/messages` with a bot API key (https://zulip.com/api/send-message) | **Best in set**: `GET /api/v1/messages` with `narrow` (https://zulip.com/api/get-messages); topics = one thread per question | Via the push bouncer; even self-hosted servers must register with it (https://zulip.readthedocs.io/en/latest/production/mobile-push-notifications.html). E2EE since 12.0 | **12.3, 2026-09-21** — https://github.com/zulip/zulip/releases/tag/12.3 | Cloud **Free**: 10,000 messages search history, 5 GB (≈9 months at 36/day); Standard **$6.67**/user/mo annual, $8 monthly (https://zulip.com/plans/) | Heavy if self-hosted (PostgreSQL, RabbitMQ, Redis, memcached) + bouncer registration; zero on Cloud | Not disqualified — **runner-up**. Costs a second org/account and a free-tier history window that will eventually bite |
| **Twist** (Doist) | Native apps (Android/desktop) | API v3: `POST /api/v3/threads/*`, `comments/add`, `conversation_messages/add` (https://developer.twist.com/v3/) | `comments/get`, `conversation_messages/get` — full read+write | App push; not measured here | **No date retrieved** — `https://twist.com/changelog` returns 404 to this harness | **Free**: $0, but **1 month** of message history (https://twist.com/pricing); Unlimited $6/user/mo | None | Fails requirement 5 as researched: no release feed to cite ⇒ maintenance cannot be asserted |
| **Matrix / Element** | Element X Android **v26.10.0, 2026-10-16** — the most actively released client in the set (https://github.com/element-hq/element-x-android/releases/tag/v26.10.0) | Client-server API `PUT /rooms/{id}/send/m.room.message` | `/sync` or `/rooms/{id}/messages` | Requires a push gateway + app credentials chain; historically the weak link | Element X Android **v26.10.0, 2026-10-16** (above) | matrix.org $0; self-host Synapse on a small VPS | **High**: Synapse + a push gateway; and an **E2EE-capable bot** if the room is encrypted (a plain HTTP POST is not enough) | E2EE bot + push-gateway chain makes it the *highest*-coupling candidate — the same class of failure as §1(5) |
| **Mattermost** | Native apps | REST API + WebSocket | REST read of channel posts | Self-built app requires **your own Mattermost Push Notification Service** (https://developers.mattermost.com/contribute/mobile/push-notifications/) | **v12.0.0, 2026-10-14** — https://github.com/mattermost/mattermost/releases/tag/v12.0.0 | Free (self-host, Team Edition) or paid cloud | **High**: server + push proxy (R5) | Self-host burden disproportionate for one owner reading a few dozen messages/day |
| **Rocket.Chat** | Native apps | REST API + WebSocket | REST read | Push **only** through Rocket.Chat's gateway, and the workspace must be registered and accept their cloud terms (https://docs.rocket.chat/docs/push) | **8.9.0, 2026-10-05** — https://github.com/RocketChat/Rocket.Chat/releases/tag/8.9.0 | Free (self-host) | **High**: server, plus a mandatory registration coupling for push | Same as Mattermost, plus push is coupled to a vendor gateway |
| **Discord** | Native apps, reliable push | Bot REST API (`POST /channels/{id}/messages`); events need the gateway WebSocket or REST `after=` polling | REST `GET /channels/{id}/messages`, threads supported | App push, reliable in general use | **Changelog entry 2026-10-14** — https://discord.com/developers/docs/change-log | **$0** | None | Not disqualified technically; rejected on **fit** — a consumer/gaming surface for the owner's work queue, and event delivery wants a persistent gateway (R2) |
| **ntfy** | Native Android app; push is the product's whole job | `PUT/POST https://ntfy.sh/<topic>` — the simplest write path in the set | **None**: the only "reply" is a canned action button whose `http` action calls a URL *we* must expose (https://docs.ntfy.sh/publish/) | Excellent (dedicated app, priorities, no FCM dependency for its own delivery) | **v2.32.0, 2026-10-18** — https://github.com/binwiederhier/ntfy/releases/tag/v2.32.0 | Free on ntfy.sh; self-host = one Go binary | Low if self-hosted | **Fails requirement 3 outright** — no free-text conversational reply, so a question cannot be *explored* |
| **Pumble** | Native apps | API addon sends messages ("send messages, reactions, and more"), 1000 req/min/user (https://pumble.com/help/integrations/automation/api/) | **No read endpoint documented** | App push; not measured | **No date retrieved** (help-centre page only) | Free plan exists (https://pumble.com/pricing) | None | Fails requirement 3 (no documented readback) and 5 (no release feed retrieved) |
| **Basecamp 4** (Campfire + Chatbots) | Native apps | A **chatbot** posts through a keyed `lines_url` with no OAuth — but *"what you can't do is read anything from the room"*; reading/writing as a plain integration needs a person's OAuth token (`POST/GET …/buckets/{id}/chats/{id}/lines.json`) — https://github.com/basecamp/bc3-api (`sections/campfires.md`, `sections/chatbots.md`) | OAuth only (`GET /chats/2/lines.json`); the chatbot path cannot read at all | App push; not measured | **No date retrieved** — closed SaaS, no public changelog found | **$29/mo** minimum (Freelancer, 3 projects / 5 users) — https://basecamp.com/pricing | None | Readback needs **the owner's OAuth token held by an agent**, or Basecamp must POST to a listener we run (an interactive chatbot) — R2/R3 violated; plus $29/mo at this volume |
| **Notion comments** | Native apps | `POST /v1/comments` on a page, block, **or existing discussion thread** (https://developers.notion.com/reference/create-a-comment) | Comment objects retrievable | Notion app notifications; **no way to aim a push at a person from the API** — the notification is page/subscription-shaped | **No date retrieved** (`developers.notion.com/changelog.md` → 404) | Free plan / paid per seat | None | Fails requirement 4 in practice: a question cannot be *pushed to* the owner; it waits on a page he must be watching |
| **Linear comments** | Native apps, good push | GraphQL `commentCreate` + webhooks (https://linear.app/docs/api-and-webhooks) | GraphQL | App push, reliable | **No date retrieved** (changelog pages returned JS shells / 404) | Free tier; paid per seat | None | Duplicates the GitHub queue we already have — a question *is* already an issue. No gain, one more tracker |
| **GitHub Discussions + GitHub Mobile** | GitHub Mobile — but its documented scope is "read, review, and collaborate on issues and pull requests" and push *"when someone mentions your username"* (https://docs.github.com/en/get-started/using-github/github-mobile) | GraphQL `addDiscussionComment` — confirmed present by schema introspection 2026-10-21 | GraphQL discussion comments (full read) | **Not a documented push target for discussion replies** | Continuous product (GitHub); the *client* signal is the weak part | $0 on public repos; our repos are private, so the plan tier must be checked before relying on Discussions at all | None | **Fails requirement 4** — this is the status quo's hole, re-implemented in a different tab |
| **Slack** (baseline) | Native apps, excellent push | Web API (`chat.postMessage`), excellent; events need Socket Mode/HTTP endpoint | `conversations.replies`, excellent | Excellent | Mature vendor; **our** integration is the broken part (§1) | Free tier workable at this volume | None | **Not the platform's fault — ours**: 7,260 lines, 4 open defects, 0 delivered questions (§1). Adopting it again means hand-rolling the same bridge |
| **Agent-native chat UI** (e.g. Open WebUI, self-hosted) | Web UI wrapping the agent API; **no native Android client with real push** (PWA push) | Full control — it *is* the agent API | Full control | Weak: Android PWA push, not an app-store app | **Open WebUI v0.12.3, 2026-10-16** — https://github.com/open-webui/open-webui/releases/tag/v0.12.3 | $0 licence + a VPS | **High** — this is the "chat UI we build/maintain" the issue excludes | Fails the non-goals ("not a chat UI we build") and R5 (a server for us to run) |

**Two rows deserve a note.** *Discord* and *Slack* are the technically strongest chat APIs in the
set — and both are rejected for reasons that are about this fleet, not about chat. *GitHub
Discussions* is the cheapest possible answer and it fails on exactly the requirement that motivated
the issue (push that arrives).

### 3.1 Licences (requirement 5 asks for these explicitly)

| Candidate | Licence | Source |
|---|---|---|
| Telegram Bot API | proprietary service; open API, ToS-governed (no self-hostable server) | https://core.telegram.org/api/terms |
| Zulip | **Apache-2.0** | https://github.com/zulip/zulip/blob/main/LICENSE |
| Twist / Pumble / Notion / Linear / Basecamp / Slack / Discord | proprietary SaaS; API use governed by the vendor's developer terms | vendor terms pages |
| Matrix / Element | Element X Android **AGPL-3.0**; Synapse AGPL-3.0 | https://github.com/element-hq/element-x-android/blob/develop/LICENSE |
| Mattermost | "Mattermost Licensing" — compiled binaries under **MIT**, with separate terms for the `ee/` directories | https://github.com/mattermost/mattermost/blob/master/LICENSE.txt |
| Rocket.Chat | **MIT** for the core, with separately-licensed `ee/` directories | https://github.com/RocketChat/Rocket.Chat/blob/develop/LICENSE |
| ntfy | **Apache-2.0** (dual-licensed with GPLv2) | https://github.com/binwiederhier/ntfy/blob/main/LICENSE |
| GitHub Discussions | our existing GitHub plan's terms (no extra licence) | — |
| Agent-native chat UI (Open WebUI) | "Open WebUI License" — BSD-style with an added branding/50-user clause (GitHub reports it as *Other*) | https://github.com/open-webui/open-webui/blob/main/LICENSE |

Licence was **not** a deciding axis: every candidate we would actually run is either proprietary
SaaS we consume over HTTPS (Telegram, Zulip Cloud, Twist) or OSI-licensed software. It matters only
for the self-hosted rows, which lose on burden before licence ever gets a vote.

---

## 4. Recommendation

### Adopt the Telegram Bot API, with the GitHub issue as the record

Why the top of the table collapses to one:

1. **Requirement 4 already runs here in production.** `tortoise/telegram_push.py` sends the owner's
   ops pages today (tortoise#310, 2026-08-08: billing → Resend **+ Telegram**; #3639, 2026-09-16:
   abuse/security → **Telegram only**, deliberately with no email fallback because a Telegram outage
   means a lost alert). Nothing else in the table has a track record *in this fleet*; everything else
   is a vendor claim we would be testing with a real question.
2. **It is the only candidate that satisfies R1–R5 at once**, at $0 and with no server: outbound
   POST to send, outbound long-poll (`getUpdates`) to receive — no inbound socket, therefore no
   leader election, therefore neither #188 nor #386 can recur (R2). The state stays on the issue
   (R1). Nothing local is derived twice (R3). One script in the heartbeat tick (R5).
3. **`getUpdates` gives us a structured answer for free.** The owner can answer with a button
   (`callback_query` carrying our own `data` string, e.g. `ans:daniel-ospina/tortoise:9202:A`), a
   swipe-reply (`reply_to_message` identifies the card), or free text in the thread. A/B questions —
   tortoise#9097's shape — come back as `A`/`B`, not as prose to parse.
4. **Messaging surface already in the owner's hand.** Telegram Desktop covers the laptop half;
   nothing new to install on Android.

### What it costs (stated plainly)

- **Money: $0/month.** Rate limits (1 msg/s per chat, 20/min per group) are ~3 orders of magnitude
  above "a few dozen messages a day".
- **Code: two small Python paths**, not a bridge — a *sender* (~80 lines: build the card, POST) and
  a *poller* (~120 lines: `getUpdates`, map reply → issue, comment, remove label) plus tests. That
  is beside `telegram_push.py`, which already exists and already has the `ok:true` delivery contract
  (tortoise#4574 tracks unifying the *shell* senders on that contract; this path uses the Python one,
  so it lands on the good side of that split).
- **Risk 1 — content transits a third party.** The question text already lives on GitHub, also a
  third party, so this adds a second vendor to the same disclosure, not a new class of exposure. If
  that is unacceptable, the answer is Zulip Cloud (§3), not a self-hosted server.
- **Risk 2 — no bot-side export.** Mitigated structurally: Telegram owns *copies*. Delete the bot
  and lose nothing — the questions, verdicts and answers are on the issues. **The exit path is "stop
  the sender"; there is no data to migrate.** (Requirement 7.)
- **Risk 3 — 24 h update retention.** The poller must run at least daily. The heartbeat runs every
  few minutes, so this is satisfied by construction; the offset is persisted (§5.2).

### Runner-up

**Zulip Cloud** if the owner wants a dedicated work surface or rejects a consumer messenger. It has
the best readback API in the set (`GET /api/v1/messages?narrow=…`), topics give natural one-thread-
per-question, and the Free plan's 10,000-message history is ≈9 months at 36 messages/day. It costs a
second org/account and, past that window, $6.67/user/month.

---

## 5. Migration path

**Nothing in this path modifies `scripts/ask-owner.py`** (a constraint of this PR, and also the right
design: the gate is calibrated machinery — agent-infra#1610 — and the new surface is a *consumer* of
its labels, not a participant in its judgement).

### 5.1 How a JEV-filtered question is posted

The gate's existing handshake is unchanged; the new sender is bolted on **downstream of it**:

1. A lane posts its question as one comment beginning with the declaration line
   (`RESEARCH: skill=… sources=… refs=…`) and runs `python3 scripts/ask-owner.py <repo> <n>`.
2. The gate makes **one Jev call** (`JEV_MODEL = jev-1.13.0`), scoring five structural marks at 0.80
   and two mechanical language marks at 0.55; on a pass it adds the `owner-decision` label and
   prints the per-mark scores to stdout; on a bounce it posts the template **plus the exact counted
   occurrences**, adds `question-bounced` and **removes** `owner-decision`.
   Therefore: **the `owner-decision` label already *is* the JEV filter's verdict.** Raw (unfiltered)
   questions cannot reach the owner, because they never carry the label — requirement 8 is satisfied
   by the existing gate, and the card only has to *show* the numbers.
3. The heartbeat — which already runs the gate (`scripts/orchestrator-heartbeat.sh:128`) and
   therefore already holds the stdin/stdout of the pass — calls the new sender once per issue that
   **entered** `owner-decision` this tick:

   ```
   scripts/owner-notify.py send --repo <repo> --issue <n> --scores-from-stdin
   ```

   It posts one `sendMessage` card:

   ```
   ⚖️ tortoise#9202 — owner decision needed
   gate: PASSED · has_context 0.82 · has_options 0.98 · has_analysis 0.91
                   · has_recommendation 0.97 · contradiction_test 0.95
                   · jargon_free 1.00 · understandable 0.93

   <first ~10 lines of the declared question>

   [ Open issue ]        ← inline URL button
   ```
   The card identifies the issue by `<repo>#<n>` **in its own text** — that is the whole routing
   table; no local side-file maps messages to issues (R1/R3).
4. Idempotency is a **label, not a file**: after a successful send the sender adds `owner-notified`
   to the issue and never posts that issue again until the label is removed. Labels survive reboots,
   fresh machines and concurrent sessions; a local seen-file (`~/.pi/agent/slack-approval-seen.json`
   was the Slack version) does not.

### 5.2 How the reply returns to the decision relay

The poller runs in the same heartbeat tick (`scripts/owner-notify.py poll`), one consumer, outbound
only:

1. `getUpdates?offset=<stored>&timeout=0`. The offset is one integer in
   `~/.pi/agent/telegram-offset`; the heartbeat is already single per machine+repo (agent-infra#1761),
   so there is no second consumer to split updates with — and **no lease to fight over** (R2).
2. For each inbound item, resolve the issue:
   - `callback_query` → `data = ans:<repo>:<n>:<choice>` (we wrote that string);
   - `message` with `reply_to_message` → parse `<repo>#<n>` out of the quoted card text;
   - anything else → ignored (not a reply to a card ⇒ not an answer).
3. Relay it, in this order:
   ```
   gh issue comment <n> --repo <repo> --body "<reply text>

   <!-- via:telegram chat=<id> msg=<update_id> -->"
   gh issue edit <n> --repo <repo> --remove-label owner-decision
   ```
   **These two commands are the entire integration**, because everything downstream already exists:
   the `unlabeled owner-decision` timeline event *is* the answer signal (that is what
   `ask-owner.py::owner_answered_at` reads and what `undelivered-answers.py` verifies), and the label
   removal is what puts the question back into the scan's answer pass.
4. The next `ask-owner.py --scan` (unchanged) sees the removal, adds `owner-answered` +
   `answer-delivered`, and calls `notify_lane()` — which pushes *"The owner has answered your
   question on `<repo>#<n>`"* into the waiting lane's cmux pane. **This is also what satisfies the
   2026-10-10 owner direction on agent-infra#1667** ("the owner needs to be able to chat with an
   agent for questions — hence lanes"): the phone reply does not settle into a dead comment, it wakes
   the lane that asked. See §6.
5. Post a confirmation *back into the Telegram thread* — `✓ relayed to tortoise#9202 as an answer
   comment` — so the owner can see the relay happened (R4; the failure mode that produced
   `undelivered-answers.py` was silence).
6. Durability: if the offset file is lost, re-polled updates re-emit comments. The
   `<!-- via:telegram msg=<update_id> -->` marker makes the poller skip any message already commented
   (one `gh issue view --json comments` check), so replay is idempotent and a duplicate answer is
   impossible.

### 5.3 What the owner's daily phone interaction looks like (5 lines)

1. **Phone buzzes:** `⚖️ tortoise#9202 — owner decision needed · gate: PASSED (7/7 marks)`.
2. **Tap the notification:** the card is open — the question, the options, the recommendation, the
   per-mark scores, and the issue link.
3. **Answer in place:** tap `A` / `B` on the keyboard, or swipe-reply with a sentence ("A, but keep
   the flag off by default").
4. **~1 minute later, in the same thread:** `✓ relayed to tortoise#9202 as an answer comment`, and
   the lane's reply ("understood — implementing A with the flag off") appears underneath.
5. **Nothing else.** No labels to add, no dashboard to check, no "did it land?" — the issue carries
   the ruling and `undelivered-answers.py` shouts if it did not reach the lane.

### 5.4 Explicitly out of scope for the follow-up implementation (and why)

- **Do not touch `ask-owner.py`.** It is the calibrated gate; the surface is downstream of it.
- **Do not port the Slack bridge, and do not write a state file the two sides share.** Rules R1/R3.
- **Retire `extensions/slack-bridge/`** once the Telegram path has delivered its first ten answers
  (follow-up issue, not this PR — this PR is docs-only). Its four open defects (#956/#958/#959, and
  the disabled-by-default state in #40) stop being work the moment the path is not used.

---

## 6. Contradiction test (run BEFORE adopting, per `AGENTS.md` → USER QUESTIONS PROTOCOL)

**Decision found 1 — agent-infra#1667, owner direction, 2026-10-10 (recorded on the issue):**

> "Moving away from the relay. The intent is that **agents use the approved protocol in a lane**, and
> that **JEV (or an equivalent) filters the questions** — the filtering part of the relay was good and
> should survive. The relay did not work because ultimately the owner needs to be able to **chat with
> an agent** for questions — hence lanes."

*Does the recommendation contradict it?* **No, and it must not be read as adopting over it.** Two
reasons, both mechanical:

- The part #1667 rejects is a relay that **dead-ends** ("at least one path … `ask-owner.py` cannot even
  deliver"; "the failure is silent by construction"). §5.2 keeps the answer *and* wakes the lane
  (`notify_lane()`), which is the "chat with an agent" property #1667 names. The lane, not the
  messenger, remains the thing the owner talks to.
- #2273 (the spec for this work, filed after #1667) explicitly asks for *"how the reply returns to
  the decision relay"* — so the return path through the queue is in scope by the later instruction.

**If the owner reads #1667 as barring any relay return**, then this is a **reopen of #1667**, argued on
#2273 — not a quiet adoption. That call is his; the evidence for it is §1 (what a relay without
readback cost) and §5.2 (what readback costs now).

**Decision found 2 — the owner-facing transport is *already* Telegram (supports the recommendation):**

- tortoise#310 (2026-08-08): billing events notify via Resend **and Telegram**
  (`@Premislabs_notifications_bot`).
- tortoise#3639 (2026-09-16): abuse/security events are **Telegram only**, no email fallback.

These are recorded decisions about *operations alerts*, not about the question queue, so they do not
settle this question — but they do mean adopting Telegram here is **aligned with the grain of a
decision we already made**, and it means the bot, the chat and the owner's phone habit already exist.

**Suggested `OVERRIDES:` line for the decision comment that follows this research** (the marker
belongs on the issue, per `AGENTS.md`):

> **OVERRIDES:** the usual "internal tooling stays in first-party/self-hosted systems" default —
> adopting Telegram puts question text through an external messenger, which we accept because the
> text already lives on GitHub (also external), the messenger owns no state (every question, verdict
> and answer stays on the issue), and the alternative costs either a server we run or a push path we
> cannot verify.

---

## 7. Evidence gaps (what this run could NOT verify — treat those cells as unproven)

- **No search tool existed in this harness** (no `web_search`, no `mcp_load`, no exa). Every external
  fact above came from a vendor page or API fetched directly with `curl`, or from GitHub's
  REST/GraphQL API. Without a search engine, discovery was limited to the candidate list in the
  issue plus what those vendors' own docs linked to — **a better candidate could exist that this run
  never saw.**
- **Fetch failures (7):** `docs.rocket.chat/docs/push-notifications-gateway` (404 — the working page
  is `/docs/push`), `twist.com/changelog` (404), `wire.com/en/products/` (404 — Wire is therefore
  **not** in the table rather than assessed on a guess), `docs.github.com/…/mutations.md` (404),
  `linear.app/rss/changelog` (404), plus `linear.app/changelog` and `linear.app/pricing` returning
  JS-only shells with no readable body.
- **Maintenance dates NOT retrieved** (and therefore not asserted): Twist, Pumble, Basecamp 4,
  Notion, Linear, Wire. For Linear the API docs *were* retrieved, so only requirement 5 is unproven,
  not requirement 2/3.
- **Not measured from here, only documented:** every push-reliability cell except Telegram's (which
  is proven by the fleet's own ops traffic) and ntfy's (push is the product). Android *push latency*
  for Zulip/Twist/Mattermost/Rocket.Chat/Discord was not instrumented — if requirement 4 is to be
  settled by measurement rather than by vendor claim, that test has to run on the owner's phone.
- **Zulip Free-plan long-run:** the 10,000-message search-history limit is from the plans page; what
  happens to *older* messages (retained but unsearchable?) was not confirmed.
- **Telegram policy/export:** the Bot API has no message-export endpoint; the privacy terms a private
  bot chat sits under were not read in full. This is why §4 states the exit path as "stop the sender"
  rather than "export the history".

---

## 8. Sources

**Internal (measured in this repo / the fleet, 2026-10-21):**
- `scripts/ask-owner.py` (1,531 lines) — Jev call, `JEV_MODEL = jev-1.13.0`, `THRESHOLD = 0.80` /
  `THRESHOLD_LANGUAGE = 0.70` / `THRESHOLD_JARGON = 0.55`, the `owner-decision` / `question-bounced`
  / `owner-answered` / `answer-delivered` label handshake, `notify_lane()` (line 1039).
- `scripts/undelivered-answers.py` (236 lines) — the delivery predicate and why silence is invisible.
- `scripts/orchestrator-heartbeat.sh:128` — the heartbeat runs `ask-owner.py --scan`.
- `extensions/slack-bridge/` — 7,260 lines; `README.md:43`; 20 commits 2026-08-06…2026-08-31.
- Issues: agent-infra **#40, #155, #158, #172, #188, #386, #956, #958, #959, #1667, #1610, #1761,
  #1903, #1969, #2273**; tortoise **#310, #3639, #4574** (three Telegram senders, one delivery
  contract), `tortoise/telegram_push.py`, `tortoise/notify.py`.

**External (fetched 2026-10-21):**
- https://core.telegram.org/bots/api (Recent changes: **Bot API 10.3, 2026-08-24**; `getUpdates`,
  `reply_to_message`, `callback_query`)
- https://core.telegram.org/bots/faq ("bots are able to message their users at no cost"; 1 msg/s per
  chat, 20/min in a group)
- https://github.com/zulip/zulip/releases/tag/12.3 (**2026-09-21**)
- https://zulip.com/api/send-message · https://zulip.com/api/get-messages · https://zulip.com/plans/
- https://zulip.readthedocs.io/en/latest/production/mobile-push-notifications.html (push bouncer;
  E2EE from 12.0)
- https://github.com/mattermost/mattermost/releases/tag/v12.0.0 (**2026-10-14**) ·
  https://developers.mattermost.com/contribute/mobile/push-notifications/
- https://github.com/RocketChat/Rocket.Chat/releases/tag/8.9.0 (**2026-10-05**) ·
  https://docs.rocket.chat/docs/push (gateway + workspace registration)
- https://github.com/element-hq/element-x-android/releases/tag/v26.10.0 (**2026-10-16**)
- https://discord.com/developers/docs/change-log (latest entry **2026-10-14**)
- https://github.com/binwiederhier/ntfy/releases/tag/v2.32.0 (**2026-10-18**) ·
  https://docs.ntfy.sh/publish/ (action buttons / `http` action)
- https://pumble.com/help/integrations/automation/api/ · https://pumble.com/pricing
- https://developer.twist.com/v3/ · https://twist.com/pricing (Free: 1 month history)
- https://github.com/basecamp/bc3-api (`sections/campfires.md`, `sections/chatbots.md`) ·
  https://basecamp.com/pricing (Freelancer $29/mo)
- https://developers.notion.com/reference/create-a-comment
- https://linear.app/docs/api-and-webhooks
- https://docs.github.com/en/get-started/using-github/github-mobile · GitHub GraphQL schema
  introspection (`addDiscussionComment`, 2026-10-21)
- https://github.com/open-webui/open-webui/releases/tag/v0.12.3 (**2026-10-16**)
