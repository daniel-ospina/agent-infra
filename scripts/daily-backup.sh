#!/usr/bin/env bash
# daily-backup.sh — Automated Tortoise graph backup with off-box copy
# Issue #101: RPO ≤ 24h backup for falkordb-personal (port 16379)
#
# What it does:
#   1. Triggers BGSAVE on falkordb-personal
#   2. Copies RDB snapshot + graph metadata to timestamped backup dir
#   3. Copies to off-box location (/home/user/eldato/backups/tortoise/)
#   4. Prunes old backups (keep N=14)
#   5. Writes manifest.json with point counts per graph
#
# Usage: bash scripts/daily-backup.sh [--keep N]
#
# Load gate (#209): BGSAVE is itself a storm igniter — the gate defers only
# under PRE-EXISTING load. Entry preflight + pre-trigger re-check guard the
# pre-trigger steps ONLY; once BGSAVE is in flight the script completes its
# wait (a re-invoke would trigger a SECOND BGSAVE — aborting saves nothing).
# Exit 3 = DEFERRED — re-invoke to complete (never a silent skip; the invoker
# MUST re-invoke; a defer near one daily invocation can slip to the next ⇒
# RPO ≤ 48h under sustained load — accepted trade for load safety).
# Bypass: LOAD_GATE_FORCE=1 env (no script flag, scope-pinned).
# See docs/ops/load-policy.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_ROOT="$REPO_ROOT/backups"
OFFBOX_ROOT="${OFFBOX_ROOT:-$HOME/backups/tortoise}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
CONTAINER="${CONTAINER:-falkordb-personal}"
REDIS_PORT="${REDIS_PORT:-6379}"
KEEP="${1:-14}"
# If first arg is --keep, shift and read N
if [ "$KEEP" = "--keep" ]; then
    KEEP="${2:-14}"
fi
# Validate KEEP is a positive integer (P1: non-numeric would eval to 1)
if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --keep value must be a positive integer, got '$KEEP'" >&2
    exit 1
fi

LOAD_GATE_MAX_WAIT_MIN="${LOAD_GATE_MAX_WAIT_MIN:-10}"

# ── load gate (#209) ────────────────────────────────────────────────────────
# Entry preflight BEFORE any pre-trigger step (mkdirs create state): same
# entry rule as cron-quality-gates.sh — `check` (shouldSuspend) → go;
# suspended → bounded poll (`check --deferred` every 60s up to
# LOAD_GATE_MAX_WAIT_MIN; `0` = no poll); after the cap → exit 3 with a loud
# defer log (accurate: nothing has run/been created yet).
load_gate_entry() {
  if [ "${LOAD_GATE_FORCE:-}" = "1" ]; then return 0; fi
  local rc=0 out load1 suspend waited
  out="$(node "$REPO_ROOT/scripts/load-gate.mjs" check --json 2>/dev/null)" || rc=$?
  [ $rc -eq 0 ] && return 0
  if [ $rc -ne 3 ]; then
    echo "[load-gate] ERROR: gate helper failed (exit $rc) — aborting loudly" >&2
    exit 1
  fi
  load1="$(printf '%s' "$out" | sed -n 's/.*"load1":\([0-9.e+-]*\).*/\1/p')"
  suspend="$(printf '%s' "$out" | sed -n 's/.*"suspend":\([0-9.e+-]*\).*/\1/p')"
  waited=0
  while [ "$waited" -lt "$LOAD_GATE_MAX_WAIT_MIN" ]; do
    sleep 60
    waited=$((waited + 1))
    if node "$REPO_ROOT/scripts/load-gate.mjs" check --deferred >/dev/null 2>&1; then
      echo "[load-gate] resumed after ${waited} min poll (load < resume threshold)" >&2
      return 0
    fi
  done
  echo "[load-gate] DEFERRED — batch did NOT run; re-invoke after load < ${suspend:-?} (was ${load1:-?})" >&2
  exit 3
}

# Pre-trigger re-check (immediately BEFORE the storm igniter): a single
# `check`; the gate defers only under PRE-EXISTING load. Suspend → exit 3 with
# the round-2 F6 wording — hedges the check→exec race (if BGSAVE somehow ran,
# "re-invoke to complete copy" is still correct; exit-3 means "did not
# complete; re-invoke").
load_gate_pre_trigger_check() {
  if [ "${LOAD_GATE_FORCE:-}" = "1" ]; then return 0; fi
  local rc=0 out load1 suspend
  out="$(node "$REPO_ROOT/scripts/load-gate.mjs" check --json 2>/dev/null)" || rc=$?
  [ $rc -eq 0 ] && return 0
  if [ $rc -ne 3 ]; then
    echo "[load-gate] ERROR: gate helper failed (exit $rc) — aborting loudly" >&2
    exit 1
  fi
  load1="$(printf '%s' "$out" | sed -n 's/.*"load1":\([0-9.e+-]*\).*/\1/p')"
  suspend="$(printf '%s' "$out" | sed -n 's/.*"suspend":\([0-9.e+-]*\).*/\1/p')"
  echo "[load-gate] DEFERRED — partial: BGSAVE may have run; re-invoke to complete copy (load ${load1:-?} ≥ suspend ${suspend:-?})" >&2
  exit 3
}

# ── Ensure backup directories exist ──────────────────────────────
# Entry gate runs BEFORE the mkdirs — a deferral here has created nothing.
load_gate_entry
mkdir -p "$BACKUP_DIR"
mkdir -p "$OFFBOX_ROOT"

# ── Step 1: Trigger BGSAVE ───────────────────────────────────────
# Pre-trigger re-check: once BGSAVE fires below, the script NEVER aborts
# (post-trigger completion; see header).
load_gate_pre_trigger_check
echo "[$(date '+%H:%M:%S')] Triggering BGSAVE on $CONTAINER..."
docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" BGSAVE > /dev/null

# Wait for BGSAVE to complete (poll LASTSAVE)
# Post-trigger: NO abort (round-2 F2) — exit-3's "did NOT run; re-invoke"
# contract is FALSE once BGSAVE is in flight (a re-invoke would be a SECOND
# storm igniter). Optional warn-log; the wait completes regardless.
LOAD_GATE_WARNED=0
echo "[$(date '+%H:%M:%S')] Waiting for BGSAVE to complete..."
for i in $(seq 1 30); do
    if [ "$LOAD_GATE_WARNED" = "0" ] && [ "${LOAD_GATE_FORCE:-}" != "1" ]; then
        lg_out="$(node "$REPO_ROOT/scripts/load-gate.mjs" check --json 2>/dev/null)" && lg_rc=0 || lg_rc=$?
        if [ "$lg_rc" -ne 0 ]; then
            lg_load="$(printf '%s' "$lg_out" | sed -n 's/.*"load1":\([0-9.e+-]*\).*/\1/p')"
            lg_suspend="$(printf '%s' "$lg_out" | sed -n 's/.*"suspend":\([0-9.e+-]*\).*/\1/p')"
            echo "[load-gate] WARN — load ${lg_load:-?} ≥ suspend ${lg_suspend:-?} during BGSAVE wait; completing (aborting would not save the in-flight save)" >&2
            LOAD_GATE_WARNED=1
        fi
    fi
    LASTSAVE=$(docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" LASTSAVE 2>/dev/null || echo "0")
    # Check if there have been no changes since the BGSAVE we just triggered
    # by polling redis-cli INFO persistence
    PERSISTENCE=$(docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" INFO persistence 2>/dev/null || echo "")
    BGSAVE_STATUS=$(echo "$PERSISTENCE" | grep "rdb_bgsave_in_progress" | cut -d: -f2 | tr -d '\r')
    if [ "$BGSAVE_STATUS" = "0" ]; then
        echo "[$(date '+%H:%M:%S')] BGSAVE complete."
        break
    fi
    sleep 2
done

# P1(a): Fatal if BGSAVE did not complete within the timeout loop
if [ "${BGSAVE_STATUS:-1}" != "0" ]; then
    echo "ERROR: BGSAVE did not complete after 30 attempts (60s timeout)" >&2
    exit 1
fi

# ── Step 2: Query graph metadata (point counts) ───────────────────
echo "[$(date '+%H:%M:%S')] Querying graph point counts..."
GRAPHS=$(docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" GRAPH.LIST 2>/dev/null || echo "")

# Collect graph:count pairs into a plain file (bash 3.2 compat — no associative arrays)
GRAPH_COUNTS_FILE="$BACKUP_DIR/.graph_counts"
rm -f "$GRAPH_COUNTS_FILE"

for graph in $GRAPHS; do
    COUNT=$(docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" \
        GRAPH.QUERY "$graph" "MATCH (p:Point) RETURN count(p)" 2>/dev/null | \
        grep -E '^[0-9]+$' | head -1 || echo "0")
    if [ -z "$COUNT" ]; then COUNT=0; fi
    echo "$graph $COUNT" >> "$GRAPH_COUNTS_FILE"
    echo "  $graph: $COUNT points"
done

# ── Step 3: Copy RDB from container ───────────────────────────────
echo "[$(date '+%H:%M:%S')] Copying RDB from container..."
RDB_SIZE_BEFORE=$(docker exec "$CONTAINER" stat -c%s /var/lib/falkordb/data/dump.rdb 2>/dev/null || echo "0")
docker cp "$CONTAINER:/var/lib/falkordb/data/dump.rdb" "$BACKUP_DIR/dump.rdb"

# Verify copy
LOCAL_RDB_SIZE=$(stat -f%z "$BACKUP_DIR/dump.rdb" 2>/dev/null || stat -c%s "$BACKUP_DIR/dump.rdb" 2>/dev/null || echo "0")
echo "  RDB size: $LOCAL_RDB_SIZE bytes (container: $RDB_SIZE_BEFORE bytes)"

if [ "$LOCAL_RDB_SIZE" = "0" ] || [ "$LOCAL_RDB_SIZE" -lt 100 ]; then
    echo "ERROR: RDB copy appears to be empty or corrupt (size=$LOCAL_RDB_SIZE)" >&2
    exit 1
fi

# ── Step 4: Write manifest.json ───────────────────────────────────
TOTAL_POINTS=0
GRAPH_META=""

while read -r graph count; do
    [ -z "$graph" ] && continue
    TOTAL_POINTS=$((TOTAL_POINTS + count))
    if [ -n "$GRAPH_META" ]; then GRAPH_META="$GRAPH_META,"; fi
    GRAPH_META="$GRAPH_META\"$graph\": $count"
done < "$GRAPH_COUNTS_FILE"

NUM_GRAPHS=$(wc -l < "$GRAPH_COUNTS_FILE" | tr -d ' ')

cat > "$BACKUP_DIR/manifest.json" <<EOF
{
  "backed_up_at": "$TIMESTAMP",
  "container": "$CONTAINER",
  "rdb_file": "dump.rdb",
  "rdb_size_bytes": $LOCAL_RDB_SIZE,
  "graphs": {$GRAPH_META},
  "total_points": $TOTAL_POINTS
}
EOF

echo "[$(date '+%H:%M:%S')] Manifest written: $TOTAL_POINTS total points across $NUM_GRAPHS graphs"

# ── Step 5: Off-box copy ──────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] Copying to off-box location: $OFFBOX_ROOT/$TIMESTAMP..."
mkdir -p "$OFFBOX_ROOT/$TIMESTAMP"
cp -a "$BACKUP_DIR"/* "$OFFBOX_ROOT/$TIMESTAMP/"
echo "  Off-box copy complete."

# ── Step 6: Prune old backups ──────────────────────────────────────
echo "[$(date '+%H:%M:%S')] Pruning backups (keep=$KEEP)..."

prune_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then return; fi
    # P1(b): nullglob + pre-check avoids crash on empty dirs under pipefail
    local nullglob_was_set
    if shopt -q nullglob 2>/dev/null; then nullglob_was_set=1; fi
    shopt -s nullglob 2>/dev/null || true
    local matches=("$dir"/*/)
    if [ ${#matches[@]} -gt 0 ]; then
        ls -1dt "${matches[@]}" 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
            echo "  Removing: $old"
            rm -rf "$old"
        done
    fi
    if [ -z "${nullglob_was_set:-}" ]; then
        shopt -u nullglob 2>/dev/null || true
    fi
}

prune_dir "$BACKUP_ROOT"
prune_dir "$OFFBOX_ROOT"

# ── Step 7: Summary ───────────────────────────────────────────────
echo ""
echo "============================================="
echo "Backup complete: $TIMESTAMP"
echo "  Local:  $BACKUP_DIR"
echo "  Offbox: $OFFBOX_ROOT/$TIMESTAMP"
echo "  RDB:    $LOCAL_RDB_SIZE bytes"
echo "  Points: $TOTAL_POINTS"
echo "============================================="

# ── Alert on suspiciously low point count ──────────────────────────
if [ "$TOTAL_POINTS" -lt 100 ]; then
    echo "WARNING: Total point count ($TOTAL_POINTS) is suspiciously low!" >&2
    exit 2
fi

exit 0
