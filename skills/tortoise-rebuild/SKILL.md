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
updated: 2026-10-16
allowed-tools: read write edit bash grep find
---

> ⛔ **This skill MUST be read in full before any Tortoise graph rebuild or recovery.** Skipping can destroy data — a lossy rebuild is worse than no recovery.

# Tortoise Rebuild / Recovery

Recover a lost or corrupt Tortoise graph. The FalkorDB projection is a **derived view**: a lost DB is *reconstructed* by replaying the adjacent journal — and that reconstruction is never whole, because raw-Cypher writes ride no journal record. This runbook owns the recovery **procedure** only and carries **no durability claim of its own**. The single authority on what keeps a graph alive, its honest loss window, and the preserved-vs-lost node-class map is the tortoise repo's **`docs/durability-posture.md`** — link it; never restate its class list here.

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
- **A rescue sidecar is present but untrustworthy** → `recover_from_log` returns `recovered: False` with a reason naming the sidecar. It deliberately does *not* fall through to the apply-only replay, which would report success while the graph-only nodes that file alone holds stay lost. Repair it — or delete it *knowingly* to accept that loss — then re-run.
- **A sticky `config_reset` marker suppresses auto-recovery.** The marker is a graph-resident `:Meta` node, so a graph whose data is gone but whose marker remains reports `count(n) > 0`: `recover_from_log` returns `recovered: False`, reason `graph already has nodes — no rebuild`, and the automatic path stays closed until an operator clears the marker (see *Config across the wipe*). Safe — it refuses rather than wipes — but it is a real availability effect and it is deliberate.

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
This CLI runs `rebuild_all()` — a `MATCH (n) DETACH DELETE n` followed by replay,
gated by the per-call `confirm_destructive=True` token the CLI passes (#2944). It does
NOT apply the `recover_from_log` guards, and it drops `context` for v2+ events (#49).
Only use after confirming the DB is fully lost (0 nodes + single unambiguous log) and
you accept the lossiness:
- **Structural wipe guard (#2944):** `rebuild_all()` / `rebuild()` are keyword-only
  `confirm_destructive: bool = False` and **refuse by default, embedded mode
  included**. The CLI is the operator authorization point; the old `_skip_guard`
  bypass is removed. A direct Python call must pass the token explicitly.
- **Embedded mode (`path=`)** is exempt from the graph-**name** check (L2), but it is
  **not** exempt from the token: an embedded wipe no longer runs unconditionally.
- **Server/URI mode** is refused on non-`test_*` graph names by the bulk-wipe guard
  (L2 defence in depth) **even when the token was passed**.

```bash
# Lossy rebuild (only for a confirmed-lost embedded DB)
python -m tortoise rebuild --dir ~/.tortoise/logs --db ~/.tortoise/tortoise.db
```

### The rescue sidecar, and what refuses BEFORE the wipe

Immediately before the wipe `rebuild_all` writes a **pre-wipe rescue sidecar**
next to the log — `<log_dir>/.tortoise-prewipe-snapshot.json` (so the `--dir`
above) — and retires it only once the replay completes. It carries the
classes that ride no journal record and are not re-derivable, so a crash
mid-replay cannot orphan them: the next `rebuild_all` merges the leftover in,
and the embedded auto-recovery path routes through `rebuild_all` while a
sidecar is pending. **The authoritative class map is
`docs/durability-posture.md` in the tortoise repo — do not restate it here.**

**Every item below aborts with the graph UNTOUCHED. There is no bypass:**

- any pre-wipe snapshot read fails (a corrupt or merely heavy `properties(n)`
  read can fail while the light `DELETE` would have succeeded) → `RuntimeError`
  *"rebuild aborted BEFORE the graph wipe: the pre-wipe snapshot could not be
  captured"*;
- the sidecar exists but cannot be trusted — a symlink, a non-regular file, an
  oversized file (> 64 MiB), unreadable or invalid JSON, a malformed entry, an
  **unsupported `version`**, or a **section key this build cannot restore**;
- the sidecar records a **different graph identity** — merging it would
  contaminate this graph and then retire the only copy of another graph's data;
- the destructive token is missing, or a non-`test_*` server graph is targeted;
- `require_empty=True` and the graph gained nodes since the check (the
  auto-recovery route re-validates its earlier 0-node probe at the wipe).

**Deleting a rescue file is a data decision, not cleanup.** A **pending** file
holds classes the journal cannot reproduce, so deleting it accepts that loss —
legitimate when you have established its entries are stale or expendable (the
`#2814` colliding-key residual's remedy), never merely to make a refusal go
away. A **retired** (entry-less) artifact merges nothing: always safe to
delete.

### Config across the wipe, and the `config_reset` marker

The wipe is unconditional and only the journal is replayed, so authoritative
configuration (graph-resident, unjournaled, not re-derivable) is **captured
into the sidecar and restored after the replay**; `tortoise rebuild` then
reports `Config: <restored> of <expected> authoritative entr(y/ies)
restored`. The restore is **verified after the wipe** — a captured config
identity missing from the rebuilt graph is an ERROR, never a silent success.

When config cannot be *proven* restored — or, on a rescue file written before
config preservation existed, when the state is **unknown** rather than proven
reset — `rebuild_all` sets the **sticky** `:Meta{key:'config_reset'}` marker
(properties `key`, `at`, `last_at`, `count`, `reason`). Absence is what a
never-configured graph looks like, so the marker is the third state: *config
existed and did not come back*. It is **not** a tombstone.

```cypher
MATCH (n:Meta {key:'config_reset'}) RETURN properties(n)
```

- **Clear it** only after re-provisioning the configuration the marker
  reported missing: `sdk._clear_config_reset()` → `True` when one was present.
  `rebuild_all` never clears it — that is exactly what makes it reliable.

### Deploy / rollback ordering (the version gate)

The sidecar's `version` is stamped by the **running build**, and it is a
**cross-build contract**: a build that does not recognise the version — or
cannot restore a section the file carries — **refuses the rebuild** rather than
accept the file and wipe over a class it cannot see. So:

- deploy the new binary **before** the first rebuild that writes a new-version
  sidecar;
- before rolling back, **remove any sidecar whose version the target build does
  not read**. A *retired* (entry-less) file is stamped with the current version
  too, so it blocks an older build even though it merges nothing — that one is
  safe to delete. A *pending* one is not: land the newer build, never delete
  rescue data.

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
├─ embedded + adjacent .jsonl → already auto-recovered on open (check logs for
│  "auto-recovered embedded DB from ...") — verify with status()
│  └─ recovered: False? Read the reason — it is not a lost log:
│     ├ "graph already has nodes — no rebuild" + `config_reset` set → the
│     │  marker alone is why. Re-provision, then sdk._clear_config_reset().
│     └ "a pre-wipe snapshot ... cannot be trusted" → repair or delete the
│        PENDING file, then re-run. Never delete a pending file merely to
│        make a refusal go away.
├─ embedded + no log → restore from backup
└─ a rescue sidecar `.tortoise-prewipe-snapshot.json` present?
   ├─ PENDING (carries entries) → re-run `tortoise rebuild --dir <log_dir>`;
   │  delete it ONLY to accept losing what it alone holds
   └─ RETIRED (entry-less) → merges nothing; safe to delete
```
