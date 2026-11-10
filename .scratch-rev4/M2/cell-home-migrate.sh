#!/usr/bin/env bash
# cell-home-migrate.sh — converge a cell onto ONE home (agent-infra#3453). Reports, or repoints.
#
#   ./cell-home-migrate.sh [--check]     # the DEFAULT: read everything, change nothing
#   ./cell-home-migrate.sh --apply       # copy missing credentials + repoint units, then daemon-reload
#   ./cell-home-migrate.sh --help
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────────
# A cell ran with TWO homes and the units disagreed about which one a process gets. Measured
# 2026-11-05: `eldato-orchestrator.service` — the unit that SPAWNS lanes — gave them
# `HOME=/home/cmux`, while every other cell service got `HOME=/tmp/cell-home`. `gh` resolves its
# credential `GH_TOKEN` -> `GITHUB_TOKEN` -> `$HOME/.config/gh/hosts.yml` and `git` inherits it
# through `credential.helper = !gh auth git-credential`, so the two conventions resolved two
# DIFFERENT credentials: a 17-lane wave produced **0 landings**, every `git push` answering
# `403 … X-Accepted-Github-Permissions: contents=write` while `gh` READS still worked.
#
# Changing the scripts' defaults (`scripts/lib/cell-home.sh`) does NOT converge a box that already
# has `/tmp/cell-home` baked into its unit files, its drop-ins, and its credential files. That is what
# this tool is for: an existing box must reach the one home WITHOUT losing a credential and WITHOUT
# being left with a unit that names a path that does not exist.
#
# ── THE FOUR RULES THIS TOOL HOLDS ──────────────────────────────────────────────────────────────
#  1. ⛔ IT NEVER DELETES `/tmp/cell-home`. Reclaiming it is a SEPARATE decision, taken only after
#     every unit repoints AND a lane proves `push=OK` + `provider=OK` from a clean shell with nothing
#     sourced. `--apply` prints the legacy home's size as the DEFERRED reclaim and exits.
#  2. ⛔ IT NEVER OVERWRITES A CREDENTIAL THAT ALREADY EXISTS IN THE DURABLE HOME. A copy happens only
#     when the durable side is MISSING. When both sides exist it reports BOTH (`size`/`mode`/`mtime`)
#     and leaves them alone: silently picking one is how a rotated key is rolled back. A legacy copy
#     that is NEWER than the durable one is named as a CONFLICT needing an operator decision —
#     reported, never repaired.
#  3. ⛔ IT NEVER PRINTS A SECRET. Every credential is described by path, size, mode and mtime. No
#     value is read into a variable the log could reach, and no value appears in a diff or a message.
#     The ONE exception is a NAME, never a value: `keys.env` is a SOURCEABLE shell file, so an
#     assignment in it that re-points `HOME`/`CELL_HOME` at the legacy (or any volatile) home is named
#     as drift — the variable's NAME only, never what it was set to. A copy of such a file is REFUSED
#     rather than installed: copying it would re-point every lane that sources it back into the
#     second home, i.e. undo this migration from inside the file the migration installed.
#  4. ⛔ IT NEVER WRITES A UNIT THAT WOULD NOT RUN. A repointed path is written ONLY when its
#     counterpart under the durable home EXISTS. If it does not, the file is refused BY NAME with the
#     missing target quoted — a unit that execs a path that is not there is `203/EXEC` on the next
#     restart, i.e. a migration that turned a working cell into a dead one.
#
# ── IDEMPOTENCE ─────────────────────────────────────────────────────────────────────────────────
# `--apply` twice is a no-op the second time: credentials that exist are not touched, units that name
# no legacy path are not rewritten, and a converged box reports `one home` and exits 0. The backups it
# writes are `<file>.pre-cell-home` (mode preserved, written once — never clobbered by a later run).
#
# ── EXIT CODES ──────────────────────────────────────────────────────────────────────────────────
#   0  converged — one home, nothing to do (i.e. NOT ONE unit/drop-in/credential still names the
#      legacy home. A record that `--apply` COULD repoint is drift, not convergence: `--check` gates
#      the reclaim of the legacy home, so "would be repointable" must never read as "one home")
#   1  drift found (`--check`) / something was refused or left for an operator (`--apply`)
#   3  CANNOT MEASURE — a reading this tool needs could not be taken (named on stderr), or the
#      durable home cannot be derived for the account the UNITS RUN AS (a privileged invoking account
#      derives `/root`; see `check_derivation`). Never 0: "could not read" is not "one home".
#      ⛔ THE CLASS IS ENUMERATED, NOT ASPIRATIONAL: a unit/drop-in this account cannot OPEN, a unit
#      DIR or drop-in dir whose population cannot be walked, and a legacy credential path this account
#      cannot `stat` (an unsearchable ancestor) all land here. Each of them used to read as its
#      opposite — "clear of the legacy home", or "legacy MIA" — i.e. a PASS manufactured from a read
#      that was never taken, on the number that authorises RECLAIMING the legacy home.
#   2  bad usage (an unknown argument)
#   ⛔ 3 OUTRANKS 1: if any leg could not be measured the run is CANNOT MEASURE even when another leg
#      also found drift, because "I could not look" and "I looked and it is drifted" are not the same
#      report and only the first one forbids the reclaim.
#
# ── FIXTURE SEAMS (declared, not hidden) ────────────────────────────────────────────────────────
#   CELL_HOME_MIGRATE_UNIT_DIRS   colon list of unit dirs to grade (default: the three below)
#   CELL_HOME_MIGRATE_NO_RELOAD   1 = do not call `systemctl daemon-reload` (a hermetic suite)
#   SYSTEMD_UNIT_DIR / CONTROLLER_SYSTEM_UNIT_DIR / CONTROLLER_USER_UNIT_DIR   the same seams the
#                                 bring-up and the supervisor already read
set -uo pipefail

# ⛔ THE SELF PATH COUNTS ONLY WHEN IT NAMES THIS FILE — see `lib/cell-home.sh` §CONSUMERS.
_SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""     # under `bash -s` $0 is literally `bash` -> `.`
SELF_DIR=""
if [ -n "$_SELF" ]; then SELF_DIR="$(cd "$(dirname "$_SELF")" 2>/dev/null && pwd -P)"; fi
# ⛔ WITHOUT A SELF PATH THERE IS NO SIBLING TO TRUST (review F2). There used to be a RELATIVE fallback
# here (`lib/cell-home.sh`), which is the one shape §CONSUMERS forbids: a piped start
# (`bash -s < cell-home-migrate.sh`) has no file of its own, so the fallback resolved against the
# working directory and SOURCED AND EXECUTED `$PWD/lib/cell-home.sh`. This is the tool whose own
# printed remedy is `sudo -n env CELL_HOME=… bash $0 --apply`, i.e. the one most likely to be piped by
# an operator, and `$PWD` (or `/tmp`) is the ordinary case. Refuse: 3 is the state the exit table
# already reserved for a reading this tool cannot take.
if [ -z "$SELF_DIR" ]; then
  printf '%s: FATAL: no self path (a piped start) — refusing to source a resolver from the working directory ($PWD/lib/cell-home.sh would be executed). Run the file itself: bash scripts/cell-home-migrate.sh (agent-infra#3453)\n' "${0##*/}" >&2
  exit 3
fi
CELL_HOME_LIB="$SELF_DIR/lib/cell-home.sh"
if [ ! -r "$CELL_HOME_LIB" ]; then
  printf '%s: FATAL: %s is not readable — this tool will not derive a cell home from a guess. Run pi-bootstrap/setup.sh (its lib farm places the resolver) (agent-infra#3453)\n' "${0##*/}" "$CELL_HOME_LIB" >&2
  exit 3
fi
# shellcheck source=lib/cell-home.sh
. "$CELL_HOME_LIB"

MODE="--check"
for a in "$@"; do
  case "$a" in
    --check|--dry-run) MODE="--check" ;;
    --apply) MODE="--apply" ;;
    -h|--help) MODE="--help" ;;
    *) printf '%s: unknown argument %s (--check | --apply | --help)\n' "${0##*/}" "$a" >&2; exit 2 ;;
  esac
done
if [ "$MODE" = "--help" ]; then sed -n '2,12p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0; fi

HOME_DURABLE_GIVEN=0
[ -n "${CELL_HOME:-}" ] && HOME_DURABLE_GIVEN=1
HOME_DURABLE="$(cell_home_resolve)"
# ⛔ NORMALISED HERE, ONCE (review cycle-5 #2, measured). `cell_home_resolve` step 1 returns an explicit
# `CELL_HOME` VERBATIM and does not second-guess an operator, so `CELL_HOME=/home/cmux/` produced
# `HOME_DURABLE=/home/cmux/` — and this value is CONCATENATED (`.config/systemd/user`, and the projector's
# `$home$rest`), so `--apply` wrote `Environment=HOME=/home/cmux//x` into unit files, and the user-unit
# population listed one directory twice under two spellings (the `awk` dedupe cannot collapse two
# different strings). One strip here fixes every consumer; `/` itself must survive as `/`, never as "".
HOME_DURABLE="${HOME_DURABLE%/}"; [ -n "$HOME_DURABLE" ] || HOME_DURABLE=/
HOME_LEGACY="$CELL_HOME_LEGACY"
INVOKER_UID="$(id -u 2>/dev/null || printf '1')"
INVOKER="$(id -un 2>/dev/null || printf '?')"

# The unit directories, in the order the installers try them — the same read-side seams the bring-up
# and the supervisor use, so "which units this tool grades" cannot drift from "which units exist".
# ⛔ THE USER DIR COMES FROM THE HOME THIS TOOL ACTED ON, NOT FROM THE INVOKING SHELL'S `$HOME`
# (review F1, reproduced). It used to be `${HOME:+$HOME/.config/systemd/user}`, and NOTHING in this
# tool ever consulted `$HOME_DURABLE` — so the population was whatever the invoker's `$HOME` made it.
# Measured: ONE byte-identical legacy-naming unit under `$HOME_DURABLE/.config/systemd/user` answered
# `RC=0 VERDICT: one home` when the invoking `HOME` was elsewhere, and `RC=1 drift` when it was not.
# The two channels that reach this are the ones this project names itself — `cmux vm exec`
# (`HOME=/home/ubuntu`) and this tool's own printed root remedy — and the dir is real:
# `install-harness-apply-timer.sh` writes `UNIT_DIR="$HOME/.config/systemd/user"`.
# ⛔ AND `$HOME`'s DIR IS KEPT AS AN ADDITIONAL CANDIDATE when it differs: a unit really can live
# there, and this tool grades what systemd loads.
unit_dirs() {
  if [ -n "${CELL_HOME_MIGRATE_UNIT_DIRS:-}" ]; then
    printf '%s' "$CELL_HOME_MIGRATE_UNIT_DIRS" | tr ':' '\n'
    return 0
  fi
  local d
  # ⛔ `${HOME:+.config/…}`, NOT `${HOME:-}/.config/…` (review FOLLOW-UP 2): with `HOME` unset the `:-`
  # form yields the ABSOLUTE `/.config/systemd/user`, a directory nobody has, which then enters the
  # population walk as if an installer had chosen it. `:+` yields the empty string and the `[ -n "$d" ]`
  # filter below drops it — the same spelling `reap-abandoned-worktrees.sh` already uses for this hazard.
  {
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}"; do
      [ -n "$d" ] && printf '%s\n' "${d%/}"
    done
    if [ -n "${CONTROLLER_USER_UNIT_DIR:-}" ]; then
      printf '%s\n' "${CONTROLLER_USER_UNIT_DIR%/}"
    else
      [ -n "${HOME_DURABLE:-}" ] && printf '%s\n' "$HOME_DURABLE/.config/systemd/user"
      # ⛔ THE COMPARISON NO LONGER NEEDS `${HOME_DURABLE%/}` HERE: `HOME_DURABLE` is normalised once at
      # the top of the script (review cycle-5 #2). This line was ALSO the precedent the harness pass cites
      # as "the sibling tool already normalises", which was half true — it stripped `HOME` only.
      [ -n "${HOME:-}" ] && [ "${HOME%/}" != "$HOME_DURABLE" ] && printf '%s\n' "${HOME%/}/.config/systemd/user"
    fi
  } | awk 'NF && !s[$0]++'
}

# walkable_dir <dir> — 0 WALK IT, 1 ABSENT (a measurable reading: nothing was installed here),
# 3 CANNOT MEASURE. ⛔ `[ -d "$d" ] || continue` READ AS "ABSENT" FOR "I WAS NOT ALLOWED TO LOOK" (review
# F1): an ancestor that exists and denies this account search makes `-d` answer false, so the dir left
# the population with no record at all and the box read "clear of the legacy home". That is the same
# false PASS the file's `probe_open` / `cannot_traverse` pair removes one level down, applied to the DIR
# — and it matters most for the durable home's user-unit dir, which is the population review F1 is about.
walkable_dir() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  if [ -d "$d" ]; then
    [ -x "$d" ] && return 0
    return 3
  fi
  cannot_traverse "$d" && return 3
  return 1
}

# ── CREDENTIALS ────────────────────────────────────────────────────────────────────────────────
# The files a lane's provider/`gh`/`git` resolution actually reads. Each is described, never shown.
# `keys.env` is the cell's pushed env (HOME/CELL_HOME + provider keys); `auth.json` is pi's credential
# store; `hosts.yml` is `gh`'s token source, which `git` reuses via the credential helper.
# ⛔ `pi-keys.env` IS A CREDENTIAL THE FLEET READS, and this list must contain it (review F3). The
# launch line sources `$home/keys.env` AND `$home/pi-keys.env` (`orchestrator-harness/worker-terminal.sh`,
# and `key-gate.sh` names `${home}/pi-keys.env` as a credential location) — this file's OWN notes below
# say so. Leaving it out meant `--check` answered 0 (the RECLAIM precondition) while the only copy of the
# model credential sat in the legacy home: the operator deletes it. A per-name list will always lag the
# fleet — see `legacy_home_advisory` for the general mitigation.
# ⛔ ONE NAME PER LINE: every consumer reads it with `while IFS= read -r rel; do … done <<EOF $CRED_FILES`,
# so a space-separated list would be read as ONE name. The advisory matches by iterating this variable
# (not by `case`), which is why it does not need a space-delimited form (review F5 round 4).
CRED_FILES="keys.env
pi-keys.env
.pi/agent/auth.json
.config/gh/hosts.yml"

# ⛔ THE ONE CREDENTIAL THAT IS ALSO A PROGRAM. `keys.env` is SOURCED as shell by the very processes this
# migration converges (`cloud-cell-supervisor.sh` sources it under `set -a`; `orchestrator-harness/lane-env.sh`
# too), so a `HOME=`/`CELL_HOME=` assignment inside it is not a comment — it re-selects the home of every
# lane that reads it, including one that puts them back in the legacy home. The copy below is
# byte-for-byte (rule 3 forbids reading values), so a poisoned file would be installed faithfully; it is
# therefore GRADED by assignment NAME, REPORTED by `--check` and REFUSED as a copy. Nothing is repaired
# here (rule 2), and no value is ever printed (rule 3).
# ⛔ THE SAME SET DECIDES CONTENT GRADING (review F1 round 4). `CRED_FILES` gives a file PRESENCE
# treatment (copy when missing); `ENV_FILES` is what gets its ASSIGNMENTS graded and refuses a copy that
# re-points the home. `pi-keys.env` was added to the first and not the second, so a legacy-only copy that
# said `export HOME=<legacy>` was installed into the durable home and the box certified "one home" — the
# exact case rule 2/3 in the header forbids, on the file the round before added for being fleet-sourced
# (`orchestrator-harness/worker-terminal.sh` does `set -a; . "$home/pi-keys.env"`). One set, both jobs.
# ⛔ SPACE-SEPARATED, because every consumer tests it as `case " $ENV_FILES " in *" $rel "*)` — a newline
# between the names would leave neither name with a blank on both sides and silently grade nothing.
ENV_FILES="keys.env pi-keys.env"

note() { printf '%s\n' "$*"; }
warn_line() { printf 'WARN %s\n' "$*"; }

# volatile_home_assignments <file> — the NAMES (HOME, CELL_HOME) of assignments in a sourceable env file
# whose value is ABSOLUTE, is NOT the durable home, and sits under a volatile root. ⛔ IT NEVER PRINTS A
# VALUE: the caller learns which variable was re-pointed, never what it was set to. Only the shapes such
# a file really carries are parsed (leading blanks, `export `, one layer of quotes).
volatile_home_assignments() {
  local f="$1"
  [ -r "$f" ] || return 0
  awk -v dur="$HOME_DURABLE" -v vol="$CELL_HOME_VOLATILE_ROOTS" -v leg="$HOME_LEGACY" '
    BEGIN { n = split(vol, roots, ":") }
    {
      line = $0
      if (line ~ /^[[:space:]]*#/) next
      # ⛔ GRADE BY VALUE, NOT ONLY BY THE TWO NAMES (review F3 round 5). `HOME`/`CELL_HOME` are not the
      # only assignments that re-select the home: the fleet sources its credential THROUGH `ENV_FILE`
      # (`orchestrator-harness/lane-env.sh`, `cloud-cell-supervisor.sh`, `install-repair-service.sh`), so
      # a durable `keys.env` carrying `ENV_FILE=<legacy>/keys.env` re-installs the split from inside the
      # file this migration installed — and the name allow-list read it as "one home" on the number that
      # authorises the reclaim. The rule this file already states about populations applies here too: a
      # per-name list always lags the fleet.
      if (!match(line, /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/)) next
      name = substr(line, RSTART, RLENGTH)
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", name)
      sub(/=$/, "", name)
      val = substr(line, RLENGTH + 1)
      gsub(/^[[:space:]]+/, "", val); gsub(/[[:space:]]+$/, "", val)
      gsub(/^["\047]/, "", val); gsub(/["\047]$/, "", val)
      if (val == "" || val == dur) next
      if (substr(val, 1, 1) != "/") next
      # (a) ANY name whose value points INTO the legacy home is the split, whatever it is called.
      if (leg != "" && (val == leg || index(val, leg "/") == 1)) { if (!seen[name]++) print name; next }
      # (b) HOME/CELL_HOME additionally catch any other VOLATILE root (they decide the home itself).
      if (name != "HOME" && name != "CELL_HOME") next
      for (i = 1; i <= n; i++) {
        r = roots[i]
        if (r == "") continue
        if (val == r || index(val, r "/") == 1) { if (!seen[name]++) print name; next }
      }
    }' "$f" 2>/dev/null
}

# report_env_file <rel> <path> <what> — 1 (naming the VARIABLE, never the value) when a sourceable env
# file re-points HOME/CELL_HOME at a volatile home that is not the durable one; 3 when this account
# could not OPEN the file at all (a reading that was never taken is not "no assignments").
report_env_file() {
  local rel="$1" f="$2" what="$3" names
  # ⛔ A REAL OPEN, AND AN UNREADABLE FILE IS NOT "NAMES NO VOLATILE HOME" (review F2).
  # `volatile_home_assignments`'s own `[ -r "$f" ] || return 0` printed nothing for a file this account
  # cannot read, and an empty answer is indistinguishable from a converged one: a DURABLE `keys.env`
  # that re-pointed HOME/CELL_HOME at the legacy home therefore read as clean, `--check` answered 0 (the
  # number that authorises RECLAIMING the legacy home) and `--apply` reported the poisoned copy as
  # "kept". `[ -r ]` is also permission BITS rather than a reading, so it would call unreadable a file
  # root can read (root holds DAC_OVERRIDE) — `probe_open` is the open itself.
  if [ -e "$f" ] && ! probe_open "$f"; then
    warn_line "  CANNOT MEASURE: $rel — $what at $f cannot be opened by $INVOKER (mode $(mode_of "$f")), so 'it assigns no volatile home' is not a reading this tool took"
    return 3
  fi
  names="$(volatile_home_assignments "$f")"
  [ -n "$names" ] || return 0
  warn_line "  $rel: $what ASSIGNS $(printf '%s ' $names)to a home that is NOT $HOME_DURABLE — a lane that sources this file is put back into the volatile/legacy home. The VALUE is not printed (rule 3); inspect $f by hand. This tool never repairs a credential."
  return 1
}

# describe <path> — "<size>/<mode>/<mtime>" or MISSING. Never the contents; never a value.
describe() {
  local f="$1"
  [ -e "$f" ] || { printf 'MISSING'; return 0; }
  # `stat` differs between GNU and BSD; these two formats are all this needs. ⛔ THE TWO ARMS ARE ONE
  # LOGICAL LINE ON PURPOSE: `check-portability-traps.sh` grades a GUARDED CHAIN by COMMAND UNIT, where
  # `||` stays inside the unit and a `\`-continuation does not — so a chain split across lines reads as
  # a bare GNU-only call and reds the portability gate. Written this way it IS the portable idiom the
  # detector's header promises is clean, and it stays portable rather than baselined.
  stat -c '%s bytes mode=%a mtime=%Y' "$f" 2>/dev/null || stat -f '%z bytes mode=%Lp mtime=%m' "$f" 2>/dev/null || printf 'present'
}
mtime_of() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || printf '0'; }
mode_of()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf ''; }

# durable_state <path> — 0 PRESENT, 1 ABSENT (a measurable reading), 3 CANNOT MEASURE (an ancestor
# denies search, or the file cannot be opened). ⛔ THE DURABLE SIDE NEEDS THE SAME THREE-VALUED READ THE
# LEGACY SIDE HAS (review F6): `[ -e "$f_dur" ]` answers "absent" for "I was not allowed to look", so a
# durable home whose entries this account cannot search reported every credential as `durable MISSING`
# — and with the legacy home already empty (the post-reclaim shape) `--check` answered 0, a PASS over
# credentials it never stat'ed. A path whose parent is genuinely absent is ABSENT, never unmeasurable
# (`cannot_traverse` draws that line and walks upward past levels that do not resolve).
durable_state() {
  local p="$1"
  if [ -e "$p" ]; then
    probe_open "$p" || return 3
    return 0
  fi
  cannot_traverse "$p" && return 3
  return 1
}

# owner_of <path> — "uid:gid" of an existing path, or nothing. Used so a ROOT run does not leave the
# cell's credentials (or a rewritten unit) owned by root: `install`/`mv` otherwise stamp the invoker,
# and the cell account then cannot read the credential this tool exists to make readable (review F7).
owner_of() {
  stat -c '%u:%g' "$1" 2>/dev/null || stat -f '%u:%g' "$1" 2>/dev/null || printf ''
}

# make_owned_dir <dir> — `mkdir -p`, and (as root) re-own EVERY level this call CREATED. ⛔ `mkdir -p`
# can create several components; re-owning only the leaf left `<durable>/.pi` as `root:root 0700` with an
# owned credential inside it, unreachable for the cell account, while the run printed "one home" (review
# F1 round 5). `chown` on a level that already existed is deliberately NOT done: the operator's own
# directories are not this tool's to re-own.
make_owned_dir() {
  local target="$1" d created=""
  [ -n "$target" ] || return 1
  d="$target"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -d "$d" ]; do created="$d${created:+
}$created"; d="$(dirname "$d")"; done
  mkdir -p "$target" 2>/dev/null || return 1
  [ "$INVOKER_UID" = 0 ] || return 0
  [ -n "${DUR_OWNER:-}" ] || return 0
  [ -n "$created" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    chown "$DUR_OWNER" "$d" 2>/dev/null || return 3
  done <<EOF
$created
EOF
  return 0
}

# probe_open <file> — 0 iff this account can actually OPEN the file. ⛔ A REAL OPEN, NOT `[ -r ]`:
# `[ -r ]` reads PERMISSION BITS, so it answers 1 for a mode-000 file even for an account that can read
# it (root holds DAC_OVERRIDE) — the tool would then refuse a reading it actually takes, and print a
# reason that is false for the identity that ran it. The open IS the measurement, so the message a
# caller prints is true whoever invoked it.
probe_open() { ( : <"$1" ) 2>/dev/null; }

# cannot_traverse <path> — 0 iff an ANCESTOR directory exists but denies this account search, so
# `[ -e <path> ]` cannot tell "absent" from "could not look". A path whose parent does not exist is
# ABSENT (a measurable reading: nothing to converge), never unmeasurable.
cannot_traverse() {
  local d
  d="$(dirname "$1")"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    # ⛔ AN ANCESTOR THAT DOES NOT RESOLVE IS NOT PROOF OF ABSENCE — when traversal is denied the
    # whole tail of the path resolves to nothing, so the walk CARRIES ON UPWARD looking for a directory
    # it can see and is not allowed to search. Stopping at the first unresolvable level reported
    # `$LEGACY/.pi/agent/auth.json` as "legacy MIA" on exactly the box this guard exists for (measured:
    # a mode-000 legacy home, `k9b`).
    if [ -e "$d" ] && [ ! -x "$d" ]; then return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# durable_state needs `probe_open` and `cannot_traverse`, both defined below in this same header block;
# bash resolves them at CALL time, and every call site is inside the credential legs further down.

# credential_conflict <legacy> <durable> — 0 iff BOTH copies exist and the LEGACY one is NEWER.
# ⛔ ONE PREDICATE, TWO MODES (review F1). `--check` and `--apply` disagreed about the same box: the
# migration set `rc=1` on a divergence and the check only PRINTED the warning, so `--check` answered
# "one home — nothing to do" over a box whose legacy credential was NEWER than the durable one. That is
# the dangerous direction — `--check` -> 0 is the stated precondition for RECLAIMING `/tmp/cell-home`,
# so the quiet half told an operator to delete the only copy of a rotated key. The two modes cannot
# disagree again because there is only one place that decides it.
credential_conflict() {
  local f_leg="$1" f_dur="$2"
  [ -e "$f_leg" ] && [ -e "$f_dur" ] || return 1
  [ "$(mtime_of "$f_leg")" -gt "$(mtime_of "$f_dur")" ]
}

check_credentials() {
  local rel f_leg f_dur rc=0 unmeas=0 st
  note "credentials (durable=$HOME_DURABLE legacy=$HOME_LEGACY)"
  [ -d "$HOME_LEGACY" ] || note "  legacy home is absent — nothing to converge (this box is already on one home)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f_leg="$HOME_LEGACY/$rel"
    f_dur="$HOME_DURABLE/$rel"
    # ⛔ THE CONTENT LEG RUNS FIRST AND INDEPENDENT OF THE LEGACY SIDE. The DURABLE file is what lanes
    # SOURCE, so a re-pointing assignment in it is drift whether or not a legacy copy still exists —
    # the legacy home is reclaimed later, and this check must not disappear with it. Names only, never
    # a value. ⛔ AND ITS OWN READ FAILURE IS CANNOT MEASURE (review F2), not "no assignments": 3 outranks
    # the ordinary drift this arm would otherwise report.
    case " $ENV_FILES " in
      *" $rel "*)
        durable_state "$f_dur"; st=$?
        if [ "$st" = 3 ]; then
          warn_line "  CANNOT MEASURE: $rel — the durable path $f_dur cannot be measured by $INVOKER (a parent directory denies search, or the file cannot be opened), so 'it assigns no volatile home' is not a reading this tool took"
          unmeas=1
        elif [ "$st" = 0 ]; then
          report_env_file "$rel" "$f_dur" "the DURABLE copy"; st=$?
          [ "$st" = 3 ] && unmeas=1
          [ "$st" = 1 ] && rc=1
        fi ;;
    esac
    # ⛔ AN UNSEARCHABLE DURABLE PATH IS NOT "DURABLE MISSING" (review F6) — see `durable_state`.
    durable_state "$f_dur"; st=$?
    if [ "$st" = 3 ]; then
      warn_line "  CANNOT MEASURE: $rel — the durable path $f_dur cannot be measured by $INVOKER (a parent directory denies search), so 'durable is missing' is not a reading this tool took"
      unmeas=1; continue
    fi
    if [ ! -e "$f_leg" ]; then
      # ⛔ AN UNSEARCHABLE LEGACY PATH IS NOT "LEGACY MIA" (review F1). `[ ! -e "$f_leg" ]` is the same
      # answer for "the file is gone" and for "I was not allowed to look" — and the second one read as
      # "nothing to converge" on exactly the box this fails on: a root-owned 0700 legacy home under a
      # non-root `--check`. The durable side then looks converged and `--check` reaches 0 over a
      # credential it never measured, on the number that authorises reclaiming that very directory.
      # ⛔ AND IT IS ASKED HERE, NOT ABOVE THE CONTENT LEG: the durable file is what lanes SOURCE, so it
      # is graded whether or not the legacy side can be seen (the leg's own rule, one screen up). Placed
      # above, the guard `continue`d past that grading and stopped measuring the one file that can put
      # every lane back into the second home — found in self-review, pinned by `k9c`.
      if cannot_traverse "$f_leg"; then
        warn_line "  CANNOT MEASURE: $rel — a legacy path this account cannot look inside ($f_leg; a parent directory denies search to $INVOKER), so 'no legacy credential here' is not a reading this tool took"
        unmeas=1
        continue
      fi
      note "  $rel: legacy MIA, durable $(describe "$f_dur")"
      continue
    fi
    if [ ! -e "$f_dur" ]; then
      note "  $rel: legacy $(describe "$f_leg") -> durable MISSING (a copy is what --apply does)"
      rc=1
      # The copy would install the legacy file's ASSIGNMENTS too, so say so now rather than letting the
      # operator meet the refusal in `--apply` with no advance notice.
      case " $ENV_FILES " in *" $rel "*) report_env_file "$rel" "$f_leg" "the LEGACY copy --apply would install"; st=$?; [ "$st" = 3 ] && unmeas=1 ;; esac
      continue
    fi
    note "  $rel: legacy $(describe "$f_leg") | durable $(describe "$f_dur")"
    # BOTH PRESENT. Never overwrite either one. If the legacy copy is NEWER that is a real hazard a
    # human has to settle — a rotated key on the legacy side would otherwise look converged.
    # ⛔ AND IT IS DRIFT, NOT A FOOTNOTE: the same predicate `--apply` uses, with `rc=1` here too, so the
    # two modes answer the same box the same way (review F1).
    if credential_conflict "$f_leg" "$f_dur"; then
      warn_line "  $rel: the LEGACY copy is NEWER than the durable one — the two homes have diverged. This tool will not pick a winner (that would silently roll back a rotation). Inspect both by hand (compare mtimes, then move the intended one into $HOME_DURABLE), then re-run."
      rc=1
    fi
  done <<EOF
$CRED_FILES
EOF
  if [ "$unmeas" = 1 ]; then return 3; fi      # ⛔ 3 outranks 1 — see the exit-code table
  return "$rc"
}

# The credential copy. Only when the durable side is MISSING; mode preserved from the source and
# clamped to 600 for the two secret stores; contents never read, never echoed, never in argv.
migrate_credentials() {
  local rel f_leg f_dur rc=0 unmeas=0 st mode
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f_leg="$HOME_LEGACY/$rel"
    f_dur="$HOME_DURABLE/$rel"
    # ⛔ THE CONTENT LEG RUNS FIRST AND INDEPENDENT OF THE LEGACY SIDE — same reason as `--check`: the
    # durable file is what lanes source, and the legacy home is reclaimed later, so this report must not
    # vanish with it (and the two modes must not disagree about the same box).
    case " $ENV_FILES " in
      *" $rel "*)
        durable_state "$f_dur"; st=$?
        if [ "$st" = 3 ]; then
          warn_line "  CANNOT MEASURE: $rel — the durable path $f_dur cannot be measured by $INVOKER (a parent directory denies search, or the file cannot be opened), so 'it assigns no volatile home' is not a reading this tool took"
          unmeas=1
        elif [ "$st" = 0 ]; then
          report_env_file "$rel" "$f_dur" "the DURABLE copy"; st=$?
          [ "$st" = 3 ] && unmeas=1
          [ "$st" = 1 ] && rc=1
        fi ;;
    esac
    # ⛔ AN UNSEARCHABLE DURABLE PATH IS NOT "DURABLE MISSING" (review F6) — the two modes must agree.
    durable_state "$f_dur"; st=$?
    if [ "$st" = 3 ]; then
      warn_line "  CANNOT MEASURE: $rel — the durable path $f_dur cannot be measured by $INVOKER (a parent directory denies search), so 'durable is missing' is not a reading this tool took; nothing was copied and nothing was ruled out"
      unmeas=1; continue
    fi
    if [ ! -e "$f_leg" ]; then
      # ⛔ THE SAME UNMEASURABLE LEG AS `--check`, IN THE SAME PLACE — below the durable-side content leg,
      # so the two modes agree about one box (the lesson of the previous round's F1) without either of
      # them skipping the file lanes actually source: "nothing to copy" and "I could not look" are
      # different answers, and only one of them means the credential half converged.
      if cannot_traverse "$f_leg"; then
        warn_line "  CANNOT MEASURE: $rel — a legacy path this account cannot look inside ($f_leg; a parent directory denies search to $INVOKER); nothing was copied and nothing was ruled out"
        unmeas=1
      fi
      continue
    fi
    if [ -e "$f_dur" ]; then
      note "  kept   $rel (durable copy exists — never overwritten)"
      # ⛔ THE SAME DIVERGENCE WARNING THE CHECK EMITS, EMITTED HERE TOO. `--apply` is the mode where a
      # silent "kept" would read as convergence: if the LEGACY copy is newer, the two homes have
      # diverged and picking either one is an operator's decision, not this tool's. The test is
      # `credential_conflict`, the ONE place that decides it — the check calls it too.
      if credential_conflict "$f_leg" "$f_dur"; then
        warn_line "  $rel: the LEGACY copy is NEWER than the durable one — the two homes have diverged. Nothing was written (a rotation would otherwise be rolled back). Inspect both by hand, then re-run."
        rc=1
      fi
      continue
    fi
    mode="$(mode_of "$f_leg")"
    case "$rel" in
      keys.env|pi-keys.env|.pi/agent/auth.json|.config/gh/hosts.yml) mode=600 ;;
      *) [ -n "$mode" ] || mode=600 ;;
    esac
    # ⛔ A COPY OF A FILE THAT RE-POINTS THE HOME IS NOT CONVERGENCE, IT IS THE SPLIT RE-INSTALLED.
    # Named-and-refused rather than repaired: rule 2 says a credential is never rewritten, and rule 3
    # says its value is never read — so the tool reports WHICH variable is wrong and stops. The durable
    # side stays MISSING deliberately: a missing credential a lane reports is safer than one that
    # silently moves every lane back into the home this migration exists to leave.
    case " $ENV_FILES " in
      *" $rel "*)
        report_env_file "$rel" "$f_leg" "the copy is REFUSED: the LEGACY file"; st=$?
        if [ "$st" = 3 ]; then unmeas=1; continue; fi
        if [ "$st" = 1 ]; then
          warn_line "  REFUSED $rel — not copied (edit $f_leg so it names $HOME_DURABLE, then re-run)"
          rc=1; continue
        fi ;;
    esac
    # ⛔ `mkdir -p` CAN CREATE SEVERAL LEVELS AND ONLY THE LEAF WAS RE-OWNED (review F1 round 5): a root
    # run under `umask 077` left `<durable>/.pi` as `root:root 0700` with a correctly-owned
    # `.pi/agent/auth.json` inside — the cell account cannot traverse to it — and the run printed
    # "one home". `make_owned_dir` records which levels it created and re-owns each one.
    if ! make_owned_dir "$(dirname "$f_dur")"; then
      warn_line "  cannot create or own $(dirname "$f_dur") — $rel NOT copied"
      rc=1; continue
    fi
    # `install` copies bytes without ever putting them in this process's stdout; -m sets the mode in
    # the same syscall, so the file is never momentarily world-readable.
    if install -m "$mode" "$f_leg" "$f_dur" 2>/dev/null; then
      # ⛔ A ROOT RUN MUST NOT LEAVE THE CELL'S CREDENTIAL OWNED BY ROOT (review F7). `install` stamps the
      # invoker, and one of this tool's own remedies is `sudo -n env CELL_HOME=… bash $0 --apply`; the
      # cell account must still be able to READ what this migration exists to make readable, and a later
      # run would otherwise report the root-owned file as `kept`. The durable home's owner is the answer.
      # ⛔ AND A chown THAT FAILS IS REPORTED, NOT SWALLOWED (review F4): a root run whose ownership fix
      # fails still says "copied …" and the cell account cannot read it — verbatim the failure this fix
      # exists to prevent — so it is a WARN and a non-zero rc.
      if [ "$INVOKER_UID" = 0 ] && [ -n "${DUR_OWNER:-}" ]; then
        if ! chown "$DUR_OWNER" "$f_dur" 2>/dev/null; then
          warn_line "  $rel: WRITTEN BUT NOT RE-OWNED — $f_dur is owned by $(owner_of "$f_dur" || printf '?') instead of $DUR_OWNER, so $INVOKER's account may not be able to read it"
          rc=1
        fi
      fi
      note "  copied $rel -> $f_dur (mode $mode; value not printed)"
    else
      warn_line "  COPY FAILED for $rel (from $f_leg) — refused rather than left half-written"
      rc=1
    fi
  done <<EOF
$CRED_FILES
EOF
  if [ "$unmeas" = 1 ]; then return 3; fi      # ⛔ 3 outranks 1 — see the exit-code table
  return "$rc"
}

# ── UNITS ─────────────────────────────────────────────────────────────────────────────────────
# The directives whose values this tool will re-base. Anything ELSE that names the legacy home is
# reported UNHANDLED (and makes the run non-converged) rather than silently left behind: a unit is a
# file on disk that a restart reads, so "I did not recognise that line" must never read as "fine".
UNIT_DIRECTIVES='Environment|EnvironmentFile|ExecStart|ExecStartPre|ExecStartPost|ExecStop|ExecStopPost|ExecReload|WorkingDirectory|RootDirectory|ReadWritePaths|ReadOnlyPaths|StandardOutput|StandardError|LogsDirectory|StateDirectory|CacheDirectory|RuntimeDirectory'

# is_comment <line> — 0 iff systemd would IGNORE the line. `systemd.syntax(7)`: "Empty lines and lines
# beginning with `#` or `;` are ignored as comments." ⛔ ONE ANSWER, TWO CALLERS: the scanner must not
# grade a comment, and the writer must not rewrite one — the writer used to pass EVERY line through the
# projector while the scanner skipped `#`, so an operator's measured history was silently edited (and
# made to read as a FALSE statement about the past).
is_comment() {
  local l="${1:-}"
  while :; do
    case "$l" in
      [[:space:]]*) l="${l#?}" ;;
      *) break ;;
    esac
  done
  case "$l" in ''|'#'*|';'*) return 0 ;; esac
  return 1
}

# paths_in <line> <directive> — every absolute path token in a directive line, as
# "<need>\t<path>", where need is 1 (must exist), 2 (its PARENT must exist) or 3 (may be absent — the
# unit's own `-` prefix said so). ⛔ BOTH CALL SITES PASS THE DIRECTIVE, and they must: the EXISTENCE grade
# depends on it (`-` and `Standard*=` differ per directive), while the membership question ("was this
# token already on the line") ignores it for everything but completeness. Omitting it is not a supported
# shape — a tokens-only call grades every token as mandatory, so restoring that form would silently
# re-break the optional-target arms.
# ⛔ THE SEPARATOR SET IS THE PROJECTOR'S TOKEN-START SET (review F2 round 5): `=`, whitespace, quotes,
# `,`, `;`, `:` and the shell metacharacters `>`, `<`, `|`, `&`, `(`. A `:` matters because
# `Environment=PATH=/a/bin:/usr/bin` is a PATH LIST (measured: a `:`-less split produced one token that
# exists as nothing, so EVERY real unit was refused). The metacharacters matter because the projector now
# MOVES `>>$LEG/log` — and without them here the token did not start with `/`, was filtered out, the
# `miss` list stayed empty, and `--apply` wrote a unit whose target does not exist (rule 4).
# ⛔ AND A REDIRECT TARGET IS NOT AN EXECUTABLE: `>`, `<` mark a path the SHELL creates, so what must
# exist is its PARENT DIRECTORY (`need=2`), not the file. Requiring the file refused every real redirect;
# requiring nothing would write a unit that cannot start. A `|` / `(` target IS a command (`need=1`).
paths_in() {
  printf '%s' "$1" | awk -v dir="${2:-}" '
    BEGIN { seps = " \t\"\047;,=:|&<>()" }
    {
      line = $0; cur = ""; prev = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (index(seps, c) > 0) {
          if (cur != "") { emit(prev, cur); cur = "" }
          prev = c
        } else { cur = cur c }
      }
      if (cur != "") emit(prev, cur)
    }
    function emit(sep, tok,   need, dash) {
      # ⛔ A systemd EXEC PREFIX RUN BELONGS TO THE TOKEN (review P1, reproduced). `systemd.service(5)`
      # Table 2: `@`, `-`, `:`, `+`, `!` (and `!!`) may prefix an executable path, and `-` is also a
      # documented per-item prefix for `WorkingDirectory=`, `EnvironmentFile=` and `ReadWritePaths=`.
      # The PROJECTOR moves a prefixed path (lib `cell_home_project_line` strips the run before its
      # token-start test), so a prefixed token DROPPED here is repointed without its durable counterpart
      # ever being graded: `--apply` wrote `ExecStart=+<durable>/run.sh` for a missing target, printed
      # `VERDICT: one home — nothing to do` and exited 0 — and that 0 is the stated RECLAIM precondition.
      # The identical line WITHOUT the prefix was correctly refused, so the hole was the prefix only.
      # ⛔ BUT `-` IS NOT DECORATION, AND STRIPPING IT IS NOT THE SAME AS GRADING IT AS MANDATORY
      # (review P1-1, reproduced). On `EnvironmentFile=`, `ReadWritePaths=`/`ReadOnlyPaths=`,
      # `WorkingDirectory=` a leading `-` means "ignore if it does not exist" (`systemd.exec(5)`, the
      # per-item prefix clause), so a rewrite that leaves such a target absent produces a unit that
      # STARTS — and the repair of the strip above refused every one of them. The refusal then makes the
      # file un-repointable, so `--check` can never reach 0: the RECLAIM precondition becomes permanently
      # unreachable for a unit that is fine. On `ExecStart*` the same `-` means only "this exit status is
      # not fatal" and the binary MUST exist, so a blanket exemption would be wrong in the other
      # direction — hence the directive is consulted. need=3 is that third state.
      # ⛔ THE FAMILY IS THE DIRECTIVES THIS TOOL ACTUALLY GRADES **AND** THAT DOCUMENT `-` FOR A PATH
      # (review A/B on the cycle-2 head, measured with `systemd-analyze verify`). The first cut listed
      # `RootDirectory=`/`RootImage=` — systemd does NOT document a `-` prefix for them, and an absolute
      # `RootDirectory=-/x` is a FATAL configuration error ("path is not absolute", unit will not start),
      # so exempting them let the tool write exactly the unrunnable unit rule 4 forbids and still exit 0.
      # It also listed `BindPaths=`/`BindReadOnlyPaths=`/`BindDirectories=`, which are absent from
      # `UNIT_DIRECTIVES` (and `BindDirectories=` is not a systemd directive at all), so they could never
      # reach this test: the claim was unreachable coverage, which reads as protection that does not exist.
      dash = 0
      while (substr(tok, 1, 1) ~ /[-+!@]/) {
        if (substr(tok, 1, 1) == "-") dash = 1
        tok = substr(tok, 2)
      }
      if (substr(tok, 1, 1) != "/") return
      if (sep == ">" || sep == "<") need = 2
      else need = 1
      if (dash && dir ~ /^(EnvironmentFile|WorkingDirectory|ReadWritePaths|ReadOnlyPaths)$/) need = 3
      # ⛔ `StandardOutput=`/`StandardError=` NAMED FILES ARE CREATED BY SYSTEMD (review P2, measured):
      # `file:`/`append:`/`truncate:` open-or-create, so the FILE need not exist while its PARENT must —
      # refusing on the file was the same false block, one directive family over. (`StandardInput=` is not
      # in `UNIT_DIRECTIVES`, so it cannot reach here and is deliberately not listed.)
      if (dir ~ /^(StandardOutput|StandardError)$/) need = 2
      # ⛔ THE STRICTEST GRADE PER TOKEN WINS, NOT THE FIRST (review cycle-9 #5, measured). The dedupe used
      # to be first-mention-wins, which was harmless while a token had one spelling. Stripping the exec
      # prefix ended that: `ReadWritePaths=-/x /x` now reaches here as the SAME token twice — once as an
      # optional (`need=3`) and once as a mandatory (`need=1`) path — and first-mention-wins graded it
      # OPTIONAL, so a rewrite could leave a path absent that the unit also names mandatorily. That is a
      # fail-open on the rule-4/`--check`->0 surface this tool exists to protect. `needmin` keeps the
      # smallest number (1 = must exist is the strictest) for a token seen more than once; the emission
      # order stays first-mention, so callers see the same sequence.
      if (!(tok in needmin)) { order[++n] = tok; needmin[tok] = need }
      else if (need < needmin[tok]) needmin[tok] = need
    }
    END { for (i = 1; i <= n; i++) printf "%d\t%s\n", needmin[order[i]], order[i] }
    '
}

# ⛔ `paths_in` NEEDS THE DIRECTIVE, NOT JUST THE LINE: the `-` and `Standard*` rules above are
# directive-specific, and a token alone cannot carry that fact. ⛔ BOTH CALL SITES PASS IT (`orig_paths`
# and the projected grade); there is no tokens-only caller, and adding one would silently grade every
# token as mandatory — re-breaking the optional-target arms. See the contract in `paths_in`'s own header.

# unit_scan <file> — one record per DIRECTIVE line that carries the legacy home:
#   "<lineno>\t<directive>\t<projected-line>\t<missing-targets>"
# <projected-line> is the line with every BOUNDARY-ANCHORED `$HOME_LEGACY` component re-based onto
# `$HOME_DURABLE` — by `cell_home_project_line`, the lib's one projection rule (a sibling such as
# `/tmp/cell-home.bak` is NOT this home; a naive replace re-based it to a path nobody has).
# <missing-targets> is a space-separated list of paths the tool WOULD INTRODUCE under the durable home
# that do NOT exist. ⛔ IT IS SCOPED TO THE DURABLE HOME ON PURPOSE: the guard exists to stop a REWRITE
# that would not run (rule 4), so it grades the paths the rewrite introduces — not paths that were
# already in the unit, unrelated and untouched. Grading those refused whole units over pre-existing
# paths (an operator's `ARCHIVE=/var/backups/…` that does not exist yet) — a false block, and the
# sibling defect to the fabricated-target refusal the boundary rule above removes.
#   * COMMENT and BLANK lines are SKIPPED, never graded: a `#` line cannot affect systemd, and every
#     cell unit carries paragraphs of measured history that mention the legacy path by name. Grading
#     prose would refuse every real unit — the false-block shape this repo treats as its own defect.
#     (Nothing is hidden by skipping them: a comment does not run.)
#     ⛔ BOTH SPELLINGS — `systemd.syntax(7)` also ignores lines beginning with `;`, and the tool graded
#     only `#`. A unit whose measured history sits behind `;` was therefore reported UNHANDLED, refused
#     by name, and the box could NEVER reach `--check` -> 0 (the reclaim precondition) while its only
#     "defect" was a comment. `is_comment` is the one answer, used by the scanner AND the writer.
#   * BACKSLASH CONTINUATIONS inherit the previous directive name, because systemd CONCATENATES the
#     lines and expands C-style escapes — a continuation is the same directive, not a new one. ⛔ THE
#     INHERITANCE HOLDS FOR THE WHOLE LOGICAL LINE, so an INTERMEDIATE continuation line that does not
#     itself name the home does not end it (review F2). `systemd.syntax(7)`: "Lines ending in a backslash
#     are concatenated with the following line … When a comment line or lines follow a line ending with a
#     backslash, the comment block is ignored, so the continued line is concatenated with whatever
#     follows the comment block." So `ExecStart=<legacy>/run.sh \` + `--flag \` + `--state
#     <legacy>/state` is ONE directive, and a comment between the continued lines changes nothing. Clearing
#     the inherited name on a non-hit line (or on a comment) made the last line UNHANDLED: the whole file
#     was refused by a diagnostic that was FALSE ("a directive this tool does not re-base" about a
#     directive it rebases two lines above), and `--check` could never reach 0 on that box — the reclaim
#     precondition blocked for a reason the tool made up.
#   * A SIBLING NAME IS NOT THIS HOME. The record test is "the projection CHANGES this line", not "the
#     line contains the legacy string": `/tmp/cell-home.bak` (an operator's pre-migration archive, and
#     the same shape as this tool's own `<file>.pre-cell-home` backups) contains the legacy path as a
#     PREFIX but is a different directory. Emitting a record for it made `--check` call a converged box
#     drifted, and made `--apply` project it to `<home>.bak` — a target nobody has, refused by name.
#   * AN UNREADABLE FILE IS A NAMED RECORD, NOT AN EMPTY SCAN — see `probe_open` and the guard below.
#   * ⛔ THE DIRECTIVE NAME COMES FROM THE LOGICAL LINE, AND LEADING WHITESPACE IS NOT PART OF THE NAME
#     (review F4). systemd accepts an INDENTED directive (`   Environment=HOME=…` — measured with
#     `systemd-analyze verify`, which reports an unknown key in that position and not the indentation),
#     and the continuation name is inherited no matter what the continuation line starts with. Deriving
#     the name from the line's FIRST CHARACTER made both shapes UNHANDLED: an indented directive was
#     refused forever, and `ExecStart=/bin/sh -c \` + `cd <legacy>` (a continuation that happens to
#     begin with a word, not `--`) was refused as "a directive this tool does not re-base" about an
#     `ExecStart=` it re-bases two lines above. Both are the `;`-comment false block's class — the
#     scanner's line classification disagreeing with systemd's parser — so the rule is structural: if a
#     continuation is OPEN the name is the inherited one, otherwise it is `<Name>` after leading blanks.
# trim_tail <string> — the string with trailing blanks removed. ⛔ systemd IGNORES WHITESPACE AROUND `=`
# (`systemd.syntax(7)`: "Whitespace immediately before or after the `=` is ignored", confirmed with
# `systemd-analyze verify`), so `Environment = HOME=<legacy>` is an `Environment=` directive. Deriving
# the name from `${stripped%%=*}` kept the blank, the name matched no known directive, and the line was
# graded UNHANDLED — a permanent false block on a shape systemd accepts (review F3).
# _notab <string> — the string with any TAB replaced by a space. ⛔ A RECORD IS TAB-DELIMITED AND A UNIT
# LINE MAY CONTAIN A TAB, which is legal systemd whitespace (review F2): the raw line used to be field 3,
# so a tab inside it pushed the tail into the MISS field and the tool then reported "durable counterpart
# missing: <a path that exists>" and refused the file forever. Anything that goes into a record is
# sanitised here, and the record no longer carries a raw line at all (see `unit_scan`).
_notab() {
  local s="${1//$'\t'/ }"
  printf '%s' "$s"
}

trim_tail() {
  local v="${1:-}"
  while :; do case "$v" in *[[:space:]]) v="${v%?}" ;; *) break ;; esac; done
  printf '%s\n' "$v"
}

unit_scan() {
  local f="$1" n=0 line stripped dir projected miss p q _need grade orig_paths cont=""
  # ⛔ A FILE THAT CANNOT BE OPENED HAS NO RECORD ONLY IF YOU LET THE REDIRECT FAIL SILENTLY. `done < "$f"`
  # produced zero records for an unreadable unit, which the verdict then read as "clear of the legacy
  # home" (review F1). The open is attempted here, so the caller gets a NAMED CANNOT-MEASURE record.
  if ! probe_open "$f"; then
    printf '0\tUNMEASURABLE\t%s\n' "$(_notab "$f cannot be opened by $INVOKER (mode $(mode_of "$f")) — 'could not read' is not 'clear of the legacy home'")"
    return 0
  fi
  # ⛔ A LAST LINE WITHOUT A TRAILING NEWLINE IS STILL A LINE (review F1). `while IFS= read -r line`
  # DROPS it, so a unit whose final directive carried the legacy home and no trailing `\n` produced NO
  # record — `--check` answered 0 (the RECLAIM precondition) and `--apply` reported "one home" over a
  # file it never rewrote. The writer already used the correct idiom (`|| [ -n "$line" ]`), so this is
  # also a scanner/writer disagreement in the one dimension the file's doctrine says cannot exist.
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # ⛔ A COMMENT IS IGNORED BY systemd, SO IT NEITHER SETS NOR CLEARS THE CONTINUATION (review F2).
    if is_comment "$line"; then continue; fi
    # ⛔ LEADING BLANKS ARE NOT PART OF THE DIRECTIVE NAME (review F4). One strip, used by every test
    # below, so an indented directive and an indented continuation are classified like systemd does.
    stripped="$line"
    while :; do
      case "$stripped" in [[:space:]]*) stripped="${stripped#?}" ;; *) break ;; esac
    done
    # ⛔ THE PROJECTION IS THE LIB'S RULE, NOT A COPY OF IT. `cell_home_project_line` applies the
    # boundary rule (`/tmp/cell-home-2/x` and `/tmp/cell-home.bak` are not this home), and it is also
    # the record test: an unchanged projection means this line names no legacy home of OURS.
    projected="$(cell_home_project_line "$HOME_DURABLE" "$line")"
    case "$projected" in
      "$line")
        # This line names no legacy home of ours — but it may still BE part of the logical line above, so
        # the inherited directive name must survive it. Only a line that does NOT end in `\` ends the
        # logical line; a fresh `<Name>=… \` line starts a new one and sets the name it will hand down.
        # ⛔ AND A LINE THAT ENDS IN `\` WHILE A CONTINUATION IS OPEN KEEPS THE INHERITED NAME (review
        # F4): `cd … \` inside an `ExecStart=` continuation is not a directive named `cd …`.
        case "$stripped" in
          *\\ )
            if [ -z "$cont" ]; then
              case "$stripped" in [A-Za-z]*) cont="$(trim_tail "${stripped%%=*}")" ;; esac
            fi ;;
          *) cont="" ;;
        esac
        continue ;;
    esac
    # ⛔ A CONTINUATION THAT NAMES THE HOME INHERITS, WHATEVER ITS FIRST CHARACTER IS (review F4); a new
    # directive is `<Name>` read AFTER leading blanks, so an indented `   Environment=` is `Environment`.
    if [ -n "$cont" ]; then
      dir="$cont"
    else
      case "$stripped" in [A-Za-z]*) dir="$(trim_tail "${stripped%%=*}")" ;; *) dir="" ;; esac
    fi
    case "$dir" in
      "") printf '%s\tUNHANDLED\t%s\n' "$n" "$(_notab "$line")"; cont=""; continue ;;
    esac
    if ! grep -Eq "^($UNIT_DIRECTIVES)\$" <<<"$dir"; then
      printf '%s\tUNHANDLED\t%s\n' "$n" "$(_notab "$line")"; cont=""; continue
    fi
    case "$stripped" in *\\ ) cont="$dir" ;; *) cont="" ;; esac
    miss=""
    # ⛔ ONLY THE PATHS THE REWRITE INTRODUCES, AND NOT THE ONES systemd MANAGES OR IGNORES (review F2,
    # reproduced).
    # The guard filtered by LOCATION — any token under `$HOME_DURABLE` on the projected line — which is
    # not the same question as "the REWRITE introduced this token". Two ordinary shapes were therefore
    # refused with a false `203/EXEC` diagnosis:
    #   * `StateDirectory=<legacy>/state` — these directives name SUBVOLUMES systemd manages, and the unit
    #     is not made unrunnable by the path being absent. ⛔ THE REASON IS `systemd-analyze verify`, NOT
    #     "systemd creates it": the man page requires the names to be RELATIVE, an absolute value is
    #     *IGNORED* ("StateDirectory= path is absolute, ignoring"), and an operator's absolute form is
    #     exactly what this tool sees. Either way the unit starts, so neither shape may refuse;
    #     `CacheDirectory=`/`LogsDirectory=`/`RuntimeDirectory=` follow the same rule.
    #   * `Environment=PATH=<legacy>/bin:/usr/bin` — a variable VALUE list; systemd does not require its
    #     entries to exist, and `Environment=` carries no payload the service opens.
    # A refused file never repoints, so `--check` could never reach 0 on that box: the RECLAIM
    # precondition became PERMANENTLY UNREACHABLE, with a remedy built on a wrong diagnosis. This is the
    # scope the note above `unit_scan` already claimed ("grades the paths the rewrite introduces — not
    # paths that were already in the unit, unrelated and untouched") and the code did not implement.
    case "$dir" in
      StateDirectory|CacheDirectory|LogsDirectory|RuntimeDirectory) grade=0 ;;
      Environment) grade=0 ;;
      *) grade=1 ;;
    esac
    if [ "$grade" = 1 ]; then
      # the tokens this line ALREADY carried: a projected token is "introduced" only when its legacy
      # counterpart is one of them, and not when the line already named it under the durable home.
      orig_paths="$(paths_in "$line" "$dir" | awk -F'\t' '{print $2}')"
      while IFS='	' read -r _need p; do
        [ -n "$p" ] || continue
        case "$p" in *'$'*|*'{'*|*'%'*) continue ;; esac   # systemd specifiers are not resolved here
        case "$p" in "$HOME_DURABLE"|"$HOME_DURABLE"/*) ;; *) continue ;; esac   # only the durable home
        q="$HOME_LEGACY${p#"$HOME_DURABLE"}"
        case $'\n'"$orig_paths"$'\n' in *$'\n'"$q"$'\n'*) ;; *) continue ;; esac   # not a legacy token here
        case $'\n'"$orig_paths"$'\n' in *$'\n'"$p"$'\n'*) continue ;; esac              # already there: not introduced
        case "$_need" in
          2) [ -d "$(dirname "$p")" ] || miss="$miss $p" ;;   # a redirect target: its DIRECTORY must exist
          3) ;;                                                # `-`: the unit itself says "ignore if missing"
          *) [ -e "$p" ] || miss="$miss $p" ;;                # a command/binary/path: it must exist
        esac
      done <<EOF
$(paths_in "$projected" "$dir")
EOF
    fi
    # ⛔ THREE FIELDS, NO RAW LINE (review F2): `n`, the DIRECTIVE NAME, and the MISS list. The line itself
    # is re-read from the file by number wherever a message needs it, so a TAB in a unit can never move a
    # field — and a "missing durable counterpart" can never be fabricated from a line's tail.
    printf '%s\t%s\t%s\n' "$n" "$dir" "${miss# }"
  done < "$f"
}

# _project_file <src> <dst> — <src> with every GRADED line passed through the SAME projector the scan
# uses. The scan has already accepted the file (no UNHANDLED, every introduced target exists), so a line
# the projector changes is a line the scan graded; anything else is copied byte for byte. A here-string-free
# bash loop on purpose: no external producer, no pipe (#841 SIGPIPE), and no second rewriting rule.
# ⛔ A COMMENT IS NOT GRADED, SO IT IS NOT REWRITTEN (review F3). Passing every line through the
# projector edited operator-authored prose inside a root-owned unit file — the comment then read as a
# FALSE statement about measured history. `is_comment` is the scanner's own answer, so the writer and
# the scanner still cannot disagree: a line the scanner skips is a line the writer copies verbatim.
_project_file() {
  local src="$1" dst="$2" line
  : >"$dst" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if is_comment "$line"; then
      printf '%s\n' "$line" >>"$dst" || return 1
      continue
    fi
    printf '%s\n' "$(cell_home_project_line "$HOME_DURABLE" "$line")" >>"$dst" || return 1
  done <"$src"
}

# unit_files <dir> — the GRADED POPULATION of one unit dir, one path per line (sets $UNIT_FILES), plus
# the traversal errors find reported (sets $UNIT_FIND_ERR). ⛔ ONE POPULATION RULE, TWO CONSUMERS: the
# check and the writer both walk the unit dirs through this function, so one cannot see a file the other
# misses. ⛔ AND A TRAVERSAL ERROR IS NOT AN EMPTY POPULATION (review F1): find's stderr used to be
# thrown away (`2>/dev/null`), so a `<unit>.service.d` dir this account cannot read contributed NO file
# at all and the dir then read as "clear of the legacy home" — the same false PASS as an unreadable
# FILE, one level up.
#
# ⛔ THE POPULATION MUST BE THE ONE systemd LOADS, BECAUSE THE VERDICT SPEAKS FOR ALL OF IT (review F5).
# It used to be `*.service|*.timer|*.conf` AND `-type f`, so three shapes systemd reads were invisible:
# a SYMLINKED unit (`systemctl link` exists precisely to install a unit as a symlink — `-type f`
# excludes it), and every unit type other than `.service`/`.timer` (`.socket`, `.mount`, `.path`, …) —
# and `--check` then said "none — every unit … is clear of the legacy home" and answered 0 (the RECLAIM
# precondition) over a `.socket` whose `ListenStream=` named the legacy home. The writer refuses a
# symlink by name (see `migrate_units`) rather than swapping the link for a regular file.
UNIT_FILES=""
UNIT_FIND_ERR=""
unit_files() {
  local args
  args=( "$1" -maxdepth 2
         \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.mount' -o -name '*.automount'
            -o -name '*.path' -o -name '*.swap' -o -name '*.target' -o -name '*.slice' -o -name '*.conf' \)
         \( -type f -o -type l \)
         ! -name '*.pre-cell-home'
         # ⛔ AN ENABLEMENT ALIAS IS NOT A UNIT DEFINITION (review F4). `<target>.wants/<unit>` (and
         # `.requires/`, `.upholds/`) is a SYMLINK to a unit defined elsewhere; grading it made the same
         # unit graded twice, and the writer — which refuses symlinks by name — then refused the alias
         # while repointing its target, so `--check` could answer 1 forever in an order-dependent way
         # (`default.target.wants/x` sorts before `x` and is refused; `multi-user.target.wants/x` sorts
         # after and is skipped). The definition itself is still graded, once.
         ! -path '*.wants/*' ! -path '*.requires/*' ! -path '*.upholds/*' )
  local raw f
  raw="$(find "${args[@]}" 2>/dev/null | LC_ALL=C sort)"
  UNIT_FIND_ERR="$(find "${args[@]}" 2>&1 >/dev/null | LC_ALL=C sort -u)"
  # ⛔ A DANGLING SYMLINK NAMES NOTHING systemd LOADS (review F4). It used to enter the population and be
  # graded UNMEASURABLE, which is a PERMANENT exit 3 over a stale enablement link — removing the link was
  # the only way to reach `--check` -> 0. `cannot_traverse` already draws this line for the credential
  # leg: a path whose parent is genuinely absent is ABSENT (a measurable reading), not unmeasurable.
  UNIT_FILES=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -L "$f" ] && [ ! -e "$f" ]; then continue; fi
    UNIT_FILES="${UNIT_FILES}${UNIT_FILES:+$'\n'}$f"
  done <<EOF
$raw
EOF
}

# unit_scan_all — every unit/drop-in under the declared dirs, one "<file>\t<record…>" line per hit.
unit_scan_all() {
  local dir f hit st wst
  while IFS= read -r dir; do
    walkable_dir "$dir"; wst=$?
    case "$wst" in
      0) ;;
      3) printf '%s\t0\tUNMEASURABLE\t%s\n' "$dir" "$(_notab "$dir: this account cannot tell 'no unit here' from 'could not look' — an ancestor denies search, so 'no unit here names the legacy home' is not a reading this tool took")"
         continue ;;
      *) continue ;;
    esac
    unit_files "$dir"
    if [ -n "$UNIT_FIND_ERR" ]; then
      printf '%s\t0\tUNMEASURABLE\t%s\n' "$dir" "$(_notab "$dir: part of this population cannot be walked by $INVOKER ($(printf '%s' "$UNIT_FIND_ERR" | tr '\n' ' ')), so 'no unit here names the legacy home' is not a reading this tool took")"
    fi
    # A unit file, and any drop-in under `<unit>.service.d/*.conf` — the two shapes systemd merges.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # ⛔ THE PREFILTER'S STATUS IS THE DIFFERENCE BETWEEN "no match" AND "could not read" (review F1).
      # `grep -q … || continue` gave EACCES the same exit as a clean file, so a unit this account cannot
      # read silently became "clear of the legacy home" and `--check` answered 0 — the delete-the-live-
      # directory false PASS, reached through the prefilter instead of through the verdict.
      if ! probe_open "$f"; then
        printf '%s\t0\tUNMEASURABLE\t%s\n' "$f" "$(_notab "$f: cannot be opened by $INVOKER (mode $(mode_of "$f")) — cannot tell whether it names the legacy home")"
        continue
      fi
      grep -q -- "$HOME_LEGACY" "$f" 2>/dev/null
      st=$?
      if [ "$st" -gt 1 ]; then
        printf '%s\t0\tUNMEASURABLE\t%s\n' "$f" "$(_notab "$f: scanning it failed (grep status $st) — cannot tell whether it names the legacy home")"
        continue
      fi
      [ "$st" = 0 ] || continue
      hit="$(unit_scan "$f")"
      [ -n "$hit" ] || continue
      printf '%s\n' "$hit" | while IFS= read -r rec; do printf '%s\t%s\n' "$f" "$rec"; done
    done <<EOF
$UNIT_FILES
EOF
  done <<EOF
$(unit_dirs)
EOF
}

# legacy_home_advisory — the ADVISORY list of what the legacy home still holds that this tool does not
# grade. ⛔ A PER-NAME LIST ALWAYS LAGS THE FLEET (review F3): `CRED_FILES` is four names, and a fifth
# credential added tomorrow would read as "one home" and be deleted with the directory. This cannot be a
# hard gate — a cell home legitimately carries `harness/`, `.cache`, `.config` … and grading those would
# make `--check` -> 0 unreachable on every real box (a false block). So it is printed as an ADVISORY
# beside the verdict: the operator sees the whole population before reclaiming, and nothing fails on it.
legacy_home_advisory() {
  local entries name
  [ -d "$HOME_LEGACY" ] || return 0
  # ⛔ A REAL READ, NOT `[ -r ]` (review F5 round 4). `[ -r ]` is permission BITS, and `ls`'s error was
  # discarded, so a legacy home that is SEARCHABLE but not LISTABLE (mode 111) printed ZERO advisory
  # lines — i.e. "nothing ungraded here" — while the population was never read. Silence is not an answer:
  # a failed listing is stated as such.
  if ! entries="$(ls -A "$HOME_LEGACY" 2>/dev/null)"; then
    printf 'ADVISORY %s\n' "  CANNOT LIST $HOME_LEGACY — its contents were NOT reviewed; look before reclaiming"
    return 0
  fi
  printf '%s\n' "$entries" | LC_ALL=C sort | awk 'NR<=40' | while IFS= read -r name; do
    [ -n "$name" ] || continue
    # ⛔ AND THE GRADED CREDENTIALS ARE NOT "NOT GRADED" (review F5): the credentials section above
    # already measured them, so labelling them ungraded is a false statement about this run's own reading.
    # ⛔ A GRADED CREDENTIAL IS NOT "NOT GRADED" (review F5): the credentials section above already
    # measured it. Matched by ITERATING the list (newline-separated), not with a `case` on the raw value —
    # and by first component too, so `.pi` (which holds the graded `.pi/agent/auth.json`) is not libelled.
    # ⛔ EXACT NAMES ONLY (review F4 round 5): a prefix match dropped `.pi` and `.config` ENTIRELY, so
    # whatever else lives beside the graded credential (`sessions/`, editor backups) was neither graded nor
    # surfaced — an omission on the one report an operator reads before `rm -rf`. A first component that
    # CONTAINS graded children is reported as partially graded instead of being swallowed.
    _graded=0; _partial=0
    for _c in $CRED_FILES; do
      case "$_c" in
        "$name") _graded=1; break ;;
        "$name"/*) _partial=1 ;;
      esac
    done
    [ "$_graded" = 1 ] && continue
    if [ "$_partial" = 1 ]; then
      printf 'ADVISORY %s\n' "  PARTIALLY graded — inspect the rest: $HOME_LEGACY/$name"
      continue
    fi
    printf 'ADVISORY %s\n' "  present in the legacy home and NOT graded by this tool (review before reclaiming): $HOME_LEGACY/$name"
  done
}

check_units() {
  local scan cant=0
  note "units naming the legacy home ($HOME_LEGACY)"
  scan="$(unit_scan_all)"
  if [ -z "$scan" ]; then
    note "  none — every unit and drop-in directive this tool grades (.service .socket .timer .mount .automount .path .swap .target .slice, plus *.conf drop-ins) is clear of the legacy home"
    return 0
  fi
  # ⛔ A RECORD WHOSE READING COULD NOT BE TAKEN IS CANNOT-MEASURE, NEVER DRIFT AND NEVER CLEAR (review
  # F1). It is detected from the RECORD TEXT and not from a flag, because `unit_scan_all` runs inside a
  # command substitution: a counter incremented over there does not survive, and a verdict that loses
  # its own unmeasurable count is the very defect this arm exists to prevent.
  case "$scan" in *$'\tUNMEASURABLE\t'*) cant=1 ;; esac
  printf '%s\n' "$scan" | while IFS='	' read -r f n dir payload; do
    if [ "$dir" = "UNMEASURABLE" ]; then
      warn_line "  CANNOT MEASURE: $payload"
      continue
    fi
    if [ "$dir" = "UNHANDLED" ]; then
      warn_line "  $f:$n names the legacy home in a directive this tool does not re-base — fix or replace that file by hand:
      $payload"
      continue
    fi
    if [ -n "$payload" ]; then
      warn_line "  $f:$n would NOT run after a repoint — the durable counterpart does not exist: $payload
      (a unit that execs a missing path is 203/EXEC on the next restart, so --apply will REFUSE this file)"
    else
      warn_line "  $f:$n  $dir=…  ->  NOT CONVERGED: the directive still names the legacy home; --apply would repoint it"
    fi
  done
  # ⛔ THE VERDICT IS "NO RECORD AT ALL", NOT "NO UNHANDLED AND NO MISSING TARGET". Every record exists
  # because a line STILL NAMES THE LEGACY HOME, so every record is drift — including the ordinary,
  # un-migrated unit whose durable counterpart happens to exist, which `--apply` can cleanly repoint.
  # Reading "would be repointable" as "converged" made `--check` answer 0 on a box with every unit
  # pointed at the legacy home, and `--check` -> 0 is the stated precondition for RECLAIMING that home
  # (PR/issue #3453, "What is NOT in this PR" 1 and 3): an operator would delete the directory every
  # unit still names, i.e. `203/EXEC` on the next restart. UNHANDLED and `miss` stay a DISTINCT (louder)
  # class — they are refusals `--apply` cannot fix — but they are not the only kind of "not one home".
  # ⛔ AND THE THIRD CLASS IS CANNOT MEASURE, WHICH IS NOT DRIFT: a file this tool could not open, or a
  # population it could not walk, means the question "does anything here still name the legacy home" was
  # never answered — exit 3, never 0 (a PASS manufactured from a read that was never taken) and never a
  # plain 1 (which would read as "I looked, and it drifted").
  if [ "$cant" = 1 ]; then
    warn_line "  ⛔ 'could not read' is NOT 'one home': a unit or drop-in above could not be measured, so this run cannot certify the reclaim precondition on $HOME_LEGACY"
    return 3
  fi
  return 1
}

# The rewrite. One file at a time, atomically, with a one-time backup that preserves the mode.
# Writes ONLY the projected lines of directives whose every projected path exists.
migrate_units() {
  local dir f n directive projected miss rec rc=0 applied=0 refused=0 cant=0 backup tmpdir wst
  while IFS= read -r dir; do
    # ⛔ A DIR THIS ACCOUNT CANNOT SEARCH IS NOT AN EMPTY POPULATION (review F1) — `[ -d ]` answers false
    # both for "nothing was installed here" and for "an ancestor denies me search", and the second one
    # used to leave the writer with nothing to repoint and nothing to report.
    walkable_dir "$dir"; wst=$?
    case "$wst" in
      0) ;;
      3) warn_line "  CANNOT MEASURE: $dir — this account cannot tell 'nothing to repoint here' from 'could not look' (an ancestor denies search), so nothing under it was repointed or ruled out"
         cant=1; continue ;;
      *) continue ;;
    esac
    # ⛔ THE WRITER WALKS THE SAME POPULATION THE CHECK DOES (review F1): a dir find cannot traverse
    # contributes no file, so "nothing to repoint here" would be a reading this tool never took — and
    # the box would read converged on the very half that was skipped.
    unit_files "$dir"
    if [ -n "$UNIT_FIND_ERR" ]; then
      warn_line "  CANNOT MEASURE: $dir — part of this population cannot be walked by $INVOKER ($(printf '%s' "$UNIT_FIND_ERR" | tr '\n' ' ')), so nothing under it could be repointed or ruled out"
      cant=1
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local scan; scan="$(unit_scan "$f")"
      [ -n "$scan" ] || continue
      # Refuse the WHOLE file if any line is unhandled or names a missing durable counterpart: a
      # partially repointed unit is worse than an unmigrated one (it reads as migrated).
      local refuse=0
      while IFS='	' read -r n directive miss; do
        # ⛔ A FILE THIS TOOL COULD NOT OPEN IS REFUSED AND REPORTED AS UNMEASURABLE, not skipped: an
        # `install`/`cp`/`mv` on a file we cannot read would either fail late or write a unit nobody
        # graded. `unit_scan` names it; this is where the run's exit class follows (3, not 0 and not a
        # bare 1 — same reason as the check).
        if [ "$directive" = "UNMEASURABLE" ]; then
          warn_line "  CANNOT MEASURE: $miss (nothing written to $f)"
          refuse=1; cant=1; break
        fi
        if [ "$directive" = "UNHANDLED" ]; then
          warn_line "  REFUSED $f:$n — directive not re-based by this tool (nothing written to $f)"
          refuse=1; break
        fi
        if [ -n "$miss" ]; then
          warn_line "  REFUSED $f:$n — durable counterpart missing: $miss (nothing written to $f)"
          refuse=1; break
        fi
      done <<EOF
$scan
EOF
      if [ "$refuse" = 1 ]; then
        refused=$((refused + 1)); rc=1; continue
      fi
      # ⛔ A SYMLINKED UNIT IS GRADED BUT NEVER REPLACED (review F5). `systemctl link` installs a unit as
      # a symlink on purpose; the atomic `mv` below would replace the LINK with a regular file and
      # silently detach it from the tree the operator linked to. Reporting the drift in `--check` (the
      # population now includes symlinks) and refusing the write BY NAME is the honest pair: the box
      # cannot read "one home" over a linked unit, and nothing is destroyed to get there.
      if [ -L "$f" ]; then
        warn_line "  REFUSED $f — installed as a symlink ($(readlink "$f" 2>/dev/null || printf '?')); this tool does not replace a link. Edit the target by hand, then re-run."
        refused=$((refused + 1)); rc=1; continue
      fi
      # ⛔ WRITABILITY IS CHECKED BEFORE THE BACKUP, so the operator gets "run this under sudo" instead
      # of a confusing copy failure. `/etc/systemd/system` is root's; this tool never elevates itself.
      # ⛔ AND THE ADVICE NAMES THE HOME. `sudo` re-sets `HOME` to the TARGET account's home
      # (`env_reset`), so a bare `sudo -n bash $0 --apply` derives `/root` — it would repoint every
      # `Environment=`-only directive (the commonest shape) at `/root`, create a THIRD home there, and
      # report "one home" (see `check_derivation`). `env CELL_HOME=…` is what survives that reset.
      if [ ! -w "$f" ]; then
        warn_line "  REFUSED $f — not writable by $INVOKER. Re-run the unit half as root WITH the home named: sudo -n env CELL_HOME=$HOME_DURABLE bash $0 --apply"
        refused=$((refused + 1)); rc=1; continue
      fi
      # ⛔ THE WRITER IS THE PROJECTOR — there is no second rewriting rule to drift from the scanner's.
      # The first attempt re-based with its own awk that matched `^(directive)=` at the START of a line,
      # while the scan grades a BACKSLASH CONTINUATION by inheriting the previous directive name. The two
      # halves disagreed and the disagreement was a FALSE PASS (review, P1): `ExecStart=<legacy>/run.sh \`
      # + `  --state <legacy>/state` was HALF-written, `--apply` printed "one home" and exited 0 over a
      # unit that still named the legacy home, and the next `--check` then reported the tool's own partial
      # write as the operator's hand-written defect. Now every accepted line goes through the same
      # `cell_home_project_line` the scan used to accept the file — so coverage cannot differ, only the
      # whole FILE is accepted first (any UNHANDLED / missing-target record refuses it above).
      backup="$f.pre-cell-home"
      [ -e "$backup" ] || { cp -p "$f" "$backup" 2>/dev/null || { warn_line "  cannot back up $f — refusing to write it"; rc=1; continue; }; }
      tmpdir="$(mktemp "${f}.cell-home.XXXXXX" 2>/dev/null)" || { warn_line "  cannot create a temp file beside $f — refusing to write it"; rc=1; continue; }
      if _project_file "$f" "$tmpdir"; then
        # ⛔ THE POST-CONDITION: re-grade what was just written, with the SAME scanner the verdict uses.
        # A leftover record means the write did not carry what the scan accepted (a broken pipe, a
        # short write, a future refactor of either half) — refuse the swap, leave the original in place.
        if [ -n "$(unit_scan "$tmpdir")" ]; then
          rm -f "$tmpdir"
          warn_line "  REFUSED $f — the rewrite left a line that still names $HOME_LEGACY (the writer and the scanner disagree); the original file was NOT touched"
          refused=$((refused + 1)); rc=1; continue
        fi
        # Preserve the original mode AND OWNERSHIP, then swap in atomically. `chown` is best effort: a
        # non-root run owns the file it just made, and a root run puts the unit back under the account it
        # was written for (review F7 — the comment claimed this and only `chmod` was done).
        chmod "$(mode_of "$f")" "$tmpdir" 2>/dev/null || true
        _own="$(owner_of "$f")"
        if [ -n "$_own" ] && ! chown "$_own" "$tmpdir" 2>/dev/null; then
          warn_line "  REFUSED $f — the rewritten file could not be re-owned to $_own (it would land owned by the invoker); the original was NOT touched"
          rm -f "$tmpdir"; refused=$((refused + 1)); rc=1; continue
        fi
        if mv -f "$tmpdir" "$f" 2>/dev/null; then
          note "  repointed $f (backup: $backup)"
          applied=$((applied + 1))
        else
          rm -f "$tmpdir"; warn_line "  WRITE FAILED for $f — original left in place"; rc=1
        fi
      else
        rm -f "$tmpdir"; warn_line "  rewrite FAILED for $f — original left in place"; rc=1
      fi
    done <<EOF
$UNIT_FILES
EOF
  done <<EOF
$(unit_dirs)
EOF
  if [ "$applied" -gt 0 ] && [ "${CELL_HOME_MIGRATE_NO_RELOAD:-}" != 1 ]; then
    # ⛔ daemon-reload RE-READS THE FILES; IT DOES NOT RESTART ANYTHING. Running units keep the
    # environment they started with, which is deliberate: this tool must be safe to run on a live
    # cell. The restart that picks the new values up is the operator's window (#3453 says so).
    if ! systemctl daemon-reload >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" != 0 ] && sudo -n true >/dev/null 2>&1; then
        sudo -n systemctl daemon-reload >/dev/null 2>&1 || { warn_line "  daemon-reload FAILED — the rewritten files are NOT live"; rc=1; }
      else
        warn_line "  daemon-reload could not run (no root, no passwordless sudo) — the rewritten files are NOT live until it does"
        rc=1
      fi
    else
      note "  daemon-reload: done (no unit was restarted)"
    fi
    note "  ⛔ THE REWRITTEN UNITS KEEP THEIR OLD ENVIRONMENT UNTIL THEY RESTART. \`eldato-orchestrator.service\` spawns the lanes and needs a planned dispatcher window (agent-infra#3453) — this tool does not take it."
  fi
  if [ "$cant" = 1 ]; then return 3; fi      # ⛔ 3 outranks 1 — see the exit-code table
  return "$rc"
}

# ── THE DERIVATION GUARD (the account the UNITS RUN AS, not the account that invoked this) ─────
# ⛔ THE DANGEROUS WRITE THIS GUARDS (review, P2/BLOCKING). `HOME_DURABLE` is `cell_home_resolve`'s
# answer, and that resolver's step 2 is the PASSWD HOME OF WHOEVER IS RUNNING. The remedy this tool
# prints for a root-owned unit dir used to be `sudo -n bash $0 --apply` — and `sudo` re-sets `HOME` to
# the TARGET account's home (`env_reset`, sudoers(5)) while `env_reset` also drops an ambient
# `CELL_HOME`. So the exact advice the tool gave derived `HOME_DURABLE=/root` and then:
#   * created `/root/keys.env`, `/root/.pi/agent/auth.json`, `/root/.config/gh/hosts.yml` — a THIRD home
#     with the cell's credentials in it; and
#   * repointed every directive whose projected path exists — `/root` exists — so the commonest shape
#     of all, `Environment=HOME=<legacy>` (the `cell-self-pin.service.d/*.conf` drop-in this change
#     itself names), became `Environment=HOME=/root`;
# and it printed `VERDICT: one home`. Rule 4's existence guard does not save it: only units whose
# PAYLOAD is under the home are refused, and an `Environment=`-only line has no payload.
#
# So the DERIVATION is refused unless it is the home the units actually run as. An explicit `CELL_HOME`
# is always honoured (the resolver's rule 1, and the seam every hermetic suite uses); what is refused is
# GUESSING it — from `root`, or from an account the graded units do not declare.
unit_users() {
  local f
  # ⛔ THE POPULATION IS EVERY UNIT THIS TOOL GRADES — NOT ONLY THE ONES IT WOULD REPOINT (review F1
  # round 3, closing the round-2 narrowing). The round-2 fix answered "whose `User=` decides" from
  # `$REPOINT_FILES` — the files whose scan still yields a record — and that set is EMPTY on a converged
  # box, which is exactly the state `--apply` produces. So the guard became VACUOUS precisely where it
  # matters: `check_derivation` then returned 0 for ANY derived home the invoking account's passwd record
  # answers (bar a root invoker and a home that does not exist), and `main` runs the CREDENTIAL half first
  # — so `--apply` copied `keys.env` / `.pi/agent/auth.json` into a third home, printed `VERDICT: one
  # home` and exited 0, and a follow-up `--check` then also read 0 because the durable side now held the
  # copies. That 0 is the stated precondition for RECLAIMING `/tmp/cell-home` (see the EXIT CODES table at
  # the top of this file and `check_derivation`'s converged verdict): the tool
  # could move the only copy of the cell's credentials into an account the units do not run as and then
  # authorise deleting the source. Reachable whenever the invoking account is not the units' account and
  # its passwd home EXISTS (`cmux` units repaired from an `ubuntu` operator path, a CI/runner account).
  # ⛔ SO THE POPULATION GOES BACK TO THE WHOLE GRADED WALK — and the FALSE BLOCK the round-2 narrowing
  # was answering is excluded by ACCOUNT instead of by UNIT (see `is_cell_home`). That is the difference
  # that matters: a vendor unit's account (`systemd-resolve`/`systemd-timesync`/`nobody`) is not a home a
  # cell could be, while a cell account is — and the converged state must not be able to silence the
  # second one. `$GRADED_FILES` is filled by leg (0) of `check_derivation`, the same walk the writer uses.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk '/^[[:space:]]*User=/ { v = $0; sub(/^[[:space:]]*User=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); if (v != "") print v }' "$f" 2>/dev/null
  done <<EOF
$GRADED_FILES
EOF
}

# is_cell_home <home> — 0 when that passwd home is a home a CELL could actually be, i.e. a REAL,
# EXISTING directory. ⛔ THIS IS THE EXCLUSION THAT REPLACES THE ROUND-2 POPULATION NARROWING, and it is
# deliberately about the ACCOUNT, not about the file: the three accounts that false-blocked a converged
# live cell (review F1 round 2, measured) are `systemd-resolve` (home `/`), `systemd-timesync` (home `/`)
# and `nobody` (home `/nonexistent`) — vendor units an ordinary Ubuntu/Debian box carries as
# `systemctl enable` aliases. None of them is a cell home: `/` is the root of the filesystem and
# `/nonexistent` is the conventional "no home" answer. Excluding them keeps a converged box at
# `--check` 0 (the acceptance criterion and the RECLAIM precondition) WITHOUT returning to the vacuous
# repoint-set population — a unit the tool never rewrites can still name the account the cell runs as.
# A home that is empty or absent cannot be verified as the units' home either, so it is not a conflict;
# it is reported by nothing here because `--check` already grades the derived home's existence.
is_cell_home() {
  case "${1:-}" in '' | /) return 1 ;; esac
  [ -d "$1" ] || return 1
  return 0
}

# ⛔ `repoint_files` USED TO LIVE HERE AND IS GONE (review F1 round 3). It answered "which files
# would this run rewrite" by scanning every unit for a surviving legacy record, and it had exactly one
# caller — leg (ii) of `check_derivation`. Grading `User=` from that set is what made the derivation
# guard vacuous on a converged box (nothing survives a scan there, so the set was empty and any
# derivation passed), and once leg (ii) reads the whole graded walk the set had no caller left. Its
# behaviour is not lost: "would this run rewrite this file" is `unit_scan`, which `migrate_units` calls
# directly on the same walk this guard uses.
GRADED_FILES=""

# account_home <user> — that account's passwd home, or nothing when it cannot be resolved (a unit whose
# `User=` is still the unrendered `{{USER}}` template, a numeric uid, a user that does not exist here).
account_home() {
  local u="$1" h=""
  [ -n "$u" ] || return 1
  if command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$u" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  [ -n "$h" ] || h="$(cd ~"$u" 2>/dev/null && pwd -P)"
  [ -n "$h" ] || return 1
  printf '%s\n' "$h"
}

# check_derivation — 0 when HOME_DURABLE may be acted on; 1 with the reason on stderr when it may not.
check_derivation() {
  local u h conflicts="" d f wst
  [ "$HOME_DURABLE_GIVEN" = 0 ] || return 0        # an explicit CELL_HOME is the operator's decision
  # (i) a PRIVILEGED invoker: the resolver answers root's passwd home, which is not a cell home at all.
  if [ "$INVOKER_UID" = 0 ]; then
    warn_line "  REFUSED: refusing to DERIVE the durable home from a privileged invoking account ($INVOKER -> $HOME_DURABLE). The units run as the cell account, not as root, so this would repoint them (and their credentials) into $HOME_DURABLE. Name the home explicitly: sudo -n env CELL_HOME=$CELL_HOME_FLEET_DEFAULT bash $0 --apply"
    return 1
  fi
  # (0) ⛔ THE POPULATION MUST BE MEASURABLE BEFORE "NO CONFLICTING User=" CAN BE AN ANSWER (review F3).
  # (ii) below reads an EMPTY `User=` list as "the units declare no other account", and an unreadable
  # dir or unit file produced exactly that empty list — so a derivation the units do not run as was
  # ACCEPTED and the credential half then wrote the cell's secrets into it (a THIRD home, the dangerous
  # write this guard exists to prevent). `main` runs the credential half before the unit half, so the
  # write happened before `migrate_units` could report that the population was never walkable. This gate
  # runs in the CURRENT shell (no command substitution), which is why it uses `unit_files` directly
  # instead of asking `unit_users` — a flag set inside `$( )` does not survive.
  # ⛔ AND IT IS WHERE THE `unit_users` POPULATION IS COLLECTED (review F1 round 3): `$GRADED_FILES` is
  # the very walk this gate already had to take, so leg (ii) grades exactly the population leg (0)
  # proved measurable — one walk, one population, no second source of truth to drift.
  GRADED_FILES=""
  while IFS= read -r d; do
    # ⛔ THE SAME THREE-VALUED DIR READ THE OTHER TWO WALKERS USE (review F1): a dir this account cannot
    # search answered `[ -d ]` false, left the population empty, and `unit_users`'s empty `User=` list was
    # then read as "the units declare no other account" — an ACCEPTED derivation on a population this
    # tool never saw. Refusing before any write is the posture leg (0) already takes for a find error.
    walkable_dir "$d"; wst=$?
    case "$wst" in
      0) ;;
      3) warn_line "  REFUSED: $d — this account cannot tell 'no unit here' from 'could not look' (an ancestor denies search), so 'the units declare no other account' is not a reading this tool took. Refusing BEFORE any write; name the home explicitly: CELL_HOME=<the units account's home> $0 $MODE"
         return 1 ;;
      *) continue ;;
    esac
    unit_files "$d"
    if [ -n "$UNIT_FIND_ERR" ]; then
      warn_line "  REFUSED: $d — part of this population cannot be walked by $INVOKER ($(printf '%s' "$UNIT_FIND_ERR" | tr '\n' ' ')), so 'the units declare no other account' is not a reading this tool took. Refusing BEFORE any write; name the home explicitly: CELL_HOME=<the units account's home> $0 $MODE"
      return 1
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! probe_open "$f"; then
        warn_line "  REFUSED: $f cannot be opened by $INVOKER (mode $(mode_of "$f")), so 'the units declare no other account' is not a reading this tool took. Refusing BEFORE any write; name the home explicitly: CELL_HOME=<the units account's home> $0 $MODE"
        return 1
      fi
      GRADED_FILES="${GRADED_FILES}${GRADED_FILES:+$'\n'}$f"
    done <<EOF
$UNIT_FILES
EOF
  done <<EOF
$(unit_dirs)
EOF
  # (ii) a graded unit declares an account whose home is not the derived one: the derivation is not the
  #      home this box runs its units as, so acting on it would move them (and their credentials) off
  #      their own tree. ⛔ THE ACCOUNT, NOT THE FILE (review F1 round 3): the round-2 population — the
  #      units this tool WOULD repoint — is EMPTY on a converged box, which made this leg vacuous on
  #      exactly the state `--apply` produces (see `unit_users`). Reading the whole graded population
  #      restores it, and the false block that narrowing was answering is excluded by ACCOUNT instead
  #      (`is_cell_home`): a vendor unit's `/` or `/nonexistent` home is not a home a cell could be, a
  #      cell account's is.
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ "$u" = "root" ] && continue                      # root units genuinely live in /root
    h="$(account_home "$u")" || continue
    [ -n "$h" ] || continue
    [ "$h" = "$HOME_DURABLE" ] && continue
    is_cell_home "$h" || continue                     # `/`, '' and a non-directory home are not cell homes
    conflicts="$conflicts $u($h)"
  done <<EOF
$(unit_users | awk '!s[$0]++')
EOF
  if [ -n "$conflicts" ]; then
    warn_line "  REFUSED: the derived durable home $HOME_DURABLE is not the home of the account the units this tool grades run as:$conflicts. Refusing to repoint units onto a home they do not run in — name the home explicitly: CELL_HOME=<that account's home> $0 --apply"
    return 1
  fi
  return 0
}

# ── MAIN ──────────────────────────────────────────────────────────────────────────────────────
# The owner a ROOT run must stamp onto what it writes into the durable home (review F7).
# ⛔ `CELL_HOME_MIGRATE_FORCE_OWNER` IS A DECLARED FIXTURE SEAM, like the four above: ownership only
# needs fixing on a ROOT run, and a suite that cannot become root cannot otherwise grade the enforcer —
# an untestable guard is an inert one (review F4). It names the uid:gid that SHOULD own what we write.
DUR_OWNER="${CELL_HOME_MIGRATE_FORCE_OWNER:-$(owner_of "$HOME_DURABLE" 2>/dev/null || true)}"
note "cell-home-migrate: mode=$MODE"
note "  durable home: $HOME_DURABLE  (derived by scripts/lib/cell-home.sh)"
note "  legacy home:  $HOME_LEGACY   (never deleted by this tool)"
if [ "$HOME_DURABLE" = "$HOME_LEGACY" ]; then
  warn_line "  the derived durable home IS the legacy home — refusing to grade a box against itself; set CELL_HOME to the durable home (agent-infra#3453)"
  exit 3
fi
# ⛔ THE DERIVATION GUARD COMES FIRST: it must be able to refuse a home that is not the units' account
# home BEFORE anything is measured against it (a privileged invoker's `/root` may not even be readable
# from here, and "does not exist" would hide the actionable refusal behind a confusing one).
if ! check_derivation; then
  exit 3
fi
if [ ! -d "$HOME_DURABLE" ]; then
  warn_line "  the durable home $HOME_DURABLE does not exist — CANNOT MEASURE (nothing was changed)"
  exit 3
fi

cred_rc=0
units_rc=0
if [ "$MODE" = "--check" ]; then
  check_credentials || cred_rc=$?
  check_units || units_rc=$?
else
  note "credentials:"
  migrate_credentials || cred_rc=$?
  note "units:"
  migrate_units || units_rc=$?
fi

# The DEFERRED reclaim, stated as a number rather than as prose. `du` is best-effort: an unreadable
# legacy home is reported as such, never as "0 B reclaimed".
legacy_size="$(du -sh "$HOME_LEGACY" 2>/dev/null | awk 'NR==1{print $1}')"
note "legacy home size: ${legacy_size:-UNREADABLE} (NOT reclaimed by this change — reclaim only after every unit repoints AND a lane proves push=OK + provider=OK from a clean shell with nothing sourced)"

# ⛔ 3 OUTRANKS 1 (see the exit-code table). "I could not look" and "I looked and it drifted" are
# different reports, and only the first one forbids the reclaim — collapsing them to 1 would let an
# unreadable unit read as an ordinary drift that `--apply` can clean up.
rc=0
for _leg_rc in "$cred_rc" "$units_rc"; do
  case "$_leg_rc" in
    0) ;;
    3) rc=3 ;;
    *) [ "$rc" = 3 ] || rc=1 ;;
  esac
done
if [ "$rc" = 3 ]; then
  note "VERDICT: CANNOT MEASURE — a reading this tool needs could not be taken (named above). This is NOT a verdict on the home: 'could not read' is not 'one home', so the reclaim precondition is NOT met."
elif [ "$rc" = 0 ]; then
  note "VERDICT: one home — nothing to do"
else
  note "VERDICT: drift found (see WARN lines above)"
fi
# ⛔ THE ADVISORY IS PRINTED BESIDE THE VERDICT AND CHANGES NOTHING (review F3): the graded population is
# a per-name list, and a credential added tomorrow would read as "one home" and be deleted with the
# directory. This is the visible remainder — never a gate, because a cell home legitimately carries
# operational directories and grading those would make `--check` -> 0 unreachable on every real box.
legacy_home_advisory
exit "$rc"
