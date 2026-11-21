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
#   P  THE SHARED ROOT'S DEFAULT HAS ONE SOURCE, AND IT IS THE LAYOUT — not `${RUNNER_ROOT:-…}` in the
#      reaper's OWN environment. The pool writes to `${RUNNER_CACHE_ROOT-$RUNNER_ROOT/_cache}` and puts
#      every install at `$RUNNER_ROOT/gh-runner-*`, so a discovered install's parent `_cache` IS the
#      pool's cache root on any box, whatever a scheduled unit renders into its `Environment=` (neither
#      renders `RUNNER_ROOT`, which is what falsified the previous "one source" claim on `/opt`).
#      Mutant: the derived candidate -> removed.
#   Q  THE SHARED ROOT'S LIVENESS GATE IS NOT VACUOUS. With NO install discovered, `any_live_now` walks
#      an empty list and answers "not live" without reading anything — so the census must be asked
#      instead, and an unattributable runner process means liveness is UNKNOWN and nothing is removed.
#      Mutant: the population witness -> removed.
#   R  THE SHARED ROOT IS PRESSURE-GATED, NOT AGE-GATED: kept above the free-space trigger, reaped below
#      it, and KEPT when the probe cannot answer (a warm cache is not a leak, and an hourly pass must not
#      empty it on a healthy box).
#      Mutant: the free-space gate -> removed.
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
      REAP_RC_GLOBS REAP_RC_SHARED_GLOBS REAP_RC_MIN_CACHE_MB REAP_RC_PS_BIN \
      REAP_RC_DF_BIN REAP_RC_INSTALL_TRIGGER_FREE_MB 2>/dev/null || true
# ⛔ BOTH FREE-SPACE GATES ARE PINNED OFF FOR THE WHOLE SUITE, because they read the BOX: this host has
# 70+ GB free, so the 40960 default would keep every shared root AND every install `.cache` and make the
# reap cases vacuous. `case_r` exercises the shared gate and `case_t` the install gate, each with a `df`
# STUB, so both directions and the unmeasurable arm are deterministic instead of host-dependent.
export REAP_RC_SHARED_TRIGGER_FREE_MB=0
export REAP_RC_INSTALL_TRIGGER_FREE_MB=0
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
# the class treats a listener PLUS content a JOB WROTE under `_work` inside the freshness window as "a job
# is running" (the conservative direction the brief asks for). `mk_install` creates `_work/_temp` EMPTY,
# and an empty sink contributes nothing to the witness (the sink's own mtime is deliberately NOT a
# freshness reading — see `case_s`), so this helper only has to age the two directories the AGE gates
# read. It ages `_temp` as well, which keeps every fixture honest about the pre-fix behaviour it was
# written against: an aged sink is idle under both readings.
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
    # ⛔ THE "YOUNG" ENTRY IS 1 DAY OLD, NOT FRESH. Two independent gates read this install: the AGE bound
    # (`REAP_RC_SCRATCH_DAYS`) and the LIVENESS window (`REAP_RC_JOB_WINDOW_S`, 900 s). A file written a
    # moment ago sits INSIDE the liveness window, so the install is LIVE and nothing under it is touched —
    # the age assertion then passes for the wrong reason (and did, in `case_l`). 1 day is younger than the
    # 7-day age bound and older than the 15-minute window, which is the only fixture that isolates the
    # AGE gate from the liveness one.
    printf 'young\n' >"$inst/_work/_temp/step.sh"; age_path "$inst/_work/_temp/step.sh" 1
    printf 'old\n'   >"$inst/_work/_temp/old-step.sh"; age_path "$inst/_work/_temp/old-step.sh" 9
    # ⛔ TWO YOUNG `_diag` LOGS, AND THE ASSERTED ONE IS THE OLDER (#4169 review, P2). With a SINGLE
    # young log the row could not redden when the age gate was deleted: the file was trivially
    # `newest_log`, so the unconditional newest-log keep answered for the age gate and the assertion
    # passed on a tree with no age bound at all — a dead-weight assertion under agent-infra#3442 rule 3.
    # The asserted log is now 2 days old with a 1-day-old sibling beside it, so ONLY the age gate can
    # keep it; `MUT_B3` deletes that gate and reddens the row.
    printf 'younger-still\n' >"$inst/_diag/Runner_1.log"; age_path "$inst/_diag/Runner_1.log" 2
    printf 'youngest\n'      >"$inst/_diag/Runner_2.log"; age_path "$inst/_diag/Runner_2.log" 1
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
    case_check "$(grep -qF "KEPT   $inst/_diag/Runner_1.log reason=too-young" <<<"$out" && echo 0 || echo 1)" \
               "and the OLDER of two young logs is kept BY THE AGE GATE (reason=too-young), not by the newest-log keep"
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
    # ⛔ THE "the cap still bounds the pass" ROW THAT USED TO SIT HERE IS GONE (#4169 review, P3). It was
    # `[ "$(grep -c '^REAPED ' <<<"$out")" -le 2 ]` over a fixture with exactly TWO candidates — true on
    # the pre-fix owner and under every mutant in this file, i.e. a row that READS as coverage of the cap
    # while asserting nothing (agent-infra#3442 rule 3). It cannot simply be given a third candidate
    # either: the oversized-admission property this case DOES pin requires the big cache to be reached
    # while less than the cap has been freed, so a small candidate ordered before it can consume the cap
    # and defer it — the two properties are not simultaneously assertable on one fixture, and `compgen`
    # decides the order. The cap's real bound is covered by `case_c`(2) ("exactly ONE 2MB cache was
    # reclaimed against a 3MB cap"), whose `MUT_C2` reddens it.
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

# ── K: an EXPLICIT glob that matched directories but NO INSTALL is a REFUSAL, not a measured zero ──
# ⛔ This is the blocking finding from the #4169 review. The refusal gate asked "did any pattern match a
# DIRECTORY", so a seam that matched a tree carrying no `bin/Runner.Listener` (a broken install, a
# `gh-runner-*` leftover, a seam one component short) passed it, fell through to "measured empty
# population", and exited 0 with `census=ok installs=0` — the record then read `verdict=ok` over the
# sink the class exists to free. Both shapes of "matched no install" now refuse with `census=no-roots`,
# which the entry point already maps to `misconfigured`.
# Mutant: the `if [ "$RC_EXPLICIT" = 1 ]; then` refusal gate -> `if false; then`.
case_k() { # <owner-script>
    local owner="$1" base out rc
    base="$(mktemp -d "$T/k.XXXXXX")"
    mkdir -p "$base/gh-runner-broken/bin" "$base/gh-runner-broken/.cache/uv"
    dd if=/dev/zero of="$base/gh-runner-broken/.cache/uv/blob" bs=1M count=2 >/dev/null 2>&1
    mk_ps "$base/ps" "$base/gh-runner-broken" idle
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_MIN_CACHE_MB=1 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "a matched directory carrying NO install marker FAILS CLOSED (rc=$rc, want 3) — it used to exit 0 with census=ok"
    case_check "$(grep -qF 'census=no-roots' <<<"$out" && echo 0 || echo 1)" \
               "and publishes census=no-roots (the state the entry point maps to misconfigured)"
    case_check "$(grep -qE 'matched [0-9]+ director(y|ies) \[' <<<"$out" && echo 0 || echo 1)" \
               "the refusal NAMES what it matched and why it is not an install"
    case_check "$(grep -qF 'bin/Runner.Listener' <<<"$out" && echo 0 || echo 1)" \
               "and names the marker the directory is missing"
    case_check "$(grep -qF 'NONE carries the install marker' <<<"$out" && grep -qF 'REAP_RC_GLOBS' <<<"$out" && echo 0 || echo 1)" \
               "pointing at the seam, not at the box"
    case_check "$([ -d "$base/gh-runner-broken/.cache/uv" ] && echo 0 || echo 1)" "nothing was removed"
    return $((CASE_FAIL > 0))
}

# ── L: a SHARED root that IS — or CONTAINS — an install is REFUSED before any delete ─────────────
# ⛔ The shared root is decided by a GLOB, so the one-token error it invites (`$RUNNER_ROOT` instead of
# `$RUNNER_ROOT/_cache`) is a delete surface over the runner INSTALL tree — and the liveness gate does
# not save it, because a runner between jobs is idle BY DESIGN. Two `stat`s, and a refusal that ends the
# pass (rc 3, `census=refused`) instead of a partial sweep.
# Mutant: the root-is-an-install guard -> `if false; then`.
case_l() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/l.XXXXXX")"
    inst="$base/gh-runner-l"
    # ⛔ THE INSTALL ARM IS GIVEN NOTHING TO DO, DELIBERATELY. The install is a legitimate target of
    # `REAP_RC_GLOBS` in this fixture, so a cache above the size bound — or an aged scratch entry — is
    # reaped by the INSTALL arm, correctly, and this case's "nothing was deleted" rows would then be
    # describing the wrong arm. Worse, the pre-fix suite passed those rows for a FALSE reason: writing
    # `aged.sh` into `_work/_temp` bumped the SINK's mtime, the install read `busy-work`, and nothing was
    # swept because of the P1 self-poisoning bug rather than because of the refusal under test.
    mk_install "$inst"; mk_cache "$inst" 0; idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    # The seam names the INSTALL itself (the one-token error) as the shared cache root.
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$inst" REAP_RC_MIN_CACHE_MB=1 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "a shared root that IS an install FAILS CLOSED (rc=$rc, want 3)"
    case_check "$(grep -qF "REFUSED $inst reason=shared-root-is-an-install" <<<"$out" && echo 0 || echo 1)" \
               "and it is REFUSED BY NAME with the reason (REFUSED … reason=shared-root-is-an-install)"
    case_check "$(grep -qF 'census=refused' <<<"$out" && echo 0 || echo 1)" \
               "the pass publishes census=refused (a state distinct from an abstention)"
    case_check "$([ -f "$inst/bin/Runner.Listener" ] && echo 0 || echo 1)" \
               "the install's MARKER survived (the pass never entered its entries)"
    case_check "$(grep -qF 'reaped=0' <<<"$out" && echo 0 || echo 1)" \
               "and NOTHING at all was removed by any arm in that pass (reaped=0) — the refusal is not a partial sweep"
    case_check "$(grep -qF 'refused=1' <<<"$out" && echo 0 || echo 1)" "the count is printed (refused=1), not implied"
    return $((CASE_FAIL > 0))
}

# ── L2: a shared root that CONTAINS an install (the parent — the exact one-token error) ─────────
# Mutant: the contains-an-install guard -> `if false; then`.
case_l2() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/l2.XXXXXX")"
    inst="$base/gh-runner-l2/inner"
    mk_install "$inst"; idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*/inner" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/gh-runner-l2" REAP_RC_MIN_CACHE_MB=1 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "a shared root that CONTAINS an install FAILS CLOSED (rc=$rc, want 3)"
    case_check "$(grep -qF 'reason=shared-root-contains-an-install' <<<"$out" && echo 0 || echo 1)" \
               "and names the reason (reason=shared-root-contains-an-install) with the entry it found"
    case_check "$([ -f "$inst/bin/Runner.Listener" ] && echo 0 || echo 1)" "the install underneath is INTACT"
    return $((CASE_FAIL > 0))
}

# ── M: cache_mb is the CLASS'S total, so it includes the shared root ────────────────────────────
# ⛔ The layout the durable half creates: every write goes to `XDG_CACHE_HOME` (the shared root), the
# per-install `.cache` dirs stay empty. The reading then reported `cache_mb=0` beside a non-zero
# `freed_mb` in the same record — a number contradicting itself in a class whose rule is "the numbers
# are printed, not implied".
# Mutant: the shared-root accumulate -> removed (the marker comment is what makes this surgical).
case_m() { # <owner-script>
    local owner="$1" base inst shared out rc
    base="$(mktemp -d "$T/m.XXXXXX")"
    inst="$base/gh-runner-m"; shared="$base/shared/_cache"
    mk_install "$inst"; mk_cache "$inst" 0; idle_work "$inst"
    mkdir -p "$shared/uv"; dd if=/dev/zero of="$shared/uv/blob" bs=1M count=3 >/dev/null 2>&1
    mk_ps "$base/ps" "$inst" idle
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$shared" REAP_RC_MIN_CACHE_MB=1000 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$(grep -qE 'cache_mb=[1-9][0-9]*' <<<"$(grep -F 'SUMMARY class=runner-cache' <<<"$out")" && echo 0 || echo 1)" \
               "cache_mb counts the SHARED root the durable half creates (it read 0 while the bytes were here)"
    case_check "$(grep -qE 'INSTALL .*cache_mb=0 ' <<<"$out" && echo 0 || echo 1)" \
               "while the per-install cache really is empty in the same pass — the two readings are not the same number by accident"
    return $((CASE_FAIL > 0))
}

# ── N: the listener's CURRENT `_diag` log is KEPT; the aged closed ones are still reaped ─────────
# ⛔ `_diag/Runner_<ts>-utc.log` is held OPEN by the listener, so unlinking it reclaims ~0 bytes while
# the `du` taken before the delete credits FREED_MB for bytes no `df` will show — and the box loses the
# diagnostics for the next failure.
# Mutant: the newest-log keep -> `if false; then`.
case_n() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/n.XXXXXX")"
    inst="$base/gh-runner-n"
    mk_install "$inst"; mk_cache "$inst" 0; idle_work "$inst"
    printf 'older\n' >"$inst/_diag/Runner_20200101-utc.log"; age_path "$inst/_diag/Runner_20200101-utc.log" 20
    printf 'current\n' >"$inst/_diag/Runner_20200102-utc.log"; age_path "$inst/_diag/Runner_20200102-utc.log" 9
    # Both are AGED (past REAP_RC_LOG_DAYS=7); only the NEWEST is the listener's open one.
    mk_ps "$base/ps" "$inst" idle
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_LOG_DAYS=7 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -f "$inst/_diag/Runner_20200102-utc.log" ] && echo 0 || echo 1)" \
               "the NEWEST aged log is KEPT (a live listener holds it open: unlinking it frees no bytes)"
    case_check "$(grep -qF 'reason=newest-log' <<<"$out" && echo 0 || echo 1)" "and it is named (reason=newest-log)"
    case_check "$([ ! -f "$inst/_diag/Runner_20200101-utc.log" ] && echo 0 || echo 1)" \
               "while an OLDER aged log in the same install WAS reaped (the age bound still binds)"
    return $((CASE_FAIL > 0))
}

# ── O: the `_work` freshness witness is ARGV-INDEPENDENT ────────────────────────────────────────
# ⛔ It used to be gated BEHIND a literal `$inst/bin/Runner.Listener` / `$inst/run.sh` argv match, so an
# install whose listener argv is `./run.sh` (or a canonicalised path, or a renamed run.sh) fell to
# `no-listener` and had its cache reaped while a job was running. The witness is now asked first.
# Mutant: the `_work` freshness gate -> `if false; then`.
case_o() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/o.XXXXXX")"
    inst="$base/gh-runner-o"
    mk_install "$inst"; mk_cache "$inst" 2
    # A JOB JUST STARTED: it WRITES INTO `_work/_temp`, which is what a running job does (and what the
    # witness must read). ⛔ NOT `_temp`'s OWN mtime: that is the directory this class deletes into, so
    # reading it is the self-poisoning `case_s` pins (#4169 review, P1).
    printf 'jobstep\n' >"$inst/_work/_temp/current-step.sh"
    printf '  4242 ./run.sh --startuptype service\n' >"$base/ps"           # argv the literal match misses
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_MIN_CACHE_MB=1 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$inst/.cache" ] && echo 0 || echo 1)" \
               'a FRESH `_work` keeps the cache even when the listener argv does not match the literal (argv-independent witness)'
    case_check "$(grep -qF 'reason=skipped-live:busy-work' <<<"$out" && echo 0 || echo 1)" \
               "and the skip names THAT witness (reason=skipped-live:busy-work)"
    case_check "$(grep -qF 'live=yes' <<<"$out" && echo 0 || echo 1)" "the installation reading says live=yes"
    return $((CASE_FAIL > 0))
}

# ── P: the SHARED root's default comes from the LAYOUT, not from this process' env ────────────
# ⛔ THE FALSIFIED CLAIM (#4169 review, BLOCKING). The default derived `${RUNNER_ROOT:-…}/_cache`
# from the reaper's OWN environment, and NEITHER scheduled artifact renders `RUNNER_ROOT` — so on the
# documented `RUNNER_ROOT=/opt` layout (the cells' real shape: installs at `/opt/gh-runner-*`, cache at
# `/opt/_cache`) the reaper derived `/tmp/actions-runner/_cache`, matched nothing, and reported `ok` while
# the pool filled a directory no glob covered. The fixture below is that layout, with `RUNNER_ROOT`
# UNSET — the derivation must not need it.
# Mutant: the derived candidate -> removed.
case_p() { # <owner-script>
    local owner="$1" base root inst shared out rc pool_root
    base="$(mktemp -d "$T/p.XXXXXX")"
    root="$base/opt"
    inst="$root/gh-runner-x64"; shared="$root/_cache"
    mk_install "$inst"; mk_cache "$inst" 0; idle_work "$inst"
    mkdir -p "$shared/uv"; dd if=/dev/zero of="$shared/uv/blob" bs=1M count=3 >/dev/null 2>&1
    mk_ps "$base/ps" "$inst" idle
    # ⛔ NO `REAP_RC_SHARED_GLOBS` OVERRIDE and NO `RUNNER_ROOT`: only the derivation can find `$shared`.
    out="$(cd "$base" && RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$root/gh-runner-*" REAP_RC_EXPLICIT=1 \
           env -u RUNNER_ROOT -u RUNNER_CACHE_ROOT -u REAP_RC_SHARED_GLOBS \
           REAP_RC_MIN_CACHE_MB=1 REAP_RC_SHARED_TRIGGER_FREE_MB=0 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ ! -e "$shared/uv" ] && echo 0 || echo 1)" \
               "the pool's cache root beside the installs IS swept with no RUNNER_ROOT and no shared-glob override"
    case_check "$(grep -qF "shared_root=derived (" <<<"$out" && grep -qF "$shared" <<<"$out" && echo 0 || echo 1)" \
               "and the pass NAMES the derived candidate it reached (shared_root=derived …)"
    # ⛔ THE CROSS-TOOL PIN the earlier round admitted it did not have: the pool's OWN expression, read
    # from the pool, resolves to the directory this case just swept. A change to either tool's layout
    # reddens here instead of silently re-opening the sink.
    pool_root="$(cd "$HERE" && env -u RUNNER_CACHE_ROOT RUNNER_ROOT="$root" bash -c \
        "$(sed -n 's/^CACHE_ROOT=/CACHE_ROOT=/p' "$HERE/ci_runner_pool.sh" | head -1); printf '%s' \"\$CACHE_ROOT\"" 2>/dev/null)"
    case_check "$([ "$pool_root" = "$shared" ] && echo 0 || echo 1)" \
               "and the POOL's own CACHE_ROOT expression resolves to that same directory (tools=$pool_root layout=$shared)"
    return $((CASE_FAIL > 0))
}

# ── Q: the shared root's liveness gate is NOT VACUOUS when no install was discovered ───────────
# ⛔ `any_live_now` walks `$INSTALL_DIRS`; with an EMPTY population it returns "not live" having read
# nothing, and the shared root was emptied on the authority of a question nobody asked. If the process
# census carries a listener/worker that no discovered install accounts for, an install lives OUTSIDE the
# globs and may be reading that root right now: liveness is UNKNOWN, nothing is removed, rc 3.
# Mutant: the population witness -> removed.
case_q() { # <owner-script>
    local owner="$1" base shared out rc
    base="$(mktemp -d "$T/q.XXXXXX")"
    shared="$base/shared/_cache"
    mkdir -p "$shared/uv"; dd if=/dev/zero of="$shared/uv/blob" bs=1M count=2 >/dev/null 2>&1
    # A runner process for an install that this pass's glob does NOT match (it lives elsewhere).
    printf '  4242 %s/elsewhere/gh-runner-z/bin/Runner.Listener run\n' "$base" >"$base/ps"
    printf '  4243 %s/elsewhere/gh-runner-z/bin/Runner.Worker spawnclient 1 2\n' "$base" >>"$base/ps"
    # Zero installs WITHOUT the explicit-seam refusal (`REAP_RC_EXPLICIT=0` is the documented way to say
    # "these globs are the defaults, a measured-empty box is not a refusal").
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=0 \
           REAP_RC_SHARED_GLOBS="$shared" REAP_RC_SHARED_TRIGGER_FREE_MB=0 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ -d "$shared/uv" ] && echo 0 || echo 1)" \
               "with ZERO installs discovered and a runner process nobody accounts for, the SHARED root is UNTOUCHED"
    case_check "$(grep -qF "KEPT   $shared reason=unattributed-runner-process" <<<"$out" && echo 0 || echo 1)" \
               "and it is KEPT BY NAME (reason=unattributed-runner-process), not silently"
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" \
               "the pass FAILS CLOSED (rc=$rc, want 3) — an empty population is not proof of idleness"
    return $((CASE_FAIL > 0))
}

# ── R: the SHARED root is PRESSURE-gated, not reaped on every tick ─────────────────────────────
# ⛔ #4169 review, P3: it had no size bound of its own and the HOURLY pass ran no free-space gate, so a
# box with hundreds of GB free had its warm machine-wide cache emptied every hour and every job
# re-downloaded the same packages. Both directions plus the unmeasurable arm, with a `df` STUB so the
# reading is a fixture and not this host's disk.
# Mutant: the free-space gate -> removed.
case_r() { # <owner-script>
    local owner="$1" base shared out rc df_stub
    base="$(mktemp -d "$T/r.XXXXXX")"
    shared="$base/shared/_cache"
    mk_ps "$base/ps" "$shared" idle
    df_stub="$base/df-stub"
    cat >"$df_stub" <<'STUB'
#!/bin/sh
case "${RC_TEST_DF_MODE:-ok}" in
    fail) exit 1 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture %s 0 %s 0%% /\n' 999999 "$(( ${RC_TEST_DF_FREE_MB:-0} * 1024 ))"
STUB
    chmod +x "$df_stub"
    mk_install "$base/gh-runner-r"; mk_cache "$base/gh-runner-r" 0; idle_work "$base/gh-runner-r"
    run_df() { # <free-mb> <mode> — one fresh fixture + one pass, prints the owner output
        rm -rf "$shared"; mkdir -p "$shared/uv"
        dd if=/dev/zero of="$shared/uv/blob" bs=1M count=2 >/dev/null 2>&1
        RC_TEST_DF_FREE_MB="$1" RC_TEST_DF_MODE="$2" REAP_RC_DF_BIN="$df_stub" \
        RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
        REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
        REAP_RC_SHARED_GLOBS="$shared" REAP_RC_SHARED_TRIGGER_FREE_MB=40960 \
        REAP_RC_MIN_CACHE_MB=1 REAP_RC_STATE_DIR="$base/state" \
        bash "$owner" --apply 2>&1
    }
    # (1) ABOVE the trigger: a healthy box keeps its warm cache.
    out="$(run_df 200000 ok)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'R1 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "above the trigger the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$shared/uv" ] && echo 0 || echo 1)" \
               "a WARM shared cache on a box with 200 GB free is KEPT (the hourly pass is not a cache evictor)"
    case_check "$(grep -qF 'reason=shared-free-above-trigger' <<<"$out" && echo 0 || echo 1)" \
               "and the keep NAMES the reading and the threshold (reason=shared-free-above-trigger)"
    # (2) BELOW the trigger: the frequent pass's case, reaped.
    out="$(run_df 1000 ok)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'R2 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ ! -e "$shared/uv" ] && echo 0 || echo 1)" \
               "BELOW the trigger the shared root IS reaped (the pressure gate is not an inert enforcer)"
    # (3) THE PROBE CANNOT ANSWER: keep it and fail closed — never "unknown" read as "safe to delete".
    out="$(run_df 1000 fail)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'R3 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ -d "$shared/uv" ] && echo 0 || echo 1)" \
               'a df that cannot answer KEEPS the root (an unanswerable gate is not a delete permission)'
    case_check "$(grep -qF 'reason=free-unmeasurable' <<<"$out" && echo 0 || echo 1)" \
               "and it is named (reason=free-unmeasurable)"
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "and the pass fails closed (rc=$rc, want 3)"
    return $((CASE_FAIL > 0))
}

# ── S: the class never poisons the witness it proves IDLENESS with (#4169 review, P1) ─────────
# ⛔ THE DEFECT THIS PINS: `_work/_temp` is a DIRECT CHILD of `_work`, and `rm` of an entry inside it
# sets `_temp`'s OWN mtime to now. While the witness read the SINK'S OWN mtime, the class's first scratch
# delete made its own pass look like a running job: scratch entry #2 was skipped `toctou:busy-work`, the
# `_diag` arm after it was skipped too, and the poisoned mtime OUTLIVED the pass — the next tick (10 min
# against a 900 s window) reported a job that never ran and skipped that install's `.cache` whole. So the
# fixture below is the normal state on the boxes #4168 measured (leftover aged `_temp` entries): TWO aged
# scratch entries and TWO aged logs, all reclaimable, in ONE pass.
# Mutant: the witness stops descending into the sink (MUT_S), i.e. it reads `_temp`'s own mtime again.
case_s() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/s.XXXXXX")"
    inst="$base/gh-runner-s"
    mk_install "$inst"; mk_cache "$inst" 0
    printf 'young\n' >"$inst/_work/_temp/young-step.sh"; age_path "$inst/_work/_temp/young-step.sh" 1
    printf 'old one\n' >"$inst/_work/_temp/old-1.sh"; age_path "$inst/_work/_temp/old-1.sh" 9
    printf 'old two\n' >"$inst/_work/_temp/old-2.sh"; age_path "$inst/_work/_temp/old-2.sh" 9
    printf 'older\n' >"$inst/_diag/Runner_20200101-utc.log"; age_path "$inst/_diag/Runner_20200101-utc.log" 20
    printf 'current\n' >"$inst/_diag/Runner_20200102-utc.log"; age_path "$inst/_diag/Runner_20200102-utc.log" 9
    idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    out="$(run_owner "$owner" "$base" "$base/ps" --apply --scratch-days 7 --log-days 7)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ ! -f "$inst/_work/_temp/old-1.sh" ] && echo 0 || echo 1)" \
               "the FIRST aged scratch entry is reaped"
    case_check "$([ ! -f "$inst/_work/_temp/old-2.sh" ] && echo 0 || echo 1)" \
               'the SECOND aged scratch entry is reaped IN THE SAME PASS (removing the first must not look like a job)'
    case_check "$([ ! -f "$inst/_diag/Runner_20200101-utc.log" ] && echo 0 || echo 1)" \
               'and the `_diag` arm still runs after a scratch delete (it was skipped too)'
    case_check "$([ -f "$inst/_diag/Runner_20200102-utc.log" ] && echo 0 || echo 1)" \
               "while the listener's CURRENT log is still kept (the age policy is unchanged)"
    case_check "$([ -f "$inst/_work/_temp/young-step.sh" ] && echo 0 || echo 1)" \
               "and young scratch is still kept (the age gate still binds)"
    case_check "$(grep -qF 'reason=toctou:busy-work' <<<"$out" && echo 1 || echo 0)" \
               'the pass NEVER claims a job is running when none is (no reason=toctou:busy-work)'
    return $((CASE_FAIL > 0))
}

# ── T: the per-install `.cache` is PRESSURE-gated on ITS OWN filesystem (#4169 review, P2) ─────
# ⛔ The entry point's `--size-trigger` fires when ANY filesystem its glob PREFIXES resolve to is low,
# and those prefixes include `/tmp` and `$HOME`. On a box whose `/tmp` is a small tmpfs it fired the pass
# every 10 minutes while the RUNNERS' filesystem held hundreds of GB free — and the pass then flushed
# every idle install's warm cache, because the install arm had no free-space condition at all (only the
# shared root did). Three directions plus the unmeasurable arm, with a `df` STUB so the reading is a
# fixture and not this host's disk.
# Mutant: the install-arm gate removed (MUT_T).
case_t() { # <owner-script>
    local owner="$1" base inst out rc df_stub
    base="$(mktemp -d "$T/t.XXXXXX")"
    inst="$base/gh-runner-t"
    df_stub="$base/df-stub"
    cat >"$df_stub" <<'STUB'
#!/bin/sh
case "${RC_TEST_DF_MODE:-ok}" in
    fail) exit 1 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture %s 0 %s 0%% /\n' 999999 "$(( ${RC_TEST_DF_FREE_MB:-0} * 1024 ))"
STUB
    chmod +x "$df_stub"
    mk_install "$inst"; idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    run_t() { # <free-mb> <mode> — one FRESH 2MB cache + one pass, prints the owner output
        rm -rf "$inst/.cache"; mk_cache "$inst" 2
        RC_TEST_DF_FREE_MB="$1" RC_TEST_DF_MODE="$2" REAP_RC_DF_BIN="$df_stub" \
        RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
        REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
        REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_INSTALL_TRIGGER_FREE_MB=40960 \
        REAP_RC_MIN_CACHE_MB=1 REAP_RC_STATE_DIR="$base/state" \
        bash "$owner" --apply 2>&1
    }
    # (1) ABOVE the trigger: the install's filesystem does not need the bytes — keep the warm cache.
    out="$(run_t 200000 ok)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'T1 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "above the trigger the pass exits 0 (rc=$rc)"
    case_check "$([ -e "$inst/.cache/uv/blob" ] && echo 0 || echo 1)" \
               'a WARM per-install cache on a filesystem with 200 GB free is KEPT (the trigger firing is not a delete licence)'
    case_check "$(grep -qF 'reason=install-free-above-trigger' <<<"$out" && echo 0 || echo 1)" \
               'and the keep NAMES its own filesystem reading (reason=install-free-above-trigger)'
    # (2) BELOW the trigger: this filesystem needs the space, so the idle cache goes.
    out="$(run_t 1000 ok)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'T2 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ ! -e "$inst/.cache" ] && echo 0 || echo 1)" \
               'BELOW the trigger the install cache IS reaped (the gate is not an inert enforcer)'
    # (3) THE PROBE CANNOT ANSWER: keep it and fail closed.
    out="$(run_t 1000 fail)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'T3 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ -e "$inst/.cache/uv/blob" ] && echo 0 || echo 1)" \
               'a df that cannot answer KEEPS the install cache (an unanswerable gate is not a delete permission)'
    case_check "$(grep -qF 'reason=install-free-unmeasurable' <<<"$out" && echo 0 || echo 1)" \
               'and it is named (reason=install-free-unmeasurable)'
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "and the pass fails closed (rc=$rc, want 3)"
    return $((CASE_FAIL > 0))
}

# ── U: the shared root's PER-ENTRY re-probe is not vacuous with an EMPTY population (#4169 review, P3) ──
# ⛔ THE DEFECT THIS PINS: `any_live_now` walks `$INSTALL_DIRS`, so with ZERO installs discovered it
# iterated nothing and answered "not live" WITHOUT READING ANYTHING — discarding the fresh census
# `census_refresh` had just paid for. The Q gate closes that shape only at the PASS-START position;
# `reap_one`'s shared-arm re-probe runs minutes later, and a runner process that appeared in that
# window was invisible. The fixture is exactly that sequence: the pass-start census carries NO runner
# process (so Q's gate correctly treats the pre-loop state as proven idle), and the SECOND census —
# read immediately before the removal — carries an unattributable `Runner.Worker`. The entry must be
# KEPT, and named `toctou:unattributed-runner-process`.
# Mutant: the empty-population census witness in `any_live_now` -> unreachable (MUT_U).
case_u() { # <owner-script>
    local owner="$1" base shared out rc df_stub
    base="$(mktemp -d "$T/u.XXXXXX")"
    shared="$base/shared/_cache"
    mkdir -p "$shared/uv"; dd if=/dev/zero of="$shared/uv/blob" bs=1M count=2 >/dev/null 2>&1
    # TWO census answers: (1) no runner process at all — a real proof of idleness for the Q gate;
    # (2) a Runner.Worker for an install this pass's globs do NOT match, appearing mid-pass.
    printf '  1 /usr/bin/init\n' >"$base/ps1"
    printf '  4243 %s/elsewhere/gh-runner-z/bin/Runner.Worker spawnclient 1 2\n' "$base" >"$base/ps2"
    printf '%s\n%s\n' "$base/ps1" "$base/ps2" >"$base/ps-seq"
    df_stub="$base/df-stub"
    cat >"$df_stub" <<'STUB'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture %s 0 %s 0%% /\n' 999999 "$(( ${RC_TEST_DF_FREE_MB:-1000} * 1024 ))"
STUB
    chmod +x "$df_stub"
    # Zero installs WITHOUT the explicit-seam refusal (`REAP_RC_EXPLICIT=0` = "these globs are the
    # defaults, a measured-empty box is not a refusal"), and the root BELOW the pressure gate so the
    # only thing that can keep it is the liveness re-probe.
    out="$(RC_TEST_DF_FREE_MB=1000 REAP_RC_DF_BIN="$df_stub" \
           RC_TEST_PS_SEQ="$base/ps-seq" RC_TEST_PS_SEQ_N="$base/ps-n" REAP_RC_PS_BIN="$PS_SEQ_STUB" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=0 \
           REAP_RC_SHARED_GLOBS="$shared" REAP_RC_SHARED_TRIGGER_FREE_MB=40960 \
           REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'U rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ -d "$shared/uv" ] && echo 0 || echo 1)" \
               "a job that appears MID-PASS keeps the shared root even with ZERO installs discovered"
    case_check "$(grep -qF 'reason=toctou:unattributed-runner-process' <<<"$out" && echo 0 || echo 1)" \
               "and the keep NAMES the fresh census witness (reason=toctou:unattributed-runner-process)"
    case_check "$(grep -qF 'installs=0' <<<"$out" && echo 0 || echo 1)" \
               "and the pass really had an EMPTY population — the re-probe, not the Q gate, is what kept it"
    return $((CASE_FAIL > 0))
}

# ── V: THE REMOVAL IS A RENAME, THEN A DELETE (#4169 review, P2) ───────────────────────────────
# ⛔ THE DEFECT THIS PINS: `census_refresh` → liveness probe → `rm -rf` is a check-then-act whose window
# is the WHOLE recursive delete (`REAP_RC_DU_TIMEOUT=120` already concedes minutes on a 21–50 GB tree).
# A listener that picks up a job one second after the probe reads a half-deleted `.cache` for the rest
# of the free — the failing job the class exists to prevent. The candidate is therefore `mv`d to
# `<path>.reaping.<pid>` FIRST (one syscall, so the probe only has to be correct up to it) and the
# renamed tree is freed afterwards.
# Mutant: `mv_path` neutered — the rename is what makes the path stop existing, so nothing is removed
# and the entry is reported `quarantine-failed` (rc 4). That is the assertion's only discriminator.
case_v() { # <owner-script>
    local owner="$1" base inst out rc
    base="$(mktemp -d "$T/v.XXXXXX")"
    inst="$base/gh-runner-v"
    mk_install "$inst"; mk_cache "$inst" 2; idle_work "$inst"
    mk_ps "$base/ps" "$inst" idle
    out="$(run_owner "$owner" "$base" "$base/ps" --apply --min-cache-mb 1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'V rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ ! -e "$inst/.cache" ] && echo 0 || echo 1)" "the idle cache is reclaimed"
    case_check "$(grep -qF "REAPED $inst/.cache how=rm-quarantined" <<<"$out" && echo 0 || echo 1)" \
               "and the record says HOW (how=rm-quarantined: renamed out of a live job's reach, then freed)"
    # ⛔ NO QUARANTINE MAY SURVIVE A SUCCESSFUL FREE: a leftover `.reaping.` tree is bytes nothing in
    # this class matches again, i.e. a leak created by the very fix that closes the window.
    case_check "$( [ -z "$(compgen -G "$inst/.cache.reaping.*" 2>/dev/null)" ] && echo 0 || echo 1)" \
               "the quarantined name does not survive a successful free (no `.reaping.` leftover)"
    return $((CASE_FAIL > 0))
}

# ── W: AN UNSIZED CANDIDATE CLAIMS THE WHOLE CAP (#4169 review, P3) ─────────────────────────────
# ⛔ THE DEFECT THIS PINS: `cap_reached "${size%%[!0-9]*}"` collapsed every `?` (a `du` that timed out
# on a 40–50 GB tree) to `pending=0`, so such a pass was UNCAPPED while its record still printed
# `max_mb=` and the docs promised the cap stops a pass that fires 144×/day. The `du` stub below fails
# for every path, which is exactly the shape of a timed-out probe.
# Mutant: the `?` -> `MAX_MB` claim removed — both caches are then reaped against a 1MB cap.
case_w() { # <owner-script>
    local owner="$1" base a b out rc du_stub
    base="$(mktemp -d "$T/w.XXXXXX")"
    a="$base/gh-runner-w1"; b="$base/gh-runner-w2"
    mk_install "$a"; mk_install "$b"
    mk_cache "$a" 2; mk_cache "$b" 2
    idle_work "$a"; idle_work "$b"
    mk_ps "$base/ps" "$a" idle
    du_stub="$base/du-stub"
    printf '#!/bin/sh\nexit 1\n' >"$du_stub"; chmod +x "$du_stub"
    out="$(RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" REAP_RC_DU_BIN="$du_stub" \
           REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
           REAP_RC_SHARED_GLOBS="$base/no-shared" \
           REAP_RC_MIN_CACHE_MB=1 REAP_RC_STATE_DIR="$base/state" \
           bash "$owner" --apply --max-mb 1 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'W rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$( [ "$(grep -c '^REAPED ' <<<"$out")" = 1 ] && echo 0 || echo 1)" \
               "an UNSIZED candidate claims the whole cap: exactly ONE is reaped against --max-mb 1"
    case_check "$(grep -qE 'capped=1' <<<"$out" && echo 0 || echo 1)" "and the pass reports capped=1"
    case_check "$(grep -qF 'reason=pass-cap' <<<"$out" && echo 0 || echo 1)" \
               "the candidate it did not reach is NAMED (reason=pass-cap)"
    case_check "$(grep -qE 'freed_mb=0 ' <<<"$out" && echo 0 || echo 1)" \
               "and freed_mb stays a MEASURED number: an unmeasured tree credits nothing to it"
    return $((CASE_FAIL > 0))
}

# ── X: A SYMLINKED `.cache` IS A POLICY KEEP, NOT AN ABSTENTION (#4169 review, P3) ──────────────
# ⛔ THE DEFECT THIS PINS: a symlinked `.cache` — the ordinary operator remedy for a small root volume
# — was counted `unmeasurable`, and ANY unmeasurable forces rc 3, so the hourly reaper reddened on a
# healthy box FOREVER with no seam to accept the layout. Nothing is unknown: the class never follows a
# symlink in a delete path, and the line names the entry.
# Mutant: the symlink arm deleted — the link is then a reap candidate and the operator's link is
# destroyed (the class deletes the LINK, which is harmless to the target but is still not its to take).
case_x() { # <owner-script>
    local owner="$1" base inst target out rc
    base="$(mktemp -d "$T/x.XXXXXX")"
    inst="$base/gh-runner-x"; target="$base/big-disk-cache"
    mk_install "$inst"; idle_work "$inst"
    mkdir -p "$target/uv"; dd if=/dev/zero of="$target/uv/blob" bs=1M count=2 >/dev/null 2>&1
    ln -s "$target" "$inst/.cache"
    mk_ps "$base/ps" "$inst" idle
    out="$(run_owner "$owner" "$base" "$base/ps" --apply --min-cache-mb 1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'X rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" \
               "a symlinked cache does NOT fail the pass closed (rc=$rc, want 0 — it used to force 3)"
    case_check "$([ -L "$inst/.cache" ] && echo 0 || echo 1)" "the operator's LINK is untouched"
    case_check "$([ -f "$target/uv/blob" ] && echo 0 || echo 1)" "and so is the tree it points at (never followed in a delete path)"
    case_check "$(grep -qF "KEPT   $inst/.cache reason=symlinked-cache" <<<"$out" && echo 0 || echo 1)" \
               "and it is KEPT BY NAME as the policy decision it is (reason=symlinked-cache)"
    case_check "$(grep -qE 'unmeasurable=0' <<<"$out" && echo 0 || echo 1)" \
               "it is NOT counted unmeasurable (an abstention would drive rc 3)"
    return $((CASE_FAIL > 0))
}

# ── Y: A CACHE THE PRESSURE GATE KEEPS COSTS ONE `df`, NOT A `du` (#4169 review, P3) ─────────────
# ⛔ THE COST THIS PINS: `df` is one syscall, `du` on a 50 GB cache is minutes, and the gate that KEEPS
# an entry does not need its size. The size used to be taken unconditionally at the TOP of
# `sweep_install`, so a `--size-trigger` pass that fired on an unrelated small filesystem paid a `du`
# of every install's cache to decide nothing — while the docs claimed a tick costs one `df`. The `du`
# stub below RECORDS every invocation, so "was it measured?" is an observation and not a reading.
# Mutant: the warm arm measures anyway (the pre-fix shape) — the recorded `du` calls appear.
case_y() { # <owner-script>
    local owner="$1" base inst warm_log cold_log out rc df_stub du_stub
    base="$(mktemp -d "$T/y.XXXXXX")"
    inst="$base/gh-runner-y"
    df_stub="$base/df-stub"; du_stub="$base/du-stub"
    cat >"$df_stub" <<'STUB'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture %s 0 %s 0%% /\n' 999999 "$(( ${RC_TEST_DF_FREE_MB:-0} * 1024 ))"
STUB
    chmod +x "$df_stub"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$RC_TEST_DU_LOG"\nprintf "2048\\t%%s\\n" "$2"\n' >"$du_stub"
    chmod +x "$du_stub"
    warm_log="$base/du-warm.log"; cold_log="$base/du-cold.log"
    run_y() { # <free-mb> <du-log>
        rm -rf "$inst/.cache"; mk_cache "$inst" 2
        RC_TEST_DF_FREE_MB="$1" RC_TEST_DU_LOG="$2" \
        REAP_RC_DF_BIN="$df_stub" REAP_RC_DU_BIN="$du_stub" \
        RC_TEST_PS_TABLE="$base/ps" REAP_RC_PS_BIN="$PS_STUB" \
        REAP_RC_GLOBS="$base/gh-runner-*" REAP_RC_EXPLICIT=1 \
        REAP_RC_SHARED_GLOBS="$base/no-shared" REAP_RC_INSTALL_TRIGGER_FREE_MB=40960 \
        REAP_RC_MIN_CACHE_MB=1 REAP_RC_STATE_DIR="$base/state" \
        bash "$owner" --apply 2>&1
    }
    mk_install "$inst"; idle_work "$inst"; mk_ps "$base/ps" "$inst" idle
    : >"$warm_log"; : >"$cold_log"
    out="$(run_y 200000 "$warm_log")"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'Y1 rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ -e "$inst/.cache/uv/blob" ] && echo 0 || echo 1)" "a WARM cache is kept"
    case_check "$([ ! -s "$warm_log" ] && echo 0 || echo 1)" \
               "and it is NOT `du`-measured at all (the gate keeps it without needing its size)"
    case_check "$(grep -qF "INSTALL $inst cache_mb=not-measured(free-above-trigger)" <<<"$out" && echo 0 || echo 1)" \
               "the reading SAYS the size was not taken (cache_mb=not-measured(...)), not `?`-as-unmeasurable"
    case_check "$(grep -qE 'cache_mb_unmeasured=1' <<<"$out" && echo 0 || echo 1)" \
               "and the SUMMARY counts it, because cache_mb= is then a lower bound"
    # CONTROL: under pressure the size IS measured, so the assertion above can vary.
    out="$(run_y 1000 "$cold_log")"
    case_check "$([ -s "$cold_log" ] && echo 0 || echo 1)" \
               "CONTROL: under pressure the cache IS `du`-measured (the cheap path is not a broken probe)"
    case_check "$(grep -qE 'cache_mb_unmeasured=0' <<<"$out" && echo 0 || echo 1)" \
               "CONTROL: and nothing is reported unmeasured on that pass"
    return $((CASE_FAIL > 0))
}

# ── mutations ─────────────────────────────────────────────────────────────────────────────────
MUT_A="$T/mut-a.sh"; MUT_B="$T/mut-b.sh"; MUT_C="$T/mut-c.sh"; MUT_C2="$T/mut-c2.sh"; MUT_D="$T/mut-d.sh"
MUT_E="$T/mut-e.sh"; MUT_F="$T/mut-f.sh"; MUT_I="$T/mut-i.sh"; MUT_J="$T/mut-j.sh"
MUT_K="$T/mut-k.sh"; MUT_L="$T/mut-l.sh"; MUT_L2="$T/mut-l2.sh"; MUT_M="$T/mut-m.sh"
MUT_N="$T/mut-n.sh"; MUT_O="$T/mut-o.sh"
MUT_P="$T/mut-p.sh"; MUT_Q="$T/mut-q.sh"; MUT_R="$T/mut-r.sh"
MUT_S="$T/mut-s.sh"; MUT_T="$T/mut-t.sh"; MUT_B2="$T/mut-b2.sh"; MUT_U="$T/mut-u.sh"
MUT_B3="$T/mut-b3.sh"; MUT_V="$T/mut-v.sh"; MUT_W="$T/mut-w.sh"; MUT_X="$T/mut-x.sh"
MUT_Y="$T/mut-y.sh"
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
apply_mutation "$OWNER" "$MUT_C2" 's/^    \[ "\$(( FREED_MB + UNSIZED_MB + pending ))" -gt "\$MAX_MB" \]$/    false/' \
    || { printf '  ❌ mutation C2 could not be applied (the cap test moved)\n'; mut_ok=0; }
# ⛔ THE TOCTOU MUTANT NEUTERS THE RE-READ, NOT THE WHOLE ARM: with the refresh stubbed to `:` the probe
# still runs and still consults a census — a FROZEN one — which is precisely the defect the finding
# described. If the case only reddened when the arm was deleted outright, it would not be testing that
# the probe is fresh.
apply_mutation "$OWNER" "$MUT_F" 's/^census_refresh() { census_read; }$/census_refresh() { :; }/' \
    || { printf '  ❌ mutation F could not be applied (the census re-read moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_J" 's/REAP_RC_LOG:-/REAP_RC_LOG_IGNORED:-/' \
    || { printf '  ❌ mutation J could not be applied (the log seam moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_I" 's/^    if \[ "\$pending" -gt "\$MAX_MB" \] && \[ "\$(( FREED_MB + UNSIZED_MB ))" -lt "\$MAX_MB" \]; then$/    if false; then/' \
    || { printf '  ❌ mutation I could not be applied (the oversized-candidate guard moved)\n'; mut_ok=0; }
# ⛔ K — the EXPLICIT-seam refusal gate (the blocking #4169 finding). Without it a glob that matched a
# directory but no install exits 0 with `census=ok installs=0`: an inert class reading healthy.
apply_mutation "$OWNER" "$MUT_K" 's/^    if \[ "\$RC_EXPLICIT" = 1 \]; then$/    if false; then/' \
    || { printf '  ❌ mutation K could not be applied (the explicit-glob refusal gate moved)\n'; mut_ok=0; }
# ⛔ L — the SHARED-root scope guards, one mutant each: the root that IS an install, and the root that
# CONTAINS one (the parent — the exact one-token error the seam invites).
apply_mutation "$OWNER" "$MUT_L" 's/^    if is_install "\$root"; then$/    if false; then/' \
    || { printf '  ❌ mutation L could not be applied (the shared-root-is-an-install guard moved)\n'; mut_ok=0; }
apply_mutation "$OWNER" "$MUT_L2" 's/^    if \[ -n "\$is_inst" \]; then$/    if false; then/' \
    || { printf '  ❌ mutation L2 could not be applied (the shared-root-contains-an-install guard moved)\n'; mut_ok=0; }
# ⛔ M — the shared-root reading is REMOVED from the class total (the marker comment makes it surgical:
# the same accumulate line exists in `sweep_install`, and a bare match would mutate both).
apply_mutation "$OWNER" "$MUT_M" 's/^    case "\$sz" in .*shared-root reading joins the class total$/    :   # shared-root reading joins the class total/' \
    || { printf '  ❌ mutation M could not be applied (the shared-root accumulate moved)\n'; mut_ok=0; }
# ⛔ N — the newest `_diag` log is no longer kept (an open file's unlink reclaims nothing and loses the
# diagnostics of the next failure).
apply_mutation "$OWNER" "$MUT_N" 's/^        if \[ -n "\$newest_log" \] && \[ "\$f" = "\$newest_log" \]; then$/        if false; then/' \
    || { printf '  ❌ mutation N could not be applied (the newest-log keep moved)\n'; mut_ok=0; }
# ⛔ O — the ARGV-INDEPENDENT `_work` witness is deleted (the pre-fix shape: only a literal listener
# argv could make a job visible).
apply_mutation "$OWNER" "$MUT_O" 's/^    newest="\$(work_witness "\$d")"$/    newest=0/' \
    || { printf '  ❌ mutation O could not be applied (the argv-independent _work witness moved)\n'; mut_ok=0; }
# ⛔ P — the DERIVED shared root (the layout is the one source; the env-derived default was falsified by
# the units' own environments).
apply_mutation "$OWNER" "$MUT_P" 's/^    add_shared_dir "\$_p\/_cache" derived$/    :/' \
    || { printf '  ❌ mutation P could not be applied (the derived shared candidate moved)\n'; mut_ok=0; }
# ⛔ Q — the population witness: without it an EMPTY install population answers "not live" vacuously.
apply_mutation "$OWNER" "$MUT_Q" 's/^        if proc_has "Runner.Listener" || proc_has "Runner.Worker"; then$/        if false; then/' \
    || { printf '  ❌ mutation Q could not be applied (the population witness moved)\n'; mut_ok=0; }
# ⛔ R — the free-space gate on the shared root (a warm cache is not a leak).
apply_mutation "$OWNER" "$MUT_R" 's/^    if \[ "\$SHARED_TRIGGER_FREE_MB" -gt 0 \]; then$/    if false; then/' \
    || { printf '  ❌ mutation R could not be applied (the shared free-space gate moved)\n'; mut_ok=0; }
# ⛔ S — the P1 fix's OWN mutant: the witness stops descending INTO the sink, i.e. it reads `_temp`'s own
# mtime again (the pre-fix reading). `case_s` reddens because the second aged entry, and the whole `_diag`
# arm, are then skipped as a job that is not running.
apply_mutation "$OWNER" "$MUT_S" 's/^        if \[ "\$f" = "\$d\/_temp" \]; then$/        if false; then/' \
    || { printf '  ❌ mutation S could not be applied (the sink-excluding witness moved)\n'; mut_ok=0; }
# ⛔ T — the install-arm pressure gate removed: the pass returns to flushing every idle warm cache.
apply_mutation "$OWNER" "$MUT_T" 's/^        elif \[ "\$INSTALL_TRIGGER_FREE_MB" -gt 0 \] && \[ "\$_press" -ge "\$INSTALL_TRIGGER_FREE_MB" \]; then$/        elif false; then/' \
    || { printf '  ❌ mutation T could not be applied (the install free-space gate moved)\n'; mut_ok=0; }
# ⛔ B2 — the #4169 review's rule-3 gap: the `_work/_temp` AGE gate shipped no mutant, so a regression that
# WIDENED the bound was reachable but uncatchable. `case_b` asserts young scratch is kept BY NAME, so a
# `false` here reaps it and reddens the case.
apply_mutation "$OWNER" "$MUT_B2" 's/^        if \[ "\$fm" -gt "\$cutoff_s" \]; then$/        if false; then/' \
    || { printf '  ❌ mutation B2 could not be applied (the _work/_temp age gate moved)\n'; mut_ok=0; }
# ⛔ U — the empty-population witness in `any_live_now`. The mutant makes the non-empty branch
# unconditional, so with ZERO installs the loop runs zero times and the function answers "not live"
# WITHOUT consulting the census it was just handed — the pre-fix defect, exactly.
apply_mutation "$OWNER" "$MUT_U" 's/^    if \[ -n "\$INSTALL_DIRS" \]; then$/    if true; then/' \
    || { printf '  ❌ mutation U could not be applied (the empty-population witness in any_live_now moved)\n'; mut_ok=0; }
# ⛔ B3 — the SECOND age gate (`_diag` logs). The suite shipped a mutant for the scratch bound (`B2`) and
# none for the log bound, so DELETING the log gate was invisible: the row that named it was kept by the
# newest-log arm instead (#4169 review, P2). `case_b` now asserts an OLDER young log beside a newer one,
# which only this gate can keep.
apply_mutation "$OWNER" "$MUT_B3" 's/^        if \[ "\$fm" -gt "\$cutoff_l" \]; then$/        if false; then/' \
    || { printf '  ❌ mutation B3 could not be applied (the _diag age gate moved)\n'; mut_ok=0; }
# ⛔ V — the ATOMIC removal: `mv` out of the way, then free. Neutering the rename is the pre-fix
# check-then-act (nothing is moved, so nothing may be deleted either).
apply_mutation "$OWNER" "$MUT_V" 's/^mv_path() { mv -- "\$1" "\$2" 2>\/dev\/null; }$/mv_path() { :; }/' \
    || { printf '  ❌ mutation V could not be applied (the quarantine rename moved)\n'; mut_ok=0; }
# ⛔ W — an UNSIZED candidate claims the whole cap (reverting it makes a `du`-timeout pass uncapped).
apply_mutation "$OWNER" "$MUT_W" 's/^    case "\$size" in .*_pending="\$MAX_MB" ;; esac$/    :/' \
    || { printf '  ❌ mutation W could not be applied (the unsized-cap claim moved)\n'; mut_ok=0; }
# ⛔ X — a symlinked `.cache` is KEPT as policy; deleting the arm makes the operator's link a candidate.
apply_mutation "$OWNER" "$MUT_X" 's/^        if \[ -L "\$cache" \]; then$/        if false; then/' \
    || { printf '  ❌ mutation X could not be applied (the symlink policy arm in the cache block moved)\n'; mut_ok=0; }
# ⛔ Y — the warm-cache arm measures anyway (the pre-fix shape: a `du` per install on every tick).
apply_mutation "$OWNER" "$MUT_Y" 's/^            warm)         _defer="free-above-trigger" ;;$/            warm)         _defer=""; sz="$(du_mb "$cache")" || sz="" ;;/' \
    || { printf '  ❌ mutation Y could not be applied (the deferred-size arm moved)\n'; mut_ok=0; }

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
expect_pass "K an EXPLICIT glob matching directories but NO install is a REFUSAL" case_k "$OWNER"
expect_pass "L a shared root that IS an install is REFUSED before any delete" case_l "$OWNER"
expect_pass "L2 a shared root that CONTAINS an install is REFUSED (the parent, one token short)" case_l2 "$OWNER"
expect_pass "M cache_mb counts the SHARED root, not only the per-install .cache dirs" case_m "$OWNER"
expect_pass "N the listener's CURRENT _diag log is kept; older aged logs are reaped" case_n "$OWNER"
expect_pass "O a fresh _work keeps the cache without a literal listener argv match" case_o "$OWNER"
expect_pass "P the pool's cache root is reached from the LAYOUT, with no RUNNER_ROOT and no override" case_p "$OWNER"
expect_pass "Q zero installs + an unattributable runner process keeps the shared root (rc 3)" case_q "$OWNER"
expect_pass "R the shared root is pressure-gated: kept when warm, reaped when low, kept when unanswerable" case_r "$OWNER"
expect_pass "S aged scratch and logs are ALL reclaimed in one pass (the class cannot poison its own witness)" case_s "$OWNER"
expect_pass "T the install cache is pressure-gated on its own filesystem: warm kept, low reaped, unanswerable kept" case_t "$OWNER"
expect_pass "U with ZERO installs the per-entry re-probe still asks the FRESH census (no vacuous liveness)" case_u "$OWNER"
expect_pass "V the removal is a RENAME then a delete (how=rm-quarantined, no leftover)" case_v "$OWNER"
expect_pass "W an UNSIZED candidate claims the whole per-pass cap" case_w "$OWNER"
expect_pass "X a symlinked .cache is a POLICY keep, not an abstention (rc 0, link untouched)" case_x "$OWNER"
expect_pass "Y a warm cache costs one df and no du (and says its size was not measured)" case_y "$OWNER"

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
expect_fail "K mutant: the explicit-glob refusal gate deleted"          case_k "$MUT_K"
expect_fail "L mutant: a shared root that IS an install is swept"       case_l "$MUT_L"
expect_fail "L2 mutant: a shared root CONTAINING an install is swept"   case_l2 "$MUT_L2"
expect_fail "M mutant: the shared-root reading is not counted"          case_m "$MUT_M"
expect_fail "N mutant: the newest (open) _diag log is reaped too"       case_n "$MUT_N"
expect_fail "O mutant: the argv-independent _work witness deleted"      case_o "$MUT_O"
expect_fail "P mutant: the derived shared candidate removed"             case_p "$MUT_P"
expect_fail "Q mutant: the population witness removed (vacuous liveness)" case_q "$MUT_Q"
expect_fail "R mutant: the shared free-space gate removed"               case_r "$MUT_R"
expect_fail "S mutant: the witness reads the sink's own mtime again"      case_s "$MUT_S"
expect_fail "T mutant: the install free-space gate removed"               case_t "$MUT_T"
expect_fail "B2 mutant: the _work/_temp age gate removed"                 case_b "$MUT_B2"
expect_fail "U mutant: the empty-population witness in any_live_now is unreachable" case_u "$MUT_U"
expect_fail "B3 mutant: the _diag age gate removed"                        case_b "$MUT_B3"
expect_fail "V mutant: the rename that makes the path vanish is neutered"  case_v "$MUT_V"
expect_fail "W mutant: an unsized candidate claims nothing of the cap"     case_w "$MUT_W"
expect_fail "X mutant: the symlinked-cache policy arm deleted"             case_x "$MUT_X"
expect_fail "Y mutant: a warm cache is du-measured anyway"                 case_y "$MUT_Y"

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
