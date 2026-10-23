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
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_ne() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3 (both: $1)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent() { if [ -e "$1" ]; then bad "$2 (exists: $1)"; else ok "$2"; fi; }
assert_file() { if [ -f "$1" ]; then ok "$2"; else bad "$2 (absent: $1)"; fi; }
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
cleanup() {
  pkill -f "$T/root-" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

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
exec /usr/bin/uname "$@"
STUB
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
case "$*" in *registration-token*) printf 'tok-fixture\n'; exit 0 ;; esac
exit 1
STUB
cat >"$BIN/ps" <<'STUB'
#!/usr/bin/env bash
# The process table is the liveness probe. FIXTURE_PS_FAIL makes it unreadable, which must be
# `cannot-measure` — never "no listeners", which would double-start a listener.
[ "${FIXTURE_PS_FAIL:-0}" = 1 ] && { echo "ps: cannot read /proc" >&2; exit 1; }
[ "${FIXTURE_PS_EMPTY:-0}" = 1 ] && exit 0
exec /usr/bin/ps "$@"
STUB
cat >"$BIN/hostname" <<'STUB'
#!/usr/bin/env bash
printf 'fixturebox\n'
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
exec "$DIR/bin/Runner.Listener" run
STUB
cat >"$TEMPLATE/bin/Runner.Listener" <<'STUB'
#!/usr/bin/env bash
# ⛔ argv must STAY "<dir>/bin/Runner.Listener run" — the real binary never execs anything else, so a
# stub that did would let a broken argv matcher pass. Hence a CHILD sleep, killed on TERM/EXIT.
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

run()      { bash "$POOL" "$@" 2>&1; }
rc_of()    { bash "$POOL" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
reset_logs() { : >"$GH_LOG"; : >"$CONFIG_LOG"; }
fresh_pool() { RUNNER_ROOT="$T/root-$1"; export RUNNER_ROOT; rm -rf "$RUNNER_ROOT"; mkdir -p "$RUNNER_ROOT"; }
# register <name> — what a hand-provisioned runner looks like: a complete install with `.runner` and
# NO pid file of ours. This is the migration population (two such runners were the incident).
register() { cp -a "$TEMPLATE" "$RUNNER_ROOT/$1"; : >"$RUNNER_ROOT/$1/.runner"; }

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
assert_eq "$(listeners_for "$RUNNER_ROOT/pi-runner-a")" "1" "a listener is running for the instance dir"

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
fresh_pool prefix
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 POOL_PREFIX='nested/x' timeout 20 bash "$POOL" reconcile 2>&1)"; rc=$?
assert_eq "$rc" "2" "a prefix that cannot name a valid runner ends the pass (rc 2), it does not spin"
assert_absent "$RUNNER_ROOT/nested" "an invalid prefix created nothing"

# ⛔ A NAME COLLISION MUST NOT END THE PASS: six stale dirs occupy -1..-6 and the next free name is
# -7. Ending on the first collision would leave the box BELOW its ceiling with exit 0.
fresh_pool stale
for n in 1 2 3 4 5 6; do mkdir -p "$RUNNER_ROOT/pi-runner-fixturebox-$n"; done
out="$(FIXTURE_MEM_MB=12000 FIXTURE_NCPU=8 run reconcile)"
assert_eq "$?" "0" "a pass through stale names exits 0 (it acted)"
assert_contains "$out" "added name=pi-runner-fixturebox-7" \
  "reconcile SKIPPED the six stale names and added the first FREE one"
assert_contains "$out" "ceiling reached slots=3 ceiling=3" "and it still stopped at the ceiling"

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
assert_contains "$out" "RUNNER_TEMPLATE" "--help prints the env seams"
assert_contains "$out" "every runner on THIS box" "--help scopes --all to this box (no cross-box read here)"
assert_eq "$(rc_of bogus-verb)" "1" "an unknown verb exits 1"
assert_eq "$(rc_of add)" "1" "add with no --name exits 1"

# ⛔ `shift 2` with ONE argument left FAILS WITHOUT DECREMENTING `$#`: `add --name` looped forever
# instead of the documented rc 1, and `--name --dry-run` consumed the FLAG as a name, leaving DRY at 0
# so a preview installed a runner for real.
fresh_pool argv; reset_logs
assert_eq "$(timeout 10 bash "$POOL" add --name >/dev/null 2>&1; echo $?)" "1" \
  "'add --name' with no value exits 1 (it used to loop forever)"
assert_eq "$(timeout 10 bash "$POOL" restart --name >/dev/null 2>&1; echo $?)" "1" \
  "'restart --name' with no value exits 1"
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

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ $FAIL assertion(s) failed, $PASS passed"
  exit 1
fi
echo "✅ all $PASS assertions passed"
