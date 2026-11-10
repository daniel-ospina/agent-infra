#!/usr/bin/env bash
# WORKED EXAMPLE — the #3368 prefix-match shape (agent-infra#3442).
#
# NOT EXECUTED BY ANYTHING. This file is READ by `mutation-attribution.test.sh` as the copyable shape
# for a bash suite's own NON-VACUITY proof. A real suite puts this block at the end of its own file,
# derived FROM the shipped script, exactly as `brief-gate.test.sh` section G does.
#
# WHY THIS SHAPE EXISTS. #3368's new gate asserted `reason=pin-tree` while the pre-fix code emitted
# `reason=pin-tree-shape`. Both matched on a PREFIX, so deleting the ENTIRE record-based probe left
# the suite green: the assertion was satisfied by a sibling path it was never meant to cover. The
# mutant below is the one that catches it — it deletes the probe, so a gate that only prefix-matches
# keeps passing while the row that NAMES the probe must go red.
set -u

# The mutation is derived from the SHIPPED file so it tracks it, never from the test.
mutant="$TMP/gate.no-probe.sh"
sed '/^  # the record-based probe$/,/^  # end record-based probe$/d' "$GATE_SRC" > "$mutant"
# The transformation is ASSERTED, not assumed: if the anchor stops matching, sed yields an UNCHANGED
# file and the arms below pass for the wrong reason.
cmp -s "$GATE_SRC" "$mutant" && { echo "MUTANT: the sed anchor no longer matches"; exit 1; }
bash -n "$mutant" || { echo "MUTANT: does not parse"; exit 1; }   # alive: not a syntax error
out="$(bash "$mutant" --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || { echo "MUTANT: the gate accepted what the probe should refuse"; exit 1; }
# THE ROW THAT NAMES THE BEHAVIOUR — an exact reason, never a prefix match.
grep -qx 'reason=pin-tree' <<<"$out" || { echo "the attribution row did not go red"; exit 1; }
