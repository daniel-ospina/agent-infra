#!/usr/bin/env bash
# ci_runner_pool.sh — provision, report and RECONCILE this box's self-hosted CI runner pool.
#
# WHY THIS EXISTS (agent-infra#2373)
#   Provisioning a runner on the fleet's machine had no in-repo path at all. Two scripts could do
#   it, and both existed ONLY as untracked files in a cloud cell's /tmp (`cell-runner-add.sh`,
#   `runner-ctl.sh`) — neither in agent-infra nor in tortoise `origin/main` — so a fresh cell could
#   not provision a runner from the repo, both scripts were one `rm` away from being lost, and every
#   capacity change was a hand step made by whoever was driving. Measured 2026-10-22 22:30-22:45Z:
#   the pool went 6 -> 12 online entirely by hand; two runners GitHub showed OFFLINE were not
#   missing but had DEAD LISTENERS (their `_diag` stopped at 22:03 with `Deleting Runner Session`),
#   and one add was correctly refused at `MemAvailable=2.21 GB is below the 3.5 GB floor`.
#
# THE OWNER DECISION THIS ENCODES (agent-infra#2344, comment 6347825624, 2026-10-22)
#   "The runner build must refuse to add a runner when free memory is below a stated floor, and must
#    report the reading it used — 'manage capacity well' has to be a predicate the machine evaluates,
#    not a wish in a brief." Sizing is per box and MEMORY-bound, not a flat count: 3 slots on an
#    8-core/7.5 GB box, 2 on a 4-core box. Both gates below therefore PRINT the reading they used,
#    on success as well as on refusal. A gate that refuses without the number it read is a wish with
#    a semicolon.
#
# ⛔ THE FLOOR GATES *ADDING*, NEVER *RESTARTING*. Measured in the same incident: two runners came
#   back at ~200 MB each by restarting a stopped listener, while a NEW runner on a 2.21 GB box was
#   correctly refused. Applying the add-floor to a restart would leave a dead listener dead on a
#   busy box — the exact capacity the floor is trying to protect. `restart` has no floor; `add` has.
#
# THE CEILING IS CORE-AWARE AND PER BOX. Slots are bounded by `ceil(ncpu / RUNNER_CORES_PER_SLOT)`:
#   with the default 3 that is 3 on an 8-core box and 2 on a 4-core box, the owner's numbers. It is
#   a bound on how many runners THIS box carries, not a fleet-wide quota, and it is refused with the
#   core count, the ceiling, the slot count AND the memory reading printed.
#
# ⛔ ONE COMPLETE RUNNER INSTALL PER INSTANCE DIR — this is GitHub's layout, not a preference.
#   `config.sh` resolves its OWN directory (`DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"; cd "$DIR"`)
#   and `run.sh` does the same, so config writes `.runner` beside ITSELF and the listener runs from
#   there — the caller's cwd is ignored. Measured on the box: `/tmp/actions-runner/pi-runner-cell1-x64-1/`
#   holds config.sh, run.sh, env.sh, bin/, and the live listener is
#   `/tmp/actions-runner/pi-runner-cell1-x64-1/bin/Runner.Listener run`. So `add` COPIES
#   `RUNNER_TEMPLATE` (one pristine unpacked release) into `$RUNNER_ROOT/<name>` and configures THERE.
#   A single shared install with per-name instance dirs would register runners whose `.runner` never
#   appears where this script looks — and the suite would not have seen it, because a stub that
#   writes `.runner` into $PWD models a contract GitHub's script does not have.
#
# ⛔ LIVENESS IS THE PROCESS TABLE, NOT A PID FILE. A pid file is a stale flag that records a past
#   state and is never revalidated (#8175's class): a recycled pid would read "live" forever, and on
#   a box with no /proc it cannot be revalidated at all. The runner's own process cannot go stale —
#   its argv carries the instance dir and GitHub's binary name is fixed — so `listener_pid` reads
#   `ps` and matches BOTH. That is also the only way the runners the old hand scripts started are
#   visible at all: they wrote no pid file of ours, and reading them as DEAD would double-start a
#   listener on every pass.
#   ⛔ AND AN UNREADABLE PROCESS TABLE IS `cannot-measure`, NOT "no listeners" (#2373 review round
#   2): `ps` failing is the one input here whose absence would produce an ACTION (a double-started
#   listener) rather than a refusal, so it fails closed like every other reading.
#
# ⛔ THE LABEL DESCRIBES THE RUNNER. `ci_runner_gate.sh` selects the pool by `self-hosted-arm64` /
#   `self-hosted-x64`, and its invariant is "a runner's labels must describe that runner". A runner
#   registered with no pool marker is invisible to that gate forever and matches no `runs-on:` job —
#   registered, advertised to GitHub, and idle: zero capacity added. So the marker is derived from
#   the host's arch by DEFAULT, an unknown arch is `cannot-measure`, and a RUNNER_LABELS override
#   must still CONTAIN one of the two markers (a typo is refused, not registered as a jobless
#   runner). Runner NAMES are unique per repo, so the prefix defaults to `pi-runner-<host>` — two
#   boxes' passes must never mint the same name.
#
# THE RECONCILIATION PASS IS THE POINT (`reconcile`), not the one-shot verbs. It is idempotent:
#   (a) start the listener of every EXISTING registration that is dead, (b) add a runner only above
#   the memory floor, (c) REFUSE above the core-aware ceiling. Running it twice changes nothing the
#   second time. NOTHING SCHEDULES IT YET — arming it is an operator decision (which boxes, which
#   interval), so this file is callable and idempotent rather than self-arming.
#
# FAIL-CLOSED. An unreadable memory reading, core count, floor, cores-per-slot, arch, process table
#   or label is `cannot-measure` (rc 2) and changes NOTHING — never read as "probably fine". The
#   memory read is `orchestrator-harness/capacity.sh`'s, so this file adds no fourth /proc/meminfo
#   parser.
#
# USAGE
#   ci_runner_pool.sh status  [--all]              # per-runner rows + this box's readings
#   ci_runner_pool.sh add      --name <name> [--dry-run]
#   ci_runner_pool.sh restart  --name <name> [--dry-run]
#   ci_runner_pool.sh reconcile [--dry-run]        # the pass: restart dead listeners, add to ceiling
#
# ENV: RUNNER_ROOT (one complete install per runner; default /tmp/actions-runner, the measured
#        layout) · RUNNER_TEMPLATE (pristine unpacked release to copy; default $RUNNER_ROOT/_template)
#      RUNNER_MEM_FLOOR_MB (3584 = the 3.5 GB the gate refused at) · RUNNER_CORES_PER_SLOT (3)
#      RUNNER_POOL_REPO (the repo the registration-token is minted for) · RUNNER_TOKEN (skip gh)
#      RUNNER_LABELS (overrides the derived self-hosted-<arch> marker; must still contain it)
#      POOL_PREFIX (default pi-runner-<host>) · RUNNER_START_SETTLE_S (5)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act — nothing changed, EXCEPT a registration
#       the message names explicitly (a `.runner` written before its listener failed) · 3 REFUSED by
#       a gate (a floor/ceiling verdict), nothing changed · 4 name not available (that name is taken;
#       nothing changed, try another name)
#
# `status` exits 3 when it produced a report in which at least one listener is DEAD — a report is
# still a report, but a dead listener is a fact a caller must be able to branch on without parsing
# the table. It exits 2 (never 0, never 3) when it could not measure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPACITY_LIB="${CAPACITY_LIB:-$SELF_DIR/orchestrator-harness/capacity.sh}"

RUNNER_ROOT="${RUNNER_ROOT:-/tmp/actions-runner}"
RUNNER_TEMPLATE="${RUNNER_TEMPLATE:-$RUNNER_ROOT/_template}"
MEM_FLOOR_MB="${RUNNER_MEM_FLOOR_MB:-3584}"   # 3.5 GB, the floor the gate refused at (#2373)
CORES_PER_SLOT="${RUNNER_CORES_PER_SLOT:-3}"  # 8 cores -> 3 slots, 4 cores -> 2 (owner sizing)
SETTLE_S="${RUNNER_START_SETTLE_S:-5}"        # how long a just-started listener gets to appear
POOL_REPO="${RUNNER_POOL_REPO:-daniel-ospina/tortoise}"
GH_CMD="${RUNNER_POOL_GH:-gh}"
POOL_LABEL_X64="self-hosted-x64"
POOL_LABEL_ARM64="self-hosted-arm64"

DRY=0
MEM_MB=""; NCPU=""; CEILING=""; LISTENER_PID=""

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# mb_as_gb <mb> — the human form the owner reads ("2.21 GB"), never the only form printed.
mb_as_gb() { awk -v m="${1:-0}" 'BEGIN{printf "%.2f", m/1024}'; }
usage() {
  # The USAGE..EXIT block, read from this file's own header so help cannot drift from the contract.
  awk '/^# USAGE$/{f=1} f{ if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
  exit "${1:-1}"
}

# is_uint <value> — a non-empty, positive decimal integer small enough for `test` to compare.
# ⛔ EVERY operand of a gate passes through this. `[ "2263" -lt "3.5G" ]` returns 2 with
# "integer expression expected", and under `set -uo pipefail` (no -e) an `if` reads that ERROR as
# FALSE — so an unvalidated operand does not fail the gate, it SILENTLY DISABLES it and the add
# proceeds on a box at 2.21 GB. The floor is the owner's predicate; it may not be unset by a typo,
# and the length cap closes the same hole from the other side (a 20-digit value also ERRORS the
# comparison, which reads as false — `[ 12000 -lt 99999999999999999999 ]` is rc 2, not true).
is_uint() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*|0) return 1 ;; esac
  [ "${#v}" -le 15 ] || return 1
  return 0
}

# ── readings ─────────────────────────────────────────────────────────────────────────────────
# Both gates read HERE, once, so the number a decision was taken on is the number it printed.
readings() {
  [ -r "$CAPACITY_LIB" ] || { err "cannot-measure why=capacity-lib-absent path=$CAPACITY_LIB"; return 2; }
  # shellcheck source=/dev/null
  . "$CAPACITY_LIB"
  if ! is_uint "$MEM_FLOOR_MB"; then
    err "cannot-measure why=floor-unreadable value=${MEM_FLOOR_MB:-<empty>} (RUNNER_MEM_FLOOR_MB must be a positive integer MB)"; return 2
  fi
  if ! is_uint "$CORES_PER_SLOT"; then
    err "cannot-measure why=cores-per-slot-unreadable value=${CORES_PER_SLOT:-<empty>}"; return 2
  fi
  MEM_MB="$(cap_mem_free_mb 2>/dev/null)" || MEM_MB=""
  if ! is_uint "$MEM_MB"; then
    MEM_MB=""; err "cannot-measure why=mem-unreadable (cap_mem_free_mb gave no usable value)"; return 2
  fi
  NCPU="$(cap_ncpu 2>/dev/null)" || NCPU=""
  if ! is_uint "$NCPU"; then
    NCPU=""; err "cannot-measure why=ncpu-unreadable (cap_ncpu gave no usable value)"; return 2
  fi
  CEILING=$(( (NCPU + CORES_PER_SLOT - 1) / CORES_PER_SLOT ))
  [ "$CEILING" -ge 1 ] || CEILING=1
  return 0
}

# arch marker — GitHub stamps ARM64/X64 from the REGISTRATION HOST, and the gate selects on the
# matching custom marker. `uname -m` is the only statement available BEFORE the registration.
pool_label_for_host() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)          printf '%s' "$POOL_LABEL_X64" ;;
    arm64|aarch64)         printf '%s' "$POOL_LABEL_ARM64" ;;
    *) return 1 ;;
  esac
}

# ── the pool as it stands ────────────────────────────────────────────────────────────────────
# A registration is a directory carrying `.runner` — GitHub's own marker, written by config.sh. The
# listing is the FILESYSTEM, not a `gh` call: a box that cannot reach GitHub must still be able to
# say what it has registered (and GitHub's view is the thing that lies when a listener has died).
registered_dirs() {
  local d
  [ -d "$RUNNER_ROOT" ] || return 0
  for d in "$RUNNER_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d%/}/.runner" ] || continue
    printf '%s\n' "${d%/}"
  done
}
# slots — how many runners this box carries. `wc -l` (never `grep -c .`) so an empty pool is 0 with
# rc 0: an empty listing is a real reading, and a failed grep here would read as "no slots" too.
slots() { local n; n="$(registered_dirs | wc -l)"; printf '%s' "$((n))"; }

# valid_name <name> — a runner name is a path component AND goes to `config.sh --name`.
# Anything with a `/` or a leading dot escapes $RUNNER_ROOT and is invisible to `slots`/`status`, so
# an escaped registration would sit outside the ceiling that is supposed to bound it.
valid_name() { case "${1:-}" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

# listener_pid <dir> — pid of a LIVE listener for this instance dir, or empty.
# rc 0 = measured (the pid printed, or nothing when there is none). rc 2 = CANNOT MEASURE.
# ⛔ THE PROCESS TABLE IS THE EVIDENCE: the runner's argv carries its own install dir and GitHub's
# binary is always named `Runner.Listener`, so neither can go stale (unlike a pid file) and it works
# on a box with no /proc. Every match is enumerated — a first-match read is how a stale process gets
# mistaken for the live one. The `/bin/Runner.Listener` suffix is what keeps `pi-runner-1` from
# matching `pi-runner-10`. An empty table is `cannot-measure` too: `ps` never lists zero processes.
listener_pid() {
  local d="$1" phys out pid args
  phys="$(cd "$d" 2>/dev/null && pwd -P)" || phys="$d"
  if ! out="$(ps -eo pid=,args= 2>/dev/null)"; then
    err "cannot-measure why=process-table-unreadable (ps -eo pid=,args= failed)"; return 2
  fi
  [ -n "$out" ] || { err "cannot-measure why=process-table-empty (ps listed no processes)"; return 2; }
  while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    case "$args" in
      *Runner.Listener*)
        case "$args" in
          *"$phys/bin/Runner.Listener"*|*"$d/bin/Runner.Listener"*) printf '%s\n' "$pid"; return 0 ;;
        esac ;;
    esac
  done <<<"$out"
  return 0
}

# probe_listener <dir> — sets LISTENER_PID. rc 0 alive · 1 dead · 2 cannot-measure.
# The third state is the point: "no listeners" and "I could not look" must never be the same value,
# because one of them starts a second listener.
probe_listener() {
  local p
  LISTENER_PID=""
  p="$(listener_pid "$1")" || return 2
  LISTENER_PID="$p"
  [ -n "$p" ] || return 1
  return 0
}

# start_listener <dir> — start run.sh from the instance dir, then PROVE a listener appeared.
# A pid we just forked exists for one instant; a registration whose listener dies on connect (GitHub
# refusing a duplicate, a revoked token) would otherwise be reported "restarted" every pass, forever.
start_listener() {
  local d="$1" i=0 rc
  [ -x "$d/run.sh" ] || { err "cannot-act why=runner-not-installed path=$d/run.sh"; return 2; }
  ( cd "$d" && exec "$d/run.sh" ) >>"$d/listener.log" 2>&1 &
  while [ "$i" -lt $((SETTLE_S * 2)) ]; do
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) say "listener_pid=$LISTENER_PID"; return 0 ;;
      2) return 2 ;;   # cannot measure: never claim a start, never wait blind
    esac
    sleep 0.5; i=$((i + 1))
  done
  err "cannot-act why=listener-never-appeared waited=${SETTLE_S}s see=$d/listener.log"
  return 2
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────
cmd_status() {
  local dead=0 live=0 d rc
  while [ $# -gt 0 ]; do
    case "$1" in --all) shift ;; *) err "usage: status [--all]"; return 1 ;; esac
  done
  readings || return 2
  printf 'host=%s ncpu=%s ceiling=%s slots=%s mem_available=%s MB (%s GB) floor=%s MB (%s GB)\n' \
    "$(cap_host 2>/dev/null || hostname 2>/dev/null || printf box)" \
    "$NCPU" "$CEILING" "$(slots)" "$MEM_MB" "$(mb_as_gb "$MEM_MB")" \
    "$MEM_FLOOR_MB" "$(mb_as_gb "$MEM_FLOOR_MB")"
  printf '%-32s %-9s %s\n' NAME LISTENER STATE
  while read -r d; do
    [ -n "$d" ] || continue
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) printf '%-32s %-9s %s\n' "$(basename "$d")" "$LISTENER_PID" "live"; live=$((live + 1)) ;;
      1) printf '%-32s %-9s %s\n' "$(basename "$d")" "-" "DEAD"; dead=$((dead + 1)) ;;
      # An unreadable probe is NOT a dead listener: a report that says DEAD here would be a false
      # verdict a caller acts on, and rc 3 would claim it measured something.
      *) return 2 ;;
    esac
  done <<<"$(registered_dirs)"
  printf 'summary live=%s dead=%s slots=%s ceiling=%s\n' "$live" "$dead" "$(slots)" "$CEILING"
  [ "$dead" -eq 0 ] || return 3
  return 0
}

cmd_add() {
  local name="" dir token rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: add --name <runner-name> [--dry-run]"; return 1 ;;
    esac
  done
  if ! valid_name "$name"; then
    err "usage: add --name <runner-name> — a name is [A-Za-z0-9._-], must not start with '.', and must not contain '/'"; return 1
  fi
  readings || return 2

  # ⛔ MEMORY FIRST: the owner's binding constraint is memory, not cores (#2344 comment 6347825624).
  if [ "$MEM_MB" -lt "$MEM_FLOOR_MB" ]; then
    err "REFUSED add name=$name MemAvailable=$(mb_as_gb "$MEM_MB") GB is below the $(mb_as_gb "$MEM_FLOOR_MB") GB floor (read ${MEM_MB} MB, floor ${MEM_FLOOR_MB} MB) — nothing added"
    return 3
  fi
  if [ "$(slots)" -ge "$CEILING" ]; then
    err "REFUSED add name=$name slots=$(slots) ceiling=$CEILING ncpu=$NCPU cores_per_slot=$CORES_PER_SLOT MemAvailable=$(mb_as_gb "$MEM_MB") GB floor=$(mb_as_gb "$MEM_FLOOR_MB") GB — above the core-aware ceiling, nothing added"
    return 3
  fi

  # The marker the pool gate selects on. Without it the runner is registered, advertised and idle —
  # and a TYPO in the override would produce exactly that with rc 0, so the marker is required to be
  # present in whatever we are about to pass to config.sh.
  local label="${RUNNER_LABELS:-}"
  if [ -z "$label" ]; then
    label="$(pool_label_for_host)" || label=""
    if [ -z "$label" ]; then
      err "cannot-measure why=arch-unknown uname_m=$(uname -m 2>/dev/null || printf '?') — set RUNNER_LABELS to the pool marker ($POOL_LABEL_X64 or $POOL_LABEL_ARM64)"; return 2
    fi
  fi
  case ",$label," in
    *",$POOL_LABEL_X64,"*|*",$POOL_LABEL_ARM64,"*) ;;
    *) err "cannot-measure why=label-unknown value=$label — a runner without $POOL_LABEL_X64/$POOL_LABEL_ARM64 matches no job and is invisible to ci_runner_gate.sh"; return 2 ;;
  esac
  say "reading: MemAvailable=$(mb_as_gb "$MEM_MB") GB (${MEM_MB} MB) floor=$(mb_as_gb "$MEM_FLOOR_MB") GB ncpu=$NCPU ceiling=$CEILING slots=$(slots) labels=$label"

  dir="$RUNNER_ROOT/$name"
  if [ -f "$dir/.runner" ]; then
    err "name-unavailable name=$name already registered at $dir — use restart"; return 4
  fi
  # A directory with no `.runner` is a FAILED earlier config (ours are removed on failure) or another
  # tool's. It is not a free slot and it is not ours to delete.
  if [ -d "$dir" ]; then
    err "name-unavailable name=$name dir=$dir exists without a .runner registration — clear it or pick another name"; return 4
  fi
  [ -x "$RUNNER_TEMPLATE/config.sh" ] || {
    err "cannot-act why=runner-template-absent path=$RUNNER_TEMPLATE/config.sh (one complete runner install to copy)"; return 2
  }
  if [ "$DRY" = 1 ]; then say "dry-run: would copy $RUNNER_TEMPLATE to $dir, register name=$name and start its listener"; return 0; fi

  token="${RUNNER_TOKEN:-}"
  if [ -z "$token" ]; then
    # A registration token is single-use and expires in ~1h, so it is minted per add and never stored.
    token="$("$GH_CMD" api -X POST "repos/$POOL_REPO/actions/runners/registration-token" --jq .token 2>/dev/null)" || token=""
  fi
  case "$token" in
    ''|null|*[[:space:]]*) err "cannot-act why=no-registration-token repo=$POOL_REPO (set RUNNER_TOKEN, or authenticate $GH_CMD)"; return 2 ;;
  esac

  # ONE COMPLETE INSTALL PER INSTANCE (see the header): config.sh writes `.runner` beside ITSELF.
  cp -a "$RUNNER_TEMPLATE" "$dir" || { err "cannot-act why=template-copy-failed from=$RUNNER_TEMPLATE to=$dir"; return 2; }
  local -a args=(--unattended --name "$name" --work "$dir/_work" --labels "$label" --token "$token")
  if ! "$dir/config.sh" "${args[@]}" >"$dir/config.log" 2>&1; then
    # Nothing valid exists yet, and a full runner install left behind is invisible to `slots`, never
    # bounded by the ceiling, and would make the next pass mint another name — so it goes.
    rm -rf "$dir"
    err "cannot-act why=config-failed see=$RUNNER_ROOT/$name/config.log (the installation was removed)"; return 2
  fi
  # config.sh's own `.runner` marker is the proof the registration happened — never the exit code
  # alone (a config that "succeeded" without writing `.runner` has registered nothing).
  if [ ! -f "$dir/.runner" ]; then
    rm -rf "$dir"
    err "cannot-act why=no-registration-marker dir=$dir (the installation was removed)"; return 2
  fi
  if ! start_listener "$dir"; then
    # The registration EXISTS now. Saying "nothing changed" here would be false, and the retry is
    # refused by the `.runner` check above — so name the state and the way back.
    err "registered=1 listener=dead name=$name dir=$dir — the registration is in place; run: $0 restart --name $name"
    return 2
  fi
  say "added name=$name dir=$dir listener_pid=$(listener_pid "$dir")"
  return 0
}

cmd_restart() {
  local name="" dir rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: restart --name <runner-name> [--dry-run]"; return 1 ;;
    esac
  done
  if ! valid_name "$name"; then err "usage: restart --name <runner-name> — a name is [A-Za-z0-9._-] and must not contain '/'"; return 1; fi
  dir="$RUNNER_ROOT/$name"
  if [ ! -f "$dir/.runner" ]; then
    err "REFUSED restart name=$name no registration at $dir (add it first) — nothing changed"; return 3
  fi
  # ⛔ NO MEMORY FLOOR ON THIS PATH, DELIBERATELY (#2373). The floor gates ADDING a new runner. A
  # dead listener for an EXISTING registration costs ~200 MB to bring back and is capacity the box has
  # already paid for; refusing it on a low-memory box would leave the slot registered, advertised and
  # idle — the worst of the three states. The owner's floor sentence names ADDING, not restarting.
  rc=0; probe_listener "$dir" || rc=$?
  case "$rc" in
    0) say "live name=$name pid=$LISTENER_PID — not touched"; return 0 ;;
    2) return 2 ;;   # cannot measure: START NOTHING (a blind start is how a listener is doubled)
  esac
  if [ "$DRY" = 1 ]; then say "dry-run: would start the listener for name=$name"; return 0; fi
  start_listener "$dir" || return 2
  say "restarted name=$name pid=$(listener_pid "$dir")"
  return 0
}

cmd_reconcile() {
  local d restarted=0 added=0 refused=0 cannot=0 dead=0 skipped=0 n=1 rc budget scan=0
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) DRY=1; shift ;; *) err "usage: reconcile [--dry-run]"; return 1 ;; esac
  done
  readings || return 2
  budget=$((CEILING * 2 + 4))   # belt: the ceiling bounds the adds; this bounds a bug in it

  # (a) every EXISTING registration must have a live listener. This is the half the fleet had no
  #     automation for at all: a dead listener on a live registration reads OFFLINE to GitHub while
  #     the registration still occupies the slot.
  while read -r d; do
    [ -n "$d" ] || continue
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) continue ;;                       # live: not touched
      2) cannot=$((cannot + 1)); continue ;;   # cannot measure: start nothing
    esac
    dead=$((dead + 1))
    if [ "$DRY" = 1 ]; then say "dry-run: would restart $(basename "$d")"; continue; fi
    rc=0
    "$0" restart --name "$(basename "$d")" || rc=$?
    case "$rc" in
      0) restarted=$((restarted + 1)) ;;
      3) refused=$((refused + 1)) ;;
      # ⛔ A cannot-act is NOT a refusal: a scheduler branching on the documented codes must not see
      # a pass that could not act reported as success.
      *) cannot=$((cannot + 1)) ;;
    esac
  done <<<"$(registered_dirs)"

  # (b)+(c) add only ABOVE the floor and BELOW the ceiling. A gate verdict (rc 3) ENDS the pass — it
  #        is a measurement of this box, not a per-name accident — while an UNAVAILABLE name (rc 4)
  #        is a per-name accident: skip to the next name, because one stale directory must not cost
  #        the box the capacity it is entitled to.
  while [ "$budget" -gt 0 ]; do
    budget=$((budget - 1))
    [ "$(slots)" -lt "$CEILING" ] || { say "ceiling reached slots=$(slots) ceiling=$CEILING ncpu=$NCPU"; break; }
    scan=0
    while [ -e "$RUNNER_ROOT/$POOL_PREFIX-$n" ]; do
      n=$((n + 1)); scan=$((scan + 1))
      if [ "$scan" -ge 200 ]; then
        err "cannot-act why=no-free-runner-name scanned=200 prefix=$POOL_PREFIX-$n"
        cannot=$((cannot + 1)); break 2
      fi
    done
    if [ "$DRY" = 1 ]; then say "dry-run: would add $POOL_PREFIX-$n"; break; fi
    rc=0
    "$0" add --name "$POOL_PREFIX-$n" || rc=$?
    case "$rc" in
      0) added=$((added + 1)); n=$((n + 1)) ;;
      4) skipped=$((skipped + 1)); n=$((n + 1)) ;;
      3) refused=$((refused + 1)); break ;;
      *) cannot=$((cannot + 1)); break ;;
    esac
  done

  printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s refused=%s cannot=%s slots=%s ceiling=%s mem_available=%s MB floor=%s MB dry_run=%s\n' \
    "$dead" "$restarted" "$added" "$skipped" "$refused" "$cannot" "$(slots)" "$CEILING" "$MEM_MB" "$MEM_FLOOR_MB" "$DRY"
  [ "$cannot" -eq 0 ] || return 2
  return 0
}

main() {
  local verb="${1:-}"; shift 2>/dev/null || true
  if [ -z "${POOL_PREFIX:-}" ]; then
    # Runner names are unique PER REPO, so an unqualified prefix means two boxes' passes mint the
    # same names and each one's registration replaces the other's. The measured names were
    # box-qualified (`pi-runner-cell4-x64-2`) for exactly this reason.
    local h; h="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || h=""
    case "$h" in ''|*[!A-Za-z0-9._-]*) h="box" ;; esac
    POOL_PREFIX="pi-runner-$h"
  fi
  case "$verb" in
    status)    cmd_status "$@" ;;
    add)       cmd_add "$@" ;;
    restart)   cmd_restart "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    ''|-h|--help|help) usage 0 ;;
    *) err "ci_runner_pool: unknown command '$verb' (try: status|add|restart|reconcile)"; return 1 ;;
  esac
}

main "$@"
