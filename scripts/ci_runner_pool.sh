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
#                                                 (--all is the SAME view: the default already lists
#                                                  every runner on THIS box, so the flag widens
#                                                  nothing. The cross-box view is capacity.sh / the
#                                                  fleet inventory, which this script does not
#                                                  duplicate.)
#   ci_runner_pool.sh add      --name <name> [--dry-run]
#   ci_runner_pool.sh restart  --name <name> [--dry-run]
#   ci_runner_pool.sh reconcile [--dry-run]        # the pass: restart dead listeners, add to ceiling
#
# ENV: RUNNER_ROOT (one complete install per runner; default /tmp/actions-runner, the measured
#        layout) · RUNNER_TEMPLATE (pristine unpacked release to copy; default $RUNNER_ROOT/_template)
#      RUNNER_MEM_FLOOR_MB (3584 = the 3.5 GB the gate refused at) · RUNNER_CORES_PER_SLOT (3)
#      RUNNER_POOL_REPO (owner/name — BOTH the registration-token's scope and the URL the runner is
#        registered at, so it must be bare `owner/name`; a URL form is refused) · RUNNER_TOKEN (skip gh)
#      RUNNER_LABELS (overrides the derived self-hosted-<arch> marker; must still contain it)
#      POOL_PREFIX (default pi-runner-<host>) · RUNNER_START_SETTLE_S (5)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act — nothing changed, EXCEPT a registration
#       the message names explicitly (a `.runner` written before its listener failed) · 3 REFUSED,
#       nothing changed — `add`: a gate verdict (a floor/ceiling refusal); `restart`: that name has no
#       registration under $RUNNER_ROOT (NOT a capacity verdict — it needs `add`); `status`: the report
#       it produced contains a DEAD listener (see below) · 4 name not available (that name is taken;
#       nothing changed, try another name) · 5 this name could not be REGISTERED (config.sh failed, or
#       it left no `.runner`): a per-name failure, so the pass tries the next name rather than ending
#       ⛔ 4 IS CHECKED BEFORE 3: a name that is already taken reports 4 even on a box that is also
#       at/below a gate, because the name condition is a fact about the request, not the box.
#
# `status` exits 3 when it produced a report in which at least one listener is DEAD — a report is
# still a report, but a dead listener is a fact a caller must be able to branch on without parsing
# the table. It exits 2 (never 0, never 3) when it could not measure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPACITY_LIB="${CAPACITY_LIB:-$SELF_DIR/orchestrator-harness/capacity.sh}"
# ⛔ RE-INVOKE THROUGH AN ABSOLUTE PATH, NEVER `$0`: `bash ci_runner_pool.sh reconcile` run from the
# script's own directory leaves `$0` as a bare filename that is not on PATH, so every child dispatch
# fails `command not found` — reconcile then reports a false `cannot-act` on a healthy box and no dead
# listener is ever restarted.
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"

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
MEM_MB=""; NCPU=""; CEILING=""; LISTENER_PID=""; SLOTS=""

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
  # ⛔ `0?*` — a LEADING ZERO is OCTAL to bash's arithmetic, and `08`/`09` are fatal there: the
  # arithmetic error kills the shell outright (rc 1, the documented USAGE code) mid-action, so a
  # "validated" operand could still die inside `$((…))` with no verdict printed. `010` is worse than
  # fatal: it is accepted, and means EIGHT where every other comparison reads it as ten.
  case "$v" in ''|*[!0-9]*|0|0?*) return 1 ;; esac
  [ "${#v}" -le 15 ] || return 1
  return 0
}

# validate_operands — the env operands that are not READINGS but still gate an action.
# ⛔ `RUNNER_START_SETTLE_S` was the one operand that reached arithmetic unvalidated: `5s` made
# `$((SETTLE_S * 2))` a bash ERROR (rc 1, "value too great for base") on a start that had already
# succeeded, and `0` skipped the settle loop entirely and reported `listener-never-appeared` for a
# listener that was running. Both are a one-character typo producing a wrong verdict.
validate_operands() {
  if ! is_uint "$SETTLE_S"; then
    err "cannot-measure why=settle-unreadable value=${SETTLE_S:-<empty>} (RUNNER_START_SETTLE_S must be a positive integer of seconds)"; return 2
  fi
  # ⛔ THE REPO IS AN OPERAND TOO, and it now has TWO consumers: the `gh` token path
  # (`repos/$POOL_REPO/...`) and the registration URL (`https://github.com/$POOL_REPO`). A URL-form or
  # multi-slash value produces `https://github.com/https://github.com/o/r`; config.sh then fails at
  # parse time per NAME, so `add` returns rc 5 for every name and `reconcile` grinds through its whole
  # attempt budget before `cannot-act` — the only evidence a per-name `.config-<name>.log`.
  case "$POOL_REPO" in
    ''|/*|*/|*/*/*|*://*) err "cannot-measure why=repo-unreadable value=${POOL_REPO:-<empty>} (RUNNER_POOL_REPO must be owner/name — it is both the token scope and the registration URL)"; return 2 ;;
    */*) : ;;
    *) err "cannot-measure why=repo-unreadable value=$POOL_REPO (RUNNER_POOL_REPO must be owner/name)"; return 2 ;;
  esac
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
  local d tpl tpl_lit
  # ⛔ AN ABSENT ROOT IS AN EMPTY POOL (a fresh box); a root that EXISTS but is not a DIRECTORY is a
  # misconfiguration, and reading it as "0 slots, rc 0" is the same false empty-pool reading the guard
  # below closes.
  [ -e "$RUNNER_ROOT" ] || [ -L "$RUNNER_ROOT" ] || return 0
  if [ ! -d "$RUNNER_ROOT" ]; then
    err "cannot-measure why=runner-root-not-a-directory path=$RUNNER_ROOT"; return 2
  fi
  # ⛔ "THERE IS NO POOL" AND "I CANNOT READ THE POOL" ARE DIFFERENT ANSWERS, and only the first one is
  # 0. The glob below expands to NOTHING on a root that exists but cannot be listed (mode 300, an ACL
  # or SELinux denial, a transient readdir error on a mounted root), so the pool read as EMPTY — and
  # an empty pool never trips the ceiling: `add` added on a box already at its bound and `reconcile`
  # spent its whole attempt budget minting listeners on a box sized for a third as many (measured: 32
  # listeners on a 3-slot box, rc 0, cannot=0). This is the same class as the unreadable process
  # table — the one input whose absence would produce an ACTION instead of a refusal.
  # ⛔ READ **AND** SEARCH (`r`+`x`). `-r` alone is not enough for a listing: `readdir` needs `r`, but
  # every `[ -d "$d" ]`/`[ -e "$d/.runner" ]` on the entries needs `x` — so a mode-444 root SUCCEEDED
  # `ls -A` while the glob matched nothing, and the pool read empty with rc 0 (measured).
  if [ ! -r "$RUNNER_ROOT" ] || [ ! -x "$RUNNER_ROOT" ] || ! ls -A "$RUNNER_ROOT" >/dev/null 2>&1; then
    err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT"; return 2
  fi
  # ⛔ THE TEMPLATE EXCLUSION MUST NOT DEPEND ON THE TEMPLATE RESOLVING. `$tpl` used to be the only
  # bound, so an unresolvable RUNNER_TEMPLATE left it EMPTY and the `[ -z "$tpl" ] || …` guard
  # evaluated TRUE — the pristine release was then emitted as a runner, `reconcile` started a
  # listener INSIDE it (which every later `add` copies into its instance, `.runner` and all, voiding
  # the proof-of-registration check), and `slots` counted it against the ceiling. So BOTH the
  # resolved and the literal path are excluded, plus the documented default `$RUNNER_ROOT/_template`
  # by name — the layout the shipped default uses while a release is still unpacking.
  tpl="$(cd "$RUNNER_TEMPLATE" 2>/dev/null && pwd -P)" || tpl=""
  tpl_lit="${RUNNER_TEMPLATE%/}"
  # ⛔ DOT DIRECTORIES ARE ENUMERATED: `"$RUNNER_ROOT"/*/` never matches a name starting with `.`,
  # so a hand-provisioned `.foo` registration was invisible to `status` and to `slots` (never
  # bounded by the ceiling) while `restart` happily started it — the same registration read two
  # different ways by two verbs.
  for d in "$RUNNER_ROOT"/*/ "$RUNNER_ROOT"/.[!.]*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    # ⛔ A DIR WE CANNOT INSPECT IS COUNTED, NOT SKIPPED. `-f .runner` is FALSE for a registration
    # we cannot read, so a `chmod 000` instance vanished from `slots`: the box looked EMPTIER than
    # it is and the core-aware ceiling (the owner's sizing bound) under-counted — the OVER-add
    # direction. Counting it keeps the ceiling conservative, and the probe downstream then reports
    # cannot-measure instead of inventing a number.
    # ⛔ READ **AND** SEARCH: a dir with `r` but not `x` (mode 444) passes `-r` and then fails every
    # `-d`/`-e` on its contents, so it was DROPPED from the listing — the box looked emptier than it is
    # and the ceiling under-counted, which is the OVER-add direction this arm exists to prevent.
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then printf '%s\n' "$d"; continue; fi
    [ -e "$d/.runner" ] || [ -L "$d/.runner" ] || continue
    # The pristine template is never a runner, even if something wrote a `.runner` into it.
    [ "$d" != "${RUNNER_ROOT%/}/_template" ] || continue
    [ -z "$tpl_lit" ] || [ "$d" != "$tpl_lit" ] || continue
    [ -z "$tpl" ] || [ "$(cd "$d" && pwd -P)" != "$tpl" ] || continue
    printf '%s\n' "$d"
  done
}
# count_dirs <listing> — 0 for an EMPTY listing (`wc -l` over an empty string is 1, not 0).
count_dirs() { local s="${1:-}"; [ -n "$s" ] || { printf '0'; return 0; }; printf '%s\n' "$s" | wc -l | tr -d ' '; }

# slots — refresh $SLOTS from the pool listing. rc 2 = CANNOT MEASURE, and EVERY consumer must refuse:
# `n="$(registered_dirs | wc -l)"` (the old shape) turned "could not read the pool" into the integer 0,
# which is the unsafe direction on both gates (0 never reaches the ceiling).
slots() {
  local out
  out="$(registered_dirs)" || return 2   # pipefail is set; the listing error is not swallowed
  SLOTS="$(count_dirs "$out")"
  return 0
}

# valid_name <name> — a runner name is a path component AND goes to `config.sh --name`.
# Anything with a `/` or a leading dot escapes $RUNNER_ROOT and is invisible to `slots`/`status`, so
# an escaped registration would sit outside the ceiling that is supposed to bound it. A leading `-` is
# refused because `--name -x` would be read as a FLAG by config.sh (and `--name --dry-run` would
# otherwise register a runner named `--dry-run` while leaving DRY at 0 — a preview that installs).
valid_name() { case "${1:-}" in ''|.*|-*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

# take_name_value <verb> <argc> <value> — the `--name` arm's own contract.
# ⛔ `shift 2` with ONE argument left FAILS WITHOUT DECREMENTING `$#`, and under `set -uo pipefail`
# (no `-e`) nothing stops it: `add --name` looped forever instead of returning the documented rc 1.
take_name_value() {
  local verb="$1" argc="$2" val="${3:-}"
  if [ "$argc" -lt 2 ]; then err "usage: $verb --name <runner-name> [--dry-run]"; return 1; fi
  case "$val" in
    -*) err "usage: $verb --name <runner-name> — the name must not start with '-'"; return 1 ;;
  esac
  return 0
}

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
  # ⛔ `-ww`, NOT A BARE `ps -eo`: procps TRUNCATES `args` to `$COLUMNS` (measured: with
  # `COLUMNS=80` every line came back exactly 80 chars, the argv cut mid-`Runner.Li`, while
  # `ps -ww` returned the full line under the same COLUMNS), and BSD/macOS `ps` truncates `args`
  # unless `-w` is given — and this file explicitly claims to work on a box with no /proc.
  # A truncated argv makes the suffix match below MISS a LIVE listener, which is not a cosmetic
  # reporting bug: `restart`/`reconcile` then start a SECOND listener for one registration (the
  # double-start the process-table design exists to prevent) and `status` exits 3 (DEAD) on a
  # healthy box. Double `-w` means unlimited width on both GNU and BSD.
  if ! out="$(ps -ww -eo pid=,args= 2>/dev/null)"; then
    err "cannot-measure why=process-table-unreadable (ps -ww -eo pid=,args= failed)"; return 2
  fi
  [ -n "$out" ] || { err "cannot-measure why=process-table-empty (ps listed no processes)"; return 2; }
  while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    case "$args" in
      *Runner.Listener*)
        # ⛔ ANCHOR ON THE INVOCATION, NOT ON THE PATH. A live runner's measured argv is
        # `<dir>/bin/Runner.Listener run --startuptype service`, so requiring the ` run` that must
        # follow the binary is what separates a LISTENER from any process that merely NAMES the file
        # (`tail -f <dir>/bin/Runner.Listener`, an editor, a shell holding the path as an argument).
        # A bare path-substring match is this file's own named defect in disguise: a DEAD
        # registration then reads LIVE forever, so `restart`/`reconcile` skip it and the slot stays
        # idle while the report says healthy.
        case "$args" in
          *"$phys/bin/Runner.Listener run"*|*"$d/bin/Runner.Listener run"*) printf '%s\n' "$pid"; return 0 ;;
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
  # ⛔ AN INSTANCE DIR WE CANNOT INSPECT IS cannot-measure, NOT DEAD. `listener_pid` cannot resolve its
  # physical path, so a `chmod 000` registration used to report DEAD (rc 3) and `restart` refused it
  # "no registration at … (add it first)" — both asserting a measured fact the tool never measured, on
  # a registration that EXISTS. It is COUNTED as a slot (registered_dirs), so the two halves agree:
  # counted against the ceiling, and reported unreadable rather than dead.
  [ -r "$1" ] && [ -x "$1" ] || { err "cannot-measure why=instance-unreadable path=$1"; return 2; }
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
  local dead=0 live=0 d rc dirs
  # `--all` is ACCEPTED AND CHANGES NOTHING, DELIBERATELY: #2373 names a `status --all`, and the
  # default view already IS every runner on this box, so there is no narrower form for the flag to
  # widen. It is documented as such (USAGE) rather than left as a flag a reader assumes reveals more
  # than it does — and rather than dropped, because the issue's clause names it.
  while [ $# -gt 0 ]; do
    case "$1" in --all) shift ;; *) err "usage: status [--all]"; return 1 ;; esac
  done
  readings || return 2
  # ONE listing, one count: `slots` (listing #1) and `dirs` (listing #2) could disagree while
  # registrations appeared, and the report then printed more DEAD rows than `slots=` (measured:
  # `live=0 dead=30 slots=17`). The rows and the count now come from the SAME read.
  dirs="$(registered_dirs)" || return 2
  SLOTS="$(count_dirs "$dirs")"
  printf 'host=%s ncpu=%s ceiling=%s slots=%s mem_available=%s MB (%s GB) floor=%s MB (%s GB)\n' \
    "$(cap_host 2>/dev/null || hostname 2>/dev/null || printf box)" \
    "$NCPU" "$CEILING" "$SLOTS" "$MEM_MB" "$(mb_as_gb "$MEM_MB")" \
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
  done <<<"$dirs"
  printf 'summary live=%s dead=%s slots=%s ceiling=%s\n' "$live" "$dead" "$SLOTS" "$CEILING"
  [ "$dead" -eq 0 ] || return 3
  return 0
}

cmd_add() {
  local name="" dir token rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) take_name_value add "$#" "${2:-}" || return 1; name="${2:-}"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: add --name <runner-name> [--dry-run]"; return 1 ;;
    esac
  done
  if ! valid_name "$name"; then
    err "usage: add --name <runner-name> — a name is [A-Za-z0-9._-], must not start with '.', and must not contain '/'"; return 1
  fi
  # ⛔ THE NAME'S OWN VERDICT COMES BEFORE THE BOX'S. A name availability check placed AFTER the
  # floor/ceiling gates returned rc 3 on a box at its ceiling even when the name was already
  # registered — so a caller branching on the documented "4 = that name is taken, try another"
  # could never see the name condition it was asking about. These checks read no capacity, so
  # running them first costs nothing and costs the caller nothing.
  dir="$RUNNER_ROOT/$name"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if [ -e "$dir/.runner" ] || [ -L "$dir/.runner" ]; then
      err "name-unavailable name=$name already registered at $dir — use restart"; return 4
    fi
    # ⛔ `-e`, NOT `-d`. A caller-supplied path may be a FILE (an operator's notes, a symlink to a
    # shared install), and a `-d` test let it through to `cp -aL`; the copy then fails and the
    # cleanup below does `rm -rf "$dir"` — DELETING the operator's file to tidy up after our own
    # failure. Anything already at the target path is refused, and its message does not claim it
    # is a directory.
    err "name-unavailable name=$name path=$dir already exists (a file, a symlink, or a directory without a .runner registration) — clear it or pick another name"; return 4
  fi
  readings || return 2

  # ⛔ MEMORY FIRST: the owner's binding constraint is memory, not cores (#2344 comment 6347825624).
  if [ "$MEM_MB" -lt "$MEM_FLOOR_MB" ]; then
    err "REFUSED add name=$name MemAvailable=$(mb_as_gb "$MEM_MB") GB is below the $(mb_as_gb "$MEM_FLOOR_MB") GB floor (read ${MEM_MB} MB, floor ${MEM_FLOOR_MB} MB) — nothing added"
    return 3
  fi
  slots || return 2
  if [ "$SLOTS" -ge "$CEILING" ]; then
    err "REFUSED add name=$name slots=$SLOTS ceiling=$CEILING ncpu=$NCPU cores_per_slot=$CORES_PER_SLOT MemAvailable=$(mb_as_gb "$MEM_MB") GB floor=$(mb_as_gb "$MEM_FLOOR_MB") GB — above the core-aware ceiling, nothing added"
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
  say "reading: MemAvailable=$(mb_as_gb "$MEM_MB") GB (${MEM_MB} MB) floor=$(mb_as_gb "$MEM_FLOOR_MB") GB ncpu=$NCPU ceiling=$CEILING slots=$SLOTS labels=$label"

  [ -x "$RUNNER_TEMPLATE/config.sh" ] || {
    err "cannot-act why=runner-template-absent path=$RUNNER_TEMPLATE/config.sh (one complete runner install to copy)"; return 2
  }
  if [ "$DRY" = 1 ]; then
    # The registration token is the add's last precondition and is minted AFTER this return (a dry run
    # must not POST). So the preview requires a token SOURCE — and says so — rather than announcing an
    # add the pass cannot make. A `gh` that is present but unauthenticated is the one residual a
    # side-effect-free probe cannot see; it is named here rather than papered over.
    if [ -z "${RUNNER_TOKEN:-}" ] && ! command -v "$GH_CMD" >/dev/null 2>&1; then
      err "cannot-act why=no-registration-token repo=$POOL_REPO (set RUNNER_TOKEN, or put $GH_CMD on PATH) — a preview cannot mint one"; return 2
    fi
    say "dry-run: would copy $RUNNER_TEMPLATE to $dir, register name=$name and start its listener"; return 0
  fi

  token="${RUNNER_TOKEN:-}"
  if [ -z "$token" ]; then
    # A registration token is single-use and expires in ~1h, so it is minted per add and never stored.
    token="$("$GH_CMD" api -X POST "repos/$POOL_REPO/actions/runners/registration-token" --jq .token 2>/dev/null)" || token=""
  fi
  case "$token" in
    ''|null|*[[:space:]]*) err "cannot-act why=no-registration-token repo=$POOL_REPO (set RUNNER_TOKEN, or authenticate $GH_CMD)"; return 2 ;;
  esac

  # ONE COMPLETE INSTALL PER INSTANCE (see the header): config.sh writes `.runner` beside ITSELF.
  # ⛔ THE CLAIM IS ATOMIC. `mkdir` is the only filesystem verb here that FAILS when another pass has
  # taken the name; the `[ -e "$dir" ]` check above is check-then-act, and `cp -aL <template> <existing
  # dir>` NESTS into it rather than failing — so two overlapping invocations (a hand `add` during a
  # scheduled `reconcile`, two operators) would both configure ONE instance: a second registration
  # token spent, `.runner` overwritten, the GitHub-side registration orphaned, and both passes
  # reporting an add neither uniquely made (measured: two simultaneous passes both reported
  # `added name=pi-runner-…-1`).
  if ! mkdir "$dir" 2>/dev/null; then
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      err "name-unavailable name=$name path=$dir appeared while this add ran (another pass took it) — use restart"; return 4
    fi
    err "cannot-act why=template-copy-failed from=$RUNNER_TEMPLATE to=$dir (the instance dir could not be created)"; return 2
  fi
  # ⛔ THE CEILING IS RE-READ AFTER THE NAME IS CLAIMED. The gate above is a SNAPSHOT taken before the
  # token mint, so two passes adding DIFFERENT names both clear it and the box ends ABOVE the owner's
  # core-aware bound with both rc 0 (measured: 4 registrations on a 3-slot box). `mkdir` is the
  # serialisation point: a pass that lost the race hears it here and gives the directory back.
  # ⚠️ Residual: two passes can still both read `slots` before either writes its `.runner`; closing that
  # completely needs a pool-level lock, which is a declared follow-up (a lock that survives a killed
  # pass is machinery of its own).
  if ! slots; then
    rm -rf "$dir"
    err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT (the ceiling could not be re-read after claiming $name; the claim was released)"; return 2
  fi
  if [ "$SLOTS" -ge "$CEILING" ]; then
    rm -rf "$dir"
    err "REFUSED add name=$name slots=$SLOTS ceiling=$CEILING — another pass took the free slot while this add ran; nothing added"
    return 3
  fi
  # ⛔ `-L`, NOT a bare `-a`: `cp -a` is `--no-dereference`, so a SYMLINKED template would produce a
  # symlinked instance — every alias then shares ONE install and one listener, `listener_pid` reads
  # them all LIVE through the shared physical path (so a dead one is never restarted), the template
  # is mutated by the first config, and each alias eats a slot it does not own. Dereferenced, the copy
  # is a real install or it is nothing — so the install is checked, not assumed.
  if ! cp -aL "$RUNNER_TEMPLATE/." "$dir/" 2>/dev/null; then
    rm -rf "$dir"   # a partial install is invisible to `slots` and would block this name forever
    err "cannot-act why=template-copy-failed from=$RUNNER_TEMPLATE to=$dir (the partial copy was removed)"; return 2
  fi
  if [ -L "$dir" ] || [ ! -f "$dir/config.sh" ]; then
    rm -rf "$dir"
    err "cannot-act why=template-not-copied template=$RUNNER_TEMPLATE ($dir has no config.sh — the copy was removed)"; return 2
  fi
  # ⛔ THE LOG LIVES OUTSIDE THE INSTANCE DIR, because the instance dir is REMOVED on failure and
  # config.sh's stderr is the only diagnostic for the commonest real failures (name taken on GitHub,
  # token already used/expired, disk full). A `see=` path pointing into a directory we just deleted
  # is worse than no pointer at all.
  local cfglog="$RUNNER_ROOT/.config-$name.log"
  # ⛔ `--url` IS REQUIRED, NOT OPTIONAL. GitHub's own `config.sh --help` says "Repository to add the
  # runner to. Required if unattended", `CommandSettings.GetUrl()` passes an EMPTY default, and
  # PromptManager's unattended arm THROWS on an empty non-optional value ("Invalid configuration
  # provided for --url. Terminating unattended configuration.") instead of falling back to the
  # token's repo. Without it every real add failed at config and reported it as a NAME problem
  # (rc 5, "a token it consumed may have registered the name") — and the suite stayed green because
  # its config stub ignored argv. Derived from POOL_REPO in ONE place so the two cannot drift.
  local pool_url="https://github.com/$POOL_REPO"
  local -a args=(--unattended --url "$pool_url" --name "$name" --work "$dir/_work" --labels "$label" --token "$token")
  if ! "$dir/config.sh" "${args[@]}" >"$cfglog" 2>&1; then
    # Nothing valid exists yet, and a full runner install left behind is invisible to `slots`, never
    # bounded by the ceiling, and would make the next pass mint another name — so it goes.
    rm -rf "$dir"
    # ⛔ rc 5, NOT rc 2: a config failure is about THIS NAME (GitHub already holds it, the token was
    # spent, this dir's permissions), while the gates an rc 2 reports are about the BOX. Ending the
    # pass here is how a box that rebooted `/tmp` — every local `.runner` gone, every name still taken
    # on GitHub — could never re-provision the pool this pass exists to recover.
    err "name-failed why=config-failed see=$cfglog (the installation was removed; GitHub-side state is unknown — a token it consumed may have registered the name); trying the next name"; return 5
  fi
  # config.sh's own `.runner` marker is the proof the registration happened — never the exit code
  # alone (a config that "succeeded" without writing `.runner` has registered nothing).
  if [ ! -f "$dir/.runner" ]; then
    rm -rf "$dir"
    err "name-failed why=no-registration-marker dir=$dir see=$cfglog (the installation was removed); trying the next name"; return 5
  fi
  rm -f "$cfglog"   # the marker proves the registration; a successful log is no longer news
  if ! start_listener "$dir"; then
    # The registration EXISTS now. Saying "nothing changed" here would be false, and the retry is
    # refused by the `.runner` check above — so name the state and the way back.
    err "registered=1 listener=dead name=$name dir=$dir — the registration is in place; run: $SELF restart --name $name"
    return 2
  fi
  say "added name=$name dir=$dir listener_pid=$(listener_pid "$dir")"
  return 0
}

cmd_restart() {
  local name="" dir rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) take_name_value restart "$#" "${2:-}" || return 1; name="${2:-}"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: restart --name <runner-name> [--dry-run]"; return 1 ;;
    esac
  done
  # ⛔ `restart` ADDRESSES something that already exists, so it must not impose `add`'s creation
  # rules: the migration population this tool was written for is hand-provisioned and its names were
  # never validated (`bad name` is a legal directory). Rejecting those would leave that listener dead
  # forever AND make every reconcile pass exit 2 on an otherwise healthy box. Only path ESCAPES are
  # refused here.
  case "$name" in ''|.|..|-*|*/*) err "usage: restart --name <runner-name> — a name must not be empty, start with '-', be '.'/'..', or contain '/'"; return 1 ;; esac
  dir="$RUNNER_ROOT/$name"
  # ⛔ JUDGE THE ROOT BEFORE CONCLUDING "NO REGISTRATION". Every test on `$RUNNER_ROOT/$name` needs `x`
  # on the ROOT (traversal — NOT `r`: `restart` addresses a KNOWN name and never lists the pool, so a
  # mode-111 root is legitimate here and must not be refused). A non-searchable root made this verb
  # report a registration that EXISTS as missing and send the operator to `add` it (which then refuses
  # rc 4 on the existing directory) — the same false verdict `status` refuses to print. An ABSENT root
  # still falls through to rc 3 "no registration"; a root that is not a directory is named as such.
  if [ -e "$RUNNER_ROOT" ] || [ -L "$RUNNER_ROOT" ]; then
    if [ ! -d "$RUNNER_ROOT" ]; then
      err "cannot-measure why=runner-root-not-a-directory path=$RUNNER_ROOT"; return 2
    fi
    if [ ! -x "$RUNNER_ROOT" ]; then
      err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT"; return 2
    fi
  fi
  # ⛔ AN UNREADABLE INSTANCE IS cannot-measure, NOT "no registration": `-f .runner` is FALSE for a
  # registration we cannot reach, and the message would send the operator to `add` a runner that is
  # already registered (the same false verdict `status` must never print). Traversal is `x`; `restart`
  # never lists the instance, so `r` is not required here either.
  if [ ! -x "$dir" ]; then
    if [ -d "$dir" ]; then
      err "cannot-measure why=instance-unreadable path=$dir"; return 2
    fi
    err "REFUSED restart name=$name no registration at $dir (add it first) — nothing changed"; return 3
  fi
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
  # ⛔ THE START'S OWN PRECONDITION IS CHECKED BEFORE THE DRY RETURN, so a preview cannot announce a
  # start the real pass refuses. `start_listener` re-checks it (defence in depth), but a check that
  # only lives downstream of the `--dry-run` return is a preview that lies.
  [ -x "$dir/run.sh" ] || { err "cannot-act why=runner-not-installed path=$dir/run.sh"; return 2; }
  if [ "$DRY" = 1 ]; then say "dry-run: would start the listener for name=$name"; return 0; fi
  start_listener "$dir" || return 2
  say "restarted name=$name pid=$(listener_pid "$dir")"
  return 0
}

cmd_reconcile() {
  local d restarted=0 added=0 refused=0 cannot=0 dead=0 skipped=0 failed=0 n=1 rc budget scan=0 dry_adds=0
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) DRY=1; shift ;; *) err "usage: reconcile [--dry-run]"; return 1 ;; esac
  done

  # (a) every EXISTING registration must have a live listener. This is the half the fleet had no
  #     automation for at all: a dead listener on a live registration reads OFFLINE to GitHub while
  #     the registration still occupies the slot.
  # ⛔ A CHECKED ENUMERATION, like `cmd_status`: a here-string DISCARDS the producer's status, so an
  # unlistable root made this arm silently do nothing and the summary print `dead=0 restarted=0` — a
  # "nothing to do" reading where nothing was measured. The pass still exited 2, but a monitor keyed on
  # `dead=` read a healthy pool.
  local dirs
  if ! dirs="$(registered_dirs)"; then
    cannot=$((cannot + 1))
    # The REASON was already named by `registered_dirs` (runner-root-unreadable /
    # runner-root-not-a-directory), so this line does not invent one — and the pass still publishes its
    # machine-readable summary, as every other cannot-measure exit of this verb does.
    printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=unmeasured ceiling=%s mem_available=unmeasured floor=%s MB dry_run=%s\n' \
      "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${CEILING:-unmeasured}" "${MEM_FLOOR_MB:-unset}" "$DRY"
    err "cannot-act (the restart arm could not enumerate the pool; the reason is the line above the summary)"
    return 2
  fi
  while read -r d; do
    [ -n "$d" ] || continue
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) continue ;;                       # live: not touched
      2) cannot=$((cannot + 1)); continue ;;   # cannot measure: start nothing
    esac
    dead=$((dead + 1))
    if [ "$DRY" = 1 ]; then
      # ⛔ THE PREVIEW ASKS, IT DOES NOT RESTATE. `restart --dry-run` re-runs the same liveness probe
      # and the same cannot-measure arm, so a preview can never announce a start the real pass would
      # refuse (an unreadable process table, a missing `run.sh`).
      rc=0
      "$SELF" restart --name "$(basename "$d")" --dry-run || rc=$?
      case "$rc" in
        0) restarted=$((restarted + 1)) ;;
        3) refused=$((refused + 1)) ;;
        *) cannot=$((cannot + 1)) ;;
      esac
      continue
    fi
    rc=0
    "$SELF" restart --name "$(basename "$d")" || rc=$?
    case "$rc" in
      0) restarted=$((restarted + 1)) ;;
      3) refused=$((refused + 1)) ;;
      # ⛔ A cannot-act is NOT a refusal: a scheduler branching on the documented codes must not see
      # a pass that could not act reported as success.
      *) cannot=$((cannot + 1)) ;;
    esac
  done <<<"$dirs"

  # ⛔ THE TWO HALVES OF THE PASS DO NOT NEED THE SAME INPUTS. Restarting a dead listener needs no
  # capacity reading at all — no floor, no ceiling (see cmd_restart) — so gating the WHOLE pass on
  # `readings` refused the one action this tool exists for, on exactly the box that needs it: dead
  # listeners on a host whose memory read is broken. Measured shape: an unreadable
  # cap_mem_free_mb returned 2 before the restart arm ran, so every dead listener stayed dead and
  # nothing in the output said the restart arm had never been reached. The restart arm therefore runs
  # FIRST; only the ADD arm requires the readings, and an unreadable reading still makes the pass exit
  # 2 — after the restarts, with the summary disclosing that the add arm did not run.
  if ! readings; then
    cannot=$((cannot + 1))
    slots >/dev/null 2>&1 || SLOTS="unmeasured"
    printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=%s ceiling=unmeasured mem_available=unmeasured floor=%s MB dry_run=%s\n' \
      "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${SLOTS:-unmeasured}" "${MEM_FLOOR_MB:-unset}" "$DRY"
    err "cannot-measure why=capacity-readings-unavailable (the restart arm already ran; nothing was ADDED) — fix the reading, then re-run"
    return 2
  fi
  # ⛔ THIS BOUNDS ATTEMPTS, NOT ADDS. Every iteration advances `n` (or breaks), so this is what makes
  # the loop terminate — but a name GitHub already holds costs an attempt AND adds nothing, so a budget
  # sized to the ceiling lands the pass short of capacity, and at 2*CEILING+4 held names it can never
  # add at all. Held names are normal after a `/tmp` wipe (every local `.runner` gone, every
  # registration still on GitHub), so the slack is sized for that, not for a hypothetical bug.
  budget=$((CEILING * 4 + 20))

  # (b)+(c) add only ABOVE the floor and BELOW the ceiling. A gate verdict (rc 3) ENDS the pass — it
  #        is a measurement of this box, not a per-name accident — while an UNAVAILABLE name (rc 4)
  #        is a per-name accident: skip to the next name, because one stale directory must not cost
  #        the box the capacity it is entitled to.
  while [ "$budget" -gt 0 ]; do
    budget=$((budget - 1))
    # ⛔ A POOL THAT CANNOT BE READ ENDS THE PASS (rc 2, nothing added): `slots` reads 0 for "cannot
    # list the root", and 0 never reaches the ceiling — that is how one pass minted 32 listeners on a
    # 3-slot box while reporting cannot=0.
    if ! slots; then
      cannot=$((cannot + 1))
      err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT (the pass stopped; nothing was added)"
      break
    fi
    # Nothing is added in a dry run, so `slots` never moves: the ceiling is counted against
    # slots + what the preview has already announced.
    if [ "$DRY" = 1 ]; then
      [ $(( SLOTS + dry_adds )) -lt "$CEILING" ] || {
        say "dry-run: ceiling would be reached slots=$SLOTS+$dry_adds ceiling=$CEILING ncpu=$NCPU"; break; }
    else
      [ "$SLOTS" -lt "$CEILING" ] || { say "ceiling reached slots=$SLOTS ceiling=$CEILING ncpu=$NCPU"; break; }
    fi
    scan=0
    while [ -e "$RUNNER_ROOT/$POOL_PREFIX-$n" ]; do
      n=$((n + 1)); scan=$((scan + 1))
      if [ "$scan" -ge 200 ]; then
        err "cannot-act why=no-free-runner-name scanned=200 prefix=$POOL_PREFIX-$n"
        cannot=$((cannot + 1)); break 2
      fi
    done
    # ⛔ THE PREVIEW ASKS, IT DOES NOT RESTATE: `add --dry-run` runs the SAME floor, ceiling, label,
    # name-availability and template checks, in the same order, and returns the same codes. A preview
    # that published "would add" unconditionally announced capacity the owner's memory floor refuses
    # (the mirror of under-reporting it).
    rc=0
    if [ "$DRY" = 1 ]; then
      "$SELF" add --name "$POOL_PREFIX-$n" --dry-run || rc=$?
    else
      "$SELF" add --name "$POOL_PREFIX-$n" || rc=$?
    fi
    case "$rc" in
      0) if [ "$DRY" = 1 ]; then dry_adds=$((dry_adds + 1)); else added=$((added + 1)); fi; n=$((n + 1)) ;;
      4) skipped=$((skipped + 1)); n=$((n + 1)) ;;
      # A name that could not be REGISTERED is a per-name accident too: try the next one, because the
      # box's capacity does not depend on GitHub happening to hold this name.
      5) failed=$((failed + 1)); n=$((n + 1)) ;;
      3) refused=$((refused + 1)); break ;;
      *) cannot=$((cannot + 1)); break ;;
    esac
  done

  # ⛔ In a dry run the counts are the PREVIEW's, for every field — `restarted` already counted what
  # it would start, so `added` must count what it would add, or the machine-readable summary
  # under-reports the very change the preview announced.
  [ "$DRY" = 1 ] && added=$((added + dry_adds))
  slots >/dev/null 2>&1 || SLOTS="unmeasured"
  printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=%s ceiling=%s mem_available=%s MB floor=%s MB dry_run=%s\n' \
    "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${SLOTS:-unmeasured}" "$CEILING" "$MEM_MB" "$MEM_FLOOR_MB" "$DRY"
  # ⛔ A PASS THAT PROVISIONED NOTHING IS NOT A SUCCESS. Exit 5 is per-NAME (that is the whole point:
  # one taken name must not end the pass), so on its own it cannot report a box that could not register
  # ANYTHING — a GitHub 5xx, an expired runner scope, a full disk all arrive as the same code. When the
  # pass ended short of the ceiling with every attempt failing, that IS cannot-act.
  if [ "$added" -eq 0 ] && [ "$failed" -gt 0 ] && [ "${SLOTS:-0}" -lt "$CEILING" ]; then
    err "cannot-act why=no-runner-registered failed=$failed slots=${SLOTS:-unmeasured} ceiling=$CEILING — the box gained no capacity this pass"
    return 2
  fi
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
  # ⛔ HELP BEFORE VALIDATION: `--help` reads no operand, and the box whose env is WRONG is exactly
  # the one that cannot read the contract otherwise — `RUNNER_START_SETTLE_S=5s … --help` used to
  # report `cannot-measure` and exit 2 with the usage block unreachable.
  case "$verb" in
    ''|-h|--help|help) usage 0 ;;
  esac
  validate_operands || return 2
  case "$verb" in
    status)    cmd_status "$@" ;;
    add)       cmd_add "$@" ;;
    restart)   cmd_restart "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    *) err "ci_runner_pool: unknown command '$verb' (try: status|add|restart|reconcile)"; return 1 ;;
  esac
}

main "$@"
