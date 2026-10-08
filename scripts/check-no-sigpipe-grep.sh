#!/usr/bin/env bash
# check-no-sigpipe-grep.sh — #841: fail the build if the SIGPIPE false-negative idiom returns.
#
# THE BUG CLASS
# -------------
#   printf '%s' "$TEXT"  piped into  grep -q 'PATTERN'     # ⛔ never write this again
#
# Under `set -o pipefail`, `grep -q` exits at its FIRST match while the writer is still
# pushing bytes. The writer then takes SIGPIPE (141) and, because `pipefail` reports the
# last non-zero status of the pipeline, the PIPELINE status becomes non-zero — so the `if`
# takes the ELSE branch and a fail-closed gate reports a FALSE NEGATIVE. The message it
# prints asserts a content problem ("no scoping comment", "no code-review evidence") when
# the text was there all along.
#
# Observed 2026-09-12 on PR #751: `pipeline-compliance` — the repo's ONLY required status
# check — blocked a compliant PR with `printf: write error: Broken pipe`, while the
# identical invocation passed on a developer machine (see WINDOWS OF FAILURE below).
#
# WINDOWS OF FAILURE (why this looked flaky, and why "it works locally" proves nothing)
# ------------------------------------------------------------------------------------
# The race needs ALL of:
#   1. `pipefail` active in the invoking shell,
#   2. a payload larger than the pipe buffer (~64 KiB) AFTER the match,
#   3. the match on an early *line*, so grep can exit having read only a prefix —
#      grep matches line-by-line, so a single giant line forces it to read everything
#      and the race never fires.
# Cause 3 is why a payload-shape test that pads with one long line is vacuous, and why
# `tests/sigpipe-grep/run.sh` pads with many SHORT LINES. Cause 2 is why short-payload
# tests cannot catch this class at all.
#
# THE FIX
# -------
# A here-string: `grep -q 'PATTERN' <<<"$TEXT"`. Bash backs it with a temp file, so there
# is no earlier writer left to kill. Every grep flag is preserved (-q, -qi, -qE, -qx, -qF)
# and the empty-string case behaves identically for every pattern that does not match an
# empty line. Requires bash — here-strings are a bash feature, so in a POSIX `sh` script
# (`#!/usr/bin/env sh`, e.g. the `.husky/` hooks) capture first instead:
#     out="$(cmd)"; grep -q PAT <<<"$out"        # bash
#     out="$(cmd)"; [ -n "$out" ] && case "$out" in *PAT*) ... ;; esac   # POSIX
#
# SCOPE — WHAT THIS GUARD DOES NOT COVER (deliberate)
# ---------------------------------------------------
# It matches the BUILTIN writers `printf`/`echo` only, because that is the set where the
# fix is mechanical and universal. The same false negative is reachable with ANY producer
# (`git … | grep -q`, `docker … | grep -q`, a function's output) — see the data-loss sites
# fixed in `scripts/stale-worktrees.sh`/`scripts/cleanup-worktree.sh` (#863) and the
# follow-up issue for broadening this guard. Do not read a green run as "no SIGPIPE risk
# exists anywhere"; read it as "the builtin-writer idiom is gone".
#
# WHAT IS SCANNED, AND WHERE THIS GUARD HAS TO RUN
# ------------------------------------------------
# The scan set and the exceptions file are resolved for the repo UNDER SCAN, not for this
# one: `--dirs '<space-separated dirs>'` (or the `SIGPIPE_SCAN_DIRS` env var) replaces the
# default `scripts .husky pi-bootstrap`, and a `.sigpipe-grep-exceptions.txt` at the scan
# root replaces the shared `scripts/…` path. Both knobs exist because this guard is shared
# BY SYMLINK — in a consumer repo `scripts/` points back HERE, so the default set scans the
# wrong tree and the exceptions file is one the consumer cannot write. Wire it into a
# consumer's CI with an explicit `--dirs` for its own layout: a guard that is present but
# never invoked is a guard that has not run (tortoise#7588, where the shared `scripts/`
# symlink made this guard invisible to the repo the four data-loss sites shipped in).
#
# DECLARED EXCEPTIONS (a blocked fix is recorded, never hidden)
# ------------------------------------------------------------
# `scripts/sigpipe-grep-exceptions.txt` (or `.sigpipe-grep-exceptions.txt` at the scan root)
# declares `<path> <count> <content-hash> #<issue>`
# for occurrences that CANNOT currently be fixed — see that file. Guarantees:
#   · an exception is printed LOUDLY on every run (never a silent mute),
#   · a declaration whose COUNT or CONTENT-HASH does not match the file FAILS the guard,
#     so neither a stale exception nor a count-preserving swap can hide behind one,
#   · an exception with no tracking issue is rejected.
#
# SELF-SCAN: the guard includes ITSELF (no self-exclusion). An earlier revision skipped its
# own path and review round 1 found a genuine occurrence hiding in that blind spot. The
# header/remedy prose is written so it never spells the literal pipeline.
#
# EXIT: 0 clean (possibly with declared exceptions) · 1 the idiom is present · 2 usage

set -uo pipefail

ROOT=""
SCAN_DIRS_ARG=""
DIRS_FLAG_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "check-no-sigpipe-grep: --root needs a directory" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    --dirs)
      [ $# -ge 2 ] || { echo "check-no-sigpipe-grep: --dirs needs a space-separated list" >&2; exit 2; }
      SCAN_DIRS_ARG="$2"; DIRS_FLAG_GIVEN=1; shift 2 ;;
    -h|--help)
      sed -n '2,/^# EXIT: /p' "$0"; exit 0 ;;
    *) echo "check-no-sigpipe-grep: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[ -d "$ROOT" ] || { echo "check-no-sigpipe-grep: not a directory: $ROOT" >&2; exit 2; }

# A consumer repo overrides the set through `--dirs`/`SIGPIPE_SCAN_DIRS`; the default is
# this repo's own layout, so an unparameterised run here behaves exactly as it always has.
# The FLAG-FIRST test is on "was --dirs given", not on the value being non-empty: `--dirs ''`
# must be an error, never a quiet fall back to the default set (which, in a consumer whose
# `scripts/` symlinks back here, would scan THIS tree and print a clean run — #7588 itself).
if [ "$DIRS_FLAG_GIVEN" -eq 1 ]; then
  # `read -a` consumes ONE line, so a newline-separated value (a CI variable delivered as a
  # YAML block) would be silently truncated to its first dir — and the dropped ones would
  # never be validated. Refuse it rather than scan a subset that looks complete.
  case "$SCAN_DIRS_ARG" in *$'\n'*) echo "check-no-sigpipe-grep: --dirs must be one line (space-separated; a newline would silently truncate the set)" >&2; exit 2 ;; esac
  read -r -a SCAN_DIRS <<<"$SCAN_DIRS_ARG"
# The test is on whether the VALUE IS SET AT ALL, not on it being non-empty: an explicit
# knob that arrives EMPTY (e.g. `env: SIGPIPE_SCAN_DIRS: ${{ vars.X }}` forwarded with X
# unset) must be an error, not a quiet fall back to the default set — in a consumer whose
# `scripts/` symlinks back here that fallback scans THIS tree and prints a clean run (#7588).
elif [ -n "${SIGPIPE_SCAN_DIRS+x}" ]; then
  case "${SIGPIPE_SCAN_DIRS}" in *$'\n'*) echo "check-no-sigpipe-grep: SIGPIPE_SCAN_DIRS must be one line (space-separated; a newline would silently truncate the set)" >&2; exit 2 ;; esac
  read -r -a SCAN_DIRS <<<"$SIGPIPE_SCAN_DIRS"
else
  SCAN_DIRS=(scripts .husky pi-bootstrap)
fi

# An empty resolution scans zero files and prints a clean run, so it is a usage error.
# `${arr[@]+...}` keeps this safe under `set -u` on bash 3.2, where a zero-element array
# has no `${arr[@]}` to expand at all.
NONEMPTY=0
for _d in ${SCAN_DIRS[@]+"${SCAN_DIRS[@]}"}; do NONEMPTY=1; break; done
[ "$NONEMPTY" -eq 1 ] || {
  echo "check-no-sigpipe-grep: the scan set is empty — name at least one directory" >&2; exit 2; }
unset NONEMPTY _d

# Resolved in the repo UNDER SCAN, so a consumer can declare its own blocked fixes —
# `scripts/` is the symlink it cannot write through. The shared path stays the fallback.
if [ -f "$ROOT/.sigpipe-grep-exceptions.txt" ]; then
  EXC_FILE=".sigpipe-grep-exceptions.txt"
else
  EXC_FILE="scripts/sigpipe-grep-exceptions.txt"
fi

# `find` errors are NOT discarded. A directory it cannot descend, or a symlink loop, makes
# `find` print an error and yield a PARTIAL list — which is a clean run over files that were
# never read, the guard's cardinal sin (#7588 review round 5). Readability of the scan dir
# itself is checked above; this catches everything underneath it.
FIND_ERRS="$(mktemp)"
trap 'rm -f "$FIND_ERRS"' EXIT

# `find -L` so a scan dir that is a SYMLINK is still descended into (consumer repos
# symlink `scripts/` back to this repo; plain `find` returns nothing and the guard would
# print "clean" after scanning zero files).
#
# SELECTION IS BY NAME **OR SHEBANG**, not by name alone. `.husky/` hooks are extensionless
# POSIX-sh files, and so are most of `.github/scripts/` — including an extensionless script
# that shipped the very false negative this guard exists to catch (tortoise#7588). A
# `-name '*.sh'` filter reports a clean run having never read them.
is_shell_file() {
  case "$1" in
    *.sh|*.bash) return 0 ;;
  esac
  # The BASENAME must carry the extension for it to be "a file we do not claim". Matching
  # the whole PATH against `*/*.*` is wrong: `*` crosses `/`, so `scripts/v2.1/deploy` and
  # `.github/scripts/v1.0/deploy` matched it on a DIRECTORY's dot and were skipped without
  # their shebang ever being read — a clean run on a real occurrence (#7588 review).
  local base="${1##*/}"
  case "$base" in
    .*.*) return 1 ;;   # a dotfile that carries a further extension (.env.local)
    ?*.*) return 1 ;;   # an ordinary name that carries an extension (foo.txt)
  esac
  # Extensionless: claim it only if its first line names a SHELL. Captured first, never
  # piped into a quiet grep — that is the very idiom this guard exists to catch.
  # The interpreter TOKEN must be sh/bash: a bare `*sh*` also claims fish/tcsh/zsh/xonsh,
  # which have no `pipefail` and where the printed remedy (a bash here-string) is invalid.
  # Read a BOUNDED prefix. `head -1` on a file with no newline reads to EOF, so a large
  # extensionless non-shell file would be materialised into a shell variable (measured on
  # bash 3.2: a 300 MB no-newline file cost 82s and 315 MB RSS, vs 0.21s when it was
  # skipped). Real binaries stop at their first newline anyway; this bound stops the cost
  # depending on that luck.
  local chunk first
  # 4096, not 512: a real shebang is a few dozen bytes, but a cap that clips the interpreter
  # token would be a false NEGATIVE (the old unbounded `head -1` would have claimed it).
  chunk="$(head -c 4096 "$1" 2>/dev/null)"
  first="${chunk%%$'\n'*}"
  case "$first" in
    '#!'*/sh|'#!'*/sh[[:space:]]*|'#!'*/bash|'#!'*/bash[[:space:]]*|\
    '#!'*[[:space:]]sh|'#!'*[[:space:]]sh[[:space:]]*|\
    '#!'*[[:space:]]bash|'#!'*[[:space:]]bash[[:space:]]*) return 0 ;;
  esac
  return 1
}

scan_files() {
  # Normalise the dir before taking the basename. `${dir%/}` strips ONE slash, so `.husky//`
  # still took the wrong branch, and `.husky/.` reached it too — the same green-over-zero
  # files this normalization exists to close (#7588 review round 4).
  local dir="$1"
  while :; do
    case "$dir" in
      */) dir="${dir%/}" ;;
      */. ) dir="${dir%/.}" ;;
      *) break ;;
    esac
  done
  # A path starting with `-` is parsed by `find` as a predicate (`find: illegal option`),
  # which fails into a discarded stderr and an empty list: green, nothing scanned. `./`
  # disambiguates; the reported paths then keep the prefix, so a declaration needs it too.
  local target="$dir"
  case "$dir" in -*) target="./$dir" ;; esac
  # The basename decides, so `$ROOT/.husky` and `.husky` select identically — otherwise the
  # count pre-pass and the scan disagree about which files were read.
  case "${dir##*/}" in
    .husky) find -L "$target" -type f 2>>"$FIND_ERRS" ;;
    *) find -L "$target" -type f 2>>"$FIND_ERRS" | while IFS= read -r f; do
         is_shell_file "$f" && printf '%s\n' "$f"
       done ;;
  esac
}

# An EXPLICITLY named set must be real: a typo (or a consumer's `scripts/` symlink) that
# resolves to nothing would otherwise print "✅ clean" having read no file at all. The
# DEFAULT set tolerates an absent dir, because `.husky`/`pi-bootstrap` are not in every repo.
if [ "$DIRS_FLAG_GIVEN" -eq 1 ] || [ -n "${SIGPIPE_SCAN_DIRS+x}" ]; then
  STRICT_DIRS=1
else
  STRICT_DIRS=0
fi

# Validate the dirs first (cheap), then select the files ONCE — the count and the scan both
# read that one list, so the `find` traversal and the per-file shebang read are not paid
# twice (measured: the duplicate pass was ~43% of the run).
for d in ${SCAN_DIRS[@]+"${SCAN_DIRS[@]}"}; do
  # Absolute dirs are honoured: `$ROOT/$d` would prepend a root to a path that already has
  # one, so an absolute --dirs was reported as "does not exist" (a false block) or matched a
  # decoy directory under $ROOT.
  case "$d" in /*) scan_dir="$d" ;; *) scan_dir="$ROOT/$d" ;; esac
  # `-e` alone is not enough: an existing but UNREADABLE dir passes it, `find` then fails into
  # a discarded stderr, and the guard reports a clean run over zero files (#7588 review round 4).
  # `-r` is required for either; `-x` (SEARCH) only for a DIRECTORY, since that is what `find`
  # needs to descend. Requiring `-x` of a named FILE made `--dirs somefile.sh` a false block.
  if [ ! -e "$scan_dir" ] || [ ! -r "$scan_dir" ] || { [ -d "$scan_dir" ] && [ ! -x "$scan_dir" ]; }; then
    [ "$STRICT_DIRS" -eq 1 ] && {
      echo "check-no-sigpipe-grep: scan dir does not exist, or is not readable and searchable: $d (pass --dirs with this repo's layout)" >&2
      exit 2; }
  fi
done
unset scan_dir

FILE_LIST="$(
  cd "$ROOT" || exit 2
  for d in "${SCAN_DIRS[@]}"; do
    # An ABSENT dir is SKIPPED here, never scanned: the default set tolerates `.husky` and
    # `pi-bootstrap` being absent, and `find` on a missing path would populate FIND_ERRS and
    # turn every such run into a false exit 2. Existence of an EXPLICITLY named dir was
    # already enforced above.
    [ -e "$d" ] && scan_files "$d"
  done
)"
FILE_COUNT="$(printf '%s\n' "$FILE_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"

# A partial scan is not a clean scan: if `find` could not read part of the tree, say so and
# stop rather than report a verdict over an unknown subset.
if [ -s "$FIND_ERRS" ]; then
  echo "check-no-sigpipe-grep: could not fully scan every file — a partial scan is not a clean scan:" >&2
  cat "$FIND_ERRS" >&2
  exit 2
fi

HITS="$(
  cd "$ROOT" || exit 2
  printf '%s\n' "$FILE_LIST" | sed '/^$/d' | sort | while IFS= read -r f; do
    awk -v F="$f" '
      # does the text after "grep " carry a quiet flag?  (-q, -Fqx, -iq, --quiet)
      function has_quiet(s,   n, i, parts, t) {
        n = split(s, parts, /[ \t]+/)
        for (i = 1; i <= n; i++) {
          t = parts[i]
          if (t == "--quiet") return 1
          if (t == "--") return 0
          if (t ~ /^-[A-Za-z]*q[A-Za-z]*$/) return 1
          if (t !~ /^-/) return 0
        }
        return 0
      }
      # a pure comment or blank line is documentation: it cannot execute, so it is skipped
      # (otherwise a script that merely DOCUMENTS the anti-pattern fails the build).
      /^[ \t]*#/ || /^[ \t]*$/ { if (buf != "") { if (match(buf, /(printf|echo)[^|]*\|[ \t]*grep[ \t]+/) && has_quiet(substr(buf, RSTART + RLENGTH))) print F ":" start ": " buf } ; buf = ""; start = 0; next }
      {
        raw = $0
        if (start == 0) start = NR
        # join a continuation: an explicit trailing backslash AND a pipeline broken after a
        # bare `|` (both are legal bash line breaks)
        if (raw ~ /\\[ \t]*$/ || raw ~ /\|[ \t]*$/) {
          sub(/\\[ \t]*$/, "", raw); sub(/\|[ \t]*$/, "|", raw)
          buf = buf raw " "
          next
        }
        joined = buf raw; buf = ""
        if (match(joined, /(printf|echo)[^|]*\|[ \t]*grep[ \t]+/) && has_quiet(substr(joined, RSTART + RLENGTH))) print F ":" start ": " joined
        start = 0
      }
      END {
        if (buf != "") {
          if (match(buf, /(printf|echo)[^|]*\|[ \t]*grep[ \t]+/) && has_quiet(substr(buf, RSTART + RLENGTH))) print F ":" start ": " buf
        }
      }
    ' "$f"
  done
)"

# content fingerprint of one file's matched lines — lets an exception pin the CONTENT, not
# just a count (a count-preserving swap must not inherit an existing exception).
fingerprint() { # <path> ; reads HITS from the environment
  printf '%s\n' "$HITS" | sed '/^$/d' | grep "^$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'):" | LC_ALL=C sort | shasum -a 256 | cut -c1-16
}

fails="" warns=""
FILES_WITH_HITS="$(printf '%s\n' "$HITS" | sed '/^$/d' | cut -d: -f1 | LC_ALL=C sort -u)"

if [ -n "$FILES_WITH_HITS" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    actual="$(printf '%s\n' "$HITS" | sed '/^$/d' | grep -c "^$(printf '%s' "$f" | sed 's/[.[\*^$]/\\&/g'):")"
    hash="$(fingerprint "$f")"
    line="$(grep -E "^$(printf '%s' "$f" | sed 's/[].[\*^$/]/\\&/g')[[:space:]]" "$ROOT/$EXC_FILE" 2>/dev/null | head -1)"
    if [ -z "$line" ]; then
      fails+="  $f — $actual occurrence(s), undeclared"$'\n'
      continue
    fi
    d_count="$(printf '%s' "$line" | awk '{print $2}')"
    d_hash="$(printf '%s' "$line" | awk '{print $3}')"
    d_issue="$(printf '%s' "$line" | awk '{print $4}')"
    case "$d_issue" in
      \#*) ;;
      *) fails+="  $f — exception declares no tracking issue (4th column must be #<issue>)"$'\n'; continue ;;
    esac
    case "$d_count" in ''|*[!0-9]*) fails+="  $f — malformed declaration (2nd column must be an integer): $line"$'\n'; continue ;; esac
    if [ "$d_count" -ne "$actual" ]; then
      fails+="  $f — exception declares $d_count occurrence(s) but the file has $actual. A changed count is never inherited: fix it or re-declare DELIBERATELY."$'\n'
    elif [ "$d_hash" != "$hash" ]; then
      fails+="  $f — exception count matches ($actual) but the CONTENT changed (declared $d_hash, actual $hash). A count-preserving swap must not inherit an exception."$'\n'
    else
      warns+="  ⚠️  $f — $actual occurrence(s) DECLARED BLOCKED (tracked in $d_issue); this file is NOT safe, its fix just cannot be merged yet"$'\n'
    fi
  done <<< "$FILES_WITH_HITS"
fi

# a declaration for a file with no hits (or a malformed/issue-less line) is also fatal
if [ -f "$ROOT/$EXC_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    f="$(printf '%s' "$line" | awk '{print $1}')"
    n="$(printf '%s' "$line" | awk '{print $2}')"
    case "$n" in ''|*[!0-9]*) fails+="  $EXC_FILE — malformed declaration (2nd column must be an integer): $line"$'\n'; continue ;; esac
    # STALE only when the file was actually SCANNED and produced no hits. A declaration for a
    # file OUTSIDE this invocation's scan set is UNVERIFIED, not stale — otherwise a consumer
    # whose exceptions file covers files a narrower `--dirs` does not reach gets a red run for
    # every narrowed invocation, including a developer checking one directory (#7588).
    if [ "$n" -gt 0 ] && grep -qx "$f" <<<"$FILE_LIST" && ! grep -qx "$f" <<<"$FILES_WITH_HITS"; then
      fails+="  $f — STALE exception: declares $n occurrence(s) but the file has NONE. Delete the line ($EXC_FILE)."$'\n'
    fi
  done < "$ROOT/$EXC_FILE"
fi

if [ -n "$warns" ]; then
  printf '⚠️  declared (blocked) exceptions — recorded, not silenced:\n%s' "$warns" >&2
fi

if [ -n "$fails" ]; then
  echo "❌ SIGPIPE false-negative idiom (printf/echo piped into a quiet grep under pipefail) — #841:" >&2
  printf '%s' "$fails" >&2
  printf '%s\n' "$HITS" | sed '/^$/d' | sed 's/^/     /' >&2
  echo "" >&2
  echo "Fix: invert to a here-string, e.g." >&2
  echo "  BAD   printf '%s' \"\$TEXT\" piped into grep -q 'PATTERN'" >&2
  echo "  GOOD  grep -q 'PATTERN' <<<\"\$TEXT\"" >&2
  echo "(bash-only; every flag still applies. See the header of this script for the windows of failure," >&2
  echo " and for the POSIX-sh variant that .husky/ hooks need.)" >&2
  exit 1
fi

echo "✅ no builtin-writer SIGPIPE false-negative idiom in ${SCAN_DIRS[*]} (scanned $FILE_COUNT file(s) under $ROOT)"
echo "   NOTE: scope is printf/echo only — any other producer piped into a quiet grep has the same failure mode."
exit 0
