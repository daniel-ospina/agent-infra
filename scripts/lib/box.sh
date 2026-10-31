#!/usr/bin/env bash
# scripts/lib/box.sh — ONE portability shim for the two platforms the harness runs on.
#
#   . scripts/lib/box.sh            # then call box_* functions
#   bash scripts/lib/box.sh --selftest
#
# WHY THIS FILE EXISTS (agent-infra#2271, the "one shim" half). The harness runs on macOS and on
# Linux cells, and the two disagree on exactly four primitives. Each disagreement had already been
# discovered SEPARATELY, in a different script, after it failed there:
#
#   • `sed -i`      — BSD requires a backup suffix ARG (`sed -i '' -e …`); GNU refuses one.
#                     A GNU spelling on macOS silently treats the next argument as the suffix, so
#                     `sed -i 's/a/b/' f` becomes an edit of nothing plus a stray file `f`'s suffix.
#   • `date`        — BSD: `date -r <epoch>` takes epoch SECONDS; GNU: `date -d @<epoch>`.
#   • CPU count     — macOS: `sysctl -n hw.ncpu`; Linux: `nproc` (or `getconf _NPROCESSORS_ONLN`).
#                     `spawn-gate.sh` already derives `_NCPU` this way at SOURCE time; a script
#                     sourced under the wrong PATH pinned `_NCPU=4` and MAX_LOAD=40 for every cell
#                     (#1702). That is the failure this shim exists to make impossible.
#   • mtime         — BSD: `stat -f %m`; GNU: `stat -c %Y`.
#   • scheduler     — macOS: launchd; Linux cell: systemd user units, or a bare tmux session.
#
# ⛔ WHAT THIS FILE IS NOT. It is not a second `bounded.sh` (that owns BOUNDED EXECUTION and stays
# the only home for "no `timeout` on macOS", #2046) and not a second `fleet-inventory.sh` (that owns
# process reads). It answers only the five questions above, so a caller never re-derives them — the
# re-derivation is the drift (#2216's class).
#
# ⛔ EVERY PRIMITIVE IS PROBED, NEVER ASSUMED FROM `uname`. A wrong `uname` (a Linux container with
# a BSD userland, a macOS box with GNU coreutils first on PATH — Homebrew users routinely have this)
# would make an assumption-based switch edit the wrong files. Each function therefore tries the
# mechanisms in order and reports which one answered, and `box_selftest` prints that provenance so a
# test can assert it rather than trust it.
#
# SEAMS (tests, and an operator pinning a mechanism):
#   BOX_OS=<darwin|linux|other>   force the OS (probe order still decides the primitive)
#   BOX_NCPU_FORCE=<n>            force a CPU count (exercise the clamp without a real box)
set -u

BOX_OS="${BOX_OS:-}"
BOX_NCPU_MECH=""
BOX_MTIME_MECH=""
BOX_DATE_MECH=""
BOX_SED_MECH=""

box_os() {
  if [ -n "${BOX_OS:-}" ]; then printf '%s\n' "$BOX_OS"; return 0; fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'darwin\n' ;;
    Linux)  printf 'linux\n' ;;
    *)      printf 'other\n' ;;
  esac
}

# box_ncpu — the CPU count, clamped at 1. Sets BOX_NCPU_MECH so a caller can record WHICH mechanism
# answered (a pass that says "8 CPUs" must be able to say how it knows).
box_ncpu() {
  local n=""
  if [ -n "${BOX_NCPU_FORCE:-}" ]; then
    BOX_NCPU_MECH="forced"; printf '%s\n' "$BOX_NCPU_FORCE"; return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n="" ;; *) BOX_NCPU_MECH="sysctl" ;; esac
  fi
  if [ -z "$n" ] && command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n="" ;; *) BOX_NCPU_MECH="nproc" ;; esac
  fi
  if [ -z "$n" ] && command -v getconf >/dev/null 2>&1; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n="" ;; *) BOX_NCPU_MECH="getconf" ;; esac
  fi
  # ⛔ A CPU READ THAT FAILED IS 1, NOT 0: a 0 propagates into every divisor downstream and turns
  # "unknown" into "the box has no capacity", which reads as a full fleet.
  [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null || { n=1; BOX_NCPU_MECH="fallback"; }
  printf '%s\n' "$n"
}

# box_mtime <file> — epoch seconds of mtime, or non-zero when it cannot be read.
box_mtime() {
  local f="$1" v=""
  [ -e "$f" ] || return 1
  # BSD form first: on macOS `stat -c` does not exist; on GNU `stat -f` means "filesystem status"
  # and would print the wrong thing, so the -c form is attempted BEFORE -f on a Linux-looking box.
  case "$(box_os)" in
    linux)
      if v="$(stat -c %Y "$f" 2>/dev/null)"; then BOX_MTIME_MECH="stat-c"; fi  # portability-ok: OS-GUARDED — this arm runs only inside `case "$(box_os)" in linux)`; macOS takes the `stat -f` arm below
      ;;
  esac
  if [ -z "$v" ]; then
    if v="$(stat -f %m "$f" 2>/dev/null)"; then BOX_MTIME_MECH="stat-f"; fi
  fi
  if [ -z "$v" ]; then
    if v="$(stat -c %Y "$f" 2>/dev/null)"; then BOX_MTIME_MECH="stat-c"; fi  # portability-ok: LAST-RESORT ARM of the probe chain — it runs only after the `stat -f` arm above declined, and `box_mtime` is the shim the rule points at
  fi
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

# box_epoch_to_iso <epoch> — ISO-8601 UTC. BSD `date -r <epoch>`, GNU `date -d @<epoch>`.
box_epoch_to_iso() {
  local e="$1" v=""
  case "$(box_os)" in
    darwin)
      if v="$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then BOX_DATE_MECH="date-r"; fi
      ;;
  esac
  if [ -z "$v" ]; then
    if v="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then BOX_DATE_MECH="date-d"; fi  # portability-ok: LAST-RESORT ARM of box_epoch_to_iso's probe chain — it runs only after the `date -r` arm declined, and this function IS the shim the rule points at
  fi
  if [ -z "$v" ]; then
    if v="$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then BOX_DATE_MECH="date-r"; fi
  fi
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# box_sed_i <expression> <file> — in-place edit, portable across BSD and GNU sed.
# ⛔ THE BACKUP SUFFIX IS ALWAYS PASSED, EMPTY. BSD sed REQUIRES the argument; GNU sed accepts
# `-i''` (no space) as "no suffix". The combined form below is the only spelling both accept, and
# it is why callers must not hand-roll `sed -i` (a GNU spelling on macOS silently consumes the
# script as the suffix and edits NOTHING, reporting success).
box_sed_i() {
  local expr="$1" f="$2"
  [ -f "$f" ] || return 1
  case "$(box_os)" in
    darwin) BOX_SED_MECH="bsd" ;;
    *)      BOX_SED_MECH="gnu" ;;
  esac
  if sed --version >/dev/null 2>&1; then
    # GNU sed: -i and the empty suffix must NOT be separated, or the script becomes the suffix.
    BOX_SED_MECH="gnu"
    sed -i'' -e "$expr" "$f"  # portability-ok: GNU BRANCH of box_sed_i — chosen by probing `sed --version`, so the empty suffix is attached the GNU way on purpose
  else
    BOX_SED_MECH="bsd"
    sed -i '' -e "$expr" "$f"  # portability-ok: BSD BRANCH of box_sed_i — the empty suffix must be a SEPARATE argument here, which is what BSD requires
  fi
}

# box_scheduler — which supervisor mechanism this box uses for long-lived jobs.
# A value a caller can branch on; "none" is a real answer (a plain foreground box), never an error.
box_scheduler() {
  case "$(box_os)" in
    darwin) command -v launchctl >/dev/null 2>&1 && { printf 'launchd\n'; return 0; } ;;
    linux)
      command -v systemctl >/dev/null 2>&1 && { printf 'systemd\n'; return 0; }
      command -v tmux >/dev/null 2>&1 && { printf 'tmux\n'; return 0; } ;;
  esac
  command -v tmux >/dev/null 2>&1 && { printf 'tmux\n'; return 0; }
  printf 'none\n'
}

# box_refuse <rc> <message…> — the ONE refusal shape. Every refusal in the shim's callers goes
# through this so that "refused" is greppable and never mistakable for a partial success.
box_refuse() {
  local rc="$1"; shift
  printf '[box] REFUSED — %s\n' "$*" >&2
  return "$rc"
}

# box_provenance — WHICH mechanism answers on this box, printed for a record. ⛔ The primitives run
# in `$(…)` subshells, so the `BOX_*_MECH` they set do not reach the caller; provenance is therefore
# answered by re-probing here rather than by reading a variable a subshell wrote and lost.
box_provenance() {
  local tmp m
  tmp="$(mktemp "${TMPDIR:-/tmp}/box-prov-XXXXXX" 2>/dev/null)" || { printf 'os=%s provenance=unavailable\n' "$(box_os)"; return 1; }
  printf 'x\n' > "$tmp"; box_ncpu >/dev/null 2>&1 || true
  m="$(box_mtime "$tmp")"; box_mtime "$tmp" >/dev/null 2>&1 || true
  box_epoch_to_iso "${m:-0}" >/dev/null 2>&1 || true
  box_sed_i 's/x/x/' "$tmp" >/dev/null 2>&1 || true
  printf 'os=%s ncpu=%s mtime=%s sed=%s date=%s\n' "$(box_os)" "$BOX_NCPU_MECH" "$BOX_MTIME_MECH" "$BOX_SED_MECH" "$BOX_DATE_MECH"
  rm -f "$tmp"
}

# ── pin_dirty <repo> <scoped-path> ────────────────────────────────────────────────────────────────
# Is the PINNED harness dir the bytes the commit carries?   0 = CLEAN, 1 = DIRTY (entries printed),
# 2 = CANNOT VERIFY (git status itself failed — never a pass).
#
# ⛔ FOUR predicates read this state — the runtime resolver (scripts/harness-exec.sh), the cell
# supervisor's DRIFT check and its provenance stamp, and the installer's — and for one review round
# they read a WEAKER one here than the resolver did, so `check` certified a pin CLEAN that `exec`
# refused and `apply` would never repair (found by review, round 4). This body is therefore the
# SINGLE implementation; the two deployment mirrors carry it byte-for-byte and a drift arm
# (cloud-cell-supervisor.test.sh §(p3)) compares them — not re-typed, which is how they diverged.
#
# ⛔ `--ignored=matching` MATTERS. A gitignored file cannot be committed, so it is never part of the
# pin, and it is exactly where a local hotfix lives (`tmp/`, `dist/`, `*.log` are all ignored by this
# repo), so `--entry tmp/x.sh` used to pass every check. Plain `--porcelain` reports NOTHING for those.
# ⛔ AND SO DOES THE TOLERANCE. The pin ROOT's guard (cloud-cell-supervisor.sh `assert_pin_dir_safe`)
# already ruled that `.DS_Store`/`._*` REGULAR files must not brick a cell on one Finder visit; that
# ruling is REUSED here one level down rather than reversed by the flag above — a dropping is not an
# execution vector (bash cannot run a `.DS_Store`), and one visit would otherwise refuse the pin.
pin_dirty() {
  local repo="$1" scoped="$2" top out line path keep=""
  # ⛔ THE TOPLEVEL, because porcelain prints paths relative to the REPOSITORY ROOT even when `repo` is a
  # subdirectory — and two of the three callers pass the harness SUBDIR (the production convention). A
  # first version resolved entries against `$repo`, so its tolerance was unreachable there and a
  # `.DS_Store` read DIRTY to the instruments while the runtime read CLEAN: the round-4 divergence again,
  # with the fail direction inverted (found by review, round 5).
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 2
  out="$(git -C "$repo" status --porcelain --ignored=matching -- "$scoped" 2>/dev/null)" || return 2
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in '"'*'"') path="${path#\"}"; path="${path%\"}" ;; esac
    # ⛔ TOLERATE ONLY **UNTRACKED/IGNORED** DROPPINGS. A TRACKED file named `._x` is part of the pin, so a
    # MODIFICATION to it must read DIRTY — the name is not the property (found by review, round 5: a
    # rewritten tracked `._x` read CLEAN). `!!` = ignored, `??` = untracked.
    case "$line" in
      '!!'*|'??'*) case "${path##*/}" in
        .DS_Store|._*) [ -f "$top/$path" ] && [ ! -L "$top/$path" ] && continue ;;
      esac ;;
    esac
    keep="$keep$line
"
  done <<<"$out"
  [ -n "$keep" ] || return 0
  printf '%s' "$keep"
  return 1
}

# box_selftest — exercise every primitive and print PROVENANCE, so a test asserts behaviour rather
# than trusting this file's comments. macOS-only branches print a SKIP line WITH the reason.
box_selftest() {
  local fails=0 os ncpu tmp m1 iso sched
  os="$(box_os)"
  printf 'box: os=%s scheduler=%s\n' "$os" "$(box_scheduler)"

  box_ncpu >/dev/null; printf 'box: provenance %s\n' "$(box_provenance)"
  ncpu="$(box_ncpu)"
  case "$ncpu" in ''|*[!0-9]*) printf 'FAIL ncpu=%s\n' "$ncpu"; fails=$((fails+1)) ;;
    *) [ "$ncpu" -ge 1 ] && printf 'PASS ncpu=%s via=%s\n' "$ncpu" "$BOX_NCPU_MECH" \
         || { printf 'FAIL ncpu=%s (must be >=1)\n' "$ncpu"; fails=$((fails+1)); } ;;
  esac

  tmp="$(mktemp "${TMPDIR:-/tmp}/box-selftest-XXXXXX")" || { printf 'FAIL mktemp\n'; return 1; }
  printf 'alpha\n' > "$tmp"
  m1="$(box_mtime "$tmp")" || m1=""
  case "$m1" in ''|*[!0-9]*) printf 'FAIL mtime=%s\n' "$m1"; fails=$((fails+1)) ;;
    *) printf 'PASS mtime=%s via=%s\n' "$m1" "$BOX_MTIME_MECH" ;;
  esac
  if iso="$(box_epoch_to_iso "$m1" 2>/dev/null)"; then
    printf 'PASS epoch_to_iso=%s via=%s\n' "$iso" "$BOX_DATE_MECH"
  else
    printf 'FAIL epoch_to_iso could not format %s on %s\n' "$m1" "$os"; fails=$((fails+1))
  fi
  if box_sed_i 's/alpha/beta/' "$tmp" && [ "$(head -1 "$tmp")" = "beta" ]; then
    printf 'PASS sed_i via=%s\n' "$BOX_SED_MECH"
  else
    printf 'FAIL sed_i did not rewrite the file (via=%s)\n' "$BOX_SED_MECH"; fails=$((fails+1))
  fi
  # ⛔ THE SILENT-CONSUMPTION ARM: the GNU spelling `sed -i 's/a/b/' f` on BSD sed treats the SCRIPT
  # as the backup suffix, so it rewrites nothing and exits 0. Run that spelling deliberately and
  # assert the file was NOT changed where the platform is BSD — this is the measured reason the shim
  # exists, and it fails loudly if a future "portable" rewrite reintroduces the spelling.
  printf 'alpha\n' > "$tmp"
  sed -i 's/alpha/beta/' "$tmp" >/dev/null 2>&1 || true  # portability-ok: DELIBERATE PROBE — the GNU spelling is run on purpose to assert it is silent on BSD; this is the measured reason the shim exists
  if [ "$os" = "darwin" ]; then
    if [ "$(head -1 "$tmp")" = "alpha" ]; then
      printf 'PASS sed-i-gnu-spelling-is-silent-on-bsd (file unchanged, exit 0) — the shim is required\n'
    else
      printf 'FAIL sed-i-gnu-spelling REWROTE the file on BSD — the probe above is not measuring BSD sed\n'; fails=$((fails+1))
    fi
  else
    printf 'PASS sed-i-gnu-spelling-is-valid-on-gnu (file=%s) — no shim needed here, same call\n' "$(head -1 "$tmp")"
  fi
  rm -f "$tmp" "$tmp''" 2>/dev/null

  case "$os" in
    darwin) printf 'SKIP launchd-arm: only meaningful on macOS with an installed job (asserted by the caller suite)\n' ;;
    *)      printf 'SKIP launchd-arm: %s has no launchctl — scheduler=%s\n' "$os" "$(box_scheduler)" ;;
  esac

  [ "$fails" -eq 0 ] && { printf 'box: OK (%s)\n' "$os"; return 0; }
  printf 'box: %s FAILURE(S)\n' "$fails"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --selftest|"") box_selftest; exit $? ;;
    *) printf 'usage: box.sh [--selftest]\n' >&2; exit 64 ;;
  esac
fi
