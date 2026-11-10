#!/usr/bin/env bash
# scripts/ci-failure-set.truncated.test.sh — #3174: a TRUNCATED shard run must be reported UNPROVEN,
# never folded into main's baseline as a smaller failure set.
#
# WHY THIS IS THE HALF THAT MATTERS. The set of shards red on `main` is the REFERENCE SET every batch
# verdict subtracts (`batch_failures − main_failures`). `scripts/run-bash-shards.sh` was killed
# mid-run on main and printed no recap, so the reference set silently SHRANK as the job got slower —
# measured over three consecutive main runs: 13, then 11, then 10 failing shards, with nothing
# fixed in between. A shard genuinely red on main then drops out of the baseline, reappears as "a new
# failure caused by the batch", and gets a constituent dropped or reverted on a false signal.
#
# `run-bash-shards.sh` now prints `⚠️ RECAP INCOMPLETE (k/n shards ran)` when it is interrupted (its
# TERM/INT trap; pinned in `scripts/run-bash-shards.recap.test.sh`). THIS suite pins what the
# consumers do with it:
#
#   ARM 1 — THE PARSER (`scripts/ci_exemption.py`), the one module every consumer reads. On a capture
#     carrying the marker, both CLI doors (`ids`, `signatures`) must exit 4, print NO ids and say
#     UNPROVEN. A truncated list emitted as an answer IS the fold. A COMPLETE capture must still
#     yield its identity (else the refusal would be vacuous and disable every baseline).
#   ARM 2 — THE BASELINE (`scripts/ci-failure-set.sh --main-union-rates`) over a fake-`gh` window
#     holding one COMPLETE red run, one TRUNCATED red run and one green run must: build a table
#     (a single killed run must not make the reference uncomputable), EXCLUDE the truncated run's
#     shard, keep the denominator honest (`<id>\t1\t2` — the killed run is not counted as measured),
#     and say UNPROVEN. A window whose ONLY failing run is truncated is REFUSED (rc 1) instead of
#     published as an empty baseline, which would read as "nothing fails on main".
#   ARM 3 — THE PR DOOR (`--commit-rows --unattributed`): the excluded run must still be NAMED, or
#     `admin-merge.sh` §1c cross-checks its own count against a collector that deliberately published
#     nothing and blames the collector for a correct exclusion.
#
# Fixtures are mktemp trees outside the checkout; `CI_FAILURE_SET_GH` is the script's own seam for a
# fake `gh`. bash 3.2 compatible. Containment tests use here-strings, never `printf | grep -q`
# (scripts/check-no-sigpipe-grep.sh, #841).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT/scripts/ci_exemption.py"
COLLECTOR="$ROOT/scripts/ci-failure-set.sh"

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  ⏭  %s\n' "$1"; }

if [ ! -r "$PARSER" ] || [ ! -r "$COLLECTOR" ]; then
  echo "❌ ci-failure-set.truncated: cannot find the parser or the collector — refusing to report"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "⏭  ci-failure-set.truncated: python3 absent — the parser and the collector both need it; SKIPPING"
  printf 'PASS 0 · FAIL 0 · SKIP 1\n'
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/truncated-baseline.XXXXXX")" || {
  echo "❌ ci-failure-set.truncated: cannot create a temp dir — refusing to report"
  exit 2
}
trap 'rm -rf "$TMP"' EXIT

MARKER='⚠️ RECAP INCOMPLETE (1/3 shards ran)'

# ── the two captures ─────────────────────────────────────────────────────────────────────────────
# Real shape: a `<job>\t<step>\t<ts>Z ` prefix on every line, so the parser's own prefix stripping is
# exercised rather than assumed.
mk_capture() {  # <file> <content...>
  local file="$1"
  shift
  : >"$file"
  local n=0
  for line in "$@"; do
    n=$((n + 1))
    printf 'bash-suites (2)\tBash shards — the ONE list both lanes run (#1369)\t2026-10-31T17:57:1%s.1234567Z %s\n' "$n" "$line" >>"$file"
  done
}

mk_capture "$TMP/truncated.log" \
  '❌ FAILED SHARD: scripts/truncated-red.test.sh' \
  "$MARKER — scripts/run-bash-shards.sh was TERMINATED (TERM)" \
  '❌ 1 bash shard(s) had failed when this run was killed' \
  '❌ failing shard(s): scripts/truncated-red.test.sh'

mk_capture "$TMP/complete.log" \
  '❌ FAILED SHARD: scripts/measured-red.test.sh' \
  '❌ 1 bash shard(s) failed' \
  '❌ failing shard(s): scripts/measured-red.test.sh'

echo ""
echo "1. THE PARSER — a truncated capture is UNPROVEN, not a shorter failure set"
python3 "$PARSER" ids --log "$TMP/truncated.log" >"$TMP/ids.out" 2>"$TMP/ids.err"
IRC=$?
IDS="$(cat "$TMP/ids.out" 2>/dev/null)"
IERR="$(cat "$TMP/ids.err" 2>/dev/null)"
if [ "$IRC" -eq 4 ]; then
  ok "the ids door answers a TRUNCATED capture with exit 4 (the collector's 'truncated:' state), not 0"
else
  bad "the ids door exited $IRC on a truncated capture, expected 4 — a partial set would be subtracted as the baseline"
fi
if [ -z "$IDS" ]; then
  ok "it emits NO ids (a consumer that ignores the exit code cannot fold a partial set)"
else
  bad "it emitted ids for a truncated capture: $(tr '\n' '|' <<<"$IDS" | cut -c1-200)"
fi
if grep -q 'UNPROVEN' <<<"$IERR" && grep -q 'RECAP INCOMPLETE' <<<"$IERR"; then
  ok "it says UNPROVEN and quotes the marker it saw (the word the operator and the rail read)"
else
  bad "it did not say UNPROVEN/marker on stderr: $(tr '\n' '|' <<<"$IERR" | cut -c1-300)"
fi
python3 "$PARSER" signatures --log "$TMP/truncated.log" >"$TMP/sig.out" 2>"$TMP/sig.err"
SRC=$?
if [ "$SRC" -eq 4 ] && [ ! -s "$TMP/sig.out" ]; then
  ok "the signatures door refuses too (rc 4, empty table) — no second door publishes the truncated set"
else
  bad "the signatures door answered rc $SRC with $(sed -n '1,2p' "$TMP/sig.out" | tr '\n' '|')"
fi
python3 "$PARSER" ids --log "$TMP/complete.log" >"$TMP/ids2.out" 2>"$TMP/ids2.err"
ORC=$?
OIDS="$(cat "$TMP/ids2.out" 2>/dev/null)"
if [ "$ORC" -eq 0 ] && grep -q 'bash-shard::scripts/measured-red\.test\.sh' <<<"$OIDS"; then
  ok "a COMPLETE capture still yields its shard identity (rc 0) — the refusal is not vacuous"
else
  bad "a complete capture did not yield its identity (rc $ORC): $(tr '\n' '|' <<<"$OIDS" | cut -c1-300)"
fi

echo ""
echo "2. THE BASELINE — the truncated run is EXCLUDED and the exclusion is LOUD"
mkdir -p "$TMP/logs"
{
  printf 'completed\tfailure\taaaa111:1001\t11111\tCI\tpush\n'
  printf 'completed\tfailure\tbbbb222:1002\t11111\tCI\tpush\n'
  printf 'completed\tsuccess\tcccc333:1003\t11111\tCI\tpush\n'
} >"$TMP/listing"
cp "$TMP/complete.log" "$TMP/logs/1001.log"
cp "$TMP/truncated.log" "$TMP/logs/1002.log"
: >"$TMP/logs/1003.log"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$1" in\n'
  printf '  run) case "$2" in list) cat "$FAKE_GH_LISTING" ;; view) cat "$FAKE_GH_LOGS/$3.log" ;; *) exit 1 ;; esac ;;\n'
  printf '  api) printf "3\\n" ;;\n'
  printf '  *) exit 1 ;;\n'
  printf 'esac\n'
} >"$TMP/gh"
chmod +x "$TMP/gh"
FAKE_GH_LISTING="$TMP/listing"
FAKE_GH_LOGS="$TMP/logs"
export FAKE_GH_LISTING FAKE_GH_LOGS

CI_FAILURE_SET_GH="$TMP/gh" bash "$COLLECTOR" --main-union-rates 1 >"$TMP/rates.out" 2>"$TMP/rates.err"
RRC=$?
RERR="$(cat "$TMP/rates.err" 2>/dev/null)"
ROUT="$(cat "$TMP/rates.out" 2>/dev/null)"
if [ "$RRC" -eq 0 ]; then
  ok "the rate table builds from a window CONTAINING a truncated run (a killed run must not make the reference uncomputable)"
else
  bad "the rate table refused a window with one truncated run (rc $RRC): $(tr '\n' '|' <<<"$RERR" | cut -c1-400)"
fi
if grep -q 'UNPROVEN' <<<"$RERR"; then
  ok "…and it says UNPROVEN, naming how many runs were excluded (never a silent shrink)"
else
  bad "…and it did NOT say UNPROVEN about the excluded run: $(tr '\n' '|' <<<"$RERR" | cut -c1-400)"
fi
if grep -q '^bash-shard::scripts/measured-red\.test\.sh' <<<"$ROUT"; then
  ok "the COMPLETE red run's shard is in the baseline"
else
  bad "the complete red run's shard is MISSING from the baseline: $(tr '\n' '|' <<<"$ROUT" | cut -c1-300)"
fi
if grep -q 'truncated-red' <<<"$ROUT"; then
  bad "the TRUNCATED run's shard was FOLDED into the baseline — the exact fold #3174 fixes"
else
  ok "the TRUNCATED run's shard is NOT in the baseline (a partial set is never subtracted as a set)"
fi
want_row="$(printf 'bash-shard::scripts/measured-red.test.sh\t1\t2')"
got_row="$(grep -F 'bash-shard::scripts/measured-red.test.sh' <<<"$ROUT" | head -1)"
if [ "$got_row" = "$want_row" ]; then
  ok "the DENOMINATOR is honest: 1 failure over 2 fully-measured runs (the killed run is not counted as measured)"
else
  bad "the rate row is wrong — want '<id>	1	2' (1 failure / 2 measured runs), got: [$(tr '\n' '|' <<<"$got_row")]"
fi

# ALL failing runs truncated → the reference cannot be computed at all, and that must be a REFUSAL
# (an empty table would read as "nothing fails on main").
{
  printf 'completed\tfailure\tbbbb222:1002\t11111\tCI\tpush\n'
  printf 'completed\tsuccess\tcccc333:1003\t11111\tCI\tpush\n'
} >"$TMP/listing-trunc-only"
FAKE_GH_LISTING="$TMP/listing-trunc-only"
export FAKE_GH_LISTING
CI_FAILURE_SET_GH="$TMP/gh" bash "$COLLECTOR" --main-union-rates 1 --runs-report "$TMP/report2" \
  >"$TMP/rates2.out" 2>"$TMP/rates2.err"
R2RC=$?
R2ERR="$(cat "$TMP/rates2.err" 2>/dev/null)"
if [ "$R2RC" -ne 0 ] && grep -q 'UNPROVEN' <<<"$R2ERR"; then
  ok "a window whose ONLY failing run is truncated is REFUSED as UNPROVEN (rc $R2RC), not published as an empty baseline"
else
  bad "a window of only-truncated failing runs answered rc $R2RC: $(tr '\n' '|' <<<"$R2ERR" | cut -c1-400)"
fi
# ⛔ THE LABEL IS WHAT MAKES THE REFUSAL ACTIONABLE (review of this change, cycle 2, P2): without
# `unreadable=truncated:<run-id>` the rail's `case` falls into its "the run LISTING could not be read"
# arm — the opposite of what happened (the window WAS listed; its failing runs were killed).
if grep -q 'unreadable=truncated:1002' "$TMP/report2" 2>/dev/null; then
  ok "the refusal PUBLISHES its own state (unreadable=truncated:1002), so the rail names the right cause"
else
  bad "the refusal published no 'truncated:' label: report=[$(sed -n '1,8p' "$TMP/report2" 2>/dev/null | tr '\n' '|')]"
fi

echo ""
echo "3. THE PR DOOR — the excluded run is still NAMED for admin-merge's count"
FAKE_GH_LISTING="$TMP/listing"
export FAKE_GH_LISTING
CI_FAILURE_SET_GH="$TMP/gh" bash "$COLLECTOR" --commit-rows deadbeef \
  --unattributed "$TMP/unattr" >"$TMP/rows.out" 2>"$TMP/rows.err"
RRRC=$?
UNATTR_SHOWN=""
[ -s "$TMP/unattr" ] && UNATTR_SHOWN="$(sed -n '1,5p' "$TMP/unattr" | tr '\n' ' ')"
RERR2="$(sed -n '1,5p' "$TMP/rows.err" | tr '\n' '|')"
if [ "$RRRC" -eq 0 ] && grep -q '1002' "$TMP/unattr" 2>/dev/null; then
  ok "the PR door names the truncated run in --unattributed (so admin-merge's count and the collector agree)"
else
  bad "the PR door did not name the truncated run in --unattributed (rc $RRRC): unattributed=[$UNATTR_SHOWN] err=$(cut -c1-300 <<<"$RERR2")"
fi
if grep -q 'measured-red' "$TMP/rows.out" 2>/dev/null; then
  ok "…while the COMPLETE run's row is still published for the decision"
else
  bad "the complete run's row is missing from --commit-rows output: $(sed -n '1,3p' "$TMP/rows.out" | tr '\n' '|')"
fi

echo ""
printf 'PASS %d · FAIL %d · SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
