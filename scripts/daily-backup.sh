#!/usr/bin/env bash
# daily-backup.sh — Automated Tortoise graph backup with off-box copy
# Issue #101: RPO ≤ 24h backup for falkordb-personal (port 16379)
#
# What it does:
#   1. Triggers BGSAVE on falkordb-personal
#   2. Copies RDB snapshot + graph metadata to timestamped backup dir
#   3. Copies to off-box location (/Users/home/eldato/backups/tortoise/)
#   4. Prunes old backups (keep N=14)
#   5. Writes manifest.json with point counts per graph
#
# Usage: bash scripts/daily-backup.sh [--keep N]

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
# If second arg is --keep N, parse it
if [ "$KEEP" = "--keep" ]; then
    KEEP="${2:-14}"
fi

# ── Ensure backup directories exist ──────────────────────────────
mkdir -p "$BACKUP_DIR"
mkdir -p "$OFFBOX_ROOT"

# ── Step 1: Trigger BGSAVE ───────────────────────────────────────
echo "[$(date '+%H:%M:%S')] Triggering BGSAVE on $CONTAINER..."
docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" BGSAVE > /dev/null

# Wait for BGSAVE to complete (poll LASTSAVE)
echo "[$(date '+%H:%M:%S')] Waiting for BGSAVE to complete..."
for i in $(seq 1 30); do
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
    ls -1dt "$dir"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
        echo "  Removing: $old"
        rm -rf "$old"
    done
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
