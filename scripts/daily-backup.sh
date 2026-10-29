#!/usr/bin/env bash
# daily-backup.sh — Automated Tortoise graph backup with off-box copy
# Issue #101: RPO ≤ 24h backup for the LOCAL FalkorDB on host port 16379
# Issue #907: the container is RESOLVED from the port it publishes, never named by a literal
#
# What it does:
#   1. Resolves the local FalkorDB container from the host port it PUBLISHES (16379 by
#      default), and refuses loudly when there is none, more than one, or one that does
#      not answer (#907)
#   2. Triggers BGSAVE on it
#   3. Copies RDB snapshot + graph metadata to timestamped backup dir
#   4. Copies to the off-box location ($HOME/backups/tortoise)
#   5. Prunes old backups (keep N=14)
#   6. Writes manifest.json with point counts per graph
#
# ⚠️ THE RPO CLAIM IS CONDITIONAL. “RPO ≤ 24h” holds only while something invokes this
# script on a ≤24h cadence. Nothing in this repo schedules it — the claim is not in force
# without an external scheduler (#907), and an unscheduled target that fails silently is
# exactly the state #907 was filed about.
#
# Usage:  bash scripts/daily-backup.sh [--keep N]
#
# Env:
#   CONTAINER           explicit container name — skips resolution (the human override)
#   REDIS_HOST_PORT     host port the local FalkorDB publishes (default 16379)
#   REDIS_PORT          port INSIDE the container (default 6379)
#   OFFBOX_ROOT         off-box destination root (default $HOME/backups/tortoise)
#   PREFLIGHT_TIMEOUT   redis-cli connect timeout for the preflight PING (default 5s)
#
# Exit codes: 0 = complete · 1 = failure (unverifiable target / copy / consistency) ·
#             2 = complete but the source looked wrong (total points < 100) ·
#             3 = DEFERRED by the load gate (nothing written; re-invoke)
# On exit 1 the incomplete backup directory is REMOVED, so a failed run can never be
# mistaken for the newest backup by restore-smoke.sh (see the trap below).
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
OFFBOX_DIR="$OFFBOX_ROOT/$TIMESTAMP"
# #907 — the container is RESOLVED from the host port it publishes. A non-empty CONTAINER
# env var is an explicit human override and skips resolution.
CONTAINER="${CONTAINER:-}"
REDIS_HOST_PORT="${REDIS_HOST_PORT:-16379}"
REDIS_PORT="${REDIS_PORT:-6379}"
PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-5}"
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

# ── Target resolution + fail-loud preflight (#907) ────────────────
# WHY THE TARGET IS RESOLVED AND NOT NAMED. This script used to default
# `CONTAINER=falkordb-personal` — a literal that no longer exists on the machine (the
# container serving 16379 is `falkordb-16379`). So the default named a container that was
# not there, the RPO ≤ 24h guarantee in the header above was not in force, and the two
# hard-coded strings had drifted apart with nothing able to notice (#907). The one fact
# that cannot drift is the PORT the graph publishes, so the target is resolved with
# `docker ps --filter publish=$REDIS_HOST_PORT`.
#
# AMBIGUITY IS A REFUSAL, NOT A COIN FLIP. Port 16379 is also where a second, near-empty
# FalkorDB can appear on `::1` (tortoise#6666 — a `localhost` client reads the decoy). Two
# publishers on one host port mean the target cannot be identified, and backing up the
# wrong graph is silent: the script would exit 0 having copied the wrong data. >1 match is
# therefore a loud exit 1 naming every candidate; `CONTAINER=<name>` is the override.
#
# THE PREFLIGHT RUNS BEFORE ANY STATE IS CREATED. A failed run used to leave an EMPTY
# `$BACKUP_ROOT/<timestamp>/` behind — and restore-smoke.sh picks the NEWEST directory
# under `backups/`, so one failed backup blocked verification of a GOOD older one with
# “No dump.rdb in …”. Nothing is written here — not even a mkdir — until the target has
# been proven to exist and answer.
#
# WHY A PING AT ALL, WHEN `docker inspect` SAYS “Running”. Because running is not
# answering: on 2026-09-29 this graph accepted TCP and never replied (#907), so a
# scheduled backup would hang instead of failing. Honest scope of this probe: `-t` bounds
# the CONNECT only (measured on redis-cli 8.10.2 — an accepting-but-silent socket still
# blocked a `-t 2` PING), so it catches a missing container, a stopped container, a
# refused/closed port and an immediate error reply, and it does NOT bound a wedged Docker
# daemon (where `docker ps` itself hangs). That last one is the separate, owner-gated
# infrastructure failure recorded on #907, not a condition this script can repair.
resolve_container() {
    if [ -n "$CONTAINER" ]; then
        printf '%s\n' "$CONTAINER"
        return 0
    fi
    local candidates line count=0
    candidates="$(docker ps --filter "publish=$REDIS_HOST_PORT" --filter status=running \
        --format '{{.Names}}' 2>/dev/null || true)"
    # Counted with a shell loop (no `| grep`): the writer-into-quiet-grep idiom is a
    # false-negative class this repo guards against (scripts/check-no-sigpipe-grep.sh).
    while IFS= read -r line; do
        [ -n "$line" ] && count=$((count + 1))
    done <<<"$candidates"
    if [ "$count" -eq 0 ]; then
        echo "ERROR: no running container publishes host port $REDIS_HOST_PORT — nothing to back up." >&2
        echo "       Looked for: docker ps --filter publish=$REDIS_HOST_PORT --filter status=running" >&2
        echo "       Name the target explicitly if the port differs: CONTAINER=<name> bash ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "ERROR: $count containers publish host port $REDIS_HOST_PORT — the backup target is ambiguous:" >&2
        while IFS= read -r line; do
            [ -n "$line" ] && echo "         $line" >&2
        done <<<"$candidates"
        echo "       A second publisher on this port is the ::1 decoy hazard (tortoise#6666)." >&2
        echo "       Name the intended target: CONTAINER=<name> bash ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    printf '%s\n' "$candidates"
}

# The preflight uses the SAME address rule the rest of the fleet uses (#4844): bind to an
# address, never to the name. `127.0.0.1` inside the container is unambiguous.
preflight_container() {
    local running ping
    running="$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)"
    if [ "$running" != "true" ]; then
        echo "ERROR: container '$CONTAINER' is not a running Docker container (docker inspect -> '${running:-<none>}')." >&2
        echo "       Nothing was written. Fix the target and re-run." >&2
        exit 1
    fi
    ping="$(docker exec "$CONTAINER" redis-cli -h 127.0.0.1 -p "$REDIS_PORT" \
        -t "$PREFLIGHT_TIMEOUT" PING 2>/dev/null || true)"
    if [ "$ping" != "PONG" ]; then
        echo "ERROR: container '$CONTAINER' did not answer PING on port $REDIS_PORT (got '${ping:-<no reply>}')." >&2
        echo "       Refusing to back up from an unverified target. Nothing was written." >&2
        exit 1
    fi
}

# An INCOMPLETE backup directory is removed on ANY failure. A directory without a
# manifest.json is not a backup: leaving it made `restore-smoke.sh` pick it as the newest
# one and refuse to restore, so a failed run disabled the verification of the good backup
# that was still on disk (#907). A directory that DOES carry its manifest (the exit-2
# “source looked wrong” case) is kept — it is a real artifact and the evidence.
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -d "$BACKUP_DIR" ] && [ ! -f "$BACKUP_DIR/manifest.json" ]; then
            rm -rf "$BACKUP_DIR"
        fi
        if [ -d "$OFFBOX_DIR" ] && [ ! -f "$OFFBOX_DIR/manifest.json" ]; then
            rm -rf "$OFFBOX_DIR"
        fi
    fi
    return 0
}
trap on_exit EXIT

# ── Ensure backup directories exist ──────────────────────────────
# Entry gate runs BEFORE the mkdirs — a deferral here has created nothing.
load_gate_entry
# #907 — resolve the target and PROVE it answers before anything is written.
CONTAINER="$(resolve_container)"
preflight_container
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
        # The helper's status is read ONLY here, where it was just set. These two branches
        # used to be one `if`/`elif` pair, so the second one read `$lg_rc` on a path where
        # it had never been assigned — with `set -u` and the documented LOAD_GATE_FORCE=1
        # bypass, `lg_rc: unbound variable` aborted the script at the first iteration, i.e.
        # the emergency bypass could never complete a backup (#907).
        if [ "$lg_rc" -eq 3 ]; then
            lg_load="$(printf '%s' "$lg_out" | sed -n 's/.*"load1":\([0-9.e+-]*\).*/\1/p')"
            lg_suspend="$(printf '%s' "$lg_out" | sed -n 's/.*"suspend":\([0-9.e+-]*\).*/\1/p')"
            echo "[load-gate] WARN — load defer (gate rc=3): load ${lg_load:-?} ≥ suspend ${lg_suspend:-?} during BGSAVE wait; completing (aborting would not save the in-flight save)" >&2
            LOAD_GATE_WARNED=1
        elif [ "$lg_rc" -ne 0 ]; then
            echo "[load-gate] helper unavailable during wait (rc $lg_rc) — completing wait without load re-check" >&2
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
# ⛔ NOT `GRAPHS=$(… || echo "")` (agent-infra#2121, empty-as-pass). `|| echo ""` rewrites a FAILED
# read into an EMPTY one, so the loop below iterates ZERO times, step 4 then writes `"graphs": {}` /
# `"total_points": 0`, and the run announces a complete backup whose manifest cannot be told from a
# backup of an EMPTY database — the two states the manifest exists to distinguish. This is the same
# read that scripts/restore-smoke.sh already refuses on (`[ -z "$GRAPHS" ] && FAIL exit 1`), so read
# the status and refuse for the same reason: an inventory we could not read is UNKNOWN, not zero.
# Cost: no backup directory is left (the EXIT trap removes one with no manifest), so the next run
# redoes it — cheaper than a manifest that lies about what it captured.
GRAPHS=$(docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" GRAPH.LIST 2>/dev/null) || GRAPH_LIST_RC=$?
if [ "${GRAPH_LIST_RC:-0}" -ne 0 ]; then
    echo "ERROR: GRAPH.LIST read FAILED (rc=$GRAPH_LIST_RC) on container '$CONTAINER'." >&2
    echo "       The graph inventory is UNKNOWN, not empty — refusing to write a manifest that would" >&2
    echo "       report 0 graphs / 0 points as if it had verified them. Nothing was kept." >&2
    exit 1
fi

# Collect graph:count pairs into a plain file (bash 3.2 compat — no associative arrays)
GRAPH_COUNTS_FILE="$BACKUP_DIR/.graph_counts"
rm -f "$GRAPH_COUNTS_FILE"

for graph in $GRAPHS; do
    # ⛔ THE SAME LAUNDERING, ONE READ DOWN (agent-infra#2121 review, found independently by two
    # reviewers). `… | grep -E '^[0-9]+$' | head -1 || echo "0"` binds the `||` to `head`, which
    # SUCCEEDS on empty input — so a failed GRAPH.QUERY left COUNT="" and the `[ -z … ] && COUNT=0`
    # below wrote that failure into the manifest as "this graph holds 0 points". A graph with genuinely
    # zero points returns a numeric row, so an empty result is ALWAYS a failed read: refuse it rather
    # than certify a count nothing observed. (The old `TOTAL_POINTS -lt 100` gate cannot catch it —
    # one masked count among healthy graphs keeps the total above the floor.)
    COUNT=$(docker exec "$CONTAINER" redis-cli -p "$REDIS_PORT" \
        GRAPH.QUERY "$graph" "MATCH (p:Point) RETURN count(p)" 2>/dev/null | \
        grep -E '^[0-9]+$' | head -1) || COUNT=""
    case "$COUNT" in
        ''|*[!0-9]*)
            echo "ERROR: point count read FAILED for graph '$graph' (got '${COUNT:-<empty>}')." >&2
            echo "       The count is UNKNOWN, not zero — refusing to write a manifest that would" >&2
            echo "       report it as 0 points. Nothing was kept." >&2
            exit 1
            ;;
    esac
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
  "redis_host_port": "$REDIS_HOST_PORT",
  "rdb_file": "dump.rdb",
  "rdb_size_bytes": $LOCAL_RDB_SIZE,
  "graphs": {$GRAPH_META},
  "total_points": $TOTAL_POINTS
}
EOF

echo "[$(date '+%H:%M:%S')] Manifest written: $TOTAL_POINTS total points across $NUM_GRAPHS graphs"

# ── Step 5: Off-box copy ──────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] Copying to off-box location: $OFFBOX_DIR..."
mkdir -p "$OFFBOX_DIR"
cp -a "$BACKUP_DIR"/* "$OFFBOX_DIR/"
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
echo "  Offbox: $OFFBOX_DIR"
echo "  RDB:    $LOCAL_RDB_SIZE bytes"
echo "  Points: $TOTAL_POINTS"
echo "============================================="

# ── Alert on suspiciously low point count ──────────────────────────
if [ "$TOTAL_POINTS" -lt 100 ]; then
    echo "WARNING: Total point count ($TOTAL_POINTS) is suspiciously low!" >&2
    exit 2
fi

exit 0
