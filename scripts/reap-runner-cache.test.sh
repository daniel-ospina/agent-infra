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
#   F  THE PROBE IS RE-ASKED, PER INSTALL: a job that STARTS during the pass is caught by the re-probe and
#      the cache is kept (`reason=toctou:worker-running`). The census fixture ANSWERS DIFFERENTLY on the
#      second call, which is the only way to tell a re-probe from a frozen table.
#      Mutant: `census_refresh() { census_read; }` -> `{ :; }` (the refresh stops re-reading).
#   G  THE SAME PROPERTY FOR THE SHARED PER-BOX CACHE ROOT, which no row covered at all: the entry is
#      kept when an install starts a job mid-pass. Same mutant (the shared arm asks the population
#      question through the same refresh).
#   H  A RE-PROBE THAT CANNOT ANSWER KEEPS THE CANDIDATE and the pass fails closed (rc 3) — the arm that
#      replaces the unreachable `_live = 2` branch. Same mutant.
#   I  A CANDIDATE BIGGER THAN THE WHOLE PER-PASS CAP IS STILL TAKEN (once), and the cap still bounds the
#      pass afterwards; the measured population is 21–50 GB against a 20 GB default, so refusing it is
#      an inert enforcer that never frees the box.
#      Mutant: the oversized-admission guard -> `if false; then`.
#   J  THE `REAP_RC_LOG` SEAM IS HONOURED, not exported-and-ignored: the pass log lands at the pinned
#      path and NOT at the default one, which is what the entry point relies on when the state dir has
#      fallen back to tmpfs.
#      Mutant: `REAP_RC_LOG:-` -> `REAP_RC_LOG_IGNORED:-` (the seam stops being read).
#   E  THE INSTALL MARKER IS THE SCOPE, not the size bound: a directory the glob matches but which
#      carries no `bin/Runner.Listener` is untouched while the real install in the same run is reaped.
#      Its neighbour's cache is ABOVE the size bound on purpose — otherwise `below-min-cache` would
#      protect it and the case would pass for a reason unrelated to the marker (#4169 review, NOTE-3).
#      Mutant: `is_install() { … }` -> `is_install() { true; }`.
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

# ps_seq_stub — a census whose ANSWER CHANGES BETWEEN CALLS. ⛔ This is the only fixture that can observe
# a RE-PROBE: a stub that always answers the same thing cannot tell "the table was re-read" from "the
# frozen copy was consulted", which is exactly the defect #4169's review found in the documented
# `toctou` arm. `$RC_TEST_PS_SEQ` lists one table path per line (call N reads line N, the last repeats),
# and `RC_TEST_PS_FAIL_AFTER=<n>` makes every call after the n-th answer NOTHING (the unreadable arm).
PS_SEQ_STUB="$T/ps-stub-seq"
cat >"$PS_SEQ_STUB" <<'STUB'
#!/bin/sh
n=$(cat "$RC_TEST_PS_SEQ_N" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" >"$RC_TEST_PS_SEQ_N"
if [ "${RC_TEST_PS_FAIL_AFTER:-0}" -gt 0 ] && [ "$n" -gt "${RC_TEST_PS_FAIL_AFTER:-0}" ]; then exit 1; fi
total=$(grep -c . "$RC_TEST_PS_SEQ")
[ "$n" -gt "$total" ] && n="$total"
cat "$(sed -n "${n}p" "$RC_TEST_PS_SEQ")"
STUB
chmod +x "$PS_SEQ_STUB"

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

# ── F: the probe is RE-ASKED per install — a job that STARTS mid-pass keeps its cache ────────
case_f() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/f.XXXXXX")"
    inst="$base/gh-runner-f"
    mk_install "$inst"; mk_cache "$inst" 2; idle_work "$inst"
    # Call 1 (pass start) sees an IDLE install; every call after sees a Runner.Worker — i.e. a job
    # started while the pass was classifying. ⛔ The difference between the two tables is the ONLY thing
    # that can keep the cache, so a frozen census MUST reap it and this case must redden.
    mk_ps "$base/ps-idle" "$inst" idle
    mk_ps "$base/ps-live" "$inst" live
    printf '%s\n%s\n' "$base/ps-idle" "$base/ps-live" >"$base/seq"
    rm -f "$base/n"
    out="$(RC_TEST_PS_SEQ="$base/seq" RC_TEST_PS_SEQ_N="$base/n" REAP_RC_PS_BIN="$PS_SEQ_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply --min-cache-mb 1 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$inst/.cache" ] && echo 0 || echo 1)" \
               "the cache of an install whose job STARTED mid-pass is NOT removed"
    case_check "$(grep -qF 'reason=toctou:worker-running' <<<"$out" && echo 0 || echo 1)" \
               "and the skip NAMES the re-probe and its witness (reason=toctou:worker-running)"
    return $((CASE_FAIL > 0))
}

# ── G: the SHARED per-box cache root gets the same re-probe (the population's question) ──────
case_g() { # <owner-script>
    local owner="$1" base inst shared out rc
    base="$(mktemp -d "$T/g.XXXXXX")"
    inst="$base/gh-runner-g"; shared="$base/shared/_cache"
    mk_install "$inst"; mk_cache "$inst" 0        # below the size bound: this install is not a candidate
    idle_work "$inst"
    mkdir -p "$shared/uv"; dd if=/dev/zero of="$shared/uv/blob" bs=1M count=2 >/dev/null 2>&1
    mk_ps "$base/ps-idle" "$inst" idle
    mk_ps "$base/ps-live" "$inst" live
    printf '%s\n%s\n' "$base/ps-idle" "$base/ps-live" >"$base/seq"
    rm -f "$base/n"
    out="$(RC_TEST_PS_SEQ="$base/seq" RC_TEST_PS_SEQ_N="$base/n" REAP_RC_PS_BIN="$PS_SEQ_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$shared" REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$shared/uv" ] && echo 0 || echo 1)" \
               "a SHARED-root entry is NOT emptied when an install starts a job mid-pass"
    case_check "$(grep -qF 'reason=toctou:worker-running' <<<"$out" && echo 0 || echo 1)" \
               "and the skip NAMES the re-probe (no row covered the shared root before this case)"
    return $((CASE_FAIL > 0))
}

# ── H: a re-probe that CANNOT ANSWER keeps the candidate and fails closed ───────────────────
case_h() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/h.XXXXXX")"
    inst="$base/gh-runner-h"
    mk_install "$inst"; mk_cache "$inst" 2; idle_work "$inst"
    mk_ps "$base/ps-idle" "$inst" idle
    printf '%s\n' "$base/ps-idle" >"$base/seq"
    rm -f "$base/n"
    # Call 1 answers; every later call answers NOTHING — the probe that can no longer prove anything.
    out="$(RC_TEST_PS_FAIL_AFTER=1 RC_TEST_PS_SEQ="$base/seq" RC_TEST_PS_SEQ_N="$base/n" \
           REAP_RC_PS_BIN="$PS_SEQ_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply --min-cache-mb 1 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "a re-probe that cannot answer FAILS CLOSED (rc=$rc, want 3)"
    case_check "$([ -d "$inst/.cache" ] && echo 0 || echo 1)" "and the candidate is KEPT, not removed on a stale reading"
    case_check "$(grep -qF 'reason=toctou-census-unreadable' <<<"$out" && echo 0 || echo 1)" \
               "the arm is REACHABLE and named (reason=toctou-census-unreadable) — it was dead code before"
    return $((CASE_FAIL > 0))
}

# ── I: a candidate BIGGER than the whole cap is still taken (the inert-enforcer shape) ──────────
# ⛔ THE TWO INSTALLS ARE NOT ORDERED ON PURPOSE: `compgen -G` returns matches in filesystem order, not
# lexical order, so an assertion that names WHICH one went first is a flake. The property is
# order-independent in both directions — the oversized cache must be GONE either way, and pre-fix it
# survives either way (refused as `0 + 5 > 3` when it is first; refused after the small one eats the
# cap when it is second). That is what makes this row redden on the pre-fix code deterministically.
case_i() { # <owner-script>
    local owner="$1" base big small out rc
    base="$(mktemp -d "$T/i.XXXXXX")"
    big="$base/gh-runner-big"; small="$base/gh-runner-small"
    mk_install "$big"; mk_install "$small"
    mk_cache "$big" 5; mk_cache "$small" 2
    idle_work "$big"; idle_work "$small"
    mk_ps "$base/ps" "$big" idle
    printf '  4244 %s/bin/Runner.Listener run\n' "$small" >>"$base/ps"
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_MIN_CACHE_MB=1 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply --max-mb 3 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$(grep -qF "REAPED $big/.cache" <<<"$out" && echo 0 || echo 1)" \
               "a 5MB cache against a 3MB cap IS reclaimed — NEVER refused on every tick (the measured 21-50GB population against the 20GB default)"
    case_check "$([ ! -e "$big/.cache" ] && echo 0 || echo 1)" "and it is really gone, not merely reported"
    case_check "$([ "$(grep -c '^REAPED ' <<<"$out")" -le 2 ] && echo 0 || echo 1)" \
               "the cap still bounds the pass (at most the two candidates, never a third tick's work)"
    return $((CASE_FAIL > 0))
}

# ── J: the REAP_RC_LOG seam is HONOURED (the entry point exports it on its fallback path) ──────
# ⛔ An exported seam the owner ignores reads as a seam that does not exist, and on the state-dir
# fallback path — a box with a FULL DISK, i.e. exactly when this class matters — the log then lands in
# `$HOME` instead of the fallback state dir. The sibling owners honour `REAP_RW_LOG`/`REAP_AW_LOG`; the
# three must not disagree about the same fact.
case_j() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/j.XXXXXX")"
    inst="$base/gh-runner-j"
    mk_install "$inst"; mk_cache "$inst" 0; idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" \
           REAP_RC_STATE_DIR="$base/state" REAP_RC_LOG="$base/pinned/own.log" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -f "$base/pinned/own.log" ] && echo 0 || echo 1)" \
               "REAP_RC_LOG is HONOURED: the pass log landed at the pinned path"
    case_check "$(grep -qF 'SUMMARY' "$base/pinned/own.log" 2>/dev/null && echo 0 || echo 1)" \
               "and it carries the SUMMARY (the durable artifact, not an empty file)"
    case_check "$([ ! -e "$base/state/runner-cache-reap.log" ] && echo 0 || echo 1)" \
               "while the default path was NOT used (the seam is not merely ignored)"
    return $((CASE_FAIL > 0))
}

# ── mutations ─────────────────────────────────────────────────────────────────────────────────
MUT_A="$T/mut-a.sh"; MUT_B="$T/mut-b.sh"; MUT_C="$T/mut-c.sh"; MUT_C2="$T/mut-c2.sh"; MUT_D="$T/mut-d.sh"
MUT_E="$T/mut-e.sh"; MUT_F="$T/mut-f.sh"; MUT_I="$T/mut-i.sh"; MUT_J="$T/mut-j.sh"
mut_ok=1
apply_mutation "$OWNER" "$MUT_A" 's/^    if \[ "\$live" = 0 \]; then$/    if false; then/' \
    || { printf '  ❌ mutation A could not be applied (the skip-live arm moved) — that case now covers nothing\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_B" 's/^        elif \[ -n "\$sz" \] && \[ "\$sz" -lt "\$MIN_CACHE_MB" \]; then$/        elif false; then/' \
    || { printf '  ❌ mutation B could not be applied (the size bound moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_D" 's/^    if \[ "\$CENSUS" != "ok" \]; then LIVE_REASON="census-unreadable"; return 2; fi$/    :/' \
    || { printf '  ❌ mutation D could not be applied (the census gate moved)\n'; mut_ok=0; }
# ⛔ THE MARKER TEST IS THE ONLY THING PROTECTING A GLOB-MATCHED NEIGHBOUR, so it gets its own mutant:
# case E's neighbour carries a cache ABOVE the size bound precisely so the bound cannot answer for it.
apply_mutation "$OWNER" "$MUT_E" 's/^is_install() { .*$/is_install() { true; }/' \
    || { printf '  ❌ mutation E could not be applied (the install marker test moved)\n'; mut_ok=0; }
apply_mutation "$REAPER" "$MUT_C" 's/\[ "\$mb" -lt "\$RUNNER_CACHE_TRIGGER_FREE_MB" \] && low=1/[ "$mb" -gt "$RUNNER_CACHE_TRIGGER_FREE_MB" ] \&\& low=1/' \
    || { printf '  ❌ mutation C could not be applied (the trigger comparison moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_C2" 's/^    \[ "\$(( FREED_MB + pending ))" -gt "\$MAX_MB" \]$/    false/' \
    || { printf '  ❌ mutation C2 could not be applied (the cap test moved)\n'; mut_ok=0; }
# ⛔ THE TOCTOU MUTANT NEUTERS THE RE-READ, NOT THE WHOLE ARM: with the refresh stubbed to `:` the probe
# still runs and still consults a census — a FROZEN one — which is precisely the defect the finding
# described. If the case only reddened when the arm was deleted outright, it would not be testing that
# the probe is fresh.
apply_mutation "$OWNER" "$MUT_F" 's/^census_refresh() { census_read; }$/census_refresh() { :; }/' \
    || { printf '  ❌ mutation F could not be applied (the census re-read moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_J" 's/REAP_RC_LOG:-/REAP_RC_LOG_IGNORED:-/' \
    || { printf '  ❌ mutation J could not be applied (the log seam moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_I" 's/^    if \[ "\$pending" -gt "\$MAX_MB" \] && \[ "\$FREED_MB" -lt "\$MAX_MB" \]; then$/    if false; then/' \
    || { printf '  ❌ mutation I could not be applied (the oversized-candidate guard moved)\n'; mut_ok=0; }

printf '── ran with %s ──\n' "${BASH_VERSION%%(*}"
expect_pass "A a live install is SKIPPED and the idle one is reaped" case_a "$OWNER"
expect_pass "B a small cache and young scratch are KEPT; aged scratch is reaped" case_b "$OWNER"
expect_pass "C the size trigger fires only below the threshold, and a pass is capped" case_c "$REAPER" "$OWNER"
expect_pass "D an unreadable census removes nothing and fails closed" case_d "$OWNER"
expect_pass "F a job that starts mid-pass keeps its cache (the probe IS re-read)" case_f "$OWNER"
expect_pass "G the SHARED cache root re-probes the population too" case_g "$OWNER"
expect_pass "H a re-probe that cannot answer keeps the candidate and fails closed" case_h "$OWNER"
expect_pass "I a candidate bigger than the whole cap is still taken, once" case_i "$OWNER"
expect_pass "J the REAP_RC_LOG seam is honoured" case_j "$OWNER"

printf '\n── mutations: each arm must redden the case that covers it ──\n'
[ "$mut_ok" = 1 ] || bad "one or more mutations could not be applied (see above)"
expect_fail "A mutant: the skip-live arm deleted"                      case_a "$MUT_A"
expect_fail "B mutant: the size bound deleted"                         case_b "$MUT_B"
expect_fail "C mutant: the trigger comparison inverted"                case_c "$MUT_C" "$OWNER"
expect_fail "C2 mutant: the per-pass cap never reached"                case_c "$REAPER" "$MUT_C2"
expect_fail "D mutant: the census gate deleted"                        case_d "$MUT_D"
# E's mutant is applied HERE but asserted at the scope case itself (below), because `case_scope` is
# defined after this block — an `expect_fail` naming an undefined function is "command not found",
# which reads as a caught mutant while proving nothing.
expect_fail "F mutant: the re-probe stops RE-READING the census"         case_f "$MUT_F"
expect_fail "G mutant: the re-probe stops RE-READING (shared root arm)"  case_g "$MUT_F"
expect_fail "H mutant: the re-probe stops RE-READING (unreadable arm)"  case_h "$MUT_F"
expect_fail "I mutant: the oversized-candidate guard deleted"            case_i "$MUT_I"
expect_fail "J mutant: the log seam is ignored"                         case_j "$MUT_J"

printf '\n── the owner never removes anything it was not asked to ──\n'
# ⛔ A SCOPE CASE, not a policy one: the owner is handed a tree that contains an install AND an
# unrelated neighbour, and must leave the neighbour alone. It is the shape the family has already been
# bitten by (`REAPED …/gh-runner-x//bin`, a seam one component short).
# ⛔ AND IT MUST BE THE MARKER THAT PROTECTS THE NEIGHBOUR, NOT THE SIZE BOUND (#4169 review, NOTE-3).
# The neighbour used to hold a 0 MB cache while `REAP_RC_MIN_CACHE_MB=1`, so `is_install() { true; }`
# still KEPT it as `below-min-cache` and every row stayed green: the case passed for a reason unrelated
# to what it claims to pin, and the mutant that deletes the marker test survived it. The neighbour now
# carries a cache ABOVE the bound, so only `is_install` can keep it — proven by `MUT_E` below.
case_scope() {
    local base outer out rc owner="${1:-$OWNER}"
    base="$(mktemp -d "$T/e.XXXXXX")"
    outer="$base/not-a-runner"; mkdir -p "$outer/.cache/keep"
    # 2 MB of REAL bytes: above `REAP_RC_MIN_CACHE_MB=1` below, so the SIZE bound cannot keep this
    # neighbour — only the install marker can.
    dd if=/dev/zero of="$outer/.cache/keep/blob" bs=1M count=2 >/dev/null 2>&1
    mk_install "$base/gh-runner-ok"; mk_cache "$base/gh-runner-ok" 2; idle_work "$base/gh-runner-ok"
    mk_ps "$base/ps" "$base/gh-runner-ok" idle
    # The glob matches the NEIGHBOUR too; only a marker-carrying install may be reaped.
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/*" REAP_RC_EXPLICIT=1 REAP_RC_SHARED_GLOBS="$base/no-shared" \
           REAP_RC_MIN_CACHE_MB=1 REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$outer/.cache/keep" ] && echo 0 || echo 1)" \
               "a directory matched by the glob but WITHOUT the install marker is untouched"
    case_check "$([ ! -e "$base/gh-runner-ok/.cache" ] && echo 0 || echo 1)" \
               "while the real install in the same run WAS reaped"
    return $((CASE_FAIL > 0))
}
expect_pass "E only a directory carrying bin/Runner.Listener is ever touched" case_scope
expect_fail "E mutant: the install marker test deleted"                 case_scope "$MUT_E"

printf '\n──────────────────────────────\n'
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
