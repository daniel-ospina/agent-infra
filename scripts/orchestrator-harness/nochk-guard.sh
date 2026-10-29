#!/usr/bin/env bash
# nochk-guard.sh — the startup guard for the NOCHECKS arm's classification (agent-infra#2719).
#
# WHY THIS IS A SEPARATE FILE, NOT AN INLINE BLOCK IN orch-loop.sh.
# `check-class.py` is not "one arm": it is EVERY PR's classification. With it missing, `python3
# <missing>` writes to stderr and prints nothing, the sweep's pipeline yields `V=""` for every PR, and
# the controller falls to its residual wait arm — no merge, no fixer, no reviewer, re-read for ever.
# That is a total stop, so it takes the `exit 78` treatment `repo-authority.sh` already gets.
#
# ⛔ AND IT CANNOT LIVE INLINE IN THE LOOP (measured, review P1). Several shipped suites extract a
# one-line helper with `sed -n "/^$1()/,/^}/p"` (capacity-transfer.test.sh, live-ownership.test.sh,
# test-gates.sh). `is_num()` is such a one-liner, so its extraction runs to the NEXT line that starts
# with `}` — inserting any function with a closing brace ABOVE that point silently re-points the
# extraction, and `capacity-transfer.test.sh` went 4 red because the swallowed text referenced
# `$_HERE_RS` under `set -u`. Keeping the guard in its own sourced module means orch-loop.sh gains no
# new top-level `}` at all, so no peer suite's extraction can shift. (The real defect is the
# brace-blind extractor; that is filed separately rather than worked around forever here.)
#
# `orch-loop.sh` sources this file (the same $O-then-script-dir order repo-authority.sh gets) and
# calls `nochk_require_classifier`, failing closed when the function itself is absent.

nochk_require_classifier() { # <check-class.py|""> <nochk-resolve.py|""> <O> <harness-dir>; exits 78
  _ck="$1"; _nchk="$2"; _o="$3"; _hd="${4:-<unresolved>}"
  if [ -z "$_ck" ]; then
    _fatal_nock="FATAL check-class.py not found (looked in $_o and $_hd) — every PR's classification would be EMPTY (no merge, no fixer, no reviewer), so the controller refuses to start; re-seed it: bash $_o/deploy-harness.sh --src <harness checkout> --o $_o"
    echo "orch-loop: $_fatal_nock" >&2
    printf '%s [startup] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_fatal_nock" >> "$_o/logs/orch-loop.log" 2>/dev/null || true
    exit 78
  fi
  if [ -z "$_nchk" ]; then
    # A DEGRADED ARM IS NOT A FATAL: a NOCHECKS PR is then NAMED "the arm produced no verdict" and
    # re-read next cycle — never silently, never spun.
    printf '%s [startup] ⚠️ NOCHECKS ARM ABSENT: nochk-resolve.py was not found in %s or %s — a NOCHECKS PR is NAMED as "the arm produced no verdict" and re-read next cycle (never silently, never spun); re-seed the harness (deploy-harness.sh)\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_o" "$_hd" >> "$_o/logs/orch-loop.log" 2>/dev/null || true
  fi
  return 0
}
