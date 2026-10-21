#!/usr/bin/env bash
# gh-probe-bound.test.sh — the credential probe in refresh-candidates.sh can NEVER stall the pass.
#
# WHY THIS TEST EXISTS. Measured 2026-10-21: `refresh-candidates.sh` sat at `stage=provision` for a
# whole session and every pass recorded `STALE(800m)`, so origination never ran. `gh auth token` never
# returned on that box (rc=142 under an alarm; on the live box every gh call was waiting out the
# per-machine courtesy gate's 300 s admission window). An unbounded probe is an unbounded pass, and
# nothing in the suite could see it because the probe was never RUN against a gh that does not answer.
#
# WHAT IT PINS, in the order the probe decides:
#   1. GH_TOKEN / GITHUB_TOKEN in the environment is PRESENCE — gh is not invoked AT ALL.
#   2. a probe that does not answer inside the bound says "presence UNKNOWN" and the pass CONTINUES
#      to the API question (rc=1 TRANSIENT when that also times out) — never a hang.
#   3. a credential that does answer still succeeds (the bound did not turn into a refusal).
#   4. a credential that is genuinely ABSENT is still NOT PROVISIONABLE (rc=3) — presence keeps its
#      meaning: the bound must not be bought by refusing nothing.
#   5. an HTTP 401 is still PERMANENT (rc=3).
#   6. an INVALID/ZERO bound is refused as a bound and replaced (a zero bound is no bound).
#   7. SENSITIVITY, BY MUTATION: with the bound removed from the SAME driver, case 2 HANGS. A test
#      that passes against an unbounded probe would be asserting nothing at all.
#
# Hermetic: no gh, no network, no repo. The functions are extracted from the SHIPPED script (never
# restated here — an expectation taken from this file cannot fail on the script).
#
# Run: bash scripts/orchestrator-harness/gh-probe-bound.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/refresh-candidates.sh}"

checks=0; failures=0
ok(){ checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
bad(){ checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

[ -f "$SUT" ] || { echo "FATAL: $SUT not found"; exit 1; }

# ── extract the shipped probe (constants + the two functions) ───────────────────────────────────
# Anchored on the assignments and on `name() {` … a column-0 `}`. If a future edit renames or inlines
# either function the extraction comes back EMPTY, and an empty driver passes every assertion
# vacuously — so the extraction is itself asserted below.
EXTRACT="$T/probe.sh"
{
  awk '/^EXIT_TRANSIENT=/{print; next} /^EXIT_NOT_PROVISIONABLE=/{print; next} /^GH_PROBE_TIMEOUT=/{print; next}' "$SUT"
  # ⛔ A PREFIX match (`index(...) == 1`), not the exact string `fn() {`: `gh_probe_bounded() {   # <args>`
  # carries a trailing comment on its opener line, and the exact match extracted nothing — which the
  # test caught as "could not be extracted" rather than passing vacuously.
  for fn in gh_probe_was_bounded_out gh_probe_bounder gh_probe_bounded gh_probe_bound_ok gh_probe_env; do
    awk -v fn="$fn" '
      index($0, fn "() {") == 1 { f = 1; print; if ($0 ~ /}[[:space:]]*$/) exit; next }
      f { print; if ($0 ~ /^}[[:space:]]*$/) exit }
    ' "$SUT"
  done
} > "$EXTRACT"

for want in 'EXIT_TRANSIENT=' 'GH_PROBE_TIMEOUT=' 'gh_probe_was_bounded_out() {' 'gh_probe_bounder() {' 'gh_probe_bounded() {' 'gh_probe_bound_ok() {' 'gh_probe_env() {'; do
  if grep -qF -- "$want" "$EXTRACT"; then
    ok "the shipped probe exposes $want"
  else
    bad "the probe could not be extracted from $SUT ($want missing) — every assertion below would be vacuous"
  fi
done
[ "$failures" -eq 0 ] || { echo "❌ cannot test the shipped probe"; exit 1; }

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
# A `gh` that records EVERY argv it is handed and then behaves as the case asks. The record is the
# only evidence that matters for case 1: "not invoked" cannot be read off a sleep.
mk_gh(){ # <dir> <mode>
  local dir="$1" mode="$2"
  mkdir -p "$dir"
  # ⛔ THE MODE IS SUBSTITUTED AT GENERATION TIME (`$mode`), while `\$1 \$2` stay RUNTIME argv. Writing
  # `$2mode` here reads as "${2}mode" inside the stub — so every case fell through to `exit 0` and the
  # "hanging gh" answered instantly, which is how this test first reported case 2 as a bogus pass.
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/argv.log"
case "$mode" in
  hang) sleep 60 ;;
  # ⛔ THE KILL PATH: `timeout -k 2` TERMs at the bound and KILLs 2 s later. A child that TRAPS TERM
  # outlives the TERM, so the exit is 137 — not 124. That is the shape that was misread as "gh answered
  # with a failure", i.e. as an ABSENT credential, and latched the permanent marker.
  trapterm) trap '' TERM; sleep 60 ;;
esac
case "\$1 \$2" in
  "auth token")
    case "$mode" in nope) echo "no oauth token for the configured host" >&2; exit 1 ;; *) echo "s3cr3t-token"; exit 0 ;; esac ;;
  "api rate_limit") echo '{"resources":{}}'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$dir/gh"
}

# run_probe <dir-with-gh> <VAR=VAL>... — sources the extracted probe in a SUBSHELL and prints
# "RC=<n> SECS=<n>".
# ⛔ Subshell + `.` sourcing, never `bash <a variable path>`: a fresh interpreter spawned on a path
# the guard cannot read is the #1484 script indirection, and it fails closed (correctly) instead of
# running this suite. Same shell, isolated environment.
run_probe(){
  local bin="$1"; shift
  (
    unset GH_TOKEN GITHUB_TOKEN
    for _kv in "$@"; do export "$_kv"; done
    PATH="$bin:$PATH"; export PATH
    set -uo pipefail
    cd "$T" || return 1
    # ⛔ A LITERAL operand (`./probe.sh`), not a `$VAR` path: the worktree hazard gate refuses an
    # interpreter spawned on a path it cannot resolve statically, and correctly so — a test that
    # points at a variable path can run anything. The file is in THIS case's temp dir by construction.
    . ./probe.sh
    t0=$(date +%s)
    gh_probe_env
    rc=$?
    echo "RC=$rc SECS=$(( $(date +%s) - t0 ))"
  ) 2>&1
}
field(){ printf '%s\n' "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p" | tail -1; }

echo "1. a token IN THE ENVIRONMENT is presence, without invoking gh"
B1="$T/b1"; mk_gh "$B1" ok   # a HEALTHY gh: presence must be skipped even when it would answer
OUT="$(run_probe "$B1" GH_TOKEN=env-token)"
if [ "$(field "$OUT" RC)" = 0 ]; then ok "GH_TOKEN in env -> rc=0 (present, usable)"; else bad "GH_TOKEN in env -> rc=$(field "$OUT" RC) (want 0): $OUT"; fi
if [ "$(field "$OUT" SECS)" -lt 10 ] 2>/dev/null; then ok "GH_TOKEN in env answered immediately ($(field "$OUT" SECS)s) — no probe ran"; else bad "GH_TOKEN in env took $(field "$OUT" SECS)s — the probe ran anyway"; fi
if [ ! -s "$B1/argv.log" ] || ! grep -q 'auth token' "$B1/argv.log"; then
  ok "the PRESENCE probe (gh auth token) was never invoked — the env token short-circuits it"
else
  bad "gh auth token was invoked anyway: $(tr '\n' ';' < "$B1/argv.log")"
fi
# The API call is expected (validation is a separate question from presence) — pin that it happened,
# so "gh not invoked at all" cannot be mistaken for the env-token short circuit.
if grep -q 'api rate_limit' "$B1/argv.log" 2>/dev/null; then
  ok "the API validation call still ran (presence was skipped, validation was not)"
else
  bad "no API validation call ran — case 1 proves less than it claims"
fi

echo ""
echo "2. a probe that does not answer inside the bound says so, and the pass CONTINUES"
B2="$T/b2"; mk_gh "$B2" hang
OUT="$(run_probe "$B2" GH_PROBE_TIMEOUT=2)"
if [ "$(field "$OUT" RC)" = 1 ]; then ok "a hanging gh -> rc=1 TRANSIENT (retried next cycle), not rc=3"; else bad "a hanging gh -> rc=$(field "$OUT" RC) (want 1): $OUT"; fi
if [ "$(field "$OUT" SECS)" -lt 30 ] 2>/dev/null; then ok "it RETURNED in $(field "$OUT" SECS)s instead of hanging"; else bad "it took $(field "$OUT" SECS)s — the bound did not fire"; fi
case "$OUT" in *"presence UNKNOWN"*) ok "it SAYS presence is unknown (never silently reads a silence as absence)" ;; *) bad "no 'presence UNKNOWN' line: $OUT" ;; esac
case "$OUT" in *"did not answer within 2s"*) ok "the line names the bound it used (2s)" ;; *) bad "the line does not name the bound: $OUT" ;; esac
case "$OUT" in *NOT_PROVISIONABLE*) bad "a slow probe latched the PERMANENT verdict: $OUT" ;; *) ok "a slow probe did NOT latch the permanent MERGE-ONLY marker" ;; esac

echo ""
echo "2b. the KILL path (a child that outlives TERM) is UNKNOWN too, never an absent credential"
B2b="$T/b2b"; mk_gh "$B2b" trapterm
OUT="$(run_probe "$B2b" GH_PROBE_TIMEOUT=1)"
if [ "$(field "$OUT" RC)" = 1 ]; then ok "a TERM-trapping probe -> rc=1 TRANSIENT (the kill-after exit is not a verdict)"; else bad "a TERM-trapping probe -> rc=$(field "$OUT" RC) (want 1): $OUT"; fi
case "$OUT" in *"NOT PROVISIONABLE"*) bad "the KILL path was read as an ABSENT credential -> permanent MERGE-ONLY marker: $OUT" ;; *) ok "the KILL path never reads as a stored-credential absence" ;; esac
case "$OUT" in *"presence UNKNOWN"*) ok "and it says presence is unknown" ;; *) bad "no 'presence UNKNOWN' on the kill path: $OUT" ;; esac

echo ""
echo "2c. NO bounding tool on the box: presence UNKNOWN + TRANSIENT, never a silent PERMANENT"
B2c="$T/b2c"; mk_gh "$B2c" hang
OUT="$(run_probe "$B2c" GH_PROBE_BOUNDER=none)"
if [ "$(field "$OUT" RC)" = 1 ]; then ok "no bounder -> rc=1 (retried), not rc=3"; else bad "no bounder -> rc=$(field "$OUT" RC) (want 1): $OUT"; fi
case "$OUT" in *"NO BOUNDING TOOL"*) ok "it names the missing tool instead of printing a wrong remedy" ;; *) bad "it does not say the bounder is missing: $OUT" ;; esac
case "$OUT" in *"NOT PROVISIONABLE"*) bad "a missing bounder was reported as a credential verdict: $OUT" ;; *) ok "a missing bounder is never a credential verdict" ;; esac
if [ "$(field "$OUT" SECS)" -lt 10 ] 2>/dev/null; then ok "and it did not run the probe unbounded ($(field "$OUT" SECS)s)"; else bad "it took $(field "$OUT" SECS)s — the unbounded probe ran anyway"; fi

echo ""
echo "2d. the perl fallback bounds the probe too (a box without timeout)"
B2d="$T/b2d"; mk_gh "$B2d" hang
OUT="$(run_probe "$B2d" GH_PROBE_TIMEOUT=2 GH_PROBE_BOUNDER=perl)"
if [ "$(field "$OUT" RC)" = 1 ]; then ok "perl alarm -> rc=1 TRANSIENT"; else bad "perl alarm -> rc=$(field "$OUT" RC) (want 1): $OUT"; fi
if [ "$(field "$OUT" SECS)" -lt 30 ] 2>/dev/null; then ok "the perl path returned in $(field "$OUT" SECS)s"; else bad "the perl path took $(field "$OUT" SECS)s — it did not bound"; fi

echo ""
echo "6b. the BOUND VALIDATOR rejects every no-bound spelling (0, 00, 01, empties)"
( cd "$T" && . ./probe.sh
  for v in 0 00 01 000 '' abc 1.5 -5 ' 15' 1 15 300; do
    if gh_probe_bound_ok "$v"; then printf 'ACCEPT %s\n' "$v"; else printf 'REJECT %s\n' "$v"; fi
  done ) > "$T/bound_ok.txt" 2>&1
if grep -qE '^ACCEPT (0|00|01|000)$' "$T/bound_ok.txt"; then
  bad "a zero/leading-zero bound was ACCEPTED (timeout reads it as 0 = no bound): $(tr '\n' ' ' < "$T/bound_ok.txt")"
else
  ok "0 / 00 / 01 / 000 are all REJECTED as bounds (coreutils reads a leading zero as duration 0)"
fi
if [ "$(grep -c '^ACCEPT' "$T/bound_ok.txt")" = 3 ]; then ok "and the three real bounds (1, 15, 300) are still accepted"; else bad "the validator is over-strict: $(tr '\n' ' ' < "$T/bound_ok.txt")"; fi

echo ""
echo "2e. an INVALID GH_PROBE_BOUNDER pin is replaced, never a 127 read as an absent credential"
B2e="$T/b2e"; mk_gh "$B2e" ok
OUT="$(run_probe "$B2e" GH_PROBE_BOUNDER=garbage)"
# ⛔ THE SEAM IS A SEAM. An unknown bounder reaches the catch-all, which exits 127 — and 127 is not a
# bound-fired status, so the presence probe would read "command not found" as "no credential STORED"
# and return PERMANENT with `gh auth login` as the remedy: the defect the discovery exists to remove,
# reintroduced through its own knob.
case "$OUT" in *"NOT PROVISIONABLE"*) bad "an INVALID GH_PROBE_BOUNDER produced a permanent credential verdict: $OUT" ;; *) ok "an invalid bounder pin never becomes a credential verdict" ;; esac
case "$OUT" in *"WARN"*"GH_PROBE_BOUNDER"*) ok "it warns that the pin is not one of timeout|perl|none" ;; *) bad "the invalid pin is not reported: $OUT" ;; esac
if [ "$(field "$OUT" RC)" = 0 ]; then ok "and the discovered bounder still lets a healthy probe succeed"; else bad "the discovered bounder did not recover (rc=$(field "$OUT" RC)): $OUT"; fi

echo ""
echo "3. a credential that DOES answer still succeeds (the bound did not become a refusal)"
B3="$T/b3"; mk_gh "$B3" ok
OUT="$(run_probe "$B3" GH_PROBE_TIMEOUT=5)"
if [ "$(field "$OUT" RC)" = 0 ]; then ok "stored credential + answering API -> rc=0"; else bad "stored credential -> rc=$(field "$OUT" RC) (want 0): $OUT"; fi

echo ""
echo "4. a credential that is genuinely ABSENT is still NOT PROVISIONABLE"
B4="$T/b4"; mk_gh "$B4" nope
OUT="$(run_probe "$B4" GH_PROBE_TIMEOUT=5)"
if [ "$(field "$OUT" RC)" = 3 ]; then ok "no stored credential -> rc=3 PERMANENT (presence keeps its meaning)"; else bad "no stored credential -> rc=$(field "$OUT" RC) (want 3): $OUT"; fi
case "$OUT" in *"no oauth token"*) ok "the probe's own reason is surfaced" ;; *) bad "the reason is missing: $OUT" ;; esac

echo ""
echo "5. an HTTP 401 is still PERMANENT"
B5="$T/b5"; mkdir -p "$B5"
cat > "$B5/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth token") echo tok; exit 0 ;;
  "api rate_limit") echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$B5/gh"
OUT="$(run_probe "$B5" GH_PROBE_TIMEOUT=5)"
if [ "$(field "$OUT" RC)" = 3 ]; then ok "401 -> rc=3 PERMANENT"; else bad "401 -> rc=$(field "$OUT" RC) (want 3): $OUT"; fi

echo ""
echo "6. a ZERO/invalid bound is refused as a bound and replaced"
B6="$T/b6"; mk_gh "$B6" ok
OUT="$(run_probe "$B6" GH_PROBE_TIMEOUT=0)"
case "$OUT" in *"is not a positive whole number"*) ok "GH_PROBE_TIMEOUT=0 warns that a zero bound is NO bound" ;; *) bad "GH_PROBE_TIMEOUT=0 was accepted silently: $OUT" ;; esac
if [ "$(field "$OUT" RC)" = 0 ]; then ok "the replaced bound still lets a healthy probe succeed"; else bad "the replaced bound broke a healthy probe: $OUT"; fi

echo ""
echo "7. SENSITIVITY — the same driver against an UNBOUNDED probe must hang"
MUT="$T/mutant.sh"
sed 's|terr="$(gh_probe_bounded "$bound" gh auth token 2>&1 >/dev/null)"|terr="$(gh auth token 2>\&1 >/dev/null)"|' \
  "$EXTRACT" > "$MUT"
if cmp -s "$EXTRACT" "$MUT"; then
  bad "the mutation did not apply — case 7 cannot prove the bound is what prevents the stall"
else
  # A watchdog, not `timeout`: the mutant must be given a real chance to hang, and its liveness is
  # what proves it did. Same subshell + `.` sourcing as run_probe (no spawned interpreter).
  (
    unset GH_TOKEN GITHUB_TOKEN
    GH_PROBE_TIMEOUT=2; export GH_PROBE_TIMEOUT
    PATH="$B2:$PATH"; export PATH
    cd "$T" || exit 1
    . ./mutant.sh
    gh_probe_env
    echo "returned rc=$?"
  ) > "$T/mut.out" 2>&1 &
  mpid=$!
  mpid=$!
  i=0
  while [ "$i" -lt 12 ] && kill -0 "$mpid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  if kill -0 "$mpid" 2>/dev/null; then
    hang=1; kill -9 "$mpid" 2>/dev/null
  else
    hang=0
  fi
  wait "$mpid" 2>/dev/null
  if [ "$hang" = 1 ]; then
    ok "the unbounded mutant HANGS (killed at 12s) — case 2's bound is what prevents the stall"
  else
    bad "the unbounded mutant returned (output: $(cat "$T/mut.out")) — case 2 is not measuring a bound"
  fi
fi

echo ""
printf '%s\n' "----------------------------------------"
if [ "$failures" -eq 0 ]; then
  printf '✅ gh-probe-bound: %d checks passed\n' "$checks"
  exit 0
fi
printf '❌ gh-probe-bound: %d of %d checks FAILED\n' "$failures" "$checks"
exit 1
