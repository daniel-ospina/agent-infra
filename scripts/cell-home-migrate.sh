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
#   0  converged — one home, nothing to do
#   1  drift found (`--check`) / something was refused or left for an operator (`--apply`)
#   3  CANNOT MEASURE — a reading this tool needs could not be taken (named on stderr). Never 0:
#      "could not read" is not "one home".
#
# ── FIXTURE SEAMS (declared, not hidden) ────────────────────────────────────────────────────────
#   CELL_HOME_MIGRATE_UNIT_DIRS   colon list of unit dirs to grade (default: the three below)
#   CELL_HOME_MIGRATE_NO_RELOAD   1 = do not call `systemctl daemon-reload` (a hermetic suite)
#   SYSTEMD_UNIT_DIR / CONTROLLER_SYSTEM_UNIT_DIR / CONTROLLER_USER_UNIT_DIR   the same seams the
#                                 bring-up and the supervisor already read
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)"
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

HOME_DURABLE="$(cell_home_resolve)"
HOME_LEGACY="$CELL_HOME_LEGACY"

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

note() { printf '%s\n' "$*"; }
warn_line() { printf 'WARN %s\n' "$*"; }

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
    if [ ! -e "$f_leg" ]; then
      note "  $rel: legacy MIA, durable $(describe "$f_dur")"
      continue
    fi
    if [ ! -e "$f_dur" ]; then
      note "  $rel: legacy $(describe "$f_leg") -> durable MISSING (a copy is what --apply does)"
      rc=1
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
# <projected-line> is the line with every `$HOME_LEGACY` prefix replaced by `$HOME_DURABLE`.
# <missing-targets> is a space-separated list of projected paths that do NOT exist.
#   * COMMENT and BLANK lines are SKIPPED, never graded: a `#` line cannot affect systemd, and every
#     cell unit carries paragraphs of measured history that mention the legacy path by name. Grading
#     prose would refuse every real unit — the false-block shape this repo treats as its own defect.
#     (Nothing is hidden by skipping them: a comment does not run.)
#   * BACKSLASH CONTINUATIONS inherit the previous directive name, because systemd CONCATENATES the
#     lines and expands C-style escapes — a continuation is the same directive, not a new one.
unit_scan() {
  local f="$1" n=0 line dir projected miss p cont="" pat="$HOME_LEGACY" rep="$HOME_DURABLE"
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in ''|'#'*) cont=""; continue ;; esac
    case "$line" in *"$HOME_LEGACY"*) ;; *) cont=""; continue ;; esac
    case "$line" in [A-Za-z]*) dir="${line%%=*}" ;; *) dir="$cont" ;; esac
    case "$dir" in
      "") printf '%s\tUNHANDLED\t%s\t\n' "$n" "$line"; cont=""; continue ;;
    esac
    if ! printf '%s' "$dir" | grep -Eq "^($UNIT_DIRECTIVES)\$"; then
      printf '%s\tUNHANDLED\t%s\t\n' "$n" "$line"; cont=""; continue
    fi
    case "$line" in *\\ ) cont="$dir" ;; *) cont="" ;; esac
    # ⛔ THE UNQUOTED `${line//$pat/$rep}` IS DELIBERATE (bash 3.2, and this repo runs on macOS):
    # `${line//"$pat"/"$rep"}` makes bash 3.2 splice the QUOTE CHARACTERS into the result, so the
    # projected line became `ExecStart="/home/cmux"/harness/run.sh` — a path that does not exist, so
    # the existence guard then refused every honest unit with a target nobody could explain. Measured
    # while writing this suite, which is why the arms below assert the REWRITE and not just its rc.
    projected="${line//$pat/$rep}"
    miss=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in *'$'*|*'{'*|*'%'*) continue ;; esac   # systemd specifiers are not resolved here
      [ -e "$p" ] || miss="$miss $p"
    done <<EOF
$(paths_in "$projected")
EOF
    printf '%s\t%s\t%s\t%s\n' "$n" "$dir" "$projected" "${miss# }"
  done < "$f"
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
  local scan rc=0
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
      note "  $f:$n  $dir=…  ->  durable counterpart exists"
    fi
  done
  # The report above runs in a subshell, so the VERDICT is derived again here rather than borrowed
  # from it: a loop's exit status cannot speak for a pipeline.
  if printf '%s\n' "$scan" | awk -F'\t' '{ if ($3=="UNHANDLED") bad=1; else if ($5 != "") bad=1 } END { exit bad?0:1 }'; then
    rc=1
  fi
  return "$rc"
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
      if [ ! -w "$f" ]; then
        warn_line "  REFUSED $f — not writable by $(id -un). Re-run the unit half as root: sudo -n bash $0 --apply"
        refused=$((refused + 1)); rc=1; continue
      fi
      # Write: a per-file awk pass that re-bases only the graded directives, so words the tool did
      # not classify are untouched byte for byte.
      backup="$f.pre-cell-home"
      [ -e "$backup" ] || { cp -p "$f" "$backup" 2>/dev/null || { warn_line "  cannot back up $f — refusing to write it"; rc=1; continue; }; }
      tmpdir="$(mktemp "${f}.cell-home.XXXXXX" 2>/dev/null)" || { warn_line "  cannot create a temp file beside $f — refusing to write it"; rc=1; continue; }
      if LC_ALL=C awk -v legacy="$HOME_LEGACY" -v durable="$HOME_DURABLE" -v dirs="^($UNIT_DIRECTIVES)=" '
          {
            line = $0
            if (index(line, legacy) == 0) { print line; next }
            d = line; sub(/=.*$/, "", d)
            if (line ~ dirs) {
              out = ""
              while ((i = index(line, legacy)) > 0) {
                out = out substr(line, 1, i - 1) durable
                line = substr(line, i + length(legacy))
              }
              print out line
              next
            }
            print line
          }' "$f" >"$tmpdir" 2>/dev/null; then
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

# ── MAIN ──────────────────────────────────────────────────────────────────────────────────────
note "cell-home-migrate: mode=$MODE"
note "  durable home: $HOME_DURABLE  (derived by scripts/lib/cell-home.sh)"
note "  legacy home:  $HOME_LEGACY   (never deleted by this tool)"
if [ "$HOME_DURABLE" = "$HOME_LEGACY" ]; then
  warn_line "  the derived durable home IS the legacy home — refusing to grade a box against itself; set CELL_HOME to the durable home (agent-infra#3453)"
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
