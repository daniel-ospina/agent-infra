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
CELL_HOME_LIB="${SELF_DIR:+$SELF_DIR/lib/cell-home.sh}"
CELL_HOME_LIB="${CELL_HOME_LIB:-lib/cell-home.sh}"
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
HOME_LEGACY="$CELL_HOME_LEGACY"
INVOKER_UID="$(id -u 2>/dev/null || printf '1')"
INVOKER="$(id -un 2>/dev/null || printf '?')"

# The unit directories, in the order the installers try them — the same read-side seams the bring-up
# and the supervisor use, so "which units this tool grades" cannot drift from "which units exist".
unit_dirs() {
  if [ -n "${CELL_HOME_MIGRATE_UNIT_DIRS:-}" ]; then
    printf '%s' "$CELL_HOME_MIGRATE_UNIT_DIRS" | tr ':' '\n'
    return 0
  fi
  local d
  for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" \
           "${CONTROLLER_USER_UNIT_DIR:-${HOME:-}/.config/systemd/user}"; do
    [ -n "$d" ] && printf '%s\n' "${d%/}"
  done | awk 'NF && !s[$0]++'
}

# ── CREDENTIALS ────────────────────────────────────────────────────────────────────────────────
# The files a lane's provider/`gh`/`git` resolution actually reads. Each is described, never shown.
# `keys.env` is the cell's pushed env (HOME/CELL_HOME + provider keys); `auth.json` is pi's credential
# store; `hosts.yml` is `gh`'s token source, which `git` reuses via the credential helper.
CRED_FILES="keys.env
.pi/agent/auth.json
.config/gh/hosts.yml"

# ⛔ THE ONE CREDENTIAL THAT IS ALSO A PROGRAM. `keys.env` is SOURCED as shell by the very processes this
# migration converges (`cloud-cell-supervisor.sh` sources it under `set -a`; `orchestrator-harness/lane-env.sh`
# too), so a `HOME=`/`CELL_HOME=` assignment inside it is not a comment — it re-selects the home of every
# lane that reads it, including one that puts them back in the legacy home. The copy below is
# byte-for-byte (rule 3 forbids reading values), so a poisoned file would be installed faithfully; it is
# therefore GRADED by assignment NAME, REPORTED by `--check` and REFUSED as a copy. Nothing is repaired
# here (rule 2), and no value is ever printed (rule 3).
ENV_FILES="keys.env"

note() { printf '%s\n' "$*"; }
warn_line() { printf 'WARN %s\n' "$*"; }

# volatile_home_assignments <file> — the NAMES (HOME, CELL_HOME) of assignments in a sourceable env file
# whose value is ABSOLUTE, is NOT the durable home, and sits under a volatile root. ⛔ IT NEVER PRINTS A
# VALUE: the caller learns which variable was re-pointed, never what it was set to. Only the shapes such
# a file really carries are parsed (leading blanks, `export `, one layer of quotes).
volatile_home_assignments() {
  local f="$1"
  [ -r "$f" ] || return 0
  awk -v dur="$HOME_DURABLE" -v vol="$CELL_HOME_VOLATILE_ROOTS" '
    BEGIN { n = split(vol, roots, ":") }
    {
      line = $0
      if (line ~ /^[[:space:]]*#/) next
      if (!match(line, /^[[:space:]]*(export[[:space:]]+)?(HOME|CELL_HOME)=/)) next
      name = substr(line, RSTART, RLENGTH)
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", name)
      sub(/=$/, "", name)
      val = substr(line, RLENGTH + 1)
      gsub(/^[[:space:]]+/, "", val); gsub(/[[:space:]]+$/, "", val)
      gsub(/^["\047]/, "", val); gsub(/["\047]$/, "", val)
      if (val == "" || val == dur) next
      if (substr(val, 1, 1) != "/") next
      for (i = 1; i <= n; i++) {
        r = roots[i]
        if (r == "") continue
        if (val == r || index(val, r "/") == 1) { if (!seen[name]++) print name; next }
      }
    }' "$f" 2>/dev/null
}

# report_env_file <rel> <path> <what> — return 1 (naming the VARIABLE, never the value) when a sourceable
# env file re-points HOME/CELL_HOME at a volatile home that is not the durable one.
report_env_file() {
  local rel="$1" f="$2" what="$3" names
  names="$(volatile_home_assignments "$f")"
  [ -n "$names" ] || return 0
  warn_line "  $rel: $what ASSIGNS $(printf '%s ' $names)to a home that is NOT $HOME_DURABLE — a lane that sources this file is put back into the volatile/legacy home. The VALUE is not printed (rule 3); inspect $f by hand. This tool never repairs a credential."
  return 1
}

# describe <path> — "<size>/<mode>/<mtime>" or MISSING. Never the contents; never a value.
describe() {
  local f="$1"
  [ -e "$f" ] || { printf 'MISSING'; return 0; }
  # `stat` differs between GNU and BSD; these two formats are all this needs.
  stat -c '%s bytes mode=%a mtime=%Y' "$f" 2>/dev/null \
    || stat -f '%z bytes mode=%Lp mtime=%m' "$f" 2>/dev/null \
    || printf 'present'
}
mtime_of() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || printf '0'; }
mode_of()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf ''; }

check_credentials() {
  local rel f_leg f_dur rc=0
  note "credentials (durable=$HOME_DURABLE legacy=$HOME_LEGACY)"
  [ -d "$HOME_LEGACY" ] || note "  legacy home is absent — nothing to converge (this box is already on one home)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f_leg="$HOME_LEGACY/$rel"
    f_dur="$HOME_DURABLE/$rel"
    # ⛔ THE CONTENT LEG RUNS FIRST AND INDEPENDENT OF THE LEGACY SIDE. The DURABLE file is what lanes
    # SOURCE, so a re-pointing assignment in it is drift whether or not a legacy copy still exists —
    # the legacy home is reclaimed later, and this check must not disappear with it. Names only, never
    # a value.
    case " $ENV_FILES " in
      *" $rel "*) if [ -e "$f_dur" ]; then report_env_file "$rel" "$f_dur" "the DURABLE copy" || rc=1; fi ;;
    esac
    if [ ! -e "$f_leg" ]; then
      note "  $rel: legacy MIA, durable $(describe "$f_dur")"
      continue
    fi
    if [ ! -e "$f_dur" ]; then
      note "  $rel: legacy $(describe "$f_leg") -> durable MISSING (a copy is what --apply does)"
      rc=1
      # The copy would install the legacy file's ASSIGNMENTS too, so say so now rather than letting the
      # operator meet the refusal in `--apply` with no advance notice.
      case " $ENV_FILES " in *" $rel "*) report_env_file "$rel" "$f_leg" "the LEGACY copy --apply would install" || true ;; esac
      continue
    fi
    note "  $rel: legacy $(describe "$f_leg") | durable $(describe "$f_dur")"
    # BOTH PRESENT. Never overwrite either one. If the legacy copy is NEWER that is a real hazard a
    # human has to settle — a rotated key on the legacy side would otherwise look converged.
    if [ "$(mtime_of "$f_leg")" -gt "$(mtime_of "$f_dur")" ]; then
      warn_line "  $rel: the LEGACY copy is NEWER than the durable one — the two homes have diverged. This tool will not pick a winner (that would silently roll back a rotation). Inspect both by hand (compare mtimes, then move the intended one into $HOME_DURABLE), then re-run."
    fi
  done <<EOF
$CRED_FILES
EOF
  return "$rc"
}

# The credential copy. Only when the durable side is MISSING; mode preserved from the source and
# clamped to 600 for the two secret stores; contents never read, never echoed, never in argv.
migrate_credentials() {
  local rel f_leg f_dur rc=0 mode
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f_leg="$HOME_LEGACY/$rel"
    f_dur="$HOME_DURABLE/$rel"
    # ⛔ THE CONTENT LEG RUNS FIRST AND INDEPENDENT OF THE LEGACY SIDE — same reason as `--check`: the
    # durable file is what lanes source, and the legacy home is reclaimed later, so this report must not
    # vanish with it (and the two modes must not disagree about the same box).
    case " $ENV_FILES " in
      *" $rel "*) if [ -e "$f_dur" ]; then report_env_file "$rel" "$f_dur" "the DURABLE copy" || rc=1; fi ;;
    esac
    [ -e "$f_leg" ] || continue
    if [ -e "$f_dur" ]; then
      note "  kept   $rel (durable copy exists — never overwritten)"
      # ⛔ THE SAME DIVERGENCE WARNING THE CHECK EMITS, EMITTED HERE TOO. `--apply` is the mode where a
      # silent "kept" would read as convergence: if the LEGACY copy is newer, the two homes have
      # diverged and picking either one is an operator's decision, not this tool's.
      if [ "$(mtime_of "$f_leg")" -gt "$(mtime_of "$f_dur")" ]; then
        warn_line "  $rel: the LEGACY copy is NEWER than the durable one — the two homes have diverged. Nothing was written (a rotation would otherwise be rolled back). Inspect both by hand, then re-run."
        rc=1
      fi
      continue
    fi
    mode="$(mode_of "$f_leg")"
    case "$rel" in
      keys.env|.pi/agent/auth.json|.config/gh/hosts.yml) mode=600 ;;
      *) [ -n "$mode" ] || mode=600 ;;
    esac
    # ⛔ A COPY OF A FILE THAT RE-POINTS THE HOME IS NOT CONVERGENCE, IT IS THE SPLIT RE-INSTALLED.
    # Named-and-refused rather than repaired: rule 2 says a credential is never rewritten, and rule 3
    # says its value is never read — so the tool reports WHICH variable is wrong and stops. The durable
    # side stays MISSING deliberately: a missing credential a lane reports is safer than one that
    # silently moves every lane back into the home this migration exists to leave.
    case " $ENV_FILES " in
      *" $rel "*)
        if ! report_env_file "$rel" "$f_leg" "the copy is REFUSED: the LEGACY file"; then
          warn_line "  REFUSED $rel — not copied (edit $f_leg so it names $HOME_DURABLE, then re-run)"
          rc=1; continue
        fi ;;
    esac
    mkdir -p "$(dirname "$f_dur")" 2>/dev/null || { warn_line "  cannot create $(dirname "$f_dur") — $rel NOT copied"; rc=1; continue; }
    # `install` copies bytes without ever putting them in this process's stdout; -m sets the mode in
    # the same syscall, so the file is never momentarily world-readable.
    if install -m "$mode" "$f_leg" "$f_dur" 2>/dev/null; then
      note "  copied $rel -> $f_dur (mode $mode; value not printed)"
    else
      warn_line "  COPY FAILED for $rel (from $f_leg) — refused rather than left half-written"
      rc=1
    fi
  done <<EOF
$CRED_FILES
EOF
  return "$rc"
}

# ── UNITS ─────────────────────────────────────────────────────────────────────────────────────
# The directives whose values this tool will re-base. Anything ELSE that names the legacy home is
# reported UNHANDLED (and makes the run non-converged) rather than silently left behind: a unit is a
# file on disk that a restart reads, so "I did not recognise that line" must never read as "fine".
UNIT_DIRECTIVES='Environment|EnvironmentFile|ExecStart|ExecStartPre|ExecStartPost|ExecStop|ExecStopPost|ExecReload|WorkingDirectory|RootDirectory|ReadWritePaths|ReadOnlyPaths|StandardOutput|StandardError|LogsDirectory|StateDirectory|CacheDirectory|RuntimeDirectory'

# paths_in <line> — every absolute path token in a directive line. The separator set is `=`, whitespace,
# quotes, `,`, `;` AND `:` — a `:` because `Environment=PATH=/a/bin:/usr/bin` is a PATH LIST and each
# element has to be checked on its own: measured while writing this suite, a `:`-less split produced one
# token `/home/cmux/.local/bin:/usr/bin:/bin` that exists as nothing, so EVERY unit carrying a PATH (i.e.
# every real unit) was refused with a "missing target" nobody could explain. Prints one per line.
paths_in() {
  printf '%s' "$1" | tr ' \t"\047;,=:' '\n' | awk '/^\// && !s[$0]++'
}

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
#   * BACKSLASH CONTINUATIONS inherit the previous directive name, because systemd CONCATENATES the
#     lines and expands C-style escapes — a continuation is the same directive, not a new one.
#   * A SIBLING NAME IS NOT THIS HOME. The record test is "the projection CHANGES this line", not "the
#     line contains the legacy string": `/tmp/cell-home.bak` (an operator's pre-migration archive, and
#     the same shape as this tool's own `<file>.pre-cell-home` backups) contains the legacy path as a
#     PREFIX but is a different directory. Emitting a record for it made `--check` call a converged box
#     drifted, and made `--apply` project it to `<home>.bak` — a target nobody has, refused by name.
unit_scan() {
  local f="$1" n=0 line dir projected miss p cont=""
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in ''|'#'*) cont=""; continue ;; esac
    # ⛔ THE PROJECTION IS THE LIB'S RULE, NOT A COPY OF IT. `cell_home_project_line` applies the
    # boundary rule (`/tmp/cell-home-2/x` and `/tmp/cell-home.bak` are not this home), and it is also
    # the record test: an unchanged projection means this line names no legacy home of OURS.
    projected="$(cell_home_project_line "$HOME_DURABLE" "$line")"
    case "$projected" in "$line") cont=""; continue ;; esac
    case "$line" in [A-Za-z]*) dir="${line%%=*}" ;; *) dir="$cont" ;; esac
    case "$dir" in
      "") printf '%s\tUNHANDLED\t%s\t\n' "$n" "$line"; cont=""; continue ;;
    esac
    if ! grep -Eq "^($UNIT_DIRECTIVES)\$" <<<"$dir"; then
      printf '%s\tUNHANDLED\t%s\t\n' "$n" "$line"; cont=""; continue
    fi
    case "$line" in *\\ ) cont="$dir" ;; *) cont="" ;; esac
    miss=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in *'$'*|*'{'*|*'%'*) continue ;; esac   # systemd specifiers are not resolved here
      case "$p" in "$HOME_DURABLE"|"$HOME_DURABLE"/*) ;; *) continue ;; esac   # only what WE introduce
      [ -e "$p" ] || miss="$miss $p"
    done <<EOF
$(paths_in "$projected")
EOF
    printf '%s\t%s\t%s\t%s\n' "$n" "$dir" "$projected" "${miss# }"
  done < "$f"
}

# _project_file <src> <dst> — <src> with every line passed through the SAME projector the scan uses.
# The scan has already accepted the file (no UNHANDLED, every introduced target exists), so a line the
# projector changes is a line the scan graded; anything else is copied byte for byte. A here-string-free
# bash loop on purpose: no external producer, no pipe (#841 SIGPIPE), and no second rewriting rule.
_project_file() {
  local src="$1" dst="$2" line
  : >"$dst" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$(cell_home_project_line "$HOME_DURABLE" "$line")" >>"$dst" || return 1
  done <"$src"
}

# unit_scan_all — every unit/drop-in under the declared dirs, one "<file>\t<record…>" line per hit.
unit_scan_all() {
  local dir f hit
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    # A unit file, and any drop-in under `<unit>.service.d/*.conf` — the two shapes systemd merges.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -q -- "$HOME_LEGACY" "$f" 2>/dev/null || continue
      hit="$(unit_scan "$f")"
      [ -n "$hit" ] || continue
      printf '%s\n' "$hit" | while IFS= read -r rec; do printf '%s\t%s\n' "$f" "$rec"; done
    done <<EOF
$(find "$dir" -maxdepth 2 \( -name '*.service' -o -name '*.timer' -o -name '*.conf' \) -type f 2>/dev/null | LC_ALL=C sort)
EOF
  done <<EOF
$(unit_dirs)
EOF
}

check_units() {
  local scan
  note "units naming the legacy home ($HOME_LEGACY)"
  scan="$(unit_scan_all)"
  if [ -z "$scan" ]; then
    note "  none — every unit and drop-in directive is clear of the legacy home"
    return 0
  fi
  printf '%s\n' "$scan" | while IFS='	' read -r f n dir projected miss; do
    if [ "$dir" = "UNHANDLED" ]; then
      warn_line "  $f:$n names the legacy home in a directive this tool does not re-base — fix or replace that file by hand:
      $projected"
      continue
    fi
    if [ -n "$miss" ]; then
      warn_line "  $f:$n would NOT run after a repoint — the durable counterpart does not exist: $miss
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
  return 1
}

# The rewrite. One file at a time, atomically, with a one-time backup that preserves the mode.
# Writes ONLY the projected lines of directives whose every projected path exists.
migrate_units() {
  local dir f n directive projected miss rec rc=0 applied=0 refused=0 backup tmpdir
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local scan; scan="$(unit_scan "$f")"
      [ -n "$scan" ] || continue
      # Refuse the WHOLE file if any line is unhandled or names a missing durable counterpart: a
      # partially repointed unit is worse than an unmigrated one (it reads as migrated).
      local refuse=0
      while IFS='	' read -r n directive projected miss; do
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
        # Preserve the original mode and ownership, then swap in atomically.
        chmod "$(mode_of "$f")" "$tmpdir" 2>/dev/null || true
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
$(find "$dir" -maxdepth 2 \( -name '*.service' -o -name '*.timer' -o -name '*.conf' \) -type f 2>/dev/null | LC_ALL=C sort)
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
  local dir f
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      awk '/^[[:space:]]*User=/ { v = $0; sub(/^[[:space:]]*User=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); if (v != "") print v }' "$f" 2>/dev/null
    done <<EOF
$(find "$dir" -maxdepth 2 \( -name '*.service' -o -name '*.timer' -o -name '*.conf' \) -type f 2>/dev/null | LC_ALL=C sort)
EOF
  done <<EOF
$(unit_dirs)
EOF
}

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
  local u h conflicts=""
  [ "$HOME_DURABLE_GIVEN" = 0 ] || return 0        # an explicit CELL_HOME is the operator's decision
  # (i) a PRIVILEGED invoker: the resolver answers root's passwd home, which is not a cell home at all.
  if [ "$INVOKER_UID" = 0 ]; then
    warn_line "  REFUSED: refusing to DERIVE the durable home from a privileged invoking account ($INVOKER -> $HOME_DURABLE). The units run as the cell account, not as root, so this would repoint them (and their credentials) into $HOME_DURABLE. Name the home explicitly: sudo -n env CELL_HOME=/home/cmux bash $0 --apply"
    return 1
  fi
  # (ii) the graded units declare an account whose home is not the derived one: the derivation is not
  #      the home they run as, so repointing them would move them off their own tree.
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ "$u" = "root" ] && continue                      # root units genuinely live in /root
    h="$(account_home "$u")" || continue
    [ -n "$h" ] || continue
    [ "$h" = "$HOME_DURABLE" ] && continue
    conflicts="$conflicts $u($h)"
  done <<EOF
$(unit_users | awk '!s[$0]++')
EOF
  if [ -n "$conflicts" ]; then
    warn_line "  REFUSED: the derived durable home $HOME_DURABLE is not the home of the account the graded units run as:$conflicts. Refusing to repoint units onto a home they do not run in — name the home explicitly: CELL_HOME=<that account's home> $0 --apply"
    return 1
  fi
  return 0
}

# ── MAIN ──────────────────────────────────────────────────────────────────────────────────────
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

rc=0
[ "$cred_rc" = 0 ] || rc=1
[ "$units_rc" = 0 ] || rc=1
if [ "$rc" = 0 ]; then
  note "VERDICT: one home — nothing to do"
else
  note "VERDICT: drift found (see WARN lines above)"
fi
exit "$rc"
