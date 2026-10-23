#!/usr/bin/env bash
# creation-gate.test.sh — offline checks for the creation gate (#2535).
#
# No network, no credentials: a STUB `gh` earlier on PATH emits a canned GraphQL answer and records
# every invocation, so the assertions pin the VERDICT ARITHMETIC and the four directions that decide
# whether the fleet can keep moving:
#
#   1. over the floor + create  -> REFUSED, and the refusal quotes the numbers it compared
#   2. over the floor + land    -> ALLOWED  (the case that must never regress: a gate that refuses a
#                                   landing lane during a landing backlog is backwards — capping μ
#                                   raises wait time in M/M/1, W = 1/(μ−λ))
#   3. under the floor + create -> ALLOWED
#   4. UNREADABLE + create      -> REFUSED (fail CLOSED), UNREADABLE + land -> ALLOWED (fail OPEN)
#
# Plus: no `--kind` is a usage error (an unsafe default is the thing the flag removes), a stale stamp
# is UNKNOWN rather than a zero, and a fresh cache costs ZERO extra `gh` calls.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/creation-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { local d="$1"; shift; if eval "$@"; then pass=$((pass+1)); printf '  ok   %s\n' "$d"; else fail=$((fail+1)); printf '  FAIL %s\n' "$d"; fi; }
[ -f "$GATE" ] || { echo "gate missing: $GATE" >&2; exit 1; }
bash -n "$GATE" || { echo "gate does not parse" >&2; exit 1; }

# ── the stub `gh` the gate resolves on PATH ─────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG:-/dev/null}"
[ "${STUB_FAIL:-0}" = 1 ] && { printf 'gh-limit: RATE LIMITED bucket=core attempts=4\n' >&2; exit 1; }
[ "${STUB_GARBAGE:-0}" = 1 ] && { printf 'not json at all\n'; exit 0; }
# The canned answer: OPEN_COUNT open PRs, LAND_RECENT of them merged inside the window.
CATS="${STUB_MERGED_CATS:-0}"
printf '{"data":{"repository":{"open":{"totalCount":%s},"merged":{"nodes":[' \
  "${STUB_OPEN:-0}"
i=0
while [ "$i" -lt "$CATS" ]; do
  [ "$i" -gt 0 ] && printf ','
  printf '{"mergedAt":"2026-10-23T15:40:00Z"}'
  i=$((i + 1))
done
printf ']}}}}'
exit 0
STUB
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"
export PATH

# Fixed clock so the stamp arithmetic is exact. KEEP_AT is "now"; an old stamp is KEEP_AT - 7200.
NOW=1792771200          # 2026-10-23T16:00:00Z
REPO="acme/widget"

run() {  # run <kind|""> <extra env...> ; sets RC OUT ERR
  local kind="$1"; shift
  local odir="$TMP/o.$RANDOM.$RANDOM"
  mkdir -p "$odir/state"
  ERR="$odir/err"; OUT="$odir/out"
  if [ -n "$kind" ]; then
    env "$@" O="$odir" STUB_LOG="$odir/calls.log" \
      bash "$GATE" --kind="$kind" --repo="$REPO" --now="$NOW" >"$OUT" 2>"$ERR"
  else
    env "$@" O="$odir" STUB_LOG="$odir/calls.log" \
      bash "$GATE" --repo="$REPO" --now="$NOW" >"$OUT" 2>"$ERR"
  fi
  RC=$?
  CALLS="$odir/calls.log"
  LAST="$odir"
}

# ── 1. OVER the floor + create -> REFUSED, quoting what it compared ───────────────────────────
# 69 open, 1 landed in the last hour: 1.4% drain vs a 4.2% floor (a 24h lead time at this rate).
run create STUB_OPEN=69 STUB_MERGED_CATS=1
ck "over-floor + create is REFUSED (rc=1)" "[ "$RC" -eq 1 ]"
grep -q 'REFUSED kind=create' "$ERR"                       ; ck "  refusal says REFUSED kind=create" "[ $? -eq 0 ]"
grep -q '69 open, 1 landed in 60 min' "$ERR"               ; ck "  refusal quotes the OPEN count and the WINDOW" "[ $? -eq 0 ]"
grep -q 'ratio 1.4% < 4.2% floor' "$ERR"                   ; ck "  refusal quotes the RATIO and the FLOOR it compared" "[ $? -eq 0 ]"
grep -q '24h lead time' "$ERR"                             ; ck "  refusal names where the floor comes from (24h lead)" "[ $? -eq 0 ]"
grep -q 'nothing was created' "$ERR"                       ; ck "  refusal states no creation happened" "[ $? -eq 0 ]"
ck "  refusal is on stderr, not stdout" "[ ! -s \"$OUT\" ]"

# ── 2. OVER the floor + land -> ALLOWED (the case that must never regress) ────────────────────
run land STUB_OPEN=69 STUB_MERGED_CATS=1
ck "over-floor + land is ALLOWED (rc=0) — the drain is never throttled" "[ "$RC" -eq 0 ]"
ck "  land printed no refusal" "! grep -q REFUSED \"$ERR\""

# 2b. the SAME over-floor measurement, this time already CACHED: land must still be allowed, must say
# WHY, and must cost ZERO gh calls (a landing lane pays nothing to be told it may land).
OD="$TMP/o.landcached"; mkdir -p "$OD/state"
printf '# fresh\n%s\tok\t69\t1\t60\n' "$NOW" >"$OD/state/creation-ratio-acme-widget.tsv"
env O="$OD" STUB_LOG="$OD/calls.log" STUB_OPEN=69 STUB_MERGED_CATS=1 bash "$GATE" \
  --kind=land --repo="$REPO" --now="$NOW" >"$OD/out" 2>"$OD/err"; RC=$?
ck "over-floor (cached) + land is ALLOWED (rc=0)" "[ "$RC" -eq 0 ]"
ck "  and it says why (the drain is what the floor protects)" "grep -q 'never held' \"$OD/out\""
ck "  and land cost ZERO gh calls" "[ ! -s \"$OD/calls.log\" ]"

# ── 2b. over the floor + fix / measure -> ALLOWED ─────────────────────────────────────────────
for k in fix measure; do
  run "$k" STUB_OPEN=69 STUB_MERGED_CATS=1
  ck "over-floor + $k is ALLOWED (rc=0)" "[ "$RC" -eq 0 ]"
done

# ── 3. UNDER the floor + create -> ALLOWED ────────────────────────────────────────────────────
# 69 open, 5 landed in the last hour: 7.2% drain, above the 4.2% floor.
run create STUB_OPEN=69 STUB_MERGED_CATS=5
ck "under-floor + create is ALLOWED (rc=0)" "[ "$RC" -eq 0 ]"
grep -q 'ratio 7.2% >= 4.2%' "$OUT"                         ; ck "  and quotes the ratio over the floor" "[ $? -eq 0 ]"

# ── 3b. the boundary: exactly at the floor is ALLOWED (>=, not >) ─────────────────────────────
# 100 open, 5 landed in the last hour: 5.0% > 4.2%. And 24 open / 1 landed = 4.16% < 4.2% -> held.
run create STUB_OPEN=24 STUB_MERGED_CATS=1
ck "just UNDER the floor (4.1%) is REFUSED (rc=1)" "[ "$RC" -eq 1 ]"
run create STUB_OPEN=23 STUB_MERGED_CATS=1
ck "just OVER the floor (4.3%) is ALLOWED (rc=0)" "[ "$RC" -eq 0 ]"

# ── 4. UNREADABLE measurement: fail CLOSED for create, OPEN for land/fix/measure ──────────────
run create STUB_FAIL=1
ck "unreadable + create is REFUSED (rc=3, fail CLOSED)" "[ "$RC" -eq 3 ]"
grep -q 'UNREADABLE' "$ERR"                                 ; ck "  and says the measurement is UNREADABLE" "[ $? -eq 0 ]"
grep -q 'never a zero' "$ERR"                               ; ck "  and says a failed read is never a zero" "[ $? -eq 0 ]"
for k in land fix measure; do
  run "$k" STUB_FAIL=1
  ck "unreadable + $k is ALLOWED (rc=0, fail OPEN)" "[ "$RC" -eq 0 ]"
done
run create STUB_GARBAGE=1
ck "an unparseable answer + create is REFUSED (rc=3), not read as 0 open" "[ "$RC" -eq 3 ]"

# ── 5. a STALE stamp is UNKNOWN, never a zero ─────────────────────────────────────────────────
# Seed a fresh-looking cache row stamped two hours ago, with a GOOD ratio in it: a gate that trusts
# an old stamp would allow creation on a stale number.
OD="$TMP/o.stale"; mkdir -p "$OD/state"
printf '%s\tok\t5\t99\t60\n' "$((NOW - 7200))" >"$OD/state/creation-ratio-acme-widget.tsv"
env O="$OD" STUB_LOG="$OD/calls.log" STUB_FAIL=1 bash "$GATE" --kind=create --repo="$REPO" --now="$NOW" \
  >"$OD/out" 2>"$OD/err"; RC=$?
ck "a 2h-old stamp is re-measured, and a FAILED re-read holds creation (rc=3)" "[ "$RC" -eq 3 ]"
# ...and with the re-read working, the stale GOOD ratio must be replaced by the live one.
env O="$OD" STUB_LOG="$OD/calls.log" STUB_OPEN=69 STUB_MERGED_CATS=1 bash "$GATE" \
  --kind=create --repo="$REPO" --now="$NOW" >"$OD/out2" 2>"$OD/err2"; RC=$?
ck "a 2h-old stamp re-read live: now OVER the floor, so REFUSED (rc=1)" "[ "$RC" -eq 1 ]"

# ── 6. ONE read serves many creations (the cache is the cost control) ─────────────────────────
OD="$TMP/o.cache"; mkdir -p "$OD/state"
for i in 1 2 3; do
  env O="$OD" STUB_LOG="$OD/calls.log" STUB_OPEN=69 STUB_MERGED_CATS=5 bash "$GATE" \
    --kind=create --repo="$REPO" --now="$NOW" >/dev/null 2>&1
done
n="$(wc -l <"$OD/calls.log" 2>/dev/null | tr -d ' ')"
ck "3 creations inside the window cost exactly ONE gh read (got ${n:-0})" "[ "${n:-0}" -eq 1 ]"

# ── 7. --kind is REQUIRED, with no unsafe default ─────────────────────────────────────────────
run "" STUB_OPEN=69 STUB_MERGED_CATS=5
ck "no --kind is a usage error (rc=2), not an inherited 'allowed'" "[ "$RC" -eq 2 ]"
grep -q 'has no default' "$ERR"                             ; ck "  and the message says why" "[ $? -eq 0 ]"
run bogus STUB_OPEN=69 STUB_MERGED_CATS=5
ck "an unknown --kind is a usage error (rc=2)" "[ "$RC" -eq 2 ]"

# ── 8. an unresolvable repo + create -> HELD (cannot measure != fine) ─────────────────────────
# Run from a directory that is not a git checkout and pass no --repo.
OD="$TMP/o.norepo"; mkdir -p "$OD/state" "$TMP/notgit"
( cd "$TMP/notgit" && env O="$OD" STUB_LOG="$OD/calls.log" STUB_OPEN=69 STUB_MERGED_CATS=5 \
    bash "$GATE" --kind=create --now="$NOW" >"$OD/out" 2>"$OD/err" ); RC=$?
ck "no resolvable repo + create is HELD (rc=3)" "[ "$RC" -eq 3 ]"

# ── 9. the floor is DERIVED from the lead time, not independently typed ───────────────────────
# 1000/24h = 41.7%%, rounded UP to 42 tenths (4.2%). A floor below the lead time would allow a
# creation the lead time forbids; a floor typed by hand could drift from the number it prints.
src_pct="$(awk -F= '/^CG_MAX_LEAD_H=/{print $2}' "$GATE" | head -1 | cut -d'#' -f1 | tr -d ' ')"
ck "CG_MAX_LEAD_H is a named constant (got '${src_pct:-none}')" "[ -n "${src_pct:-}" ]"
grep -q 'CG_DRAIN_PCT10=\$(( (1000 + CG_MAX_LEAD_H - 1) / CG_MAX_LEAD_H ))' "$GATE"
ck "the floor is DERIVED from CG_MAX_LEAD_H in one place" "[ $? -eq 0 ]"

printf '\ncreation-gate.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
