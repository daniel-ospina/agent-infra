---
name: tortoise-rebuild
description: Recover a lost or corrupt Tortoise/FalkorDB graph — health check, JSONL event-log rebuild, backup restore. Use when a Tortoise DB won't open, reports 0 nodes, crashes, or when asked to rebuild/recover/restore the Tortoise graph.
domain: operations
type: Workflow
status: live
subjects.team: organisation-design-team
tags: [tortoise, falkordb, recovery, rebuild, backup, operations, health-check, jsonl, embedded]
summary: "Tortoise graph recovery — health check on open, transparent JSONL rebuild for embedded DBs, manual rebuild CLI, backup restore, production fail-loud policy."
created: 2026-08-07
updated: 2026-08-07
allowed-tools: read write edit bash grep find
---

> ⛔ **This skill MUST be read in full before any Tortoise graph rebuild or recovery.** Skipping can destroy data — a lossy rebuild is worse than no recovery.

# Tortoise Rebuild / Recovery

Recover a lost or corrupt Tortoise graph. The **event log (JSONL) is the source of truth**; the FalkorDB projection is a derived view — a lost DB can be rebuilt by replaying the log.

## When to Use

- DB won't open / queries fail
- Graph reports **0 nodes** but you know data existed
- Crash/interrupted restore left the graph empty
- Asked to "rebuild", "recover", "restore", or "check health" of the Tortoise graph
- After a FalkorDBLite corruption event (SQLite single-writer hazard — see #6761)

## Health Check on Open (automatic)

Since #428, `FalkorProjection.__init__` runs `_auto_health_recover()` before creating indexes:

- **Probe fails** (graph unresponsive):
  - **Production** (`FLY_APP_NAME` set) or **server/URI mode** → raises `RuntimeError` with the manual recovery command — NEVER silently rebuilds a remote DB from a local log.
  - **Embedded** with an adjacent `.jsonl` → auto-rebuilds via `recover_from_log`.
  - **Embedded** with no adjacent log → raises with restore-from-backup guidance.
- **Probe passes, 0 nodes + non-empty adjacent log** (embedded dev only) → auto-rebuilds.
- **Escape hatch:** `FalkorProjection(db, skip_health_check=True)` — used by the `rebuild` CLI itself (a broken DB must not block its own rebuild).

## Manual Rebuild

Two paths — know the difference:

**Safe recovery — `recover_from_log` (recommended; mirrors auto-recovery #428):**
Only rebuilds the "lost DB" case: DB has **0 total nodes** AND the log has **> 0 events**.
Partial divergence (`0 < db < log`) is left alone — SDK-created points may never appear
in the log; a rebuild would destroy them. Only rebuilds from an **unambiguous** log:
exactly one adjacent `.jsonl` (multiple logs = possible mid-restore artifacts; refuses).
Replays faithfully via `projection.apply()` — NOT `rebuild_all` (which drops context
for v2+ events, #49). Torn trailing lines (crash mid-append) are skipped, not fatal.

```python
# Safe manual recovery (embedded DBs) — same guards as auto-recovery
from tortoise.consistency import recover_from_log
from tortoise.projection import FalkorProjection

proj = FalkorProjection("~/.tortoise/tortoise.db", skip_health_check=True)
result = recover_from_log("~/.tortoise/logs", proj)  # dir containing exactly one .jsonl
print(result)  # {recovered, log_points, db_points, reason}
# recovered=False with a reason → do NOT wipe — investigate or restore from backup.
```

**Lossy fallback — `python -m tortoise rebuild --dir <jsonl-dir> --db <db>`:**
This CLI runs `rebuild_all()` — an unconditional `MATCH (n) DETACH DELETE n` followed
by replay. It does NOT apply the `recover_from_log` guards, and it drops `context` for
v2+ events (#49). Only use after confirming the DB is fully lost (0 nodes + single
unambiguous log) and you accept the lossiness:
- **Embedded mode (`path=`)** has no graph-name guard — the wipe runs unconditionally.
- **Server/URI mode** is refused on non-`test_*` graph names by the bulk-wipe guard.

```bash
# Lossy rebuild (only for a confirmed-lost embedded DB)
python -m tortoise rebuild --dir ~/.tortoise/logs --db ~/.tortoise/tortoise.db
```

## Backup / Restore

- `python -m tortoise backup --db <path> [--events <path>]` — JSONL archiver + BGSAVE (see `tortoise/backup.py`)
- `python -m tortoise migrate-db` — migrate legacy `embedded.db` → canonical `tortoise.db` (data-safe, marker-guarded; NOT a corrupt-DB rebuild)
- Divergence check (manual): `python -m tortoise check-consistency --db <path> --log <path>` — log-vs-graph count via `tortoise/consistency.py` `check_consistency()` (not run at startup)

## Production Rules

- **NEVER auto-rebuild a production (FLY) or remote/URI graph from a local log.** Fail loud with the manual command instead — a silent rebuild can mask an infra failure.
- For production recovery: restore from backup or point `TORTOISE_DB_URI` at the correct instance. Do not replay local logs into a cloud DB.

## Debugging Aids

- `tortoise/sdk.py` `status()` — `{connected, counts, total_entities}` connectivity + entity counts
- `tortoise/embedded_reaper.py` — embedded-mode process reaper (single-writer safety)
- `tortoise/consistency.py` — log-vs-graph divergence
- `tortoise/backup.py` — JSONL archive + BGSAVE

## Quick Decision Tree

> Continue following the workflow as mandated by this skill. Do not skip steps.

```
DB won't open / 0 nodes?
├─ FLY_APP_NAME or URI mode → manual recovery (never auto-rebuild) → backup/URI fix
└─ embedded + adjacent .jsonl → already auto-recovered on open (check logs for
   "auto-recovered embedded DB from ...") — verify with status()
└─ embedded + no log → restore from backup
```
