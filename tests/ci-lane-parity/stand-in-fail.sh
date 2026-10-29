#!/usr/bin/env bash
# stand-in-fail.sh — the ONE failing shard the runner's naming arm needs (#2643).
#
# WHY THIS FILE EXISTS
# --------------------
# `scripts/run-bash-shards.sh` prints the NAME of a failing shard (`❌ FAILED SHARD: <path>`) and a
# recap (`❌ failing shard(s): <path,…>`). That is the whole point of the change: main and every PR
# carried four red shards for hours on 2026-10-24, and `❌ 4 bash shard(s) failed` named none of
# them, so every lane re-derived the same four from the CI log by hand.
#
# A READER-FACING LINE NOBODY ASSERTS IS A LINE THE NEXT REFACTOR DELETES SILENTLY. The runner's own
# runtime sentinels prove the COUNTER is wired; they cannot prove a NAME is printed, because the
# sentinel is deliberately not a listed shard (a green run must never print a name — see
# `shard_fail`'s `shard_is_listed` gate). So the arm that pins the naming lives in
# `tests/ci-lane-parity/run.sh` (§8am), and it needs a shard that FAILS, is committed, and is
# hermetic: this one. Its rc depends on nothing but itself.
#
# ⛔ Do NOT "fix" this file to exit 0 — §8am's non-vacuity half requires a runner built from this
# stand-in to print no name when the naming is deleted, and to print this path when it is not.
exit 1
