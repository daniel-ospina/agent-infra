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

# `find` errors are NOT discarded. A directory it cannot descend makes `find` print an error
# and yield a PARTIAL list — which is a clean run over files that were never read, the guard's
# cardinal sin (#7588 review round 5). Readability of the scan dir itself is checked above;
# this catches everything underneath it. A SYMLINK LOOP is the one diagnostic that is NOT a
# partial scan — see the partition below.
FIND_ERRS="$(mktemp)" || {
  echo "check-no-sigpipe-grep: cannot create a diagnostics file (TMPDIR unset or unwritable) — refusing to report a verdict over a scan that has not run" >&2
  exit 2
}
# The sink must be ABSOLUTE. The scan runs after `cd "$ROOT"` (the FILE_LIST subshell below),
# while this precondition and the partition read both run in the guard's original cwd — so a
# RELATIVE mktemp result would be WRITTEN under $ROOT and READ here, i.e. two different files,
# an empty partition, and a clean verdict over a partial scan. That is not hypothetical: GNU
# `mktemp` with no template implies `--tmpdir`, so it emits a relative name whenever TMPDIR
# itself is relative.
case "$FIND_ERRS" in
  /*) ;;
  *) FIND_ERRS="$PWD/$FIND_ERRS" ;;
esac
# mktemp's STATUS is not proof the sink is usable, and neither is OPENABILITY or WRITE-ONLY
# success: a wrapper that exits 0 without creating a file, a sink on a volume that takes the
# open but refuses the write, and a sink that accepts the write but discards it (or cannot be
# READ back) would ALL swallow find's stderr, leave the partition empty, and let a partial scan
# read as a clean one. Instead of trusting the write, read the byte back — which is what the
# partition will do — then truncate it away again.
if ! { printf x >>"$FIND_ERRS" && [ "$(cat "$FIND_ERRS" 2>/dev/null)" = x ] && : >"$FIND_ERRS"; } 2>/dev/null; then
  echo "check-no-sigpipe-grep: the diagnostics file is not writable — refusing to report a verdict over a scan that has not run" >&2
  exit 2
fi
trap 'rm -f "$FIND_ERRS"' EXIT

# ONE diagnostic is exempt from the partial-scan rule: findutils' own CYCLE report, matched
# by prefix in the partition below (`find: File system loop detected`). `find -L` is required so
# the top-level symlink a consumer repo's `scripts/` IS gets descended, so `find` can also meet a
# cycle — and everything a cycle reaches is reachable WITHOUT it, so find lists every file and
# the diagnostic only records that it did not follow the cycle once more. Reading it as a
# partial scan reds a tree the guard read completely, which is the false block its own suite
# pins (#11aa).
#
# NOTHING ELSE IS EXEMPT. ELOOP (`Too many levels of symbolic links` — glibc's and BSD libc's
# wording — or `Symbolic link loop`, musl's) is raised whenever a path fails to resolve within
# the kernel's symlink budget, and the overwhelmingly common case of that is a NON-cyclic chain
# whose content is reachable no other way. Treating it as benign would let the guard exit 0
# having read no file — the exact false clean this guard exists to prevent — so it stays fatal.
# The cost is a false BLOCK on two shapes, and the polarity is deliberate because a partial scan
# is never a clean scan:
#   · an over-long chain (the case above), and
#   · a cycle find reports as ELOOP rather than as its own cycle report — a MUTUAL SYMLINK PAIR
#     (`one -> other`, `other -> one`) is one. Recorded as a limit next to #11aa, not excused:
#     GNU find exits 2 there, while BSD find lists both entries and exits 0, so the guard's false
#     BLOCK is real on CI and does not arise on macOS.
# BSD find's silence is SHAPE-DEPENDENT, so do not read it as a platform guarantee: an entry
# whose whole resolution fails is skipped in silence with no file listed and exit 0 (what the
# suite's #11af fixture does, and its skip line discloses). Do not generalise from that to what
# BSD find prints in shapes this suite cannot construct: Darwin's find carries no
# `Too many levels of symbolic links` string at all — that wording belongs to libc, not to find.
#
# `LC_ALL=C` on the find calls below (`scan_files`) pins the cycle wording: findutils is
# gettext-translated, and a translated report would not match the partition's prefix.

# `find -L` so a scan dir that is a SYMLINK is still descended into (consumer repos
# symlink `scripts/` back to this repo; plain `find` returns nothing and the guard would
# print "clean" after scanning zero files).
#
# SELECTION IS BY NAME **OR SHEBANG**, not by name alone. `.husky/` hooks are extensionless
# POSIX-sh files, and so are most of `.github/scripts/` — including an extensionless script
# that shipped the very false negative this guard exists to catch (tortoise#7588). A
# `-name '*.sh'` filter reports a clean run having never read them.
# The NAME half of `is_shell_file`, asked on its own: true when the BASENAME definitively
# EXCLUDES the file without any read (the `.*.*` / `?*.*` arms below). Kept as its own
# predicate so the readability probe can ask "would the guard read this at all?" WITHOUT first
# attempting the read the probe exists to test. It mirrors `is_shell_file`'s precedence exactly,
# including the `*.sh`/`*.bash` arm being checked first — `foo.txt.sh` is claimed by name, so it
# is never excluded here either.
name_excluded() {
  case "$1" in
    *.sh|*.bash) return 1 ;;
  esac
  case "${1##*/}" in
    .*.*|?*.*) return 0 ;;
  esac
  return 1
}

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
  # The interpreter TOKEN must be sh/bash, never a bare `*sh*`: this guard's scan set and the
  # remedy it prints are POSIX-sh/bash-specific, so other interpreters are out of SCOPE by
  # decision. That is deliberately NOT a claim about their pipeline semantics — zsh has
  # `pipefail` (`setopt pipefail`) and tcsh propagates a failed element regardless — so restoring
  # a capability argument here would be wrong for both of them again.
  # Read a BOUNDED prefix. `head -1` on a file with no newline reads to EOF, so a large
  # extensionless non-shell file would be materialised into a shell variable (measured on
  # bash 3.2: a 300 MB no-newline file cost 82s and 315 MB RSS, vs 0.21s when it was
  # skipped). Real binaries stop at their first newline anyway; this bound stops the cost
  # depending on that luck.
  # A FAILING reader is the same class as an unreadable file, and it fails in the direction that
  # matters: an empty `chunk` names no interpreter, so the file is dropped from the scan set and
  # the guard reports a clean run over a file it never read — the exact tortoise#7588 shape, since
  # the files this arm exists to claim are extensionless. Route it into the same fail-closed sink.
  local chunk first
  # 4096, not 512: a real shebang is a few dozen bytes, but a cap that clips the interpreter
  # token would be a false NEGATIVE (the old unbounded `head -1` would have claimed it).
  chunk="$(head -c 4096 "$1" 2>/dev/null)" || {
    printf 'check-no-sigpipe-grep: cannot read %s\n' "$1" >>"$FIND_ERRS"
    return 1
  }
  # A NON-EMPTY FILE CANNOT YIELD AN EMPTY READ. A reader that consumes nothing, prints nothing and
  # exits 0 is invisible to the status check above, and the empty chunk names no interpreter — so an
  # EXTENSIONLESS shell file is dropped from the scan set and the guard reports clean over it. That
  # is the tortoise#7588 shape, and this arm exists precisely to claim extensionless files.
  #
  # The test is the reader's BYTE COUNT, never the captured text: command substitution strips
  # trailing newlines and every NUL, so a legitimate file of newlines or NULs (a `.gitkeep`) also
  # captures as empty and would be a false BLOCK. The second read is paid only in that suspicious
  # case. `wc` is already load-bearing (the file-count message) and a non-integer count refuses too
  # — the same fail-closed polarity, since it means the measurement itself is not trustworthy.
  if [ -s "$1" ] && [ -z "$chunk" ]; then
    _nread="$(head -c 4096 "$1" 2>/dev/null | wc -c | tr -d ' ')"
    case "$_nread" in
      ''|*[!0-9]*|0)
        printf 'check-no-sigpipe-grep: the shebang reader returned nothing for the non-empty file %s\n' "$1" >>"$FIND_ERRS"
        return 1 ;;
    esac
  fi
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
  # A file `find` LISTED but that cannot be OPENED must not be skipped in silence: `find -L` could
  # STAT it, so no diagnostic reaches the partition, and the scanner would print a verdict over a
  # file it never read. Pushing it into the sink names the file and fails the partition, and that
  # PUSH is what refuses the shipped shape (measured: removing it yields `scanned 0 file(s)` and
  # exit 0). The readiness test below is NOT interchangeable with it — removing the test merely
  # moves the failure to the scanner's own status, which is why the two pins disagree about which
  # one is load-bearing.
  #
  # WHAT IS FATAL IS NARROWER THAN "ANY UNREADABLE FILE", and the difference is the NAME rule.
  # A basename carrying an extension (`notes.txt`, `.env.local`) is excluded without any read,
  # so the guard would never have opened it and refusing it is a false BLOCK on a tree the guard
  # can clear. Everything else is either claimed by name (`*.sh`/`*.bash`) or UNDECIDED until its
  # shebang is read — and that read is exactly what cannot happen — so an unreadable extensionless
  # file stays fatal: it cannot be ruled out as a shell script. (Probing only AFTER
  # `is_shell_file` would be the tempting simplification and it reopens that fail-open.)
  # The `.husky` arm scans EVERY listed file, extension or not, so there the unconditional probe
  # is right: every one of them is a file the guard would have read.
  # A SILENTLY failing `find` is the one failure the partition above cannot see: it writes no
  # diagnostic, so it lists nothing and the guard reports a clean run over a tree it never
  # enumerated. Both arms report FIND's own status (PIPESTATUS[0], read immediately after the
  # pipeline) rather than the loop's, which is only its last iteration's: with the loop's status a
  # completely enumerated tree that merely contains a non-shell file reads as a failed enumeration
  # and becomes a false block (measured: deleting both returns fails as such — 11d and 11m).
  # `set -o pipefail` supplies the same status for the pipeline itself, so the return states the
  # contract locally rather than being the only thing that catches a silent `find`.
  # A SILENTLY SUCCEEDING enumerator (consumes nothing, prints nothing, exits 0) lists an empty
  # tree and no status check can see it — the same family as the swallowing classifier, and the
  # result is `✅ … scanned 0 file(s)` over files that are sitting right there. `find -L <path>
  # -maxdepth 0` ALWAYS prints the path itself, so an empty result from that probe proves the tool
  # is not reporting what it sees; refuse rather than scan a tree we were told is empty.
  if [ -z "$(LC_ALL=C find -L "$target" -maxdepth 0 2>/dev/null)" ]; then
    printf 'check-no-sigpipe-grep: the enumerator reported nothing for %s, which exists\n' "$target" >>"$FIND_ERRS"
    return 1
  fi
  case "${dir##*/}" in
    .husky) LC_ALL=C find -L "$target" -type f 2>>"$FIND_ERRS" | while IFS= read -r f; do
              [ -r "$f" ] || printf 'check-no-sigpipe-grep: cannot read %s\n' "$f" >>"$FIND_ERRS"
              printf '%s\n' "$f"
            done
            return "${PIPESTATUS[0]}" ;;
    *) LC_ALL=C find -L "$target" -type f 2>>"$FIND_ERRS" | while IFS= read -r f; do
         if name_excluded "$f"; then
           :
         elif [ -r "$f" ]; then
           is_shell_file "$f" && printf '%s\n' "$f"
         else
           printf 'check-no-sigpipe-grep: cannot read %s\n' "$f" >>"$FIND_ERRS"
         fi
       done
       return "${PIPESTATUS[0]}" ;;
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

# The enumeration's status is part of the contract for the same reason: the fail-closed partition
# catches an error `find` PRINTS, never a silent non-zero exit. The per-dir status is find's own
# (see scan_files), NOT the function's — `scan_files` legitimately ends on a non-zero
# `is_shell_file` for a dir holding only extensionless non-shell files, so testing the function's
# status here would make every such tree a false block.
FILE_LIST="$(
  cd "$ROOT" || exit 2
  rc=0
  for d in "${SCAN_DIRS[@]}"; do
    # An ABSENT dir is SKIPPED here, never scanned: the default set tolerates `.husky` and
    # `pi-bootstrap` being absent, and `find` on a missing path would populate FIND_ERRS and
    # turn every such run into a false exit 2. Existence of an EXPLICITLY named dir was
    # already enforced above.
    [ -e "$d" ] && { scan_files "$d" || rc=$?; }
  done
  exit "$rc"
)" || ENUM_RC=$?
FILE_COUNT="$(printf '%s\n' "$FILE_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"

# Partition find's diagnostics. A cycle report loses no file, so it is announced and the run
# continues; ANYTHING ELSE is a file the guard never read, and a partial scan is not a clean
# scan — say so and stop rather than report a verdict over an unknown subset.
#
# The partition is done by the SHELL, never by an external command, so it is fail-closed by
# construction: every line of the file is read, and a line is benign only if it matches the
# cycle report. A classifier that could itself fail (a `grep` whose status is not 0/1, say)
# would leave BOTH lists empty and print a clean run over a partial scan — which is why no
# external command decides this verdict.
LOOP_ERRS=""; PARTIAL_ERRS=""
while IFS= read -r err_line || [ -n "$err_line" ]; do
  case "$err_line" in
    'find: File system loop detected'*) LOOP_ERRS="${LOOP_ERRS}${err_line}"$'\n' ;;
    '') ;;
    *) PARTIAL_ERRS="${PARTIAL_ERRS}${err_line}"$'\n' ;;
  esac
done < "$FIND_ERRS"
if [ -n "$LOOP_ERRS" ]; then
  echo "check-no-sigpipe-grep: note — a symlink cycle was seen while scanning; a cycle reaches no file its own tree does not, so the run continues:" >&2
  printf '%s' "$LOOP_ERRS" >&2
fi
if [ -n "$PARTIAL_ERRS" ]; then
  echo "check-no-sigpipe-grep: could not fully scan every file — a partial scan is not a clean scan:" >&2
  printf '%s' "$PARTIAL_ERRS" >&2
  exit 2
fi
# The enumerator's OWN status, judged HERE rather than at the assignment, and only when the
# partition does not already explain it. That ordering is load-bearing: GNU `find -L` exits 1 when
# it meets a symlink cycle WHILE LISTING EVERY FILE, so refusing on the raw status turned the benign
# case this partition exempts into a false BLOCK — it reddened `sigpipe-grep` on CI, where findutils
# reports the cycle and exits 1, while BSD find stays silent and exits 0. A non-zero status is
# therefore fatal only when NO cycle report accounts for it (a silently failing or shimmed
# enumerator, which writes no diagnostic at all).
LOOP_SEEN=0
[ -n "$LOOP_ERRS" ] && LOOP_SEEN=1
unset LOOP_ERRS PARTIAL_ERRS err_line
if [ "${ENUM_RC:-0}" -ne 0 ] && [ "$LOOP_SEEN" -eq 0 ]; then
  echo "check-no-sigpipe-grep: the file enumeration did not complete — refusing a verdict over a tree it may not have listed" >&2
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
    ' "$f" || { printf 'check-no-sigpipe-grep: the scanner failed on %s — refusing a verdict over files it may not have read\n' "$f" >&2; exit 2; }
  done
)"
# The scan pass's OWN status is part of the fail-closed contract:
# a scanner that is MISSING or that fails prints no hits, and no hits is indistinguishable from a
# clean tree. The pipeline's status is the loop's, the loop's is its LAST iteration's, so a
# failure on any earlier file is masked — and the assignment's status is discarded entirely
# unless it is read here. (`find`/`cat`/`mktemp` failures were already fatal around the SINK;
# this applies the same rule around the SCANNER.)
SCAN_RC=$?
if [ "$SCAN_RC" -ne 0 ]; then
  echo "check-no-sigpipe-grep: the scan pass did not complete (status $SCAN_RC) — refusing a verdict over files it may not have read" >&2
  exit 2
fi

# content fingerprint of one file's matched lines — lets an exception pin the CONTENT, not
# just a count (a count-preserving swap must not inherit an existing exception).
fingerprint() { # <path> ; reads HITS from the environment
  printf '%s\n' "$HITS" | sed '/^$/d' | grep "^$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'):" | LC_ALL=C sort | shasum -a 256 | cut -c1-16
}

fails="" warns=""
# The CLASSIFICATION pass decides whether the verdict loop runs at all, so its status is part of
# the contract in the same way the scan pass's is: if it fails, FILES_WITH_HITS is empty while
# HITS is not, the loop below is skipped, and the guard reports clean with the idiom sitting in
# HITS. (`cut` is the only tool in this pipeline that the SCAN_RC guard above cannot see.)
FILES_WITH_HITS="$(printf '%s\n' "$HITS" | sed '/^$/d' | cut -d: -f1 | LC_ALL=C sort -u)" || {
  echo "check-no-sigpipe-grep: could not classify the scan's hits — refusing a verdict over files that may contain the idiom" >&2
  exit 2
}
# A STATUS check cannot cover the converse: a classifier that CONSUMES its input, prints nothing and
# exits 0 empties the classification while HITS is not empty, the per-file loop below is skipped,
# and the guard reports clean with the idiom sitting in HITS. Cross-check the two VALUES instead —
# this needs no external command, so it cannot itself fail open.
if [ -z "$FILES_WITH_HITS" ] && [ -n "$HITS" ]; then
  echo "check-no-sigpipe-grep: the scan found matches that could not be classified — refusing a verdict" >&2
  exit 2
fi

if [ -n "$FILES_WITH_HITS" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    actual="$(printf '%s\n' "$HITS" | sed '/^$/d' | grep -c "^$(printf '%s' "$f" | sed 's/[.[\*^$]/\\&/g'):")"
    # VALIDATE THE VALUE, not the exit code. `grep -c` exits 0 (count printed), 1 (zero AND
    # `grep`'s ordinary no-match, which for -c still prints `0`), or >1 (an ERROR). Gate on the
    # status alone and the hole just moves: a shim printing nothing exiting 1 leaves `actual`
    # EMPTY, and an empty operand makes the comparison below fail SILENTLY (`integer expression
    # expected`, the `if` is false), so the COUNT check is skipped and control falls through to
    # the CONTENT-HASH check — a declaration whose count contradicts its own hash then passes as
    # a warning and the guard exits 0, against its own contract. A count is a non-negative
    # integer or it is nothing; anything else refuses here.
    case "$actual" in
      ''|*[!0-9]*)
        echo "check-no-sigpipe-grep: could not count the occurrences in $f — refusing a verdict" >&2
        exit 2 ;;
    esac
    # Same reasoning for the fingerprint: an empty pipeline yields the hash of EMPTY INPUT
    # (`e3b0c44298fc1c14…`), which is a well-FORMED value, so no shape check can catch it — a
    # declaration carrying it would be accepted and defeat the count-preserving-swap guarantee.
    if ! hash="$(fingerprint "$f")" || [ -z "$hash" ]; then
      echo "check-no-sigpipe-grep: could not fingerprint $f — refusing a verdict" >&2
      exit 2
    fi
    # ...and the empty-input digest must be refused explicitly, because it is the ONE failure a
    # well-formedness check cannot see: it is 16 valid hex characters, and it is what a fingerprint
    # pipeline yields when it swallows its input and still exits 0. A real file in FILES_WITH_HITS
    # has at least one matched line, so sha256 of the empty string is unreachable for a correct run.
    case "$hash" in
      e3b0c44298fc1c14)
        echo "check-no-sigpipe-grep: the fingerprint of $f is the digest of EMPTY input — refusing a verdict" >&2
        exit 2 ;;
    esac
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
    # Membership is decided IN THE SHELL, not by an external. `grep` cannot do it fail-closed: it
    # exits 0 for a match, 1 for none and >1 for an error, so a shim that prints nothing and exits 0
    # reports BOTH memberships true — which suppresses the stale check and lets a stale declaration
    # pass. A `case` cannot fail that way, and quoting the needle keeps its characters literal
    # (quoting suppresses globbing), so a path containing `*`/`?`/`[` is still exact.
    case $'\n'"$FILE_LIST"$'\n' in
      *$'\n'"$f"$'\n'*) in_file_list=0 ;;
      *) in_file_list=1 ;;
    esac
    case $'\n'"$FILES_WITH_HITS"$'\n' in
      *$'\n'"$f"$'\n'*) in_hits=0 ;;
      *) in_hits=1 ;;
    esac
    if [ "$n" -gt 0 ] && [ "$in_file_list" -eq 0 ] && [ "$in_hits" -ne 0 ]; then
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
