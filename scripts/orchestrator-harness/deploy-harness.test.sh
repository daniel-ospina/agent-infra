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
# ⛔ THE HASHER IS RESOLVED ONCE AND IS MANDATORY. `shasum -a 256` was hardcoded with no fallback, so
# on a host without it every hash slot in `snapshot()` came back EMPTY and the "target BYTE-IDENTICAL"
# assertions degraded to a filename+mode comparison while still printing ✅ — a green verdict over no
# evidence, the exact false-PASS class this suite exists to forbid. The repo's idiom is
# sha256sum-first (`check-deployed-drift.sh:163`, `install.sh:745`, `cloud-cell-supervisor.sh:744`).
SHA_CMD="sha256sum"
command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"
if ! printf 'x' | $SHA_CMD >/dev/null 2>&1; then
  echo "FATAL: no usable sha256 tool (sha256sum / shasum -a 256) — refusing to report byte assertions as passed" >&2
  exit 1
fi
sha256_of() { $SHA_CMD < "$1" | cut -d' ' -f1; }

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
  printf '%s %s %s\n' "$f" "$(sha256_of "$f")" "$( [ -x "$f" ] && echo x || echo - )"; done ); }

# ── 1. THE HAPPY PATH — and proof that it is a deploy, not a listing ────────────────────────────
say_case "1. a valid source deploys, verifies, and notifies success"
SRC1="$T/src1"; O1="$T/o1"; make_src "$SRC1"; make_target "$O1"
mkdir -p "$O1/bg"
# ⛔ THE SELF-CONFIRMING SHAPE, on purpose: the target already holds 30 scripts AND the exact files
# the source ships. A deploy that counted what is already there would call this a success before it
# copied anything. The assertion is that success comes from the COPY, so the stale orch-loop.sh must
# be replaced and the unrelated files must survive.
BEFORE_LIVE="$(sha256_of "$O1/live-only.sh")"
notify_reset
deploy "$SRC1" "$O1"
if [ "$RC" -eq 0 ]; then ok "valid source -> exit 0"; else bad "valid source -> exit $RC (expected 0): $OUT"; fi
grep -q "VERIFIED" <<< "$OUT" && ok "prints the VERIFIED verdict" || bad "no VERIFIED verdict in output"
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
[ "$(sha256_of "$O1/live-only.sh")" = "$BEFORE_LIVE" ] && ok "live-only runtime file untouched" || bad "deploy overwrote or removed a non-harness file"
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
grep -q "30" <<< "$OUT" && bad "output leans on the pre-existing file count" || ok "output does not cite pre-existing file counts"

# ── 3. NOTHING COPIED — a source that ships no files ─────────────────────────────────────────────
say_case "3. source shipping zero files -> FAILURE (a deploy of nothing is not a success)"
SRC3="$T/src3"; O3="$T/o3"; mkdir -p "$SRC3"; make_target "$O3" 5
BEFORE="$(snapshot "$O3")"
notify_reset; deploy "$SRC3" "$O3"
[ "$RC" -ne 0 ] && ok "empty source -> non-zero exit ($RC)" || bad "empty source exited 0"
# ⛔ The EXIT CODE, not just "non-zero": without this the later internal-invariant fallback (exit 1)
# satisfied the case, so the zero-file REFUSAL — and its "refused before touching the target"
# contract — was never actually pinned. Deleting the N==0 block left the suite green.
[ "$RC" = "78" ] && ok "exit 78 (the zero-file refusal, not a later invariant fallback)" || bad "exit $RC, expected 78 (refused before touching anything)"
grep -qi "ships ZERO files" <<< "$OUT" && ok "the refusal names zero shipped files (indicator (b))" || bad "refused for some other reason: $OUT"
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
# ⛔ AND ZERO WRITTEN IS NOT "PARTIAL". The message above is right for a partial copy; asserting it
# unconditionally told an operator their runtime was PARTIAL when nothing had been written at all,
# which invites a restore/re-kill of a box that is exactly as it was. Branch on the count.
if [ "$(id -u)" = "0" ]; then
  echo "  (zero-written sub-case skipped — running as root, where a 0555 target is still writable)"
else
  SRC5b="$T/src5b"; O5b="$T/o5b"; make_src "$SRC5b"; make_target "$O5b" 2
  chmod 555 "$O5b"                     # every copy fails, nothing can be written
  notify_reset; deploy "$SRC5b" "$O5b"
  chmod 755 "$O5b"
  [ "$RC" = "1" ] && ok "nothing writable -> exit 1 (a copy failure, not a refusal)" || bad "exit $RC, expected 1"
  grep -qi "NOTHING was written" <<< "$(notify_last)" && ok "0 copied says NOTHING was written" || bad "a zero-file copy did not say nothing was written: $(notify_last)"
  grep -qi "PARTIAL" <<< "$(notify_last)" && bad "a zero-file copy claimed the runtime is PARTIAL (it is untouched)" || ok "does not claim PARTIAL when nothing was written"
  grep -qi "unchanged" <<< "$(notify_last)" && ok "says the runtime is unchanged" || bad "does not say the runtime was left as it was: $(notify_last)"
fi

# ── 6. A COPY THAT SILENTLY DOES NOT MATCH — the verification gate is load-bearing ───────────────
say_case "6. copy reports success but bytes differ -> FAILURE (verification, not the copy, decides)"
SRC6="$T/src6"; O6="$T/o6"; make_src "$SRC6"; make_target "$O6"
# ⛔ THE REAL DEFECT SHAPE: `cp` exits 0 and the bytes at the target are NOT the source's. A `cmp`
# shim was NOT enough — it exits on the argument text, so `cmp a b` and `cmp b b` both matched and a
# verify loop comparing the TARGET WITH ITSELF (a tautology: `cmp -s "$O/$rel" "$O/$rel"`) still
# passed this case, i.e. the half the PR exists to add could have been entirely decorative. Corrupting
# the copy instead makes the assertion direction-sensitive by construction.
mkdir -p "$T/cpbin"
cat > "$T/cpbin/cp" <<SH
#!/usr/bin/env bash
"$REAL_CP" "\$@" || exit \$?
# append a byte to exactly one destination, reporting success — the silent-drift case
for a in "\$@"; do
  case "\$a" in *.deploy.*) case "\$a" in *claims.sh*) printf 'CORRUPTED\n' >> "\$a" ;; esac ;; esac
done
exit 0
SH
chmod +x "$T/cpbin/cp"
notify_reset
OUT="$(PATH="$T/cpbin:$PATH" bash "$DEPLOY" --src "$SRC6" --o "$O6" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "unverified bytes -> non-zero exit ($RC)" || bad "unverified bytes exited 0"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
notify_success && bad "unverified bytes notified SUCCESS" || ok "no success notification"
grep -q "DRIFT	claims.sh" "$O6/.deploy-ledger.tsv" 2>/dev/null && ok "ledger records the drift" || bad "ledger does not record the drift"
grep -qi "verification failed" <<< "$OUT" && ok "reports a VERIFICATION failure (distinct from a copy failure)" || bad "does not report a verification failure: $OUT"
# and the comparison's DIRECTION is pinned structurally, so the tautology above cannot come back quietly
DEPLOY_CODE0="$(grep -v '^[[:space:]]*#' "$DEPLOY" || true)"
grep -q 'cmp -s "\$SRC/\$rel" "\$O/\$rel"' <<< "$DEPLOY_CODE0" && ok "verification compares SOURCE against target (not target against itself)" || bad "the compare is not source->target — a self-comparison cannot fail"

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
# ⛔ AND it must fail in the COPY phase, not be caught later by `cmp` on a directory: the assertions
# above were satisfied by the verify half alone, so deleting the shape guard left the suite green.
grep -q "COPY-FAIL	claims.sh" "$O8/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger names the COPY-FAIL (the guard fired, not the verify half)" || bad "no COPY-FAIL entry — the shape guard is not load-bearing"

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
# The helper's non-comment lines are CAPTURED once and tested in the shell: a non-quiet grep piped
# into `grep -q` is the #841/#864 SIGPIPE false-negative (the quiet grep exits early, the producer
# dies of SIGPIPE, and under `pipefail` the assertion reports the wrong cause).
DEPLOY_CODE="$(grep -v '^[[:space:]]*#' "$DEPLOY" || true)"
grep -q 'ls "\$O"' <<< "$DEPLOY_CODE" && bad "the helper counts files from the target (self-confirming evidence)" || ok "the helper never counts files from the target"
grep -q 'cp -R' <<< "$DEPLOY_CODE" && bad "the helper still uses a bare recursive cp" || ok "no bare recursive copy"

# ── 12. A TRUNCATED INVENTORY — the walk's status must be READ, not discarded ─────────────────────
say_case "12. an unsearchable source SUBDIRECTORY -> FAILURE (a partial inventory is not a deploy)"
# ⛔ This was a second measured false PASS of the same #2041 class: the inventory was built inside a
# PROCESS SUBSTITUTION, whose exit status bash never waits for, so `find` exiting 1 ("Permission
# denied") yielded a TRUNCATED file list, every term of the verdict then agreed with itself, and the
# run printed `VERIFIED — 2/2` + exit 0 while the source's own `gh-limit.py` was never deployed.
if [ "$(id -u)" = "0" ]; then
  echo "  (skipped — running as root, where chmod 000 is still searchable)"
else
  SRC12="$T/src12"; O12="$T/o12"; make_src "$SRC12"; make_target "$O12"
  # ⛔ `retired/`, deliberately a NON-anchor subtree: chmod-ing `gh-limit` here made the anchor check
  # (which stats the real path) refuse first, so the case passed against a helper whose inventory was
  # still truncated — the assertion would have been satisfied by a different guard.
  chmod 000 "$SRC12/retired"           # a DIRECTORY, not a file: case 7 is the unreadable-FILE shape
  notify_reset; deploy "$SRC12" "$O12"
  chmod 755 "$SRC12/retired"
  [ "$RC" = "78" ] && ok "unsearchable subdirectory -> exit 78 (refused, nothing written)" || bad "exit $RC, expected 78 — a truncated inventory was deployed as if complete"
  notify_success && bad "a truncated inventory notified SUCCESS — the #2041 false PASS, one mechanism over" || ok "no success notification"
  notify_failure && ok "failure notification emitted" || bad "no failure notification"
  [ -e "$O12/gh-limit/gh" ] && bad "a partial deploy still wrote files" || ok "nothing was written by the refusal"
fi

# ── 13. A STALE BUT REAL HARNESS — the anchors must cover the files #2041 measured missing ────────
say_case "13. a source with the two old anchors but no gh-limit.py/gh-rest/gh/gh-limit/gh -> REFUSED"
# `orch-loop.sh` and `claims.sh` exist in every checkout back to 2026-10-13; the three files whose
# absence #2041 measured landed 2026-10-17/18. A two-anchor test therefore CERTIFIED a days-stale
# checkout that shipped none of them — the identical measured consequence, reached through a source
# that is days old instead of 1274 commits old. Nothing else in the fleet catches it:
# check-deployed-drift.sh compares depth-1 `*.sh` only, and install.sh:770 excludes `gh-rest/gh` from
# the payload fold by name.
SRC13="$T/src13"; O13="$T/o13"; make_target "$O13"
mkdir -p "$SRC13"; printf '#!/bin/bash\n' > "$SRC13/orch-loop.sh"; printf '#!/bin/bash\n' > "$SRC13/claims.sh"
notify_reset; deploy "$SRC13" "$O13"
[ "$RC" = "78" ] && ok "old-but-real harness -> exit 78 (refused)" || bad "exit $RC, expected 78 — a checkout missing gh-limit.py was certified"
notify_success && bad "a harness missing gh-limit.py notified SUCCESS" || ok "no success notification"
grep -qi "gh-limit.py" <<< "$(notify_last)" && ok "the notification names the missing anchor" || bad "notification does not name the cause: $(notify_last)"

# ── 14. A SYMLINK THE SOURCE SHIPS — refused, never silently omitted ──────────────────────────────
say_case "14. a symlink in the source -> REFUSAL (find -type f cannot see it; cp -R used to carry it)"
SRC14="$T/src14"; O14="$T/o14"; make_src "$SRC14"; make_target "$O14"
ln -s gh-limit.py "$SRC14/gh-shim"        # the shape a future `gh-*/gh` fallback would ship as
notify_reset; deploy "$SRC14" "$O14"
[ "$RC" = "78" ] && ok "source symlink -> exit 78 (refused, nothing written)" || bad "exit $RC, expected 78 — a symlink was silently left behind"
notify_success && bad "a source with an undeployable symlink notified SUCCESS" || ok "no success notification"
[ -e "$O14/gh-shim" ] && bad "the refusal still wrote to the target" || ok "nothing was written by the refusal"

# ── 15. A SELF-DEPLOY — every file would compare with itself ─────────────────────────────────────
say_case "15. --src == --o is refused (a self-comparison cannot fail, and the ledger would land in the source)"
SRC15="$T/src15"; make_src "$SRC15"
notify_reset; deploy "$SRC15" "$SRC15"
[ "$RC" = "78" ] && ok "source == target -> exit 78 (refused)" || bad "exit $RC, expected 78 — a tautological VERIFIED was printed"
notify_success && bad "a self-deploy notified SUCCESS" || ok "no success notification"
[ -e "$SRC15/.deploy-ledger.tsv" ] && bad "the refusal wrote a ledger INTO the source tree" || ok "no deploy artefact left in the source"
# a target nested inside the source is the same defect with a longer path
notify_reset; deploy "$SRC15" "$SRC15/nested"
[ "$RC" = "78" ] && ok "target nested inside the source -> exit 78" || bad "nested overlap exited $RC, expected 78"

# ── 16. THE DOCUMENTED CALL SHAPE — `--repo`, and the notifier default ───────────────────────────
say_case "16. --repo derivation + \$O/bg/notify.sh default + env O are the shape the caller actually uses"
# The documented invocation is `--repo <checkout> --o <runtime>` with NO `--notify`; every other case
# here passes `--src` and `--notify` explicitly, so neither the derivation nor the notifier default
# — the block whose own comment says the ordering "is the whole point" — was exercised at all.
CO16="$T/co16"; O16="$T/o16"; mkdir -p "$CO16/scripts"; mk_src16="$CO16/scripts/orchestrator-harness"
make_src "$mk_src16"; make_target "$O16"; mkdir -p "$O16/bg"
cp "$NOTIFY" "$O16/bg/notify.sh"
notify_reset
OUT="$(bash "$DEPLOY" --repo "$CO16" --o "$O16" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--repo resolves the source and deploys (exit 0)" || bad "--repo invocation exited $RC: $OUT"
notify_success && ok "the \$O/bg/notify.sh default fired the success notification" || ok "notification default: $(notify_last)"
notify_success && ok "notifier default resolved before the preflight" || bad "the default notifier was never resolved (got: $(notify_last))"
# and an absent source through the SAME default must notify FAILURE, not fall silent
notify_reset
OUT="$(bash "$DEPLOY" --src "$T/absent16" --o "$O16" 2>&1)"; RC=$?
[ "$RC" = "78" ] && ok "absent source via the default notifier -> exit 78" || bad "exit $RC, expected 78"
notify_failure && ok "the default notifier reported the refusal (indicator (a) of #2041)" || bad "a refusal reached nobody: $(notify_last)"
# env `O` is honoured (the #1745-class false PASS: an explicit `O=<dir>` used to address $HOME/orchestrator)
notify_reset
OUT="$(O="$O16" bash "$DEPLOY" --src "$SRC1" --no-notify 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "env O=<dir> is honoured without --o" || bad "env O exited $RC: $OUT"

# ── 17. TWO SHAPES THAT MUST NOT WRITE OUTSIDE THE TARGET, OR LIE ABOUT EVIDENCE ────────────────
say_case "17. a symlink at the destination, and a directory at the ledger path"
SRC17="$T/src17"; O17="$T/o17"; EL="$T/elsewhere17"; make_src "$SRC17"; make_target "$O17"
mkdir -p "$EL"
rm -f "$O17/claims.sh"; ln -s "$EL" "$O17/claims.sh"   # a shipped name that is a link into another dir
notify_reset; deploy "$SRC17" "$O17"
[ "$RC" -ne 0 ] && ok "destination symlink -> non-zero exit ($RC)" || bad "destination symlink exited 0"
notify_success && bad "a symlink destination notified SUCCESS" || ok "no success notification"
[ -z "$(ls -A "$EL" 2>/dev/null)" ] && ok "nothing was written through the link, outside the target" || bad "the deploy wrote $(ls -A "$EL") OUTSIDE the target"
grep -q "COPY-FAIL	claims.sh	(target path is a SYMLINK" "$O17/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger names the SYMLINK shape (not merely \"is a directory\")" || bad "the symlink guard did not fire (masked by the directory guard?)"
# a DIRECTORY at the ledger path: `mv` would move the temp INSIDE it and report success silently
SRC17b="$T/src17b"; O17b="$T/o17b"; make_src "$SRC17b"; make_target "$O17b"; mkdir -p "$O17b/.deploy-ledger.tsv"
notify_reset; deploy "$SRC17b" "$O17b"
[ "$RC" -eq 0 ] && ok "bytes are still verified when only the ledger cannot be installed" || bad "ledger shape changed the deploy verdict (exit $RC)"
grep -qi "ledger NOT installed" <<< "$OUT" && ok "says the ledger could NOT be installed" || bad "silently moved the temp file into the ledger directory"
grep -qi "ledger could NOT be written" <<< "$OUT" && ok "the verdict names the missing evidence instead of pointing at it" || bad "VERIFIED still points at a ledger that does not exist"

# ── 18. THE EXECUTABLE BIT IS ASSERTED, NOT INHERITED FROM `cp -p` ───────────────────────────────
say_case "18. a copy that drops the mode is repaired (a 0644 merge-one.sh is a loop that cannot spawn)"
# Without this case the block above was unfalsifiable: `cp -p` carried the mode, so deleting the
# helper's own chmod left every assertion green — the comment credited code that was not load-bearing.
SRC18="$T/src18"; O18="$T/o18"; make_src "$SRC18"; make_target "$O18"
mkdir -p "$T/cpbin18"
cat > "$T/cpbin18/cp" <<'SH'
#!/usr/bin/env bash
# a cp that ignores -p, the platform whose mode preservation we must not trust. NOTE the QUOTED
# heredoc delimiter: backticks in an unquoted heredoc BODY are command substitution, and the word
# `cp` in a comment ran the real cp with no operands on the first attempt.
args=(); for a in "$@"; do [ "$a" = "-p" ] || args+=("$a"); done
"${REAL_CP:?}" "${args[@]}" || exit $?
# ⛔ cp WITHOUT -p still lands the source's mode minus umask, so a mode-dropping shim has to drop it
# explicitly — otherwise the helper's own chmod +x was never load-bearing and the case proved nothing.
for a in "${args[@]}"; do
  case "$a" in *.deploy.*) chmod 644 "$a" 2>/dev/null || true ;; esac
done
exit 0
SH
chmod +x "$T/cpbin18/cp"
notify_reset
OUT="$(REAL_CP="$REAL_CP" PATH="$T/cpbin18:$PATH" bash "$DEPLOY" --src "$SRC18" --o "$O18" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "deploy without -p still verifies (exit 0)" || bad "deploy without -p exited $RC: $OUT"
[ -x "$O18/merge-one.sh" ] && ok "the helper RESTORED the executable bit itself" || bad "the executable bit was lost (only cp -p was carrying it)"

# ── 19. THE IDENTITY RECORD — a redeploy must not make the drift gate cry "hand edit" ────────────
say_case "19. a stale .agent-infra-stamp.json is NAMED in the verdict, not hidden"
# install.sh folds $O/*.sh into `payloadSha256`; check-deployed-drift.sh reports a mismatch as its
# top-severity "post-install hand edit". Nothing re-stamped after a redeploy, so every legitimate
# deploy produced that alarm and it stopped meaning anything.
SRC19="$T/src19"; O19="$T/o19"; make_src "$SRC19"; make_target "$O19"
printf '{"payloadSha256":"deadbeefdeadbeef"}\n' > "$O19/.agent-infra-stamp.json"
notify_reset; deploy "$SRC19" "$O19"
[ "$RC" -eq 0 ] && ok "the bytes still verify (the stamp is not the deploy's evidence)" || bad "a stale stamp failed the deploy (exit $RC)"
grep -qi "identity record STALE" <<< "$OUT" && ok "the verdict names the stale identity record" || bad "silently left a stale payloadSha256 behind"
grep -qi "STALE" <<< "$(notify_last)" && ok "the notification names it too (a caller reads only that)" || bad "the notification reads as fully current: $(notify_last)"
grep -q "STALE-STAMP" "$O19/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger records the stale stamp" || bad "the ledger does not record the stale stamp"
# and a matching stamp is NOT reported (no false alarm on a fresh install's own record)
STAMP_LIVE="$( ( cd "$O19" && for f in *.sh; do [ -f "$f" ] || continue; $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
printf '{"payloadSha256":"%s"}\n' "$STAMP_LIVE" > "$O19/.agent-infra-stamp.json"
notify_reset; deploy "$SRC19" "$O19"
grep -qi "identity record STALE" <<< "$OUT" && bad "a CURRENT stamp was reported as stale (false alarm)" || ok "a current identity record is not flagged"

echo
echo "════════════════════════════════════════"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: CLEAN"; exit 0; }
echo "RESULT: $FAIL FAILURE(S)"
exit 1
