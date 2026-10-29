#!/bin/bash
# tests/ci-lane-parity/stand-in-shard-fail.sh — a HERMETIC stand-in that FAILS, for the ATTRIBUTION
# pin in tests/ci-lane-parity/run.sh (arm 8am, #2643).
#
# WHY THIS FILE EXISTS
#   `stand-in-shard.sh` is a single `exit 0`, which is exactly what the counter/sweep/sentinel pins
#   need and exactly what the attribution pin cannot use: "a failed shard is NAMED" needs a shard that
#   actually fails, inside the checkout (the runner refuses any target that resolves outside it, or
#   through a symlink), and hermetic (its rc must depend on nothing but itself, so an unrelated red
#   elsewhere in the tree can never make this pin pass or fail for the wrong reason).
#
# WHY IT PRINTS
#   One line, so a reader of a FAILING 8s can tell which fixture spoke. It must NOT contain the
#   string the runner prints for the attribution (`❌ failed shard: <path>`), or the pin could be
#   satisfied by the shop's own output rather than by the runner's.

echo "stand-in-shard-fail: this fixture fails on purpose (#2643 arm 8am)"
exit 1
