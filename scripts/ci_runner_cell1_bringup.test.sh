#!/usr/bin/env bash
# ci_runner_cell1_bringup.test.sh — hermetic guards for ci_runner_cell1_bringup.sh.
#
# It asserts the REFUSALS, because each one is a failure that already happened on a real box:
#   · disk below the floor  → the exact state that killed both cell-1 listeners (ENOSPC, 15:22:51Z)
#   · awk not GNU awk       → mawk 1.3.4's `REcompile() - panic` turned a green step FALSE RED (#2637)
#   · an install with no .runner → starting it registers nothing and serves nothing (#2502)
#   · a listener already live    → a second listener on ONE install double-claims jobs
# A guard nobody can demonstrate refusing is a wish with a semicolon, so every case runs the real
# script and reads its exit code — never a reimplementation of its logic.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/ci_runner_cell1_bringup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '   ❌ %s\n' "$1"; }
expect_rc() { # <want> <got> <label>
  [ "$1" = "$2" ] && ok "$3 (rc=$2)" || bad "$3 — wanted rc=$1, got rc=$2"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root" "$TMP/bin"
# A stub gh: `--version` is not used; every read is answered from env so the test never touches GitHub.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_GH_OUT:-}" ; exit "${FAKE_GH_RC:-0}"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export CI_RUNNER_ROOT="$TMP/root" CI_RUNNER_PREFIX=fake CI_RUNNER_REPO=o/r

# 1. list mode reads only the artifact and never starts anything
out="$(FAKE_GH_OUT=$'21\tfake-1\tonline\tbusy=true\tself-hosted' "$SUT" --status 2>&1)"; rc=$?
expect_rc 0 "$rc" "status mode succeeds"
printf '%s' "$out" | grep -q 'fake-1' && ok "status prints the runner row" || bad "status did not print the runner row"

# 2. disk floor: ROOT on a filesystem we cannot fake — pin the floor ABOVE what the box has
out="$(FAKE_GH_OUT='' CI_RUNNER_DISK_MIN_GB=100000 "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "disk below the floor REFUSES"
printf '%s' "$out" | grep -q 'why=disk-below-floor' && ok "disk refusal names the reason" || bad "disk refusal did not name the reason"

# 3. memory floor: same shape, on the memory arm (#2387)
out="$(FAKE_GH_OUT='' CI_RUNNER_MEM_MIN_MB=10000000 "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "memory below the floor REFUSES"
printf '%s' "$out" | grep -q 'why=mem-below-floor' && ok "memory refusal names the reason" || bad "memory refusal did not name the reason"

# 4. a guard that fails OPEN is no guard: with both floors cleared, the awk arm must still refuse
#    when awk is not gawk. CI_RUNNER_AWK pins the probe so this runs on a gawk box too.
out="$(FAKE_GH_OUT='' CI_RUNNER_DISK_MIN_GB=0 CI_RUNNER_MEM_MIN_MB=0 CI_RUNNER_AWK_VERSION='mawk 1.3.4 20240123' "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "awk that is not GNU awk REFUSES (#2637)"
printf '%s' "$out" | grep -q 'why=awk-not-gawk' && ok "awk refusal names the reason" || bad "awk refusal did not name the reason"

# 5. an install with no .runner is refused, never "started"
mkdir -p "$TMP/root/fake-1"
out="$(FAKE_GH_OUT='' CI_RUNNER_DISK_MIN_GB=0 CI_RUNNER_MEM_MIN_MB=0 "$SUT" 2>&1)"; rc=$?
expect_rc 3 "$rc" "install with no .runner REFUSES"
printf '%s' "$out" | grep -q 'why=not-configured' && ok "unconfigured refusal names the reason" || bad "unconfigured refusal did not name the reason"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
