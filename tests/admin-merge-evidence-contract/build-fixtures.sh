#!/bin/bash
# Build the clause-7 fixtures from a REAL captured certificate.
#
# NEG = the real, verbatim evidence comment posted by scripts/admin-merge.sh on
#       agent-infra#1406 (head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45). It is
#       VACUOUS (`measured sets: PR failing runs=0 | main failing runs=0`) and its
#       parity line reads `lane parity: NOT ESTABLISHED — declared off`, so the
#       contract REFUSES it. Captured 2026-09-23.
# POS = the same capture with ONLY the state block substituted: the vacuous
#       "NOT ESTABLISHED / declared off" block is replaced by the producer's real
#       established-parity value (scripts/admin-merge.sh:3354). Every other byte,
#       including the clause-4 line and the attribution line, is the capture's.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cp /tmp/captured-1406.md "$D/captured-1406-vacuous-parity-not-established.md"
python3 - "$D/captured-1406-vacuous-parity-not-established.md" "$D/captured-1406-parity-established.md" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
# The vacuous/declared-off state block, as a real body renders it: the
# `measured sets:` line plus the `lane parity: NOT ESTABLISHED` paragraph.
before = text
text = re.sub(r"measured sets: PR failing runs=0 \| main failing runs=0 \([^\n]*\)\n", "", text)
text = re.sub(r"lane parity: NOT ESTABLISHED — declared off;[^\n]*\n", "", text)
assert text != before, "the vacuous state block was not found — capture shape changed"
open(dst, "w", encoding="utf-8").write(text)
print("POS written; vacuous block removed")
PY
echo "NEG: $(wc -l < "$D/captured-1406-vacuous-parity-not-established.md") lines (vacuous, parity NOT ESTABLISHED)"
echo "POS: $(wc -l < "$D/captured-1406-parity-established.md") lines (envelope only — parity line added by the suite from the producer)"
