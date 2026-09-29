#!/bin/bash
# Build the clause-7 fixtures. Run from anywhere; rewrites the two committed
# fixtures from the committed RAW capture (no network, no /tmp dependency).
#
# The RAW capture is committed alongside as `raw-1406-capture.md`, so these
# fixtures are REGENERABLE from the repository. (The first version of this script
# read an untracked `/tmp/captured-1406.md`, which meant the "real capture" could
# not be re-derived by anyone else — a fixture whose provenance is unreproducible
# is one step from a hand-written fixture, which is the failure this suite exists
# to catch.)
#
# NEG = the real, VERBATIM evidence comment posted by scripts/admin-merge.sh on
#       agent-infra#1406 (head 6f5366c6f4dbcfd9158fc3b2172758eac0390b45),
#       captured 2026-09-23. It is VACUOUS (both counts are 0) and its parity line
#       reads `lane parity: NOT ESTABLISHED — declared off`, so the contract
#       REFUSES it. This is the only byte-for-byte real body, and it is the
#       reference the drift-pin checks every required literal against.
#
# POS = the SAME ENVELOPE with a NON-VACUOUS count line. This is SYNTHETIC and the
#       filename says so: the producer emits its vacuous state block whenever both
#       counts are 0, so a real capture with non-zero counts would need a different
#       PR (one that actually had failures) — the envelope, the clause-4 line and
#       the attribution line are the capture's, the two counts are not. It exists
#       to prove that clause 4 accepts the producer's current vocabulary; the
#       suite labels it synthetic, and the earlier version of this script claimed
#       parity was "added from the producer" while emitting a file with no parity
#       line at all.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cp "$D/raw-1406-capture.md" "$D/captured-1406-vacuous-parity-not-established.md"
python3 - "$D/captured-1406-vacuous-parity-not-established.md" "$D/derived-1406-nonvacuous-counts.md" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
before = text
# Replace the two zero counts with non-zero ones, keeping the clause-4 spelling
# and the rest of the envelope byte-for-byte. Both counts non-zero => NOT vacuous,
# so clause 5's parity requirement does not apply.
text = re.sub(r"PR failing: 0 \| main failing: 0 \| blocked by the decision: 0",
              "PR failing: 2 | main failing: 7 | blocked by the decision: 0", text)
assert text != before, "the count line was not found — capture shape changed"
open(dst, "w", encoding="utf-8").write(text)
print("POS written; counts made non-vacuous (synthetic counts, real envelope)")
PY
echo "NEG: $(wc -l < "$D/captured-1406-vacuous-parity-not-established.md") lines (REAL capture: vacuous, parity NOT ESTABLISHED)"
echo "POS: $(wc -l < "$D/derived-1406-nonvacuous-counts.md") lines (SYNTHETIC non-vacuous counts over the real envelope)"
