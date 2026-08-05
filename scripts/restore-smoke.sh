#!/usr/bin/env bash
# restore-smoke.sh — Restore latest backup to throwaway graph + verify
# Issue #101: proves a backup can actually be restored
#
# What it does:
#   1. Finds the latest backup (local or off-box)
#   2. Starts a THROWAWAY FalkorDB container using the backup RDB
#   3. Counts points across all graphs
#   4. Asserts total points > 0
#   5. Reports OK/FAIL
#   6. Cleans up throwaway container (DOES NOT touch real containers)
#
# Usage: bash scripts/restore-smoke.sh [backup_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_ROOT="${1:-}"
THROWAWAY_CONTAINER="tortoise_smoke_test_$$"
THROWAWAY_PORT="${SMOKE_PORT:-16380}"
SMOKE_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cleanup() {
    local exit_code=$?
    echo ""
    echo "[$(date '+%H:%M:%S')] Cleaning up throwaway container: $THROWAWAY_CONTAINER"
    docker stop "$THROWAWAY_CONTAINER" 2>/dev/null || true
    docker rm "$THROWAWAY_CONTAINER" 2>/dev/null || true
    if [ -n "${SMOKE_VOLUME:-}" ]; then
        docker volume rm "$SMOKE_VOLUME" 2>/dev/null || true
    fi
    # P2: cleanup the temp dir used for RDB
    if [ -n "${SMOKE_TMPDIR:-}" ] && [ -d "$SMOKE_TMPDIR" ]; then
        rm -rf "$SMOKE_TMPDIR"
    fi
    exit $exit_code
}
trap cleanup EXIT

# ── Step 1: Find latest backup ─────────────────────────────────────
if [ -z "$BACKUP_ROOT" ]; then
    # Try local first, then off-box
    if [ -d "$REPO_ROOT/backups" ] && [ -n "$(ls -1dt "$REPO_ROOT/backups"/*/ 2>/dev/null | head -1)" ]; then
        BACKUP_DIR=$(ls -1dt "$REPO_ROOT/backups"/*/ | head -1)
    elif [ -d "$HOME/backups/tortoise" ] && [ -n "$(ls -1dt "$HOME/backups/tortoise"/*/ 2>/dev/null | head -1)" ]; then
        BACKUP_DIR=$(ls -1dt "$HOME/backups/tortoise"/*/ | head -1)
    else
        echo -e "${RED}FAIL${NC}: No backups found in $REPO_ROOT/backups/ or $HOME/backups/tortoise/"
        exit 1
    fi
else
    BACKUP_DIR="$BACKUP_ROOT"
fi

if [ ! -f "$BACKUP_DIR/dump.rdb" ]; then
    echo -e "${RED}FAIL${NC}: No dump.rdb in $BACKUP_DIR"
    exit 1
fi

echo "[$(date '+%H:%M:%S')] Using backup: $BACKUP_DIR"
RDB_SIZE=$(stat -f%z "$BACKUP_DIR/dump.rdb" 2>/dev/null || stat -c%s "$BACKUP_DIR/dump.rdb" 2>/dev/null || echo "0")
echo "  RDB size: $RDB_SIZE bytes"

if [ -f "$BACKUP_DIR/manifest.json" ]; then
    echo "  Manifest: $(cat "$BACKUP_DIR/manifest.json")"
fi

# ── Step 2: Validate RDB is non-empty ──────────────────────────────
echo "[$(date '+%H:%M:%S')] Validating RDB file..."
if [ ! -s "$BACKUP_DIR/dump.rdb" ]; then
    echo -e "${RED}FAIL${NC}: RDB file is empty or missing"
    exit 1
fi
# Check for Redis magic bytes (REDIS0009 or similar)
RDB_HEADER=$(head -c 9 "$BACKUP_DIR/dump.rdb" 2>/dev/null || echo "")
if echo "$RDB_HEADER" | grep -q "REDIS"; then
    echo -e "${GREEN}  RDB file has valid Redis header: $RDB_HEADER${NC}"
else
    echo -e "${YELLOW}  RDB header not recognized (got: $RDB_HEADER) — continuing anyway${NC}"
fi

# ── Step 3: Start throwaway container with backup RDB ──────────────
echo "[$(date '+%H:%M:%S')] Starting throwaway container: $THROWAWAY_CONTAINER (port $THROWAWAY_PORT)..."

# Create a temp dir for the RDB
SMOKE_TMPDIR=$(mktemp -d /tmp/tortoise-smoke-XXXXXX)
cp "$BACKUP_DIR/dump.rdb" "$SMOKE_TMPDIR/dump.rdb"

# Start throwaway container with the backup RDB
# FalkorDB stores data at /var/lib/falkordb/data (FALKORDB_DATA_PATH env)
docker run -d --rm \
    --name "$THROWAWAY_CONTAINER" \
    -p "$THROWAWAY_PORT:6379" \
    -v "$SMOKE_TMPDIR:/var/lib/falkordb/data:rw" \
    falkordb/falkordb:latest \
    > /dev/null

# Wait for it to start
echo "[$(date '+%H:%M:%S')] Waiting for throwaway container to be ready..."
for i in $(seq 1 20); do
    if docker exec "$THROWAWAY_CONTAINER" redis-cli -p 6379 PING 2>/dev/null | grep -q PONG; then
        echo "  Container ready after ${i}s"
        break
    fi
    sleep 1
done

# Verify container is running
if ! docker ps --filter "name=$THROWAWAY_CONTAINER" --format '{{.Names}}' | grep -q "$THROWAWAY_CONTAINER"; then
    echo -e "${RED}FAIL${NC}: Throwaway container failed to start"
    docker logs "$THROWAWAY_CONTAINER" 2>&1 | tail -20
    exit 1
fi

# ── Step 4: Query graphs and count points ──────────────────────────
echo "[$(date '+%H:%M:%S')] Querying restored graphs..."
GRAPHS=$(docker exec "$THROWAWAY_CONTAINER" redis-cli -p 6379 GRAPH.LIST 2>/dev/null || echo "")

if [ -z "$GRAPHS" ]; then
    echo -e "${RED}FAIL${NC}: No graphs found in restored backup — empty RDB?"
    exit 1
fi

TOTAL_POINTS=0
for graph in $GRAPHS; do
    RESULT=$(docker exec "$THROWAWAY_CONTAINER" redis-cli -p 6379 \
        GRAPH.QUERY "$graph" "MATCH (p:Point) RETURN count(p)" 2>/dev/null || echo "0")
    COUNT=$(echo "$RESULT" | grep -E '^[0-9]+$' | head -1 || echo "0")
    if [ -z "$COUNT" ]; then COUNT=0; fi
    TOTAL_POINTS=$((TOTAL_POINTS + COUNT))
    echo "  $graph: $COUNT points"
done

echo "  Total points across all graphs: $TOTAL_POINTS"

# ── Step 5: Assertions ─────────────────────────────────────────────
if [ "$TOTAL_POINTS" -le 0 ]; then
    echo -e "${RED}FAIL${NC}: 0 points found in restored graphs — backup appears empty"
    exit 1
fi

# Compare with manifest if available — try jq first, python3 as fallback (P2)
if [ -f "$BACKUP_DIR/manifest.json" ]; then
    MANIFEST_TOTAL="?"
    if command -v jq &>/dev/null; then
        MANIFEST_TOTAL=$(jq -r '.total_points // 0' "$BACKUP_DIR/manifest.json" 2>/dev/null || echo "?")
    elif command -v python3 &>/dev/null; then
        MANIFEST_TOTAL=$(python3 -c "import json; d=json.load(open('$BACKUP_DIR/manifest.json')); print(d.get('total_points', 0))" 2>/dev/null || echo "?")
    fi
    echo "  Manifest expected: $MANIFEST_TOTAL points"
    if [ "$MANIFEST_TOTAL" != "?" ] && [ "$TOTAL_POINTS" -lt "$MANIFEST_TOTAL" ]; then
        echo -e "${YELLOW}WARNING${NC}: Restored points ($TOTAL_POINTS) < manifest ($MANIFEST_TOTAL)"
    fi
fi

# ── Step 6: Fine ───────────────────────────────────────────────────
echo ""
echo "============================================="
echo -e "${GREEN}SMOKE TEST PASSED${NC}"
echo "  Backup:    $BACKUP_DIR"
echo "  RDB size:  $RDB_SIZE bytes"
echo "  Graphs:    $GRAPHS"
echo "  Points:    $TOTAL_POINTS"
echo "============================================="

# Cleanup happens via trap
exit 0
