#!/usr/bin/env python3
"""Issue #100: Restore wiped 16379/tortoise graph from fragment DB.

Reads from: redislite fragment at /tmp/tortoise_restore_src.db (copy of
    /Users/home/eldato/negation-game-explorations/tortoise/tortoise.db)
Writes to: docker FalkorDB localhost:16379, graph `tortoise_restored_20260805`

Fragment stats: 2,312 statements + 1,991 operators = 4,303 total points.
Operator content format: IMPL|NAND|ALTERNATIVE_TO(source_id, target_id)
"""
from __future__ import annotations

import re
import sys
import time
from collections import defaultdict

# ── Connect to source (redislite embedded) ────────────────────────────────
print("=" * 70)
print("Tortoise Graph Restore — Issue #100")
print("=" * 70)

print("\n[1/5] Connecting to source fragment (redislite)...")
from redislite.falkordb_client import FalkorDB as RedisliteFalkor
src_db = RedisliteFalkor("/tmp/tortoise_restore_src.db")
src_g = src_db.select_graph("tortoise")

# ── Read all points from source ───────────────────────────────────────────
print("[2/5] Reading points from fragment...")
t0 = time.time()

# Get all statement points
stmt_result = src_g.query(
    "MATCH (n:Point) WHERE n.is_operator IS NULL OR n.is_operator = false "
    "RETURN n"
)
statements = []
for row in stmt_result.result_set:
    props = dict(row[0].properties)
    statements.append(props)

# Get all operator points
op_result = src_g.query(
    "MATCH (n:Point) WHERE n.is_operator = true RETURN n"
)
operators = []
for row in op_result.result_set:
    props = dict(row[0].properties)
    operators.append(props)

elapsed_read = time.time() - t0
print(f"  Statements: {len(statements)}")
print(f"  Operators:  {len(operators)}")
print(f"  Total:      {len(statements) + len(operators)}")
print(f"  Read in {elapsed_read:.1f}s")

# ── Connect to target (docker FalkorDB) ───────────────────────────────────
print("\n[3/5] Connecting to target (docker falkordb-personal:16379)...")
from falkordb import FalkorDB
target_db = FalkorDB(host="localhost", port=16379, socket_connect_timeout=5, socket_timeout=30)
target_g = target_db.select_graph("tortoise_restored_20260805")

# Verify target is empty
count_check = target_g.query("MATCH (n) RETURN count(n)")
existing = count_check.result_set[0][0]
if existing > 0:
    print(f"  ⚠️  Target graph already has {existing} nodes — will MERGE (idempotent)")
else:
    print("  ✅ Target graph is empty — ready for restore")

# ── Ensure indexes on target ──────────────────────────────────────────────
print("\n[3.5/5] Ensuring indexes on target graph...")
indexes = [
    ("Point", "id"),
    ("Point", "content_hash"),
    ("Point", "context"),
]
for label, prop in indexes:
    try:
        target_g.query(f"CREATE INDEX FOR (n:{label}) ON (n.{prop})")
    except Exception:
        pass  # Index already exists

# ── Write statements to target ────────────────────────────────────────────
print(f"\n[4/5] Writing {len(statements)} statements to target...")
t1 = time.time()
now_iso = time.strftime("%Y-%m-%dT%H:%M:%S.000000+00:00", time.gmtime())

batch_size = 50
total_stmt = len(statements)
written_stmt = 0
errors_stmt = 0

for i in range(0, total_stmt, batch_size):
    batch = statements[i:i + batch_size]
    for props in batch:
        try:
            pid = props.get("id")
            if not pid:
                errors_stmt += 1
                continue
            content = props.get("content", "")
            ctx = props.get("context", "")
            pk = props.get("pointKind", "statement")
            status = props.get("status", "live")
            confidence = props.get("confidence", 0.5)
            ca = props.get("createdAt", now_iso)

            target_g.query(
                "MERGE (n:Point {id: $id}) "
                "SET n.content = $content, "
                "    n.context = $context, "
                "    n.pointKind = $pointKind, "
                "    n.status = $status, "
                "    n.confidence = $confidence, "
                "    n.createdAt = $createdAt, "
                "    n.updatedAt = $now, "
                "    n.is_operator = false",
                params={
                    "id": pid,
                    "content": content,
                    "context": ctx,
                    "pointKind": pk,
                    "status": status,
                    "confidence": float(confidence),
                    "createdAt": ca,
                    "now": now_iso,
                },
            )
            written_stmt += 1
        except Exception as e:
            errors_stmt += 1
            print(f"  ⚠️  Error writing statement {props.get('id', '???')}: {e}")

    if (i + batch_size) % 500 == 0 or i + batch_size >= total_stmt:
        print(f"  Progress: {min(i + batch_size, total_stmt)}/{total_stmt} statements "
              f"({written_stmt} ok, {errors_stmt} errors)")

elapsed_write_stmts = time.time() - t1
print(f"  Wrote {written_stmt} statements in {elapsed_write_stmts:.1f}s")

# ── Parse operators and write to target ───────────────────────────────────
print(f"\n[4.5/5] Writing {len(operators)} operators to target...")
t2 = time.time()

# Pattern: OP_TYPE(source_id, target_id)
# Examples: IMPL(01KXH2CDCPN8K3ZDH6WJYN45YX, 01KXH2CDAGC2RQ1FNTYEKPSH50)
OPERATOR_PATTERN = re.compile(r'^(\w+)\((.+?),\s*(.+?)\)$')

written_ops = 0
errors_ops = 0
parse_errors = 0

for props in operators:
    try:
        pid = props.get("id")
        op_type = props.get("op_type", "IMPL")
        ctx = props.get("context", "")
        content = props.get("content", "")
        ca = props.get("createdAt", now_iso)

        if not pid:
            errors_ops += 1
            continue

        # Try parsing content for source_id/target_ids
        m = OPERATOR_PATTERN.match(content)
        if m:
            parsed_type = m.group(1)
            source_id = m.group(2).strip()
            target_id = m.group(3).strip()
            if parsed_type != op_type:
                # Use parsed type from content (ground truth)
                op_type = parsed_type
        else:
            parse_errors += 1
            # Fallback: no parseable source/target — create as operator node only
            target_g.query(
                "MERGE (n:Point {id: $id}) "
                "SET n.is_operator = true, "
                "    n.op_type = $op_type, "
                "    n.content = $content, "
                "    n.context = $context, "
                "    n.createdAt = $createdAt, "
                "    n.updatedAt = $now",
                params={
                    "id": pid,
                    "op_type": op_type,
                    "content": content,
                    "context": ctx,
                    "createdAt": ca,
                    "now": now_iso,
                },
            )
            written_ops += 1
            continue

        # Create operator node
        target_g.query(
            "MERGE (n:Point {id: $id}) "
            "SET n.is_operator = true, "
            "    n.op_type = $op_type, "
            "    n.content = $content, "
            "    n.context = $context, "
            "    n.createdAt = $createdAt, "
            "    n.updatedAt = $now",
            params={
                "id": pid,
                "op_type": op_type,
                "content": content,
                "context": ctx,
                "createdAt": ca,
                "now": now_iso,
            },
        )

        # Create edges from operator → source and operator → target
        edge_type = "hasPart" if op_type not in ("IMPL", "NAND", "ALTERNATIVE_TO") else op_type

        # Edge to source (idx=0) — MERGE to avoid duplicates on re-run
        target_g.query(
            f"MATCH (o:Point {{id: $oid}}), (s:Point {{id: $sid}}) "
            f"MERGE (o)-[:{edge_type} {{idx: 0}}]->(s)",
            params={"oid": pid, "sid": source_id},
        )

        # Edge to target (idx=1) — MERGE to avoid duplicates on re-run
        target_g.query(
            f"MATCH (o:Point {{id: $oid}}), (t:Point {{id: $tid}}) "
            f"MERGE (o)-[:{edge_type} {{idx: 1}}]->(t)",
            params={"oid": pid, "tid": target_id},
        )
        written_ops += 1

    except Exception as e:
        errors_ops += 1
        if errors_ops <= 3:
            print(f"  ⚠️  Error writing operator {props.get('id', '???')}: {e}")

    if written_ops % 500 == 0:
        print(f"  Progress: {written_ops}/{len(operators)} operators "
              f"({errors_ops} errors, {parse_errors} unparseable)")

elapsed_write_ops = time.time() - t2
print(f"  Wrote {written_ops} operators in {elapsed_write_ops:.1f}s")
print(f"  Parse errors (operator-only, no edges): {parse_errors}")
print(f"  Write errors: {errors_ops}")

# ── Verify ─────────────────────────────────────────────────────────────────
print("\n[5/5] Verifying restore...")
t3 = time.time()

r = target_g.query("MATCH (n:Point) WHERE n.is_operator IS NULL OR n.is_operator = false RETURN count(n)")
stmt_count = r.result_set[0][0]
r = target_g.query("MATCH (n:Point) WHERE n.is_operator = true RETURN count(n)")
op_count = r.result_set[0][0]
r = target_g.query("MATCH (n) RETURN count(n)")
total_count = r.result_set[0][0]

# Count edges
try:
    r = target_g.query("MATCH ()-[e]->() RETURN count(e)")
    edge_count = r.result_set[0][0]
except Exception:
    edge_count = "N/A"

# Top contexts
r = target_g.query(
    "MATCH (n:Point) WHERE n.context IS NOT NULL "
    "RETURN n.context, count(*) as c ORDER BY c DESC LIMIT 10"
)

print(f"\n  Restored graph stats:")
print(f"    Statement points: {stmt_count}")
print(f"    Operator points:  {op_count}")
print(f"    Total points:     {total_count}")
print(f"    Edges:            {edge_count}")
print(f"\n  Top contexts:")
for row in r.result_set:
    print(f"    {row[0]}: {row[1]}")

elapsed_verify = time.time() - t3
total_elapsed = time.time() - t0

print(f"\n{'=' * 70}")
print(f"Done in {total_elapsed:.1f}s total")
if errors_stmt > 0 or errors_ops > 0:
    print(f"ERRORS: {errors_stmt} statement write errors, {errors_ops} operator write errors")
    print(f"{'=' * 70}")
    sys.exit(1)
print(f"{'=' * 70}")
