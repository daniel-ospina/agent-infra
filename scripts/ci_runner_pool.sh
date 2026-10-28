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
# ⛔ THE ENV A LISTENER INHERITS IS PART OF STARTING IT (agent-infra#2937). An instance's `.env` can
#   name a TMPDIR (`TMPDIR=/tmp/ci-actions-runner-N` on the pi-runner VM, hand-written 2026-09-30), and
#   NOTHING creates that directory: GitHub's `run.sh` sources `.env` and runs every job step under it,
#   and the runner has no mkdir of its own. The instance dir is persistent and its unit is enabled, so
#   after a reboot the LISTENER survives and its TMPDIR does not — `mktemp: failed to create file via
#   template '/tmp/ci-actions-runner-2/tmp.XXXXXXXXXX'`, exit 2, on a runner GitHub reports `online`.
#   That presentation is the damage: jobs that use `mktemp` fail identically and jobs that do not, pass,
#   so a HOST-WIDE fault reads as a flaky, PR-specific one (measured: it cost a full investigation of
#   an unrelated PR before the `mktemp` line was read). So `start_listener` now satisfies the env it is
#   about to hand over (create it, idempotently, before exec) and `status` reports a missing target as
#   a DEFECT rather than leaving the next job to discover it.
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
#   parser. ⛔ **THE POOL IS EVERY RUNNER ON THE BOX, NOT EVERY DIRECTORY UNDER ONE ROOT**: the same
#   process table is read for LIVE listeners whose instance dir sits OUTSIDE `RUNNER_ROOT` (measured
#   on the box this was written for: three live registrations under `/opt/gh-runner-*` while the
#   default root is `/tmp/actions-runner`). A listing that excludes them is a PARTIAL count of a
#   per-box budget, so `add` refuses (`why=pool-root-incomplete`) instead of putting a fourth runner
#   on a three-slot box, and `restart` refuses instead of calling an existing registration missing.
#   `RUNNER_ROOT` must be the directory that CONTAINS the instance dirs; set it to `/opt` and the same
#   box reports its real slots and can restart its real registrations.
#
# USAGE
#   ci_runner_pool.sh status  [--all]              # per-runner rows + this box's readings
#                                                 (--all is the SAME view: the default already lists
#                                                  every runner on THIS box, so the flag widens
#                                                  nothing. The cross-box view is capacity.sh / the
#                                                  fleet inventory, which this script does not
#                                                  duplicate.)
#                                                 A row whose instance `.env` names a TMPDIR that does
#                                                 NOT exist is reported as `defect tmpdir-missing` and
#                                                 is NOT a healthy row — see agent-infra#2937 below.
#   ci_runner_pool.sh add      --name <name> [--dry-run]
#   ci_runner_pool.sh restart  --name <name> [--dry-run]
#   ci_runner_pool.sh reconcile [--dry-run]        # the pass: restart dead listeners, add to ceiling
#
# ENV: RUNNER_ROOT (the directory that CONTAINS the instance dirs, one level above them; default
#        /tmp/actions-runner, where this tool puts what it creates — a root that excludes a LIVE
#        listener is refused as pool-root-incomplete)
#      RUNNER_TEMPLATE (pristine unpacked release to copy; default $RUNNER_ROOT/_template)
#      RUNNER_MEM_FLOOR_MB (3584 = the 3.5 GB the gate refused at) · RUNNER_CORES_PER_SLOT (3)
#      RUNNER_POOL_REPO (owner/name — BOTH the registration-token's scope and the URL the runner is
#        registered at, so it must be bare `owner/name`; a URL form is refused) · RUNNER_TOKEN (skip gh;
#        SINGLE-USE, so it serves one `add` — `reconcile` refuses it rather than spending it on the
#        first name and failing the rest)
#      RUNNER_LABELS (overrides the derived self-hosted-<arch> marker; must still contain it)
#      POOL_PREFIX (default pi-runner-<host>) · RUNNER_START_SETTLE_S (5)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act — nothing changed, EXCEPT a registration
#       the message names explicitly (a `.runner` written before its listener failed) · 3 REFUSED,
#       nothing changed — `add`: a gate verdict (a floor/ceiling refusal); `restart`: that name has no
#       registration under $RUNNER_ROOT, or its dir exists without a `.runner` (NOT a capacity verdict —
#       the message names the state and the action that clears it); `status`: the report
#       it produced contains a DEAD listener, or a `defect tmpdir-missing` row (see below) · 4 name not
#       available (that name is taken;
#       nothing changed, try another name) · 5 this name could not be REGISTERED (config.sh failed, or
#       it left no `.runner`): a per-name failure, so the pass tries the next name rather than ending
#       ⛔ 4 IS CHECKED BEFORE 3: a name that is already taken reports 4 even on a box that is also
#       at/below a gate, because the name condition is a fact about the request, not the box.
#
# `status` exits 3 when it produced a report in which at least one listener is DEAD — a report is
# still a report, but a dead listener is a fact a caller must be able to branch on without parsing
# the table. It exits 2 (never 0, never 3) when it could not measure — including a pool it can only
# PARTLY see (a live listener outside `RUNNER_ROOT`, `why=pool-root-incomplete`), because the rows and
# the slot count it prints would then describe part of the box as if it were all of it.
#
# ⛔ A `defect tmpdir-missing` ROW ALSO EXITS 3 (agent-infra#2937): a LIVE listener whose `.env` names
# a TMPDIR that does not exist is reported `online` by GitHub, runs its unit happily, PICKS UP jobs,
# and fails each one in its first seconds at `mktemp`. That is a report containing a runner nobody can
# use, so rc 0 over it would be a false PASS. `start_listener` — the single path `add`, `restart` and
# `reconcile` all start through — now creates the directory (`mkdir -p`, mode 700, owner = the
# listener's own user) before it execs `run.sh`, so a reboot cannot leave the listener without it and
# no systemd drop-in has to be remembered per instance.
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

log_line() { printf '%s\n' "$*"; }
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

# outside_listener_dirs — instance dirs with a LIVE listener that sit OUTSIDE $RUNNER_ROOT.
# rc 0 = measured (one dir per line, possibly none) · rc 2 = CANNOT MEASURE.
# ⛔ THE POOL IS EVERY RUNNER ON THE BOX, NOT EVERY DIRECTORY UNDER ONE ROOT (#2381 review, P1).
# A box whose registrations live under a DIFFERENT parent (measured: three live listeners under
# /opt/gh-runner-*, while the shipped default root is /tmp/actions-runner) made `slots` read 1 where
# the box carried 3 — so `reconcile` would ADD onto a box already at the owner's 3-slot ceiling
# (memory and cores are per BOX, not per root), and `restart` answered "no registration … (add it
# first)" for a registration that was right there. Both are ACTIONS taken from a listing that was
# not the pool — the class this file refuses everywhere else. The process table is the one reading
# that holds regardless of where the installs live, and it is already this file's liveness evidence.
# is_plain_path <s> — no whitespace and no shell syntax. A dir that does not RESOLVE is judged by its
# spelling only when it is a plain path (#2524 review, P1): `bash -c 'cd <root>/pi-1 && exec
# <outside>/bin/…'` leaves a "dir" whose literal prefix is under the root but which is not a path at
# all, and calling that "inside" is how an outside listener read as in-pool.
is_plain_path() {
  case "${1:-}" in
    *[[:space:]]*|*'&'*|*'|'*|*';'*|*'<'*|*'>'*) return 1 ;;
  esac
  return 0
}

outside_listener_dirs() {
  local out pid args dir root lroot pdir cand one
  if ! out="$(ps -ww -eo pid=,args= 2>/dev/null)"; then
    err "cannot-measure why=process-table-unreadable (ps -ww -eo pid=,args= failed)"; return 2
  fi
  [ -n "$out" ] || { err "cannot-measure why=process-table-empty (ps listed no processes)"; return 2; }
  # The PHYSICAL root when it resolves, the literal one otherwise: a symlinked root must not report
  # every registration under it as "outside". ⛔ A ROOT OF `/` STAYS `/` — normalising it away made
  # the containment pattern `//*`, which no absolute dir matches, so every listener on the box
  # reported "outside" with a remedy the operator had already applied (#2381 review round 6).
  root="$(cd "$RUNNER_ROOT" 2>/dev/null && pwd -P)" || root="$RUNNER_ROOT"
  root="${root%/}"; [ -n "$root" ] || root="/"
  lroot="${RUNNER_ROOT%/}"; [ -n "$lroot" ] || lroot="/"
  while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    # Same invocation anchor as `listener_pid`: the ` run` after the binary is what separates a
    # LISTENER from any process that merely names the file.
    case "$args" in *"/bin/Runner.Listener run"*) ;; *) continue ;; esac
    # ⛔ THE INSTANCE DIR IS THE ARGV WORD THAT CARRIES THE BINARY, NOT EVERYTHING BEFORE IT (#2381
    # review round 6, P1): a listener started through a wrapper (`nohup`, `env K=V`, `bash`, `sudo`,
    # a service shim) has `<wrapper> <dir>/bin/Runner.Listener run` as its argv, so the whole prefix
    # was `nohup <dir>` — not an absolute path — and the old `continue` DROPPED it silently. Measured:
    # `listener_pid` calls that same process LIVE while this arm called the pool complete, so `add`
    # minted a token and REGISTERED a runner on a box already at its ceiling.
    dir="${args%%/bin/Runner.Listener run*}"
    # Strip the WRAPPER tokens, not everything before the binary: `nohup <dir>/bin/…`, `env K=V <dir>/…`,
    # `bash <dir>/bin/…` all carry a wrapper in front. ⚠️ One token at a time, because an INSTANCE DIR
    # MAY CONTAIN A SPACE (measured: the suite's own `bad name` fixture) — splitting on the last space
    # tore `…/bad name` into `name` and dropped a LIVE listener out of the pool.
    while [ -n "$dir" ] && [ "${dir#/}" = "$dir" ] && [ "$dir" != "${dir#* }" ]; do dir="${dir#* }"; done
    case "$dir" in
      # ⛔ A RELATIVE INSTANCE DIR IS cannot-measure, NEVER "not an instance": GitHub's own `run.sh`
      # starts `./bin/Runner.Listener`, and a relative dir cannot be judged inside or outside without
      # the process's cwd — so dropping it is how an outside listener gets past the arm that exists to
      # catch exactly that.
      /*) ;;
      *) err "cannot-measure why=instance-dir-unresolvable argv=$args (the instance dir is not an absolute path, so it cannot be judged against RUNNER_ROOT)"; return 2 ;;
    esac
    dir="${dir%/}"
    # ⛔ RESOLVE FIRST, THEN JUDGE (#2524 review, P1): a LITERAL prefix test is defeated by `..`
    # (`$RUNNER_ROOT/../outside/pi-x`) and by a wrapper whose argv contains its own `cd` target
    # (`bash -c 'cd $RUNNER_ROOT/pi-1 && exec <outside>/bin/…'`), so those listeners read IN-POOL and
    # the pool read as complete — the over-add this arm exists to prevent. The physical dir is the only
    # evidence that can be trusted. A dir that does not RESOLVE is judged by spelling ONLY when the
    # spelling is a plain path under our own root (a deleted instance is still our capacity), and is
    # `cannot-measure` (rc 2) otherwise — never dropped, and never called "inside" on shell syntax.
    if ! pdir="$(cd "$dir" 2>/dev/null && pwd -P)" || [ -z "$pdir" ]; then
      # ⛔ AN UNRESOLVABLE DIR IS JUDGED BY SPELLING ONLY WHEN THE SPELLING IS A PLAIN PATH (#2524
      # review, P1). A deleted instance dir under our OWN root is still a runner of ours — the capacity
      # is on the box, its listing entry is simply gone (an operator `rm -rf`ed it under a live
      # listener), so it stays IN-POOL rather than blocking every add. But a wrapper's own `cd` target
      # is NOT a path: `bash -c 'cd <root>/pi-1 && exec <outside>/bin/…'` has a literal prefix under the
      # root, and judging THAT by spelling is how an outside listener read as inside. Anything carrying
      # shell syntax is `cannot-measure` (rc 2), never "inside".
      is_plain_path "$dir" || {
        err "cannot-measure why=instance-dir-unresolvable argv=$args (the instance dir '$dir' is not a plain path and does not resolve, so it cannot be judged against RUNNER_ROOT)"; return 2; }
      for cand in "$root" "$lroot"; do
        [ -n "$cand" ] || continue
        [ "$cand" = "/" ] && continue 2
        case "$dir" in "$cand"/*) continue 2 ;; esac
      done
      err "cannot-measure why=instance-dir-unresolvable argv=$args (the instance dir '$dir' does not resolve on this box, so it cannot be judged against RUNNER_ROOT)"; return 2
    fi
    # INSIDE = the PHYSICAL dir under the PHYSICAL or the LITERAL root (`/` contains every absolute path).
    for cand in "$root" "$lroot"; do
      [ -n "$cand" ] || continue
      [ "$cand" = "/" ] && continue 2
      case "$pdir" in "$cand"/*) continue 2 ;; esac
      # ⛔ A SYMLINKED INSTANCE INSIDE THE ROOT IS IN THE POOL (#2381 review round 6, P1): `run.sh`
      # resolves its own dir with `cd -P`, so argv carries the TARGET and the dir is not literally
      # under the root — while `registered_dirs` counts `$RUNNER_ROOT/$(basename)` as a slot and
      # `listener_pid` reads it LIVE. Reporting it outside refused `add` and `reconcile` on a box whose
      # only defect was a hand-made symlink, and printed a report that contradicted its own rows.
      one="$cand/$(basename "$dir")"
      if [ -d "$one" ] && [ "$(cd "$one" 2>/dev/null && pwd -P)" = "$pdir" ]; then continue 2; fi
    done
    printf '%s\n' "$dir"
  done <<<"$out"
  return 0
}

# join_lines <text> — one comma-separated field from a newline-separated list (#2381 review round 6,
# P2): the machine-readable `outside=` field was `tr '\n' ' '`, which glued the first dir to the em
# dash (`outside=/opt/x— a LIVE…`) and left two dirs an unquoted space-separated list.
join_lines() { local s; s="$(printf '%s' "$1" | tr '\n' ',')"; printf '%s' "${s%,}"; }

# require_pool_complete <verb> — rc 0 = the listing under $RUNNER_ROOT IS the box's pool.
# rc 2 = a LIVE listener runs from an instance dir OUTSIDE it, so the listing (and the ceiling
# counted from it) is INCOMPLETE and no action may be taken from it. Fails closed: an unreadable
# process table is rc 2 here too, never "nothing outside".
require_pool_complete() {
  local outside
  outside="$(outside_listener_dirs)" || return 2
  [ -z "$outside" ] && return 0
  err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT outside=$(join_lines "$outside") — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT, so the pool listing (and the ceiling counted from it) is incomplete; set RUNNER_ROOT to the directory that CONTAINS every instance dir (one level above them) — $1 NOT attempted"
  return 2
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

# instance_tmpdir <dir> — the TMPDIR the instance's own `.env` names, as an ABSOLUTE path, or empty
# when it names none. ⛔ NOTHING CREATES THAT DIRECTORY (agent-infra#2937). GitHub's `run.sh` sources
# `.env` and runs every job step under that TMPDIR; the runner has no mkdir of its own, and this tool
# neither wrote the `.env` nor ever looked at it. So an instance whose `.env` names a VOLATILE path
# (`/tmp/ci-actions-runner-N`, hand-written on the pi-runner VM) keeps a HEALTHY listener across a
# reboot while its TMPDIR is gone: the job is PICKED UP, starts, and dies in its first seconds at
# `mktemp` — which reads as "this workflow is broken", not "this host is". Measured job 122457527181:
# `mktemp: failed to create file via template '/tmp/ci-actions-runner-2/tmp.XXXXXXXXXX'`, exit 2, on a
# box GitHub reported `online`.
# A relative value resolves against the INSTANCE DIR, because `run.sh` `cd`s there before the listener
# reads the variable — resolving it anywhere else would create a directory the runner never uses.
#
# ⛔ THREE STATES, NOT TWO (#3004 review, P1). Returning empty for BOTH "the file names no TMPDIR" AND
# "the file could not be read" made an unreadable `.env` collapse into "names none": `[ -f ]` is TRUE
# for a mode-000 file, `sed`'s error was discarded, and the caller then published `tmpdir_defects=0`
# — a count over a reading nobody took. `status` may legitimately run as a DIFFERENT user from the
# runner's, so that shape is reachable exactly as the comment on its call site describes.
#   rc 0 + a path   · it names a TMPDIR (absolute, resolved)
#   0, no output    · it names none (the agent-infra `ai-runner-*` shape) — nothing to create
#   2               · CANNOT MEASURE (unreadable `.env`), or a value no shell-free read can satisfy
#
# ⛔ AND THE VALUE MUST BE LITERAL (#3004 review, P1). `run.sh` SOURCES `.env`, so the listener sees
# the EXPANDED value while a `sed` read sees the raw text: `TMPDIR=$HOME/ci-tmp` had this tool create a
# directory literally named `$HOME` under the instance dir and print `created tmpdir=…` (rc 0) over a
# runner that still inherited an ABSENT TMPDIR — a false PASS in the exact dimension this arm adds.
# The same went for a trailing comment (`…/tmp  # scratch`). A value needing shell evaluation is
# refused rather than guessed at: the refusal names the value and the remedy, and it starts nothing.
instance_tmpdir() {
  local d="$1" t
  [ -f "$d/.env" ] || return 0
  # An EXISTING but unreadable `.env` is cannot-measure. `-r` is the read this function actually does
  # (and it is FALSE for a mode-000 file, which `-f` alone happily accepts).
  [ -r "$d/.env" ] || { err "cannot-measure why=tmpdir-unreadable path=$d/.env"; return 2; }
  # LAST assignment wins, which is what a shell sourcing the file would do. `export TMPDIR=…` is
  # honoured too — `. ./.env` accepts it, so requiring a bare `TMPDIR=` made a legal .env invisible to
  # BOTH the creation and the detection. The `2>/dev/null` is gone on purpose: a read that failed must
  # be visible, not silently equal to "names none".
  t="$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TMPDIR=//p' "$d/.env" | tail -n 1)" || return 2
  t="${t%$'\r'}"   # a `.env` edited on a CRLF host would otherwise name a path with a CR in it
  case "$t" in     # strip ONE layer of matching quotes; the value is a path, not a shell word
    \"*\") t="${t#\"}"; t="${t%\"}" ;;
    \'*\') t="${t#\'}"; t="${t%\'}" ;;
  esac
  [ -n "$t" ] || return 0
  # A `$`, a backtick or a `~` is EXPANDED by the sourcing listener; whitespace is where a value ends
  # and a comment begins. None of them can be honoured from the raw text, so none is guessed at.
  case "$t" in
    *'$'*|*'`'*|*'~'*|*[[:space:]]*)
      err "cannot-act why=tmpdir-value-not-literal value=$t (named by $d/.env) — the listener SOURCES .env, so this value is expanded there and cannot be satisfied from the raw text; write a literal absolute path in $d/.env"
      return 2 ;;
  esac
  case "$t" in /*) : ;; *) t="$d/$t" ;; esac
  printf '%s' "$t"
}

# ensure_tmpdir <dir> — create the TMPDIR the instance's `.env` names, IDEMPOTENTLY, before the
# listener is exec'd. rc 0 = satisfiable (created, or already there) · 2 = cannot-act, nothing started.
# ⛔ OWNER AND MODE. The directory is created BY THE USER THAT WILL RUN THE LISTENER, which is the only
# owner that can be right here: `start_listener` execs `run.sh` as this same process's user, so a
# `mkdir` needs no chown and cannot pick the wrong one. Mode 700 is what a private per-runner temp dir
# should be, and `mkdir -p` does NOT touch the mode of a directory that already exists — so the
# operative boxes (hand-repaired, carrying 755) are left exactly as they are, and only a directory
# this tool creates is tightened.
# ⛔ AND A CREATION THAT FAILED IS A REFUSAL, NOT A WARNING. Starting the listener anyway is the whole
# defect: it comes up healthy and every job on it dies at `mktemp`. `mkdir`'s exit code alone is not
# the verdict either (the `-p` arm can succeed while the target is still not a directory) — the test
# is that the directory EXISTS and this user can write it, which is what `mktemp` will do next.
ensure_tmpdir() {
  local d="$1" t created=0 rc=0 p
  t="$(instance_tmpdir "$d")" || rc=$?
  # cannot-measure (`tmpdir-unreadable`) and a non-literal value are BOTH cannot-act here: the reason
  # was already named by `instance_tmpdir`, so this arm does not invent a second one. Starting the
  # listener anyway is the defect — the env it would inherit is unknown.
  [ "$rc" -eq 0 ] || return 2
  [ -n "$t" ] || return 0
  if [ ! -d "$t" ]; then
    # ⛔ A PREVIEW MAY NOT MUTATE, AND IT MAY NOT LIE (#3004 review, P2). `--dry-run` used to skip this
    # check entirely (it sat downstream of the DRY return), so an uncreatable target previewed as
    # "would start the listener" (rc 0) and then refused for real (rc 2) — the lying preview this file
    # refuses everywhere else. In DRY mode the same satisfiability question is asked WITHOUT creating:
    # `mkdir -p` succeeds over any missing ancestors, so the test is the first ancestor that EXISTS.
    if [ "$DRY" = 1 ]; then
      p="$t"
      while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="$(dirname "$p")"; done
      if [ -d "$p" ] && [ -w "$p" ]; then
        log_line "dry-run: would create tmpdir=$t (named by $d/.env)"
        return 0
      fi
      err "cannot-act why=tmpdir-uncreatable path=$t (named by $d/.env) — nothing started: the listener would come up healthy and every job on it would die at mktemp; check the parent directory's permissions and that no FILE sits on the path"
      return 2
    fi
    mkdir -p -m 700 "$t" 2>/dev/null || true
    [ -d "$t" ] || {
      err "cannot-act why=tmpdir-uncreatable path=$t (named by $d/.env) — nothing started: the listener would come up healthy and every job on it would die at mktemp; check the parent directory's permissions and that no FILE sits on the path"
      return 2
    }
    created=1
  fi
  [ -w "$t" ] || {
    err "cannot-act why=tmpdir-unwritable path=$t (named by $d/.env) — nothing started: the listener would come up healthy and every job on it would die at mktemp"
    return 2
  }
  # PRINT THE PATH, as the memory floor prints its reading: a creation nobody can see is one the
  # operator cannot audit, and this is the line that distinguishes a repaired box from a lucky one.
  [ "$created" = 1 ] && log_line "created tmpdir=$t (named by $d/.env; nothing else creates it)"
  return 0
}

# start_listener <dir> — start run.sh from the instance dir, then PROVE a listener appeared.
# A pid we just forked exists for one instant; a registration whose listener dies on connect (GitHub
# refusing a duplicate, a revoked token) would otherwise be reported "restarted" every pass, forever.
start_listener() {
  local d="$1" i=0 rc
  [ -x "$d/run.sh" ] || { err "cannot-act why=runner-not-installed path=$d/run.sh"; return 2; }
  # ⛔ THE ENV THE LISTENER INHERITS MUST BE SATISFIABLE BEFORE IT IS EXEC'D (agent-infra#2937). This is
  # the ONE place a listener is STARTED — `add`, `restart` and `reconcile` all come through here — so
  # the creation is at START TIME and survives a reboot with no systemd drop-in to remember. It is not
  # the only place a listener RUNS, though: a listener that SURVIVED the reboot is never started again,
  # so `cmd_restart` and `cmd_reconcile` also repair their LIVE arms (#3004 review, P1). `--dry-run`
  # cannot reach here, but `ensure_tmpdir` is DRY-aware anyway so no future caller can mutate a preview.
  ensure_tmpdir "$d" || return 2
  ( cd "$d" && exec "$d/run.sh" ) >>"$d/listener.log" 2>&1 &
  while [ "$i" -lt $((SETTLE_S * 2)) ]; do
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) log_line "listener_pid=$LISTENER_PID"; return 0 ;;
      2) return 2 ;;   # cannot measure: never claim a start, never wait blind
    esac
    sleep 0.5; i=$((i + 1))
  done
  err "cannot-act why=listener-never-appeared waited=${SETTLE_S}s see=$d/listener.log"
  return 2
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────
cmd_status() {
  local dead=0 live=0 d rc dirs outside t rownote tmpdir_defects=0
  # `--all` is ACCEPTED AND CHANGES NOTHING, DELIBERATELY: #2373 names a `status --all`, and the
  # default view already IS every runner on this box, so there is no narrower form for the flag to
  # widen. It is documented as such (USAGE) rather than left as a flag a reader assumes reveals more
  # than it does — and rather than dropped, because the issue's clause names it.
  while [ $# -gt 0 ]; do
    case "$1" in --all) shift ;; *) err "usage: status [--all]"; return 1 ;; esac
  done
  readings || return 2
  # ⛔ THE INCOMPLETE-POOL READ IS ITS OWN REFUSAL (#2381 review, P1): a report that counts only
  # `$RUNNER_ROOT` while live listeners run elsewhere is a partial count printed as the box's pool.
  outside="$(outside_listener_dirs)" || return 2
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
    # ⛔ A LIVE ROW UNDER A MISSING TMPDIR IS NOT A HEALTHY ROW (agent-infra#2937). This is the exact
    # shape that cost a full investigation of an unrelated PR: GitHub says `online`, the unit says
    # `active (running)`, the job is PICKED UP — and every job on the instance dies at `mktemp` in its
    # first seconds, so the failure presents as "this workflow is broken". The tool holds the datum
    # (`.env`) and now reads it, instead of leaving the next job to discover it.
    # ⛔ MISSING ONLY, NOT UNWRITABLE: `status` may legitimately run as a different user from the one
    # that owns the runner, so a `-w` test here would report a defect on a healthy box. The launcher
    # runs as the listener's own user and DOES refuse an unwritable target.
    t="$(instance_tmpdir "$d")" || return 2   # cannot measure: never publish tmpdir_defects=0 over it
    if [ -n "$t" ] && [ ! -d "$t" ]; then
      # ⛔ THE CLAUSE MUST MATCH THE ROW IT IS UNDER (#3004 review, P2): this arm runs for DEAD rows
      # too, where "report it healthy" is false — the row says DEAD and GitHub says offline — and only
      # the missing-TMPDIR half is true. `rc` is the state this loop already measured.
      rownote="the listener row above (and GitHub) report it healthy"
      [ "$rc" = 1 ] && rownote="the listener row above reports it DEAD"
      err "defect tmpdir-missing name=$(basename "$d") path=$t — $rownote, and every job on it dies at mktemp; run: $SELF restart --name $(basename "$d")"
      tmpdir_defects=$((tmpdir_defects + 1))
    fi
  done <<<"$dirs"
  # ⛔ THE SUMMARY NAMES THE READING IT IS (#2381 review round 6, P1). The rows come from the PROCESS
  # TABLE, which only holds LIVE listeners: an instance dir outside RUNNER_ROOT whose listener is DEAD
  # is invisible here, and a bare `slots=N` over it read as "the box's pool" in exactly the incident
  # `restart` exists for (two runners GitHub showed OFFLINE). The caveat travels WITH the count.
  printf 'summary live=%s dead=%s slots=%s ceiling=%s pool_read=process-table-live-only tmpdir_defects=%s\n' "$live" "$dead" "$SLOTS" "$CEILING" "$tmpdir_defects"
  # After the measured rows, so the report is visible — but the count it publishes is NOT this box's
  # pool, so the rc must not claim a complete measurement.
  if [ -n "$outside" ]; then
    err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT outside=$(join_lines "$outside") — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT, so slots=$SLOTS counts a PARTIAL pool; set RUNNER_ROOT to the directory that CONTAINS every instance dir (one level above them) and re-read — ⚠️ this reading is the process table, so consolidating the parents is what makes it complete; an instance dir outside RUNNER_ROOT whose listener is DEAD is not enumerable at all"
    return 2
  fi
  # ⛔ A MISSING TMPDIR IS A DEFECT THE CALLER MUST BE ABLE TO BRANCH ON, like a DEAD listener: rc 0
  # over a row whose jobs cannot run is the false PASS this arm exists to refuse.
  [ "$dead" -eq 0 ] && [ "$tmpdir_defects" -eq 0 ] || return 3
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
  # ⛔ A CEILING COUNTED FROM PART OF THE BOX IS NOT THE CEILING (#2381 review, P1). This gate is the
  # last thing between the pass and a registration, so it refuses rather than trusting a listing that
  # provably excludes a live listener.
  require_pool_complete add || return 2
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
  log_line "reading: MemAvailable=$(mb_as_gb "$MEM_MB") GB (${MEM_MB} MB) floor=$(mb_as_gb "$MEM_FLOOR_MB") GB ncpu=$NCPU ceiling=$CEILING slots=$SLOTS labels=$label"

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
    log_line "dry-run: would copy $RUNNER_TEMPLATE to $dir, register name=$name and start its listener"; return 0
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
  # The SAME completeness check as the pre-claim gate: an outside listener can appear (a hand add, a
  # peer pass with a different root) between the two reads, and the claim is released rather than
  # turned into a registration the ceiling never counted.
  if ! require_pool_complete add; then rm -rf "$dir"; return 2; fi
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
  log_line "added name=$name dir=$dir listener_pid=$(listener_pid "$dir")"
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
  # already registered (the same false verdict `status` must never print). This guard DEREFERENCES a
  # KNOWN name, so traversal (`x`) is what it needs; `probe_listener` below independently requires
  # `r`+`x` before liveness is judged, so do not "restore symmetry" by relaxing that one too.
  if [ ! -x "$dir" ]; then
    if [ -d "$dir" ]; then
      err "cannot-measure why=instance-unreadable path=$dir"; return 2
    fi
    # ⛔ A PATH THAT EXISTS IS NOT A MISSING REGISTRATION (#2381 review round 2, P2): a FILE or a
    # DANGLING SYMLINK squatting on the name is refused by `add` (rc 4, "clear it or pick another
    # name"), so "add it first" here sent the operator to a verb that cannot help — the two-verb
    # bounce this file exists to end, surviving for every non-directory shape because this arm only
    # asked "is it a traversable directory".
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      err "REFUSED restart name=$name path=$dir exists but is not a searchable directory (a file or a symlink) — clear it, or pick another name; nothing changed"; return 3
    fi
    # ⛔ BEFORE CONCLUDING "NO REGISTRATION", ASK WHERE THE POOL ACTUALLY LIVES (#2381 review, P1).
    # A registration under another parent is not missing, and "add it first" is the one remedy that
    # cannot help (add refuses a name it cannot see, and the operator is sent to re-register a runner
    # that already exists).
    require_pool_complete restart || return 2
    # ⛔ THIS READ IS THE PROCESS TABLE, AND IT ONLY SEES LIVE LISTENERS (#2381 review round 6, P1).
    # A registration under another parent whose listener is DEAD is invisible here, so "no
    # registration" would be a measured claim the tool did not measure — and "(add it first)" is the
    # one verb that cannot help (add refuses a held name and cannot see the other parent either). The
    # message names the limitation and the real next step instead of asserting absence.
    err "REFUSED restart name=$name no registration at $dir — nothing changed. ⚠️ this read is the PROCESS TABLE (ps), so an instance dir OUTSIDE RUNNER_ROOT=$RUNNER_ROOT whose listener is DEAD is invisible here: check the other parents on this box (e.g. the installs §'pool is every runner on the box' names), or set RUNNER_ROOT to the parent that CONTAINS every instance dir"; return 3
  fi
  # ⛔ ONE REGISTRATION, ONE DEFINITION (#2381 review, P2). The listing (`registered_dirs`) and `add`
  # both accept a `.runner` that is a FILE **or a SYMLINK** (`-e || -L`); this verb required `-f`,
  # which is FALSE for a symlink whose target is a directory or does not exist. The verbs then read
  # ONE registration two ways and bounced the operator forever: `add` answered "already registered —
  # use restart" (rc 4) and `restart` answered "no registration — add it first" (rc 3), so an
  # enumerated, DEAD slot could never be restarted — it stayed advertised to GitHub and idle, which is
  # the one state `restart` exists to end. `-f` here was also the false verdict the guard above
  # refuses to print, arrived at by a different predicate: a registration we cannot inspect is
  # `cannot-measure`, never "no registration".
  if [ ! -e "$dir/.runner" ] && [ ! -L "$dir/.runner" ]; then
    # ⛔ "ADD IT FIRST" IS NOT A REMEDY HERE (#2381 review, P2): the directory EXISTS, so `add`
    # refuses this same path as unavailable (rc 4) and the operator bounces between two verbs forever.
    # Name the state that was measured and the action that actually clears it.
    err "REFUSED restart name=$name path=$dir exists but carries no .runner registration (a file, a symlink, or a directory without one) — clear it, or pick another name; nothing changed"; return 3
  fi
  # ⛔ NO MEMORY FLOOR ON THIS PATH, DELIBERATELY (#2373). The floor gates ADDING a new runner. A
  # dead listener for an EXISTING registration costs ~200 MB to bring back and is capacity the box has
  # already paid for; refusing it on a low-memory box would leave the slot registered, advertised and
  # idle — the worst of the three states. The owner's floor sentence names ADDING, not restarting.
  rc=0; probe_listener "$dir" || rc=$?
  case "$rc" in
    # ⛔ A LIVE LISTENER IS NOT A REPAIRED BOX (#3004 review, P1). The scenario THIS TOOL EXISTS FOR is
    # the post-reboot one: the instance dir is persistent and its unit is enabled, so the LISTENER
    # SURVIVES while its /tmp TMPDIR does not. `start_listener` cannot help there — nothing is started —
    # so skipping the live arm made `restart`, the very remedy `status` prints, answer "not touched"
    # and exit 0 over the still-broken box: a false PASS handed to the operator, and the PR's own claim
    # ("start-time, so a reboot cannot undo it") false for the reboot it documents. Creating a
    # directory does not touch, restart or double-start a listener — the invariant this line states
    # still holds; the env the listener ALREADY has is simply made satisfiable at last.
    0) ensure_tmpdir "$dir" || return 2
       log_line "live name=$name pid=$LISTENER_PID — not touched"; return 0 ;;
    2) return 2 ;;   # cannot measure: START NOTHING (a blind start is how a listener is doubled)
  esac
  # ⛔ THE START'S OWN PRECONDITION IS CHECKED BEFORE THE DRY RETURN, so a preview cannot announce a
  # start the real pass refuses. `start_listener` re-checks it (defence in depth), but a check that
  # only lives downstream of the `--dry-run` return is a preview that lies.
  [ -x "$dir/run.sh" ] || { err "cannot-act why=runner-not-installed path=$dir/run.sh"; return 2; }
  # ⛔ AND SO IS THE ENV PRECONDITION (#3004 review, P2): it lives in `start_listener`, i.e. downstream
  # of this DRY return, so an uncreatable TMPDIR previewed as "would start the listener" (rc 0) and
  # then refused for real (rc 2). `ensure_tmpdir` is DRY-aware: it REPORTS the creation it would make
  # and refuses an unsatisfiable target, mutating nothing.
  ensure_tmpdir "$dir" || return 2
  if [ "$DRY" = 1 ]; then log_line "dry-run: would start the listener for name=$name"; return 0; fi
  start_listener "$dir" || return 2
  log_line "restarted name=$name pid=$(listener_pid "$dir")"
  return 0
}

cmd_reconcile() {
  local d restarted=0 added=0 refused=0 cannot=0 dead=0 skipped=0 failed=0 n=1 rc budget scan=0 dry_adds=0 outside
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
      # ⛔ THE LIVE ARM IS THIS PASS'S REPAIR PATH FOR THE POST-REBOOT STATE (#3004 review, P1): the
      # listener survived, its TMPDIR did not, and nothing below this line runs for it. Repairing the
      # env does not touch the listener, so "not touched" stays true while the box stops being broken.
      # An unrepairable TMPDIR is `cannot`, not a clean pass.
      0) ensure_tmpdir "$d" || cannot=$((cannot + 1)); continue ;;
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
        3) cannot=$((cannot + 1)) ;;   # see the race note below — never `refused`
        *) cannot=$((cannot + 1)) ;;
      esac
      continue
    fi
    rc=0
    "$SELF" restart --name "$(basename "$d")" || rc=$?
    case "$rc" in
      0) restarted=$((restarted + 1)) ;;
      # ⛔ A RESTART REFUSAL IS NOT A PASS (#2381 review, P2). `refused` is the ADD arm's
      # floor/ceiling refusal — a legitimate outcome that must not fail the pass — and it NEVER
      # reaches the exit decision, so counting a `restart` rc 3 here printed `dead=1 refused=1` and
      # exited 0: a false PASS over the pass's OWN first job, a slot it had enumerated as dead one
      # line above and left dead. A restart rc 3 means the verb disagreed with the listing this pass
      # just used (the registration vanished between the two, a TOCTOU), so it is cannot-act (exit
      # 2), never success. The reachable half of that disagreement — a `.runner` this pass lists and
      # `restart` calls missing — is pinned in `ci_runner_pool.test.sh` ("a dangling-symlink
      # marker"); this arm is the residual race a static fixture cannot construct.
      3) cannot=$((cannot + 1)) ;;
      # ⛔ A cannot-act is NOT a refusal: a scheduler branching on the documented codes must not see
      # a pass that could not act reported as success.
      *) cannot=$((cannot + 1)) ;;
    esac
  done <<<"$dirs"

  # ⛔ THE RESTART ARM CANNOT ENUMERATE A POOL THAT IS NOT UNDER $RUNNER_ROOT (#2381 review, P1).
  # Reporting `dead=0 restarted=0` over listeners it never listed is a false healthy reading, and the
  # ADD arm downstream counts its ceiling from the same partial listing — so the pass names the gap
  # and exits 2 rather than publishing a clean summary over part of the box.
  if ! outside="$(outside_listener_dirs)"; then
    cannot=$((cannot + 1))
  elif [ -n "$outside" ]; then
    cannot=$((cannot + 1))
    err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT outside=$(join_lines "$outside") — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT: this pass could not enumerate it (the restart arm covers RUNNER_ROOT alone) and the ADD arm refuses on the same reading; set RUNNER_ROOT to the directory that CONTAINS every instance dir"
  fi

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
  # ⛔ A CALLER-SUPPLIED TOKEN CANNOT SERVE A PASS (#2381 review, P2). A registration token is
  # SINGLE-USE and expires in ~1h — both this file's own premises — so an inherited $RUNNER_TOKEN
  # covers exactly ONE add: every later name would fail config.sh (rc 5) and the pass would burn its
  # whole attempt budget reporting `failed=N added=0`. A dry run spends nothing, so it may preview.
  if [ "$DRY" = 0 ] && [ -n "${RUNNER_TOKEN:-}" ]; then
    cannot=$((cannot + 1)); budget=0
    err "cannot-act why=runner-token-single-use (RUNNER_TOKEN is single-use, so it covers ONE add; this pass can add several — the ADD arm did not run, the RESTART arm already did; unset RUNNER_TOKEN and authenticate $GH_CMD so each add mints its own)"
  fi

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
        log_line "dry-run: ceiling would be reached slots=$SLOTS+$dry_adds ceiling=$CEILING ncpu=$NCPU"; break; }
    else
      [ "$SLOTS" -lt "$CEILING" ] || { log_line "ceiling reached slots=$SLOTS ceiling=$CEILING ncpu=$NCPU"; break; }
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
  # ⛔ THE FINAL LISTING IS ITSELF A GATE OPERAND (#2381 review, P1). This used to be
  # `slots >/dev/null 2>&1 || SLOTS="unmeasured"`, and the literal string then reached
  # `[ "$SLOTS" -lt "$CEILING" ]` below: that test ERRORS, and under `set -uo pipefail` (no `-e`) an
  # errored test is FALSE — so the "provisioned nothing" guard was SILENTLY DISABLED and the pass
  # exited 0 over a pool it could not list. Exactly the class the header names for every other
  # operand; the summary read must fail closed like them. `SLOTS` is CLEARED first so a failed read
  # cannot leave the loop's earlier count in place and be printed as if it had just been measured.
  SLOTS=""
  if ! slots; then
    cannot=$((cannot + 1))
  fi
  printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=%s ceiling=%s mem_available=%s MB floor=%s MB dry_run=%s\n' \
    "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${SLOTS:-unmeasured}" "$CEILING" "$MEM_MB" "$MEM_FLOOR_MB" "$DRY"
  # ⛔ A PASS THAT PROVISIONED NOTHING IS NOT A SUCCESS. Exit 5 is per-NAME (that is the whole point:
  # one taken name must not end the pass), so on its own it cannot report a box that could not register
  # ANYTHING — a GitHub 5xx, an expired runner scope, a full disk all arrive as the same code. When the
  # pass ended short of the ceiling with every attempt failing, that IS cannot-act. The `-n` operand
  # check is load-bearing: without it an unmeasured `SLOTS` re-opens the silent-disable above.
  if [ "$added" -eq 0 ] && [ "$failed" -gt 0 ] && [ -n "$SLOTS" ] && [ "$SLOTS" -lt "$CEILING" ]; then
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
