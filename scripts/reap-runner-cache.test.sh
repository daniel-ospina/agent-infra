#!/usr/bin/env bash
# reap-runner-cache.test.sh — the `runner-cache` class (agent-infra#4168) and the arms that make it safe.
#
# Run: bash scripts/reap-runner-cache.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ EVERY CASE IS MUTATION-CHECKED, on the rule this repo already applies to the #2542 classes: a test
# that passes against a broken script proves nothing, so each case runs TWICE — once against the real
# file (must PASS) and once against a MUTANT of that file with the case's own arm neutered (must FAIL).
# If a mutation cannot be applied (the source line moved), the suite says so and counts it a failure: a
# stale mutation is a case that has silently stopped checking anything.
#
# COVERAGE — the four arms the brief names, one case each:
#   A  TWO INSTALLS, one with a job in flight and one idle → the idle `.cache` is REAPED, the live one
#      is SKIPPED WHOLE and named (`skipped-live`). This is the class's one correctness property: a
#      cache deleted under a live job fails the job.
#      Mutant: `if [ "$live" = 0 ]; then` -> `if false; then` (the skip arm deleted).
#   B  NO CHURN: a cache below the size bound and scratch younger than the age bound are BOTH KEPT and
#      named, and nothing is removed — while an aged entry in the same install IS reaped, so the two
#      gates are shown to be the only difference.
#      Mutant: `elif [ -n "$sz" ] && [ "$sz" -lt "$MIN_CACHE_MB" ]; then` -> `elif false; then`.
#   C  THE SIZE TRIGGER, BOTH DIRECTIONS, through `disk-reaper.sh`: above the threshold NO class runs
#      (the record says `not-run`, with the reading it took), below it the class runs; and a pass
#      STOPS at the per-pass cap, leaving the remaining candidates for the next tick.
#      Mutant: `[ "$mb" -lt "$RUNNER_CACHE_TRIGGER_FREE_MB" ]` -> `[ "$mb" -gt … ]` (the trigger
#      inverted) — the "it fired" assertion reddens. The cap is mutated separately.
#   D  AN UNREADABLE PROCESS CENSUS REMOVES NOTHING and exits 3: an install's liveness cannot be proved,
#      so neither its cache nor its scratch may go.
#      Mutant: `if [ "$CENSUS" != "ok" ]; then LIVE_REASON="census-unreadable"; return 2; fi` -> deleted.
#
# Hermetic: every fixture is under $T, HOME is redirected, the state dir and the install globs are
# explicit `$T/...` paths, and the process census is a FIXTURE TABLE — NOTHING here can read or delete
# the real box's `/opt/gh-runner-*`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER="$HERE/reap-runner-cache.sh"
REAPER="$HERE/disk-reaper.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
CASE_FAIL=0
case_check() { # <0|1> <message>
    if [ "$1" = 0 ]; then printf '     · %s\n' "$2"; return 0; fi
    printf '     ✗ %s\n' "$2"; CASE_FAIL=$((CASE_FAIL + 1)); return 1
}
expect_pass() { local l="$1"; shift; if ( CASE_FAIL=0; "$@" ); then ok "$l"; else bad "$l"; fi; }
expect_fail() { local l="$1"; shift
    if ( CASE_FAIL=0; "$@" ); then bad "$l — MUTANT SURVIVED: the arm is not covered by this case"
    else ok "$l"; fi; }

for f in "$OWNER" "$REAPER"; do
    [ -f "$f" ] || { printf 'FATAL: %s missing — this suite tests the runner-cache class and its owner\n' "$f"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/rrc-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

# ⛔ THE BOX'S OWN HARNESS ENV MUST NOT LEAK IN: a present-but-wrong `DISK_REAPER_*` would make a case
# fail for the box's reason rather than the code's.
unset DISK_REAPER_ONLY DISK_REAPER_REPOS DISK_REAPER_RUNNER_CACHE_GLOBS \
      DISK_REAPER_RUNNER_CACHE_SHARED_GLOBS DISK_REAPER_RUNNER_CACHE_MIN_MB \
      DISK_REAPER_RUNNER_CACHE_TRIGGER_FREE_MB DISK_REAPER_RUNNER_CACHE_PASS_CAP_MB \
      REAP_RC_GLOBS REAP_RC_SHARED_GLOBS REAP_RC_MIN_CACHE_MB REAP_RC_PS_BIN 2>/dev/null || true
export HOME="$T/home"; mkdir -p "$HOME"

# apply_mutation <src> <dest> <sed-expression> — write the mutant; FAIL LOUDLY when nothing changed.
apply_mutation() {
    local src="$1" dest="$2" expr="$3"
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$HERE/lib" "$(dirname "$dest")/lib"
    sed "$expr" "$src" >"$dest" 2>/dev/null || return 1
    cmp -s "$src" "$dest" && return 1              # the expression matched nothing: a STALE mutation
    bash -n "$dest" 2>/dev/null || return 1        # a syntax error is not a mutation of behaviour
    chmod +x "$dest"
    return 0
}

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────
# mk_install <dir> — a minimal runner INSTALL: the marker `bin/Runner.Listener` is what makes a directory
# an install (the class never trusts the glob alone).
mk_install() {
    mkdir -p "$1/bin" "$1/_work/_temp" "$1/_diag"
    : >"$1/bin/Runner.Listener"
}
# mk_cache <install> <mb> — `mb` MiB of real bytes under <install>/.cache (0 = an empty cache dir).
mk_cache() {
    mkdir -p "$1/.cache/uv"
    if [ "${2:-0}" -gt 0 ]; then
        dd if=/dev/zero of="$1/.cache/uv/blob" bs=1M count="$2" >/dev/null 2>&1
    else
        : >"$1/.cache/uv/blob"
    fi
}
# idle_work <install> — make the install's `_work` read IDLE. ⛔ THE FIXTURE MUST BE GENUINELY IDLE:
# the class treats a listener PLUS content written under `_work` inside the freshness window as "a job
# is running" (the conservative direction the brief asks for), and `mk_install` creates `_work/_temp`
# just now — so an un-aged fixture is live for 15 minutes and every reap assertion would be vacuous.
# Only the `_temp` DIRECTORY is aged (that is what `newest_mtime_under` reads); the files keep their own
# mtimes, which is what the age gates read.
idle_work() {
    age_path "$1/_work/_temp" 1
    age_path "$1/_diag" 1
}
age_path() { # <path> <days>
    local when=$(( $(date +%s) - $2 * 86400 - 3600 ))
    touch -d "@$when" "$1" 2>/dev/null \
        || touch -t "$(date -r "$when" +%Y%m%d%H%M 2>/dev/null || printf 202001010000)" "$1" 2>/dev/null || true
}
# mk_ps <file> <install> live|idle — a FIXTURE process table. `live` carries a Runner.Worker (the
# decisive witness: Actions spawns one per job), `idle` carries only the listener.
mk_ps() {
    : >"$1"
    printf '  4242 %s/bin/Runner.Listener run --startuptype service\n' "$2" >>"$1"
    [ "$3" = live ] && printf '  4243 %s/bin/Runner.Worker spawnclient 42 43\n' "$2" >>"$1"
    return 0
}
# ps_stub — ONE stub that `cat`s the table named by $RC_TEST_PS_TABLE, so the owner's `ps -axo
# pid=,command=` call is answered by a fixture and never by the box.
PS_STUB="$T/ps-stub"
cat >"$PS_STUB" <<'STUB'
#!/bin/sh
cat "$RC_TEST_PS_TABLE"
STUB
chmod +x "$PS_STUB"

# run_owner <owner> <fixture-base> <ps-table> [extra args…] — prints the owner's output.
run_owner() {
    local owner="$1" base="$2" table="$3"; shift 3
    RC_TEST_PS_TABLE="$table" REAP_RC_PS_BIN="$PS_STUB" \
    REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
    REAP_RC_SHARED_GLOBS="$base/no-shared" \
    REAP_RC_STATE_DIR="$base/state" \
    bash "$owner" "$@" 2>&1
}

# ── A: a live install is SKIPPED WHOLE, the idle one is reaped ───────────────────────────────────
case_a() { # <owner-script>
    local owner="$1" base live idle out rc
    base="$(mktemp -d "$T/a.XXXXXX")"
    live="$base/gh-runner-live"; idle="$base/gh-runner-idle"
    mk_install "$live"; mk_install "$idle"
    mk_cache "$live" 2; mk_cache "$idle" 2
    idle_work "$live"; idle_work "$idle"
    # BOTH tables are fresh enough to reap; the ONLY difference is the Runner.Worker line.
    mk_ps "$base/ps" "$live" live
    printf '  4244 %s/bin/Runner.Listener run\n' "$idle" >>"$base/ps"
    out="$(run_owner "$owner" "$base" "$base/ps" --apply --min-cache-mb 1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$live/.cache" ] && echo 0 || echo 1)" "the install with a JOB IN FLIGHT kept its cache"
    case_check "$(grep -qF "SKIPPED-LIVE $live" <<<"$out" && echo 0 || echo 1)" \
               "and it is SKIPPED BY NAME (SKIPPED-LIVE $live)"
    case_check "$(grep -qF 'reason=skipped-live:worker-running' <<<"$out" && echo 0 || echo 1)" \
               "the skip NAMES the witness (worker-running), not just a verdict"
    case_check "$([ ! -e "$idle/.cache" ] && echo 0 || echo 1)" \
               "an IDENTICAL idle install in the same run HAD its cache reaped (the witness is the only difference)"
    case_check "$(grep -qF "REAPED $idle/.cache" <<<"$out" && echo 0 || echo 1)" "and the reap is reported with its path"
    # The reading an operator needs (#2344): per-install cache MB and the live verdict, on the summary.
    case_check "$(grep -qE 'SUMMARY class=runner-cache .*skipped_live=1' <<<"$out" && echo 0 || echo 1)" \
               "the SUMMARY carries skipped_live=1 (the count, not only the row)"
    case_check "$(grep -qE "INSTALL $live cache_mb=2 live=yes" <<<"$out" && echo 0 || echo 1)" \
               "and the per-install READING is printed (cache_mb=… live=yes)"
    return $((CASE_FAIL > 0))
}

# ── B: NO CHURN — a small cache and young scratch are KEPT, aged scratch is reaped ───────────────
case_b() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/b.XXXXXX")"
    inst="$base/gh-runner-b"
    mk_install "$inst"
    mk_cache "$inst" 0                       # 0 MB: below the DEFAULT size bound (256 MB)
    printf 'young\n' >"$inst/_work/_temp/step.sh"
    printf 'old\n'   >"$inst/_work/_temp/old-step.sh"; age_path "$inst/_work/_temp/old-step.sh" 9
    printf 'young\n' >"$inst/_diag/Runner_1.log"
    idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    out="$(run_owner "$owner" "$base" "$base/ps" --apply --scratch-days 7 --log-days 7)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$inst/.cache" ] && echo 0 || echo 1)" \
               "a cache BELOW the size bound is NOT reclaimed (no re-download for no space)"
    case_check "$(grep -qF 'reason=below-min-cache' <<<"$out" && echo 0 || echo 1)" \
               "and it is KEPT BY NAME with the reason (reason=below-min-cache)"
    case_check "$([ -f "$inst/_work/_temp/step.sh" ] && echo 0 || echo 1)" \
               "scratch YOUNGER than the age bound is NOT reclaimed"
    case_check "$(grep -qF 'reason=too-young' <<<"$out" && echo 0 || echo 1)" "and it is named (reason=too-young)"
    case_check "$([ -f "$inst/_diag/Runner_1.log" ] && echo 0 || echo 1)" "a young _diag log is NOT reclaimed"
    case_check "$([ ! -f "$inst/_work/_temp/old-step.sh" ] && echo 0 || echo 1)" \
               "an AGED scratch entry in the SAME install WAS reaped (the age gate is the only difference)"
    return $((CASE_FAIL > 0))
}

# ── C: the SIZE TRIGGER (both directions) and the PER-PASS CAP, through the entry point ─────────
case_c() { # <reaper> <owner-script>
    local reaper="$1" owner="$2" base inst_a inst_b out rc rec
    base="$(mktemp -d "$T/c.XXXXXX")"
    inst_a="$base/gh-runner-a"; inst_b="$base/gh-runner-b"
    mk_install "$inst_a"; mk_install "$inst_b"
    mk_cache "$inst_a" 2; mk_cache "$inst_b" 2
    idle_work "$inst_a"; idle_work "$inst_b"
    mk_ps "$base/ps" "$inst_a" idle
    printf '  4244 %s/bin/Runner.Listener run\n' "$inst_b" >>"$base/ps"
    # ── (1) ABOVE the threshold: NOT FIRED, and no class runs ────────────────────────────────────
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           DISK_REAPER_STATE_DIR="$base/s-low" \
           DISK_REAPER_RUNNER_CACHE_GLOBS="$base/gh-runner-*" \
           DISK_REAPER_RUNNER_CACHE_SHARED_GLOBS="$base/no-shared" \
           DISK_REAPER_RUNNER_CACHE_MIN_MB=1 \
           DISK_REAPER_RUNNER_CACHE_TRIGGER_FREE_MB=1 \
           RUNNER_CACHE_REAPER="$owner" \
           bash "$reaper" --apply --size-trigger 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'C1 rc=%s\n%s\n' "$rc" "$out" >&2
    rec="$(cat "$base/s-low/disk-reaper-cache.status" 2>/dev/null)"
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "above the threshold the pass exits 0 (rc=$rc)"
    case_check "$(grep -qF 'size-trigger NOT fired' <<<"$out" && echo 0 || echo 1)" \
               "it says the trigger did not fire"
    case_check "$(grep -qE 'size-trigger NOT fired.*free=.*threshold_mb=1' <<<"$out" && echo 0 || echo 1)" \
               "and prints the READING it used (free=… threshold_mb=1) — a gate that acts without the number it read is a wish (#2344)"
    case_check "$(grep -qF 'verdict_runner_cache=not-run' <<<"$rec" && echo 0 || echo 1)" \
               "and the record says the class did NOT run (not-run), never a measured zero"
    case_check "$([ -d "$inst_a/.cache" ] && echo 0 || echo 1)" "nothing was reclaimed while above the threshold"
    # ── (2) BELOW the threshold: FIRES, and the per-pass CAP stops it after one install ─────────
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           DISK_REAPER_STATE_DIR="$base/s-high" \
           DISK_REAPER_RUNNER_CACHE_GLOBS="$base/gh-runner-*" \
           DISK_REAPER_RUNNER_CACHE_SHARED_GLOBS="$base/no-shared" \
           DISK_REAPER_RUNNER_CACHE_MIN_MB=1 \
           DISK_REAPER_RUNNER_CACHE_TRIGGER_FREE_MB=999999999 \
           DISK_REAPER_RUNNER_CACHE_PASS_CAP_MB=3 \
           RUNNER_CACHE_REAPER="$owner" \
           bash "$reaper" --apply --size-trigger 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'C2 rc=%s\n%s\n' "$rc" "$out" >&2
    rec="$(cat "$base/s-high/disk-reaper-cache.status" 2>/dev/null)"
    case_check "$(grep -qF 'size-trigger FIRED' <<<"$out" && echo 0 || echo 1)" "below the threshold the trigger FIRES"
    case_check "$(grep -qE 'capped=1' <<<"$out" && echo 0 || echo 1)" "and the pass reports that it hit the per-pass cap (capped=1)"
    case_check "$(grep -qF 'reason=pass-cap' <<<"$out" && echo 0 || echo 1)" "the candidate it did not reach is NAMED (reason=pass-cap)"
    case_check "$([ "$(grep -c '^REAPED ' <<<"$out")" = 1 ] && echo 0 || echo 1)" \
               "exactly ONE 2MB cache was reclaimed against a 3MB cap (the second would have exceeded it)"
    case_check "$([ -e "$inst_a/.cache" ] || [ -e "$inst_b/.cache" ] && echo 0 || echo 1)" \
               "the OTHER install's cache SURVIVED the capped pass (the next tick continues)"
    case_check "$(grep -qE 'capped_runner_cache=1' <<<"$rec" && echo 0 || echo 1)" "and the RECORD carries capped_runner_cache=1"
    case_check "$(grep -qF 'freed_mb_runner_cache=' <<<"$rec" && echo 0 || echo 1)" "with the freed figure in the same record"
    return $((CASE_FAIL > 0))
}

# ── D: an UNREADABLE census removes NOTHING and fails closed ─────────────────────────────────────
case_d() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/d.XXXXXX")"
    inst="$base/gh-runner-d"
    mk_install "$inst"; mk_cache "$inst" 2
    printf 'old\n' >"$inst/_work/_temp/step.sh"; age_path "$inst/_work/_temp/step.sh" 9
    idle_work "$inst"
    out="$(REAP_RC_PS_BIN=/nonexistent/ps \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_MIN_CACHE_MB=1 \
           REAP_RC_SCRATCH_DAYS=7 REAP_RC_LOG_DAYS=7 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "an unreadable process census FAILS CLOSED (rc=$rc, want 3)"
    case_check "$(grep -qF 'census=unreadable' <<<"$out" && echo 0 || echo 1)" "and the census state is named (census=unreadable)"
    case_check "$([ -d "$inst/.cache" ] && echo 0 || echo 1)" "NOTHING was removed: the cache is still there"
    case_check "$([ -f "$inst/_work/_temp/step.sh" ] && echo 0 || echo 1)" "and neither was the aged scratch"
    case_check "$(grep -qF 'reason=census-unreadable' <<<"$out" && echo 0 || echo 1)" \
               "the install is KEPT BY NAME with the reason (reason=census-unreadable)"
    return $((CASE_FAIL > 0))
}

# ── mutations ─────────────────────────────────────────────────────────────────────────────────
MUT_A="$T/mut-a.sh"; MUT_B="$T/mut-b.sh"; MUT_C="$T/mut-c.sh"; MUT_C2="$T/mut-c2.sh"; MUT_D="$T/mut-d.sh"
mut_ok=1
apply_mutation "$OWNER" "$MUT_A" 's/^    if \[ "\$live" = 0 \]; then$/    if false; then/' \
    || { printf '  ❌ mutation A could not be applied (the skip-live arm moved) — that case now covers nothing\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_B" 's/^        elif \[ -n "\$sz" \] && \[ "\$sz" -lt "\$MIN_CACHE_MB" \]; then$/        elif false; then/' \
    || { printf '  ❌ mutation B could not be applied (the size bound moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_D" 's/^    if \[ "\$CENSUS" != "ok" \]; then LIVE_REASON="census-unreadable"; return 2; fi$/    :/' \
    || { printf '  ❌ mutation D could not be applied (the census gate moved)\n'; mut_ok=0; }
apply_mutation "$REAPER" "$MUT_C" 's/\[ "\$mb" -lt "\$RUNNER_CACHE_TRIGGER_FREE_MB" \] && low=1/[ "$mb" -gt "$RUNNER_CACHE_TRIGGER_FREE_MB" ] \&\& low=1/' \
    || { printf '  ❌ mutation C could not be applied (the trigger comparison moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_C2" 's/^    \[ "\$(( FREED_MB + pending ))" -gt "\$MAX_MB" \]$/    false/' \
    || { printf '  ❌ mutation C2 could not be applied (the cap test moved)\n'; mut_ok=0; }

printf '── ran with %s ──\n' "${BASH_VERSION%%(*}"
expect_pass "A a live install is SKIPPED and the idle one is reaped" case_a "$OWNER"
expect_pass "B a small cache and young scratch are KEPT; aged scratch is reaped" case_b "$OWNER"
expect_pass "C the size trigger fires only below the threshold, and a pass is capped" case_c "$REAPER" "$OWNER"
expect_pass "D an unreadable census removes nothing and fails closed" case_d "$OWNER"

printf '\n── mutations: each arm must redden the case that covers it ──\n'
[ "$mut_ok" = 1 ] || bad "one or more mutations could not be applied (see above)"
expect_fail "A mutant: the skip-live arm deleted"                      case_a "$MUT_A"
expect_fail "B mutant: the size bound deleted"                         case_b "$MUT_B"
expect_fail "C mutant: the trigger comparison inverted"                case_c "$MUT_C" "$OWNER"
expect_fail "C2 mutant: the per-pass cap never reached"                case_c "$REAPER" "$MUT_C2"
expect_fail "D mutant: the census gate deleted"                        case_d "$MUT_D"

printf '\n── the owner never removes anything it was not asked to ──\n'
# ⛔ A SCOPE CASE, not a policy one: the owner is handed a tree that contains an install AND an
# unrelated neighbour, and must leave the neighbour alone. It is the shape the family has already been
# bitten by (`REAPED …/gh-runner-x//bin`, a seam one component short).
case_scope() {
    local base outer out rc
    base="$(mktemp -d "$T/e.XXXXXX")"
    outer="$base/not-a-runner"; mkdir -p "$outer/.cache/keep"; printf 'x\n' >"$outer/.cache/keep/f"
    mk_install "$base/gh-runner-ok"; mk_cache "$base/gh-runner-ok" 2; idle_work "$base/gh-runner-ok"
    mk_ps "$base/ps" "$base/gh-runner-ok" idle
    # The glob matches the NEIGHBOUR too; only a marker-carrying install may be reaped.
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/*" REAP_RC_EXPLICIT=1 REAP_RC_SHARED_GLOBS="$base/no-shared" \
           REAP_RC_MIN_CACHE_MB=1 REAP_RC_STATE_DIR="$base/state" \
           bash "$OWNER" --apply 2>&1)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$outer/.cache/keep" ] && echo 0 || echo 1)" \
               "a directory matched by the glob but WITHOUT the install marker is untouched"
    case_check "$([ ! -e "$base/gh-runner-ok/.cache" ] && echo 0 || echo 1)" \
               "while the real install in the same run WAS reaped"
    return $((CASE_FAIL > 0))
}
expect_pass "E only a directory carrying bin/Runner.Listener is ever touched" case_scope

printf '\n──────────────────────────────\n'
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
