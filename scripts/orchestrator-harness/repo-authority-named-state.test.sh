#!/usr/bin/env bash
# repo-authority-named-state.test.sh — an unreadable protection endpoint must say WHY it is unreadable.
#
# WHY THIS FILE EXISTS. On 2026-10-22 the account's REST pool hit `5000 used / 0 remaining` while
# GraphQL still held 4769. The protection read failed, `required_checks` returned 1, the resolver fell
# back to `REQ_SOURCE=fallback`, and every lane reported “the merge contract is UNKNOWN” — a sentence
# that sends an operator to check credentials, the `--repo` flag and the repo's own protection rules.
# All three were fine. The budget was empty, and the layer knew it.
#
# So this pins three things, and the third is the one that keeps a stale record from becoming a
# permanent excuse:
#   (1) an exhausted-budget record => the failure NAMES it (`gh-core-exhausted resets_in=<Nm>`);
#   (2) no record (healthy budget)   => the failure is silent, exactly as before (no new noise);
#   (3) a record whose window has PASSED => silent (a closed window is not a current state).
#
# No network, no credentials: a stub gh fails the read the way GitHub does.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RA="$HERE/repo-authority.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi; }
[ -f "$RA" ] || { echo "missing: $RA" >&2; exit 1; }
bash -n "$RA" || { echo "repo-authority.sh does not parse" >&2; exit 1; }

# A gh that refuses the way an exhausted pool does: rc 1, nothing on stdout.
printf '#!/usr/bin/env bash\nprintf "API rate limit exceeded for user ID 81560491.\\n" >&2\nexit 1\n' > "$TMP/gh"
chmod +x "$TMP/gh"

NOW="$(date +%s)"

probe() {  # probe <state-dir> -> sets RC / ERR (stdout is irrelevant: the read FAILED)
  GH_LIMIT_DIR="$1" bash -c 'source "$1"; required_checks o/r "$2"' _ "$RA" "$TMP/gh" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  ERR="$(cat "$TMP/err")"
  OUT="$(cat "$TMP/out")"
}

echo "── (1) exhausted budget => the failure NAMES the state ───────────────────────────────────────"
mkdir -p "$TMP/s1"
printf 'gh-core-exhausted resets_in=12m at=%s bucket=core remaining=0 reset=%s\n' "$NOW" "$((NOW + 700))" > "$TMP/s1/health"
probe "$TMP/s1"
ck "(1) the read still FAILS (fail-closed, unchanged)" $([ "$RC" -eq 1 ] && echo 0 || echo 1)
ck "(1) nothing was printed as a context set" $([ -z "$OUT" ] && echo 0 || echo 1)
ck "(1) stderr names gh-core-exhausted resets_in=<Nm>" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted resets_in=12m' && echo 0 || echo 1)
ck "(1) the window is computed from the record, not restated from the file (12m of 700s)" \
   $(printf '%s' "$ERR" | grep -q 'resets_in=12m' && echo 0 || echo 1)
ck "(1) it says the budget is the problem, not the repo/token/GitHub" \
   $(printf '%s' "$ERR" | grep -q 'not a broken repo' && echo 0 || echo 1)

echo "── (2) no record => silent (an ordinary unreadable read adds no noise) ───────────────────────"
mkdir -p "$TMP/s2"
probe "$TMP/s2"
ck "(2) the read FAILS" $([ "$RC" -eq 1 ] && echo 0 || echo 1)
ck "(2) stderr is EMPTY (no invented diagnosis)" $([ -z "$ERR" ] && echo 0 || echo 1)

echo "── (3) a record whose window PASSED is not a current state ──────────────────────────────────"
mkdir -p "$TMP/s3"
printf 'gh-core-exhausted resets_in=1m at=%s bucket=core remaining=0 reset=%s\n' "$((NOW - 900))" "$((NOW - 60))" > "$TMP/s3/health"
probe "$TMP/s3"
ck "(3) the read FAILS" $([ "$RC" -eq 1 ] && echo 0 || echo 1)
ck "(3) stderr is EMPTY — a closed window cannot keep asserting itself" $([ -z "$ERR" ] && echo 0 || echo 1)

echo "── (4) a GOOD read is unaffected (no named state on success) ────────────────────────────────"
printf '#!/usr/bin/env bash\nprintf "pipeline-compliance\\nai-review-gate\\n"\n' > "$TMP/gh-ok"
chmod +x "$TMP/gh-ok"
GH_LIMIT_DIR="$TMP/s1" bash -c 'source "$1"; required_checks o/r "$2"' _ "$RA" "$TMP/gh-ok" >"$TMP/out" 2>"$TMP/err"
RC=$?
ck "(4) exit 0 with the deduplicated, space-joined set" \
   $([ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "pipeline-compliance ai-review-gate" ] && echo 0 || echo 1)
ck "(4) it prints nothing on stderr even with an exhausted record present" $([ ! -s "$TMP/err" ] && echo 0 || echo 1)

echo "── (5) UNDATED records, and a window the two readers must agree about ───────────────────────"
# (5a) An UNDATED record is the shape EVERY `GH_LIMIT_NO_WAIT` caller produces (eight heartbeat
# tools set it). Requiring `reset > now` made this reader print NOTHING for it, so the lane fell back
# to “branch protection UNREADABLE” — the defect this file exists to remove.
mkdir -p "$TMP/s5"
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$NOW" > "$TMP/s5/health"
probe "$TMP/s5"
ck "(5a) an undated record still NAMES the state" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted resets_in=?' && echo 0 || echo 1)
ck "(5a) … and prints no number nobody measured" \
   $(printf '%s' "$ERR" | grep -q 'resets_in=?' && echo 0 || echo 1)
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$((NOW - 1000))" > "$TMP/s5/health"
probe "$TMP/s5"
ck "(5b) an undated record past its bound is SILENT (age-bounded, like every record here)" \
   $([ -z "$ERR" ] && echo 0 || echo 1)
# (5c) the CLAMP must accept what the layer's cfg_secs accepts: a decimal and a negative reach the
# 60 s floor, a non-numeric falls back to the default. Sending the first two to 900 made the two
# readers disagree about one record (measured, round 4).
printf 'gh-core-exhausted resets_in=? at=%s bucket=core remaining=? reset=0\n' "$((NOW - 300))" > "$TMP/s5/health"
export GH_LIMIT_HEALTH_UNKNOWN_WINDOW=45.5
probe "$TMP/s5"
ck "(5c) window=45.5 clamps to the 60 s floor => a 300 s-old record is SILENT, as the layer says" \
   $([ ! -s "$TMP/err" ] && echo 0 || echo 1)
export GH_LIMIT_HEALTH_UNKNOWN_WINDOW=-5
probe "$TMP/s5"
ck "(5c) window=-5 clamps to the 60 s floor too (was sent to the 900 s default)" \
   $([ ! -s "$TMP/err" ] && echo 0 || echo 1)
export GH_LIMIT_HEALTH_UNKNOWN_WINDOW=abc
probe "$TMP/s5"
ck "(5c) window=abc falls back to the default => the record is NAMED (not silently dropped)" \
   $(printf '%s' "$ERR" | grep -q 'gh-core-exhausted resets_in=?' && echo 0 || echo 1)
unset GH_LIMIT_HEALTH_UNKNOWN_WINDOW

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
