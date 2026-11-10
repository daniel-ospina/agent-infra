---
title: "The decision gate — provisioning the owner-question credential, and what refuses without it (#2642)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-11-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2642, ask-owner, owner-decision, cloud-cell-bringup, cloud-cell-supervisor, jev-config, typesafe
---

# The decision gate (#2642)

`scripts/ask-owner.py` is the gate that decides whether a lane's question earns the
`owner-decision` label — **the queue the owner actually reads**. It scores a question with the
TypeSafe (formerly "JEV") API and either labels it into the queue, bounces it back with a template,
or **exits 2**.

Exit 2 is honest: the gate refuses to label a question it could not score. Before this change it was
also **silent**, and that is what cost the fleet: the comment is posted and readable, the lane's own
report says "asked", and the question is absent from the queue. Measured 2026-10-24 on agent-infra
cell-1 — **nine owner questions posted, not one queued** — because `~/.pi/agent/jev-config.json`
existed on the laptop and on no cell.

## Where the credential comes from, and who writes it

`ask-owner.py::_key()` resolves it in this order:

1. `$TYPESAFE_API_KEY` (the vendor's own name),
2. `$JEV_API_KEY` (the older name — a plist or a cell env may carry it),
3. `$HOME/.pi/agent/jev-config.json`, a 0600 JSON store with an `apiKey` field. **The field must be a
   JSON string**: the gate reads the raw value and sends it as `Bearer <value>`, so a number, object,
   array or `true` is not a credential — it either takes the unkeyed branch or comes back `jev http
   401`. A store holding one reads as *no usable key* on every surface below (it is repaired from
   `keys.env` when the box has one, and otherwise refuses), never as `configured`.

On a cell, **`scripts/cloud-cell-bringup.sh::check_decision_gate` is the writer**, and the box's own
`keys.env` is the only source it will read:

- a key named **and valued** in `keys.env` (`TYPESAFE_API_KEY=…`, or `JEV_API_KEY=…`) is written into
  the 0600 store, preserving every other field (`model` included);
- a store that already holds a **different** key is never overwritten — which key is current is a
  decision, not a repair — so the shadow is *reported* instead;
- an **ambient export is not a source**. A lane sources `keys.env` itself, and a tmux worker is
  served the *server's* environment, so an export that lives only in an operator's shell reaches no
  worker. That near-miss gets its own refusal rather than a false pass.

The store is durable on purpose: a reader that sources nothing (a systemd unit, a hand-run
`ask-owner.py --scan`) has only the store, and the gate has to work from those too.

## What refuses, and where it is visible

| surface | behaviour |
|---|---|
| `cloud-cell-bringup.sh --check` | **REFUSES** the box, by name (`CHECK FAILED [decision gate]: …`), before `CELL READY` and before the paid provider probe. A store that exists but cannot be parsed is refused too — the script will not replace a credential file it cannot read. A store whose `apiKey` is not a JSON **string** is not a credential the gate can send: it is treated as an empty store and REPAIRED from `keys.env` (other fields preserved), or refused when the box has no key to repair it from. |
| `cloud-cell-supervisor.sh status` | one **read-only** line: `jev: configured (…)` / `⛔ jev: MISSING …` / `⛔ jev: a TypeSafe key is set in THIS shell but NOT in keys.env …`. `configured` is claimed only for a string-valued `apiKey` the gate can actually send (the same rule the bring-up applies). It names the one command that repairs; it never writes. |
| `ask-owner.py <repo> <n>` | exit 2 is honest, and its REASON is named: a scoring failure from `jev()` (no key, a rejected key, a failed call) prints the cause line and then `UNSCORED — the owner queue did not receive this`. The other exit-2 causes name themselves without that sentence (`could not read <repo>#<n>`, `could not read the answer state … UNKNOWN`, `jev returned no answer for …`). |
| `ask-owner.py --scan` | the summary line carries `unscored=N` on both arms, and every unscored question is NAMED above it as `UNSCORED <repo>#<n> — …`, one line per question, with the cause on the line above. `orchestrator-heartbeat.sh` sums that field into `N_ASK` (so the naming lines reach the log) and logs one `ALERT ask-gate UNSCORED …` per tick. |

The alert is deliberately **cause-neutral**: `unscored` counts every exit 2, and only one of them is
"no key on this box". On a box whose key is present but wrong the per-question line reads `jev http
401: …` and the alert does not tell the operator to provision a key that is already there.

**OVERRIDES:** a missing credential warns rather than fails in the sibling case
(`docs/plans/2026-11-04-issue-3275-hosted-mcp-cell-provision.md` D6) — that decision covers a
*different* credential (the hosted-MCP token) and a *different* verifier (the layer's `--verify`), so
it does not reach this one. This issue carries its own decision, quoted in its `OVERRIDES` line: a
decision gate that only works on the laptop cannot gate fleet work, and the credential must be
provisioned by the harness like the harness pin itself. A cell that prints `CELL READY` while its
decision gate cannot fire is the inert-enforcer shape this repo files as a defect — the same reason
`check_schedule` is fatal (`docs/ops/fleet-schedule.md`).

## If a cell is refused

```bash
# on the box, in the real home the cell runs under
printf 'TYPESAFE_API_KEY=%s\n' '<the key>' >> "$CELL_HOME/keys.env"   # or: cmux vm push --secret
chmod 600 "$CELL_HOME/keys.env"
bash "$CHECKOUT/scripts/cloud-cell-bringup.sh" --check
```

The bring-up writes `$CELL_HOME/.pi/agent/jev-config.json` (mode 600) from that line and reports
`REPAIRED decision gate`. Then:

```bash
python3 ~/.pi/agent/scripts/ask-owner.py <owner/repo> <issue> --dry-run    # 0 or 1, not 2
bash scripts/cloud-cell-supervisor.sh status | grep jev                    # jev: configured (…)
```

A key that is *present but wrong* is not this gate's question — the first real question returns
`jev http 401: …` from `ask-owner.py`, which names the host and the status.
