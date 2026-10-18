#!/usr/bin/env bash
# gh-serial.test.sh — hermetic tests for the single-flight + bounded-backoff gh layer (#1988).
#
# Every case drives a STUB gh (no network, no credentials) and asserts on what the layer DID:
#   * single flight          two concurrent callers never overlap; an unserialised CONTROL does
#                            overlap, so the measurement is proven able to see the defect;
#   * in-flight backoff      a 429 with `retry-after: 1` is retried after 1 s and then succeeds;
#                            a SECONDARY limit with no headers waits >= 60 s and doubles;
#   * a bounded end          the 4th refusal exits 75 with `RATE_LIMITED bucket=…` — never 0, never
#                            an empty result (the failure that made the fleet look idle);
#   * the documented order   `retry-after` -> reset when remaining is 0 -> >= 60 s exponential;
#   * mutative pacing        two mutating calls are >= 1 s apart;
#   * conditional REST       a 304 replays the cached body BYTE-EXACTLY and costs no quota;
#   * no false positive      a permission 403 is replayed once, not slept on and not retried;
#   * no silent substitution the engine missing is a LOUD 127, never a bare unserialised gh.
#
# The sleep schedule is asserted through GHS_SLEEP_CMD (a recorder that stands in for time.sleep)
# so the cases prove the DELAYS CHOSEN without waiting 420 s for them; the 1 s retry-after and the
# 1 s mutative spacing are real sleeps, because those are the documented numbers themselves.
# PRE-FIX CONTROLS: the single-flight, 429-retry and secondary-limit sections each carry one, driving
# the same stub the way the harness drove it before this change. The other sections (mutative
# spacing, 304 replay, permission 403, timeouts, missing engine) assert a behaviour a bare `gh` does
# not have at all — there is nothing to control against.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
ENGINE="$HERE/gh-serial/gh-serial"
LIB="$HERE/gh-serial/lib.sh"

pass=0; fail=0
ck() { # ck <description> <rc>
  if [ "${2:-1}" -eq 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi
}
note() { printf '       %s\n' "$*"; }

[ -x "$ENGINE" ] || { echo "FATAL: $ENGINE is missing or not executable"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-serial-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin"
unset GHS_GH GHS_BIN O 2>/dev/null || true

fresh_state() { # a per-case state dir: the mutative-spacing clock and last-limit never leak
  CASE_STATE="$TMP/state-$1"; rm -rf "$CASE_STATE"; mkdir -p "$CASE_STATE"
  export GHS_STATE_DIR="$CASE_STATE"
}

# Recorder that stands in for time.sleep, appending the requested delay to $SLEEPS.
cat > "$TMP/bin/record-sleep" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "${SLEEPS:?}"
SH
chmod +x "$TMP/bin/record-sleep"

echo "── single flight: one gh invocation at a time per machine ──"
cat > "$TMP/bin/slow-gh" <<'SH'
#!/bin/bash
# A gh that takes 0.4 s and logs its own start/end so overlap is MEASURED, not assumed.
ts() { python3 -c 'import time; print("%.6f" % time.time())'; }
printf 'S %s %s\n' "$(ts)" "$$" >> "${GH_LOG:?}"
sleep 0.4
printf 'E %s %s\n' "$(ts)" "$$" >> "${GH_LOG:?}"
echo "slow-ok"
SH
chmod +x "$TMP/bin/slow-gh"

max_inflight() { # <log> -> the largest number of overlapping [S,E] intervals
  python3 - "$1" <<'PY'
import sys
starts, ends, events = {}, {}, []
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) == 3 and parts[0] in ("S", "E"):
        (starts if parts[0] == "S" else ends)[parts[2]] = float(parts[1])
for pid, t in starts.items():
    events.append((t, 1))
    events.append((ends.get(pid, float("inf")), -1))
events.sort()
cur = peak = 0
for _, delta in events:
    cur += delta
    peak = max(peak, cur)
print(peak)
PY
}

fresh_state concurrent
export GH_LOG="$TMP/concurrent.log"; : > "$GH_LOG"
export GHS_GH="$TMP/bin/slow-gh" GHS_BIN="$ENGINE"
( : > "$TMP/c1.out"; "$ENGINE" run -- api x >"$TMP/c1.out" 2>"$TMP/c1.err"; echo $? > "$TMP/c1.rc" ) &
( : > "$TMP/c2.out"; "$ENGINE" run -- api x >"$TMP/c2.out" 2>"$TMP/c2.err"; echo $? > "$TMP/c2.rc" ) &
wait
peak="$(max_inflight "$GH_LOG")"
[ "$peak" = "1" ] && rc=0 || rc=1
ck "two concurrent ghs calls never overlap (measured max in flight = $peak)" $rc
[ "$(cat "$TMP/c1.rc")" = "0" ] && [ "$(cat "$TMP/c2.rc")" = "0" ] && rc=0 || rc=1
ck "both serialised callers still succeed (rc=0, rc=$(cat "$TMP/c1.rc")/$(cat "$TMP/c2.rc"))" $rc
[ "$(grep -c '^slow-ok$' "$TMP/c1.out")" = "1" ] && rc=0 || rc=1
ck "the layer is transparent: gh's own stdout reaches the caller" $rc

# CONTROL — the same stub called directly, unserialised. If this did NOT overlap, the case above
# would prove nothing about the lock. This is also the PRE-FIX behaviour: a bare gh call has no
# queue, so the concurrency GitHub documents as the secondary-limit trigger is present.
export GH_LOG="$TMP/control.log"; : > "$GH_LOG"
"$TMP/bin/slow-gh" api x >/dev/null & "$TMP/bin/slow-gh" api x >/dev/null &
wait
peak="$(max_inflight "$GH_LOG")"
[ "$peak" -ge 2 ] && rc=0 || rc=1
ck "CONTROL: the same two calls WITHOUT the layer DO overlap (max in flight = $peak) — pre-fix shape" $rc
unset GHS_GH

echo "── a 429 with retry-after: 1 is retried, then succeeds ──"
fresh_state retry
cat > "$TMP/bin/legacy-retry-gh" <<'SH'
#!/bin/bash
n=0; [ -f "$CNT" ] && n="$(cat "$CNT")"; n=$((n + 1)); printf '%s' "$n" > "$CNT"
if [ "$n" -eq 1 ]; then
  printf 'HTTP/2.0 429 Too Many Requests\r\nRetry-After: 1\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: %s\r\n\r\n{"message":"You have exceeded a secondary rate limit."}\n' \
    "$(python3 -c 'import time; print(int(time.time()) + 1)')"
  exit 1
fi
printf 'HTTP/2.0 200 OK\r\nX-RateLimit-Remaining: 4998\r\n\r\n{"number":42}\n'
exit 0
SH
chmod +x "$TMP/bin/legacy-retry-gh"
export CNT="$TMP/retry.count" SLEEPS="$TMP/retry.sleeps"; : > "$SLEEPS"
GHS_GH="$TMP/bin/legacy-retry-gh" GHS_SLEEP_CMD="$TMP/bin/record-sleep" GHS_JITTER=0 \
  "$ENGINE" run -- api -i repos/o/r/pulls/1 >"$TMP/retry.out" 2>"$TMP/retry.err"
rc=$?
[ "$rc" -eq 0 ] && rc=0 || { rc=1; note "rc=$rc stderr: $(cat "$TMP/retry.err")"; }
ck "a 429 is retried and the call SUCCEEDS (rc=0)" $rc
grep -q '"number":42' "$TMP/retry.out" && rc=0 || rc=1
ck "the retried call returns the real payload, not the 429 body" $rc
[ "$(cat "$CNT")" = "2" ] && rc=0 || rc=1
ck "exactly two invocations (one retry) — recorded $(cat "$CNT")" $rc
waited="$(head -1 "$SLEEPS" 2>/dev/null || true)"
python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - 1.0) < 0.05 else 1)' "${waited:-0}" 2>/dev/null
ck "retry-after: 1 was honoured (waited ${waited:-none}s)" $?

# PRE-FIX CONTROL — the same 429 driven the way the harness drove it before this change (a bare gh
# call, no layer). This is the state the fix exists to change: ONE attempt, rc 1, no retry, and the
# 429 body handed back to a caller that reads it as data.
printf '0' > "$TMP/legacy.count"
CNT="$TMP/legacy.count" "$TMP/bin/legacy-retry-gh" api -i repos/o/r/pulls/1 >"$TMP/legacy.out" 2>/dev/null
legacy_rc=$?
[ "$legacy_rc" -eq 1 ] && [ "$(cat "$TMP/legacy.count")" = "1" ] && rc=0 || rc=1
ck "CONTROL: before the fix the same 429 fails once (rc=$legacy_rc, attempts=$(cat "$TMP/legacy.count")) — the case above is what the layer adds" $rc

echo "── a secondary limit with NO headers: >= 60 s, doubling, then a LOUD bounded failure ──"
fresh_state secondary
cat > "$TMP/bin/secondary-gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${ARGS:?}"
if [ "$1" = "api" ] && [ "$2" = "rate_limit" ]; then
  python3 -c 'import json,time; print(json.dumps({"resources":{"core":{"remaining":2948,"reset":int(time.time())+3000},"graphql":{"remaining":0,"reset":int(time.time())+120}}}))'
  exit 0
fi
printf 'GraphQL: API rate limit already exceeded for user ID 81560491.\n' >&2
exit 1
SH
chmod +x "$TMP/bin/secondary-gh"
export ARGS="$TMP/secondary.args" SLEEPS="$TMP/secondary.sleeps"; : > "$SLEEPS"; : > "$ARGS"
GHS_GH="$TMP/bin/secondary-gh" GHS_SLEEP_CMD="$TMP/bin/record-sleep" GHS_JITTER=0 \
  "$ENGINE" run -- pr list --repo o/r --state open >"$TMP/sec.out" 2>"$TMP/sec.err"
rc=$?
[ "$rc" -eq 75 ] && rc=0 || { rc=1; note "rc=$rc (want 75) stderr: $(cat "$TMP/sec.err")"; }
ck "an exhausted retry budget exits 75, not 0" $rc
[ -s "$TMP/sec.out" ] && rc=1 || rc=0
ck "it does NOT print an empty result on stdout (the 'looks idle' failure)" $rc
grep -q 'RATE_LIMITED bucket=graphql' "$TMP/sec.err" && rc=0 || rc=1
ck "the failure NAMES the bucket (graphql) and is greppable" $rc
grep -q 'NOT EMPTY DATA' "$TMP/sec.err" && rc=0 || rc=1
ck "the failure says in words that this is not empty data" $rc
set -- $(cat "$SLEEPS" 2>/dev/null | tr '\n' ' ')
[ "$#" -eq 3 ] && rc=0 || { rc=1; note "waits recorded: ${*:-none} (want 3)"; }
ck "three waits for four attempts (bounded, never infinite)" $rc
first="${1:-0}"; second="${2:-0}"; third="${3:-0}"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 60.0 else 1)' "$first"
ck "the first wait is >= 60 s (got ${first}s) — GitHub's documented floor" $?
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) >= 2*float(sys.argv[1])*0.9 else 1)' "$first" "$second"
ck "the wait DOUBLES (${first}s -> ${second}s)" $?
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) >= 2*float(sys.argv[1])*0.9 else 1)' "$second" "$third"
ck "and doubles again (${second}s -> ${third}s)" $?
[ "$(grep -c 'rate_limit' "$ARGS")" -ge 1 ] && rc=0 || rc=1
ck "the bucket/reset was corroborated by /rate_limit, not guessed" $rc
grep -q 'bucket=graphql' "$CASE_STATE/last-limit" 2>/dev/null && rc=0 || rc=1
ck "the limited cycle is recorded in last-limit for the heartbeat to name" $rc

# PRE-FIX CONTROL — the measured shape driven with a bare gh call: rc 1, EMPTY stdout, and no
# distinguishable named error. A caller in the harness reads that as "no rows" (this is exactly
# `[scope] open=UNKNOWN` / `queue=UNREADABLE`). The case above is what makes it impossible.
ARGS="$TMP/legacy-secondary.args"; : > "$ARGS"
"$TMP/bin/secondary-gh" pr list --repo o/r --state open >"$TMP/legacy-sec.out" 2>/dev/null
legacy_rc=$?
[ "$legacy_rc" -eq 1 ] && [ ! -s "$TMP/legacy-sec.out" ] && rc=0 || rc=1
ck "CONTROL: before the fix the same refusal exits 1 with EMPTY stdout (indistinguishable from 'no rows')" $rc
grep -q 'RATE_LIMITED' "$TMP/legacy-sec.out" 2>/dev/null && rc=1 || rc=0
ck "CONTROL: and nothing names the bucket, so the cycle cannot say WHY it was blind" $rc

echo "── a hung gh is a TRANSPORT failure, not a rate limit: bounded, never retried ──"
fresh_state calltimeout
cat > "$TMP/bin/hang-gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${ARGS:?}"
sleep 5
SH
chmod +x "$TMP/bin/hang-gh"
export ARGS="$TMP/hang.args" SLEEPS="$TMP/hang.sleeps"; : > "$ARGS"; : > "$SLEEPS"
GHS_GH="$TMP/bin/hang-gh" GHS_CALL_TIMEOUT=1 GHS_SLEEP_CMD="$TMP/bin/record-sleep" \
  "$ENGINE" run -- api repos/o/r >/dev/null 2>"$TMP/hang.err"
rc=$?
[ "$rc" -eq 124 ] && rc=0 || { rc=1; note "rc=$rc (want 124) stderr: $(cat "$TMP/hang.err")"; }
ck "a gh that never returns is killed at GHS_CALL_TIMEOUT and exits 124" $rc
grep -q 'CALL_TIMEOUT' "$TMP/hang.err" && rc=0 || rc=1
ck "the failure is NAMED as a timeout (so it is not mistaken for a rate limit)" $rc
[ "$(wc -l < "$ARGS" | tr -d ' ')" = "1" ] && rc=0 || rc=1
ck "it is NOT retried (invocations=$(wc -l < "$ARGS" | tr -d ' ')) — a stuck socket must not hold the box's lock for 4 rounds" $rc
[ -e "$CASE_STATE/last-limit" ] && rc=1 || rc=0
ck "a timeout does NOT write last-limit (it would point the next reader at GitHub quota)" $rc
[ -e "$CASE_STATE/last-call-timeout" ] && rc=0 || rc=1
ck "it is recorded under its OWN name" $rc

echo "── a wedged LOCK is not a rate limit either ──"
fresh_state locktimeout
cat > "$TMP/bin/fast-gh" <<'SH'
#!/bin/bash
echo ok
SH
chmod +x "$TMP/bin/fast-gh"
# Hold the flock from a separate process for longer than GHS_LOCK_TIMEOUT allows.
python3 - "$CASE_STATE/gh.lock" <<'PY' &
import fcntl, sys, time
fd = open(sys.argv[1], "w")
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(4)
PY
holder=$!
sleep 0.5
GHS_GH="$TMP/bin/fast-gh" GHS_LOCK_TIMEOUT=1 "$ENGINE" run -- api x >/dev/null 2>"$TMP/lock.err"
rc=$?
wait "$holder" 2>/dev/null
[ "$rc" -eq 75 ] && rc=0 || { rc=1; note "rc=$rc (want 75)"; }
ck "a lock that cannot be acquired in GHS_LOCK_TIMEOUT fails loudly (75), never hangs" $rc
grep -q 'LOCK_TIMEOUT' "$TMP/lock.err" && rc=0 || rc=1
ck "and names the lock, not GitHub" $rc
[ -e "$CASE_STATE/last-limit" ] && rc=1 || rc=0
ck "it does NOT write last-limit (B3: the durable record must not blame quota)" $rc
[ -e "$CASE_STATE/last-lock-timeout" ] && rc=0 || rc=1
ck "it is recorded under its OWN name" $rc
GHS_STATE_DIR="$CASE_STATE" "$ENGINE" state >"$TMP/state.out" 2>&1
grep -q 'last-lock-timeout:.*age=[0-9]*s' "$TMP/state.out" && rc=0 || rc=1
ck "'state' reports the record WITH ITS AGE (a write-only record would be a stale flag)" $rc
# ALL records, not the first: `last-limit` is never cleared, so returning on the first hit lets a
# months-old rate limit mask the wedged lock that is the CURRENT reason a cycle is blind.
printf 'bucket=graphql reset=unknown at=%s attempts=4 cmd=gh pr list\n' "$(( $(date +%s) - 172800 ))" > "$CASE_STATE/last-limit"
GHS_STATE_DIR="$CASE_STATE" "$ENGINE" state >"$TMP/state2.out" 2>&1
grep -q 'last-limit:' "$TMP/state2.out" && grep -q 'last-lock-timeout:' "$TMP/state2.out" && rc=0 || rc=1
ck "'state' prints EVERY record present, so a stale limit cannot mask the current cause" $rc

echo "── a permission 403 is NOT a rate limit: replayed once, never slept on ──"
fresh_state perm
cat > "$TMP/bin/perm-gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${ARGS:?}"
echo 'gh: Resource not accessible by integration (HTTP 403)' >&2
exit 1
SH
chmod +x "$TMP/bin/perm-gh"
export ARGS="$TMP/perm.args" SLEEPS="$TMP/perm.sleeps"; : > "$SLEEPS"; : > "$ARGS"
GHS_GH="$TMP/bin/perm-gh" GHS_SLEEP_CMD="$TMP/bin/record-sleep" \
  "$ENGINE" run -- pr merge 7 --repo o/r --squash >"$TMP/perm.out" 2>"$TMP/perm.err"
rc=$?
[ "$rc" -eq 1 ] && rc=0 || { rc=1; note "rc=$rc (want 1)"; }
ck "a permission 403 keeps gh's own exit status (1)" $rc
[ "$(wc -l < "$ARGS" | tr -d ' ')" = "1" ] && rc=0 || rc=1
ck "it is NOT retried (invocations=$(wc -l < "$ARGS" | tr -d ' '))" $rc
[ -s "$SLEEPS" ] && rc=1 || rc=0
ck "nothing was slept" $rc
grep -q 'Resource not accessible' "$TMP/perm.err" && rc=0 || rc=1
ck "gh's real stderr reaches the caller unchanged" $rc

echo "── mutative calls are >= 1 s apart (GitHub's stated guidance) ──"
fresh_state spacing
cat > "$TMP/bin/stamp-gh" <<'SH'
#!/bin/bash
python3 -c 'import time; print("%.6f" % time.time())' >> "${STAMPS:?}"
echo "done"
SH
chmod +x "$TMP/bin/stamp-gh"
export STAMPS="$TMP/stamps"; : > "$STAMPS"
export GHS_GH="$TMP/bin/stamp-gh" GHS_BIN="$ENGINE"
. "$LIB"
ghs_mut -- pr comment 1 --repo o/r --body hi >/dev/null 2>&1
ghs_mut -- pr comment 2 --repo o/r --body hi >/dev/null 2>&1
gap="$(python3 -c '
import sys
t=[float(x) for x in open(sys.argv[1]).read().split()]
print("%.3f" % (t[1]-t[0]) if len(t) >= 2 else "-1")' "$STAMPS")"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 0.95 else 1)' "$gap"
ck "two mutating calls are spaced ${gap}s apart (>= 1 s)" $?

echo "── conditional REST: an unchanged poll is a byte-exact 304 replay ──"
fresh_state etag
cat > "$TMP/bin/etag-gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${ARGS:?}"
hdr=""
for a in "$@"; do case "$a" in if-none-match:*) hdr="$a" ;; esac; done
if [ -n "$hdr" ]; then
  printf 'HTTP/2.0 304 Not Modified\r\nETag: "abc123"\r\nX-RateLimit-Remaining: 4998\r\n\r\n'
  exit 1
fi
printf 'HTTP/2.0 200 OK\r\nETag: "abc123"\r\nX-RateLimit-Remaining: 4997\r\n\r\n'
# Deliberately NOT valid UTF-8: a text re-encode would corrupt the replay.
printf '{"v":"\377\376","n":7}'
exit 0
SH
chmod +x "$TMP/bin/etag-gh"
export ARGS="$TMP/etag.args"; : > "$ARGS"
export GHS_GH="$TMP/bin/etag-gh"
"$ENGINE" rest "repos/o/r/pulls?state=open" >"$TMP/etag1.out" 2>"$TMP/etag1.err"
rc1=$?
"$ENGINE" rest "repos/o/r/pulls?state=open" >"$TMP/etag2.out" 2>"$TMP/etag2.err"
rc2=$?
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && rc=0 || { rc=1; note "rc=$rc1/$rc2"; }
ck "both polls succeed (the 304 is a SUCCESS, not gh's rc 1)" $rc
cmp -s "$TMP/etag1.out" "$TMP/etag2.out" && rc=0 || rc=1
ck "the 304 replayed the cached body BYTE-EXACTLY (non-UTF-8 payload)" $rc
grep -q 'if-none-match: "abc123"' "$ARGS" && rc=0 || rc=1
ck "the second poll SENT if-none-match (so GitHub can answer 304 and charge nothing)" $rc
[ "$(grep -c 'if-none-match' "$ARGS")" = "1" ] && rc=0 || rc=1
ck "exactly one charged fetch and one conditional confirmation" $rc
# The etag and the body it validates are ONE invariant. Two files replaced separately can pair a NEW
# etag with an OLD body (a concurrent poll, or a kill between the writes), and every later 304 then
# replays bytes the server never validated — with rc 0. Assert the SHAPE, or a regression back to two
# files passes every other check in this section (round-2 review).
[ "$(ls "$CASE_STATE/etag" | grep -c '\.cache$')" = "1" ] \
  && [ "$(ls "$CASE_STATE/etag" | wc -l | tr -d ' ')" = "1" ] && rc=0 || rc=1
ck "the cache is ONE file per URL (etag+body replaced atomically, no .etag/.body sibling)" $rc

cat > "$TMP/bin/jq-gh" <<'SH'
#!/bin/bash
printf 'HTTP/2.0 200 OK\r\nETag: "j1"\r\n\r\n{"v":"x"}'
exit 0
SH
chmod +x "$TMP/bin/jq-gh"
GHS_GH="$TMP/bin/jq-gh" "$ENGINE" rest "repos/o/r/commits/main" --jq '.v' >"$TMP/jq1.out" 2>&1
[ "$(cat "$TMP/jq1.out")" = "x" ] && rc=0 || rc=1
ck "--jq projects the cached/live body" $rc
GHS_GH="$TMP/bin/jq-gh" "$ENGINE" rest "repos/o/r/commits/main" --jq '.v | nosuchfn' >/dev/null 2>"$TMP/jq2.err"
rc=$?
[ "$rc" -ne 0 ] && rc=0 || rc=1
ck "a failed --jq exits non-zero (never an empty result, the #1981 class)" $rc
grep -q 'refusing to return an empty result' "$TMP/jq2.err" && rc=0 || rc=1
ck "and says why" $rc

# A 304 is a SUCCESS decided by the STATUS, not by gh's exit code. gh exits 1 for it today, but that
# is gh's implementation detail: keying on rc means the day it exits 0 the 304 falls through to an
# EMPTY body with rc 0 — a silent empty poll on a free read.
cat > "$TMP/bin/etag-rc0-gh" <<'SH'
#!/bin/bash
hdr=""
for a in "$@"; do case "$a" in if-none-match:*) hdr="$a" ;; esac; done
if [ -n "$hdr" ]; then
  printf 'HTTP/2.0 304 Not Modified\r\nETag: "rc0"\r\n\r\n'
  exit 0
fi
printf 'HTTP/2.0 200 OK\r\nETag: "rc0"\r\n\r\n'
printf '{"v":"cached-once"}'
exit 0
SH
chmod +x "$TMP/bin/etag-rc0-gh"
GHS_GH="$TMP/bin/etag-rc0-gh" "$ENGINE" rest "repos/o/r/branches/main" >"$TMP/rc0a.out" 2>/dev/null
GHS_GH="$TMP/bin/etag-rc0-gh" "$ENGINE" rest "repos/o/r/branches/main" >"$TMP/rc0b.out" 2>"$TMP/rc0b.err"
rc=$?
[ "$rc" -eq 0 ] && [ -s "$TMP/rc0b.out" ] && cmp -s "$TMP/rc0a.out" "$TMP/rc0b.out" && rc=0 || rc=1
ck "a 304 with rc 0 replays the cached body (status decides, never the exit code)" $rc

GHS_GH="$TMP/bin/etag-rc0-gh" GHS_STATE_DIR="$TMP/state-nocache" "$ENGINE" rest "repos/o/r/none" --jq .v >/dev/null 2>&1
printf 'HTTP/2.0 304 Not Modified\r\n\r\n' > "$TMP/nocache.gh"
cat > "$TMP/bin/etag-only304-gh" <<'SH'
#!/bin/bash
printf 'HTTP/2.0 304 Not Modified\r\n\r\n'
exit 1
SH
chmod +x "$TMP/bin/etag-only304-gh"
GHS_GH="$TMP/bin/etag-only304-gh" "$ENGINE" rest "repos/o/r/uncached" >"$TMP/nocache.out" 2>"$TMP/nocache.err"
rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$TMP/nocache.out" ] && rc=0 || rc=1
ck "a 304 with NO stored body is a loud failure, never an invented empty result" $rc

echo "── the layer can never silently degrade to an unserialised gh ──"
fresh_state missing
mkdir -p "$TMP/noengine"
cp "$LIB" "$TMP/noengine/lib.sh"
( unset O GHS_BIN; . "$TMP/noengine/lib.sh"; ghs_run -- pr list ) >"$TMP/missing.out" 2>"$TMP/missing.err"
rc=$?
[ "$rc" -eq 127 ] && rc=0 || { rc=1; note "rc=$rc (want 127)"; }
ck "a missing engine is a LOUD 127" $rc
grep -q 'refusing to fall back to an unserialised gh' "$TMP/missing.err" && rc=0 || rc=1
ck "and says it refused to fall back" $rc
GHS_GH=/nonexistent/gh "$ENGINE" run -- pr list >/dev/null 2>"$TMP/nogh.err"
[ "$?" -eq 127 ] && rc=0 || rc=1
ck "a missing real gh is a LOUD 127" $rc
# The layer must never answer a question gh was asked. `-h/--help` belongs to the layer ONLY when no
# gh command has been named yet; once one has, the flag is gh's (and is forwarded to it). The shape
# that exposes it is the no-`--` one, where `--help` arrives AFTER a gh token.
out="$(GHS_GH="$TMP/bin/fast-gh" "$ENGINE" run gh pr create --help 2>/dev/null)"
case "$out" in
  *"MODES"*|*"gh-serial run"*) rc=1 ;;
  *) rc=0 ;;
esac
ck "'run gh … --help' is NOT swallowed by the layer's own help" $rc
out="$(GHS_GH="$TMP/bin/fast-gh" "$ENGINE" run --help 2>/dev/null)"
case "$out" in *"MODES"*) rc=0 ;; *) rc=1 ;; esac
ck "but a bare 'run --help' still answers with the layer's own help" $rc

echo "── wiring: the harness scripts call the layer EXPLICITLY ──"
REFRESH="$HERE/refresh-candidates.sh"
LOOP="$HERE/orch-loop.sh"
grep -q 'gh-serial/lib.sh' "$REFRESH" && rc=0 || rc=1
ck "refresh-candidates.sh sources the explicit layer" $rc
[ "$(grep -c 'ghs_run' "$REFRESH")" -ge 5 ] && rc=0 || { rc=1; note "ghs_run sites: $(grep -c 'ghs_run' "$REFRESH")"; }
ck "refresh-candidates.sh routes its queue + listing reads through it" $rc
grep -q '^if ! gh issue list' "$REFRESH" && rc=1 || rc=0
ck "the pre-fix bare listing lines are gone (no silent opt-out left)" $rc
grep -q 'gh-serial/lib.sh' "$LOOP" && rc=0 || rc=1
ck "orch-loop.sh sources the explicit layer" $rc
grep -q 'ghs_run -- gh pr list --repo "\$OR" --state open' "$LOOP" && rc=0 || rc=1
ck "orch-loop.sh's open-PR count (the 'open=UNKNOWN' symptom) uses it" $rc
# The pre-flight probes are deliberately NOT wrapped (they are the diagnostics that must stay
# cheap and must keep distinguishing a 401 from a transport fault). Allowlist them explicitly so a
# NEW bare gh call cannot slip in unnoticed.
bare="$(grep -nE '^[[:space:]]*(if |elif |! )?gh ' "$REFRESH" | grep -vE 'gh auth (token|status)|gh api rate_limit|command -v gh' || true)"
[ -z "$bare" ] && rc=0 || { rc=1; note "unwrapped bare gh lines: $bare"; }
ck "every OTHER bare gh line in refresh-candidates.sh is an allowlisted pre-flight probe" $rc
# The LAYER must reach the BOX, not just the checkout. install.sh seeds the Mac; the cell seeders are
# a different path, and a cell seeded without gh-serial/ runs UNDEFINED ghs_run ⇒ 127 on every read ⇒
# queue=UNREADABLE forever with the cell reporting RUNNING (#1736). That was a review finding on this
# change; these assertions keep it from regressing.
grep -q "mkdir -p \"\$O/gh-serial\"" "$HERE/../cloud-cell-supervisor.sh" && rc=0 || rc=1
ck "cloud-cell-supervisor.sh seeds the gh layer into \$O" $rc
grep -q "gh-serial/lib.sh gh-serial/gh-serial gh-serial/gh_serial.py" "$HERE/../cloud-cell-supervisor.sh" && rc=0 || rc=1
ck "cloud-cell-supervisor.sh's check REFUSES a cell without the layer" $rc
grep -q 'gh-serial' "$HERE/../deploy-crossbox.sh" && rc=0 || rc=1
ck "deploy-crossbox.sh seeds it too" $rc
grep -q 'the layer would install incomplete' "$HERE/install.sh" && rc=1 || rc=0
ck "install.sh's incomplete-set branch is not DEAD code claiming a refusal it cannot reach" $rc
grep -q 'die "gh-serial/ is missing from the shipped set' "$HERE/install.sh" && rc=0 || rc=1
ck "install.sh REFUSES (die, non-zero) a shipped set without the layer" $rc
grep -q 'ghs_run version' "$HERE/install.sh" && rc=0 || rc=1
ck "install.sh proves the artifact the CALL SITES use (lib.sh), not just the engine" $rc

echo
echo "gh-serial: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
