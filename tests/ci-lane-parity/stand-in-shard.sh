#!/bin/bash
# tests/ci-lane-parity/stand-in-shard.sh — a HERMETIC stand-in target for the runtime pins in
# tests/ci-lane-parity/run.sh (8n, 8q, 8ac7).
#
# WHY THIS FILE EXISTS
#   Those pins replace every `run_shard` line with ONE cheap target so they can exercise the
#   runner's own self-checks — the listed==executed arithmetic, the sweep arm, the
#   failure-recording sentinel — without running the sixty real suites. The stand-in must
#   therefore answer with a FIXED rc that depends on nothing but itself.
#
# WHY IT IS NOT A REPO-WIDE GUARD
#   Until 2026-10-23 the stand-in was `scripts/check-no-sigpipe-grep.sh`. That guard's rc is a
#   function of EVERY file in the tree, so five `printf … | grep -q` idioms in
#   `scripts/orchestrator-harness/lander.test.sh` (#2301) turned 8n's CONTROL fixture red on every
#   PR — reported as "the control fixture returned rc 1", which blames the fixture and never names
#   the real cause (a different job's subject: `sigpipe-grep-guard`). It also cost 9.6 s per
#   invocation × 59 replaced shards × 2 sites: the lane's self-test spent ~38 min re-scanning the
#   repo to prove a runner's counter works.
#
# WHY IT IS A COMMITTED FILE AND NOT A $TMP STUB
#   The runner refuses a shard path that resolves outside this checkout, or through a symlink —
#   so the stand-in has to live inside the checkout. It is inert on purpose: one `exit 0`, no
#   output, no repo access. Keep it that way.

exit 0
