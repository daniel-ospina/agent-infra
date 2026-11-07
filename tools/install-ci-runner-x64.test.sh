#!/usr/bin/env bash
# install-ci-runner-x64.test.sh — the adapter's contract, proven against a FAKE pool tool.
#
# ⛔ NO REAL REGISTRATION IS EVER MADE HERE. `CI_RUNNER_POOL_TOOL` points at a fixture that records
# its argv and exits with a chosen code, so the properties that matter — "a guard refusal propagates
# as a refusal", "an existing slot is not added twice", "the slot NAME is the one the caller's
# `_next_free_slot` derives" and "the LAST line of the MERGED stream is the accounting" — are tested
# without a token, a network, or a live runner. A test that registers a real runner on the host it
# runs on is how this fleet got leaked launchd units and 26-hour orphan controllers (#3430).
#
# The invariants here are not stylistic: each case is a way the adapter can provision runners that
# `runner_autoscale.py` cannot count, or record a correct refusal as a failure — see the adapter's
# header for the four facts from the caller that each one pins.
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
SUT=$HERE/install-ci-runner-x64.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/install-ci-runner-x64.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

# The host's own runner environment must not decide the outcome of a test.
unset RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT RUNNER_AUTOSCALE_BASE RUNNER_NAME_PREFIX

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# check <label> <expected-rc> <actual-rc> [expected-substring] [haystack]
check() {
  local label=$1 want=$2 got=$3 sub=${4:-} hay=${5:-}
  if [ "$want" != "$got" ]; then bad "$label (rc want=$want got=$got)"; return; fi
  if [ -n "$sub" ] && ! printf '%s' "$hay" | grep -qF -- "$sub"; then
    bad "$label (missing '$sub' in: $(printf '%s' "$hay" | tr '\n' '|' | cut -c1-140))"; return
  fi
  ok "$label"
}

# fake_pool <rc> — a pool tool that logs its argv and exits rc, printing a reading/refusal line.
fake_pool() {
  local rc=$1 body=$TMP/fake-pool.sh
  cat > "$body" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
printf 'fake: mem_floor_mb=3584 reading_mb=2210 %s\n' "\${FAKE_NOTE:-}"
exit $rc
EOF
  chmod +x "$body"
  printf '%s\n' "$body"
}

: > "$TMP/calls.log"
# A correctly-configured box names the SAME root to both tools: `RUNNER_ROOT` is what the pool tool
# installs under, `RUNNER_AUTOSCALE_RUNNER_ROOT` is what the caller inventories. Cases 15 and 16 are
# the ones that make them disagree on purpose.
export RUNNER_ROOT=$TMP/root
export RUNNER_AUTOSCALE_RUNNER_ROOT=$TMP/root
mkdir -p "$RUNNER_ROOT"

# 1. --count required
out=$(bash "$SUT" 2>&1); rc=$?
check "missing --count is a usage error" 1 "$rc" "usage:" "$out"

# 2. leading-zero count is refused, not silently re-read as octal or as false
out=$(bash "$SUT" --count 08 --fallback auto 2>&1); rc=$?
check "leading-zero count -> refusal" 2 "$rc" "cannot-measure why=count-not-a-positive-integer" "$out"

# 3. a strategy other than auto is refused rather than ignored
out=$(bash "$SUT" --count 2 --fallback manual 2>&1); rc=$?
check "unsupported --fallback refused" 1 "$rc" "unsupported --fallback" "$out"

# 4. an unreadable pool tool is a REFUSAL (the original defect, in its smallest form)
out=$(CI_RUNNER_POOL_TOOL=$TMP/nope.sh bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "unreadable pool tool -> refusal naming the path" 2 "$rc" "why=pool-tool-unreadable" "$out"

# 5. the pool tool's rc=2 (cannot-measure / cannot-act) propagates as a REFUSAL
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 2) bash "$SUT" --count 2 --fallback auto 2>&1); rc=$?
check "pool cannot-measure (rc=2) propagates as a refusal" 2 "$rc" "guard-refused" "$out"

# 6. ⛔ THE POOL TOOL'S GATE VERDICTS ARE rc=3, NOT rc=2 (`REFUSED add … nothing added`: the memory
# floor and the core-aware ceiling — the COMMON verdict on a box already at its limit). Mapping only
# rc=2 recorded a correct refusal as a hard failure on every pass (#3469's shape).
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 3) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "pool gate REFUSAL (rc=3) propagates as a refusal" 2 "$rc" "guard-refused" "$out"
calls=$(wc -l < "$TMP/calls.log" | tr -d ' ')
check "refusal stops the loop (1 attempt, not 2)" 1 "$calls"

# 7. any other rc propagates verbatim — a real failure is never reported as a refusal
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 7) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "hard failure propagates its own rc" 7 "$rc" "rc=7" "$out"

# 8. slot 1 is the caller's BASE name — `_next_free_slot` numbers it `gh-runner-x64`, never
# `gh-runner-x64-1`, so a `-1` suffix leaves the caller's slot #1 permanently free.
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "success exit 0" 0 "$rc" "provisioned slot=1 name=gh-runner-x64 root=$RUNNER_ROOT added=1" "$out"
calls=$(tr '\n' '|' < "$TMP/calls.log")
check "slot 1 is requested under the base name" 0 0 "add --name gh-runner-x64|" "$calls"

# 9. ⛔ `--count N` IS A SLOT INDEX, NOT A TOTAL: the caller passes `_next_free_slot`, so ONE call is
# at most ONE addition. A cumulative "make 1..N exist" sweep puts several runners on a box whose
# per-step memory/disk re-read budgeted one.
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 3 --fallback auto 2>&1); rc=$?
check "slot 3 derived from the index" 0 "$rc" "name=gh-runner-x64-3 root=$RUNNER_ROOT added=1" "$out"
calls=$(tr '\n' '|' < "$TMP/calls.log")
check "slot 3 asks for exactly one name" 0 0 "add --name gh-runner-x64-3|" "$calls"
case "$calls" in *gh-runner-x64-1*|*gh-runner-x64-2*) bad "a slot index swept lower slots into the same call";; *) ok "one call = one addition";; esac

# 10. ⛔ THE PASS RECORD IS THE LAST LINE OF THE *MERGED* STREAM (`_run` concatenates stdout then
# stderr), so the accounting must be last and stderr must be silent on the success path.
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 2 --fallback auto 2>&1)
lastline=$(printf '%s\n' "$out" | tail -1)
case "$lastline" in
  "provisioned slot=2 name=gh-runner-x64-2 root=$RUNNER_ROOT added=1"*) ok "the merged last line is the accounting";;
  *) bad "the merged last line is not the accounting: $(printf '%s' "$lastline" | cut -c1-120)";;
esac

# 11. IDEMPOTENCY: an existing install is skipped, not added a second time (the #9639 over-fill)
mkdir -p "$RUNNER_ROOT/gh-runner-x64"; : > "$RUNNER_ROOT/gh-runner-x64/.runner"
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "existing slot skipped, still exit 0" 0 "$rc" "provisioned slot=1 name=gh-runner-x64 root=$RUNNER_ROOT added=0 skipped=1" "$out"
calls=$(wc -l < "$TMP/calls.log" | tr -d ' ')
check "no add beside an existing install" 0 "$calls"

# 12. --dry-run reaches the pool tool and does not claim to have provisioned
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 2 --fallback auto --dry-run 2>&1); rc=$?
calls=$(tr '\n' '|' < "$TMP/calls.log")
check "--dry-run is passed through" 0 0 "add --name gh-runner-x64-2 --dry-run|" "$calls"
check "a dry run does not report a provision" 0 "$rc" "would-provision slot=2" "$out"

# 13. a base OUTSIDE the root is uncountable by `discover()` — refused, not installed blind
out=$(RUNNER_AUTOSCALE_BASE=$TMP/elsewhere/gh-runner-x64 CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "base outside the caller's root -> refusal" 2 "$rc" "why=base-outside-root" "$out"

# 14. a base that does not start with `gh-runner` is invisible to `discover()` — refused
out=$(RUNNER_AUTOSCALE_BASE=$RUNNER_ROOT/pi-runner-x64 CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "base not discoverable as gh-runner* -> refusal" 2 "$rc" "why=base-not-discoverable" "$out"

# 15. the root FOLLOWS the caller when only the caller's knob is set (`provision()` passes no root)
out=$(env -u RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT=$TMP/root2 CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "root follows RUNNER_AUTOSCALE_RUNNER_ROOT" 0 "$rc" "root=$TMP/root2 added=1" "$out"

# 16. two different roots is a box that provisions what the caller cannot count — refused
out=$(RUNNER_ROOT=$TMP/root RUNNER_AUTOSCALE_RUNNER_ROOT=$TMP/other CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "disagreeing roots -> refusal" 2 "$rc" "why=root-disagreement" "$out"

printf '\n%s\n' "install-ci-runner-x64: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
