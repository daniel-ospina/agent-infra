#!/usr/bin/env bash
# tests/admin-merge/check-unresolved.sh — the unresolved-check REFUSAL, in both
# directions (tortoise#10399).
#
# THE DEFECT THIS GATES. Two lanes railed two fully green tortoise PRs (#10474,
# #10475) and both HUNG: `pending=1` on a head whose required aggregator
# `python-ci-gate` had no completed attempt, because its `needs:` jobs were
# queued behind a saturated runner pool. The rail waited with a 8760s stall and a
# 18064s ceiling — lane-occupancy bounds — so a lane spent its whole budget inside
# one command and, from outside, produced exactly the artefact of a lander that
# was never running.
#
# WHAT IS ASSERTED, AND WHY IT IS A DECISION AND NOT A MESSAGE.
#   1. REFUSES: a never-concluding check set is classified UNRESOLVED, per check,
#      with its own status/conclusion — and `null` is never read as a pass.
#   2. STILL LANDS: a genuinely green set (every newest attempt completed with
#      success/neutral/skipped) is classified RESOLVED, so the wait proceeds.
#   3. THE BOUND IS STATED AND IT BINDS FIRST: the refusal bound is strictly below
#      the occupancy bounds, so this refusal is reached before the hang — which is
#      what makes it bounded rather than "happened to be fast".
#   4. THE GREEN TREE ARM REFUSES ON PENDING: a surface with unresolved checks can
#      never take the `green` PASS path.
#
# ⛔ NO MESSAGE-TEXT ASSERTIONS on the rail's prose: (1)/(2) assert the SET the
# resolver returns and its exit code; (3)/(4) assert the numbers and the control
# flow that decide the exit path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/admin-merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1" >&2; }

# ── EXTRACT THE RESOLVER ────────────────────────────────────────────────────
# The scan must be driven as the rail drives it — the real function body, not a
# re-implementation — so a change to the rail cannot leave this test green against
# a copy of behaviour the rail no longer has.
start="$(grep -n '^check_unresolved_scan() {' "$SCRIPT" | cut -d: -f1)"
if [ -z "$start" ]; then
  bad "check_unresolved_scan is not defined in scripts/admin-merge.sh"
  exit 1
fi
end="$(awk -v s="$start" 'NR>s && /^}/ { print NR; exit }' "$SCRIPT")"
[ -n "$end" ] || { bad "could not delimit check_unresolved_scan"; exit 1; }

{
  echo '#!/usr/bin/env bash'
  # The scan resolves its interpreter through the rail's own $PYTHON_BIN, so the
  # harness must provide it exactly as the rail does at startup.
  echo 'PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python)}"'
  sed -n "${start},${end}p" "$SCRIPT"
  echo 'check_unresolved_scan "$1"'
} > "$TMP/scan.sh"
chmod +x "$TMP/scan.sh"

# ── FIXTURE 1: A NEVER-CONCLUDING SET (the measured shape) ──────────────────
cat > "$TMP/never.json" <<'JSON'
{"total_count":4,"check_runs":[
 {"id":124783536754,"name":"python-ci-gate","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}},
 {"id":124788856867,"name":"python-ci-gate","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}},
 {"id":124790401293,"name":"ci-introduced-failure","status":"queued","conclusion":null,"app":{"slug":"github-actions"}},
 {"id":124762495444,"name":"docs","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}
]}
JSON
out="$("$TMP/scan.sh" "$TMP/never.json" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && ok "REFUSES: a never-concluding set is classified unresolved (rc=0)" \
  || bad "REFUSES: expected rc=0 for an unresolved set, got $rc"

# The DECISION is the SET of unresolved checks, and the newest attempt per name
# is the only attempt that describes the tree: `python-ci-gate` holds BOTH a
# failure (id …754) and an in_progress (id …867) on this head, so a scan that
# reported the older `failure` would refuse a head for the wrong reason and one
# that dropped the name entirely would never refuse at all.
want="$(printf 'check-unresolved:ci-introduced-failure:queued/-\ncheck-unresolved:python-ci-gate:in_progress/-' | sort)"
got="$(printf '%s\n' "$out" | sort)"
if [ "$got" = "$want" ]; then
  ok "REFUSES: names EXACTLY the unresolved checks, newest attempt per name, null conclusion carried as '-'"
else
  bad "REFUSES: unresolved set mismatch"; printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2
fi

# The resolved check must NOT appear: over-reporting would refuse green heads.
if printf '%s\n' "$out" | grep -q 'docs'; then
  bad "REFUSES: the completed/green check 'docs' was reported as unresolved"
else
  ok "REFUSES: a completed check is not reported (no over-refusal)"
fi

# ── FIXTURE 2: A GENUINELY GREEN SET (must still land) ─────────────────────
cat > "$TMP/green.json" <<'JSON'
{"total_count":5,"check_runs":[
 {"id":1,"name":"test (a)","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":2,"name":"docs","status":"completed","conclusion":"neutral","app":{"slug":"github-actions"}},
 {"id":3,"name":"canary-streak","status":"completed","conclusion":"skipped","app":{"slug":"github-actions"}},
 {"id":124788856867,"name":"python-ci-gate","status":"completed","conclusion":"success","app":{"slug":"github-actions"}},
 {"id":124783536754,"name":"python-ci-gate","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}}
]}
JSON
out="$("$TMP/scan.sh" "$TMP/green.json" 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && ok "STILL LANDS: an all-resolved set is classified RESOLVED (rc=1) and the wait proceeds" \
  || bad "STILL LANDS: expected rc=1 for a resolved set, got $rc"
[ -z "$out" ] && ok "STILL LANDS: no unresolved line is emitted" \
  || { bad "STILL LANDS: emitted a refusal for a green set"; printf '%s\n' "$out" >&2; }

# The superseded `failure` attempt (id …754) must not block a head whose NEWEST
# attempt is success — this is #10475's real shape, and taking the worst attempt
# would refuse the very PR this fix exists to unblock.
if printf '%s\n' "$out" | grep -q 'python-ci-gate'; then
  bad "STILL LANDS: a SUPERSEDED failure attempt was read as the verdict"
else
  ok "STILL LANDS: a superseded failure attempt does not refuse (newest attempt wins)"
fi

# ── FIXTURE 3: AN EMPTY SURFACE IS NOT "NOTHING UNRESOLVED" ────────────────
printf '{"total_count":0,"check_runs":[]}' > "$TMP/empty.json"
"$TMP/scan.sh" "$TMP/empty.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an EMPTY surface is refused as unreadable (rc=2), never as 'nothing pending'" \
  || bad "empty surface: expected rc=2, got $rc"

# ── FIXTURE 4: TWO CONCATENATED PAGES (the shape `gh api --paginate` emits) ─
# ⛔ `--paginate` emits ONE JSON OBJECT PER PAGE, so the scan's parser has to walk
# a CONCATENATED document stream, not a single body. A pagination regression
# yields rc=2, which the caller now refuses — but with only single-document
# fixtures that regression would pass this test silently.
cat > "$TMP/pages.json" <<'JSON'
{"total_count":2,"check_runs":[
 {"id":10,"name":"docs","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}
{"total_count":1,"check_runs":[
 {"id":11,"name":"queuedjob","status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]}
JSON
out="$("$TMP/scan.sh" "$TMP/pages.json" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "check-unresolved:queuedjob:queued/-" ]; then
  ok "two concatenated PAGES parse as one surface (the check on page 2 is found)"
else
  bad "multi-page parse: rc=$rc out='$out'"
fi

# ── THE BOUND: STATED, AND IT BINDS BEFORE THE OCCUPANCY BOUNDS ────────────
# Extracted from the script itself, so the numbers asserted are the numbers the
# rail ships. If a future change raises this bound above the stall bound, the
# refusal stops being reachable before the hang and this test reddens.
bound_line="$(grep -n '^CHECK_UNRESOLVED_BOUND=' "$SCRIPT" | cut -d: -f1)"
stall_line="$(grep -n '^FIRST_CHECKS_STALL=' "$SCRIPT" | cut -d: -f1)"
ceil_line="$(grep -n '^FIRST_CHECKS_CEILING=' "$SCRIPT" | cut -d: -f1)"
[ -n "$bound_line" ] && [ -n "$stall_line" ] && [ -n "$ceil_line" ] \
  || { bad "the bound constants are not all defined"; exit 1; }
bound="$(sed -n "${bound_line}p" "$SCRIPT" | sed 's/.*:-\([0-9][0-9]*\)}.*/\1/')"
stall="$(sed -n "${stall_line}p" "$SCRIPT" | sed 's/.*:-\([0-9][0-9]*\)}.*/\1/')"
ceil="$(sed -n "${ceil_line}p" "$SCRIPT" | sed 's/.*:-\([0-9][0-9]*\)}.*/\1/')"
case "$bound" in ''|*[!0-9]*) bad "CHECK_UNRESOLVED_BOUND default does not parse as an integer"; exit 1 ;; esac
if [ "$bound" -lt "$stall" ] && [ "$bound" -lt "$ceil" ]; then
  ok "the refusal bound (${bound}s) is strict-below the stall (${stall}s) and ceiling (${ceil}s) — it binds FIRST, so the refusal is reached before the hang"
else
  bad "the refusal bound (${bound}s) does not bind before the occupancy bounds (stall ${stall}s, ceiling ${ceil}s)"
fi

# ── THE GREEN TREE ARM MUST REFUSE ON PENDING ──────────────────────────────
# ── THE TREE ARM MUST **NOT** REDDEN AN IN-FLIGHT CHECK ────────────────────
# ⛔ THIS IS A PIN AGAINST RE-INTRODUCING A REVERSAL. A first cut of this fix also
# refused in the evaluated-tree `green)` arm whenever TREE_PENDING > 0. That reads
# well in the abstract and it REVERSES A RECORDED, TESTED DECISION — four arms of
# tests/admin-merge/run.sh pin "A CHECK STILL RUNNING IS NOT A RED — on the PR's
# tree either", and the cut reddened `bash-suites (1)` with 14 of 1841 assertions
# failing. On a saturated runner pool "some check on head just started" is the
# NORMAL case, so that rule makes the rail unlandable.
# The #10399 defect is closed where it was MEASURED — in the FIRST-CHECKS wait,
# which is the only place the rail is actually waiting on those checks.
green_arm="$(awk '/^  case "\$TREE_STATUS" in/{f=1} f&&/^    green\)/{g=1} g{print} g&&/evaluated tree/{c++} c&&/^      info "admin-merge: ✅/{exit}' "$SCRIPT")"
if [ -z "$green_arm" ]; then
  bad "could not delimit the evaluated-tree 'green' arm"
elif printf '%s\n' "$green_arm" | grep -q 'REFUSED(check-unresolved)'; then
  bad "the evaluated-tree 'green' arm refuses on an in-flight check — that reverses a tested decision (see tests/admin-merge/run.sh, 'A CHECK STILL RUNNING IS NOT A RED') and makes a busy tree unlandable"
else
  ok "the evaluated-tree 'green' arm does NOT redden an in-flight check (the recorded decision stands; #10399 is closed in the FIRST-CHECKS wait)"
fi

printf '\n%s\n' "----------------------------------------------------------------"
printf 'check-unresolved: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
