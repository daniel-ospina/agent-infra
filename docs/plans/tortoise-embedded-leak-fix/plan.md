# Implementation Plan: Tortoise Embedded Mode Redis-Server Process Leak

**Date**: 2026-08-06
**Scope**: Tortoise embedded mode (redislite) orphaned redis-server process elimination
**Status**: Draft — for review

---

## 1. APPROACH SELECTION

### Selected Approach: Alt 4 — Tiered Defense-in-Depth (A through E), Full Migration

**Tier A**: Stable-path singleton (`TORTOISE_EMBEDDED_PATH`, default `~/.tortoise/tortoise.db`) — eliminates the path diversity that defeats reusability.

**Tier A+**: Unified migration of ALL ~25 connection points to the canonical path, plus hard-reject of relative paths in `FalkorProjection.__init__` — closes the leak at the source.

**Tier B**: Stateless no-path/tempdir reaper (`CLIENT LIST` verified, `PING 2s x3`, `SIGTERM`-first, then `SIGKILL`) — catches orphaned servers from the SIGKILL window and any edge cases the migration misses.

**Tier C**: Lifecycle hardening (context manager on `FalkorProjection`, signal handler for SIGTERM/SIGINT, `setsid`/`killpg` for no-path connections) — makes the embedded DB a well-behaved process citizen.

**Tier D**: Docker orchestration routing (cron/daemon/MCP → `docker://` URI, with environment-based routing in `entrypoint.sh`) — ensures long-running processes never use embedded mode.

**Tier E**: Gate (FLY guard on embedded mode, loud warning on relative-path use) — prevents regression.

### Why This Is the Best Approach

**Outcome quality**: Alt 4 eliminates the leak at every layer. The stable path makes redislite's native reuse work (same path → 1 server cross-process). The migration closes all 25 leak points. The reaper handles the SIGKILL window — the dominant kill mode in agent orchestration. The lifecycle hardening makes graceful shutdown work for SIGTERM paths. The Docker routing keeps production processes off embedded mode entirely. The FLY guard prevents new code from reintroducing the leak. Each tier addresses a distinct failure mode; no single tier is the sole defense.

**Edge case handling**: All six leak categories are covered:
- Category 1 (no-path connections from `redislite.Redis()`): reaper + Tier A hard-reject
- Category 2 (tempdir from `tempfile.mkdtemp()`): reaper
- Category 3 (relative/per-CWD paths): migration to canonical + hard-reject
- Category 4 (SIGKILL before `close()`): reaper
- Category 5 (concurrent spawn to same path): verified no-leak (redislite native reuse), no action needed
- Category 6 (import-side-effect instantiation): Tier A hard-reject prevents this

**Failure mode coverage**: 
- SIGKILL (dominant): reaper sweeps orphans
- SIGTERM (secondary): signal handler + context manager clean shutdown
- Crash/exception: context manager + `__del__` fallback
- Import-time leak: hard-reject in constructor
- Future regression: FLY guard catches it at dev time

**Future extensibility**: Each tier is independently testable and replaceable. The stable-path pattern is the standard approach for embedded databases (SQLite, RocksDB, BoltDB all do this). The reaper is stateless — no PID files, no state files, no cleanup needed. If redislite is eventually replaced with a different embedded DB, only Tier A changes; Tiers B–E are backend-agnostic.

**Alignment with product trajectory**: Docker/Cloud is the product; embedded is a dev stepping stone. Alt 4 respects this — Tier D routes production to Docker, Tier A keeps embedded clean for dev loops. Alt 1 (Docker everywhere) would force Docker into dev, which was explicitly rejected as "heavyweight and unnecessary per the product decision."

### Rejected Alternatives

#### Alt 1: Docker Everywhere (Eliminate Embedded)
**When this WOULD have been better**: If the product trajectory were to abandon embedded mode entirely (Docker-only product), this would be the cleanest solution — zero leak surface, no reaper needed, no migration. It's the right solution for production. It's the wrong solution for dev loops where Docker daemon availability is not guaranteed and rapid iteration matters.

#### Alt 2: Monkeypatch Choke-Point
**When this WOULD have been better**: If there were only 2–3 connection points (all in library code) and the redislite API were stable and version-pinned, a focused monkeypatch would be the minimal-change solution. In our case: 25 connection points span library, CLI, scripts, and tests; redislite is not version-pinned; the monkeypatch is process-global (kills legitimate multi-DB use cases); import-order fragility means the patch could silently fail. The monkeypatch would be defense-in-depth ONLY if it were a hard-reject (fail loudly) rather than a silent redirect — and Alt 4 already does that with the hard-reject in the constructor.

#### Alt 3: Process-Supervisor (PDEATHSIG)
**When this WOULD have been better**: On Linux, PR_SET_PDEATHSIG is near-perfect — the kernel guarantees child cleanup on parent death with zero race window. If the dev machine were Linux and the deployment target were Linux-only, this would be the simplest approach (~5 files, proxy subprocess). But macOS is the dev machine, and macOS has no PR_SET_PDEATHSIG. The polling-based fallback has a race window between parent death and poll interval — exactly the window where SIGKILL'd agents leave orphans. Fatal for the dev machine.

#### Alt 4 + Light Migration (Fix Library Only, Let Reaper Handle Scripts)
**When this WOULD have been better**: If the 14 relative-path graph-scripts were truly one-off/historical (never re-run), it would be wasteful to migrate them. But they ARE re-run — some in automated cycles, some by agents during issue resolution. Every run of a relative-path script creates an orphanable server. The reaper would clean it up, but only after a 6-second window (2s × 3 PING rounds). Full migration eliminates the window entirely for these scripts. The reaper is defense-in-depth, not primary defense. Quality over convenience: full migration produces the better outcome.

---

## 2. PROBLEM STATEMENT

Tortoise embedded mode (redislite) leaks redis-server OS processes. redislite spawns one OS-level redis-server process per connection when the path is not reusable — and paths are reused ONLY when they match exactly (absolute, normalized). 19 graph-scripts use relative paths (`FalkorProjection('tortoise.db')`), producing a different absolute path per CWD. 4 scripts bypass the projection entirely (`redislite.falkordb_client.FalkorDB(path)`). 2 library paths use `_PROJECT_ROOT / "tortoise.db"` (resolved to different absolutes in different contexts). When the parent process is killed with SIGKILL — the dominant kill mode in agent orchestration — all lifecycle hooks (`close()`, `atexit`, `__del__`, signal handlers) are defeated. The redis-server child is orphaned.

**Impact**: 650+ orphaned redis-server processes observed on the dev machine (2026-08-06), consuming ~1.7GB RSS. Each orphan holds a socket and memory. Over weeks of agent-driven development, the machine degrades until manual intervention.

**Root cause**: (1) No canonical path — every relative, per-CWD, or unnormalized path creates a new, non-reusable redislite server. (2) No reaper — nothing detects or cleans up orphaned servers. (3) No lifecycle hardening — no signal handlers, no process groups, no graceful shutdown path. (4) SIGKILL defeats everything — the dominant kill mode bypasses all Python-level cleanup.

---

## 3. PROPOSED SOLUTION

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        TIER E: FLY GATE                          │
│  Prevents regression — warns on relative-path use, blocks in CI │
├─────────────────────────────────────────────────────────────────┤
│                     TIER D: DOCKER ROUTING                       │
│  cron/daemon/MCP → docker://   |   dev/CLI → embedded ok        │
├─────────────────────────────────────────────────────────────────┤
│                 TIER C: LIFECYCLE HARDENING                      │
│  Context manager  |  SIGTERM/SIGINT handler  |  setsid/killpg   │
├─────────────────────────────────────────────────────────────────┤
│                   TIER B: TEMPDIR REAPER                         │
│  Stateless orphan detector → CLIENT LIST → PING 2s×3 → SIGTERM  │
│  → SIGKILL. Covers SIGKILL window.                               │
├─────────────────────────────────────────────────────────────────┤
│              TIER A+: MIGRATION + HARD-REJECT                     │
│  ~25 connection points → canonical path  |  Relative-path → err │
├─────────────────────────────────────────────────────────────────┤
│                 TIER A: STABLE-PATH SINGLETON                     │
│  TORTOISE_EMBEDDED_PATH env → default ~/.tortoise/tortoise.db    │
│  One-time migration of existing data to canonical path           │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Canonical path, not singleton lock**: We use a single canonical path for embedded mode, not a process-level singleton. redislite's native behavior (same path → 1 server cross-process) gives us the singleton semantics without a lock. Multiple processes connecting to the same canonical path share one redis-server. This is the same model SQLite uses.

2. **Hard-reject, not silent redirect**: When `FalkorProjection.__init__` receives a relative path, it raises `ValueError` with a clear message pointing to the canonical path. This fails loudly rather than silently changing what data the caller operates on. Silent redirects (monkeypatch approach) would break scripts that deliberately use separate DBs.

3. **Stateless reaper**: The reaper has no PID files, no state files, no database. It uses `CLIENT LIST` on each redislite server to verify there are no active connections, then `PING` with exponential backoff to confirm liveness, then `SIGTERM` → wait → `SIGKILL`. Stateless means no cleanup needed, no stale state, no race conditions with PID reuse.

4. **Reaper is defense-in-depth, not primary defense**: The migration (Tier A+) eliminates the leak at the source. The reaper (Tier B) catches the residual window — SIGKILL during an active connection, edge cases the migration misses, third-party code that imports redislite directly.

---

## 4. IMPLEMENTATION PLAN

### Child 1: Tier A + Tier A+ — Stable-Path Singleton + Migration + Guards [THE FIX]

**Goal**: Eliminate path diversity. Every embedded connection uses exactly one canonical path. Relative paths are rejected at the constructor.

#### Step 1.1: Add `TORTOISE_EMBEDDED_PATH` resolution to `FalkorProjection.__init__`

**File**: `tortoise/projection/__init__.py` (and sync to `tortoise/projection.py`)

- Add a module-level helper `_resolve_embedded_path(path)` that:
  1. If `path` is `None`, return `None` (caller wants Docker/server mode via `host=`)
  2. If `path` is relative (doesn't start with `/` or `~`), raise `ValueError("Relative paths are not supported for embedded mode. Use TORTOISE_EMBEDDED_PATH env var or an absolute path. Canonical: {canonical}")`
  3. If `path` starts with `~`, expand with `os.path.expanduser()`
  4. Resolve with `os.path.realpath()` (follows symlinks, normalizes)
  5. Return resolved path

- Default canonical path: `os.environ.get("TORTOISE_EMBEDDED_PATH", os.path.expanduser("~/.tortoise/tortoise.db"))`

- The `FalkorProjection.__init__` embedded branch changes from:
  ```python
  if path is not None:
      from redislite.falkordb_client import FalkorDB
      self.db = FalkorDB(path)
  ```
  to:
  ```python
  if path is not None:
      from redislite.falkordb_client import FalkorDB
      resolved = _resolve_embedded_path(path)
      self.db = FalkorDB(resolved)
      self._embedded_path = resolved  # stored for reaper visibility
  ```

#### Step 1.2: Add `TortoiseSDK` canonical-path resolution

**File**: `tortoise/sdk.py`

- In `TortoiseSDK.__init__`, when `db_path` is provided (non-URI mode), resolve it through the same `_resolve_embedded_path`:
  ```python
  if self._db_path is not None:
      from .projection import _resolve_embedded_path
      self._db_path = _resolve_embedded_path(self._db_path)
  ```

#### Step 1.3: Migrate ~25 connection points to canonical path

**Files**: 25 files across 4 categories.

**Category A — 14 graph-scripts with relative `'tortoise.db'`**:
`graph-scripts/auto_discovery_cycle1.py`, `graph-scripts/auto_discovery_cycle2.py`, `graph-scripts/auto_discovery_cycle3.py`, `graph-scripts/auto_discovery_cycle4.py`, `graph-scripts/auto_discovery_all.py`, `graph-scripts/bp_approach_cycle1.py`, `graph-scripts/bp_approach_cycle3.py`, `graph-scripts/bp_approach_cycle4.py`, `graph-scripts/bp_pros_cons_cycle5.py`, `graph-scripts/cost_control_cycle1.py`, `graph-scripts/cost_control_cycle2.py`, `graph-scripts/cost_control_cycle3.py`, `graph-scripts/cost_control_cycle4.py`, `graph-scripts/add_convergence_evidence.py`, `graph-scripts/test_6707_shock.py`

Change: `FalkorProjection('tortoise.db')` → `FalkorProjection(_canonical_path())` where `_canonical_path()` is a local helper reading `TORTOISE_EMBEDDED_PATH` with the default fallback. Add a comment: `# Uses canonical embedded path — safe to SIGKILL; reaper covers orphan window`.

**Category B — 4 direct redislite bypasses**:
`graph-scripts/fix_6704_operational_grounding.py`, `graph-scripts/fix_6706_approach_grounding.py`, `graph-scripts/fix_6709_comparison_to_approach.py`, `scripts/restore_graph_issue100.py`

Change: `from redislite.falkordb_client import FalkorDB; db = FalkorDB(absolute_path)` → Either (a) switch to `FalkorProjection(absolute_path)` via the library (preferred, gives them lifecycle management), OR (b) resolve through the same canonical helper and add explicit `db.close()`.

**Category C — 4 absolute hardcoded paths**:
`graph-scripts/fix_6704_operational_grounding.py` (already absolute, but bypasses projection), `graph-scripts/fix_6706_approach_grounding.py` (same), `graph-scripts/fix_6709_comparison_to_approach.py` (same), `scripts/restore_graph_issue100.py` (hardcoded `/tmp/tortoise_restore_src.db`)

For the three fix_670x scripts: switch to `FalkorProjection` with the canonical path. For `restore_graph_issue100.py`: this is a genuine multi-DB use case (source is a fragment DB, target is Docker). Keep the hardcoded `/tmp/` source path but add an explicit `src_db.close()` and document that this is a deliberate non-canonical use.

**Category D — 5 tortoise source files with per-CWD paths**:
`tortoise/pipeline_cli.py` (line 131: `_PROJECT_ROOT / "tortoise.db"`), `tortoise/backup.py` (line 85: `FalkorProjection(db_path)` from argument), `tortoise/__main__.py` (lines 11, 128, 209, 422, 434, 441, 449, 811, 1059 — various `FalkorProjection(args.db)` patterns), `tortoise/mcp_server.py` (line 31: `FalkorProjection.from_uri(_db_uri)`)

- `pipeline_cli.py`: Resolve `_PROJECT_ROOT / "tortoise.db"` through canonical helper.
- `backup.py`: In `restore()`, resolve `db_path` through canonical helper if not already absolute.
- `__main__.py`: In `init` command embedded fallback (line 256), resolve `args.path` through canonical helper. For Docker-mode paths (URI), no change needed.
- `mcp_server.py`: Already uses `TORTOISE_DB_URI` — no change needed for embedded path. Add comment documenting the routing.

#### Step 1.4: One-time migration script

**New file**: `scripts/migrate-to-canonical-path.sh` (or Python script)

For users with existing data at non-canonical paths (e.g., `./tortoise.db`, custom `--db` paths):
1. Detect if `~/.tortoise/tortoise.db` exists
2. If not, find the most recently modified `tortoise.db` in likely locations (`./tortoise.db`, `$PROJECT_ROOT/tortoise.db`, previous `TORTOISE_EMBEDDED_PATH` value)
3. Copy it to `~/.tortoise/tortoise.db` (or warn user to set `TORTOISE_EMBEDDED_PATH`)
4. Print clear instructions

#### Step 1.5: Guard — hard-reject relative paths

Already covered in Step 1.1. The `_resolve_embedded_path` function raises `ValueError` for relative paths. This is the defense-in-depth against future code reintroducing the leak. The error message includes the canonical path so the developer knows what to use.

#### Step 1.6: Update `entrypoint.sh` and default path in `__main__.py`

- `tortoise/__main__.py` line ~281: change default `embedded.db` → `tortoise.db` (or read `TORTOISE_EMBEDDED_PATH`)
- `entrypoint.sh`: add explicit `TORTOISE_EMBEDDED_PATH` default
- `tortoise-capture` TypeScript extension: already uses `~/.tortoise/tortoise.db` — no change needed

---

### Child 2: Tier B + Tier C — Reaper + Lifecycle Hardening [SAFETY NET]

**Goal**: Catch orphaned servers from the SIGKILL window and make embedded mode a well-behaved process citizen.

#### Step 2.1: Stateless orphan reaper

**New file**: `tortoise/embedded_reaper.py`

```python
"""Stateless orphan reaper for redislite redis-server processes.

Covers the SIGKILL window — when the parent process is killed with SIGKILL,
all Python-level cleanup (close(), atexit, __del__, signal handlers) is
defeated. The redis-server child is orphaned. This reaper finds and kills
orphaned servers with no active CLIENT LIST connections.

Stateless: no PID files, no state files, no database. Uses CLIENT LIST
(on redislite's embedded redis) to determine if a server has active clients.
"""
```

Algorithm:
1. `ps aux | grep redis-server` — find all redis-server processes (filter out grep, filter out Docker containers by checking cgroup/ancestry)
2. For each candidate PID:
   a. Parse its `--port` from `/proc/{pid}/cmdline` (or `ps` args on macOS) to get the Unix socket path (redislite uses Unix sockets, not TCP)
   b. Connect with a raw Redis client: `redis-cli -s {socket_path} CLIENT LIST`
   c. If connection fails (server dead but process table stale): SIGKILL immediately
   d. If `CLIENT LIST` returns only the reaper's own connection: server is orphaned
   e. Send `PING` — wait 2s — `PING` — wait 2s — `PING` (3 rounds, 6s total). If ANY `PING` fails, server is dead/unresponsive → SIGKILL
   f. Send `SHUTDOWN NOSAVE` (preferred) or `SIGTERM` — wait 2s
   g. If process still alive: `SIGKILL`
3. Log actions to a structured log (`~/.tortoise/reaper.log` or stdout)
4. Exit 0 (stateless — no cleanup needed)

**Key properties**:
- Runs as a standalone script: `python -m tortoise.embedded_reaper`
- No persistent state — can be run from cron, from agent startup, or ad-hoc
- `CLIENT LIST` prevents killing servers with active connections (covers the multi-process case where one process is alive and using the DB)
- Idempotent — safe to run repeatedly
- Testable — can be run against a test redislite instance

#### Step 2.2: Context manager on FalkorProjection

**File**: `tortoise/projection/__init__.py` (and sync to `tortoise/projection.py`)

Add `__enter__` / `__exit__`:
```python
def __enter__(self):
    return self

def __exit__(self, exc_type, exc_val, exc_tb):
    self.close()
    return False  # don't suppress exceptions
```

This enables `with FalkorProjection(path) as proj:` usage, which the migration (Child 1) should adopt where possible.

#### Step 2.3: `__del__` fallback on FalkorProjection

**File**: `tortoise/projection/__init__.py` (and sync)

```python
def __del__(self):
    """Best-effort close on GC. Does NOT run if SIGKILL'd."""
    try:
        self.close()
    except Exception:
        pass  # GC can happen in any order; don't raise
```

This catches the case where a `FalkorProjection` is created and never `.close()`d but the process exits normally (not SIGKILL). It's a safety net, not a primary defense.

#### Step 2.4: Signal handler for SIGTERM/SIGINT

**New file**: `tortoise/embedded_lifecycle.py`

```python
"""Lifecycle management for embedded mode — signal handlers, process groups."""

import os
import signal
import atexit

_embedded_instances: list = []  # weakrefs to FalkorProjection instances

def register_embedded_instance(proj):
    """Register a FalkorProjection for cleanup on signal."""
    import weakref
    _embedded_instances.append(weakref.ref(proj))

def _cleanup_all():
    for ref in _embedded_instances:
        proj = ref()
        if proj is not None:
            try:
                proj.close()
            except Exception:
                pass

def _signal_handler(signum, frame):
    _cleanup_all()
    # Re-raise the signal with default handler
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)

def install_embedded_lifecycle():
    """Install signal handlers and atexit for embedded mode. Idempotent."""
    if not _embedded_instances:  # only install once (use flag in production)
        signal.signal(signal.SIGTERM, _signal_handler)
        signal.signal(signal.SIGINT, _signal_handler)
        atexit.register(_cleanup_all)
```

This is called once at module import time (with a guard to prevent double-install). It covers graceful shutdown (SIGTERM, SIGINT). It does NOT cover SIGKILL — that's the reaper's job.

#### Step 2.5: `setsid`/`killpg` for no-path connections (defense-in-depth)

After Tier A, there should be NO no-path connections. But as defense-in-depth, if a redislite server is spawned without a path (or with a tempdir path), put it in its own process group so it can be cleanly killed:

**File**: `tortoise/projection/__init__.py` — in the embedded branch after creating `self.db`:

```python
# Put embedded redis-server in its own process group for clean kill
if hasattr(self.db, 'redis') and hasattr(self.db.redis, 'pid'):
    try:
        os.setpgid(self.db.redis.pid, 0)  # new process group
    except (OSError, ProcessLookupError):
        pass  # server may have already exited
```

And in the signal handler (Step 2.4), use `os.killpg()` for any registered instances.

---

### Child 3: Tier D + Tier E — Docker Orchestration Routing + FLY Guard [HARDENING]

**Goal**: Keep production/long-running processes on Docker; prevent regression.

#### Step 3.1: Docker routing in entrypoint.sh

**File**: `entrypoint.sh` (or equivalent startup script)

Add explicit routing logic:
```bash
# If running as a daemon, cron, or MCP server, force Docker
if [[ "${TORTOISE_ROLE:-}" =~ ^(daemon|cron|mcp|server)$ ]]; then
    if [[ -z "${TORTOISE_DB_URI:-}" ]]; then
        export TORTOISE_DB_URI="docker://:${FALKORDB_PASSWORD:-}@${FALKORDB_HOST:-localhost}:${FALKORDB_PORT:-16379}/tortoise"
    fi
    echo "[tortoise] Routing to Docker (role=${TORTOISE_ROLE})"
fi
```

For dev/CLI usage, default to `TORTOISE_EMBEDDED_PATH`.

#### Step 3.2: Docker routing in `TortoiseSDK` / `FalkorProjection.from_uri`

**File**: `tortoise/projection/__init__.py`

Add a `from_env()` classmethod that inspects the environment and selects the right mode:
```python
@classmethod
def from_env(cls, **kwargs) -> "FalkorProjection":
    """Auto-select Docker or embedded based on environment.

    Priority:
    1. TORTOISE_DB_URI (explicit — Docker or custom)
    2. FALKORDB_HOST set → Docker (implicit)
    3. TORTOISE_ROLE=daemon|cron|mcp|server → Docker
    4. TORTOISE_EMBEDDED_PATH → embedded (canonical)
    5. Default ~/.tortoise/tortoise.db → embedded
    """
    import os
    db_uri = os.environ.get("TORTOISE_DB_URI")
    if db_uri:
        return cls.from_uri(db_uri)
    # ... etc
```

This gives all callers a single, correct entry point.

#### Step 3.3: FLY guard

**File**: `tortoise/__main__.py` or a pre-commit hook

In the `tortoise check` command (which already exists), add:
- Check for running redislite processes that aren't on the canonical path
- Check for relative-path `FalkorProjection(` calls in Python files
- Emit warnings (not errors — dev freedom)

This is a development-time guard — it catches new code that would reintroduce the leak before it reaches production.

#### Step 3.4: CI pre-commit hook (optional — future work)

Add a pre-commit hook that greps for `FalkorProjection(` with a relative path argument and blocks the commit. This is the hard gate. Can be implemented as a simple grep-based check.

---

## 5. TESTING STRATEGY

### Unit Tests

| Test | What It Verifies | Location |
|------|-----------------|----------|
| `test_canonical_path_resolution` | `_resolve_embedded_path` normalizes `~`, `..`, symlinks, rejects relative | `tests/test_projection.py` |
| `test_relative_path_rejected` | `FalkorProjection('tortoise.db')` raises `ValueError` | `tests/test_projection.py` |
| `test_canonical_path_reuse` | Two `FalkorProjection(canonical)` share one redis-server (CLIENT LIST count) | `tests/test_projection.py` |
| `test_context_manager` | `with FalkorProjection(path) as proj:` calls `.close()` on exit | `tests/test_projection.py` |
| `test_del_fallback` | `proj = FalkorProjection(path); del proj; gc.collect()` triggers close | `tests/test_projection.py` |
| `test_signal_handler_cleanup` | SIGTERM during active projection triggers close before exit | `tests/test_embedded_lifecycle.py` |
| `test_reaper_idempotent` | Running reaper twice produces same (clean) result | `tests/test_embedded_reaper.py` |
| `test_reaper_skips_active` | Reaper does NOT kill a server with active CLIENT LIST connections | `tests/test_embedded_reaper.py` |
| `test_reaper_kills_orphan` | Reaper kills a server with only its own CLIENT LIST connection | `tests/test_embedded_reaper.py` |
| `test_reaper_sigkill_fallback` | Reaper SIGKILLs a server that doesn't respond to SHUTDOWN | `tests/test_embedded_reaper.py` |

### Integration Tests

| Test | What It Verifies |
|------|-----------------|
| `test_full_migration_script` | Migration script copies DB to canonical path, doesn't overwrite existing |
| `test_end_to_end_sigkill` | Start projection → SIGKILL parent → reaper finds and cleans orphan |
| `test_concurrent_multi_process` | 4 processes connect to canonical path → 1 redis-server → all can query |
| `test_mcp_server_docker_routing` | MCP server with TORTOISE_ROLE=mcp routes to Docker, not embedded |

### Existing Test Compatibility

- `tests/conftest.py` already forces Docker URI — no change needed
- `tests/test_projection.py` uses temp paths with explicit `close()` — update to use canonical path or temp path-as-argument (temp paths are absolute, so the hard-reject won't block them)
- `tests/test_cross_ontology.py` uses absolute paths (`/tmp/tortoise-test-s6.db`) — these pass the `is_absolute` check, no change needed

### Manual Verification

1. Run `tortoise init` → verify embedded mode uses `~/.tortoise/tortoise.db`
2. Run a graph-script with relative path → verify `ValueError` with helpful message
3. SIGKILL a long-running `tortoise index github` → run reaper → verify orphan cleaned
4. Run 3 concurrent `tortoise query` processes → verify single `redis-server` via `ps aux`

---

## 6. VERIFICATION PLAN

### Pre-Deploy Verification (Dev Machine)

1. **Pre-existing orphans**: Run reaper on the current dev machine → verify 650+ orphans are cleaned
2. **No new orphans after migration**: Run the full test suite → run reaper → verify zero orphans found
3. **Canonical path is sticky**: Set `TORTOISE_EMBEDDED_PATH`, run scripts, check `CLIENT LIST` on the canonical server → verify all connections go to one server
4. **Relative path loud failure**: Run `python -c "from tortoise.projection import FalkorProjection; FalkorProjection('tortoise.db')"` → verify `ValueError`
5. **Docker routing**: Run MCP server with `TORTOISE_ROLE=mcp` → verify it connects to Docker, not embedded

### Post-Deploy Verification (Production)

1. **Health check**: `tortoise check` passes with Docker mode
2. **Reaper cron**: Reaper runs hourly via cron → zero orphans in production (production uses Docker, so this should be a no-op)
3. **Monitoring**: Add reaper log metrics to monitoring dashboard

### Rollback Plan

1. Revert the hard-reject in `FalkorProjection.__init__` (comment out the `ValueError` for relative paths) → scripts continue to work with their old paths
2. Set `TORTOISE_EMBEDDED_PATH` to the old default → connections go to the old path
3. The reaper is stateless and non-destructive — can be disabled by removing the cron job

---

## 7. ACCEPTANCE CRITERIA

1. **Zero process leaks under SIGKILL**: After running the full test suite and SIGKILL'ing any long-running process mid-operation, the reaper finds zero orphaned redis-server processes.
2. **Single server for canonical path**: Running 5 concurrent processes using `FalkorProjection` with the canonical path results in exactly 1 redis-server process.
3. **Relative paths rejected**: `FalkorProjection('tortoise.db')` raises a `ValueError` with a message that includes the canonical path.
4. **Reaper does not kill active servers**: Running the reaper while a legitimate process is using the DB does not disrupt that process.
5. **Context manager works**: `with FalkorProjection(path) as proj:` correctly calls `.close()` on scope exit, including on exception.
6. **Docker routing for daemons**: Processes with `TORTOISE_ROLE` set to `daemon`, `cron`, `mcp`, or `server` connect to Docker, not embedded.
7. **Existing tests pass**: All existing tests pass without modification (tests use Docker or absolute temp paths).
8. **One-time migration is safe**: Running the migration script does not overwrite existing data; it detects collisions and warns.

---

## 8. RUNTIME PREREQUISITES

### New Dependencies
- None. The reaper uses `ps`, `/proc` (Linux) or `ps` args (macOS), and the `redis` Python package (already a dependency of redislite) for `CLIENT LIST`.

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `TORTOISE_EMBEDDED_PATH` | Canonical path for embedded mode | `~/.tortoise/tortoise.db` |
| `TORTOISE_DB_URI` | Docker/server URI (existing) | (none) |
| `FALKORDB_HOST` | Docker host (existing) | `localhost` |
| `FALKORDB_PORT` | Docker port (existing) | `16379` |
| `TORTOISE_ROLE` | Process role for routing (`daemon`, `cron`, `mcp`, `server`, `dev`) | (none) |

### Files Changed

| File | Change Type | Child |
|------|-------------|-------|
| `tortoise/projection/__init__.py` | Add `_resolve_embedded_path`, hard-reject, context manager, `__del__`, stored `_embedded_path` | 1, 2 |
| `tortoise/projection.py` | Sync all changes from `__init__.py` | 1, 2 |
| `tortoise/sdk.py` | Resolve `db_path` through canonical helper | 1 |
| `tortoise/__main__.py` | Resolve `args.path` in embedded fallback, update default path, add `from_env()`, Docker routing in `check` | 1, 3 |
| `tortoise/backup.py` | Resolve `db_path` in `restore()`, add `close()` to `_bgsave()` | 1 |
| `tortoise/pipeline_cli.py` | Resolve `_PROJECT_ROOT / "tortoise.db"` through canonical helper | 1 |
| `tortoise/embedded_reaper.py` | **NEW**: Stateless orphan reaper | 2 |
| `tortoise/embedded_lifecycle.py` | **NEW**: Signal handlers, `atexit`, `setsid` | 2 |
| `scripts/migrate-to-canonical-path.sh` | **NEW**: One-time migration script | 1 |
| 14 graph-scripts | `FalkorProjection('tortoise.db')` → canonical path | 1 |
| 4 fix/restore scripts | Direct `redislite` bypasses → `FalkorProjection` + canonical | 1 |
| `entrypoint.sh` | Add `TORTOISE_ROLE` routing, `TORTOISE_EMBEDDED_PATH` default | 3 |

### Estimated Effort

| Child | Description | Estimate |
|-------|-------------|----------|
| Child 1 | Stable-path + migration + guards | 4–6 hours |
| Child 2 | Reaper + lifecycle hardening | 3–4 hours |
| Child 3 | Docker routing + FLY guard | 2–3 hours |
| **Total** | | **9–13 hours** |

---

## 9. RISKS AND MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Relative-path hard-reject breaks a legitimate use case | Low | Medium | Error message points to canonical path; user sets `TORTOISE_EMBEDDED_PATH` or uses absolute path |
| Reaper kills a server with a legitimate but idle connection | Low | High | `CLIENT LIST` verification prevents this; PING triple-check ensures server is actually alive |
| Migration script overwrites user data | Low | High | Script detects existing canonical-path DB and warns; never overwrites without `--force` |
| redislite version change breaks `CLIENT LIST` compatibility | Low | Medium | `CLIENT LIST` is a core Redis command, stable across versions; reaper has try/except fallback to `PING`-only detection |
| `setsid`/`killpg` on macOS has different semantics | Medium | Low | Only applies to no-path connections (which Tier A eliminates); wrapped in try/except |
| Two copies of `projection.py` diverge | Medium | Medium | CI check to assert `projection.py` and `projection/__init__.py` are in sync (or eliminate one copy) |

---

*End of plan.*
