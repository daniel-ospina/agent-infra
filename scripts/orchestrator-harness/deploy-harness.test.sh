#!/usr/bin/env bash
# deploy-harness.test.sh — the regression contract for agent-infra#2041.
#
# The issue: `bg/finish.sh` deployed with a bare `cp -R`, ignored its rc, and then notified
# "convergence COMPLETE … $(ls "$O"/*.sh | wc -l) scripts" unconditionally. On a box whose checkout
# pre-dated the harness the `cp` returned 1, the deploy copied NOTHING, and the notification still
# reported the previous deployment's file count as this deploy's evidence. `gh-limit.py`, the
# `gh-limit/` shim and six reaper scripts were missing from a deployment everybody believed current.
#
# This suite drives the SHIPPED `deploy-harness.sh` against scratch sources and scratch runtimes. It
# asserts the behaviours the issue's Indicators name, and — the part that matters — it asserts them
# in the shape that was MEASURED, not a convenient one:
#
#   * a source directory that does not exist FAILS, in a runtime that is already full of scripts
#     (the 30-file pre-seeded target is the measured false-positive: "there are files there, so the
#     deploy must have worked");
#   * a deploy that copies nothing can never emit a success verdict;
#   * a copy that fails for ONE file is a FAILURE — partial is not success, and the count reported is
#     this run's, never the target's;
#   * a copy that "succeeds" but does not match the source is a FAILURE (the verification gate is
#     load-bearing, not decorative);
#   * every failing path notifies FAILURE, and no failing path notifies success;
#   * a preflight refusal leaves the target BYTE-IDENTICAL — a bad deploy changes nothing;
#   * a good deploy lands subdirectories (`gh-rest/gh`, `gh-limit/gh`, `retired/*.sh`), replaces a
#     stale file, preserves the executable bit, and does not disturb unrelated runtime files.
#
# Run: bash scripts/orchestrator-harness/deploy-harness.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${DEPLOY_UNDER_TEST:-$HERE/deploy-harness.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/deploy-harness-test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

[ -f "$DEPLOY" ] && ok "shipped deploy helper present: $(basename "$DEPLOY")" || { bad "missing $DEPLOY"; exit 1; }
[ -x "$DEPLOY" ] || bad "shipped deploy helper is not executable"
bash -n "$DEPLOY" 2>/dev/null && ok "deploy helper parses" || bad "deploy helper does not parse"

REAL_CP="$(command -v cp)"
REAL_CMP="$(command -v cmp)"

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
# A source that looks like the shipped harness: top-level scripts, two subdirectory shims (the pair
# the measured box was missing), and a retired/ file. Plus a file whose executable bit matters.
make_src() { # make_src <dir>
  local d="$1"
  mkdir -p "$d/gh-rest" "$d/gh-limit" "$d/retired"
  printf '#!/bin/bash\necho orch-loop v2\n'   > "$d/orch-loop.sh"
  printf '#!/bin/bash\necho claims v2\n'      > "$d/claims.sh"
  printf '#!/bin/bash\necho merge-one v2\n'   > "$d/merge-one.sh"
  printf '#!/usr/bin/env python3\nprint(1)\n' > "$d/gh-limit.py"
  printf '#!/bin/bash\necho rest\n'           > "$d/gh-rest/gh"
  printf '#!/bin/bash\necho limit-shim\n'     > "$d/gh-limit/gh"
  printf '#!/bin/bash\necho old\n'            > "$d/retired/sweep.sh"
  printf 'plain data\n'                       > "$d/port-provenance.txt"
  chmod +x "$d"/*.sh "$d"/*.py "$d"/gh-rest/gh "$d"/gh-limit/gh "$d"/retired/sweep.sh
}
# A runtime that ALREADY has a full deployment (stale bytes) plus unrelated runtime state. The stale
# orch-loop.sh is the file a correct deploy must replace; `keep-state.txt` is the file it must not.
make_target() { # make_target <dir> [pre-seed-count]
  local d="$1" n="${2:-0}" i
  mkdir -p "$d/state" "$d/logs"
  printf '#!/bin/bash\necho orch-loop STALE\n' > "$d/orch-loop.sh"; chmod +x "$d/orch-loop.sh"
  printf 'runtime state — must survive any deploy\n' > "$d/keep-state.txt"
  printf 'live-only patch\n' > "$d/live-only.sh"
  for i in $(seq 1 "$n"); do printf '#!/bin/bash\n# pre-existing script %s\n' "$i" > "$d/preseed-$i.sh"; done
}
# The notifier stub. It records EXACTLY the calls the helper made — that log is the assertion surface
# for "the notification is gated on the verdict". `BGDIR` points it away from the target so a
# notification never mutates the directory we are asserting is untouched.
NOTIFY="$T/bin/notify.sh"; mkdir -p "$T/bin"
cat > "$NOTIFY" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${2:-}" "${3:-}" >> "$DEPLOY_TEST_NOTIFY_LOG"
echo "  [notify] $1: ${2:-}"
SH
chmod +x "$NOTIFY"
NLOG="$T/notify.log"
export DEPLOY_TEST_NOTIFY_LOG="$NLOG"
notify_lines() { [ -f "$NLOG" ] && wc -l < "$NLOG" | tr -d ' ' || echo 0; }
notify_reset() { : > "$NLOG"; }
notify_last()  { tail -1 "$NLOG" 2>/dev/null; }
notify_has()   { [ -f "$NLOG" ] && grep -q -- "$1" "$NLOG"; }
notify_success() { notify_has "deploy VERIFIED"; }
notify_failure() { notify_has "deploy FAILED"; }

# `deploy <src> <o> [extra args...]` -> sets RC, OUT
deploy() {
  local src="$1" o="$2"; shift 2
  OUT="$(bash "$DEPLOY" --src "$src" --o "$o" --notify "$NOTIFY" "$@" 2>&1)"; RC=$?
}
# A byte-level snapshot of a directory, for "the target was left untouched" assertions. Sizes are
# useless for that (the measured doc's own rule) — this hashes the bytes and the modes.
snapshot() { ( cd "$1" 2>/dev/null && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s %s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)" "$( [ -x "$f" ] && echo x || echo - )"; done ); }

# ── 1. THE HAPPY PATH — and proof that it is a deploy, not a listing ────────────────────────────
say_case "1. a valid source deploys, verifies, and notifies success"
SRC1="$T/src1"; O1="$T/o1"; make_src "$SRC1"; make_target "$O1"
mkdir -p "$O1/bg"
# ⛔ THE SELF-CONFIRMING SHAPE, on purpose: the target already holds 30 scripts AND the exact files
# the source ships. A deploy that counted what is already there would call this a success before it
# copied anything. The assertion is that success comes from the COPY, so the stale orch-loop.sh must
# be replaced and the unrelated files must survive.
BEFORE_LIVE="$(shasum -a 256 < "$O1/live-only.sh" | cut -d' ' -f1)"
notify_reset
deploy "$SRC1" "$O1"
if [ "$RC" -eq 0 ]; then ok "valid source -> exit 0"; else bad "valid source -> exit $RC (expected 0): $OUT"; fi
echo "$OUT" | grep -q "VERIFIED" && ok "prints the VERIFIED verdict" || bad "no VERIFIED verdict in output"
if notify_success; then ok "notification is the SUCCESS one"; else bad "no success notification (got: $(notify_last))"; fi
notify_failure && bad "a successful deploy also notified FAILURE" || ok "success path emits no failure notification"
[ "$(notify_lines)" = "1" ] && ok "exactly one notification per run" || bad "$(notify_lines) notifications for one run"

# the copy really happened: stale bytes replaced, by comparison with the source
cmp -s "$SRC1/orch-loop.sh" "$O1/orch-loop.sh" && ok "stale orch-loop.sh replaced with the source bytes" || bad "orch-loop.sh does not match the source"
cmp -s "$SRC1/claims.sh" "$O1/claims.sh"     && ok "claims.sh present and identical" || bad "claims.sh missing or differs"
# subdirectories — the measured gap (gh-rest/gh, gh-limit/gh never landed)
[ -f "$O1/gh-rest/gh" ] && cmp -s "$SRC1/gh-rest/gh" "$O1/gh-rest/gh" && ok "subdir gh-rest/gh deployed" || bad "subdir gh-rest/gh NOT deployed"
[ -f "$O1/gh-limit/gh" ] && cmp -s "$SRC1/gh-limit/gh" "$O1/gh-limit/gh" && ok "subdir gh-limit/gh deployed" || bad "subdir gh-limit/gh NOT deployed"
[ -f "$O1/retired/sweep.sh" ] && ok "nested retired/ deployed" || bad "nested retired/ NOT deployed"
# the executable bit — a 0644 merge-one.sh is a loop that cannot spawn, and the loss is silent
[ -x "$O1/merge-one.sh" ] && ok "executable bit preserved" || bad "executable bit LOST on merge-one.sh"
[ ! -x "$O1/port-provenance.txt" ] && ok "non-executable file stays non-executable" || bad "port-provenance.txt gained +x"
# runtime state is not the harness and must not be touched
[ "$(shasum -a 256 < "$O1/live-only.sh" | cut -d' ' -f1)" = "$BEFORE_LIVE" ] && ok "live-only runtime file untouched" || bad "deploy overwrote or removed a non-harness file"
[ -f "$O1/keep-state.txt" ] && ok "runtime state file preserved" || bad "runtime state file destroyed"
grep -q "verified	gh-rest/gh" "$O1/.deploy-ledger.tsv" 2>/dev/null && ok "per-file ledger records the copy" || bad "no per-file ledger entry for gh-rest/gh"

# ── 2. THE MEASURED DEFECT — absent source against a target full of scripts ──────────────────────
say_case "2. absent source, target pre-seeded with 30 scripts -> FAILURE, target untouched"
O2="$T/o2"; make_target "$O2" 30
BEFORE="$(snapshot "$O2")"
notify_reset
deploy "$T/does-not-exist" "$O2"
[ "$RC" -ne 0 ] && ok "absent source -> non-zero exit ($RC)" || bad "absent source exited 0 — the #2041 false PASS"
[ "$RC" = "78" ] && ok "exit 78 (refused before touching anything)" || bad "exit $RC, expected 78"
notify_failure && ok "failure notification emitted" || bad "NO failure notification for an absent source"
notify_success && bad "an absent source notified SUCCESS" || ok "no success notification"
grep -qi "does not exist" <<< "$(notify_last)" && ok "notification names the cause" || bad "notification does not name the cause: $(notify_last)"
if [ "$(snapshot "$O2")" = "$BEFORE" ]; then ok "target byte-identical after the refusal"; else bad "the refusal MODIFIED the target"; fi
# the exact self-confirming counter from the old line 34 must not appear as evidence of anything
echo "$OUT" | grep -q "30" && bad "output leans on the pre-existing file count" || ok "output does not cite pre-existing file counts"

# ── 3. NOTHING COPIED — a source that ships no files ─────────────────────────────────────────────
say_case "3. source shipping zero files -> FAILURE (a deploy of nothing is not a success)"
SRC3="$T/src3"; O3="$T/o3"; mkdir -p "$SRC3"; make_target "$O3" 5
BEFORE="$(snapshot "$O3")"
notify_reset; deploy "$SRC3" "$O3"
[ "$RC" -ne 0 ] && ok "empty source -> non-zero exit ($RC)" || bad "empty source exited 0"
notify_success && bad "empty source notified SUCCESS — indicator (b) violated" || ok "no success notification (0 files copied)"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
[ "$(snapshot "$O3")" = "$BEFORE" ] && ok "target untouched" || bad "empty-source refusal modified the target"

# ── 4. A DIRECTORY THAT IS NOT THE HARNESS ───────────────────────────────────────────────────────
say_case "4. a source with no orch-loop.sh/claims.sh is refused, not deployed"
SRC4="$T/src4"; O4="$T/o4"; mkdir -p "$SRC4"; printf 'not a harness\n' > "$SRC4/random.sh"; make_target "$O4"
BEFORE="$(snapshot "$O4")"
notify_reset; deploy "$SRC4" "$O4"
[ "$RC" -ne 0 ] && ok "non-harness source -> non-zero exit ($RC)" || bad "non-harness source exited 0"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
notify_success && bad "non-harness source notified SUCCESS" || ok "no success notification"
[ "$(snapshot "$O4")" = "$BEFORE" ] && ok "target untouched" || bad "refusal modified the target"

# ── 5. A COPY THAT FAILS MID-RUN — partial is not success ────────────────────────────────────────
say_case "5. copy fails for one file mid-run -> FAILURE, no partial success claimed"
SRC5="$T/src5"; O5="$T/o5"; make_src "$SRC5"; make_target "$O5" 10
# A `cp` shim that fails for exactly one file. This is the "copy status per file" the fix is built
# on: the helper must PROPAGATE a failed copy, not discover it later and not average it away.
mkdir -p "$T/cpbin"
cat > "$T/cpbin/cp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *merge-one.sh) echo "cp: \$a: permission denied" >&2; exit 1 ;; esac
done
exec "$REAL_CP" "\$@"
SH
chmod +x "$T/cpbin/cp"
notify_reset
OUT="$(PATH="$T/cpbin:$PATH" bash "$DEPLOY" --src "$SRC5" --o "$O5" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "failed copy -> non-zero exit ($RC)" || bad "failed copy exited 0"
[ "$RC" = "1" ] && ok "exit 1 (copy failure, not a refusal)" || bad "exit $RC, expected 1"
notify_failure && ok "failure notification emitted" || bad "no failure notification for a failed copy"
notify_success && bad "a failed copy notified SUCCESS — partial success claimed" || ok "no success notification"
grep -q "PARTIAL" <<< "$(notify_last)" && ok "notification states the runtime is now partial" || bad "notification does not warn about the partial runtime: $(notify_last)"
grep -q "merge-one.sh" <<< "$(notify_last)" && ok "notification names the failed file" || bad "notification does not name the failed file"
grep -q "COPY-FAIL	merge-one.sh" "$O5/.deploy-ledger.tsv" 2>/dev/null && ok "ledger records the failed file" || bad "ledger does not record the failed copy"
grep -qi "VERIFIED" <<< "$(notify_last)" && bad "failure notification contains the success vocabulary" || ok "failure notification carries no success claim"
# the count in the message must be THIS RUN's copy count, never a listing of the target (28 pre-
# existing + 9 copied would look like "37 files, all good" — the old formula's exact failure)
grep -q "$(ls "$O5"/*.sh 2>/dev/null | wc -l | tr -d ' ') of" <<< "$(notify_last)" && bad "notification quotes the target's file count as evidence" || ok "notification does not quote the target's file count"

# ── 6. A COPY THAT SILENTLY DOES NOT MATCH — the verification gate is load-bearing ───────────────
say_case "6. copy reports success but bytes differ -> FAILURE (verification, not the copy, decides)"
SRC6="$T/src6"; O6="$T/o6"; make_src "$SRC6"; make_target "$O6"
# A `cmp` that lies for exactly one file: the copy path is untouched, so ONLY the verification half
# can catch this. If this case passes with a success verdict, the gate is decorative.
mkdir -p "$T/cmpbin"
cat > "$T/cmpbin/cmp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *claims.sh) exit 1 ;; esac
done
exec "$REAL_CMP" "\$@"
SH
chmod +x "$T/cmpbin/cmp"
notify_reset
OUT="$(PATH="$T/cmpbin:$PATH" bash "$DEPLOY" --src "$SRC6" --o "$O6" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "unverified bytes -> non-zero exit ($RC)" || bad "unverified bytes exited 0"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
notify_success && bad "unverified bytes notified SUCCESS" || ok "no success notification"
grep -q "DRIFT	claims.sh" "$O6/.deploy-ledger.tsv" 2>/dev/null && ok "ledger records the drift" || bad "ledger does not record the drift"
grep -qi "verification failed" <<< "$OUT" && ok "reports a VERIFICATION failure (distinct from a copy failure)" || bad "does not report a verification failure: $OUT"

# ── 7. A REAL UNREADABLE SOURCE FILE (the issue's own case (c), non-root only) ───────────────────
say_case "7. an unreadable source file -> FAILURE, not partial success"
if [ "$(id -u)" = "0" ]; then
  echo "  (skipped — running as root, where chmod 000 is still readable)"
else
  SRC7="$T/src7"; O7="$T/o7"; make_src "$SRC7"; make_target "$O7"
  chmod 000 "$SRC7/merge-one.sh"
  notify_reset; deploy "$SRC7" "$O7"
  chmod 644 "$SRC7/merge-one.sh"
  [ "$RC" -ne 0 ] && ok "unreadable source file -> non-zero exit ($RC)" || bad "unreadable source file exited 0"
  notify_success && bad "unreadable source file notified SUCCESS" || ok "no success notification"
  notify_failure && ok "failure notification emitted" || bad "no failure notification"
fi

# ── 8. A TARGET SHAPE THAT WOULD SWALLOW THE RENAME ─────────────────────────────────────────────
say_case "8. a directory where a file belongs is a copy failure, not a silent move-into"
SRC8="$T/src8"; O8="$T/o8"; make_src "$SRC8"; make_target "$O8"
mkdir -p "$O8/claims.sh"          # a DIRECTORY sitting where claims.sh belongs
notify_reset; deploy "$SRC8" "$O8"
[ "$RC" -ne 0 ] && ok "wrong target shape -> non-zero exit ($RC)" || bad "wrong target shape exited 0"
notify_success && bad "wrong target shape notified SUCCESS" || ok "no success notification"
[ -d "$O8/claims.sh" ] && ok "the directory was not silently replaced" || bad "deploy replaced a directory"

# ── 9. THE VERDICT IS NOT HOSTAGE TO THE NOTIFIER ───────────────────────────────────────────────
say_case "9. an unrunnable notifier does not fake a failure, and does not fake a report"
SRC9="$T/src9"; O9="$T/o9"; make_src "$SRC9"; make_target "$O9"
OUT="$(bash "$DEPLOY" --src "$SRC9" --o "$O9" --notify "$T/nope.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "verified deploy still exits 0 without a notifier" || bad "missing notifier turned a good deploy into exit $RC"
grep -qi "notify-UNRUNNABLE\|no notifier at" <<< "$OUT" && ok "says loudly that nobody was notified" || bad "silently declined to notify"
# and --no-notify is honoured
notify_reset
OUT="$(bash "$DEPLOY" --src "$SRC9" --o "$O9" --no-notify 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--no-notify still verifies (exit 0)" || bad "--no-notify exited $RC"
[ "$(notify_lines)" = "0" ] && ok "--no-notify fired no notification" || bad "--no-notify still fired $(notify_lines)"

# ── 10. IDEMPOTENCE — a second deploy of the same source is still a verified success ──────────────
say_case "10. re-running the deploy over its own output is a verified success"
notify_reset; deploy "$SRC1" "$O1"
[ "$RC" -eq 0 ] && ok "second run exits 0" || bad "second run exited $RC"
notify_success && ok "second run verifies (bytes already matched, and it still copied them)" || bad "second run did not verify: $(notify_last)"
[ "$(notify_lines)" = "1" ] && ok "exactly one notification on the second run" || bad "$(notify_lines) notifications"

# ── 11. THE DOCUMENTED CALL SITE — bg/finish.sh must not be able to bypass the verdict ───────────
say_case "11. the helper owns the verdict, so a caller cannot announce success on a failed deploy"
# The old finish.sh announced success as a SIBLING statement, so the fix is that success exists only
# as this script's exit code + its own notification. Structural assertion: the success string is
# emitted on exactly one line of the helper, and that line is unreachable on any failure path
# (it sits after the copy-fail and verify-fail gates, which both `exit 1`).
n_success_lines="$(grep -c 'harness deploy VERIFIED' "$DEPLOY")"
[ "$n_success_lines" = "1" ] && ok "one success-notification site" || bad "$n_success_lines success-notification sites (expected 1)"
n_verified_print="$(grep -c 'say "\$PROG: VERIFIED' "$DEPLOY")"
[ "$n_verified_print" = "1" ] && ok "one VERIFIED print site" || bad "$n_verified_print VERIFIED print sites (expected 1)"
grep -v '^[[:space:]]*#' "$DEPLOY" | grep -q 'ls "\$O"' && bad "the helper counts files from the target (self-confirming evidence)" || ok "the helper never counts files from the target"
grep -v '^[[:space:]]*#' "$DEPLOY" | grep -q 'cp -R' && bad "the helper still uses a bare recursive cp" || ok "no bare recursive copy"

echo
echo "════════════════════════════════════════"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: CLEAN"; exit 0; }
echo "RESULT: $FAIL FAILURE(S)"
exit 1
