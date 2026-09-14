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
# DECLARED EXCEPTIONS (a blocked fix is recorded, never hidden)
# ------------------------------------------------------------
# `scripts/sigpipe-grep-exceptions.txt` declares `<path> <count> <content-hash> #<issue>`
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
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "check-no-sigpipe-grep: --root needs a directory" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,72p' "$0"; exit 0 ;;
    *) echo "check-no-sigpipe-grep: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[ -d "$ROOT" ] || { echo "check-no-sigpipe-grep: not a directory: $ROOT" >&2; exit 2; }

SCAN_DIRS=(scripts .husky pi-bootstrap)
EXC_FILE="scripts/sigpipe-grep-exceptions.txt"

# `find -L` so a scan dir that is a SYMLINK is still descended into (consumer repos
# symlink `scripts/` back to this repo; plain `find` returns nothing and the guard would
# print "clean" after scanning zero files). `.husky/` hooks are extensionless POSIX-sh
# files, so that dir is not filtered by `-name`.
scan_files() {
  case "$1" in
    .husky) find -L "$1" -type f 2>/dev/null ;;
    *) find -L "$1" -type f -name '*.sh' 2>/dev/null ;;
  esac
}

HITS="$(
  cd "$ROOT" || exit 2
  for d in "${SCAN_DIRS[@]}"; do
    [ -e "$d" ] || continue
    scan_files "$d"
  done | sort | while IFS= read -r f; do
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
    if [ "$n" -gt 0 ] && ! grep -qx "$f" <<<"$FILES_WITH_HITS"; then
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

echo "✅ no builtin-writer SIGPIPE false-negative idiom in ${SCAN_DIRS[*]} (scanned under $ROOT)"
echo "   NOTE: scope is printf/echo only — any other producer piped into a quiet grep has the same failure mode."
exit 0
