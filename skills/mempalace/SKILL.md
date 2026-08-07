---
name: mempalace
description: "DEPRECATED — MemPalace has been removed (S10 licensing cleanup, 2026-07-17). All memory operations now route through Tortoise (hosted API / FalkorDB). See the memory-system plan (eldato repo docs/epics/2026-07-14-memory-system/04-plan.md) for the new memory system."
allowed-tools: read, bash, grep, find, mempalace_status, mempalace_search, mempalace_diary_read, mempalace_diary_write, mempalace_add_drawer, mempalace_update_drawer, mempalace_get_drawer, mempalace_list_drawers, mempalace_delete_drawer, mempalace_check_duplicate, mempalace_checkpoint, mempalace_mine, mempalace_init, mempalace_sync, mempalace_kg_query, mempalace_kg_add, mempalace_kg_invalidate, mempalace_kg_timeline, mempalace_kg_stats, mempalace_list_wings, mempalace_list_rooms, mempalace_get_taxonomy, mempalace_get_aaak_spec, mempalace_traverse, mempalace_find_tunnels, mempalace_create_tunnel, mempalace_list_tunnels, mempalace_delete_tunnel, mempalace_list_hallways, mempalace_delete_hallway, mempalace_follow_tunnels, mempalace_graph_stats, mempalace_hook_settings, mempalace_memories_filed_away, mempalace_reconnect, mempalace_instructions, mempalace_delete_by_source
version: 1.0.0
---

# MemPalace — DEPRECATED

**This skill is deprecated as of 2026-07-17.** The MemPalace Python package and all its MCP tools have been removed from the project (S10 licensing cleanup, Epic #5199 Phase B Wave 1).

## What replaced it

The new memory system is **Tortoise + FalkorDB** — a Docker-based knowledge graph with JSONL event sourcing. See:

- **Plan:** eldato repo `docs/epics/2026-07-14-memory-system/04-plan.md` (fetch: `gh api repos/daniel-ospina/eldato/contents/docs/epics/2026-07-14-memory-system/04-plan.md --jq .content | base64 -d`)
- **Architecture:** Tortoise Python package (CLI + Python API) → FalkorDB (Docker, port 6379)
- **Session reflection:** `reflect.py` (eldato repo `operations/memory/reflect.py`, legacy) → JSONL event log → Tortoise projection → FalkorDB; the NEW path is hosted Tortoise `POST /v1/sessions` via `extensions/reflect-hook.ts` (agent-infra)

## What to do instead

| Old (MemPalace) | New (Tortoise/FalkorDB) |
|---|---|
| `mempalace_search` | Tortoise FalkorDB Cypher queries |
| `mempalace_kg_add` | `tortoise projection` via JSONL events |
| `mempalace_diary_write` | hosted Tortoise `POST /v1/sessions` (via reflect-hook) / legacy eldato reflect.py → JSONL Event log |
| `mempalace_status` | `tortoise status` (per-ontology node counts) |
| `mempalace_wake-up` | Tortoise cross-ontology query |
| `mempalace_checkpoint` | `tortoise checkpoint` (Phase B) |

## Phase B remaining issues

- **S9** (unfiled): Skill wiring — wire research/strategy/vision skills to Tortoise
- **S11** (#6889): Onboarding — single-command deploy ≤5 min

Until S9 and S11 are complete, agents should use the plan document for memory-related decisions. Session context is the primary short-term memory source.
