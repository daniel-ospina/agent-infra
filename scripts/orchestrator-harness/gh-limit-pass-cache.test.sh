#!/usr/bin/env bash
# gh-limit-pass-cache.test.sh — the PASS-SCOPED read memo in gh-limit.py (agent-infra#1984 cause 1).
#
# WHAT IT IS. A refresh pass runs the collision pre-flight once per candidate, and three of the five
# calls each candidate makes are fleet-wide constants (identity, the open-PR list, the recently-closed
# PR sample). Measured: 72 of a 24-candidate pass's 134 core requests were those three answers asked
# 24 times. The memo replays the WHOLE INVOCATION — argv in, exact (stdout, stderr, rc) out — for the
# life of one pass, so there is no gh semantics to re-create.
#
# WHAT THIS SUITE PINS — every one of these is a way the feature could be WRONG rather than off:
#   * inert unless the caller asks (an un-asked-for cache is a surprise, not a saving);
#   * the replayed bytes are the child's bytes, on BOTH streams, and the rc agrees;
#   * a FAILURE is never memoised (a pinned error turns one transient fault into a pass-long
#     "unreadable" that this layer manufactured);
#   * `/rate_limit` is never memoised — it is the pass's own budget METER, and a frozen meter hides
#     exactly the exhaustion the pacing gate exists to see;
#   * `auth token` is never memoised — its stdout is the credential, and the memo is a FILE ON DISK;
#   * a mutation is never memoised (replaying its output would report work it did not do);
#   * the working directory is part of the key (the same argv in two checkouts is two questions);
#   * a corrupt entry is a MISS, never an error, and a vanished directory never fails a call.
#
# No network, no credentials, no real gh. Run: bash scripts/orchestrator-harness/gh-limit-pass-cache.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/gh-limit.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
echo "==> gh-limit pass cache ($HERE)"
T="$(mktemp -d "${TMPDIR:-/tmp}/gh-pass-cache.XXXXXX")"
trap 'rm -rf "$T"' EXIT
[ -f "$HELPER" ] || { echo "  FAIL missing $HELPER"; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$HELPER" \
  || { echo "  FAIL $HELPER does not parse"; exit 1; }

STUB="$T/gh"; LOG="$T/stub.log"; CACHE="$T/cache"; STATE="$T/state"
: > "$LOG"
> "$STUB" cat <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_TEST_LOG"
case "$*" in
  *boom*)  printf 'the api refused\n' >&2; exit 7 ;;
  *token*) printf 'gho_SECRET_MUST_NOT_BE_STORED\n'; exit 0 ;;
  *stderr*) printf 'OUT-BODY\n'; printf 'ERR-BODY\n' >&2; exit 0 ;;
  *)       printf 'BODY:%s\n' "$*" ;;
esac
SH
chmod +x "$STUB"

# ghx <cache-dir|""> [cwd] -- <argv…> ; $OUT (stdout) / $ERR (stderr) / $RC
OUT=""; ERR=""; RC=0
ghx() {
  local cache="$1" cwd="$2"; shift 3 2>/dev/null || shift 2
  local envs=(GH_LIMIT_DIR="$STATE" GH_TEST_LOG="$LOG")
  [ -n "$cache" ] && envs+=(GH_LIMIT_PASS_CACHE="$cache")
  OUT="$( cd "${cwd:-$T}" && env "${envs[@]}" python3 "$HELPER" --real-gh "$STUB" -- "$@" 2>"$T/.err" )"
  RC=$?
  ERR="$(cat "$T/.err")"
}
stub_calls() { wc -l < "$LOG" | tr -d ' '; }
reset_log() { : > "$LOG"; }

# ── 1) OFF BY DEFAULT ───────────────────────────────────────────────────────────────────────────
reset_log
ghx "" "" -- api repos/o/r/pulls
ghx "" "" -- api repos/o/r/pulls
[ "$(stub_calls)" = "2" ] && ok "off: with GH_LIMIT_PASS_CACHE unset, two identical calls make two requests" \
                          || bad "off: a cached answer was served with the feature OFF ($(stub_calls) requests, want 2)"

# ── 2) ON: THE SECOND CALL IS SERVED FROM THE MEMO, BYTE FOR BYTE ──────────────────────────────
reset_log; rm -rf "$CACHE"
ghx "$CACHE" "" -- api repos/o/r/pulls
first_out="$OUT"; first_rc="$RC"
ghx "$CACHE" "" -- api repos/o/r/pulls
[ "$(stub_calls)" = "1" ] && ok "on: the second identical call issued NO request (1 for 2 calls)" \
                          || bad "on: the memo did not engage ($(stub_calls) requests for 2 identical calls)"
[ "$OUT" = "$first_out" ] && ok "on: the replayed stdout is byte-identical to the live answer" \
                          || bad "on: the replay changed the bytes (live '$first_out', replay '$OUT')"
[ "$RC" = "$first_rc" ] && ok "on: the replayed exit status matches ($RC)" \
                        || bad "on: the replay returned rc=$RC, the live call returned $first_rc"

# ── 3) BOTH STREAMS, SEPARATELY ────────────────────────────────────────────────────────────────
reset_log; rm -rf "$CACHE"
ghx "$CACHE" "" -- api repos/o/r/stderr
live_out="$OUT"; live_err="$ERR"
ghx "$CACHE" "" -- api repos/o/r/stderr
[ "$OUT" = "$live_out" ] && [ "$ERR" = "$live_err" ] \
  && ok "streams: stdout and stderr are replayed SEPARATELY and unchanged (not merged)" \
  || bad "streams: the replay merged or altered the streams (out '$OUT' err '$ERR')"

# ── 4) A FAILURE IS NEVER MEMOISED ─────────────────────────────────────────────────────────────
reset_log; rm -rf "$CACHE"
ghx "$CACHE" "" -- api repos/o/r/boom
rc1="$RC"
ghx "$CACHE" "" -- api repos/o/r/boom
[ "$(stub_calls)" = "2" ] && ok "failure: a non-zero call is re-attempted, not replayed (2 requests for 2 calls)" \
                          || bad "failure: a FAILED call was memoised — one transient fault would read as 'unreadable' for the whole pass"
[ "$rc1" != "0" ] && ok "failure: the failure's status is passed through unchanged (rc=$rc1)" \
                  || bad "failure: the fixture did not fail, so the check above is vacuous"

# A STORED failure must not be replayed either — the read path refuses one on its own, so a
# hand-edited / foreign / older-format entry cannot become a pinned "unreadable" answer.
reset_log; rm -rf "$CACHE"; mkdir -p "$CACHE"
ghx "$CACHE" "" -- api repos/o/r/pulls
for f in "$CACHE"/*.json; do
  [ -e "$f" ] || continue
  python3 - "$f" <<'PYR'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["rc"] = 7
json.dump(d, open(p, "w"))
PYR
done
ghx "$CACHE" "" -- api repos/o/r/pulls
[ "$RC" -eq 0 ] && ok "failure: a STORED non-zero entry is not replayed (rc=0 on the live answer)" \
                || bad "failure: a stored rc=7 entry was replayed as the answer (rc=$RC) — a pinned failure"
# ── 5) THE BUDGET METER IS NEVER MEMOISED ──────────────────────────────────────────────────────
# The refresh's pacing gate re-reads `/rate_limit` before every candidate exactly to see what the
# last one cost. A frozen meter reports a budget that cannot move.
reset_log; rm -rf "$CACHE"
ghx "$CACHE" "" -- api rate_limit
ghx "$CACHE" "" -- api rate_limit
[ "$(stub_calls)" = "2" ] && ok "meter: /rate_limit is ALWAYS asked live (2 for 2 calls)" \
                          || bad "meter: /rate_limit was memoised — the pacing gate would read a budget that cannot move"

# ── 6) THE CREDENTIAL IS NEVER WRITTEN TO DISK ───────────────────────────────────────────────
reset_log; rm -rf "$CACHE"; mkdir -p "$CACHE"
ghx "$CACHE" "" -- auth token
ghx "$CACHE" "" -- auth token
[ "$(stub_calls)" = "2" ] && ok "secret: 'gh auth token' is never memoised (2 for 2 calls)" \
                          || bad "secret: 'gh auth token' was memoised"
if grep -rq 'gho_SECRET_MUST_NOT_BE_STORED' "$CACHE" 2>/dev/null; then
  bad "secret: THE TOKEN IS ON DISK under the cache directory — this directory is inside the box's state dir"
else
  ok "secret: no credential reached the cache directory"
fi

# ── 7) A MUTATION IS NEVER MEMOISED ───────────────────────────────────────────────────────────
reset_log; rm -rf "$CACHE"
ghx "$CACHE" "" -- api -X POST repos/o/r/issues/1/comments -f body=hi
ghx "$CACHE" "" -- api -X POST repos/o/r/issues/1/comments -f body=hi
[ "$(stub_calls)" = "2" ] && ok "mutation: a POST is issued twice, never replayed" \
                          || bad "mutation: a MUTATING call was memoised — a replayed write reports work that did not happen"

# ── 8) THE WORKING DIRECTORY IS PART OF THE KEY ──────────────────────────────────────────────
# `gh pr list` without `--repo` resolves the repository from the cwd, so an identical argv in two
# checkouts is two different questions.
reset_log; rm -rf "$CACHE"; mkdir -p "$T/a" "$T/b"
ghx "$CACHE" "$T/a" -- pr list --state open
ghx "$CACHE" "$T/b" -- pr list --state open
[ "$(stub_calls)" = "2" ] && ok "cwd: the same argv from two checkouts makes two requests (no cross-repo replay)" \
                          || bad "cwd: two different checkouts shared one memo entry — a wrong-repo answer replayed at rc 0"

# ── 9) A CORRUPT ENTRY IS A MISS, AND A VANISHED DIRECTORY IS NOT FATAL ──────────────────────
reset_log; rm -rf "$CACHE"; mkdir -p "$CACHE"
ghx "$CACHE" "" -- api repos/o/r/pulls
for f in "$CACHE"/*.json; do [ -e "$f" ] && printf 'not json{' > "$f"; done          # corrupt it
ghx "$CACHE" "" -- api repos/o/r/pulls
[ "$RC" -eq 0 ] && ok "corrupt: a corrupt memo entry is a MISS, not a failure (rc=0)" \
                || bad "corrupt: a corrupt entry failed the call (rc=$RC, err: $ERR)"
rm -rf "$CACHE"                                                                       # vanish it
ghx "$CACHE" "" -- api repos/o/r/pulls
[ "$RC" -eq 0 ] && ok "corrupt: an unwritable/absent cache directory does not fail the call (rc=0)" \
                || bad "corrupt: a missing cache directory failed the call (rc=$RC, err: $ERR)"

echo
printf 'gh-limit pass cache: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
