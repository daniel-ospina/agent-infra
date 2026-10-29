#!/usr/bin/env bash
# ci_runner_pool.test.sh — hermetic suite for scripts/ci_runner_pool.sh (agent-infra#2373).
#
# Run: bash scripts/ci_runner_pool.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. NO network, NO `gh`, NO real runner install,
# NO real /proc/meminfo read: the memory reading, the core count, `uname` and `gh` are shims on
# PATH, the runner release is a stub TEMPLATE under a temp dir, and every instance dir lives under a
# temp RUNNER_ROOT. It runs in BOTH bash lanes (scripts/run-bash-shards.sh).
#
# ⛔ THE INSTALL STUB MODELS GITHUB'S REAL CONTRACT, NOT A CONVENIENT ONE. `config.sh` and `run.sh`
#   resolve their OWN directory (`DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"; cd "$DIR"`) and the
#   listener's argv stays `<dir>/bin/Runner.Listener run` for its whole life — measured on the box.
#   A stub that wrote `.runner` into the CALLER's cwd would pin behaviour GitHub's script does not
#   have: it would have passed while every real add wrote `.runner` into the shared install.
#
# WHY THESE CASES — each one is a measured failure from #2373 (2026-10-22 22:30-22:45Z), or a
# fail-open that would defeat the owner's predicate:
#   * the ADD floor: `pi-runner-cell4-x64-2` was correctly REFUSED at
#     `MemAvailable=2.21 GB is below the 3.5 GB floor`, and the owner made that predicate a
#     requirement (agent-infra#2344, comment 6347825624) — so a below-floor ADD must refuse, must
#     print the reading it used, and must have changed NOTHING.
#   * the FLOOR OPERAND itself: `RUNNER_MEM_FLOOR_MB=3.5G` makes `[ … -lt … ]` ERROR, and an errored
#     test is FALSE under `set -uo pipefail` — so an unvalidated operand silently DISABLES the floor.
#     That is `cannot-measure` here, not an add.
#   * the RESTART floor: two cell-3 runners GitHub showed offline were not missing — their listeners
#     were dead, and `runner-ctl.sh start` brought each back at ~200 MB. The floor applies to ADDING,
#     so a restart on the same low-memory box must still work, and must NOT touch a live listener.
#     The migration population has NO pid file of ours: liveness is the PROCESS TABLE, not a flag.
#   * the CEILING: slots are bounded per box by cores (3 on an 8-core, 2 on a 4-core), and the
#     refusal prints the core count, the ceiling AND the memory reading.
#   * the LABEL: a runner registered without the pool marker is invisible to `ci_runner_gate.sh`
#     forever — registered, advertised, idle. The marker is derived per host, and an arch we cannot
#     name is `cannot-measure` rather than a jobless runner.
#   * the RECONCILIATION pass: idempotent, restarts dead listeners, adds to the ceiling, stops on a
#     gate verdict, and a `cannot-act` is rc 2 — never a pass reported as success.
#   * AN ORPHANED REGISTRATION (#2892) — one GitHub deleted server-side. Measured on `pi-cell-4`
#     2026-10-27: the listener appears and then exits **rc 0** at +4 s with
#     "The runner registration has been deleted from the server", `config.sh --replace` refuses
#     ("already configured"), and NOTHING could retire it. So: `restart` must report rc 6 (not a false
#     `restarted`), `status` must show ORPHANED (not DEAD) and refuse to count it as capacity, and
#     `reclaim` must retire the install — gated on the clock, on evidence newer than the marker, and
#     on a live sibling that holds the name (re-registering there would delete a WORKING runner).
#   * CAPACITY, NOT DIRECTORIES: two installs carrying one `agentName` are one slot (measured: 47 and
#     35, both `pi-runner-cell4-x64-1`), and a box whose root is a MIXED directory (`/opt` with
#     `/opt/containerd` in it) must still be measurable when a non-member is provably not an install.
#   * THE PRIVATE TEMP ROOT (#7815): a self-hosted runner hands every job the box's SHARED `/tmp`, so a
#     suite that guards its temp dir by OWNERSHIP fails on other people's files — a tortoise shard died
#     with `SharedTmpdirScanError: os.scandir('/tmp')` while one unrelated fixture had written 337 GB into
#     `/private/tmp` (#3003). `RUNNER_TEMP` cannot be that root (per job, absent before the first job, and
#     an ABSENT `$TMPDIR` makes Python silently fall back to the shared dir), so every instance gets its OWN
#     stable `$instance/_tmp` (0700) exported as TMPDIR/TMP/TEMP before `exec`, bounded by an mtime sweep —
#     and the sweep must NOT run on a live-listener path, because mtime age is not a holder witness.
#   * FAIL-CLOSED: every unreadable reading is `cannot-measure` (rc 2) and changes nothing.
#   * the MUTATION case at the end proves the floor assertion is LIVE: a copy with the floor
#     comparison removed must stop refusing. A suite that passes against the mutant pins nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL="$SCRIPT_DIR/ci_runner_pool.sh"
CAPACITY_LIB="$SCRIPT_DIR/orchestrator-harness/capacity.sh"
export CAPACITY_LIB

PASS=0
FAIL=0
# ⏭ SKIPS ARE COUNTED AND NAMED: a case that cannot run on this host (a root shell bypasses the
# directory permissions two cases below rely on) must not read as coverage it did not have.
SKIPPED=0
skip() { SKIPPED=$((SKIPPED + 1)); echo "  ⏭ NOT COVERED HERE: $1"; }
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_ne() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3 (both: $1)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
# ⛔ THE NEGATIVE OF assert_contains: "no directory was created" is a statement about ABSENCE that a
#   positive assertion cannot make, and a case that only ever asserts presence passes just as happily
#   against a launcher that creates the directory unconditionally and wrongly.
assert_omits() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi; }
# mode_of <path> — the permission bits, portably (GNU first; BSD on the macOS lane).
mode_of() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }
assert_absent() { if [ -e "$1" ]; then bad "$2 (exists: $1)"; else ok "$2"; fi; }
assert_file() { if [ -f "$1" ]; then ok "$2"; else bad "$2 (absent: $1)"; fi; }
# ⛔ A DIRECTORY IS NOT A FILE: `assert_file` is `[ -f ]`, which is FALSE for the private temp roots
#   this suite asserts on, so using it there reports "absent" for a directory that exists.
assert_dir() { if [ -d "$1" ]; then ok "$2"; else bad "$2 (not a directory: $1)"; fi; }
count_lines() { local n; n="$(wc -l <"$1" 2>/dev/null)" || n=0; printf '%s' "$((n))"; }
# listeners_for <dir> — how many live listeners GitHub would see for that instance dir.
# ⛔ pgrep, not `ps | grep`: a `grep -F <path>` command line CONTAINS the path it searches for, so it
# counts ITSELF and every count is one too high — the exact "first-match reading" defect this repo
# names. pgrep excludes its own process by design.
listeners_for() { local n; n="$(pgrep -f -- "$1/bin/Runner.Listener" 2>/dev/null | wc -l)" || n=0; printf '%s' "$((n))"; }
# listener_pids_for <dir> — the pids themselves, for asserting a LIVE listener was not re-spawned.
listener_pids_for() { pgrep -f -- "$1/bin/Runner.Listener" 2>/dev/null | sort | tr '\n' ' '; }
# slots — the registrations the script would count, read the same way (a dir carrying `.runner`).
slots() { local n; n="$(ls -d "$RUNNER_ROOT"/*/.runner 2>/dev/null | wc -l)" || n=0; printf '%s' "$((n))"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-pool-test.XXXXXX")"
# The ps shim filters the host table to fixture processes, so it needs the fixture root.
export FIXTURE_T="$T"
# ⛔ ONE PATTERN FOR EVERY LISTENER SHAPE, NOT JUST `root-` (#2381 review, P2): the
# symlinked-instance case starts a listener from `$T/real/pi-runner-sym`, which no `$T/root-`
# pattern matches — so one listener (and its `sleep 600`) leaked past cleanup on EVERY run, with the
# instance dir deleted underneath it (measured: 5 orphans after 5 runs, each ppid=1). The suite runs
# in both CI lanes, i.e. on the very boxes this tool manages. `bin/Runner.Listener` is the shape
# every fixture listener has, and it matches no part of the suite's own command line.
# ⛔ AND IT IS ITS OWN FUNCTION SO THE PATTERN IS ASSERTED, NOT MERELY PRESENT (#2381 review round 6,
# P2): the arm was reachable only through a trap, so its regression was invisible — a killed run
# (CI cancel, job timeout, a `timeout`-bounded mutation run) left the tree AND its listeners behind
# (measured on this box: 9 abandoned `ci-runner-pool-test.*` trees, 13 orphaned listeners).
kill_fixture_listeners() { pkill -f "$T/.*bin/Runner\.Listener" 2>/dev/null || true; }
cleanup() {
  kill_fixture_listeners
  # the permission cases leave mode-000/444 dirs, which `rm -rf` cannot traverse
  chmod -R u+rwX "$T" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP   # the EXIT trap then runs cleanup exactly once

BIN="$T/bin"; mkdir -p "$BIN"
export GH_LOG="$T/gh.log" CONFIG_LOG="$T/config.log"
: >"$GH_LOG"; : >"$CONFIG_LOG"

# ── PATH shims: every read a gate branches on, plus `gh` and `uname` ────────────────────────
# `mem_avail_mb` is the seam capacity.sh itself delegates to (`command -v mem_avail_mb`), so this
# stubs the READER the shipped code calls, not the script under test.
cat >"$BIN/mem_avail_mb" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FIXTURE_MEM_MB:-12000}"
STUB
cat >"$BIN/nproc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FIXTURE_NCPU:-8}"
STUB
printf '#!/usr/bin/env bash\nexit 1\n' >"$BIN/sysctl"
cat >"$BIN/uname" <<'STUB'
#!/usr/bin/env bash
case "$*" in *-m*) printf '%s\n' "${FIXTURE_ARCH:-x86_64}"; exit 0 ;; esac
exec /bin/uname "$@"
STUB
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
# ⛔ FIXTURE_GH_LATE_REGISTER plants a registration at TOKEN-MINT time — i.e. AFTER `add` read the
# ceiling but BEFORE it claimed its name. That is the window two passes race in: without the re-check
# after the claim, both clear the same stale snapshot and the box ends above the ceiling (measured: 4
# registrations on a 3-slot box, both rc 0). Planting it here makes the window deterministic.
if [ -n "${FIXTURE_GH_LATE_REGISTER:-}" ]; then
  case "$*" in *registration-token*)
    cp -a "${RUNNER_TEMPLATE:?}" "${RUNNER_ROOT:?}/${FIXTURE_GH_LATE_REGISTER}" 2>/dev/null || true
    : >"${RUNNER_ROOT:?}/${FIXTURE_GH_LATE_REGISTER}/.runner" 2>/dev/null || true ;;
  esac
fi
case "$*" in *registration-token*) printf 'tok-fixture\n'; exit 0 ;; esac
exit 1
STUB
cat >"$BIN/ps" <<'STUB'
#!/usr/bin/env bash
# The process table is the liveness probe. FIXTURE_PS_FAIL makes it unreadable, which must be
# `cannot-measure` — never "no listeners", which would double-start a listener.
[ "${FIXTURE_PS_FAIL:-0}" = 1 ] && { echo "ps: cannot read /proc" >&2; exit 1; }
[ "${FIXTURE_PS_EMPTY:-0}" = 1 ] && exit 0
# ⛔ THE CALL COUNTER IS READ BEFORE THE TABLE IS PRINTED, so a seam can refuse THIS read (#2892
# review round 4, P1). It used to be incremented at the bottom of the stub, which made every
# "fail from the n-th read on" seam either impossible or silently off by one.
f="${FIXTURE_T:?}/.ps-count"
c=0; [ -f "$f" ] && c="$(cat "$f" 2>/dev/null || printf 0)"
case "$c" in ''|*[!0-9]*) c=0 ;; esac
c=$((c + 1)); printf '%s' "$c" >"$f" 2>/dev/null || true
# ⛔ FIXTURE_PS_FAIL_AFTER=<n> lets the FIRST n reads through and fails every read after that — the
# only way to reach a probe that runs LATER than the pool rows (a quarantine row in `status`), which
# is exactly where a failed read was being READ AS A DEAD LISTENER and printed as "rm -rf as its
# owner" over a runner that might be live.
case "${FIXTURE_PS_FAIL_AFTER:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$c" -gt "$FIXTURE_PS_FAIL_AFTER" ] && { echo "ps: cannot read /proc" >&2; exit 1; } ;;
esac
# ⛔ THE FIXTURE TABLE IS THE SUITE'S OWN PROCESSES ONLY (#2381 review, P1). The suite models a
# listener with a real process under $T, but the HOST also runs runners (measured: three live
# listeners under /opt/gh-runner-* on the boxes this suite runs on). Reading the whole host table
# would make the new outside-the-root arm fire in every case — "the pool is complete" would fail on
# exactly the boxes this tool manages. Filtering to lines that name a fixture path keeps the fixture
# hermetic; FIXTURE_PS_EXTRA is the only way to plant a listener elsewhere.
out="$(/bin/ps "$@")" || { printf '%s\n' "$out" >&2; exit 1; }
# ⛔ THE FILTER IS THIS CASE'S POOL, NOT THE WHOLE FIXTURE TEMP DIR (#2381 review round 6, P2): a
# `$FIXTURE_T/` filter lets every EARLIER case's leaked listener stay in the table, so once the
# wrapper-prefix arm below was fixed the whole suite went red on fixtures it never planted — and the
# "same box with no outside listener" control was really asserting "the leaked listeners are
# invisible". `$T/real/` is included because the symlinked-instance case legitimately starts its
# listener at the symlink's PHYSICAL target.
printf '%s\n' "$out" | while IFS= read -r line; do
  case "$line" in
    *"${RUNNER_ROOT:?}/"*) printf '%s\n' "$line" ;;
    *"${FIXTURE_T:?}/real/"*) printf '%s\n' "$line" ;;
  esac
done
# ⛔ A REAL PROCESS TABLE IS NEVER EMPTY, and the script refuses an EMPTY one as `cannot-measure`
#   (`ps` listed no processes = I could not look). The shim used to stay non-empty only because its OWN
#   command line contained the fixture path; once the filter is per-case, that accident is gone, so a
#   baseline system row stands in for the processes a real box always has. FIXTURE_PS_EMPTY still
#   models the unmeasurable table, above.
printf '    %s /sbin/init\n' 1
# ⛔ FIXTURE_PS_OUTSIDE_AFTER=<n> plants the extra line only from the (n+1)-th ps call on — the seam
# that reaches a guard on a LATER read, the same way FIXTURE_LS_FAIL_AFTER does for the listing. It is
# the ONLY way to pin `add`'s POST-claim completeness re-check: an outside listener that appears
# during the token mint (#2381 review round 6, P2). (The counter itself is read at the top of the stub.)
if [ -n "${FIXTURE_PS_EXTRA:-}" ]; then
  if [ -n "${FIXTURE_PS_OUTSIDE_AFTER:-}" ]; then
    [ "$c" -gt "$FIXTURE_PS_OUTSIDE_AFTER" ] && printf '%s\n' "$FIXTURE_PS_EXTRA"
  else
    printf '%s\n' "$FIXTURE_PS_EXTRA"
  fi
fi
exit 0
STUB
cat >"$BIN/hostname" <<'STUB'
#!/usr/bin/env bash
printf 'fixturebox\n'
STUB
cat >"$BIN/ls" <<'STUB'
#!/usr/bin/env bash
# The pool listing is `ls -A "$RUNNER_ROOT"`. FIXTURE_LS_FAIL makes THAT readdir fail while the mode
# bits still allow it (an ACL/SELinux denial, a transient error on a mounted root) — the one shape the
# permission checks cannot reach, so it is the arm that genuinely proves the listing is checked.
# FIXTURE_LS_FAIL_AFTER=<n> lets the FIRST n root listings through and fails the next one: that is the
# only way to reach a guard on a LATER listing (a pass that listed the pool once already), which is
# where `reconcile`'s add loop re-reads it.
ls_root_listed() { # counts this root-listing call and says whether it may proceed
  local f c
  f="${RUNNER_ROOT:?}/.ls-count"
  c=0; [ -f "$f" ] && c="$(cat "$f" 2>/dev/null || printf 0)"
  case "$c" in ''|*[!0-9]*) c=0 ;; esac
  c=$((c + 1)); printf '%s' "$c" >"$f" 2>/dev/null || true
  [ "$c" -le "$1" ]
}
for a in "$@"; do
  if [ "$a" = "${RUNNER_ROOT:-}" ]; then
    if [ "${FIXTURE_LS_FAIL:-0}" = 1 ]; then
      echo "ls: cannot open directory '$a': Permission denied" >&2; exit 2
    fi
    if [ -n "${FIXTURE_LS_FAIL_AFTER:-}" ] && ! ls_root_listed "$FIXTURE_LS_FAIL_AFTER"; then
      echo "ls: cannot open directory '$a': Permission denied" >&2; exit 2
    fi
  fi
done
if [ -x /bin/ls ]; then exec /bin/ls "$@"; fi
exec /usr/bin/ls "$@"
STUB
# `curl` is the retirement CLOCK GUARD's probe (`reclaim` compares this against the local clock). A
# fixture that answered "network error" to every probe would make every shrink case cannot-measure,
# so the healthy path must be a working probe — and FIXTURE_TIME_SKEW_S / FIXTURE_CURL_FAIL are the
# two real shapes it has to tell apart: a box whose clock is wrong, and a box that cannot be dated.
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
[ "${FIXTURE_CURL_FAIL:-0}" = 1 ] && exit 6
skew="${FIXTURE_TIME_SKEW_S:-0}"
now="$(date -u +%s)"
epoch=$((now - skew))
if date -u -d "@$epoch" +%s >/dev/null 2>&1; then
  stamp="$(date -u -d "@$epoch" '+%a, %d %b %Y %H:%M:%S')"
else
  stamp="$(date -u -r "$epoch" '+%a, %d %b %Y %H:%M:%S')"
fi
printf 'HTTP/2 200\r\ndate: %s GMT\r\n\r\n' "$stamp"
STUB
chmod +x "$BIN"/*

# ── the runner release, stubbed to GitHub's real shape ──────────────────────────────────────
TEMPLATE="$T/template"; mkdir -p "$TEMPLATE/bin"
cat >"$TEMPLATE/config.sh" <<'STUB'
#!/usr/bin/env bash
# GitHub's config.sh resolves ITS OWN directory and cds there — the caller's cwd is ignored.
SOURCE="${BASH_SOURCE[0]}"
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
cd "$DIR"
printf '%s | %s\n' "$PWD" "$*" >>"${CONFIG_LOG:?}"
# ⛔ --url IS REQUIRED IF UNATTENDED (GitHub's own usage text: "Repository to add the runner to.
#   Required if unattended"), and the runner THROWS rather than defaulting it to the token's repo —
#   so this stub refuses exactly as config.sh does. A stub that ignored argv let the shipped `add`
#   omit --url and stay GREEN: this file modelled the cwd contract and the listener argv, but not
#   the ONE argument that decides whether a registration happens at all. The URL is PARSED, not
#   prefix-matched, so `--url https://github.com/` (no owner/name) is refused the way config refuses it.
cfg_url=""; cfg_prev=""
for a in "$@"; do [ "$cfg_prev" = "--url" ] && cfg_url="$a"; cfg_prev="$a"; done
case "$cfg_url" in
  https://github.com/?*/?*) : ;;
  *) echo "config.sh: Invalid configuration provided for url. Terminating unattended configuration." >&2; exit 1 ;;
esac
case " $* " in *" --name ${FIXTURE_CONFIG_FAIL_NAME:-__none__} "*) echo "config.sh: a runner with this name already exists" >&2; exit 1 ;; esac
if [ -n "${FIXTURE_CONFIG_TAKEN:-}" ]; then
  nm=""; prev=""
  for a in "$@"; do [ "$prev" = "--name" ] && nm="$a"; prev="$a"; done
  case " ${FIXTURE_CONFIG_TAKEN} " in *" ${nm##*-} "*) echo "config.sh: a runner with this name already exists" >&2; exit 1 ;; esac
fi
[ "${FIXTURE_CONFIG_FAIL:-0}" = 1 ] && { echo "config.sh: the registration token is invalid" >&2; exit 1; }
[ "${FIXTURE_CONFIG_NOMARKER:-0}" = 1 ] && exit 0
: >.runner
exit 0
STUB
cat >"$TEMPLATE/run.sh" <<'STUB'
#!/usr/bin/env bash
SOURCE="${BASH_SOURCE[0]}"
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
cd "$DIR"
# ⛔ GITHUB'S run.sh SOURCES `.env` — so this stub is the ONE place the real contract is observable:
#   whatever `.env` names becomes the environment the listener and every job step run under. A stub
#   that skipped it would pass while the SHIPPED launcher left a TMPDIR nobody created, because the
#   only thing that consumes `TMPDIR=` is the file this stub was ignoring (agent-infra#2937).
if [ -f .env ]; then . ./.env; fi
# ⛔ AND IT RECORDS WHAT IT INHERITED, from INSIDE the listener, at the instant the real run.sh would
#   hand that env to a job. `absent` here is precisely the state in which every job on the instance
#   dies at `mktemp` while GitHub reports the runner `online` — so the ordering the fix claims
#   (directory created BEFORE exec) is asserted, not merely the directory's existence afterwards.
if [ -n "${FIXTURE_TMPDIR_LOG:-}" ]; then
  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR:-}" ]; then printf 'present %s\n' "$TMPDIR"
  else printf 'absent %s\n' "${TMPDIR:-<unset>}"; fi >>"$FIXTURE_TMPDIR_LOG"
fi
exec "$DIR/bin/Runner.Listener" run
STUB
cat >"$TEMPLATE/bin/Runner.Listener" <<'STUB'
#!/usr/bin/env bash
# ⛔ argv must STAY "<dir>/bin/Runner.Listener run" — the real binary never execs anything else, so a
# stub that did would let a broken argv matcher pass. Hence a CHILD sleep, killed on TERM/EXIT.
# ⛔ THE `.orphan` MARKER MODELS A REGISTRATION GITHUB DELETED (#2892), and it must reproduce BOTH
# halves of the measured shape: the process APPEARS (so a start reads as successful) and then goes
# away ~0.6 s later, AFTER printing GitHub's own line — with **rc 0**, which is exactly what the box
# did (`DIED rc=0 after 4s`, pi-cell-4 2026-10-27T04:19Z). A stub that exited non-zero would let an
# exit-status classifier pass, and the shipped code must classify by the message instead.
INST="$( cd -P "$( dirname "$( dirname "${BASH_SOURCE[0]}" )" )" && pwd )"
if [ -e "$INST/.orphan" ]; then
  sleep 0.6
  printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n'
  exit 0
fi
sleep 600 &
child=$!
trap 'kill "$child" 2>/dev/null' EXIT TERM INT
wait "$child"
STUB
chmod +x "$TEMPLATE/config.sh" "$TEMPLATE/run.sh" "$TEMPLATE/bin/Runner.Listener"

export RUNNER_TEMPLATE="$TEMPLATE"
export RUNNER_MEM_FLOOR_MB=3584 RUNNER_CORES_PER_SLOT=3 RUNNER_START_SETTLE_S=1
export RUNNER_POOL_REPO="daniel-ospina/tortoise"
export RUNNER_LABELS=self-hosted-x64
export PATH="$BIN:$PATH"

# ⛔ THE SHIPPED FUNCTION BODIES, VERBATIM (never a re-typed copy) — `main` runs only at the bottom of
#   the script, so extracting a function is how a unit-level arm is asserted. ⛔ THE SED SCRIPT IS
#   SINGLE-QUOTED ON PURPOSE: bash 3.2 (macOS's /bin/bash) brace-expands the `{/,/^}` range inside a
#   DOUBLE-quoted sed script that reaches it through `eval`, which split the expression into two nonsense
#   words and made every assertion in the owner-guard case below pass vacuously on that host.
shipped_fns() { # <pool> <fn>…
  local pool="$1" fn; shift
  for fn in "$@"; do sed -n '/^'"$fn"'() {/,/^}/p' "$pool"; done
}
# ⛔ THE FULL SET THE OWNER GUARD NEEDS: `ensure_tmpdir` delegates the private root to
#   `ensure_private_tmp`, which delegates the owner comparison to `tmp_owner_guard` and the age bound to
#   `sweep_tmp_root` — extracting only the entry point would leave those undefined and every assertion
#   would then be measuring a command-not-found instead of the guard.
TMPDIR_FNS=(instance_tmpdir instance_tmp_root sweep_tmp_root tmp_owner_guard ensure_private_tmp ensure_tmpdir)

run()      { bash "$POOL" "$@" 2>&1; }
rc_of()    { bash "$POOL" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
reset_logs() { : >"$GH_LOG"; : >"$CONFIG_LOG"; }
fresh_pool() { RUNNER_ROOT="$T/root-$1"; export RUNNER_ROOT; rm -rf "$RUNNER_ROOT"; mkdir -p "$RUNNER_ROOT"; rm -f "$T/.ps-count"; }
# register <name> — what a hand-provisioned runner looks like: a complete install with `.runner` and
# NO pid file of ours. This is the migration population (two such runners were the incident).
register() { cp -a "$TEMPLATE" "$RUNNER_ROOT/$1"; : >"$RUNNER_ROOT/$1/.runner"; }
# orphanize <name> — model a registration GITHUB DELETED: its start IS refused (the stub prints
# GitHub's own line and exits 0, the measured shape). ⛔ A FIXTURE THAT EXPECTS A RETIREMENT MUST
# CALL THIS (#2892 review round 3, P1): a log line on its own is no longer proof — `reclaim` starts
# the listener and believes only a refusal it dated ITSELF, because a skew-era line survives a clock
# that was later corrected (actions/runner#4648).
orphanize() { : >"$RUNNER_ROOT/$1/.orphan"; }

# ══ 1. ADD above the floor: a complete install per instance, configured THERE ════════════════
echo "── add: above the floor ──"
fresh_pool add; reset_logs
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-a)"
assert_eq "$?" "0" "add above the floor exits 0"
assert_contains "$out" "reading: MemAvailable=11.72 GB (12000 MB) floor=3.50 GB ncpu=8 ceiling=3 slots=0 labels=self-hosted-x64" \
  "add PRINTS THE READING IT USED, including the label it registered (owner decision #2344)"
assert_contains "$out" "added name=pi-runner-a" "add reports the runner it added"
assert_file "$RUNNER_ROOT/pi-runner-a/.runner" "the registration marker lands in the INSTANCE dir"
assert_file "$RUNNER_ROOT/pi-runner-a/config.sh" "the instance dir holds a complete install"
assert_absent "$TEMPLATE/.runner" "the shared template was not mutated"
assert_contains "$(cat "$CONFIG_LOG")" "$RUNNER_ROOT/pi-runner-a | " \
  "config.sh ran with ITS OWN directory as cwd (GitHub's contract, not the caller's)"
assert_contains "$(cat "$CONFIG_LOG")" "--labels self-hosted-x64" "config.sh was given the pool marker"
assert_contains "$(cat "$CONFIG_LOG")" "--token tok-fixture" "config.sh was given a registration token"
# ⛔ The URL is the argument whose absence made every real `add` fail while the suite stayed green.
assert_contains "$(cat "$CONFIG_LOG")" "--url https://github.com/daniel-ospina/tortoise" \
  "config.sh was given the REPO URL — unattended config refuses to run without one"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-a")" "1" "a listener is running for the instance dir"

# ⛔ …AND IT MUST FOLLOW THE REPO, not be the default written twice: this case runs a NON-default repo
#   and asserts the URL follows it (a hardcoded default passes the assertion above and fails here).
fresh_pool urlfollow; reset_logs
out="$(RUNNER_POOL_REPO=acme/other FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-url)"
assert_eq "$?" "0" "an add with a NON-DEFAULT RUNNER_POOL_REPO succeeds"
assert_contains "$(cat "$CONFIG_LOG")" "--url https://github.com/acme/other" \
  "config.sh was given a URL DERIVED from RUNNER_POOL_REPO (a hardcoded default would fail here)"

# ⛔ The repo has TWO consumers (the gh token path and the registration URL), so a URL-form or
#   multi-slash value must be refused as an OPERAND — not discovered per name, as rc 5, after a full
#   runner install was copied and a token spent.
for bad_repo in 'https://github.com/acme/other' 'acme' 'acme/' 'a/b/c'; do
  out="$(RUNNER_POOL_REPO="$bad_repo" FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-badrepo)"
  assert_eq "$?" "2" "RUNNER_POOL_REPO='$bad_repo' is cannot-measure (rc 2), never a malformed --url"
  assert_contains "$out" "cannot-measure why=repo-unreadable" "it names the operand"
  assert_absent "$RUNNER_ROOT/pi-runner-badrepo" "and nothing was created"
done

# ── (1) a symlinked template must still produce a COPY ─────────────────────────────────────
# `cp -a` is `--no-dereference`: with a symlinked template it would create a SYMLINKED instance, so
# every alias shares one install and one listener (a dead one reads LIVE forever, and the template is
# mutated). The copy is dereferenced, and a symlink result is refused.
echo "── add: a symlinked template ──"
fresh_pool symtemplate; reset_logs
ln -s "$TEMPLATE" "$T/pristine-release-link"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/pristine-release-link" run add --name pi-runner-sym)"
assert_eq "$?" "0" "add from a SYMLINKED template succeeds"
if [ -L "$RUNNER_ROOT/pi-runner-sym" ]; then
  bad "the instance is a real directory, not a symlink to the shared install"
else
  ok "the instance is a real directory, not a symlink to the shared install"
fi
assert_file "$RUNNER_ROOT/pi-runner-sym/.runner" "the copy has its own .runner"
assert_absent "$TEMPLATE/.runner" "the pristine release was NOT mutated by the add"
assert_eq "$(slots)" "1" "one add is one slot (the template is never counted)"

# ── (2) the template is never a slot, in the SHIPPED nesting ───────────────────────────────
# The default is `RUNNER_TEMPLATE=$RUNNER_ROOT/_template` — INSIDE the glob that lists registrations.
# A `.runner` there must not become a slot, a `status` row, or something the pass starts a listener in
# (a listener inside the pristine release would then be COPIED into every later instance).
echo "── the nested template is never a runner ──"
fresh_pool nesting; reset_logs
mkdir -p "$RUNNER_ROOT/_template"; cp -a "$TEMPLATE/." "$RUNNER_ROOT/_template/"; : >"$RUNNER_ROOT/_template/.runner"
register pi-runner-real
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$RUNNER_ROOT/_template" run status --all)"
assert_contains "$out" "summary live=0 dead=1 slots=1" "the nested template is NOT a slot"
if grep -qF "_template" <<<"$out"; then
  bad "status does not list the template as a runner"
else
  ok "status does not list the template as a runner"
fi
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$RUNNER_ROOT/_template" run reconcile --dry-run)"
if grep -qF "for name=_template" <<<"$out"; then
  bad "the pass does not start a listener inside the pristine release"
else
  ok "the pass does not start a listener inside the pristine release"
fi

# ── the template exclusion must NOT depend on the template RESOLVING ─────────────────────
# `tpl` was the only bound: an unresolvable RUNNER_TEMPLATE left it empty, the `[ -z "$tpl" ] || …`
# guard then evaluated TRUE, and the pristine release was emitted as a runner — so `reconcile`
# started a listener INSIDE it (which every later `add` copies into the instance, `.runner` and
# all) and `slots` counted it against the ceiling. Here the release is still unpacking (the env var
# points somewhere that does not exist yet) while `$RUNNER_ROOT/_template` carries a stray marker.
echo "── the template is excluded even when RUNNER_TEMPLATE does not resolve ──"
fresh_pool nestunres; reset_logs
mkdir -p "$RUNNER_ROOT/_template"; cp -a "$TEMPLATE/." "$RUNNER_ROOT/_template/"; : >"$RUNNER_ROOT/_template/.runner"
register pi-runner-real
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/nothing-unpacked-yet" run status)"
assert_contains "$out" "summary live=0 dead=1 slots=1" \
  "an unresolvable template does not turn the pristine release into a slot"
if grep -qF "_template" <<<"$out"; then
  bad "an unresolvable template does not list the pristine release as a runner"
else
  ok "an unresolvable template does not list the pristine release as a runner"
fi
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/nothing-unpacked-yet" run reconcile)"
if grep -qF "name=_template" <<<"$out"; then
  bad "an unresolvable template does not make the pass start a listener inside the release"
else
  ok "an unresolvable template does not make the pass start a listener inside the release"
fi
assert_eq "$(listeners_for "$RUNNER_ROOT/_template")" "0" "no listener was started inside the pristine release"

# ── the template exclusion must NOT depend on the release being NAMED `_template` ────────
# The default name has its own arm, and it answers every fixture whose release IS `_template` — so
# deleting the two NAME/PHYSICAL arms left this suite green while a release under any other name was
# listed as a DEAD runner, counted against the ceiling (`reconcile` then stopped one slot short) and had
# a listener started inside it — whose `.runner` every later `add` copies into the instance, voiding the
# proof-of-registration check. This fixture uses a non-default name so only those two arms can answer.
echo "── the template is excluded even when it is reached through another path ──"
fresh_pool namedtpl; reset_logs
cp -a "$TEMPLATE" "$RUNNER_ROOT/release-2"; : >"$RUNNER_ROOT/release-2/.runner"
# ⛔ THE TEMPLATE PATH MUST NOT RESOLVE LITERALLY TO THE ENUMERATED DIR, or the NAME arm answers the
#   fixture and the PHYSICAL arm can be deleted alone with the suite green (measured). A symlinked
#   template is the shape `tpl` exists for — and the measured outcome of losing it is a release listed
#   as a DEAD runner with a listener started inside it.
ln -s "$RUNNER_ROOT/release-2" "$T/rel-alias"
register pi-runner-real2
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/rel-alias" run status)"
assert_contains "$out" "summary live=0 dead=1 slots=1" \
  "a pristine release reached through a symlinked template path is not a slot"
if grep -qF "release-2" <<<"$out"; then
  bad "a release behind a symlinked template path is not listed as a runner"
else
  ok "a release behind a symlinked template path is not listed as a runner"
fi
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/rel-alias" run reconcile)"
assert_eq "$(listeners_for "$RUNNER_ROOT/release-2")" "0" \
  "no listener was started inside the release behind the symlinked template path"
assert_contains "$out" "ceiling reached slots=3 ceiling=3" \
  "and the pass still reached the ceiling (the release did not eat a slot)"

# ── the pool ROOT's own readdir is the arm the permission checks cannot replace ────────
# A root whose `readdir` fails while both mode bits pass (an ACL/SELinux denial, a transient error on a
# mounted root) read as an EMPTY pool — the original over-add class. The `ls -A` probe is that arm; the
# mode-bit fixtures (300/444/000) are all caught by `-r`/`-x` and cannot pin it.
echo "── a readdir failure on a healthy-mode root ──"
fresh_pool readdir; reset_logs
register pi-runner-r1
out="$(FIXTURE_LS_FAIL=1 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "2" "a failing readdir on a healthy-mode root is cannot-measure, not an empty pool"
assert_contains "$out" "cannot-measure why=runner-root-unreadable" "it names the unreadable root"
assert_eq "$(FIXTURE_LS_FAIL=1 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of add --name pi-runner-r2)" "2" \
  "and an add refuses rather than adding above an unreadable ceiling"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "nothing was registered"

# ⛔ A LISTING THAT FAILS **LATER** IN THE PASS IS ITS OWN GUARD: `reconcile` re-reads the pool before
#   every add, and losing that re-read flipped a fail-closed pass into rc 0 / `cannot=0` with an
#   INVENTED reason (`ceiling reached slots= ceiling=3`) — the monitored rc + cannot= pair read a
#   healthy box over a pool it never listed. The counter lets the restart arm's listing through and
#   fails the add loop's, which is the only way to reach a guard on a second listing.
echo "── reconcile: a listing that fails inside the add loop ──"
fresh_pool latefail; reset_logs
register pi-runner-lf1
out="$(FIXTURE_LS_FAIL_AFTER=1 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "2" "a listing failure inside the add loop stops the pass (rc 2, not a clean 0)"
assert_contains "$out" "cannot=2" "the summary counts BOTH unmeasured listings (the loop's and the final one)"
assert_contains "$out" "the pass stopped; nothing was added" "and the measured reason is published"
if grep -qF "ceiling reached" <<<"$out"; then
  bad "the pass invents 'ceiling reached' when it never listed the pool"
else
  ok "the pass invents no ceiling verdict it did not measure"
fi
rm -f "$RUNNER_ROOT/.ls-count"

# ⛔ THE FINAL LISTING IS ITSELF A GATE OPERAND (#2381 review, P1). `reconcile` re-lists the pool to
#   print its summary, and that listing used to be written as `slots || SLOTS="unmeasured"` — a
#   NON-INTEGER then reached `[ "$SLOTS" -lt "$CEILING" ]`, which ERRORS and, under `set -uo pipefail`
#   with no `-e`, reads as FALSE: the "provisioned nothing" guard was silently DISABLED and the pass
#   exited 0 over a pool it could not list. This case fails the LAST listing only (the restart arm's
#   and the add loop's succeed, so `cannot` starts at 0), which is the only shape that discriminates:
#   the pass must NOT certify an unmeasured pool, whatever the loop managed to do.
echo "── reconcile: a listing that fails at the FINAL summary ──"
fresh_pool finallist; reset_logs
register pi-runner-fl1
out="$(FIXTURE_LS_FAIL_AFTER=2 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=3 run reconcile)"
assert_eq "$?" "2" "a listing failure at the FINAL summary refuses (rc 2, never a clean 0)"
assert_contains "$out" "cannot=1" "the summary counts the unmeasured final listing"
assert_contains "$out" "slots=unmeasured" "and it prints no stale slot count as if it had been read"

# ══ 2. ADD below the floor: REFUSED, the reading printed, nothing changed ═══════════════════
echo "── add: below the memory floor ──"
fresh_pool floor; reset_logs
out="$(FIXTURE_MEM_MB=2263 FIXTURE_NCPU=8 run add --name pi-runner-b)"
assert_eq "$?" "3" "add below the floor exits 3 (REFUSED)"
assert_contains "$out" "REFUSED add name=pi-runner-b" "the refusal names itself"
assert_contains "$out" "MemAvailable=2.21 GB is below the 3.50 GB floor" \
  "the refusal prints the reading it used, in the measured shape"
assert_contains "$out" "read 2263 MB, floor 3584 MB" "the refusal also prints the raw MB it compared"
assert_absent "$RUNNER_ROOT/pi-runner-b" "a refused add creates no instance dir"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "a refused add never runs config.sh"
assert_eq "$(count_lines "$GH_LOG")" "0" "a refused add never mints a registration token"

# ══ 3. FAIL-CLOSED on the gate's own OPERANDS — an errored test is FALSE, i.e. gate DISABLED ══
echo "── fail-closed: the gate operands ──"
fresh_pool operand; reset_logs
out="$(FIXTURE_MEM_MB=2263 FIXTURE_NCPU=8 RUNNER_MEM_FLOOR_MB=3.5G run add --name pi-runner-op)"
assert_eq "$?" "2" "a NON-NUMERIC floor is cannot-measure (rc 2), never an add"
assert_contains "$out" "cannot-measure why=floor-unreadable" "the unreadable floor names itself"
assert_absent "$RUNNER_ROOT/pi-runner-op" "an unreadable floor adds NOTHING (the fail-open it closes)"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_MEM_FLOOR_MB=120000000000000000000 run add --name pi-runner-op3)"
assert_eq "$?" "2" "a 20-DIGIT floor is cannot-measure too (test errors on it, which reads as false)"
assert_contains "$out" "cannot-measure why=floor-unreadable" "it names the operand"
assert_absent "$RUNNER_ROOT/pi-runner-op3" "it added nothing"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_CORES_PER_SLOT=0 run add --name pi-runner-op2)"
assert_eq "$?" "2" "a zero cores-per-slot is cannot-measure (rc 2)"
assert_contains "$out" "cannot-measure why=cores-per-slot-unreadable" "it names the operand"
assert_absent "$RUNNER_ROOT/pi-runner-op2" "it added nothing"

# ── (5) a directory that is not ours is refused, never adopted and deleted ──────────────────
# The unregistered-directory arm is the guard that stops `add` from `cp`-ing INTO a foreign dir (which
# then makes its config.sh non-executable, and the failure path `rm -rf`s it).
echo "── add: a directory that is not ours ──"
fresh_pool foreign; reset_logs
mkdir -p "$RUNNER_ROOT/pi-runner-foreign"; echo "someone else's work" >"$RUNNER_ROOT/pi-runner-foreign/keep.txt"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-foreign)"
assert_eq "$?" "4" "a directory without a .runner is name-unavailable (rc 4), not adoptable"
assert_contains "$out" "path=$RUNNER_ROOT/pi-runner-foreign already exists" "the refusal names what it found"
assert_file "$RUNNER_ROOT/pi-runner-foreign/keep.txt" "the foreign directory was NOT deleted"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "no config.sh ran inside it"

# ── a REGULAR FILE at the target path is refused, and SURVIVES ──────────────────────────
# `[ -d "$dir" ]` let a file through to `cp -aL`; the copy then failed and the cleanup path ran
# `rm -rf "$dir"` — deleting an operator's file to tidy up after the tool's own failure. Data loss
# reached from a typo in a runner name, so the guard is `-e` (anything already there) and the file
# must still be byte-identical after the refusal.
echo "── add: a regular FILE at the target path ──"
fresh_pool foreignfile; reset_logs
printf 'operator notes — not a runner\n' >"$RUNNER_ROOT/pi-runner-file"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-file)"
assert_eq "$?" "4" "a regular file at the target path is name-unavailable (rc 4)"
assert_contains "$out" "already exists" "the refusal says the path exists"
assert_eq "$(cat "$RUNNER_ROOT/pi-runner-file" 2>/dev/null)" "operator notes — not a runner" \
  "the operator's FILE was not deleted by add's failure cleanup"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-file")" "0" "no listener was started for a file"

# ⛔ AND A DANGLING SYMLINK at the target is the same "already exists" case: `[ -e ]` is false for it,
#   so without the `-L` half the check falls through to the CLAIM — which happens AFTER the
#   registration token was minted. The refusal then costs a single-use token and blames "another pass"
#   that does not exist.
echo "── add: a dangling symlink at the target path ──"
fresh_pool foreigndangle; reset_logs
ln -s "$T/no-such-target" "$RUNNER_ROOT/pi-runner-dangle"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-dangle)"
assert_eq "$?" "4" "a dangling symlink at the target path is name-unavailable (rc 4)"
assert_contains "$out" "already exists" "the refusal says the path exists, not that another pass took it"
assert_eq "$(grep -c 'registration-token' "$GH_LOG" 2>/dev/null || true)" "0" \
  "and no single-use registration token was minted for it"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-dangle")" "0" "and no listener was started for it"

# ══ 4. ADD above the CORE-AWARE ceiling ═════════════════════════════════════════════════════
echo "── add: above the core-aware ceiling ──"
fresh_pool ceiling; reset_logs
register pi-runner-1; register pi-runner-2
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=4 run add --name pi-runner-c)"
assert_eq "$?" "3" "add above the ceiling exits 3 (REFUSED)"
assert_contains "$out" "slots=2 ceiling=2 ncpu=4" "the ceiling is core-aware (4 cores -> 2 slots)"
assert_contains "$out" "MemAvailable=11.72 GB floor=3.50 GB" \
  "the ceiling refusal prints the memory reading too (both readings, #2373 item 3c)"
assert_absent "$RUNNER_ROOT/pi-runner-c" "a ceiling refusal creates no instance dir"
assert_contains "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-c)" "ncpu=8 ceiling=3" \
  "the same slot count is ACCEPTED on an 8-core box"

# ── a TAKEN NAME reports 4 even when the box is ALSO at a gate ─────────────────────────────
# The name checks used to sit AFTER the floor/ceiling gates, so a taken name on a full box returned
# 3 — a caller branching on the documented "4 = that name is taken, try another" could never see the
# name condition it asked about (this is the reconcile retry branch). rc 4 is the answer about the
# NAME, and it is a fact about the request rather than about the box.
echo "── add: a taken name outranks a gate verdict ──"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=4 rc_of add --name pi-runner-1)" "4" \
  "a taken name reports 4, not the ceiling's 3, on a box at its ceiling"
assert_eq "$(FIXTURE_MEM_MB=100 FIXTURE_NCPU=8 rc_of add --name pi-runner-1)" "4" \
  "a taken name reports 4, not the floor's 3, on a box below its floor"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=4 rc_of add --name pi-runner-free)" "3" \
  "a FREE name still gets the ceiling verdict (the reorder did not swallow the gate)"

# ══ 5. RESTART: a dead listener comes back, a live one is NOT touched ═══════════════════════
echo "── restart: dead vs live ──"
fresh_pool restart; reset_logs
register pi-runner-live     # no listener: GitHub shows it OFFLINE
register pi-runner-gone     # registered by a hand script, listener died (the incident)
bash "$POOL" restart --name pi-runner-live >/dev/null 2>&1     # bring the first one up
live_pids="$(listener_pids_for "$RUNNER_ROOT/pi-runner-live")"
live_pid="$(printf '%s' "$live_pids" | awk '{print $1}')"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-gone")" "0" "the dead runner has no listener"

# ⛔ THE FLOOR MUST NOT GATE A RESTART (measured: two runners came back at ~200 MB each).
out="$(FIXTURE_MEM_MB=2263 FIXTURE_NCPU=8 run restart --name pi-runner-gone)"
assert_eq "$?" "0" "restart on a LOW-MEMORY box still succeeds (the floor gates ADDING only)"
assert_contains "$out" "restarted name=pi-runner-gone" "the dead listener was reported restarted"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-gone")" "1" "exactly one listener now runs for it"
# (The migration case above IS the pin for "no pid file of ours": this runner was registered by a
#  hand script, has no pid file, and is still started from the process table. A `[ ! -f .listener.pid ]`
#  assertion here would pass with the restart path deleted entirely — it pins nothing.)

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-live)"
assert_eq "$?" "0" "restart of a LIVE listener exits 0"
assert_contains "$out" "live name=pi-runner-live pid=$live_pid — not touched" \
  "a live listener is reported and NOT touched"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-live")" "1" "no second listener was started for it"
assert_eq "$(listener_pids_for "$RUNNER_ROOT/pi-runner-live")" "$live_pids" \
  "the live listener's pid is still the same one (not re-spawned)"

# A taken name is a per-name accident, not a box verdict: rc 4, and reconcile must skip to the
# next name rather than ending the pass and gaining nothing.
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of add --name pi-runner-gone)" "4" \
  "adding an already-registered name exits 4 (name-unavailable), not 3"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-gone)"
assert_contains "$out" "name-unavailable name=pi-runner-gone" "the taken name names itself"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-gone")" "1" "a taken name did not disturb its listener"

# ⛔ A hand-provisioned registration is called what its author called it. `restart` ADDRESSES an
# existing registration, so it must not impose `add`'s creation rules — refusing here would leave that
# listener dead forever AND make every later reconcile pass exit 2 on a healthy box.
mkdir -p "$RUNNER_ROOT/bad name"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/bad name/"   # `cp -a src dst` with dst existing would nest it
: >"$RUNNER_ROOT/bad name/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name 'bad name')"
assert_eq "$?" "0" "restart addresses an EXISTING registration whatever it is named"
assert_contains "$out" "restarted name=bad name" "the unvalidated name was started, not refused"
assert_eq "$(listeners_for "$RUNNER_ROOT/bad name")" "1" "its listener is running"
out="$(run restart --name '../escape')"
assert_eq "$?" "1" "restart still refuses a path ESCAPE (rc 1)"

out="$(run restart --name pi-runner-absent)"
assert_eq "$?" "3" "restart of an unregistered name exits 3 (REFUSED)"
assert_contains "$out" "no registration at" "the refusal says what it looked for"

# ── (3) a shared PREFIX is not an identity: `-1` and `-10` are different runners ───────────
# The measured pool's names run -1..-12, so a bare directory-prefix match would let a live `-10`
# listener make a DEAD `-1` read live — a false row AND a listener that is never restarted.
echo "── names that share a prefix ──"
fresh_pool prefixmatch; reset_logs
register pi-runner-x-1
register pi-runner-x-10
bash "$POOL" restart --name pi-runner-x-10 >/dev/null 2>&1
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-x-10")" "1" "the -10 listener is up"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-x-1")" "0" "the -1 registration has no listener"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_contains "$out" "summary live=1 dead=1" "a live -10 does NOT make -1 read live"
if grep -qE '^pi-runner-x-1 +- +DEAD' <<<"$out"; then
  ok "the -1 row is DEAD"
else
  bad "the -1 row is DEAD"
fi
ten_pid="$(listener_pids_for "$RUNNER_ROOT/pi-runner-x-10")"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-x-1)"
assert_eq "$?" "0" "restart of -1 starts ITS OWN listener"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-x-1")" "1" "the -1 listener is now up"
assert_eq "$(listener_pids_for "$RUNNER_ROOT/pi-runner-x-10")" "$ten_pid" "the -10 listener was not touched"

# ══ 6. STATUS: rows, and a DEAD listener is an exiting fact ═════════════════════════════════
echo "── status ──"
fresh_pool status; reset_logs
register pi-runner-live; bash "$POOL" restart --name pi-runner-live >/dev/null 2>&1
register pi-runner-dead
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "3" "status exits 3 when a listener is DEAD (a report a caller can branch on)"
assert_contains "$out" "slots=2 mem_available=12000 MB (11.72 GB) floor=3584 MB (3.50 GB)" \
  "status prints the memory reading and the floor it is compared against"
assert_contains "$out" "pi-runner-dead" "the dead runner is named"
assert_contains "$out" "DEAD" "the dead state is named"
assert_contains "$out" "summary live=1 dead=1 slots=2 ceiling=3" "the summary counts both states"
bash "$POOL" restart --name pi-runner-dead >/dev/null 2>&1
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of status --all)" "0" \
  "status exits 0 once every listener is live"

# ── a DOT-named registration is visible ─────────────────────────────────────────────────
# `"$RUNNER_ROOT"/*/` never matches a name starting with `.`, so a hand-provisioned `.foo`
# registration was invisible to `status` and to `slots` (never bounded by the ceiling) while
# `restart` started it — one registration read two ways by two verbs.
# (Own pool, placed AFTER the shared-pool assertions so it cannot reset the root under them.)
echo "── status: a dot-named registration ──"
fresh_pool dotdir; reset_logs
register .hidden-runner
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_contains "$out" "summary live=0 dead=1 slots=1" "a dot-named registration IS a slot"
assert_contains "$out" ".hidden-runner" "a dot-named registration is listed"

# ── the process table must be read at FULL WIDTH ──────────────────────────────────────────
# `ps -eo pid=,args=` TRUNCATES `args` to $COLUMNS (measured on procps-ng 4.0.4: with COLUMNS=80
# every line came back exactly 80 chars with the argv cut mid-`Runner.Li`, and `ps -ww` returned the
# full line under the same COLUMNS), and BSD/macOS `ps` truncates unless `-w` is given. A truncated
# argv misses the suffix match, so a LIVE listener reads DEAD — and that is not a cosmetic
# mis-report: `restart`/`reconcile` start a SECOND listener for one registration (the double-start
# the process-table design exists to prevent) and `status` exits 3 on a healthy box. COLUMNS=40 is
# below every fixture path, so the truncated spelling cannot pass this case.
echo "── liveness: the process table is read at FULL WIDTH ──"
fresh_pool narrow; reset_logs
register pi-runner-width
bash "$POOL" restart --name pi-runner-width >/dev/null 2>&1
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-width")" "1" "one listener runs before the narrow read"
out="$(COLUMNS=40 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "0" "a narrow COLUMNS does not make a LIVE listener read DEAD (status exits 0)"
assert_contains "$out" "pi-runner-width" "the live runner is still listed"
out="$(COLUMNS=40 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-width)"
assert_eq "$?" "0" "restart under a narrow COLUMNS exits 0"
assert_contains "$out" "live name=pi-runner-width" "restart reads the listener LIVE, not DEAD"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-width")" "1" \
  "no SECOND listener was started for one registration"

# ── a process that merely NAMES the path is not a listener ────────────────────────────────
# ⛔ The mirror image of the width pin above. Matching the binary path as a SUBSTRING accepts any
#   process whose arguments quote it — `tail -f <dir>/bin/Runner.Listener`, an editor, a shell holding
#   the path as an argument — so a DEAD registration reads LIVE forever: `status` exits 0, and
#   `restart`/`reconcile` skip the registration for good while the slot stays idle and advertised to
#   GitHub. The measured argv of a real listener is `<dir>/bin/Runner.Listener run …`, so liveness is
#   the INVOCATION (` run` must follow the binary), not a mention of the file.
echo "── liveness: a process that merely QUOTES the path is not a listener ──"
fresh_pool quoted; reset_logs
register pi-runner-quoted
( exec -a "tail -f $RUNNER_ROOT/pi-runner-quoted/bin/Runner.Listener" sleep 60 ) &
quoted_pid=$!
sleep 0.3
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "3" "a DEAD registration stays DEAD when another process merely names the binary"
assert_contains "$out" "pi-runner-quoted" "the quoting process was not read as the listener"
assert_contains "$out" "summary live=0 dead=1 slots=1" "and it is counted dead, not live"
kill "$quoted_pid" 2>/dev/null || true

# ══ 7. RECONCILE: restart the dead, add to the ceiling, be IDEMPOTENT, and report cannot-act ══
echo "── reconcile ──"
fresh_pool reconcile; reset_logs
register pi-runner-live; register pi-runner-dead
bash "$POOL" restart --name pi-runner-live >/dev/null 2>&1
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "reconcile exits 0 when its pass could measure and act"
assert_contains "$out" "restarted name=pi-runner-dead" "reconcile started the dead listener"
assert_contains "$out" "added name=pi-runner-fixturebox-1" "reconcile added a runner above the floor"
assert_contains "$out" "ceiling reached slots=3 ceiling=3 ncpu=8" \
  "reconcile stopped at the core-aware ceiling"
assert_contains "$out" "reconcile: dead=1 restarted=1 added=1 skipped=0 failed=0 refused=0 cannot=0 slots=3" \
  "reconcile summarises the pass with its readings"

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "a second reconcile exits 0"
assert_contains "$out" "reconcile: dead=0 restarted=0 added=0 skipped=0 failed=0 refused=0 cannot=0 slots=3" \
  "RECONCILE IS IDEMPOTENT: a second pass changes nothing"

# A gate verdict ENDS the pass: the box is below the floor, so the first add refuses and the summary
# reports the refusal rather than measuring the same box again under another name.
rm -rf "$RUNNER_ROOT/pi-runner-fixturebox-1"
out="$(FIXTURE_MEM_MB=1000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "reconcile exits 0 when the floor (not a failure) is what stopped it"
assert_contains "$out" "REFUSED add name=pi-runner-fixturebox-1" "the floor refusal is printed by the pass"
assert_contains "$out" "refused=1 cannot=0" "the refusal is counted, and is NOT counted as cannot-act"
assert_absent "$RUNNER_ROOT/pi-runner-fixturebox-1" "the refused add created nothing"

# ⛔ A pass that could not act must NOT read as success: kill the listener AND remove its run.sh, so
# the pass must try to restart it and cannot.
pkill -f -- "$RUNNER_ROOT/pi-runner-dead/bin/Runner.Listener" 2>/dev/null || true
sleep 0.3
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-dead")" "0" "the listener is really gone before the pass"
mv "$RUNNER_ROOT/pi-runner-dead/run.sh" "$T/run.sh.bak"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "2" "a pass that could not start a listener exits 2 (never 0)"
assert_contains "$out" "cannot-act why=runner-not-installed" "the failure names the missing install"
assert_contains "$out" "cannot=1" "the summary counts it as cannot-act, not as a refusal"
mv "$T/run.sh.bak" "$RUNNER_ROOT/pi-runner-dead/run.sh"

# ── an UNREADABLE capacity reading must not stop the RESTART arm ────────────────────────
# `readings` used to gate the WHOLE pass, so a broken memory/core read returned 2 BEFORE any dead
# listener was restarted — refusing the one action this tool exists for (bring a dead listener
# back) on exactly the box that needs it. The restart arm consumes no reading; only ADDING does,
# and the summary must say the add arm did not run.
echo "── reconcile: an unreadable reading still restarts the dead ──"
fresh_pool nocapacity; reset_logs
register pi-runner-deadlistener
out="$(FIXTURE_MEM_MB=not-a-number FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "2" "an unreadable reading still exits 2 (the ADD arm could not be measured)"
assert_contains "$out" "restarted name=pi-runner-deadlistener" "the dead listener was restarted anyway"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-deadlistener")" "1" \
  "exactly one listener now runs for it"
assert_contains "$out" "ceiling=unmeasured" "the summary discloses that the add arm did not run"

# A prefix that would mint an invalid name must not spin the add loop. Own pool: at the ceiling no
# add is attempted at all, so the pass would exit 0 for the wrong reason.
# ⛔ `timeout(1)` is GNU coreutils and macOS has no such binary (rc 127 reads as "the pass failed" when
# nothing ran at all), so on such a host the case is SKIPPED and NAMED rather than reported as a red.
fresh_pool prefix
if command -v timeout >/dev/null 2>&1; then
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 POOL_PREFIX='nested/x' timeout 20 bash "$POOL" reconcile 2>&1)"; rc=$?
  assert_eq "$rc" "2" "a prefix that cannot name a valid runner ends the pass (rc 2), it does not spin"
  assert_absent "$RUNNER_ROOT/nested" "an invalid prefix created nothing"
else
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 POOL_PREFIX='nested/x' bash "$POOL" reconcile 2>&1)"
  assert_eq "$?" "2" "a prefix that cannot name a valid runner ends the pass (rc 2), it does not spin (no timeout(1) here to bound a regression)"
  assert_absent "$RUNNER_ROOT/nested" "an invalid prefix created nothing"
fi

# ⛔ A NAME COLLISION MUST NOT END THE PASS: six stale dirs occupy -1..-6 and the next free name is
# -7. Ending on the first collision would leave the box BELOW its ceiling with exit 0.
fresh_pool stale
for n in 1 2 3 4 5 6; do mkdir -p "$RUNNER_ROOT/pi-runner-fixturebox-$n"; done
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "a pass through stale names exits 0 (it acted)"
assert_contains "$out" "added name=pi-runner-fixturebox-7" \
  "reconcile SKIPPED the six stale names and added the first FREE one"
assert_contains "$out" "ceiling reached slots=3 ceiling=3" "and it still stopped at the ceiling"

# ⛔ THE rc-4 ARM *INSIDE* THE PASS. The name-scan only skips a name that EXISTS, and a DANGLING
#   SYMLINK does not (`[ -e ]` is false for it) — so `add` answers 4 on it, a per-name accident the
#   pass must SKIP. Folded into the cannot/break arm it ends the whole pass with rc 2 and leaves the box
#   at ZERO capacity: the exact inversion of "one stale directory must not cost the box the capacity it
#   is entitled to", and `skipped=` could then never be non-zero (a monitor keyed on it reads 0 forever).
echo "── a name add cannot claim is SKIPPED, not the end of the pass ──"
fresh_pool skipname; reset_logs
ln -s "$T/no-such-target" "$RUNNER_ROOT/pi-runner-fixturebox-1"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "a name that cannot be claimed does not end the pass (rc 0)"
assert_contains "$out" "skipped=1" "the unclaimable name is counted as skipped"
assert_contains "$out" "added name=pi-runner-fixturebox-2" "and the pass moved on to the next name"

# ⛔ A preview that announced ONE add where the pass makes THREE would under-report the very change
# an operator is previewing. Own pool: 0 slots, ceiling 3.
fresh_pool preview
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile --dry-run)"
assert_contains "$out" "register name=pi-runner-fixturebox-1" "the preview names the first add"
assert_contains "$out" "register name=pi-runner-fixturebox-3" "and the LAST one the pass would make"
assert_contains "$out" "dry-run: ceiling would be reached slots=0+3 ceiling=3" \
  "the preview says where it would stop"
assert_contains "$out" "added=3" "the summary counts the adds the preview ANNOUNCED (it used to say added=0)"
assert_eq "$(slots)" "0" "the preview added nothing"
fresh_pool previewcmp
assert_contains "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)" "added=3" \
  "the real pass on the same fixture makes the three adds the preview announced"

# ⛔ A preview that RESTATED "would add" instead of ASKING announced capacity the owner's floor
# refuses — the mirror of under-reporting it. These fixtures are the ones where it lied.
fresh_pool previewfloor
out="$(FIXTURE_MEM_MB=1000 FIXTURE_NCPU=8 run reconcile --dry-run)"
assert_eq "$?" "0" "a preview below the floor exits 0 (the floor is a verdict, not a failure)"
assert_contains "$out" "REFUSED add name=pi-runner-fixturebox-1" \
  "the preview HONOURS the floor instead of announcing capacity the pass refuses"
if grep -qF 'register name=' <<<"$out"; then
  bad "the preview announced no add below the floor"
else
  ok "the preview announced no add below the floor"
fi
assert_contains "$out" "refused=1" "the preview counts the refusal"

fresh_pool previewtpl
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/nope" run reconcile --dry-run)"
assert_eq "$?" "2" "a preview with no template exits 2, like the pass it previews"
assert_contains "$out" "cannot-act why=runner-template-absent" "the preview names the same cannot-act"

# …and a preview of a RESTART is faithful too: it names the listener it would start, and refuses
# when the listener cannot be measured.
fresh_pool previewrestart
register pi-runner-restartme
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile --dry-run)"
assert_contains "$out" "dry-run: would start the listener for name=pi-runner-restartme" \
  "a preview of a restart names the listener it would start"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-restartme")" "0" "the preview started nothing"

# …and a registration whose install is broken must be REFUSED by the preview too, not announced.
fresh_pool previewbroken
register pi-runner-broken
mv "$RUNNER_ROOT/pi-runner-broken/run.sh" "$T/run.sh.bak2"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-broken --dry-run)"
assert_eq "$?" "2" "a preview refuses a start the real pass would refuse (no run.sh)"
assert_contains "$out" "cannot-act why=runner-not-installed" "the preview names the same cannot-act"
if grep -qF 'would start the listener' <<<"$out"; then
  bad "the preview did not announce a start it cannot perform"
else
  ok "the preview did not announce a start it cannot perform"
fi
mv "$T/run.sh.bak2" "$RUNNER_ROOT/pi-runner-broken/run.sh"

# ── (1) a pass that provisioned nothing is cannot-act, not success ─────────────────────────
# Exit 5 is per-name by design; on its own it cannot report a box that could register NOTHING (a
# GitHub 5xx, an expired runner scope, a full disk all arrive as the same code).
fresh_pool nothingadds
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_CONFIG_FAIL=1 run reconcile)"
assert_eq "$?" "2" "a pass that registered NOTHING exits 2, never 0"
assert_contains "$out" "cannot-act why=no-runner-registered" "it says the box gained no capacity"
assert_contains "$out" "added=0" "and the summary says so"
assert_eq "$(slots)" "0" "nothing is registered"

# ── (2) GitHub-held names must not land the pass SHORT of the ceiling ──────────────────────
# After a `/tmp` wipe every local `.runner` is gone and every registration is still on GitHub, so a
# budget charged per failed name would stop the pass below capacity — and at enough held names,
# forever at added=0.
fresh_pool takenmany
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_CONFIG_TAKEN="1 2 3 4 5 6 7 8" run reconcile)"
assert_eq "$?" "0" "the pass still succeeds with eight held names"
assert_contains "$out" "added=3" "it reached the ceiling despite eight taken names"
assert_contains "$out" "ceiling reached slots=3 ceiling=3" "and it stopped there"

# ── (3) RUNNER_START_SETTLE_S is an operand, and an unreadable one changes nothing ──────────
fresh_pool settle; reset_logs
for bad in 5s 0 -1; do
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_START_SETTLE_S="$bad" run add --name pi-runner-settle)"
  assert_eq "$?" "2" "RUNNER_START_SETTLE_S=$bad is cannot-measure (rc 2), never rc 1 mid-action"
  assert_contains "$out" "cannot-measure why=settle-unreadable" "it names the operand"
  assert_absent "$RUNNER_ROOT/pi-runner-settle" "nothing was created"
done
register pi-runner-settle2
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_START_SETTLE_S=0 rc_of restart --name pi-runner-settle2)" "2" \
  "restart refuses an unreadable settle window instead of starting a listener"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-settle2")" "0" "and it started nothing"
# ⛔ The box whose ENV IS WRONG is the one that needs the contract, so `--help` may not sit behind
#   operand validation — otherwise the usage block is unreachable exactly when it is needed.
out="$(RUNNER_START_SETTLE_S=5s bash "$POOL" --help 2>&1)"
assert_eq "$?" "0" "--help exits 0 even when RUNNER_START_SETTLE_S is unreadable"
assert_contains "$out" "USAGE" "and it prints the usage block (not a cannot-measure verdict)"

# ── (4) the preview must not announce adds it has no token source for ───────────────────────
fresh_pool previewtoken
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_POOL_GH=/nonexistent-gh run reconcile --dry-run)"
assert_eq "$?" "2" "a preview with no token source exits 2, like the pass it previews"
assert_contains "$out" "cannot-act why=no-registration-token" "it names the precondition"
if grep -qF 'would copy' <<<"$out"; then
  bad "the preview announced an add it cannot make"
else
  ok "the preview announced an add it cannot make"
fi

# ══ 8. NAME VALIDATION: a name is a path component, and an escaped one sits outside the ceiling ══
echo "── name validation ──"
fresh_pool names; reset_logs
for bad_name in '../escaped' 'a/b' '.hidden' ''; do
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of add --name "$bad_name")" "1" \
    "add refuses the name '${bad_name}' (rc 1) before it touches the filesystem"
done
assert_absent "$T/escaped" "a '..' name did not escape RUNNER_ROOT"
assert_absent "$RUNNER_ROOT/a" "a 'a/b' name did not create a nested dir"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "no invalid name reached config.sh"

# ══ 9. FAIL-CLOSED readings, and every way config/listener can fall short ═══════════════════
echo "── fail-closed readings and failed actions ──"
fresh_pool closed; reset_logs
BADLIB="$T/capacity-unreadable.sh"
printf 'cap_mem_free_mb() { return 1; }\ncap_ncpu() { printf 8; }\ncap_host() { printf fixture; }\n' >"$BADLIB"
BADNCPU="$T/capacity-nocpu.sh"
printf 'cap_mem_free_mb() { printf 12000; }\ncap_ncpu() { return 1; }\ncap_host() { printf fixture; }\n' >"$BADNCPU"
out="$(CAPACITY_LIB="$BADLIB" run add --name pi-runner-x)"
assert_eq "$?" "2" "an unreadable memory reading exits 2 on add"
assert_contains "$out" "cannot-measure why=mem-unreadable" "the failure names the reading that failed"
assert_absent "$RUNNER_ROOT/pi-runner-x" "an unreadable reading adds nothing"
out="$(CAPACITY_LIB="$BADNCPU" run add --name pi-runner-y)"
assert_eq "$?" "2" "an unreadable core count exits 2 on add"
assert_contains "$out" "cannot-measure why=ncpu-unreadable" "the core failure names itself"
assert_eq "$(CAPACITY_LIB="$BADLIB" rc_of status)" "2" "status exits 2 (never 0, never 3) when it cannot measure"
assert_eq "$(CAPACITY_LIB="$BADLIB" rc_of reconcile)" "2" "reconcile exits 2 when it cannot measure"

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_ARCH=sparc64 RUNNER_LABELS= run add --name pi-runner-z)"
assert_eq "$?" "2" "an arch we cannot name is cannot-measure (never a jobless runner)"
assert_contains "$out" "cannot-measure why=arch-unknown" "it names the arch it could not classify"
assert_absent "$RUNNER_ROOT/pi-runner-z" "it registered nothing"
fresh_pool label
assert_contains "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_LABELS=self-hosted-arm64 run add --name pi-runner-z)" \
  "labels=self-hosted-arm64" "RUNNER_LABELS overrides the derived marker"
assert_contains "$(cat "$CONFIG_LOG")" "--labels self-hosted-arm64" "and config.sh received that marker"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_LABELS=self_hosted_x64 run add --name pi-runner-typo)"
assert_eq "$?" "2" "a label override WITHOUT a pool marker is cannot-measure (rc 2), never a jobless runner"
assert_contains "$out" "cannot-measure why=label-unknown" "it names the bad label"
assert_absent "$RUNNER_ROOT/pi-runner-typo" "it registered nothing"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_LABELS='self-hosted-x64,extra-label' run add --name pi-runner-extra)"
assert_eq "$?" "0" "a label LIST containing the marker is accepted"
assert_contains "$(cat "$CONFIG_LOG")" "--labels self-hosted-x64,extra-label" "the extra labels reach config.sh"

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_TEMPLATE="$T/nope" run add --name pi-runner-t)"
assert_eq "$?" "2" "a missing runner template is cannot-act (rc 2)"
assert_contains "$out" "cannot-act why=runner-template-absent" "it names the missing template"
assert_absent "$RUNNER_ROOT/pi-runner-t" "it created nothing"

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_CONFIG_FAIL=1 run add --name pi-runner-f)"
assert_eq "$?" "5" "a failing config.sh is a NAME failure (rc 5), not a box verdict"
assert_contains "$out" "name-failed why=config-failed" "it names the step that failed"
assert_contains "$out" "trying the next name" "and it says the pass may carry on"
cfg_path="${out#*see=}"; cfg_path="${cfg_path%% *}"
assert_file "$cfg_path" "the config log SURVIVES the removed install (the only diagnostic for a taken name or a spent token)"
assert_contains "$(cat "$cfg_path" 2>/dev/null)" "the registration token is invalid" \
  "the surviving log holds config.sh's OWN stderr — the only diagnostic for a spent token"
assert_absent "$RUNNER_ROOT/pi-runner-f" "a failed config REMOVES the copied install (a leftover is invisible to slots and unbounded)"

# A copy that cannot complete leaves NOTHING: a partial install is invisible to `slots` and would
# make the name permanently unavailable.
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_ROOT="$T/nonexistent-parent/root" run add --name pi-runner-cp)"
assert_eq "$?" "2" "an impossible copy is cannot-act (rc 2)"
assert_contains "$out" "cannot-act why=template-copy-failed" "it names the copy failure"
assert_absent "$T/nonexistent-parent" "no partial install was left behind"

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_CONFIG_NOMARKER=1 run add --name pi-runner-n)"
assert_eq "$?" "5" "a config.sh that exits 0 WITHOUT writing .runner is a NAME failure (rc 5)"
assert_contains "$out" "name-failed why=no-registration-marker" "the marker, not the exit code, is the proof"
assert_absent "$RUNNER_ROOT/pi-runner-n" "the unproven install was removed"

# ⛔ A NAME GITHUB ALREADY HOLDS MUST NOT END THE PASS. `RUNNER_ROOT` defaults to /tmp/actions-runner,
# so a reboot erases every local `.runner` while GitHub keeps every registration: without this, the
# first name minted after a reboot is always taken and the box can never re-provision its pool.
fresh_pool takenname
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_CONFIG_FAIL_NAME=pi-runner-fixturebox-1 run reconcile)"
assert_eq "$?" "0" "a GitHub-taken name does not end the pass"
assert_contains "$out" "name-failed why=config-failed" "the taken name is reported"
assert_contains "$out" "added name=pi-runner-fixturebox-2" "the pass moved on to the NEXT name and registered it"
assert_contains "$out" "failed=1" "the summary counts the name failure separately"
assert_absent "$RUNNER_ROOT/pi-runner-fixturebox-1" "the taken name registered nothing"
assert_eq "$(slots)" "3" "the pass filled to the ceiling with the FREE names"

# A registration whose listener never comes up must not be reported as a clean add, and the message
# must say the registration exists (a bare "nothing changed" would be false, and the retry is refused).
cp -a "$TEMPLATE" "$RUNNER_ROOT/pi-runner-dies"
printf '#!/usr/bin/env bash\nexit 1\n' >"$RUNNER_ROOT/pi-runner-dies/run.sh"; chmod +x "$RUNNER_ROOT/pi-runner-dies/run.sh"
: >"$RUNNER_ROOT/pi-runner-dies/.runner"
# ⛔ An unreadable process table is the one input whose absence would produce an ACTION (a second
# listener), so it must be `cannot-measure` on every path that reads it.
register pi-runner-ps
bash "$POOL" restart --name pi-runner-ps >/dev/null 2>&1
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-ps")" "1" "the ps-probe fixture has one live listener"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_FAIL=1 run status --all)"
assert_eq "$?" "2" "status with an unreadable process table exits 2 (NEVER 3 — it measured nothing)"
assert_contains "$out" "cannot-measure why=process-table-unreadable" "it names the unreadable table"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_FAIL=1 rc_of restart --name pi-runner-ps)" "2" \
  "restart with an unreadable process table refuses (rc 2) instead of starting a second listener"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-ps")" "1" "no second listener was started"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EMPTY=1 rc_of status --all)" "2" \
  "an EMPTY process table is also cannot-measure (ps never lists zero processes)"

out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-dies)"
assert_eq "$?" "2" "a listener that never appears is cannot-act (rc 2)"
assert_contains "$out" "cannot-act why=listener-never-appeared" "the wait is bounded and named"

# ══ OUTSIDE-THE-ROOT ARMS (#2381 review, P1) ══════════════════════════════════════════════
# The measured shape this exists for: three LIVE registrations under /opt/gh-runner-* while
# RUNNER_ROOT defaulted to /tmp/actions-runner. Both the ceiling and the restart verdict were read
# from a listing that was not the box's pool, so `add` would have put a 4th runner on a 3-slot box and
# `restart` called an existing registration missing. The reading is the PROCESS TABLE, which does not
# care where the installs live — and it fails closed: the outside dir is named, never silently ignored.
fresh_pool outside
OUTSIDE_DIR="$T/elsewhere/pi-runner-elsewhere"
mkdir -p "$OUTSIDE_DIR/bin" "$OUTSIDE_DIR/_work"
cp -a "$TEMPLATE/bin/Runner.Listener" "$OUTSIDE_DIR/bin/"
: >"$OUTSIDE_DIR/.runner"
EXTRA="424242 $OUTSIDE_DIR/bin/Runner.Listener run --startuptype service"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" run status --all)"
assert_eq "$?" "2" "status refuses a pool it can only partially enumerate (rc 2, never a clean report)"
assert_contains "$out" "cannot-measure why=pool-root-incomplete" "it names the reading that failed"
assert_contains "$out" "outside=$OUTSIDE_DIR" "and names the instance dir it cannot count"

reset_logs
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" run add --name pi-runner-outside-add)"
assert_eq "$?" "2" "add REFUSES on an incomplete pool — no runner added onto a box already at its ceiling"
assert_contains "$out" "why=pool-root-incomplete" "the refusal prints the reading it used"
assert_eq "$(count_lines "$GH_LOG")" "0" "no registration token was minted for the refused add"
assert_absent "$RUNNER_ROOT/pi-runner-outside-add" "no instance dir was claimed"

# The same box WITHOUT the outside listener is clean — so the arm fires on the reading, not a fixture.
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of status --all)" "0" \
  "the same box with no outside listener reports a complete pool (control)"

assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" rc_of restart --name pi-runner-elsewhere)" "2" \
  "restart of a registration outside the root is cannot-measure, NOT a false 'no registration'"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" run restart --name pi-runner-elsewhere)"
assert_absent "$OUTSIDE_DIR/listener.log" "and it started nothing for it"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" run reconcile)"
assert_eq "$?" "2" "reconcile does not publish a clean summary over part of the box"
assert_contains "$out" "why=pool-root-incomplete" "naming the same reading"

# ⛔ THE SCAN ARM IS THE ONE VERB PATH WITH NO COMPLETENESS GATE — AND IT IS THE DELETE PATH (#2899
#   review round 5, P2). With no gate, `registered_dirs` returns an EMPTY (but readable) listing, the
#   loop never runs — so guard 3's own `outside_listener_dirs` read at `sib` is never reached either —
#   and the pass printed `reclaim: retired=0 … cannot=0` and exited 0. "The pool is clean" and "I
#   listed an empty directory" became the same line, over an unread pool, from the verb that DELETES.
#   The recovery recipe this change documents (§6 step 2 of docs/research/2026-10-27-runner-pool-
#   self-healing.md) tells the operator to run `reclaim --dry-run` then `reclaim` — on the `pi-cell-4`
#   shape, where the installs live under `/opt` and the root defaults elsewhere, so the false clean
#   pass is the FIRST thing that recipe produces on the box it was written for.
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" run reclaim)"
assert_eq "$?" "2" "reclaim REFUSES a pool it can only partially enumerate (rc 2, never a clean pass)"
assert_contains "$out" "cannot-measure why=pool-root-incomplete" "naming the reading that failed"
assert_contains "$out" "reclaim NOT attempted" "and saying the delete verb did nothing"
assert_eq "$(grep -cF 'reclaim: retired=' <<<"$out")" "0" \
  "no all-zero summary is published over the pool it never read"
# The SAME root with no outside listener is a genuine empty pool: rc 0, and the summary names the root
# it read — so an all-zero line cannot be mistaken for a clean one (control).
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "an EMPTY pool under a complete root is still a clean pass (control)"
assert_contains "$out" "root=$RUNNER_ROOT" "and the summary names the root it read"
# `--name` names ONE directory and never reads the pool as a whole, so it is deliberately NOT gated:
# an incomplete root must not block a single-install verdict (the over-block direction of the same fix).
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" rc_of reclaim --name pi-runner-nope)" "3" \
  "a --name call is a single-dir verdict, so an incomplete root does not change it"

# ⛔ A WRAPPED LISTENER IS STILL A LISTENER (#2381 review round 6, P1). A listener started through a
#   wrapper (`nohup`, `env K=V`, `bash`, `sudo`, a service shim) has `<wrapper> <dir>/bin/…` as its
#   argv. Taking EVERYTHING before the binary gave `nohup <dir>` — not an absolute path — and the arm
#   DROPPED it: `listener_pid` called the same process LIVE while this arm called the pool complete,
#   so `add` minted a token and REGISTERED a runner on a box already at its ceiling (measured: rc 0,
#   `registered=1`, 2 unlisted runners). The same box native-shaped correctly refused — the two
#   readers of one process table must not disagree.
EXTRA_WRAPPED="424243 bash $OUTSIDE_DIR/bin/Runner.Listener run"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA_WRAPPED" run status --all)"
assert_eq "$?" "2" "a WRAPPER-started outside listener is still an incomplete pool (rc 2)"
assert_contains "$out" "cannot-measure why=pool-root-incomplete" "and it names the reading"
assert_contains "$out" "outside=$OUTSIDE_DIR" "naming the instance dir behind the wrapper"
reset_logs
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA_WRAPPED" rc_of add --name pi-runner-wrapped-add)" "2" \
  "and add REFUSES over it — no runner registered on a box whose pool it cannot count"
assert_absent "$RUNNER_ROOT/pi-runner-wrapped-add" "no instance dir was claimed"
assert_eq "$(count_lines "$GH_LOG")" "0" "and no token was minted"

# ⛔ A RELATIVE INSTANCE DIR IS cannot-measure, NEVER "not an instance" (#2381 review round 6, P1).
#   GitHub's own `run.sh` starts `./bin/Runner.Listener`, and a relative dir cannot be judged inside
#   or outside without the process's cwd — so dropping it lets an outside listener past the arm that
#   exists to catch exactly that.
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="424244 ./bin/Runner.Listener run" run status --all)"
assert_eq "$?" "2" "a listener whose instance dir cannot be resolved is cannot-measure (rc 2)"
assert_contains "$out" "cannot-measure why=instance-dir-unresolvable" "and it names the argv it could not resolve"

# ⛔ THE PASS'S OWN OUTSIDE-THE-ROOT ARM, PINNED WHERE `add` CANNOT ANSWER FOR IT (#2381 review round
#   6, P2): with a FREE slot the child `add`'s refusal supplied both the rc and the string, so deleting
#   this arm stayed green — and at the ceiling, where the add arm never runs, the pass then published
#   `ceiling reached … cannot=0` over a partial pool and exited 0 (measured).
fresh_pool outceil; reset_logs
register pi-runner-oc1; register pi-runner-oc2; register pi-runner-oc3   # slots=3 == ceiling on 8 cores
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$EXTRA" run reconcile)"
assert_eq "$?" "2" "reconcile AT THE CEILING with an outside listener is not a clean pass (rc 2)"
assert_contains "$out" "cannot=1" "and its summary counts the pool it could not enumerate"
assert_contains "$out" "added=0" "and the ADD arm added nothing over part of the box"

# ⛔ THE POST-CLAIM COMPLETENESS RE-CHECK (#2381 review round 6, P2): the claim must be RELEASED when
#   an outside listener appears during the token mint. Unreachable in every fixture before now (the
#   only outside-add fixture has slots=0, so the PRE-claim read answers first), so the guard could be
#   deleted with the suite green — and the add then registered a runner the ceiling never counted.
fresh_pool postclaim; reset_logs
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_OUTSIDE_AFTER=1 FIXTURE_PS_EXTRA="$EXTRA" run add --name pi-runner-post)"
assert_eq "$?" "2" "an outside listener that appears DURING the mint makes the add refuse (rc 2)"
assert_contains "$out" "why=pool-root-incomplete" "naming the reading that changed"
assert_absent "$RUNNER_ROOT/pi-runner-post" "the claimed directory was RELEASED, not registered"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "and config.sh never ran for it"

# ⛔ THE RESTART REMEDY MUST NOT BE ONE THAT ALWAYS REFUSES (#2381 review, P2): a directory that
# exists without a registration is not "add it first" — `add` refuses that same path as unavailable,
# so the operator bounced between two verbs forever.
fresh_pool remedy
mkdir -p "$RUNNER_ROOT/pi-runner-noinstall"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-noinstall)"
assert_eq "$?" "3" "a directory without a .runner registration is still a refusal (rc 3)"
assert_contains "$out" "carries no .runner registration" "the message names what was measured"
assert_contains "$out" "clear it, or pick another name" "and the remedy that actually clears it"
# ⛔ THE NON-DIRECTORY SHAPES TOO (#2381 review round 2, P2): a FILE or a DANGLING SYMLINK on the name
# is refused by `add` (rc 4, "clear it or pick another name") — so `restart` must not answer "add it
# first" for it. The arm only asked "is it a traversable directory", so the two-verb bounce survived
# for every shape that is not a directory. Both verbs are asserted against the SAME path.
: >"$RUNNER_ROOT/pi-runner-file"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-file)"
assert_eq "$?" "3" "a FILE squatting on the name is a refusal (rc 3), not a missing registration"
assert_contains "$out" "is not a searchable directory (a file or a symlink)" "restart names the shape it found"
assert_contains "$out" "clear it, or pick another name" "and the remedy that clears it"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-file)"
assert_eq "$?" "4" "and 'add' refuses that SAME path — the two verbs agree on the state"
ln -s "$T/no-such-target" "$RUNNER_ROOT/pi-runner-dangle"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-dangle)"
assert_eq "$?" "3" "a DANGLING SYMLINK (not a directory) is the same refusal, not 'add it first'"
assert_contains "$out" "clear it, or pick another name" "with the same remedy"

# ⛔ A SINGLE-USE TOKEN CANNOT SERVE A PASS (#2381 review, P2): every add after the first would fail
# config.sh and the pass would burn its whole attempt budget reporting failed=N added=0.
fresh_pool token
out="$(RUNNER_TOKEN=tok-fixture FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "2" "reconcile refuses an inherited single-use RUNNER_TOKEN (rc 2)"
assert_contains "$out" "why=runner-token-single-use" "naming the reason the ADD arm did not run"
assert_eq "$(slots)" "0" "nothing was added"

# ══ TMPDIR: the directory `.env` names is CREATED BY THE LAUNCHER (agent-infra#2937) ══════════
# The measured failure: an instance's `.env` carried `TMPDIR=/tmp/ci-actions-runner-N`, the instance dir
# is persistent and its unit enabled, and NOTHING creates that directory — so after a reboot the
# listener survives and its TMPDIR does not. GitHub reports the runner `online`, the job is PICKED UP,
# and it dies in its first seconds at `mktemp` (job 122457527181: exit 2). Because only jobs that use
# `mktemp` fail, a host-wide fault presented as a flaky, PR-specific defect and cost a full
# investigation of an unrelated PR.
# These cases assert the ORDERING the fix claims — the directory exists BEFORE `run.sh` is exec'd — by
# recording what the listener inherited from INSIDE the stub, which is the only place the real contract
# (GitHub's `run.sh` sources `.env`) is observable. A case that only checked `[ -d ]` afterwards would
# pass against a launcher that created the directory after the listener could already read it.
echo "── tmpdir: a missing TMPDIR target is created before the listener starts ──"
fresh_pool tmpdir; reset_logs
register pi-runner-tmp
TMPLOG="$T/tmpdir.log"; : >"$TMPLOG"
printf 'LANG=en_US.UTF-8\nTMPDIR=%s/pi-runner-tmp/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-tmp/.env"
assert_absent "$RUNNER_ROOT/pi-runner-tmp/tmp" "the TMPDIR the instance's .env names does not exist yet (the post-reboot state)"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$TMPLOG" run restart --name pi-runner-tmp)"
assert_eq "$?" "0" "restart SUCCEEDS although the TMPDIR target was missing"
assert_contains "$out" "created tmpdir=$RUNNER_ROOT/pi-runner-tmp/tmp" \
  "the launcher PRINTS the path it created (a gate that refuses without its reading is a wish)"
if [ -d "$RUNNER_ROOT/pi-runner-tmp/tmp" ]; then ok "the directory now exists"; else bad "the directory was NOT created"; fi
assert_eq "$(mode_of "$RUNNER_ROOT/pi-runner-tmp/tmp")" "700" "it is created 700 — a private per-runner temp dir"
assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-tmp") ))" "1" "the listener is running"
# ⛔ THE ASSERTION THAT PINS THE ORDER, not just the outcome: the listener was exec'd WITH a usable TMPDIR.
assert_contains "$(cat "$TMPLOG")" "present $RUNNER_ROOT/pi-runner-tmp/tmp" \
  "the listener inherited a TMPDIR that EXISTS at exec time (the creation precedes the start)"
assert_eq "$(TMPDIR="$RUNNER_ROOT/pi-runner-tmp/tmp" mktemp -d >/dev/null 2>&1; printf '%s' "$?")" "0" \
  "and the operation that failed in the incident (mktemp) now works"

# ── (1) idempotence: an EXISTING directory is left exactly as it is ─────────────────────────
# `mkdir -p` never chmods what already exists, so a hand-repaired box (the operative ones carry 755)
# must not be silently tightened — and a second start must not re-report a creation that did not happen.
echo "── tmpdir: an existing directory keeps its owner and mode ──"
fresh_pool tmpkeep; reset_logs
register pi-runner-keep
mkdir -p "$RUNNER_ROOT/pi-runner-keep/tmp"; chmod 755 "$RUNNER_ROOT/pi-runner-keep/tmp"
printf 'TMPDIR=%s/pi-runner-keep/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-keep/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-keep)"
assert_eq "$?" "0" "restart succeeds when the TMPDIR already exists"
assert_eq "$(mode_of "$RUNNER_ROOT/pi-runner-keep/tmp")" "755" "a pre-existing directory keeps its mode (no chmod)"
assert_omits "$out" "created tmpdir=" "and it does NOT claim to have created anything"

# ── (2) an instance whose .env names NO TMPDIR still gets its own PRIVATE root (#7815) ──────
# This is the COMMON shape (an `add`-provisioned instance ships no `.env`), and it used to be the one
# that inherited the BOX's shared temp dir. "Nothing is invented for `.env`" still holds; the private
# root is a separate, deliberate subject — inside the instance dir, created before the listener starts.
echo "── tmpdir: an instance that names none ──"
fresh_pool tmpnone; reset_logs
register pi-runner-none
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-none)"
assert_eq "$?" "0" "restart of an instance with no .env is unaffected"
assert_omits "$out" "created tmpdir=" "no `.env`-named directory is invented"
assert_contains "$out" "created tmpdir-root=$RUNNER_ROOT/pi-runner-none/_tmp" \
  "but the instance's OWN private temp root is created, and printed"
assert_eq "$(mode_of "$RUNNER_ROOT/pi-runner-none/_tmp")" "700" "mode 0700"

# ── (3) a RELATIVE value is REFUSED, because no directory here could be the one a job uses ──
# ⛔ `run.sh` `cd`s to the instance dir before the listener READS TMPDIR — but the listener hands that
# value to each JOB, whose working directory is `_work/<repo>/<repo>`. So `TMPDIR=scratch-here`
# resolves under the WORKSPACE, not the instance dir: creating `$d/scratch-here` (what this case used
# to assert as success) made a directory no job ever used, while the run printed `created tmpdir=…`,
# exited 0, and `status` called the row clean — a false PASS in the dimension this arm adds. The
# value is the listener's, not ours, so it is refused and the remedy is named (#3004 review, P2).
echo "── tmpdir: a relative value is refused, not resolved somewhere a job never looks ──"
fresh_pool tmprel; reset_logs
register pi-runner-rel
printf 'TMPDIR=scratch-here\n' >"$RUNNER_ROOT/pi-runner-rel/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-rel)"
assert_eq "$?" "2" "restart refuses a relative TMPDIR (rc 2) instead of starting on a guess"
assert_contains "$out" "cannot-act why=tmpdir-value-relative" "naming the shape it refused"
assert_contains "$out" "value=scratch-here" "and the value it read"
assert_absent "$RUNNER_ROOT/pi-runner-rel/scratch-here" "no instance-dir directory was invented for it"
assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-rel") ))" "0" "and nothing was started"

# ── (4) FAIL CLOSED: a target that CANNOT be created starts nothing ────────────────────────
# ⛔ The failure being prevented IS "the listener starts anyway". Starting it here would reproduce the
# incident deliberately: a healthy, online runner on which every job dies at mktemp. A refusal that
# names the path is strictly better than a runner that silently cannot work.
echo "── tmpdir: an uncreatable target refuses, starting nothing ──"
fresh_pool tmpbad; reset_logs
register pi-runner-bad
: >"$RUNNER_ROOT/pi-runner-bad/blocker"   # a FILE where a parent directory must be (ENOTDIR, portable)
printf 'TMPDIR=%s/pi-runner-bad/blocker/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-bad/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-bad)"
assert_eq "$?" "2" "it is cannot-act (rc 2), never a start"
assert_contains "$out" "cannot-act why=tmpdir-uncreatable" "naming the failure"
assert_contains "$out" "path=$RUNNER_ROOT/pi-runner-bad/blocker/tmp" "and the path it could not create"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-bad")" "0" "NO listener was started for it"

# ── (5) STATUS: a LIVE row with a missing TMPDIR is a defect that exits 3 ──────────────────
# This is the presentation that does the damage: the row says `live`, GitHub says `online`, and the
# instance cannot run a job. rc 0 over it is a false PASS a caller would act on.
echo "── tmpdir: status reports it on a LIVE listener, and exits 3 ──"
fresh_pool tmpstat; reset_logs
register pi-runner-stat
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-stat >/dev/null
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-stat")" "1" "the instance has a live listener and no TMPDIR yet"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "0" "with no TMPDIR named, status is clean (control)"
assert_omits "$out" "defect tmpdir-missing" "and reports no defect"
printf 'TMPDIR=%s/pi-runner-stat/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-stat/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "3" "a LIVE row carrying a missing TMPDIR exits 3 (a defect, not a healthy report)"
assert_contains "$out" "defect tmpdir-missing name=pi-runner-stat path=$RUNNER_ROOT/pi-runner-stat/tmp" \
  "the defect names the instance and the path"
assert_contains "$out" "restart --name pi-runner-stat" "and the action that clears it"
assert_contains "$out" "tmpdir_defects=1" "the summary counts it, so a caller need not parse the table"
# ⛔⛔ RUN THE REMEDY, DO NOT HAND-REPAIR (#3004 review, P1). This block used to `mkdir -p` by hand and
#   then assert the report was clean — so it proved the REPORT could be satisfied, never that the
#   command the report PRINTS works. It did not: `restart` hit the live arm, logged "not touched",
#   exited 0 and left the directory missing. The repair below is the printed remedy itself.
remedy="$(sed -n 's/.*run: \(.*restart --name pi-runner-stat\)$/\1/p' <<<"$out")"
assert_contains "$remedy" "restart --name pi-runner-stat" "the remedy is parsed out of the report (not restated)"
# shellcheck disable=SC2086
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash $remedy 2>&1)"
assert_eq "$?" "0" "the PRINTED REMEDY runs and exits 0"
assert_contains "$out" "created tmpdir=$RUNNER_ROOT/pi-runner-stat/tmp" "and it actually creates the directory"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "0" "once the directory exists the report is clean again"
assert_contains "$out" "tmpdir_defects=0" "and the count returns to zero"

# ── (6) THE POST-REBOOT STATE: a LIVE listener is repairable, and its listener is untouched ──
# ⛔ THE INCIDENT IS A LIVE LISTENER (#3004 review, P1). The instance dir is persistent and its unit
#   enabled, so after a reboot the LISTENER SURVIVES and only its /tmp TMPDIR is gone. Every creation
#   case in this section starts a DEAD registration, which is why they were all green while the state
#   the PR documents could not be repaired at all. This case pins the live arm specifically: the
#   directory appears, and the SAME pid is still the only listener.
echo "── tmpdir: a LIVE listener with a missing TMPDIR is repaired, not re-started ──"
fresh_pool tmplive; reset_logs
register pi-runner-live1
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-live1 >/dev/null
live_pids="$(listener_pids_for "$RUNNER_ROOT/pi-runner-live1")"
printf 'TMPDIR=%s/pi-runner-live1/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-live1/.env"
assert_absent "$RUNNER_ROOT/pi-runner-live1/tmp" "the post-reboot state: LIVE listener, TMPDIR gone"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$TMPLOG" run restart --name pi-runner-live1)"
assert_eq "$?" "0" "restart on the live row succeeds"
assert_contains "$out" "created tmpdir=$RUNNER_ROOT/pi-runner-live1/tmp" "and it CREATES the missing TMPDIR"
assert_omits "$out" "restarted name=" "without starting a second listener for a live registration"
assert_eq "$(listener_pids_for "$RUNNER_ROOT/pi-runner-live1")" "$live_pids" "the live listener was NOT replaced (same pid)"
assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-live1") ))" "1" "exactly one listener runs"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "0" "and status is clean again — the live repair cleared the defect"

# ── (7) RECONCILE's live arm repairs too (it is the arm that SKIPS every row it calls live) ──
echo "── tmpdir: reconcile repairs the row it calls live ──"
fresh_pool tmprec; reset_logs
register pi-runner-recl
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-recl >/dev/null
printf 'TMPDIR=%s/pi-runner-recl/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-recl/.env"
assert_absent "$RUNNER_ROOT/pi-runner-recl/tmp" "the live row's TMPDIR is gone before the pass"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "reconcile exits 0 (nothing was dead)"
assert_contains "$out" "created tmpdir=$RUNNER_ROOT/pi-runner-recl/tmp" "and it repaired the LIVE row"
if [ -d "$RUNNER_ROOT/pi-runner-recl/tmp" ]; then ok "the live row's TMPDIR exists after the pass"; else bad "the live row's TMPDIR was NOT created"; fi

# ── (8) AN UNREADABLE `.env` IS cannot-measure, NEVER A MEASURED ZERO ─────────────────────
# ⛔ `[ -f ]` is TRUE for a mode-000 file, so the read failed and the empty result was counted as "this
#   instance names no TMPDIR": status printed `tmpdir_defects=0` (rc 0) over an instance whose jobs all
#   die at mktemp. `status` may legitimately run as a DIFFERENT user from the runner's, so that shape is
#   reachable — and a count is not a reading (#2834).
echo "── tmpdir: an unreadable .env is cannot-measure, not a measured zero ──"
fresh_pool tmplock; reset_logs
register pi-runner-lock
printf 'TMPDIR=%s/pi-runner-lock/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-lock/.env"
chmod 000 "$RUNNER_ROOT/pi-runner-lock/.env"
if [ "$(id -u)" -eq 0 ]; then
  skip "an unreadable .env (a root shell reads it anyway)"
else
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
  assert_eq "$?" "2" "status refuses to grade a .env it could not read (rc 2, never rc 0 over a guess)"
  assert_contains "$out" "cannot-measure why=tmpdir-unreadable" "and it names the file"
  assert_omits "$out" "tmpdir_defects=0" "it publishes no zero over a reading it never took"
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-lock)" "2" \
    "and restart starts NOTHING on an env it cannot read"
  assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-lock") ))" "0" "no listener was started for it"
fi
chmod 600 "$RUNNER_ROOT/pi-runner-lock/.env"

# ── (9) A VALUE THAT NEEDS SHELL EXPANSION IS REFUSED, NOT GUESSED AT ────────────────────
# ⛔ `run.sh` SOURCES `.env`; a `sed` read does not. `TMPDIR=$HOME/ci-tmp` therefore had this tool create
#   a directory literally named `$HOME` (under the instance dir, because the value is not `/`-leading),
#   print `created tmpdir=…` and exit 0 — while the listener inherited an ABSENT /home/…/ci-tmp. The
#   (a trailing comment is the opposite case — a sourcing shell ENDS the value at the whitespace, so it
#   is TOLERATED; see case 9 below.)
echo "── tmpdir: a \$VAR value is refused, not mis-created ──"
fresh_pool tmpexp; reset_logs
register pi-runner-exp
printf 'TMPDIR=$HOME/ci-tmp\n' >"$RUNNER_ROOT/pi-runner-exp/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-exp)"
assert_eq "$?" "2" "a \$VAR value is cannot-act (rc 2), never a guessed directory"
assert_contains "$out" "cannot-act why=tmpdir-value-not-literal" "naming the shape it refused"
assert_contains "$out" "value=\$HOME/ci-tmp" "and the value it read"
assert_absent "$RUNNER_ROOT/pi-runner-exp/\$HOME" "no literal '\$HOME' directory was created (the false PASS this replaces)"

assert_absent "$RUNNER_ROOT/pi-runner-exp/ci-tmp" "and nothing was guessed at either"
assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-exp") ))" "0" "nothing was started"

# ── (9a) SHELL SYNTAX THIS PARSER DOES NOT MODEL IS REFUSED, NEVER TRUNCATED ────────────────
# ⛔ Truncating at syntax instead of refusing it created a DIFFERENT directory and reported
#   `created tmpdir=…` with rc 0 over the real path's absence — measured on the round-2 shape:
#     `TMPDIR=/tmp/x/a\ b`       → created `a\`       (the shell's value is `/tmp/x/a b`)
#     `TMPDIR=/tmp/x/x; echo hi` → created `x;`       (the shell's value is `/tmp/x/x`)
#     `TMPDIR='/tmp/adj'x`       → created `/tmp/adj` (adjacent segments concatenate: `/tmp/adjx`)
#   A backslash, a separator, a redirection or a subshell is EVALUATION, and this tool will not
#   evaluate another user's `.env` (`status` may run as root) — so each is `cannot-act` (#3004 review
#   round 3, P1).
echo "── tmpdir: backslash / separator / adjacent-segment values are refused, not truncated ──"
syn_expect() { # <case#> <value> <truncated-path-that-must-NOT-exist>
  fresh_pool "tmpsyn$1"; reset_logs
  register "pi-runner-syn$1"
  printf 'TMPDIR=%s\n' "$2" >"$RUNNER_ROOT/pi-runner-syn$1/.env"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name "pi-runner-syn$1")"
  assert_eq "$?" "2" "value [$2] is cannot-act (rc 2), never a truncated path"
  assert_contains "$out" "cannot-act why=tmpdir-value-" "naming the shape it refused"
  assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-syn$1") ))" "0" "and it started nothing"
  assert_absent "$3" "the truncated path [$3] was NOT created"
}
# ⛔ THE TRUNCATED PATHS ARE ABSOLUTE — round 2's parser returned `/tmp/x/a\`, `/tmp/x/x;` and
# `/tmp/x/adj'x`, which live OUTSIDE the fixture. Asserting `$RUNNER_ROOT/<suffix>` (the first draft)
# could never fail AND let a regression write into the host's /tmp, so the subject is the real path and
# it is cleaned up before and after.
rm -rf '/tmp/x/a\' '/tmp/x/x;' "/tmp/x/adj'x" 2>/dev/null
syn_expect 1 '/tmp/x/a\ b'      '/tmp/x/a\'
syn_expect 2 '/tmp/x/x; echo hi' '/tmp/x/x;'
syn_expect 3 "/tmp/x/adj'x"      "/tmp/x/adj'x"
rm -rf '/tmp/x/a\' '/tmp/x/x;' "/tmp/x/adj'x" 2>/dev/null
fresh_pool tmpcmt; reset_logs
register pi-runner-cmt
printf 'TMPDIR=%s/pi-runner-cmt/tmp  # scratch\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-cmt/.env"
: >"$TMPLOG"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$TMPLOG" run restart --name pi-runner-cmt)"
assert_eq "$?" "0" "a trailing comment is TOLERATED — an unquoted assignment ends at the whitespace"
assert_contains "$out" "created tmpdir=$RUNNER_ROOT/pi-runner-cmt/tmp (named by" "so the value BEFORE the comment is created"
assert_contains "$(cat "$TMPLOG")" "present $RUNNER_ROOT/pi-runner-cmt/tmp" "and that is the path the listener inherits"
assert_absent "$RUNNER_ROOT/pi-runner-cmt/tmp  # scratch" "no directory whose NAME carries the comment was made"

# ── (9b) LEGAL VALUES THE OLD REFUSAL TOOK WITH IT ──────────────────────────────────────────
# ⛔ The previous shape stripped quotes FIRST and then refused the remainder for whitespace/`$`/`~`,
# i.e. it removed exactly the characters that had made the value legal. A quoted path with a SPACE
# and a single-quoted `$` are values the sourcing listener honours EXACTLY, yet both were `cannot-act`,
# so `restart` — the remedy `status` prints — started NOTHING on a legal `.env` (#3004 review, P2).
echo "── tmpdir: a quoted path with a space, and a single-quoted dollar, are ACCEPTED ──"
fresh_pool tmpq; reset_logs
register pi-runner-q
printf 'TMPDIR="%s/pi-runner-q/dir with space"\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-q/.env"
: >"$TMPLOG"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$TMPLOG" run restart --name pi-runner-q)"
assert_eq "$?" "0" "a double-quoted path containing a space is accepted"
if [ -d "$RUNNER_ROOT/pi-runner-q/dir with space" ]; then ok "and the directory is created with that name"; else bad "the space-bearing directory was not created"; fi
assert_contains "$(cat "$TMPLOG")" "present $RUNNER_ROOT/pi-runner-q/dir with space" "and the listener inherits it"
fresh_pool tmpq2; reset_logs
register pi-runner-q2
printf "TMPDIR='%s/pi-runner-q2/\$lit'\n" "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-q2/.env"
: >"$TMPLOG"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$TMPLOG" run restart --name pi-runner-q2)"
assert_eq "$?" "0" "a single-quoted value containing a dollar is accepted (single quotes are LITERAL)"
if [ -d "$RUNNER_ROOT/pi-runner-q2/\$lit" ]; then ok "the literal-dollar directory is created, not an expanded one"; else bad "the literal-dollar directory was not created"; fi

# ── (9c) AN UNTERMINATED QUOTE NAMES NO PATH ────────────────────────────────────────────────
# `TMPDIR="/tmp/x` has no closing quote, so the string written is not a path the listener resolves.
# The old code created a directory literally named after the stray quote — a false success.
echo "── tmpdir: an unterminated quote is refused, not turned into a directory ──"
fresh_pool tmpuq; reset_logs
register pi-runner-uq
printf 'TMPDIR="/tmp/unterminated\n' >"$RUNNER_ROOT/pi-runner-uq/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-uq)"
assert_eq "$?" "2" "an unterminated quote is cannot-act (rc 2)"
assert_contains "$out" "cannot-act why=tmpdir-value-unterminated-quote" "naming the shape"
assert_absent "$RUNNER_ROOT/pi-runner-uq/\"" "no directory named after the stray quote was created"
assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-uq") ))" "0" "nothing was started"

# ── (10) `export TMPDIR=` IS THE SAME ASSIGNMENT TO A SOURCING SHELL ─────────────────────
# `. ./.env` honours `export TMPDIR=…`; requiring a bare `TMPDIR=` made the assignment invisible to BOTH
# the creation and the detection, so the directory was never made and status never reported it.
echo "── tmpdir: 'export TMPDIR=' is honoured ──"
fresh_pool tmpexport; reset_logs
register pi-runner-exp2
printf 'export TMPDIR=%s/pi-runner-exp2/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-exp2/.env"
: >"$TMPLOG"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$TMPLOG" run restart --name pi-runner-exp2)"
assert_eq "$?" "0" "an exported assignment is read like any other"
assert_contains "$out" "created tmpdir=$RUNNER_ROOT/pi-runner-exp2/tmp" "so the directory is created"
assert_contains "$(cat "$TMPLOG")" "present $RUNNER_ROOT/pi-runner-exp2/tmp" "and the listener inherits it"

# ── (11) A PREVIEW MAY NOT ANNOUNCE A START THE REAL PASS REFUSES ───────────────────────
# ⛔ The env precondition lives in `start_listener`, i.e. DOWNSTREAM of cmd_restart's `--dry-run` return,
#   so an uncreatable TMPDIR previewed as "would start the listener" (rc 0) and then refused for real
#   (rc 2) — the lying preview this file refuses elsewhere. A preview must also MUTATE nothing.
echo "── tmpdir: --dry-run tells the truth and mutates nothing ──"
fresh_pool tmpdry; reset_logs
register pi-runner-dry
: >"$RUNNER_ROOT/pi-runner-dry/blocker"
printf 'TMPDIR=%s/pi-runner-dry/blocker/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-dry/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-dry --dry-run)"
assert_eq "$?" "2" "dry-run on an UNCREATABLE target refuses (rc 2), exactly as the real pass does"
assert_omits "$out" "would start the listener" "and does not announce a start it would refuse"
assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-dry") ))" "0" "the preview started nothing"
fresh_pool tmpdry2; reset_logs
register pi-runner-dry2
printf 'TMPDIR=%s/pi-runner-dry2/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-dry2/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-dry2 --dry-run)"
assert_eq "$?" "0" "a creatable target previews as OK"
assert_contains "$out" "dry-run: would create tmpdir=$RUNNER_ROOT/pi-runner-dry2/tmp" "naming the creation it would make"
assert_absent "$RUNNER_ROOT/pi-runner-dry2/tmp" "and the preview MUTATED nothing"

# ── (12) THE DEFECT LINE MUST MATCH THE ROW IT IS UNDER ────────────────────────────────────
# The arm runs for DEAD rows too, where "the listener row above (and GitHub) report it healthy" is false.
echo "── tmpdir: the defect line does not claim a DEAD row is healthy ──"
fresh_pool tmpdead; reset_logs
register pi-runner-dead
printf 'TMPDIR=%s/pi-runner-dead/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-dead/.env"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "3" "a DEAD row with a missing TMPDIR is still a defect (rc 3)"
assert_contains "$out" "defect tmpdir-missing name=pi-runner-dead" "it is reported"
assert_contains "$out" "the listener row above reports it DEAD" "and the clause matches the row state"
assert_omits "$out" "report it healthy" "it does not assert a health the row contradicts"

# ── (13) AN EXISTING BUT UNWRITABLE TARGET IS cannot-act ──────────────────────────
# The claimed arm the review found UNTESTED (#3004): `mkdir -p` succeeds over an existing directory and
# does NOT tighten it, so a target that exists but cannot be written is the one shape where the
# directory test passes and `mktemp` would still fail. The verdict is the WRITABILITY, not the existence.
echo "── tmpdir: an existing but UNWRITABLE target refuses, starting nothing ──"
fresh_pool tmpunw; reset_logs
register pi-runner-unw
mkdir -p "$RUNNER_ROOT/pi-runner-unw/tmp"; chmod 500 "$RUNNER_ROOT/pi-runner-unw/tmp"
printf 'TMPDIR=%s/pi-runner-unw/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-unw/.env"
if [ "$(id -u)" -eq 0 ]; then
  skip "an unwritable TMPDIR (a root shell bypasses the write bit)"
else
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-unw)"
  assert_eq "$?" "2" "an unwritable target is cannot-act (rc 2), not a start"
  assert_contains "$out" "cannot-act why=tmpdir-unwritable" "and it names the write bit, not the path's absence"
  assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-unw") ))" "0" "NO listener was started — it could not run a job anyway"
fi
chmod 700 "$RUNNER_ROOT/pi-runner-unw/tmp"

# ── (13b) WRITE IS NOT SEARCH: mode 200 has `-w` and NO `-x`, and `mktemp` fails in it ─────
# ⛔ `[ -w ]` alone returned 0 SILENTLY — no `created`, no `cannot-act` — over a TMPDIR `mktemp` fails
# in (measured: rc 1), which is the false PASS the function's header says it refuses. Case (13) cannot
# see it: mode 500 has no WRITE bit, so it exercises the arm that was already there.
echo "── tmpdir: a target with WRITE but no SEARCH refuses (mode 200) ──"
fresh_pool tmpsrch; reset_logs
register pi-runner-srch
mkdir -p "$RUNNER_ROOT/pi-runner-srch/tmp"; chmod 200 "$RUNNER_ROOT/pi-runner-srch/tmp"
printf 'TMPDIR=%s/pi-runner-srch/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-srch/.env"
if [ "$(id -u)" -eq 0 ]; then
  skip "a search-bit-only defect (root bypasses the execute bit)"
else
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-srch)"
  assert_eq "$?" "2" "a target with no SEARCH bit is cannot-act (rc 2), not a silent success"
  assert_contains "$out" "cannot-act why=tmpdir-unwritable" "and it says which bit is missing"
  assert_contains "$out" "w=y x=n" "naming the two readings that disagree"
  assert_eq "$(( $(listeners_for "$RUNNER_ROOT/pi-runner-srch") ))" "0" "NO listener was started"
fi
chmod 700 "$RUNNER_ROOT/pi-runner-srch/tmp"

# ── (13c) THE LIVE ARM MAY NOT CREATE A DIRECTORY IN ANOTHER USER'S NAME ─────────────────────
# ⛔ The owner claim (`created BY THE USER THAT WILL RUN THE LISTENER`) holds for the START path only.
# A LIVE listener may belong to another user — the systemd unit that survived the reboot started it —
# so a mode-700 directory made by an operator running this as root would belong to ROOT: the runner
# could not write it, jobs would still die (EACCES instead of ENOENT), `[ -w ]` is trivially true for
# root and `status` tests existence only, so every instrument would call the row clean. pid 1 is a
# real live process owned by a DIFFERENT user on every non-root host, which is the whole guard.
echo "── tmpdir: the live arm refuses to create a TMPDIR owned by another user ──"
fresh_pool tmpown; reset_logs
register pi-runner-own
register pi-runner-own-shim
printf 'TMPDIR=%s/pi-runner-own/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-own/.env"
printf 'TMPDIR=%s/pi-runner-own-shim/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-own-shim/.env"
# ⛔ TWO CONDITIONS MAKE THIS UNTESTABLE HERE, AND BOTH ARE `skip`, NOT A SILENT PASS: a root shell
# owns every process it could compare against, and a container's pid 1 IS the invoking user. The
# comparison below is run against the REAL `ps` (`$BIN` is dropped from PATH) because this suite
# deliberately replaces `ps` with a table shim — and the guard is written to treat a shim-shaped read
# as "no mismatch proven", so asserting the refusal through the stub would pin the opposite.
if [ "$(id -u)" -eq 0 ]; then
  skip "an owner mismatch (a root shell owns every process it can compare against)"
elif [ "$(PATH=/usr/bin:/bin:/usr/sbin:/sbin ps -o user= -p 1 2>/dev/null | tr -d '[:space:]')" = "$(id -un)" ]; then
  skip "an owner mismatch (pid 1 in this container already runs as $(id -un))"
else
  FNS="$T/shipped-fns.sh"; export FNS
  shipped_fns "$POOL" "${TMPDIR_FNS[@]}" >"$FNS"
  # shellcheck disable=SC2016
  own_out="$(POOL="$POOL" ROOT="$RUNNER_ROOT" PATH=/usr/bin:/bin:/usr/sbin:/sbin bash -c '
    err() { echo "$*" >&2; }; log_line() { echo "$*"; }; DRY=0 TMP_MAX_AGE_MIN=1440
    . "$FNS"
    ensure_tmpdir "$ROOT/pi-runner-own" 1
  ' 2>&1)"
  assert_contains "$own_out" "cannot-measure why=tmpdir-owner-mismatch" "the live arm refuses an owner whose access it cannot measure"
  assert_contains "$own_out" "pid=1 runs as user=" "naming the live listener it compared"
  assert_absent "$RUNNER_ROOT/pi-runner-own/tmp" "and it created nothing under the wrong owner"
  POOL="$POOL" ROOT="$RUNNER_ROOT" PATH=/usr/bin:/bin:/usr/sbin:/sbin bash -c '
    err() { echo "$*" >&2; }; log_line() { echo "$*"; }; DRY=0 TMP_MAX_AGE_MIN=1440
    . "$FNS"
    ensure_tmpdir "$ROOT/pi-runner-own"
  ' >/dev/null 2>&1
  if [ -d "$RUNNER_ROOT/pi-runner-own/tmp" ]; then ok "the START path (no live listener) still creates it"; else bad "the start path stopped creating the directory"; fi
fi
# ⛔ AND THE SHIM ITSELF MUST NOT BECOME A REFUSAL: with the fixture's `ps` in PATH (a garbage-shaped
# table), the live repair still has to go through — the false block this guard would otherwise create
# on every box whose `ps` is not a real one.
own_shim="$(POOL="$POOL" ROOT="$RUNNER_ROOT" bash -c '
  err() { echo "$*" >&2; }; log_line() { echo "$*"; }; DRY=0 TMP_MAX_AGE_MIN=1440
  . "$FNS"
  ensure_tmpdir "$ROOT/pi-runner-own-shim" 1
' 2>&1)"
assert_omits "$own_shim" "tmpdir-owner-mismatch" "a shim-shaped ps reading is NOT turned into a refusal"
if [ -d "$RUNNER_ROOT/pi-runner-own-shim/tmp" ]; then ok "and the live repair still creates the directory under it"; else bad "a shim-shaped ps blocked the repair"; fi


# ══ PRIVATE TEMP ROOT: EVERY INSTANCE HAS ITS OWN (agent-infra#7815) ════════════════════════
# A CI shard died with `SharedTmpdirScanError: os.scandir('/tmp')` in tortoise's
# `tests/_tmpdir_hygiene.py`: that guard scans the HOST temp dir and refuses entries it does not own, so
# on a self-hosted runner with no `.env`-named TMPDIR every job inherited the BOX's `/tmp` — shared with
# every other runner install on that machine, every peer lane, and one unrelated fixture that had
# written 337 GB there (agent-infra#3003). A shared temp dir makes that guard unpassable for reasons no
# PR controls. These cases pin the two halves that can each silently disappear:
#   the DIRECTORY (0700, inside the instance, re-created by every start), and
#   the EXPORT    (the listener — and therefore every job — is exec'd with TMPDIR/TMP/TEMP in it).
# Both are observed from INSIDE the listener stub, at the instant the real `run.sh` would hand that env
# to a job, so a launcher that merely created a directory cannot pass.
echo "── private temp root: one per instance, 0700, inside its own instance dir ──"
fresh_pool tmpiso; reset_logs
register pi-runner-iso-a
register pi-runner-iso-b
ISOLOG="$T/iso.log"; : >"$ISOLOG"
root_a="$RUNNER_ROOT/pi-runner-iso-a/_tmp"
root_b="$RUNNER_ROOT/pi-runner-iso-b/_tmp"
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$ISOLOG" run restart --name pi-runner-iso-a >/dev/null
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$ISOLOG" run restart --name pi-runner-iso-b >/dev/null
assert_dir "$root_a" "instance A has a private temp root"
assert_dir "$root_b" "instance B has a private temp root"
assert_eq "$(mode_of "$root_a")" "700" "A's root is 0700 (a private per-runner temp dir)"
assert_eq "$(mode_of "$root_b")" "700" "B's root is 0700"
assert_ne "$root_a" "$root_b" "the two instances get DIFFERENT temp roots"
assert_ne "$root_a" "/tmp" "A's root is not the machine-wide /tmp"
assert_ne "$root_b" "/tmp" "B's root is not the machine-wide /tmp either"
case "$root_a" in
  "$RUNNER_ROOT/pi-runner-iso-a/"*) ok "A's root is INSIDE A's own instance dir" ;;
  *) bad "A's root is not inside its own instance dir (got: $root_a)" ;;
esac
case "$root_b" in
  "$RUNNER_ROOT/pi-runner-iso-b/"*) ok "B's root is INSIDE B's own instance dir" ;;
  *) bad "B's root is not inside its own instance dir (got: $root_b)" ;;
esac
# ⛔ THE LISTENER'S OWN ENV, not the directory's existence: this is the assertion that goes red when the
#   export is removed, and it is why the stub records what it inherited rather than what exists after.
assert_contains "$(cat "$ISOLOG")" "present $root_a" "A's listener was exec'd with A's root as TMPDIR"
assert_contains "$(cat "$ISOLOG")" "present $root_b" "B's listener was exec'd with B's root as TMPDIR"
assert_eq "$(grep -cF -- "present $root_a" "$ISOLOG")" "1" "exactly one start recorded A's root (no cross-wiring)"
# ⛔ COMPARED AS RESOLVED PATHS: `tempfile.gettempdir()` normalises (`//`→`/`, and a symlinked base
#   such as macOS's /var → /private/var is a DIFFERENT spelling of the same directory), so a raw string
#   comparison would go red over a purely cosmetic difference and prove nothing about isolation.
tmpdir_of() { env TMPDIR="$1" python3 -c 'import os,tempfile;print(os.path.realpath(tempfile.gettempdir()))'; }
assert_eq "$(tmpdir_of "$root_a")" "$(cd "$root_a" && pwd -P)" \
  "inside A's environment tempfile.gettempdir() IS A's root — the HOST temp dir the tortoise hygiene guard scans"
assert_eq "$(tmpdir_of "$root_b")" "$(cd "$root_b" && pwd -P)" \
  "and inside B's environment it is B's root"
assert_ne "$(tmpdir_of "$root_a")" "$(tmpdir_of "$root_b")" \
  "so two runners on one box cannot see each other's temp files"
assert_ne "$(tmpdir_of "$root_a")" "$(cd /tmp && pwd -P)" \
  "and neither resolves to the machine-wide /tmp (the shared root this change removes)"
assert_absent "$RUNNER_ROOT/pi-runner-iso-a/_work/_temp" \
  "RUNNER_TEMP is NOT created or moved here — the runner owns it, per job"

# ── a RE-INSTALLED instance gets the root back with no hand action ─────────────────────────
# The invariant: `reconcile`/`add` can recreate an instance and the isolation returns. `add` copies the
# release and calls `start_listener`, which is the same path that creates `_tmp` — so nothing has to
# remember the property separately.
echo "── private temp root: a re-installed instance gets it back ──"
pkill -f -- "$RUNNER_ROOT/pi-runner-iso-a/bin/Runner.Listener" 2>/dev/null || true
sleep 0.3
rm -rf "$RUNNER_ROOT/pi-runner-iso-a"     # the instance dir is GONE (a /tmp wipe, an operator rm -rf)
assert_absent "$root_a" "the instance dir — and with it the private root — is gone"
: >"$ISOLOG"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$ISOLOG" run add --name pi-runner-iso-a)"
assert_eq "$?" "0" "add re-creates the instance (rc 0)"
assert_dir "$root_a" "and the private temp root is back — with no hand action"
assert_eq "$(mode_of "$root_a")" "700" "still 0700"
assert_contains "$(cat "$ISOLOG")" "present $root_a" "and the re-installed listener is exec'd with it"

# ── the STABLE root is BOUNDED: an age sweep at every start, not per-job cleanup ──────────
# A stable root grows forever; the runner's per-job `_work/_temp` would not. The bound is mtime AGE, so
# it cannot race a job (whose scratch is minutes old) and it is safe to run on a LIVE instance.
echo "── private temp root: the age bound sweeps it, and keeps what a job may hold ──"
mkdir -p "$root_b/stale-dir"; : >"$root_b/stale-dir/x"; : >"$root_b/stale-file"
touch -t 200001010000 "$root_b/stale-dir/x" "$root_b/stale-file" "$root_b/stale-dir"
: >"$root_b/fresh-file"
assert_file "$root_b/stale-file" "the stale entry exists before the sweep"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-iso-b)"
assert_eq "$?" "0" "restart of the LIVE instance succeeds"
assert_absent "$root_b/stale-file" "an entry older than RUNNER_TMP_MAX_AGE_MIN is swept"
assert_absent "$root_b/stale-dir" "a stale DIRECTORY is swept too"
assert_file "$root_b/fresh-file" "a fresh entry is KEPT — the bound cannot race a running job"
assert_contains "$out" "swept tmpdir-root=$root_b removed=2" "the sweep prints what it removed (a bound nobody can see is a wish)"
# ⛔ THE BOUND IS THE OPERAND, not a constant in the code. The file below is ~2 days old: the DEFAULT
#   bound (1440 = 24 h) sweeps it, a 69-day bound keeps it — so this pair proves the sweep's threshold is
#   what decides, in both directions. (`date -v-2d` is BSD, `date -d` is GNU; the first one that works is
#   used, so the fixture ages identically on both lanes.)
: >"$root_b/stale-2"
two_days_ago="$(date -v-2d '+%Y%m%d%H%M' 2>/dev/null || date -d '2 days ago' '+%Y%m%d%H%M')"
touch -t "$two_days_ago" "$root_b/stale-2"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-iso-b)"
assert_absent "$root_b/stale-2" "the default (24 h) bound sweeps an entry two days old"
: >"$root_b/stale-2"
touch -t "$two_days_ago" "$root_b/stale-2"
out="$(RUNNER_TMP_MAX_AGE_MIN=100000 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-iso-b)"
assert_omits "$out" "swept tmpdir-root=" "a wider RUNNER_TMP_MAX_AGE_MIN sweeps nothing"
assert_file "$root_b/stale-2" "so the SAME file survives the wider bound — the operand is the threshold"
rm -f "$root_b/stale-2"

# ── a MISSING private root is a DEFECT (rc 3) and the printed remedy restores it ──────────
# ⛔ The shape that does the damage: LIVE listener, GitHub says `online`, and the TMPDIR it hands to
#   every job does not exist. `status` tested only a `.env`-named path, so an instance naming none — the
#   common one — read as a HEALTHY row over exactly this state.
echo "── private temp root: a missing one is a source-reported defect, with a runnable remedy ──"
rm -rf "$root_b"                            # deleted UNDER the live listener
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "3" "a missing private root is a defect (rc 3), not a healthy report"
assert_contains "$out" "defect tmpdir-missing name=pi-runner-iso-b path=$root_b" "the defect names the instance and the path"
assert_contains "$out" "summary live=2 dead=0" "and it is NOT a dead-listener verdict (the listener is live)"
assert_contains "$out" "tmpdir_defects=1" "the summary counts it, so a caller need not parse the table"
remedy="$(sed -n 's/.*run: \(.*restart --name pi-runner-iso-b\)$/\1/p' <<<"$out")"
assert_contains "$remedy" "restart --name pi-runner-iso-b" "the remedy is parsed out of the report (not restated)"
# shellcheck disable=SC2086
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash $remedy 2>&1)"
assert_eq "$?" "0" "the PRINTED REMEDY runs and exits 0"
assert_dir "$root_b" "and it restores the private root"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status --all)"
assert_eq "$?" "0" "the report is clean again"
assert_contains "$out" "tmpdir_defects=0" "with the count back at zero"

# ── a PREVIEW may not mutate the root (and must tell the truth about it) ─────────────────
pkill -f -- "$RUNNER_ROOT/pi-runner-iso-a/bin/Runner.Listener" 2>/dev/null || true
sleep 0.3
rm -rf "$root_a"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-iso-a --dry-run)"
assert_eq "$?" "0" "a preview of a start with a missing private root succeeds"
assert_contains "$out" "dry-run: would create tmpdir-root=$root_a" "naming the root it would create"
assert_absent "$root_a" "and the preview MUTATED nothing"
: >"$ISOLOG"
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$ISOLOG" run restart --name pi-runner-iso-a >/dev/null
assert_dir "$root_a" "the real start then creates it"
assert_contains "$(cat "$ISOLOG")" "present $root_a" "and hands it to the listener"

# ── MUTATION: removing the EXPORT takes the isolation with it ──────────────────────────────
# ⛔ A CASE THAT PASSES AGAINST THE MUTANT PINS NOTHING. This copy deletes ONLY the export, leaving the
#   directory creation (and the sweep) intact — so it proves the listener assertions above are reading
#   the EXPORT and not the directory's existence.
echo "── private temp root: mutation — without the export the job gets the box's temp dir ──"
fresh_pool tmpmutex; reset_logs
register pi-runner-mut-env
MUTENV="$T/mutant-tmp-export.sh"
python3 - "$POOL" "$MUTENV" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
# BOTH halves of the handover: the exported variables AND the line that announces them. Removing only
# the exec-line would leave the announcement printing a path the listener never got.
announce = '  log_line "env name=$(basename "$d") TMPDIR=$t TMP=$t TEMP=$t (RUNNER_TEMP is the runner\'s own)"\n'
export_line = '    TMPDIR="$t" TMP="$t" TEMP="$t" exec "$d/run.sh"\n'
for needle in (announce, export_line):
    assert text.count(needle) == 1, "the listener's temp export moved: update the mutation target"
text = text.replace(announce, '').replace(export_line, '    exec "$d/run.sh"\n')
open(dst, "w", encoding="utf-8").write(text)
PY
assert_file "$MUTENV" "the export mutation copy was produced"
root_m="$RUNNER_ROOT/pi-runner-mut-env/_tmp"
: >"$ISOLOG"
mut_out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$ISOLOG" bash "$MUTENV" restart --name pi-runner-mut-env 2>&1)"
assert_omits "$mut_out" "env name=" "the MUTANT never announces the env it hands over"
assert_dir "$root_m" "the mutant still CREATES the directory (the two halves are separable)"
assert_omits "$(cat "$ISOLOG")" "present $root_m" \
  "and its listener is exec'd WITHOUT it — the job then writes to whatever the box gave it, i.e. the shared temp dir this change removes"
pkill -f -- "$RUNNER_ROOT/pi-runner-mut-env/bin/Runner.Listener" 2>/dev/null || true
sleep 0.3
# … and the SHIPPED launcher, on the SAME fixture, does hand it over — so the assertion is two-sided.
: >"$ISOLOG"
FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$ISOLOG" run restart --name pi-runner-mut-env >/dev/null
assert_contains "$(cat "$ISOLOG")" "present $root_m" "the SHIPPED launcher gives the same instance its private root (the assertion is live)"

# ── the sweep's bound is a VALIDATED operand (a typo must not disable it silently) ───────
out="$(RUNNER_TMP_MAX_AGE_MIN=08 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "2" "a zero-padded RUNNER_TMP_MAX_AGE_MIN is cannot-measure (rc 2), never a fatal sweep"
assert_contains "$out" "cannot-measure why=tmp-max-age-unreadable" "and it names the operand"
# ⛔ AND IT IS VALIDATED ON THE VERB THAT SWEEPS (#7815 review, F1). The check used to live in
#   `readings()`, which `restart` never calls — so `RUNNER_TMP_MAX_AGE_MIN=abc` reached
#   `find -mmin +abc` (rc 1, no output) and quietly swept NOTHING, i.e. the bound was disabled on the
#   very path the `defect tmpdir-missing` remedy prints. Both directions are asserted: the operand is
#   refused, and the stale entry it would have judged is still there (a refusal that still swept would
#   make the rc a lie).
: >"$root_b/never-swept"; touch -t 200001010000 "$root_b/never-swept"
out="$(RUNNER_TMP_MAX_AGE_MIN=abc FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-iso-b 2>&1)"
assert_eq "$?" "2" "restart REFUSES an unreadable RUNNER_TMP_MAX_AGE_MIN (rc 2) instead of sweeping on it"
assert_contains "$out" "cannot-measure why=tmp-max-age-unreadable" "naming the operand on the sweeping verb too"
assert_file "$root_b/never-swept" "and NOTHING was swept on the refused pass"
rm -f "$root_b/never-swept"
out="$(RUNNER_TMP_MAX_AGE_MIN=0 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-iso-b 2>&1)"
assert_eq "$?" "2" "and `0` (which `find -mmin +0` reads as \"everything older than a minute\") is refused too"

# ── MUTATION: removing the creation must break these cases ────────────────────────────────
# ⛔ A CASE THAT PASSES AGAINST THE MUTANT PINS NOTHING. The copy below is the shipped script with the
#   creation DEFUSED at its single source — `ensure_tmpdir` returns immediately, so every call site
#   (the `start_listener` start path, `cmd_restart`'s live arm and its hoisted pre-start check, and
#   `cmd_reconcile`'s live arm) does nothing. Deleting one CALL is no longer the right mutation: the
#   repair is deliberately reachable from more than one arm (a live listener is never started again),
#   so a per-call-site mutation proved nothing about the others. Neutering the one function is what
#   reproduces the incident — the listener comes up under a TMPDIR that does not exist.
echo "── tmpdir: mutation — without the mkdir the listener is left unsatisfiable ──"
fresh_pool tmpmut; reset_logs
MUTTMP="$T/mutant-tmpdir.sh"
python3 - "$POOL" "$MUTTMP" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = '  t="$(instance_tmpdir "$d")" || rc=$?\n'
assert text.count(needle) == 1, "the ensure_tmpdir body moved: update the mutation target"
open(dst, "w", encoding="utf-8").write(text.replace(needle, '  return 0  # MUTANT: the creation defused\n' + needle))
PY
assert_file "$MUTTMP" "the mutation copy was produced"
register pi-runner-mut-tmp
MUTLOG="$T/mut-tmpdir.log"; : >"$MUTLOG"
printf 'TMPDIR=%s/pi-runner-mut-tmp/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-mut-tmp/.env"
mut_out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TMPDIR_LOG="$MUTLOG" bash "$MUTTMP" restart --name pi-runner-mut-tmp 2>&1)"
assert_omits "$mut_out" "created tmpdir=" "the MUTANT never creates the directory (so the cases above are live)"
assert_absent "$RUNNER_ROOT/pi-runner-mut-tmp/tmp" "the mutant leaves the target missing — the exact post-reboot state"
assert_contains "$(cat "$MUTLOG")" "absent $RUNNER_ROOT/pi-runner-mut-tmp/tmp" \
  "and its listener comes up under a TMPDIR that does not exist — the state in which every job dies at mktemp"
pkill -f "$RUNNER_ROOT/pi-runner-mut-tmp/bin/Runner.Listener" 2>/dev/null || true

# ── MUTATION: the LIVE-arm repair is load-bearing too ──────────────────────────────────────
# ⛔ The mutation above deletes the call inside `start_listener`, which the live arm never reaches — so
#   it proves nothing about the post-reboot state. This copy deletes ONLY the call in `cmd_restart`'s
#   live arm; the state it must fail to repair is the one this PR is about.
echo "── tmpdir: mutation — the LIVE-arm repair is load-bearing ──"
fresh_pool tmpmutlive; reset_logs
MUTLIVE="$T/mutant-live-arm.sh"
python3 - "$POOL" "$MUTLIVE" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = '    0) ensure_tmpdir "$dir" "$LISTENER_PID" || return 2\n'
assert text.count(needle) == 1, "the live-arm ensure_tmpdir call moved: update the mutation target"
open(dst, "w", encoding="utf-8").write(text.replace(needle, '    0)\n'))
PY
assert_file "$MUTLIVE" "the live-arm mutation copy was produced"
register pi-runner-mut-live
bash "$POOL" restart --name pi-runner-mut-live >/dev/null 2>&1
printf 'TMPDIR=%s/pi-runner-mut-live/tmp\n' "$RUNNER_ROOT" >"$RUNNER_ROOT/pi-runner-mut-live/.env"
mut_out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash "$MUTLIVE" restart --name pi-runner-mut-live 2>&1)"
assert_omits "$mut_out" "created tmpdir=" "the MUTANT never repairs a LIVE row (so the case above is live)"
assert_absent "$RUNNER_ROOT/pi-runner-mut-live/tmp" "the mutant leaves the post-reboot state broken — the defect as shipped"
assert_contains "$mut_out" "live name=pi-runner-mut-live" "while still reporting the listener 'not touched' and exiting 0"
pkill -f "$RUNNER_ROOT/pi-runner-mut-live/bin/Runner.Listener" 2>/dev/null || true

# ══ 10. MUTATION: removing the floor check must break the suite ═════════════════════════════
# The floor is the owner-mandated predicate (#2344 comment 6347825624). A copy with the comparison
# defused must STOP refusing — if that copy still refused, case 2 would be passing on something other
# than the floor and would not catch its removal.
echo "── mutation: the floor check is load-bearing ──"
fresh_pool mutant; reset_logs
MUT="$T/mutant-ci_runner_pool.sh"
python3 - "$POOL" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = '[ "$MEM_MB" -lt "$MEM_FLOOR_MB" ]'
assert text.count(needle) == 1, "the floor comparison moved: update the mutation target"
open(dst, "w", encoding="utf-8").write(text.replace(needle, '[ "$MEM_MB" -lt 0 ]'))
PY
assert_file "$MUT" "the mutation copy was produced"
mut_out="$(FIXTURE_MEM_MB=2263 FIXTURE_NCPU=8 bash "$MUT" add --name pi-runner-mut 2>&1)"
mut_rc=$?
assert_eq "$mut_rc" "0" "the MUTANT no longer refuses below the floor (the floor assertion is live)"
assert_contains "$mut_out" "added name=pi-runner-mut" "the mutant proceeds to add — so case 2 pins the floor"
assert_eq "$(FIXTURE_MEM_MB=2263 FIXTURE_NCPU=8 rc_of add --name pi-runner-shipped)" "3" \
  "the SHIPPED script still refuses the fixture the mutant accepted"
assert_absent "$RUNNER_ROOT/pi-runner-shipped" "the shipped refusal created nothing"

# ── (4) the child dispatch must not depend on `$0` being a path ────────────────────────────
# `bash ci_runner_pool.sh reconcile` from the script's own directory leaves `$0` as a bare filename
# that is not on PATH: with `$0`-based dispatch every child is `command not found`, so no dead
# listener is ever restarted and the pass reports a false cannot-act on a healthy box.
fresh_pool barename; reset_logs
register pi-runner-bare
out="$(cd "$SCRIPT_DIR" && FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash ci_runner_pool.sh reconcile 2>&1)"
assert_eq "$?" "0" "reconcile invoked by a bare relative filename exits 0"
assert_contains "$out" "restarted name=pi-runner-bare" "and its child dispatch actually ran"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-bare")" "1" "the dead listener was restarted"

# ══ 11. usage ═══════════════════════════════════════════════════════════════════════════════
out="$(bash "$POOL" --help 2>&1)"
assert_eq "$?" "0" "--help exits 0"
assert_contains "$out" "ci_runner_pool.sh add      --name <name>" "--help prints the VERBS (not the WHY prose)"
assert_contains "$out" "EXIT: 0 ok" "--help prints the exit-code contract"
# ⛔ THE rc-3 CLAUSE MAY NOT NAME A CONDITION THE CODE RETURNS 2 FOR (#2899 review round 6, P3). The
# legend claimed `status` exits 3 for "a quarantine whose liveness could not be measured" while
# `cmd_status` returns 2 for exactly that row (`UNPROBED`) — and the body says so twice. The legend is
# the ONLY exit contract an operator or scheduler is meant to read, so a clause matching no code path
# mis-routes the caller on the one signal (cannot-measure) it exists to branch on.
# ⛔ AND THE MATCH SUBJECT MUST BE WHITESPACE-FLATTENED (#2899 review round 6, P3 — this assertion was
# VACUOUS when first written). `usage()` prints the header VERBATIM, so a clause that wraps in the
# source never appears contiguously in `$out`: the pre-fix head `fd1a300a9` prints "…or a quarantine
# whose liveness could not\n      be measured (see below)", and an `assert_omits` on the single-line
# phrase therefore passed against the very code it was written to catch. Measured both ways: joined,
# the guard reports the phrase unexpectedly present at `fd1a300a9`; unjoined, it reports nothing.
help_flat="$(printf '%s' "$out" | tr '\n' ' ' | tr -s ' ')"
assert_omits "$help_flat" "quarantine whose liveness could not be measured" \
  "the status rc-3 clause does NOT claim an UNPROBED quarantine (that is rc 2)"
assert_contains "$out" 'quarantined install whose listener could not be probed (`UNPROBED`)' \
  "the rc-2 paragraph names the unmeasured quarantine instead"
assert_contains "$out" "RUNNER_TEMPLATE" "--help prints the env seams"
assert_contains "$out" "every runner on THIS box" "--help scopes --all to this box (no cross-box read here)"
assert_eq "$(rc_of bogus-verb)" "1" "an unknown verb exits 1"
assert_eq "$(rc_of add)" "1" "add with no --name exits 1"

# ⛔ `shift 2` with ONE argument left FAILS WITHOUT DECREMENTING `$#`: `add --name` looped forever
# instead of the documented rc 1, and `--name --dry-run` consumed the FLAG as a name, leaving DRY at 0
# so a preview installed a runner for real.
fresh_pool argv; reset_logs
# ⛔ `timeout(1)` IS GNU COREUTILS AND macOS HAS NO SUCH BINARY: without it these two cases were `rc 127`
#   (command not found) — a RED that says nothing about the shipped script, on every macOS run, and the
#   loop guard they exist for was never measured there. The comparison is an exit code, so a host without
#   the binary must SKIP (and say so) rather than report a red nobody can act on; both bash lanes run it.
if command -v timeout >/dev/null 2>&1; then
  assert_eq "$(timeout 10 bash "$POOL" add --name >/dev/null 2>&1; echo $?)" "1" \
    "'add --name' with no value exits 1 (it used to loop forever)"
  assert_eq "$(timeout 10 bash "$POOL" restart --name >/dev/null 2>&1; echo $?)" "1" \
    "'restart --name' with no value exits 1"
else
  skip "the no-value-argument loop guards ('add --name' / 'restart --name' would HANG, not fail, without a timeout(1) binary on this host)"
fi
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of add --name --dry-run)" "1" \
  "the preview FLAG is not consumed as the name"
assert_absent "$RUNNER_ROOT/--dry-run" "an 'add --name --dry-run' installed nothing"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "and ran no config.sh"

# ⛔ A LEADING ZERO is octal to bash arithmetic and 08/09 are FATAL there: rc 1 (the usage code) from a
# start that already succeeded, or no output at all from status/add/reconcile.
for bad in 08 09 010; do
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_START_SETTLE_S="$bad" run add --name "pi-runner-zero$bad")"
  assert_eq "$?" "2" "RUNNER_START_SETTLE_S=$bad (octal) is cannot-measure (rc 2), never a fatal shift"
  assert_contains "$out" "cannot-measure why=settle-unreadable" "it names the operand"
  assert_absent "$RUNNER_ROOT/pi-runner-zero$bad" "nothing was created"
done
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 RUNNER_CORES_PER_SLOT=08 run status)"
assert_eq "$?" "2" "a zero-padded CORES_PER_SLOT is cannot-measure (rc 2), never rc 1 with no output"
assert_contains "$out" "cannot-measure why=cores-per-slot-unreadable" "it names the operand"

# ⛔ THE NAME CLAIM IS ATOMIC. The `[ -e "$dir" ]` check is check-then-act, and `cp -aL template
#   <existing dir>` NESTS into it rather than failing — so two overlapping adds for ONE name would BOTH
#   configure the same instance: a second registration token spent, `.runner` overwritten, the
#   GitHub-side registration orphaned, and both passes reporting an add neither uniquely made. That is
#   the expected first production shape once a schedule arms the pass (doc §8).
echo "── two concurrent adds for ONE name ──"
fresh_pool race; reset_logs
( FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash "$POOL" add --name pi-runner-race >/dev/null 2>&1; echo $? >"$T/race-a.rc" ) &
race_a=$!
( FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash "$POOL" add --name pi-runner-race >/dev/null 2>&1; echo $? >"$T/race-b.rc" ) &
race_b=$!
wait "$race_a" "$race_b"
race_ok=0; race_taken=0
for race_rc in "$(cat "$T/race-a.rc" 2>/dev/null)" "$(cat "$T/race-b.rc" 2>/dev/null)"; do
  case "$race_rc" in 0) race_ok=$((race_ok + 1)) ;; 4) race_taken=$((race_taken + 1)) ;; esac
done
assert_eq "$race_ok" "1" "exactly ONE of two concurrent adds for one name succeeds"
assert_eq "$race_taken" "1" "the other reports the name unavailable (rc 4), not a second registration"
assert_eq "$(count_lines "$CONFIG_LOG")" "1" "config.sh ran exactly ONCE for that name"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-race")" "1" "and exactly one listener runs"

# ── a SYMLINKED instance dir must still read LIVE ────────────────────────────────────────
# ⛔ `run.sh` resolves its own dir with `cd -P`, so `ps` shows the PHYSICAL path whenever the instance
#   is reached through a symlink — which the migration population (hand-provisioned dirs) legally is.
#   Without the `$phys` arm of the match, a LIVE listener reads DEAD, and `restart` answers that by
#   starting a SECOND listener for one registration (measured: 2 processes, reported as
#   `cannot-act why=listener-never-appeared` for a listener that was running).
echo "── liveness through a SYMLINKED instance dir ──"
fresh_pool symlive; reset_logs
mkdir -p "$T/real"
register pi-runner-sym-real
mv "$RUNNER_ROOT/pi-runner-sym-real" "$T/real/pi-runner-sym"
ln -s "$T/real/pi-runner-sym" "$RUNNER_ROOT/pi-runner-sym"
bash "$POOL" restart --name pi-runner-sym >/dev/null 2>&1
assert_eq "$(listeners_for "$T/real/pi-runner-sym")" "1" "the symlinked registration has one listener"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "0" "a live listener behind a SYMLINKED instance reads LIVE (rc 0, not DEAD)"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-sym)"
assert_contains "$out" "live name=pi-runner-sym" "restart sees it as live and does not touch it"
assert_eq "$(listeners_for "$T/real/pi-runner-sym")" "1" "exactly one listener — no double start"
# ⛔ A SYMLINKED INSTANCE INSIDE THE ROOT IS IN THE POOL (#2381 review round 6, P1). `run.sh` resolves
#   its own dir with `cd -P`, so argv carries the TARGET and the dir is not LITERALLY under the root —
#   while `registered_dirs` counts `$RUNNER_ROOT/pi-runner-sym` as a slot and `listener_pid` reads it
#   LIVE. Reporting it outside refused `add`/`reconcile` on a box whose only defect was a hand-made
#   symlink, with a remedy ("point RUNNER_ROOT at the parent") the operator had already applied.
# A REAL listener argv is NATIVE (`<dir>/bin/Runner.Listener run`, no interpreter); the fixture's own
# stub is a shebang script, so `ps` shows it as `bash <dir>/…`. Plant the native shape too, or this
# pin would ride the wrapper arm and prove nothing about containment.
SYM_EXTRA="424245 $T/real/pi-runner-sym/bin/Runner.Listener run"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$SYM_EXTRA" run status)"
assert_eq "$?" "0" "a NATIVE listener behind an in-root symlink is still a complete pool (rc 0)"
assert_eq "$(grep -cF 'pool-root-incomplete' <<<"$out")" "0" "the symlinked instance is NOT reported outside the pool"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$SYM_EXTRA" run add --name pi-runner-sym-add --dry-run)"
assert_eq "$?" "0" "and add is not refused for it — the symlinked instance IS a slot"
assert_eq "$(grep -cF 'pool-root-incomplete' <<<"$out")" "0" "with no incomplete-pool refusal"
# its listener lives at the symlink's PHYSICAL target, outside every later case's root — kill it here so
# the per-root process-table filter cannot make a LATER case read it as an outside listener
pkill -f -- "$T/real/pi-runner-sym/bin/Runner.Listener" 2>/dev/null || true
sleep 0.3

# ⛔ A POOL THAT EXISTS BUT CANNOT BE LISTED IS NOT AN EMPTY POOL, and this is the direction that
#   SPENDS capacity: the ceiling is COUNTED FROM this listing, so a listing failure read as 0 lets
#   `add` add on a box already at its bound and lets `reconcile` mint listeners until its attempt
#   budget runs out (measured before the guard: 32 listeners on a 3-slot box, rc 0, cannot=0 — the
#   tool's central refusal silently defused). This is the same class as the unreadable process table.
echo "── an unlistable RUNNER_ROOT is cannot-measure, never an empty pool ──"
fresh_pool unlistable; reset_logs
register pi-runner-k1; register pi-runner-k2; register pi-runner-k3
if [ "$(id -u)" -eq 0 ]; then
  skip "an unlistable RUNNER_ROOT (a root shell bypasses directory permissions)"
else
  chmod 300 "$RUNNER_ROOT"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "2" "status on an unlistable pool exits 2, not 0 with slots=0"
  assert_contains "$out" "cannot-measure why=runner-root-unreadable" "it names the unreadable root"
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of add --name pi-runner-k4)" "2" \
    "add on an unlistable pool refuses (rc 2) instead of adding above an unmeasured ceiling"
  assert_eq "$(count_lines "$CONFIG_LOG")" "0" "and it registered nothing"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
  assert_eq "$?" "2" "reconcile on an unlistable pool stops the pass (rc 2)"
  assert_contains "$out" "cannot-measure why=runner-root-unreadable" "the pass says why it stopped"
  assert_contains "$out" "the restart arm could not enumerate the pool" \
    "the RESTART arm refuses too — an empty here-string had made it silently report dead=0"
  assert_contains "$out" "ceiling=unmeasured" "its summary still prints, naming the fields it could not measure"
  if grep -qF 'why=pool-unreadable' <<<"$out"; then
    bad "the restart arm invented a reason of its own (the enumeration already named the cause)"
  else
    ok "the restart arm invents no reason of its own"
  fi
  assert_eq "$(count_lines "$CONFIG_LOG")" "0" "no attempt was spent minting listeners"
  chmod 700 "$RUNNER_ROOT"
  # ⛔ READ **AND** SEARCH are different permissions, and `-r` alone was enough to pass the guard while
  #   every `[ -d "$d" ]` on the entries failed for want of `x`: a mode-444 ROOT listed as an empty,
  #   healthy pool (rc 0). Same false empty reading, one permission bit over.
  chmod 444 "$RUNNER_ROOT"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "2" "a mode-444 root (readable, not searchable) is cannot-measure, not an empty pool"
  assert_contains "$out" "cannot-measure why=runner-root-unreadable" "and it names the root"
  chmod 700 "$RUNNER_ROOT"
fi

# ⛔ A DIR WE CANNOT INSPECT IS COUNTED AS A SLOT **AND** REPORTED unreadable — the conservative
#   direction for the ceiling (a chmod'd registration must not vanish from `slots`: the box would look
#   EMPTIER than it is and the ceiling would under-count), while a DEAD verdict here would be a
#   measured fact the tool never measured (`restart` would then refuse it "add it first").
echo "── an unreadable instance dir: counted, and cannot-measure ──"
fresh_pool locked; reset_logs
register pi-runner-locked
if [ "$(id -u)" -eq 0 ]; then
  skip "an unreadable instance dir (a root shell bypasses directory permissions)"
else
  chmod 000 "$RUNNER_ROOT/pi-runner-locked"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "2" "an unreadable instance is cannot-measure (rc 2), never DEAD (rc 3)"
  assert_contains "$out" "cannot-measure why=instance-unreadable" "and it names the instance"
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-locked)" "2" \
    "restart refuses cannot-measure rather than claiming there is no registration"
  chmod 700 "$RUNNER_ROOT/pi-runner-locked"
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of status)" "3" \
    "and with the mode restored it is a measurable DEAD listener again"
  # ⛔ THE ROOT IS JUDGED BEFORE "no registration": a non-searchable ROOT makes every test on a child
  # path fail, so the verb would report a registration that EXISTS as missing (and `add` then refuses it
  # rc 4). Pinned on the ROOT arm specifically — the mode-000 case above is already caught by `-r`, and
  # an absent name (not a registered one) keeps this case from starting a listener.
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-absent)" "3" \
    "baseline: on a healthy root an ABSENT registration is rc 3 (no registration)"
  chmod 444 "$RUNNER_ROOT"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-absent)"
  assert_eq "$?" "2" "restart on a non-searchable ROOT is cannot-measure, not 'no registration'"
  assert_contains "$out" "cannot-measure why=runner-root-unreadable" "and it names the root, not the name"
  chmod 700 "$RUNNER_ROOT"
  # mode 444: readable but not searchable → `-r` passes, every test on its CONTENTS fails, so the
  # instance was dropped from `slots` (ceiling under-counted → the OVER-add direction).
  chmod 444 "$RUNNER_ROOT/pi-runner-locked"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "2" "a mode-444 instance is cannot-measure, never silently dropped"
  assert_contains "$out" "slots=1" "and it is STILL counted as a slot"
  # ⛔ AND `restart`'s OWN ARM, which is a DELETION target: mode 444 has `r` but no `x`, so a
  #   `[ ! -r ]`-only guard passes it and `[ -f .runner ]` then fails — the verb would answer a
  #   registration that EXISTS with "no registration (add it first)" and rc 3. This assertion is what
  #   makes deleting `[ ! -x "$dir" ]` red; the mode-000 case above cannot (it is caught by `-r`).
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-locked)"
  assert_eq "$?" "2" "restart on a mode-444 instance is cannot-measure, not 'no registration'"
  assert_contains "$out" "cannot-measure why=instance-unreadable" "and it names the instance"
  chmod 700 "$RUNNER_ROOT/pi-runner-locked"
fi

# ⛔ `reconcile`'s PROBE-CANNOT ARM is the one that turns a fail-closed pass into a false PASS: with the
#   counter gone the pass still prints `cannot-measure why=instance-unreadable` on stderr, but its exit
#   code and its summary — the only two things a monitor reads — both say healthy, over a pool it never
#   measured. `status`'s equivalent arm is pinned above; this is `reconcile`'s.
echo "── reconcile: an unmeasurable registration is cannot, not a clean pass ──"
fresh_pool recannot; reset_logs
register pi-runner-rec1
mkdir -p "$RUNNER_ROOT/pi-runner-rec2"; cp -a "$TEMPLATE/." "$RUNNER_ROOT/pi-runner-rec2/"; : >"$RUNNER_ROOT/pi-runner-rec2/.runner"
if [ "$(id -u)" -eq 0 ]; then
  skip "an unmeasurable registration inside reconcile (a root shell bypasses directory permissions)"
else
  chmod 000 "$RUNNER_ROOT/pi-runner-rec2"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
  assert_eq "$?" "2" "reconcile exits 2 when a registration could not be measured"
  assert_contains "$out" "cannot=1" "and its machine-readable summary counts it"
  assert_contains "$out" "restarted name=pi-runner-rec1" "while the arm that could act still ran"
  chmod 700 "$RUNNER_ROOT/pi-runner-rec2"
fi

# ⛔ A REGISTRATION WHOSE `.runner` IS A DANGLING SYMLINK IS STILL A REGISTRATION: `[ -e ]` is false for
#   it, and without the `-L` half it vanishes from `slots` and from the report — the ceiling then
#   under-counts (the OVER-add direction) and a live registration is invisible. The `-L` half of the
#   marker test needs its own fixture for the same reason the root's did.
echo "── a registration with a dangling-symlink marker ──"
fresh_pool ghostmark; reset_logs
register pi-runner-real3
# A COMPLETE INSTALL with an odd MARKER: the `-f`/`-e || -L` disagreement is a marker-classification
# bug, so the rest of the instance must be valid or `restart` would fail for an unrelated reason.
mkdir -p "$RUNNER_ROOT/pi-runner-ghost"; cp -a "$TEMPLATE/." "$RUNNER_ROOT/pi-runner-ghost/"
ln -s "$T/no-such-target" "$RUNNER_ROOT/pi-runner-ghost/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_contains "$out" "slots=2" "a dangling-symlink .runner is still a slot"
assert_contains "$out" "pi-runner-ghost" "and it is listed as a registration"

# ⛔ ONE REGISTRATION, ONE DEFINITION (#2381 review, P2). `restart` used `-f` where the listing and
#   `add` use `-e || -L`, so for this marker `add` answered "already registered — use restart" (rc 4)
#   and `restart` answered "no registration — add it first" (rc 3): the two verbs bounced the operator
#   forever and an ENUMERATED, DEAD slot stayed advertised to GitHub and idle. Both legs are asserted,
#   because the bounce is only visible as the PAIR — either verb alone looks correct.
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-ghost)"
assert_eq "$?" "4" "add calls the dangling-marker dir ALREADY REGISTERED (rc 4)"
assert_contains "$out" "use restart" "and sends the operator to restart"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-ghost)"
assert_eq "$?" "0" "restart acts on the registration add just called registered (no verb bounce)"
assert_contains "$out" "restarted name=pi-runner-ghost" "its listener was started, not refused"
assert_eq "$(grep -cF 'no registration' <<<"$out")" "0" \
  "and restart did not claim an ENUMERATED registration is missing"

# ⛔ THE PASS'S OWN FIRST JOB (#2381 review, P2): a slot `reconcile` ENUMERATES as dead must be
#   started — and a `restart` refusal used to be counted as `refused`, a bucket the exit decision
#   never reads, so the pass printed `dead=1 refused=1` and exited 0. Asserted through the same
#   dangling-marker registration, so the arm is reached by a real disagreement and not by a stub.
pkill -f -- "$RUNNER_ROOT/pi-runner-ghost/bin/Runner.Listener" 2>/dev/null || true
pkill -f -- "$RUNNER_ROOT/pi-runner-real3/bin/Runner.Listener" 2>/dev/null || true
sleep 0.3
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-ghost")" "0" "the ghost listener is gone before the pass"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "reconcile exits 0 when every enumerated dead registration was restarted"
assert_contains "$out" "restarted name=pi-runner-ghost" \
  "the pass restarted the dangling-marker slot it enumerated (never left it dead)"
assert_contains "$out" "refused=0" "and counted no restart as a refusal"

# ⛔ A RUNNER_ROOT THAT EXISTS BUT IS NOT A DIRECTORY is a misconfiguration, not an empty pool — the
#   same false empty reading in a shape no permission bit produces. TWO shapes reach that branch and
#   each is pinned SEPARATELY, because a mode-644 file root is also caught by the traversal arm — a
#   `rc_of` on it would stay green with the whole not-a-directory branch deleted (measured).
echo "── a RUNNER_ROOT that is a FILE / a DANGLING SYMLINK ──"
fresh_pool notadir; reset_logs
rmdir "$RUNNER_ROOT"
printf 'not a pool\n' >"$RUNNER_ROOT"
chmod 755 "$RUNNER_ROOT"          # executable, so ONLY the not-a-directory arm can answer
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "2" "a RUNNER_ROOT that is a regular file is cannot-measure, not an empty pool"
assert_contains "$out" "cannot-measure why=runner-root-not-a-directory" "and it says which misconfiguration"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-x)"
assert_eq "$?" "2" "restart names the not-a-directory root instead of 'no registration'"
assert_contains "$out" "cannot-measure why=runner-root-not-a-directory" "and it says which misconfiguration"
rm -f "$RUNNER_ROOT"
# A DANGLING SYMLINK is the third shape: `[ -e ]` is false for it, so without the `-L` arm the root
# reads as ABSENT — a healthy empty pool (status rc 0, slots=0) over a path that exists.
ln -s "$T/no-such-target" "$RUNNER_ROOT"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "2" "a dangling-symlink RUNNER_ROOT is cannot-measure, not an empty pool"
assert_contains "$out" "cannot-measure why=runner-root-not-a-directory" "and it names the shape"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-x)" "2" \
  "restart refuses a dangling-symlink root too, rather than 'no registration'"
rm -f "$RUNNER_ROOT"

# ⛔ THE CEILING IS RE-READ AFTER THE NAME IS CLAIMED, which is what catches a competing pass that
#   COMPLETED during this add's token mint — the token mint plus a full install copy is a window of
#   seconds, and a pass that finished inside it is exactly what the re-read sees (measured incident
#   shape: 4 registrations on a 3-slot box, both rc 0).
#   ⚠️ This does NOT cover the in-flight arm of the same race: two passes can still both read `slots`
#   before EITHER writes its `.runner`, and the listing cannot see a claim that has not registered yet.
#   That residual is declared in `cmd_add` (the pool-level lock it defers) and is NOT pinned here —
#   do not read this fixture as "the concurrent-add race is closed".
echo "── the ceiling is re-read after the claim (a competitor COMPLETED during the mint) ──"
fresh_pool lateclaim; reset_logs
register pi-runner-c1; register pi-runner-c2      # slots=2, ceiling=3
out="$(FIXTURE_GH_LATE_REGISTER=pi-runner-c3 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-c4)"
assert_eq "$?" "3" "an add that lost the last slot while minting REFUSES (rc 3), it does not over-add"
assert_contains "$out" "REFUSED add name=pi-runner-c4 slots=3 ceiling=3" "and it names both readings"
assert_absent "$RUNNER_ROOT/pi-runner-c4" "the claimed directory was released"
assert_eq "$(count_lines "$CONFIG_LOG")" "0" "and config.sh never ran for it"

# ⛔ A DEAD LISTENER OUTSIDE THE ROOT IS NOT ENUMERABLE, AND THE MESSAGE MUST SAY SO (#2381 review
#   round 6, P1): the reading is the PROCESS TABLE, so a registration under another parent whose
#   listener is DEAD is invisible — and `restart` answered "no registration … (add it first)", the one
#   verb that cannot help, for the population `restart` exists for. The refusal must name the reading
#   instead of asserting absence as a measured fact.
DEADOUT="$T/elsewhere2/pi-runner-deadout"
mkdir -p "$DEADOUT"; cp -a "$TEMPLATE/." "$DEADOUT/"; : >"$DEADOUT/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-deadout)"
assert_eq "$?" "3" "a DEAD registration outside the root is still a refusal (rc 3)"
assert_contains "$out" "PROCESS TABLE" "the message names the reading, instead of asserting absence as fact"
assert_eq "$(grep -cF 'add it first' <<<"$out")" "0" "and it does not send the operator to the verb that cannot help"
assert_eq "$(listeners_for "$DEADOUT")" "0" "nothing was started there"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_contains "$out" "pool_read=process-table-live-only" "and status's summary names the reading it is (live listeners only)"

# ⛔ THE CLEANUP ARM ITSELF IS PINNED (#2381 review round 6, P2): the leak fix is reachable only
#   through a trap, so nothing asserted it worked — a regression would leak one listener per run,
#   invisibly, on the very boxes this tool manages.
echo "── the cleanup arm kills every fixture listener shape ──"
fresh_pool clean; reset_logs
register pi-runner-clean
bash "$POOL" restart --name pi-runner-clean >/dev/null 2>&1
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-clean")" "1" "a fixture listener is running before cleanup"
kill_fixture_listeners
sleep 0.3
assert_eq "$(pgrep -f -- "$T/.*bin/Runner\.Listener" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "cleanup's pattern kills every fixture listener shape (the leak fix is LIVE, not decorative)"

# ⛔ A LITERAL PREFIX IS NOT CONTAINMENT (#2524 review, P1). `$RUNNER_ROOT/../outside/pi-x` starts
#   with the root as a STRING and resolves outside it, so the literal-first arm judged it IN-POOL and
#   the pool read as complete — the over-add this whole arm exists to prevent.
DOTOUT="$T/dot-outside/pi-runner-dotout"
mkdir -p "$DOTOUT/bin"; : >"$DOTOUT/.runner"
DOTARGV="424246 $RUNNER_ROOT/../dot-outside/pi-runner-dotout/bin/Runner.Listener run"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$DOTARGV" run status --all)"
assert_eq "$?" "2" "a '..' argv that RESOLVES outside the root is not in-pool (rc 2)"
assert_contains "$out" "cannot-measure why=pool-root-incomplete" "it is refused, not silently counted"
assert_contains "$out" "outside=$RUNNER_ROOT/../dot-outside/pi-runner-dotout" "and the outside dir is named"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$DOTARGV" rc_of add --name pi-runner-dot-add)" "2" \
  "so add REFUSES instead of registering on a box it cannot count"

# ⛔ A WRAPPER THAT CARRIES ITS OWN `cd` TARGET (#2524 review, P1). The strip loop stops at the first
#   `/`-leading token, which is the wrapper's `cd` target — so the "dir" is no directory at all and a
#   literal prefix test called it inside. It must be cannot-measure, never "complete".
CDARGV="424247 bash -c cd $RUNNER_ROOT/pi-1 && exec $OUTSIDE_DIR/bin/Runner.Listener run"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$CDARGV" run status --all)"
assert_eq "$?" "2" "an unresolvable wrapper argv is cannot-measure (rc 2), not a complete pool"
assert_contains "$out" "cannot-measure why=instance-dir-unresolvable" "naming the argv it could not resolve"

# ⛔ TWO outside dirs pin `join_lines` (#2524 review, P2): the old `tr '\n' ' '` glued the first dir
#   onto the em dash and left the pair unquoted, so a caller could not read the field.
SECOND_OUT="$T/outside-two/pi-runner-two"
mkdir -p "$SECOND_OUT/bin"; : >"$SECOND_OUT/.runner"
TWO_EXTRA="$(printf '%s\n' "424248 $OUTSIDE_DIR/bin/Runner.Listener run" "424249 $SECOND_OUT/bin/Runner.Listener run")"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="$TWO_EXTRA" run status --all)"
assert_eq "$?" "2" "two outside listeners still refuse (rc 2)"
assert_contains "$out" "outside=$OUTSIDE_DIR,$SECOND_OUT " "both dirs are comma-joined, with no glued em dash"

# ⛔ A ROOT OF `/` CONTAINS EVERY ABSOLUTE DIR (#2524 review, P2): normalising `/` away made the
#   containment pattern `//*`, so every listener on the box reported outside it — with a remedy the
#   operator had already applied.
fresh_pool rootslash
register pi-runner-slash
RUNNER_ROOT=/: out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 env RUNNER_ROOT=/ bash "$POOL" status --all 2>&1)"
assert_eq "$(grep -cF 'pool-root-incomplete' <<<"$out")" "0" "RUNNER_ROOT=/ does not report a listener outside itself"
# (rc is NOT asserted here: a listener whose instance dir was deleted under it is legitimately
#  `instance-dir-unresolvable`, and earlier cases leave such fixtures behind.)

# ══ (#2892) ORPHANED REGISTRATIONS — the state no verb could leave ═════════════════════════
# Every arm below is a measured fact from `pi-cell-4` (2026-10-27T03:30–04:20Z), where two installs
# whose registrations GitHub had deleted sat unusable while the "self-healing" pass reported them
# restarted, and the one slot that COULD be revived stayed dead for lack of a scheduled pass.

# ── CAPACITY IS NAMES, NOT DIRECTORIES ───────────────────────────────────────────────────────
# Measured: `/opt/gh-runner-x64-1` and `/opt/gh-runner-cell4-x64` both carry
# `"agentName": "pi-runner-cell4-x64-1"` (agentIds 47 and 35) — one GitHub registration, two local
# directories. Counting directories let the box read `slots=5` against `ceiling=3`.
echo "── capacity: two directories carrying ONE GitHub name ──"
fresh_pool dupname; reset_logs
register pi-runner-d1
register pi-runner-d2
printf '{\n  "agentId": 47,\n  "agentName": "pi-runner-shared"\n}\n' >"$RUNNER_ROOT/pi-runner-d1/.runner"
printf '{\n  "agentId": 35,\n  "agentName": "pi-runner-shared"\n}\n' >"$RUNNER_ROOT/pi-runner-d2/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_contains "$out" "slots=1 ceiling=3" "two dirs carrying one agentName are ONE slot of capacity"
assert_contains "$out" "registrations=2" "and the directory count is still published, as its own field"

# ── AN ORPHANED REGISTRATION IS NOT DEAD, AND NOT CAPACITY ──────────────────────────────────
echo "── an orphaned registration: its own state, and zero capacity ──"
fresh_pool orphan; reset_logs
register pi-runner-orph
: >"$RUNNER_ROOT/pi-runner-orph/.orphan"
printf '{\n  "agentId": 35,\n  "agentName": "pi-runner-cell4-x64-1"\n}\n' >"$RUNNER_ROOT/pi-runner-orph/.runner"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-orph/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "3" "an ORPHANED registration fails the report (rc 3), like a DEAD one"
assert_contains "$out" "ORPHANED" "and it is its OWN state — a bare restart is not the verb that settles it"
assert_contains "$out" "slots=0 ceiling=3" "an orphaned registration is NOT capacity"
assert_contains "$out" "orphaned=1" "and the summary counts it"
# ⛔ THIS ARM PINS A RECORDED TRADE-OFF, NOT A PROOF (#2899 review round 6, P1/R1). The classifier
# reads a LOG LINE, and a skew-era line survives a clock later corrected (actions/runner#4648) — so on
# that shape the install is `orphaned` here and yet `restart` recovers it (see the `skewline` arm).
# Counting such an install back into `slots` would close the over-add window and RE-OPEN the measured
# `pi-cell-4` failure (an unretired orphan taking a slot on a box whose real capacity is one short).
# The owner's direction (R3: an orphaned registration is not capacity) therefore stands, and every
# branch that needs a verified verdict goes through `reclaim` / `reconcile` (rc 6). Overturning it is a
# REOPEN of R3 with the owner — if this assertion is ever the thing in your way, that is the route,
# not an edit here.

# ── restart MUST NOT CALL AN ORPHAN RESTARTED (the lie that hid this for days) ───────────────
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-orph)"
assert_eq "$?" "6" "restart on an orphaned registration is rc 6 (provably orphaned), not 0 and not 2"
assert_contains "$out" "orphaned name=pi-runner-orph" "naming what it found"
assert_contains "$out" "evidence=$RUNNER_ROOT/pi-runner-orph/listener.log" "and the file that proves it"
assert_contains "$out" "reclaim --name pi-runner-orph" "and the verb that repairs it"
assert_eq "$(grep -cF 'restarted name=' <<<"$out")" "0" "it does NOT report a restart it did not achieve"

# ── reclaim: PREVIEW, then RETIRE ────────────────────────────────────────────────────────────
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim --dry-run)"
assert_eq "$?" "0" "a dry-run retire pass exits 0"
assert_contains "$out" "dry-run: would START name=pi-runner-cell4-x64-1 agent_id=35" \
  "it announces the VERIFICATION it would run (a dry run cannot prove a retire, so it does not promise one)"
assert_file "$RUNNER_ROOT/pi-runner-orph/.runner" "and a preview deleted NOTHING"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "reclaim exits 0 when it retired what it found"
assert_contains "$out" "retired name=pi-runner-cell4-x64-1 agent_id=35" "it names the GITHUB identity, not the directory"
assert_contains "$out" "reclaim: retired=1 preserved=0" "and the pass summarises itself"
assert_absent "$RUNNER_ROOT/pi-runner-orph" "the install is gone — the name is free again"
assert_contains "$out" "run: " "and it names the next verb for the freed name"

# ── the CLOCK GUARD: this evidence is ALSO what a skewed clock produces ─────────────────────
# actions/runner#4648/#1798: a wrong clock makes GitHub refuse the session and the listener print the
# SAME line. Retiring is irreversible, so an unproven clock must refuse — never guess.
echo "── reclaim: a skewed clock REFUSES, and an unmeasurable one too ──"
fresh_pool skew; reset_logs
register pi-runner-skew
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-skew/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_TIME_SKEW_S=600 run reclaim)"
assert_eq "$?" "3" "a clock 600 s off GitHub's REFUSES the retirement (rc 3)"
assert_contains "$out" "skew=600s bound=120s" "printing the offset and the bound it broke"
assert_file "$RUNNER_ROOT/pi-runner-skew/.runner" "and NOTHING was deleted"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_CURL_FAIL=1 run reclaim)"
assert_eq "$?" "2" "an UNMEASURABLE clock is cannot-measure (rc 2), never a delete"
assert_contains "$out" "why=clock-unverified" "naming the reading it could not take"
assert_file "$RUNNER_ROOT/pi-runner-skew/.runner" "and it still deleted nothing"

# ── NO EVIDENCE = PRESERVE. A dead-but-registered listener is `restart`'s, not this verb's ───
echo "── reclaim: a revivable registration is PRESERVED, never retired ──"
fresh_pool preserve; reset_logs
register pi-runner-plain
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "a pass with nothing retirable exits 0"
assert_contains "$out" "preserve name=pi-runner-plain" "it names the registration it declined to retire"
assert_contains "$out" "why=no-orphan-evidence" "and the reason"
assert_file "$RUNNER_ROOT/pi-runner-plain/.runner" "the install is untouched"

# ── EVIDENCE OLDER THAN THE CURRENT REGISTRATION IS NOT EVIDENCE ABOUT IT ──────────────────
# An install repaired IN PLACE (`remove` + a fresh `add`) keeps every old log. Reading those would
# retire a registration that its own `.runner` already superseded.
echo "── reclaim: a _diag line older than the marker is stale evidence ──"
fresh_pool staleproof; reset_logs
register pi-runner-fresh
mkdir -p "$RUNNER_ROOT/pi-runner-fresh/_diag"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-fresh/_diag/Runner_20260101-000000-utc.log"
touch -t 202601010000 "$RUNNER_ROOT/pi-runner-fresh/_diag/Runner_20260101-000000-utc.log" 2>/dev/null || true
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "nothing is retired on stale evidence"
assert_contains "$out" "preserve name=pi-runner-fresh" "the registration is preserved"
assert_file "$RUNNER_ROOT/pi-runner-fresh/.runner" "and its marker is still there"

# ── A NAME A LIVE SIBLING HOLDS IS NOT RE-REGISTERED ───────────────────────────────────────
# The measured trap: two installs share `pi-runner-cell4-x64-1`, and registering that name again
# DELETES whichever registration holds it — the exact event that orphaned the install being retired.
echo "── reclaim: retire the stale install, never the live holder of its name ──"
fresh_pool sibling; reset_logs
register pi-runner-live
register pi-runner-stale
orphanize pi-runner-stale
for d in pi-runner-live pi-runner-stale; do
  printf '{\n  "agentId": 47,\n  "agentName": "pi-runner-sibname"\n}\n' >"$RUNNER_ROOT/$d/.runner"
done
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-stale/listener.log"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-live)" "0" \
  "baseline: the sibling's listener comes up"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "the pass retires the stale install and leaves the live one alone"
assert_contains "$out" "kept=$RUNNER_ROOT/pi-runner-live" "naming the LIVE holder of the name"
assert_contains "$out" "nothing was re-registered" "and why it did not re-register that name"
assert_absent "$RUNNER_ROOT/pi-runner-stale" "the stale install is gone"
assert_file "$RUNNER_ROOT/pi-runner-live/.runner" "the live registration is untouched"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-live")" "1" "and still serving"

# ── AN UNREADABLE SIBLING NAME IS NOT "NO SIBLING" ──────────────────────────────────────────
# Guard 3 exists so the pass never tells the operator to re-register a name a working runner holds
# (re-registering DELETES the holder). `registration_name` returns EMPTY when a sibling's `.runner`
# cannot be read, and the old membership test therefore dropped that sibling entirely — so the pass
# printed "the name is free again; run: add", the one instruction that can delete a live runner.
# Measured shape: a sibling whose `.runner` carries no readable `agentName` (here: no agentName at
# all, which needs no permissions and so does not degrade to a root-only skip).
# ⛔ The retire itself is still evidence+clock guarded; it is the ADVICE that must never be a guess.
echo "── reclaim: an unreadable sibling name makes the name UNVERIFIED, never 'free again' ──"
fresh_pool sibunknown; reset_logs
register pi-runner-uu
register pi-runner-us
orphanize pi-runner-us
printf '{}\n' >"$RUNNER_ROOT/pi-runner-uu/.runner"
printf '{\n  "agentId": 9,\n  "agentName": "shared-nm"\n}\n' >"$RUNNER_ROOT/pi-runner-us/.runner"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-us/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_contains "$out" "the name is UNVERIFIED" "the pass says it could not prove the name is free"
case "$out" in
  *"the name is free again"*) bad "it still printed the re-register advice over an unreadable sibling";;
  *) ok "and it does NOT say 'the name is free again; run: add' (that is the instruction that deletes a live runner)";;
esac
assert_absent "$RUNNER_ROOT/pi-runner-us" "the retire still happened (evidence + clock are its guards, not this one)"

# ── AN UNREADABLE *OWN* NAME IS UNVERIFIED TOO (round 3, P1) ────────────────────────────────
# Guard 3 compares the retiring install's name against the pool. An unreadable OWN name used to SKIP
# the guard entirely and leave `sib_unknown=0`, so the pass printed "the name is free again; run: add
# --name <basename>" — the exact instruction that DELETES whichever live runner holds that basename.
# Reachable with no exotic permissions: `add` accepts an EMPTY `.runner` as proof of registration, so
# a `{}` marker sends a real install down this path.
echo "── reclaim: an UNREADABLE own name never prints the re-register advice ──"
fresh_pool ownunknown; reset_logs
register pi-runner-own
register pi-runner-ownholder
printf '{}\n' >"$RUNNER_ROOT/pi-runner-own/.runner"
printf '{\n  "agentId": 42,\n  "agentName": "pi-runner-own"\n}\n' >"$RUNNER_ROOT/pi-runner-ownholder/.runner"
orphanize pi-runner-own
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-own/listener.log"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-ownholder)" "0" \
  "baseline: the runner holding the BASENAME name is LIVE"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_contains "$out" "the name is UNVERIFIED" \
  "an unreadable OWN name proves as little as an unreadable sibling's, so the name is UNVERIFIED"
case "$out" in
  *"the name is free again"*) bad "it still printed 'the name is free again' over an unreadable OWN name";;
  *) ok "and the pass never prints 'run: add --name <basename>' on an unproven own name";;
esac
assert_absent "$RUNNER_ROOT/pi-runner-own" "the retire itself still happened (a fresh refusal + the clock are its guards)"
pkill -f -- "$RUNNER_ROOT/pi-runner-ownholder/bin/Runner.Listener" 2>/dev/null || true

# ── A LIVE HOLDER IN A QUARANTINE DIR IS STILL A HOLDER (round 3, P2) ───────────────────────
# `registered_dirs` excludes `*.retired-*` BY NAME (correct: a retired runner must never re-enter
# capacity), so a listener still RUNNING on a quarantined install was invisible to guard 3 — while this
# file gives that state its own `status` row (LIVE-QUAR). Guard 3 enumerates quarantine names for the
# HOLDER SCAN ONLY; capacity is never counted from them.
echo "── reclaim: a LIVE listener in a QUARANTINE dir still holds its name ──"
fresh_pool quarholder; reset_logs
register pi-runner-hq
register pi-runner-hshared
for d in pi-runner-hq pi-runner-hshared; do
  printf '{\n  "agentId": 71,\n  "agentName": "qname"\n}\n' >"$RUNNER_ROOT/$d/.runner"
done
mv "$RUNNER_ROOT/pi-runner-hshared" "$RUNNER_ROOT/pi-runner-hshared.retired-20260101T000000Z"
qdir="$RUNNER_ROOT/pi-runner-hshared.retired-20260101T000000Z"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of restart --name pi-runner-hshared.retired-20260101T000000Z)" "0" \
  "baseline: a listener IS running on the quarantined install"
orphanize pi-runner-hq
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-hq/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "the pass retires the orphaned install"
assert_contains "$out" "kept=$qdir" \
  "guard 3 sees the LIVE holder inside the quarantine dir (it is a holder, not capacity)"
assert_contains "$out" "nothing was re-registered" "so it never advises re-registering that name"
assert_file "$qdir/.runner" "the quarantined install is untouched"
pkill -f -- "$qdir/bin/Runner.Listener" 2>/dev/null || true

# ── A STALE DELETION LINE DOES NOT AUTHORISE A DELETE IF THE REGISTRATION ANSWERS (round 3, P1) ──
# actions/runner#4648, measured: a box with an unsynchronised clock starts its runner, GitHub refuses
# the session, the runner prints the SAME "registration has been deleted" line and EXITS PERMANENTLY.
# NTP then corrects the clock. The newest log is still the skew-era line, so a log-only retire deletes a
# HEALTHY registration (its GitHub registration survives holding the name, and the re-register advice
# then DELETES it). `reclaim` therefore STARTS the listener and retires only on a refusal it dated
# ITSELF — the only evidence a clock that was wrong yesterday cannot have written.
echo "── reclaim: a skew-era line over a registration that STILL ANSWERS is a revival, not a retire ──"
fresh_pool skewline; reset_logs
register pi-runner-skewline
printf '{\n  "agentId": 61,\n  "agentName": "pi-runner-skewline"\n}\n' >"$RUNNER_ROOT/pi-runner-skewline/.runner"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-skewline/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "the pass exits 0"
assert_contains "$out" "revived name=pi-runner-skewline" \
  "the listener STARTED and SURVIVED, so the old line was a skew artifact and nothing was deleted"
assert_contains "$out" "reclaim: retired=0 preserved=0 revived=1" "the summary counts a REVIVAL, not a retire"
assert_file "$RUNNER_ROOT/pi-runner-skewline/.runner" "the healthy registration is untouched"
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-skewline")" "1" "and it is serving jobs again"
pkill -f -- "$RUNNER_ROOT/pi-runner-skewline/bin/Runner.Listener" 2>/dev/null || true

# ── THE NEWEST LOG DECIDES ──────────────────────────────────────────────────────────────────
# A log accumulates across every start in ONE registration's life, so "some line in some file" is not
# evidence about the CURRENT state. GitHub prints the identical deletion line when session creation
# fails on a SKEWED clock (actions/runner#4648), so an install whose clock was once wrong keeps that
# line forever: after NTP corrected it, the install is revivable, and retiring it deletes a working
# runner. A NEWER log that does not carry the line therefore vetoes the older one — the previous code
# read `listener.log` first and returned on the first match, so the newer `_diag` was never consulted.
echo "── reclaim: a NEWER log showing a later start VETOES older evidence ──"
fresh_pool newest; reset_logs
register pi-runner-veto
orphanize pi-runner-veto
printf '{\n  "agentId": 77,\n  "agentName": "pi-runner-veto"\n}\n' >"$RUNNER_ROOT/pi-runner-veto/.runner"
touch -t 202601010000 "$RUNNER_ROOT/pi-runner-veto/.runner" 2>/dev/null || true
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-veto/listener.log"
touch -t 202601010100 "$RUNNER_ROOT/pi-runner-veto/listener.log" 2>/dev/null || true
mkdir -p "$RUNNER_ROOT/pi-runner-veto/_diag"
printf 'Listening for Jobs\n' >"$RUNNER_ROOT/pi-runner-veto/_diag/Runner_20260101-020000-utc.log"
touch -t 202601010200 "$RUNNER_ROOT/pi-runner-veto/_diag/Runner_20260101-020000-utc.log" 2>/dev/null || true
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "a pass with nothing retirable exits 0"
assert_contains "$out" "preserve name=pi-runner-veto" "the registration is PRESERVED: its newest log shows a later, successful start"
assert_file "$RUNNER_ROOT/pi-runner-veto/.runner" "and its marker is still there"
# CONTROL: with the later log gone, the same line IS the newest evidence — so the veto above is
# load-bearing rather than an arm that can never retire anything.
rm -f "$RUNNER_ROOT/pi-runner-veto/_diag/Runner_20260101-020000-utc.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "control: the pass still exits 0"
assert_contains "$out" "retired name=pi-runner-veto" "control: with no newer log, the line IS evidence and the install retires"
assert_absent "$RUNNER_ROOT/pi-runner-veto" "control: the install is gone"
# ── A FRESH ATTEMPT READS ONLY ITS OWN EVIDENCE, ON EVERY SOURCE ───────────────────────────
# `skip_bytes` scoped `listener.log` only. `_diag/Runner_*.log` is a SEPARATE file per attempt, so a
# PREVIOUS attempt's diag could supply the deletion line for a start that died for an unrelated reason
# — and rc 6 is routed straight into `reclaim`, which deletes the install. Both sources are now
# bounded by the attempt's own start time.
echo "── restart: a PREVIOUS attempt's _diag is not evidence about a FRESH start ──"
fresh_pool attempt; reset_logs
register pi-runner-att
touch -t 202601010000 "$RUNNER_ROOT/pi-runner-att/.runner" 2>/dev/null || true
mkdir -p "$RUNNER_ROOT/pi-runner-att/_diag"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-att/_diag/Runner_20260101-010000-utc.log"
touch -t 202601010100 "$RUNNER_ROOT/pi-runner-att/_diag/Runner_20260101-010000-utc.log" 2>/dev/null || true
# This attempt's listener APPEARS (so the start is not "never appeared") and then dies without
# printing anything: a death that is not evidence of anything.
printf '#!/usr/bin/env bash\nsleep 1.5\nexit 1\n' >"$RUNNER_ROOT/pi-runner-att/bin/Runner.Listener"
chmod +x "$RUNNER_ROOT/pi-runner-att/bin/Runner.Listener"
out="$(RUNNER_START_SETTLE_S=3 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-att)"
assert_eq "$?" "2" "a fresh death with no evidence from THIS attempt is cannot-act (rc 2), never rc 6"
assert_contains "$out" "why=listener-exited" "naming the reason instead of asserting an orphan"
assert_file "$RUNNER_ROOT/pi-runner-att/.runner" "and the install is STILL a registration (rc 6 would have retired it)"
# CONTROL: the same line, this time written BY THIS ATTEMPT (its own listener prints it, as the real one
# does — into `listener.log` past the pre-start byte offset), IS evidence. ⛔ The control must produce the
# line DURING the attempt: a `_diag` file written just before the start is `mt < started` and is excluded
# by the start-time bound, which is the whole point of that bound (#2892 review round 3, P2 — this control
# used to write it before the start and passed only because the bound was inert on `skip=0`).
# ⛔ WHAT MAKES THE ARM ABOVE HOLD is the NEWEST-LOG rule, and this fixture says so rather than claiming
# the start-time bound is what does it: the attempt's own (empty) `listener.log` is newer than the stale
# `_diag`, so it vetoes. The start-time bound is DEFENCE IN DEPTH for the sources a byte offset cannot
# scope (`_diag/Runner_*.log` is a separate file per attempt) — it is kept because it is correct, not
# because this fixture can show it is load-bearing.
cat >"$RUNNER_ROOT/pi-runner-att/bin/Runner.Listener" <<'STUB'
#!/usr/bin/env bash
sleep 1
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n'
exit 0
STUB
chmod +x "$RUNNER_ROOT/pi-runner-att/bin/Runner.Listener"
out="$(RUNNER_START_SETTLE_S=3 FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run restart --name pi-runner-att)"
assert_eq "$?" "6" "control: a line written DURING this attempt IS evidence (rc 6)"
assert_contains "$out" "orphaned name=pi-runner-att" "control: and it names the orphan"

# ── THE QUARANTINE NAMESPACE IS RESERVED, AND A LIVE INSTALL IN IT IS NEVER "rm -rf" ───────
# `registered_dirs` excludes `*.retired-*` BY NAME (correctly: a retired runner must never re-enter
# capacity) and `status` reports such a dir as a leftover whose remedy is `rm -rf`. Nothing stopped
# `add --name` from MINTING a live registration under that suffix, which then left the ceiling
# silently and was reported as deletable. The suffix is now refused; a dir that carries it anyway
# (hand-made, or from an older version) is reported as LIVE when a listener is running on it.
echo "── add: the quarantine SUFFIX is reserved ──"
fresh_pool suffix; reset_logs
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run add --name pi-runner-x.retired-20260101T000000Z)"
assert_eq "$?" "1" "a name carrying the quarantine suffix is REFUSED as a usage error"
assert_absent "$RUNNER_ROOT/pi-runner-x.retired-20260101T000000Z" "and nothing was provisioned"
# ⛔ THE REFUSAL NAMES THE RULE THE NAME ACTUALLY BROKE (#2899 review round 6, P2). The generic text
# recited `[A-Za-z0-9._-]` / no leading dot / no `/` — every one of which THIS name satisfies — so the
# operator was told it broke a rule it obeys and given no way to discover the reserved suffix.
assert_contains "$out" "refused: carries the RESERVED quarantine suffix '.retired-'" \
  "the refusal names the suffix it broke, not a character rule the name obeys"
assert_contains "$out" "must be [A-Za-z0-9._-]" "and still prints the general contract after the reason"
echo "── status: a RUNNING listener under a retired name is never reported as deletable ──"
fresh_pool livequar; reset_logs
register pi-runner-lq
mv "$RUNNER_ROOT/pi-runner-lq" "$RUNNER_ROOT/pi-runner-lq.retired-20260101T000000Z"
QZ="$RUNNER_ROOT/pi-runner-lq.retired-20260101T000000Z"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_EXTRA="424242 $QZ/bin/Runner.Listener run" run status --all)"
assert_contains "$out" "LIVE-QUAR" "the row says LIVE, not QUARANTINE"
assert_contains "$out" "do NOT rm -rf" "and the remedy is the opposite of deleting a working runner"
# ⛔ THE PRESERVE ADVICE MUST EXIST FOR THE NAME IT IS PRINTED ABOUT (#2899 review round 6, P3).
# `reclaim --name <quarantine>` is reachable — the name is refused only for ''/'.'/'..'/'-*'/'*/*' — and
# the pass used to end with "use: restart --name <quarantine>". `restart` starts a listener on a
# retired-named install (it refuses none of those names), i.e. the tool's own advice re-created the
# LIVE-QUAR row above. A retired-named install is never capacity and never startable on purpose, so
# that basename gets the bytes' owner instead. The listener here is already proven DEAD, which is why
# pointing at `rm -rf` cannot delete a running registration.
echo "── reclaim: a NO-EVIDENCE quarantine is not sent to 'restart' ──"
fresh_pool qpres; reset_logs
register pi-runner-qp
mv "$RUNNER_ROOT/pi-runner-qp" "$RUNNER_ROOT/pi-runner-qp.retired-20260101T000000Z"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim --name pi-runner-qp.retired-20260101T000000Z)"
assert_eq "$?" "0" "a no-evidence quarantine is PRESERVED (rc 0)"
assert_contains "$out" "preserve name=pi-runner-qp.retired-20260101T000000Z" "naming the install it declined to retire"
assert_omits "$out" "restart --name pi-runner-qp.retired-20260101T000000Z" \
  "and it is NOT sent to 'restart', which would re-create a LIVE-QUAR row"
assert_contains "$out" "rm -rf it as its owner" "it names the remedy that actually clears those bytes"

# ── THE PASS THAT MAKES IT SELF-HEALING: restart → retire → add, then idempotent ────────────
echo "── reconcile: revives, retires, provisions — and changes nothing on a second pass ──"
fresh_pool reheal; reset_logs
register pi-runner-rd
register pi-runner-ro
: >"$RUNNER_ROOT/pi-runner-ro/.orphan"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-ro/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "reconcile exits 0 when it could measure and act"
assert_contains "$out" "restarted name=pi-runner-rd" "the revivable slot is revived"
assert_contains "$out" "dir=$RUNNER_ROOT/pi-runner-ro evidence=" "the orphan is retired"
assert_contains "$out" "added name=pi-runner-fixturebox-1" "and the freed capacity is provisioned"
assert_contains "$out" "reclaimed=1" "the summary counts the retirement"
assert_contains "$out" "orphaned=0" "and reports the pool after the pass, not before it"
assert_absent "$RUNNER_ROOT/pi-runner-ro" "the orphan's install is gone"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "a second reconcile exits 0"
assert_contains "$out" "reconcile: dead=0 restarted=0 added=0" "and is IDEMPOTENT: nothing left to revive or add"
assert_contains "$out" "reclaimed=0" "and nothing left to retire"

# ── A RETIREMENT WHOSE FILES CANNOT ALL BE REMOVED IS QUARANTINED, NEVER PART-DELETED ───────────
# MEASURED ON `pi-cell-4` (2026-10-27T06:2xZ), with the first version of this verb: systemd had written
# `_diag` as root, so `rm -rf` failed AFTER unlinking `.runner` — the pass honestly reported
# `cannot-act why=retire-failed`, and left 6.9 GB that NO verb could see (every verb identifies a
# registration by `.runner`). So the retire is a RENAME first: the pool loses the registration in one
# atomic step, and the bytes that survive are a `*.retired-<stamp>` directory that `status` keeps
# naming until somebody removes them.
echo "── reclaim: a partial removal is QUARANTINED and stays visible ──"
fresh_pool quarantine; reset_logs
register pi-runner-q
orphanize pi-runner-q
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-q/listener.log"
if [ "$(id -u)" -eq 0 ]; then
  skip "a quarantined retirement (a root shell can remove anything)"
else
  mkdir -p "$RUNNER_ROOT/pi-runner-q/_diag/locked"; : >"$RUNNER_ROOT/pi-runner-q/_diag/locked/root-owned.log"
  chmod 500 "$RUNNER_ROOT/pi-runner-q/_diag/locked"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
  assert_eq "$?" "0" "the pass exits 0: the registration WAS retired, which is what it promised"
  assert_contains "$out" "quarantined dir=$RUNNER_ROOT/pi-runner-q.retired-" "naming the bytes it could not remove"
  assert_contains "$out" "reclaim: retired=1 preserved=0 revived=0 live=0 quarantined=1" "and counting the quarantine"
  assert_absent "$RUNNER_ROOT/pi-runner-q" "the pool no longer has the install at its registered path"
  assert_eq "$(ls -d "$RUNNER_ROOT"/pi-runner-q.retired-* 2>/dev/null | wc -l)" "1" "the leftovers are named on disk"
  # THE POINT OF THE RENAME: those bytes are invisible to nothing. `status` names them, and they are NOT
  # a registration — a `.runner` inside a quarantine dir must never come back as capacity.
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_contains "$out" "QUARANTINE" "status keeps naming a quarantined install"
  assert_contains "$out" "quarantine=1" "and the summary counts it"
  assert_contains "$out" "slots=0 ceiling=3" "while it stays OUT of the ceiling (it is not a runner any more)"
  assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of reclaim)" "0" "a second pass has nothing left to retire"
  for q in "$RUNNER_ROOT"/pi-runner-q.retired-*; do chmod -R u+rwX "$q" 2>/dev/null || true; done
fi


# ── REVIEW-ROUND REGRESSIONS (#2892): four ways this verb could lie or delete the wrong thing ────
# Each fixture below was written AFTER a reviewer reproduced the defect; every one of them passes
# against the pre-review code in a way the suite could not see.

# (1) A re-registered install keeps its OLD `listener.log`. Retiring on that line deletes a HEALTHY
#     runner — the P0 the `_diag` staleness rule already covered for one of the two sources only.
echo "── reclaim: a listener.log OLDER than the marker is stale evidence too ──"
fresh_pool stalelog; reset_logs
register pi-runner-relogged
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-relogged/listener.log"
touch -t 202601010000 "$RUNNER_ROOT/pi-runner-relogged/listener.log" 2>/dev/null || true
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "nothing is retired on a pre-registration listener.log"
assert_contains "$out" "preserve name=pi-runner-relogged" "the healthy install is PRESERVED"
assert_file "$RUNNER_ROOT/pi-runner-relogged/.runner" "and it still exists"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_eq "$?" "3" "and status reads it as DEAD (revivable), never ORPHANED"
assert_eq "$(grep -cF 'ORPHANED' <<<"$out")" "0" "no ORPHANED row for it"

# (2) `tail | grep -q` returns 141 under pipefail once the log passes the pipe buffer, so the evidence
#     is silently MISSED on exactly the long-lived installs that have one. The signature here is at
#     byte 0 of a 200 KB log.
echo "── reclaim: the evidence survives a log far larger than the pipe buffer ──"
fresh_pool biglog; reset_logs
register pi-runner-biglog
orphanize pi-runner-biglog
printf '{\n  "agentId": 55,\n  "agentName": "pi-runner-biglog"\n}\n' >"$RUNNER_ROOT/pi-runner-biglog/.runner"
{ printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n'
  i=0; while [ "$i" -lt 3000 ]; do printf 'INFO ordinary runner chatter line %s padding padding padding\n' "$i"; i=$((i + 1)); done
} >"$RUNNER_ROOT/pi-runner-biglog/listener.log"
# ⛔ THE PREMISE OF THIS ARM IS THE FILE'S SIZE, SO THE SIZE IS ASSERTED (#2892 review round 2, P2).
# It used to compare the file to ITSELF, which pinned nothing: a shrunken fixture (the 64 KiB pipe
# buffer is the whole reason the SIGPIPE defect appears only on long-lived installs, #841/#864) would
# have silently retired this regression while the arm still printed ✅.
bigbytes="$(wc -c <"$RUNNER_ROOT/pi-runner-biglog/listener.log" | tr -d ' ')"
case "$bigbytes" in ''|*[!0-9]*) bigbytes=0 ;; esac
if [ "$bigbytes" -gt 65536 ]; then
  ok "fixture log is ${bigbytes} bytes — past the 64 KiB pipe buffer the SIGPIPE defect needs"
else
  bad "fixture log is ${bigbytes} bytes, which is NOT past the 64 KiB pipe buffer — this arm would prove nothing"
fi
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "the pass retires it"
assert_contains "$out" "retired name=pi-runner-biglog" "a >64 KiB log is still READ (no SIGPIPE under pipefail)"
assert_absent "$RUNNER_ROOT/pi-runner-biglog" "and the install is gone"

# (3) A SYMLINKED instance: renaming the link and `rm -rf`ing it leaves the real install behind while
#     the pass reports success. It must refuse and stay out of the way.
echo "── reclaim: a symlinked instance is REFUSED, not retired through the link ──"
fresh_pool syminst; reset_logs
mkdir -p "$T/symreal/pi-runner-symreal"
cp -a "$TEMPLATE/." "$T/symreal/pi-runner-symreal/"
printf '{\n  "agentId": 99,\n  "agentName": "pi-runner-symname"\n}\n' >"$T/symreal/pi-runner-symreal/.runner"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$T/symreal/pi-runner-symreal/listener.log"
ln -s "$T/symreal/pi-runner-symreal" "$RUNNER_ROOT/pi-runner-symlink"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "2" "the pass refuses (rc 2), because a retire through a link is not what the operator meant"
assert_contains "$out" "why=instance-is-symlink" "naming the reason"
assert_file "$T/symreal/pi-runner-symreal/.runner" "the REAL install survives, untouched"
# ⛔ THE OLD ASSERTION COULD NEVER FAIL (#2892 review round 4, P2): `assert_absent` tests ONE literal
# path, and `reclaim` always appends a stamp (`<dir>.retired-<UTC stamp>`), so a literal
# `…pi-runner-symreal.retired-` — no stamp — was absent whether or not a quarantine had been made of
# the real install. Enumerate the glob instead, so the arm proves what its label claims.
qsym=0
for qsymd in "$T/symreal"/pi-runner-symreal.retired-*; do [ -e "$qsymd" ] && qsym=$((qsym + 1)); done
assert_eq "$qsym" "0" "no quarantine was made of it"
rm -f "$RUNNER_ROOT/pi-runner-symlink"

# (4) A quarantine directory keeps its `.runner`. Unreadable-but-searchable it re-entered `slots` and
#     made every pass `cannot-measure` — the opposite of what the retire message promises.
echo "── a quarantined install never re-enters the pool, readable or not ──"
fresh_pool ghostq; reset_logs
register pi-runner-live-q
mkdir -p "$RUNNER_ROOT/ghost.retired-20260101T000000Z"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/ghost.retired-20260101T000000Z/"
: >"$RUNNER_ROOT/ghost.retired-20260101T000000Z/.runner"
mkdir -p "$RUNNER_ROOT/.dot.retired-20260101T000000Z"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/.dot.retired-20260101T000000Z/"
: >"$RUNNER_ROOT/.dot.retired-20260101T000000Z/.runner"
if [ "$(id -u)" -eq 0 ]; then
  skip "an unreadable quarantine directory (a root shell bypasses directory permissions)"
else
  chmod 311 "$RUNNER_ROOT/ghost.retired-20260101T000000Z"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "3" "the pool is still measurable over unreadable quarantines (rc 3 = the one DEAD runner)"
  assert_contains "$out" "slots=1 ceiling=3" "neither quarantine is capacity, readable or not"
  assert_eq "$(grep -cF 'instance-unreadable' <<<"$out")" "0" "and neither is reported as an unreadable instance"
  assert_contains "$out" "quarantine=2" "BOTH are named — including the dot-named one"
  chmod 700 "$RUNNER_ROOT/ghost.retired-20260101T000000Z"
fi

# (5) The reconcile preview counted every orphan TWICE in `dead=`, the one field a scheduler compares
#     against `slots` to decide whether to act.
echo "── reconcile --dry-run: an orphan is counted as dead ONCE ──"
fresh_pool dryorphan; reset_logs
register pi-runner-dryorph
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-dryorph/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile --dry-run)"
assert_eq "$?" "0" "the preview exits 0"
assert_contains "$out" "reconcile: dead=1 restarted=0" "the orphan counts as ONE dead slot in the preview"
assert_contains "$out" "reclaimed=1" "and the preview announces the retirement"

# (6) A refusal must never be printed as a message containing a COMMAND the shell executes: the
#     preserve message carried `config.sh remove` in backticks inside a double-quoted string.
echo "── the retire messages contain no executable substitutions ──"
fresh_pool nocmd; reset_logs
register pi-runner-nocmd
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim 2>&1)"
assert_eq "$(grep -cF 'command not found' <<<"$out")" "0" "no backtick in a message ran a command"
assert_eq "$(grep -cF 'config.sh: command not found' <<<"$out")" "0" "specifically not config.sh"


# (7) Guard 3 (the LIVE holder of the name) must not degrade to "no sibling" when the pool listing
#     fails on the SECOND read: an empty sibling set makes the pass advise re-registering a name that
#     a working runner may hold, which DELETES that runner's registration.
echo "── reclaim: an unreadable sibling listing is a refusal, not 'no sibling' ──"
fresh_pool siblfail; reset_logs
register pi-runner-sibl
printf '{\n  "agentId": 56,\n  "agentName": "pi-runner-sibl"\n}\n' >"$RUNNER_ROOT/pi-runner-sibl/.runner"
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-sibl/listener.log"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_LS_FAIL_AFTER=1 run reclaim)"
assert_eq "$?" "2" "the pass cannot-act (rc 2) instead of guessing"
assert_contains "$out" "why=runner-root-unreadable" "naming the read it could not take"
assert_file "$RUNNER_ROOT/pi-runner-sibl/.runner" "and NOTHING was retired"
assert_eq "$(grep -cF 'add --name' <<<"$out")" "0" "it never advises re-registering the name"

# ── MUTATION: the orphan SIGNATURE is load-bearing ──────────────────────────────────────────
# If a copy whose signature no longer matches still retired the orphan, every arm above would be
# passing on something other than the evidence.
echo "── mutation: the orphan evidence is what authorises the delete ──"
fresh_pool mutretire; reset_logs
register pi-runner-mut-orph
orphanize pi-runner-mut-orph
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-mut-orph/listener.log"
MUT_R="$T/mutant-retire-ci_runner_pool.sh"
python3 - "$POOL" "$MUT_R" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = 'ORPHAN_SIG="registration has been deleted from the server"'
assert text.count(needle) == 1, "the orphan signature moved: update the mutation target"
open(dst, "w", encoding="utf-8").write(
    text.replace(needle, 'ORPHAN_SIG="a line this script will never match"'))
PY
assert_file "$MUT_R" "the mutation copy was produced"
mut_out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 bash "$MUT_R" reclaim 2>&1)"
assert_eq "$?" "0" "the MUTANT cannot see the orphan, so it retires nothing"
assert_file "$RUNNER_ROOT/pi-runner-mut-orph/.runner" "the mutant left the install in place (so the arms above pin the evidence)"
assert_contains "$mut_out" "preserve name=pi-runner-mut-orph" "the mutant calls it unprovable"
assert_eq "$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of reclaim)" "0" "the SHIPPED script retires it"
assert_absent "$RUNNER_ROOT/pi-runner-mut-orph" "and the fixture the mutant preserved is gone"

# ══ (#2892) A MIXED RUNNER ROOT: a non-member that is PROVABLY not an install ─════════════════
# Measured on `pi-cell-4`: every install lives under `/opt`, and `/opt/containerd` is
# `drwx--x--x root` — unreadable to the runner user, searchable. "Cannot inspect" was one condition
# and turned the only usable root on the box into a permanent `cannot-measure` (rc 2), so the repair
# pass could never act on the box that needed it. Searchability is what separates the two readings.
echo "── a searchable-but-unreadable NON-member of a mixed root ──"
fresh_pool mixed; reset_logs
register pi-runner-real-m
mkdir -p "$RUNNER_ROOT/containerd" "$RUNNER_ROOT/containerd/data"
if [ "$(id -u)" -eq 0 ]; then
  skip "a searchable-but-unreadable non-member (a root shell bypasses directory permissions)"
else
  chmod 311 "$RUNNER_ROOT/containerd"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "3" "the pool is MEASURABLE over a mixed root (rc 3 = its one DEAD runner, not 2)"
  # ⛔ THE OLD CONTROL COULD NEVER FAIL (#2899 review round 5, P2): it asserted the ABSENCE of
  # `containerd/x`, a path the fixture never creates, so it passed whether or not the chmod denied
  # anything. If the mode ever stopped denying the read (a user namespace, a different owner, a
  # `chmod` the kernel normalises away), `registered_dirs` would take the READABLE path, skip
  # `containerd` for carrying no `.runner`, and every other assertion in this arm would be IDENTICAL
  # in both worlds — so the arm would keep printing ✅ while R4's `has_install_marker` path stopped
  # being exercised at all. Assert the PREDICATE the arm turns on: not readable, and still searchable.
  if [ ! -r "$RUNNER_ROOT/containerd" ] && [ -x "$RUNNER_ROOT/containerd" ] && ! ls -A "$RUNNER_ROOT/containerd" >/dev/null 2>&1; then
    ok "(control: the dir really is unlistable — not readable, still searchable)"
  else
    bad "(control: the fixture did not produce an unreadable-but-searchable dir, so this arm proves nothing)"
  fi
  assert_contains "$out" "slots=1 ceiling=3" "and the non-member is not counted as capacity"
  assert_eq "$(grep -cF 'instance-unreadable' <<<"$out")" "0" "nor reported as an unreadable instance"
  # THE CONTROL: the SAME mode OVER A MEMBER is still counted and still cannot-measure — the guard is
  # searchability, not "skip whatever I cannot read".
  register pi-runner-member-m
  chmod 311 "$RUNNER_ROOT/pi-runner-member-m"
  out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
  assert_eq "$?" "2" "a searchable-but-unreadable MEMBER is still cannot-measure (rc 2)"
  assert_contains "$out" "cannot-measure why=instance-unreadable" "naming it"
  chmod 700 "$RUNNER_ROOT/pi-runner-member-m"
  chmod 700 "$RUNNER_ROOT/containerd"
fi

# ── A PROBE THAT COULD NOT RUN IS NOT A DEAD LISTENER (#2892 review round 4, P1) ────────────────
# `probe_listener` has three outcomes (0 live · 1 dead · 2 cannot-measure). The quarantine row folded
# all non-zero into its else, so an UNREADABLE PROCESS TABLE printed "retired install — rm -rf as its
# owner" — the one instruction that deletes a working registration — over a listener nobody had
# measured. The fixture: one measurable registration (so every EARLIER read is real) plus a quarantine
# with no `.runner` (exactly what rename-then-delete leaves behind), and a ps shim that fails only on
# the LAST read, which is the quarantine row's.
echo "── status: a quarantine whose liveness could NOT be read is never called deletable ──"
fresh_pool qunprobed; reset_logs
register pi-runner-qup
mkdir -p "$RUNNER_ROOT/old.retired-20260101T000000Z"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/old.retired-20260101T000000Z/"
rm -f "$RUNNER_ROOT/old.retired-20260101T000000Z/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
rcount="$(cat "$T/.ps-count" 2>/dev/null || printf 0)"
case "$rcount" in ''|*[!0-9]*) rcount=0 ;; esac
if [ "$rcount" -ge 2 ]; then
  ok "the counting run read the process table ${rcount} time(s), so the LAST read can be isolated"
else
  bad "the counting run made only ${rcount} process-table read(s) — the seam below cannot isolate the quarantine row"
fi
rm -f "$T/.ps-count"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 FIXTURE_PS_FAIL_AFTER=$((rcount - 1)) run status)"
assert_eq "$?" "2" "an unmeasurable quarantine row makes the report cannot-measure (rc 2), not rc 3"
assert_contains "$out" "UNPROBED" "the row says the liveness was not measured"
assert_contains "$out" "do NOT rm -rf" "and its remedy is the opposite of deleting a possibly-live runner"
case "$out" in
  *"rm -rf as its owner"*) bad "it printed the DELETE advice over a listener it could not probe" ;;
  *) ok "the delete advice is NOT printed over an unmeasured quarantine" ;;
esac
rm -f "$T/.ps-count"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run status)"
assert_contains "$out" "QUARANTINE" "(control: with the process table readable the same dir IS deletable, rc 3 = its DEAD registration)"
assert_contains "$out" "rm -rf as its owner" "and only then does the delete advice appear"

# ── A QUARANTINE LEFTOVER WITH NO `.runner` IS NOT AN UNREADABLE POOL ENTRY (#2892 round 4, P2) ──
# The holder scan now includes `*.retired-*`, and a quarantine normally has NO `.runner` — rename-then-
# delete unlinks it first, which is the measured `pi-cell-4` failure. Reading that as "a pool entry
# could not be read" marked the NAME unverified on every later pass, so the documented recovery
# (`reclaim` then `add --name …`) never printed again on a box with one leftover.
echo "── reclaim: a quarantine leftover with no .runner does not make the NAME unverified ──"
fresh_pool qleft; reset_logs
register pi-runner-qleft
printf '{\n  "agentId": 73,\n  "agentName": "pi-runner-qleft"\n}\n' >"$RUNNER_ROOT/pi-runner-qleft/.runner"
orphanize pi-runner-qleft
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-qleft/listener.log"
mkdir -p "$RUNNER_ROOT/old.retired-20260101T000000Z"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/old.retired-20260101T000000Z/"
rm -f "$RUNNER_ROOT/old.retired-20260101T000000Z/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "the pass retires the orphaned install"
assert_contains "$out" "retired name=pi-runner-qleft" "naming what it retired"
assert_contains "$out" "the name is free again" "and the documented recovery IS printed (nothing in the pool was unreadable)"
case "$out" in
  *UNVERIFIED*) bad "a quarantine with no .runner was read as an unreadable pool entry" ;;
  *) ok "the name was not declared UNVERIFIED by a non-registration" ;;
esac
# THE CONTROL: a `.runner` that EXISTS but whose agentName cannot be parsed still makes it UNVERIFIED.
fresh_pool qleft2; reset_logs
register pi-runner-qleft2
printf '{\n  "agentId": 74,\n  "agentName": "pi-runner-qleft2"\n}\n' >"$RUNNER_ROOT/pi-runner-qleft2/.runner"
orphanize pi-runner-qleft2
printf 'Failed to create a session. The runner registration has been deleted from the server, please re-configure.\n' \
  >"$RUNNER_ROOT/pi-runner-qleft2/listener.log"
mkdir -p "$RUNNER_ROOT/nameless"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/nameless/"
printf '{}\n' >"$RUNNER_ROOT/nameless/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim)"
assert_eq "$?" "0" "the pass still retires the orphaned install"
assert_contains "$out" "the name is UNVERIFIED" "a '.runner' we could not parse still suppresses the re-register advice"

# ── THE REFUSAL NAMES A REMEDY THAT EXISTS (#2892 review round 4, P2) ──────────────────────────
# `reclaim --name` on a dir that is not a registration used to say "'add --name <name>' is the verb
# that provisions it" — but `add` refuses an existing path with rc 4 (`name-unavailable … already
# exists`), so the advice bounced the operator between two verbs that both refuse.
echo "── reclaim: a dir that is not a registration names a remedy that EXISTS ──"
fresh_pool noregr; reset_logs
mkdir -p "$RUNNER_ROOT/pi-runner-noregr"
cp -a "$TEMPLATE/." "$RUNNER_ROOT/pi-runner-noregr/"
rm -f "$RUNNER_ROOT/pi-runner-noregr/.runner"
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reclaim --name pi-runner-noregr)"
assert_eq "$?" "3" "a path that is not a registration is REFUSED (rc 3)"
assert_contains "$out" "no .runner registration to retire" "naming the state"
assert_contains "$out" "remove $RUNNER_ROOT/pi-runner-noregr" "and naming the action that clears it"
addrc="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 rc_of add --name pi-runner-noregr)"
assert_eq "$addrc" "4" "(control: the ADVICE it used to give returns rc 4 on this very path)"
case "$out" in
  *"add --name pi-runner-noregr"*) bad "the refusal still advises 'add --name', which refuses the same path with rc 4" ;;
  *) ok "the refusal does not send the operator to a verb that refuses the same path" ;;
esac

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ $FAIL assertion(s) failed, $PASS passed"
  if [ "$SKIPPED" -gt 0 ]; then echo "⏭ $SKIPPED case(s) NOT COVERED on this host (see the ⏭ lines)"; fi
  exit 1
fi
echo "✅ all $PASS assertions passed"
if [ "$SKIPPED" -gt 0 ]; then echo "⏭ $SKIPPED case(s) NOT COVERED on this host (see the ⏭ lines)"; fi
