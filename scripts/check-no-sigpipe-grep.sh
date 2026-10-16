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
# It matches the builtin writers `printf`/`echo`, PLUS a `grep` as producer, because those are
# the sets where a recognised producer word is unambiguous in the TEXT. The `grep` producer was
# added by #864: the failure mechanism is `pipefail` + the quiet grep's early exit, NOT the
# identity of the writer, and `grep -vxF … | grep -q …` is a real gate site (`lane_has_test_shard`
# in the rail, and the test-teardown check) that #841's builtin-only predicate could not see. The
# same false negative is reachable with ANY producer (`git … | grep -q`, `docker … | grep -q`, a
# function's output) — see the data-loss sites fixed in
# `scripts/stale-worktrees.sh`/`scripts/cleanup-worktree.sh` (#863). Do not read a green run as
# "no SIGPIPE risk exists anywhere"; read it as "the recognised producer idioms are gone".
# Broadening the recognised producer set further is #864's open design question: ANY other
# producer is a false CLEAN until it is listed here.
#
#     PRODUCER-SIDE OVER-BLOCK, ACCEPTED AND PINNED (tests/sigpipe-grep/run.sh 13d). A producer
#     that writes NOTHING, or writes only once it has read everything (`grep -q`, `grep -c`),
#     cannot itself take the signal, so flagging it is a SHAPE flag and not a live false negative.
#     It is still flagged: the pipeline cannot carry that producer's status either, no live
#     occurrence of the shape exists on this tree, and writing a "does this producer write?"
#     model into a TEXT matcher is the unbounded direction #1645 documents round after round.
#     Over-block is friction and is visible; a missed producer is a silent false CLEAN.
#
#     PRODUCER-SIDE OVER-BLOCK FROM THE SUBSTRING CLASS, ALSO EXTENDED BY #864. raw_idiom is
#     deliberately not anchored (see its own note below), so the WORD `grep` anywhere before a
#     pipe counts as a producer: `ls a/grep | grep -q x`, `sed -n "/grep/p" f | grep -q x` and
#     `git log --grep=x | grep -q y` are all flagged although the producer is not grep. Reproduced
#     on fixtures (no live occurrence exists on this tree — the guard runs clean), and all are
#     recoverable through the exceptions file; the alternative (anchoring raw_idiom) regressed
#     quoted/escaped/backticked writers from flagged to CLEAN.
#
#     PRODUCER-SIDE OVER-BLOCK FROM THE QUOTED-BODY CLASS (#864). The quoted-body pass reads any
#     quoted region whose resolution begins with a producer word and which is piped straight on
#     as a wrapper body (`env -S "printf x" | grep -q p`), because a text matcher cannot tell a
#     wrapper body from an ordinary string argument: `foo "grep -vE a|b f" | grep -q c` is
#     flagged although foo is the producer. Same polarity as the substring class — over-block is
#     friction and visible, a missed producer is a silent false CLEAN — and no live occurrence of
#     the shape exists on this tree (the guard runs clean).
#
#     PRODUCER SPELLINGS THAT REACH THE SAME FALSE CLEAN, AND ARE NOW CLOSED. Each of these needed
#     the SAME conjunction — a producer word the token walk had to resolve AND a `|` inside the
#     producer's own argument that defeats raw_idiom's `[^|]*` bridge — and each was measured at rc
#     141 under `pipefail` on a >64 KiB payload whose match is on line 1, against 0 for the
#     capture-then-classify form. All are pinned in tests/sigpipe-grep/run.sh 13a:
#       a wrapper whose OPTION precedes the word   `env -i grep`, `command -p grep`,
#                                                  `stdbuf -oL grep`, `sudo -E grep`
#                                                  (the option belongs to the WRAPPER — the same
#                                                  test keeps `foo -e echo` unflagged)
#       a QUOTED or ESCAPED producer word           `"grep" -E "a|b" f | grep -q p`, `\grep …`
#       a $-rooted path                             `$HOME/bin/grep -E "a|b" f | grep -q p`
#       a PROCESS SUBSTITUTION in its argument       `grep -f <(cat list | head -2) f | grep -q p`
#       a MULTI-TOKEN WRAPPER PREFIX                 `env -u FOO -i grep …`, `env -u FOO -- grep …`,
#                                                  `stdbuf -i0 -o0 grep …` — a ONE-token lookback
#                                                  lands on the wrapper SEPARATED ARGUMENT or on
#                                                  an earlier option and never reaches the wrapper;
#                                                  the walk now crosses every token of the simple
#                                                  command up to a statement separator (so a
#                                                  producer in the PREVIOUS command cannot vouch
#                                                  for this one)
#       a producer WORD split by quoting or      `gre''p -E "a|b" f | grep -q p`,
#        escaping                                   `g\rep …`, `"gr"ep …`, `gr"ep" …`,
#                                                  `gre$'p' …`, `grep$'' …`, `ech''o …` —
#                                                  the producer word was matched by a fixed
#                                                  character ladder, which can only see a
#                                                  CONTIGUOUS spelling; the word is now assembled
#                                                  one literal character at a time with quoting and
#                                                  escaping removed — and the same for the two
#                                                  builtins, not only for `grep`
#       a `${…}`, `$(…)` or backtick region inside     `env -u $(echo a;b) -i grep …`,
#        a wrapper OPTION ARGUMENT                   `env -u ${x:-a;b} -i grep …` — a separator
#                                                  inside a SUBSTITUTION belongs to the
#                                                  substitution, not to the simple command; the
#                                                  region is opaque to the wrapper walk
#       a QUOTED or ESCAPED WRAPPER WORD             `"command" -p grep …`, `\command -p grep …`,
#                                                  `"env" -i grep …`, and the dollar-quoted
#                                                  spellings `$'env' …`, `$"env" …`, `en$'v' …` —
#                                                  the wrapper walk read RAW text, so the quoting
#                                                  never matched the WRAPWORDS list
#       a brace, parenthesis, or QUOTED or           `env -u "x(y" -- grep …`, `env -u x} -- grep
#        ESCAPED SEPARATOR inside a wrapper           …`, a wrapper option argument holding a
#        OPTION ARGUMENT                             quoted or escaped `;`/`&`/`|` — the walk
#                                                  broke on `(`/`)`/`{`/`}` and on RAW separators;
#                                                  only a REAL statement separator may end it now,
#                                                  which is what the guard quote map (QI) is for
#       a locale-quoted WRAPPER around the           `… | $"command" -p grep -q p` — the consumer
#        CONSUMER                                    token walk read only the `$'…'` spelling
#       an UNQUOTED BRACED VARIABLE among its         `/usr/bin/grep -E "a|b" ${y} f | grep -q p` —
#        arguments                                   `${y}` opens no `{ …; }` group, so its `}`
#                                                  landed in the group-depth-0 branch and CLEARED
#                                                  the writer; parameter expansions are counted
#                                                  (`pb`) so the two braces match each other
#       a `}` that closes NEITHER a group NOR a      `grep -E "a|b" shard{1,2}.txt | grep -q p`,
#        parameter                                    `grep -E "a|b" f{,} | grep -q p`,
#                                                  `grep -E "a|b" } f | grep -q p` — bash treats
#                                                  that `}` as an ordinary word character; it is
#                                                  now left ACTIVE rather than clearing the
#                                                  writer (over-block, not a false clean)
#       a producer INSIDE a WRAPPER BODY            `eval "grep -vE \"x|y\" f | grep -q needle"`,
#                                                  `env -S "grep -vE x|y f" | grep -q needle` —
#                                                  and its SINGLE-quoted spelling
#                                                  `env -S 'grep -E "a|b" f' | grep -q needle` —
#                                                  the producer own argument carries the data
#                                                  pipe, so BOTH matchers miss it; the QUOTED-BODY
#                                                  pass resolves the body (the inner shell removes
#                                                  the level-0 escapes) and re-runs the same two
#                                                  matchers on it, never a weaker third predicate
#       a producer NESTED IN A CAPTURE with a pipe   `grep -f <(grep -v x f | head) f | grep -q p`,
#        of its own                                 `grep -f $(grep -v x f | head -1) f | grep -q p`
#                                                  — the inner writer owns the pipe, so it
#                                                  overwrote the enclosing writer state and the
#                                                  outer writer pipe was never evaluated;
#                                                  that state is now SAVED ON CAPTURE ENTRY and
#                                                  RESTORED ON ITS CLOSER (a subshell `( … )` is
#                                                  not restored: it passes its stdout on)
#       an ANSI-C QUOTED producer word whose      `prin$'\164'f …`, `ech$'\157' …`,
#        ESCAPES ARE DECODED                         `gre$'\x70' …`, `ec$'\150'"o" …`,
#                                                  `ech$'\u006f' …`, `ech$'\U0000006f' …`,
#                                                  `$'\147rep' -E …`, and the same inside a
#                                                  wrapper (`env -i $'\147rep' …`) — the word was
#                                                  assembled with quoting removed, but an ANSI-C
#                                                  span DECODES its escapes, so the raw characters
#                                                  are not the word (`$'\147'` is `g`); the
#                                                  assembly now decodes octal, `\xHH`, `\uHHHH`,
#                                                  `\UHHHHHHHH` and the C single-character escapes,
#                                                  and takes an unknown escape literally, exactly as
#                                                  the shell does
#       a `<(` in a wrapper OPTION ARGUMENT          `env -u <(echo a;b) -i grep …` — the quote map
#                                                  (QI) knew `${…}`, `$(…)` and backticks but not
#                                                  the process-substitution opener, so a separator
#                                                  inside it ended the wrapper walk
#       a SPLIT word for the `printf -v` CARVE-OUT   `gre''p -v …` (a `grep` PRODUCER, flagged) and
#        (a defect this lane introduced and fixed)    `print''f -v …` (still the carve-out, not
#                                                  flagged) — the carve-out keyed on the RAW WORD
#                                                  WIDTH, and an assembled word of the same raw
#                                                  width matched it, so the split `grep -v`
#                                                  producer was dropped; it now keys on the
#                                                  ASSEMBLED WORD (`word == "printf"`), which is
#                                                  what the carve-out means
#     They were CLEAN before #864 as well (no `grep` producer was recognised at all), so none was a
#     regression; the widening closes them. The class stays open-ended in exactly the way the
#     wrapper allowlist below is (#1645) — a spelling nobody has thought of is still a false CLEAN.
#     The closed list is pinned in tests/sigpipe-grep/run.sh 13a (and 13a2 for the ANSI-C decoder,
#     which is asserted separately so a decoder regression names itself).
#
#   · WRAPPERS ARE AN ALLOWLIST, AND THAT IS THE OPEN-ENDED PART (#1645). A command that execs
#     into grep is seen through — `env`, `nice`, `command`, `time`, `sudo`, `stdbuf`, `exec`,
#     `timeout`, `nohup`, `setsid`, `busybox`, a shell's `-c`, and `eval` — but the list cannot be
#     completed by construction, so any OTHER wrapper is a false CLEAN. Adding a member is a
#     one-line change in GREPRE (both matchers) plus the prefix set in is_grep_cmd, plus a pin in
#     tests/sigpipe-grep/run.sh; nothing else about the guard is wrapper-specific.
#   · ADDING A PRODUCER WORD IS NOT A ONE-LINE CHANGE — IT TAKES TWO PLACES AND A PIN. WRITERRE
#     (read by raw_idiom AND by the quoted-body pass, which names it rather than repeating the
#     word list) and the character ladder in writer_at (scan_idiom). A word added to only one of
#     the two is a producer the other cannot see — a false CLEAN, the failure this guard exists to
#     prevent. The by-path fixtures in tests/sigpipe-grep/run.sh 13a pin the class that this gap
#     produced.
#   · TWO-STAGE PRODUCERS ARE OUT OF SCOPE. A writer piped through an intermediary (`cat`, `tee`,
#     `sort`) and then into a quiet grep does eventually kill the writer, because the intermediary
#     dies when grep exits — but the writer is piped into the INTERMEDIARY, not into grep, and this
#     guard's predicate is the ADJACENT writer-into-quiet-grep idiom. Widening it to "any quiet
#     grep anywhere in the pipeline" is a different and much broader predicate, deliberately not
#     this one.
#   · A grep that EXITS 2 IMMEDIATELY also kills its writer (`grep -m1q`, `grep -m`), and so does
#     a max-count N>=1 exiting at its N-th match. Neither is the quiet family, so neither is
#     flagged: the predicate here is the `-q` family, as stated above.
#   · A flag HELD IN A VARIABLE is undetectable: a body such as `grep $OPTS pat`, or an option
#     position in which the flag is a substitution, carries no quiet flag in the TEXT. With the
#     variable unset the command reads all its input; with it set to a quiet flag the writer dies.
#     A static reader cannot decide that, and treating every unresolvable option token as a
#     candidate would trade this narrow miss for a wide false block. Recorded, not closed. The
#     same holds for a COMMAND WORD computed by a substitution (`… | $(printf grep) -q p`) or held
#     in a variable — resolving it means RUNNING it, which is not a text predicate.
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
  # A CLIPPED FIRST LINE IS THE SAME UNDECIDABLE CASE as an empty read: `chunk` stops at 4096 bytes,
  # so a first line longer than that has its interpreter token cut off and names no shell we can see
  # — the file is dropped from the scan set and the guard reports clean over it. Only an actually
  # clipped line matters, so the second read is paid solely when the chunk carries no newline AND
  # the file is longer than the chunk (a 4096-byte file read whole is decidable and stays clean).
  if [ "$first" = "$chunk" ]; then
    _nmore="$(head -c 4097 "$1" 2>/dev/null | wc -c | tr -d ' ')"
    case "$_nmore" in
      ''|*[!0-9]*)
        printf 'check-no-sigpipe-grep: the shebang reader returned no usable byte count for %s\n' "$1" >>"$FIND_ERRS"
        return 1 ;;
      *)
        if [ "$_nmore" -gt 4096 ]; then
          printf 'check-no-sigpipe-grep: the first line of %s is longer than the shebang reader reads — cannot tell whether it is a shell script\n' "$1" >>"$FIND_ERRS"
          return 1
        fi ;;
    esac
  fi
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
  # file it never read. Pushing it into the sink is what refuses that case; the readiness test below
  # covers the same files a second time and is not a substitute — remove the push and the run is
  # clean, remove the test and the refusal merely arrives from elsewhere (the scanner's own status
  # for a name-claimed `*.sh`, this arm's read-failure push for an extensionless file).
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
  # enumerated. Both arms therefore return the PRODUCER's status (`${PIPESTATUS[0]}`, read
  # immediately after the pipeline) rather than the pipeline's, which under `pipefail` is the
  # rightmost non-zero — the loop's, when the last listed file is not a shell file.
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
    # The enumerator-status exemption is scoped PER DIRECTORY, not applied globally. A cycle report
    # from one directory says nothing about a DIFFERENT directory that exited non-zero with no
    # diagnostic: exempting that globally lets its unenumerated files pass as a clean scan. A dir
    # whose status is non-zero and which produced no cycle report of its own therefore records a
    # partial-scan error, which the partition refuses regardless of what any other dir reported.
    if [ -e "$d" ]; then
      _before="$(wc -l <"$FIND_ERRS" 2>/dev/null | tr -d ' ')"
      if ! scan_files "$d"; then
        _rc=$?
        _loops="$(sed -n "$(( ${_before:-0} + 1 )),\$p" "$FIND_ERRS" 2>/dev/null | LC_ALL=C grep -c 'find: File system loop detected' || true)"
        if [ "${_loops:-0}" -eq 0 ]; then
          printf 'check-no-sigpipe-grep: the enumeration did not complete for %s\n' "$d" >>"$FIND_ERRS"
          rc=$_rc
        fi
      fi
    fi
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
    # LC_ALL=C: awk substr and length are multibyte-aware under a UTF-8 locale, and a file with an
    # invalid byte (scripts/pi-patches/verify.sh has one) makes every substr abort with a towc
    # multibyte conversion failure, so the scan cannot complete. In the C locale they are
    # byte-oriented, which is all this matcher needs: every character it compares against is
    # ASCII, and a partial multibyte sequence never equals one.
    LC_ALL=C awk -v F="$f" '
      BEGIN {
        # The command prefixes grep may be reached through: any run of environment assignments and of
        # `env`/`nice`/`command`/`time`/`sudo` (bare or by path, so `/usr/bin/env grep` too), then an
        # optional path. `printf x | LC_ALL=C grep -q p` IS the idiom (measured rc 141), and both
        # matchers previously reported it clean because neither admitted a prefix. Defined ONCE so
        # the two matchers cannot drift apart on which forms they recognise.
        # The WRAPPER words — a command that EXECS INTO the next one and passes stdin/stdout
        # through. Named ONCE because two checks need the same list: the consumer prefix grammar
        # (GREPRE, immediately below) and the producer prefix grammar in writer_at (an option
        # before the command word belongs to the WRAPPER, not to some other command — without
        # that test `env -i grep`, `command -p grep`, `stdbuf -oL grep` and `nice --adjustment=5
        # grep` were reported CLEAN at rc 141; #864 review).
        WRAPWORDS = "env|nice|command|time|sudo|stdbuf|exec|eval|nohup|setsid|timeout|busybox|sh|bash|dash|zsh|ksh"
        GREPRE = "(([A-Za-z0-9._~+-]*/)*([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|" WRAPWORDS ")[ \t]+)*([A-Za-z0-9._~+-]*/)*"
        # The PRODUCER words whose stdout, piped into a quiet grep, is the class this guard
        # bans. `grep` joined the set in #864: the mechanism is `pipefail` plus the early
        # exit of a quiet grep, so a `grep` upstream takes the signal exactly as the builtin
        # writers do.
        # ⛔ THE PRODUCER SET LIVES IN TWO PLACES AND BOTH MUST CHANGE TOGETHER —
        #     this regex (read by raw_idiom only) and the character ladder in writer_at().
        #     writer_at is hand-written because substr() per index made the walk quadratic
        #     (27 s for a 1 MB line), and a WORD here with no branch there is a producer that
        #     scan_idiom — the authoritative walk — cannot see, i.e. exactly the false CLEAN
        #     the union of the two matchers exists to eliminate. Unlike GREPRE (single use),
        #     WRITERRE cannot be single-sourced at an acceptable cost.
        # NOTE: this program is a SINGLE-QUOTED shell word, so an apostrophe in any of these
        # comment lines would terminate it and break the whole script — keep them apostrophe-free.
        WRITERRE = "(printf|echo|grep)"
      }
      # The QUOTED BODY of a shell-out wrapper is a command in its own right and inherits the
      # wrapper stdin: `printf x | sh -c "grep -q p"` and `printf x | eval "grep -q p"` both pipe
      # the writer into a quiet grep (measured rc 141 against GNU grep 3.8 under pipefail), while the
      # token walk saw a single opaque token and reported CLEAN.
      #
      # This is deliberately PERMISSIVE - a `grep` anywhere in the body plus a quiet flag anywhere
      # in it is enough - because everything in the body shares the wrapper stdin, so ordering
      # cannot make the flag belong to someone else input the way it can out here. The cost of
      # the permissiveness is a recoverable false BLOCK; the cost of the alternative (resolving the
      # body grammar) is the false CLEAN this whole matcher exists to prevent, and the wrapper set
      # is an allowlist that can always grow one more member (#1645).
      function body_quiet(b,   s) {
        # The INNER shell removes BOTH quoting characters and BACKSLASHES before it execs the body,
        # so a body may spell the command and the flag with either quote flavour or with backslashes,
        # and all of those still run a quiet grep. Blanking only the single quote fixed one direction
        # of quoting and left the other plus every escaped spelling a false clean: the normalisation
        # is now the one the inner shell performs. A single QUOTE cannot be written literally in this
        # awk program - it sits inside a single-quoted shell word - so it is built from its octal
        # escape in a STRING, which makes that one substitution dynamic.
        s = b
        gsub(/\\/, "", s)
        gsub("\047", "", s)
        gsub("\"", "", s)
        return (s ~ /(^|[ \t;&|({="`])([A-Za-z0-9._~+-]*\/)*grep[ \t]/) &&
               (s ~ /(-[A-Za-z0-9]*q|--q|--s)/)
      }
      # The character analysis of ONE short-option cluster, from a STRING. next_tok does this
      # incrementally as it reads, but a token whose TRAILING separator has been stripped (see
      # has_quiet) must be re-read: otherwise the analysis still includes the separator, and `-qm0;`
      # loses its `-m0` and is reported quiet when grep actually reads all its input. Tokens are
      # capped at 400 characters, so reading them with substr here costs nothing.
      function analyse_cluster(t,   j, n) {
        TOKN = 0; TOKQ = 0; TOKFRST = 0; TOKM = 0; TOKZ = 0; TOKALLZ = 1; TOKDIG = 0
        n = length(t)
        for (j = 1; j <= n; j++) tokchar(substr(t, j, 1))
      }
      # does the text after "grep " carry a quiet flag?  (-q, -Fqx, -iq, --quiet)
      #
      # What has_quiet needs to know about ONE short-option cluster, accumulated as the token is
      # read. It is derived here, in one place, instead of from a rebuilt string, because the token
      # STRING has to be capped (building a huge string by concatenation is quadratic in this awk)
      # while the ANALYSIS must not be: a trailing `q` beyond the cap was a false clean, and the
      # earlier claim that nothing recognised is 400 characters long was simply wrong.
      #
      # A `q` counts only if no option BEFORE it takes an argument: `-e`, `-f`, `-m`, `-A`, `-B`,
      # `-C`, `-d` and `-D` consume the rest of the token, so `-eq1` is `-e` with pattern `q1` (NOT
      # quiet) while `-qm1` and `-1q` are. A leading run of digits is the grep -NUM context option.
      # Measured on a large payload: `-q`, `-qm1`, `-1q` and `-q1` return 141 (quiet); `-e1q`,
      # `-eq1`, `-1eq`, `-m1q` read all input.
      #
      # `-m0` CANCELS quiet: max-count 0 makes grep read all its input, so the writer cannot die
      # (measured rc 1, not 141) - `-qm0` was a new false block.
      #   TOKQ      a `q` appeared BEFORE the first consuming letter (or with none present)
      #   TOKFRST   index of the first consuming letter, 0 if there is none
      #   TOKM      that letter is `m`
      #   TOKZ      every character AFTER it is `0`
      #   TOKALLZ   the token is non-empty and every character is `0` (the `-m 0` argument)
      #   TOKDIG    length of the leading run of digits
      function tokchar(c) {
        TOKN++
        # `--max-count=0000`, `--max-count=+0` and `-m +0` all mean max-count ZERO (measured: grep
        # reads all its input), so a leading sign is not a reason to call the value non-zero.
        if (c == "+" && TOKN == 1) return
        if (c != "0") TOKALLZ = 0
        if (TOKFRST == 0 && TOKDIG == TOKN - 1 && c ~ /[0-9]/) { TOKDIG = TOKN; return }
        if (TOKFRST == 0) {
          if (c == "q") { TOKQ = 1; return }
          if (c ~ /[efmABCdD]/) { TOKFRST = TOKN; if (c == "m") TOKM = 1; TOKZ = 1; return }
          return
        }
        if (c == "+" && TOKN == TOKFRST + 1) return
        if (c != "0") TOKZ = 0
      }
      # Does this cluster consume the FOLLOWING token as its argument? `-e` does; in `-ef` the
      # argument is attached (`f`), so it does not. Without this, `grep -e pat -q` reported CLEAN
      # although it IS quiet (`-e` consumed `pat`, and the walk stopped at `pat` as though it were
      # the pattern) - a false clean in a required gate, measured 141 against real grep.
      # The long options that take an argument; written `--opt=VAL` the argument is attached, so
      # only the bare spelling consumes the next token.
      function long_takes_arg(t) {
        return (t ~ /^--(after-context|before-context|context|device|directories|exclude|exclude-dir|exclude-from|file|include|label|max-count|regexp)$/)
      }
      # The next token, ending at UNQUOTED whitespace. TOK is the token with its quoting removed,
      # because the shell removes that quoting before grep ever sees the argument: a -q written
      # inside double quotes, inside single quotes, escaped with a backslash, or as an ANSI-C
      # string all pass grep the FLAG -q (each measured rc 141) and was reported clean while the
      # walk tokenised the raw text.
      #
      # QSEP is 1 when an UNQUOTED statement separator is part of the token. That distinction is the
      # whole point: a pattern operand that merely CONTAINS a pipe or a semicolon inside its quotes
      # is quiet when followed by -q, while a separator attached to an option ends the command and
      # the -q that follows belongs to a DIFFERENT command whose output the writer never feeds.
      # A raw separator test got both backwards.
      #
      # Characters are read from CH, the line already split into characters by is_idiom. `substr(s, i, 1)`
      # per character is O(n) PER CALL in this awk, which made a single long token quadratic — an
      # 800 KB token took 24 s. The TOK value is likewise CAPPED: building a 1 MB token by
      # concatenation is quadratic too, and nothing this grammar recognises is 400 characters long.
      # Past the cap the walk still tracks quoting and separators, which is all it needs.
      function next_tok(i,   c, q, tk) {
        TOK = ""; QSEP = 0; q = 0; tk = 0
        TOKN = 0; TOKQ = 0; TOKFRST = 0; TOKM = 0; TOKZ = 0; TOKALLZ = 1; TOKDIG = 0
        # Leading whitespace belongs to the walk, not to the token: the option branches call
        # next_tok directly to consume an argument, and without this the argument was read as an
        # EMPTY token at the space before it, so `-m 0` never cancelled quiet.
        while (i <= CHN && (CH[i] == " " || CH[i] == "\t")) i++
        # The token span in the LINE, so a body can be read WHOLE even though TOK is capped (see
        # body_text): the cap is a performance device for the stored string, not a limit on what the
        # guard reads.
        TOKBEG = i; TOKEND = i - 1
        while (i <= CHN) {
          c = CH[i]
          if (q == 0) {
            if (c == " " || c == "\t") break
            if (c == "$" && CH[i + 1] == "\047") { q = 3; i += 2; continue }
            if (c == "$" && CH[i + 1] == "\"") { q = 2; i += 2; continue }
            if (c == "\047") { q = 1; i++; continue }
            if (c == "\"") { q = 2; i++; continue }
            if (c == "\\") { i++; if (i <= CHN) { tokchar(CH[i]); if (tk < 400) { TOK = TOK CH[i]; tk++ }; i++ } ; continue }
            if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "}") QSEP = 1
            tokchar(c)
            if (tk < 400) { TOK = TOK c; tk++ }
            i++
          } else if (q == 1) {
            if (c == "\047") { q = 0; i++; continue }
            tokchar(c)
            if (tk < 400) { TOK = TOK c; tk++ }
            i++
          } else if (q == 2) {
            if (c == "\"") { q = 0; i++; continue }
            if (c == "\\") { i++; if (i <= CHN) { tokchar(CH[i]); if (tk < 400) { TOK = TOK CH[i]; tk++ }; i++ } ; continue }
            tokchar(c)
            if (tk < 400) { TOK = TOK c; tk++ }
            i++
          } else {
            if (c == "\047") { q = 0; i++; continue }
            if (c == "\\") { i++; if (i <= CHN) { tokchar(CH[i]); if (tk < 400) { TOK = TOK CH[i]; tk++ }; i++ } ; continue }
            tokchar(c)
            if (tk < 400) { TOK = TOK c; tk++ }
            i++
          }
        }
        # An unterminated quote swallows the rest of the LINE, so nothing after it can be trusted to
        # be a new command: treat it as a boundary. This errs toward a recoverable false block and
        # never toward borrowing a later flag.
        if (q != 0) QSEP = 1
        TOKEND = i - 1
        return i
      }
      # Is the wrapper body (the token just read) the GNU/BSD grep regexes should be applied to? THE
      # LINE, not TOK: TOK is capped at 400 characters and a body longer than that with its `grep`
      # past the cap was invisible - a false clean on a body that is a command like any other. The
      # raw slice costs one copy and is taken only where a body is expected.
      function body_text() {
        return substr(CURLINE, TOKBEG, TOKEND - TOKBEG + 1)
      }
      # Tokens are walked in order from `start`. It does NOT stop at the first non-option token:
      # grep permutes options, so `grep PATTERN -q` IS quiet (measured rc 141 against GNU grep 3.8)
      # and stopping there reported it clean - a false clean in a required gate. There is NO token
      # cap: a 200-token cap that ended the walk was itself a false clean (200 `-i` options made a
      # `-q` past it invisible), strictly worse than origin/main, whose walk was unbounded.
      #
      # What bounds the walk is the command, not a count: it ends at `--`, at the first UNQUOTED
      # statement separator, or at end of line, so the cost is the length of ONE grep command.
      # Flags ACCUMULATE, and an `-m0` / `--max-count 0` anywhere in the list cancels quiet,
      # because max-count 0 makes grep read all its input.
      function has_quiet(start,   i, t, foundq, m0, sep, oq, om, oz, of, on, ts) {
        i = start; foundq = 0; m0 = 0
        while (i <= CHN) {
          while (i <= CHN && (CH[i] == " " || CH[i] == "\t")) i++
          if (i > CHN) break
          i = next_tok(i); t = TOK; sep = QSEP
          if (t == "--") break
          # A shell separator ENDS THE COMMAND, and the command ends at the FIRST one, so the token
          # is read up to it: `grep -e pat --quiet;echo done` IS quiet (the separator is after the
          # flag), while `grep -x;y -q pat` is not (the flag is after the separator and belongs to
          # the next command). One rule covers both directions. The SHORT-option branch alone could
          # not express it - it discarded the entire token - and the LONG-option ladder had no
          # separator handling at all, so `--quiet;` matched neither the ladder nor the invalid
          # option test and reported the idiom clean.
          if (sep && t ~ /[;|&(){}]/) {
            ts = t
            sub(/[;|&(){}].*$/, "", ts)
            analyse_cluster(ts)
            t = ts; sep = 1
          }
          # `--quiet` and `--silent` are the SAME GNU grep option, and GNU accepts any unambiguous
          # abbreviation of a long option: `--q`..`--quiet`, `--s`..`--silent` are all quiet
          # (`--s` is unambiguous - every other long option grep has starts with a different
          # letter). Only the `--quiet` ladder was recognised, so `printf x | grep --silent p`
          # reported CLEAN although grep is quiet and the writer dies (measured rc 141).
          if (t ~ /^--q(u(i(e(t)?)?)?)?$/ || t ~ /^--s(i(l(e(n(t)?)?)?)?)?$/) foundq = 1
          else if (t ~ /^--max-count=\+?0+$/) m0 = 1
          else if (t ~ /^--/) {
            if (t !~ /=/ && long_takes_arg(t)) {
              i = next_tok(i)
              if (t == "--max-count" && TOK ~ /^0+$/) m0 = 1
              sep = QSEP
            }
          } else if (t ~ /^-/) {
            # A separator the strip did not take was QUOTED: grep exits 2 on the resulting invalid
            # option (`grep "-q;x" pat`), so the token is skipped rather than read as `-q`.
            if (t ~ /[;|&(){}]/) continue
            # The argument attached to a consuming option is not the flag: `-eq1` is `-e q1`.
            # The analysis of the OPTION is saved FIRST: consuming its argument overwrites the globals.
            oq = TOKQ; om = TOKM; oz = TOKZ; of = TOKFRST; on = TOKN
            if (oq) foundq = 1
            if (om && oz && of < on) m0 = 1
            if (of == on) {
              i = next_tok(i)
              # `-m 0`: the argument is SEPARATE, so there is nothing after the `m` in the option
              # itself - the zero test applies to the token just consumed.
              if (om && oz && TOKALLZ) m0 = 1
              sep = QSEP
            }
          }
          if (sep) break
        }
        return (foundq && !m0) ? 1 : 0
      }
      # Two matchers, combined, because each alone has a blind spot that is a false clean:
      #
      #  (a) raw_idiom — the ORIGINAL matcher, unchanged in what it accepts, plus two
      #      widenings that only ADD matches (`command grep`, a by-path /bin/grep). It sees
      #      THROUGH quotes, so it catches the idiom nested in a command substitution, in a
      #      `bash -c` body string, or after a later writer on the same line. Its blind spot is
      #      a quoted writer argument that itself contains a pipe (printf "%s" "a|b" | grep -q p):
      #      the first pipe it meets is data, not a break, and the `[^|]*` bridge cannot cross it.
      #
      #      It is deliberately NOT anchored to a command start. Bounding the writer word was
      #      tried and regressed every writer that is quoted ("printf" ...), escaped (\printf ...)
      #      or reached through a backtick (`printf ...`) — plus `echo|grep` with no space — from
      #      flagged to CLEAN (#1645 review).
      #
      #      It is NOT literally a superset of origin/main, and the difference is deliberate: for
      #      `-eq`, `-fq`, `-Aq` and the rest of that family origin/main called the token quiet,
      #      but there the `q` is the argument of a consuming option and real grep reads all its
      #      input. This matcher reports those CLEAN because origin/main was WRONG to flag them
      #      (measured: 3,208 such tokens, every one with a consuming option letter before the
      #      `q`). Every other difference runs the other way — newly flagged, old clean — so the
      #      invariant that matters holds: nothing is reported clean that contains a genuine
      #      idiom unless an option argument is what consumed the `q`.
      #
      #      It is blind to a stdout redirect, and to a writer that is merely an argument or a
      #      substring, exactly as origin/main is: `printf x >f | /bin/grep -q p`,
      #      `myecho x | /bin/grep -q p`, `grep -e printf f | /bin/grep -q p`,
      #      `printf -v x y | /bin/grep -q p`, a writer inside a comment, and a `;`-separated
      #      later pipeline are all flagged although the writer cannot reach the pipe. These are
      #      origin/main flags on the bare-grep form, which the wider
      #      grep spellings now extend; removing any of them needs a tokenizer in THIS matcher,
      #      and all are recoverable through the exceptions file.
      #
      #  (b) scan_idiom — the tokenizer below, which tracks quote state so a DATA pipe is
      #      skipped and the real break is found. Its blind spot is the mirror image: it does not
      #      look inside quoted text, so the nested forms in (a) are invisible to it.
      #
      # Union them and neither blind spot survives. Neither is rewritten: a guard may err toward
      # a recoverable false block (the exceptions file), never toward a false clean, and every
      # attempt to make ONE matcher cover both classes produced exactly that (#1645 review).
      function raw_idiom(s,   off, rest, pos) {
        # EVERY site on the line, not just the leftmost. `match()` stops at the first
        # `printf|echo ... | grep`, so a non-quiet grep earlier on the line
        # (`printf x | grep -v; echo|grep -q p`) masked the genuine idiom after it and the guard
        # reported CLEAN. Review found this: the widenings below made the masking reachable on
        # lines origin/main had flagged, so it was a real regression, not a latent quirk.
        off = 0
        while (off < length(s)) {
          rest = substr(s, off + 1)
          if (!match(rest, WRITERRE "[^|]*[|][ \t]*" GREPRE "grep[ \t]+"))
            return 0
          pos = off + RSTART
          # An offset, not a slice: the walk is bounded by the grep COMMAND it is reading, never by
          # a token count or a byte window, each of which hid a flag and reported clean.
          if (has_quiet(pos + RLENGTH)) return 1
          off = pos + RLENGTH - 1
        }
        return 0
      }
      # writer -> pipe -> a quiet grep. `grep` is reachable three ways and each is the same
      # idiom: bare, by path (/bin/grep), and through `command grep` — the last is the form a
      # shell function shadowing grep invites, so it is the likeliest one inside a hook.
      #
      # What follows the pipe is read as TOKENS rather than sliced out and matched with a regex,
      # because a slice costs the length of the remainder at EVERY pipe on the line.
      # Does an option of `p` take its argument as the NEXT token (rather than attached, or not at
      # all)? Only the separated spellings matter here: `nice -n 5`, `sudo -u root`, `env -u VAR`.
      # Getting this wrong in the other direction is what makes `env -i grep -q p` a false clean
      # (finding the option, then treating `grep` as its argument) - `-i` takes no argument.
      function pfx_takes_arg(p, t,   k, n, j, c, letters) {
        if (t ~ /^--/) {
          if (t ~ /=/) return 0                 # the value is attached: nothing to consume
          if (p == "env") return (t ~ /^--(unset|chdir|split-string|block-signal|default-signal|ignore-signal)$/)
          if (p == "nice") return (t == "--adjustment")
          if (p == "sudo") return (t ~ /^--(user|group|host|prompt|chdir|close-from|command-timeout|preserve-env|other-user|role|type|login-class)$/)
          if (p == "stdbuf") return (t ~ /^--(input|output|error)$/)
          if (p == "time") return (t ~ /^--(format|output)$/)
          # `timeout --kill-after 5 10 grep -q p`: only the two that take a value; `--verbose`,
          # `--foreground` and `--preserve-status` take none, so consuming the next token for them
          # would swallow the COMMAND and report the idiom clean.
          if (p == "timeout") return (t ~ /^--(signal|kill-after)$/)
          # A shell long option that takes a value: `bash --init-file FILE -c BODY`,
          # `bash --rcfile FILE -c BODY`. Without these the FILE was read as the command and the
          # walk stopped before `-c`, inside the allowlist the header claims to see through.
          if (p ~ /^(sh|bash|dash|zsh|ksh)$/) return (t ~ /^--(init-file|rcfile)$/)
          return 0
        }
        # WHOLE-CLUSTER, not first letter: getopt groups, so `timeout -vk 5 10 grep -q p` is the
        # same command as `timeout -v -k 5 10 grep -q p` - which the guard already flagged. Testing
        # only the letter after the dash read `-vk` as `-v` (no argument), so the duration was taken
        # as the command and the idiom was reported clean.
        #
        # The argument may also be ATTACHED (`-k5`), in which case nothing is consumed from the next
        # token and the option walk must go on: the letter takes an argument only when it is the LAST
        # character of the cluster.
        # A shell -c argument is ALWAYS the next argv operand: an attached form is an error, not an
        # attached argument, and `sh -ce "grep -q pat"` is the grouped spelling of `sh -c -e ...` -
        # so the `c` may sit anywhere in the cluster and never carries its argument attached.
        # Applying the generic attached-argument rule here reported a shell body CLEAN, inside the
        # wrapper allowlist the header claims to see through.
        if (p ~ /^(sh|bash|dash|zsh|ksh)$/) return (index(t, "o") > 0 || index(t, "O") > 0) ? 1 : 0
        n = length(t)
        for (j = 2; j <= n; j++) {
          c = substr(t, j, 1)
          if (p == "exec") letters = "a"
          else if (p == "nice") letters = "n"
          else if (p == "sudo") letters = "ugpCDhUTrt"
          else if (p == "env") letters = "uCSP"
          else if (p == "stdbuf") letters = "ioe"
          else if (p == "time") letters = "fo"
          else if (p == "timeout") letters = "sk"
          else return 0
          if (index(letters, c) > 0) return (j == n) ? 1 : 0
        }
        return 0
      }
      function is_grep_cmd(i,   t, pfx, parg, base, popt, sep, shc) {
        pfx = ""; parg = 0; popt = 0; shc = 0
        while (i <= CHN) {
          while (i <= CHN && (CH[i] == " " || CH[i] == "\t")) i++
          if (i > CHN) return 0
          i = next_tok(i); t = TOK; sep = QSEP
          # A GROUP OPENING IS TRANSPARENT: `| (grep -q p)` and `| { grep -q p; }` send the group
          # stdout to the pipe, so grep inside it reads the writer. The `(`/`{`/`)` arrives attached
          # because there is no space after it.
          while (t ~ /^[(]/ || t ~ /^\{/) t = substr(t, 2)
          while (t ~ /[)]$/ || t ~ /\}$/) t = substr(t, 1, length(t) - 1)
          if (t == "") continue
          # A token that still carries an UNQUOTED separator is several commands written without a
          # space (`foo;/bin/grep`), not a command name: the stdout goes to `foo`, and a grep later
          # in that token runs as its own command with its own stdin. QUOTED is the opposite case:
          # the separators inside a quoted shell-out body (`sh -c "set -e; grep -q p"`) belong to
          # ONE body that inherits the wrapper stdin, and rejecting the token on them was a false
          # clean. Only QSEP distinguishes the two.
          if (sep && t ~ /[;|&(){}]/) return 0
          if (t == "grep" || t ~ /\/grep$/) return i
          # A wrapper BODY is read BEFORE anything else classifies the token. Inside a `-c` or eval
          # body the whole string is the command, so `LC_ALL=C grep -q p`, `FOO=1 grep -q p` and
          # `y=$(grep -q p)` each BEGIN with something the assignment skip below would swallow
          # (`LC_ALL=`), and the body was never read - a false clean on the exact prefix form the
          # comment above says the guard flags.
          #
          # The ORDER of the three is the grammar: an option argument is consumed first (the walk
          # called next_tok for the argument), then the command string a shell `-c` is owed (the
          # FIRST non-option operand, which is why `bash -co pipefail BODY` gives BODY to `-c`), then
          # an eval body.
          if (parg) {
            if (body_quiet(body_text())) return -1
            parg = 0; continue
          }
          if (shc && t !~ /^-/ && !(pfx ~ /^(sh|bash|dash|zsh|ksh)$/ && t ~ /^\+/)) {
            if (body_quiet(body_text())) return -1
            shc = 0; continue
          }
          if (pfx == "eval" && body_quiet(body_text())) return -1
          if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue        # an environment assignment
          base = t; sub(/^.*\//, "", base)
          # The prefixes grep is reached through, bare or by path (/usr/bin/env): the environment
          # wrappers, the process wrappers, the shell -c, and `timeout`/`nohup`/`setsid`/`busybox`.
          # Any other token is a DIFFERENT command, and the stdout belongs to that one, not to a
          # quiet grep - so this set is an ALLOWLIST, and a wrapper missing from it is a false CLEAN
          # by construction (#1645).
          if (base ~ /^(env|nice|command|time|sudo|stdbuf|exec|eval|nohup|setsid|timeout|busybox|sh|bash|dash|zsh|ksh)$/) {
            pfx = base; parg = 0; popt = (base == "timeout"); shc = 0; continue
          }
          # An ENVIRONMENT assignment whose value is itself a command string: `env --split-string=CMD`
          # (GNU coreutils) is the same option as `-S CMD`, and its value is the body. The generic
          # attached-value rule discards it, and it is the only member of the allowlist whose
          # ATTACHED value is a command. It is checked BEFORE the option branch, which would
          # otherwise consume it as an argument-less option.
          if (pfx == "env" && t ~ /^--split-string=/) return body_quiet(substr(t, index(t, "=") + 1)) ? -1 : 0
          if (pfx == "env" && t ~ /^-S./) return body_quiet(substr(t, 3)) ? -1 : 0
          # A SHELL OPTION, and the two things a shell does differently from every other wrapper:
          # its `-c` does NOT take an attached argument (it takes the FIRST NON-OPTION operand as
          # the command string, which is why `-ce` is `-c -e` and `-co pipefail BODY` gives the body
          # to `-c`), and its `-o`/`-O` DO take a separated one (`bash -o pipefail -c BODY`).
          # Treating `-o` as argument-less made its VALUE the command, and the walk stopped before
          # the `-c` that really carried the body - a false clean inside the wrapper allowlist.
          # `+o`/`+O` are the same options, and the old `^-` gate did not even dispatch them.
          if (t ~ /^-/ || (pfx ~ /^(sh|bash|dash|zsh|ksh)$/ && t ~ /^\+/)) {
            if (pfx ~ /^(sh|bash|dash|zsh|ksh)$/) {
              # A LONG shell option still goes through the shared table: `--init-file FILE` and
              # `--rcfile FILE` take a value, and short-circuiting every option here left the FILE
              # to be read as the command, with the walk stopping before the `-c` that carried the
              # body.
              if (t ~ /^--/) { parg = pfx_takes_arg(pfx, t); continue }
              if (index(t, "c") > 0) shc = 1
              if (index(t, "o") > 0 || index(t, "O") > 0) { parg = 1; continue }
              continue
            }
            parg = pfx_takes_arg(pfx, t); continue
          }
          # The command string a shell `-c` is still owed is read ABOVE, before anything can
          # classify the token as an assignment or a command name - and only when the token is NOT
          # an option: a shell accepts further options between `-c` and its command string
          # (`sh -c -e "grep -q p"`), and consuming the OPTION as the body lost the real one.
          # `timeout 5 grep -q p`: the DURATION is a bare operand before the command.
          if (popt && t !~ /^-/) { popt = 0; continue }
          return 0
        }
        return 0
      }
      # The writer s OWN shell context. A writer INSIDE a quoted region is usually inside a command
      # substitution (`out="$(printf ... | grep -q p)"`), where quoting RESTARTS. The streaming pass
      # carries the outer context, under which that writer is invisible (its `printf` sits inside a
      # quoted string) while raw_idiom is equally blind (the data pipe in its own argument is the
      # first `|` it meets) — both matchers fail at once and the union reported the file clean. That
      # was a regression against the previous revision, whose per-writer scan restarted the quote
      # state here. For those sites the scan restarts at the writer, exactly as it did before.
      function scan_from(start,   i, c, q, ansi, esc, g) {
        q = ""; ansi = 0; esc = 0
        for (i = start; i <= CHN; i++) {
          c = CH[i]
          if (esc) { esc = 0; w = writer_at(s, i); if (w && scan_from(i + w)) return 1; continue }
          if (q != "") {
            if ((q == "\"" || ansi) && c == "\\") { esc = 1; continue }
            if (c == q) { q = ""; ansi = 0 }
            continue
          }
          if (c == "$" && CH[i + 1] == "\047") { q = "\047"; ansi = 1; i++; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"" || c == "\047") { q = c; ansi = 0; continue }
          if (c == ";" || c == ")" || c == "}") return 0
          if (c == "&" && (CH[i + 1] == "&" || CH[i - 1] != ">")) return 0
          if (c == ">" && CH[i - 1] !~ /[0-9]/) return 0
          if (c == "<" && CH[i + 1] == "(") return 0
          if (c == "|") {
            if (CH[i + 1] == "|") return 0
            g = is_grep_cmd(i + 1)
            return (g == -1 || (g && has_quiet(g))) ? 1 : 0
          }
        }
        return 0
      }
      # Is there a writer word at `i`, and how long is it? A writer is a `printf`/`echo`/`grep` at a
      # command boundary whose next character ends the word; `printf -v NAME` writes to a shell
      # variable, not to stdout, so it cannot SIGPIPE, and a writer that is an ARGUMENT to another
      # command is not a writer either (in `foo -e echo -e "a|b" f | grep -q p` the pipeline
      # carries foo output, and the `echo` is an option argument, not a command).
      # KEEP IN STEP WITH WRITERRE (see the note at its definition): the assembly below is the
      # only producer list scan_idiom consults.
      # The numeric value of the digits in `s` in `base`: the ANSI-C escape decoder below needs it
      # and this awk has no strtonum.
      function numval(s, base,   i, c, d, v) {
        v = 0
        for (i = 1; i <= length(s); i++) {
          c = tolower(substr(s, i, 1))
          d = index("0123456789abcdef", c) - 1
          if (d < 0 || d >= base) break
          v = v * base + d
        }
        return v
      }
      # The character the C escape letter `ch` stands for, so a `$'...'` span is decoded the way
      # the shell decodes it (`\n` is a newline, `\t` a tab). An unknown escape is itself.
      function ctrl_char(ch) {
        if (ch == "a") return sprintf("%c", 7)
        if (ch == "b") return sprintf("%c", 8)
        if (ch == "e" || ch == "E") return sprintf("%c", 27)
        if (ch == "f") return sprintf("%c", 12)
        if (ch == "n") return sprintf("%c", 10)
        if (ch == "r") return sprintf("%c", 13)
        if (ch == "t") return sprintf("%c", 9)
        if (ch == "v") return sprintf("%c", 11)
        return ch
      }
      function writer_at(s, i,   prev, nxt, w, j, k, tokn, p, q, pw, ph, pto, ok, word, c, n, an, mx, hs) {
        w = 0
        # The command word is ASSEMBLED one literal character at a time with shell quoting and
        # escaping REMOVED, so a producer whose LETTERS are separated by quote runs or backslashes
        # (a doubled apostrophe pair inside the word, a backslash escape, a split double-quoted
        # span, a dollar-single-quoted span) is the same command as its contiguous spelling. A fixed
        # character ladder could only see the contiguous form, and BOTH matchers were blind to the
        # split ones — every one of them CLEAN at rc 141 (#864 review). The first-character test
        # keeps this O(1) for the common case; the assembly is bounded by the longest producer word.
        if (CH[i] != "e" && CH[i] != "p" && CH[i] != "g" \
            && !(CH[i] == "$" && CH[i + 1] == "\047")) return 0
        word = ""; j = i; n = 0; an = 0
        while (j <= CHN && n < 7) {
          c = CH[j]
          if (c == "$" && CH[j + 1] == "\047") { an = 1; j += 2; continue }
          if (c == "$" && CH[j + 1] == "\"") { an = 0; j += 2; continue }
          if (c == "\\" && an) {
            # Inside an ANSI-C quoted span the shell DECODES the escape, so the word is the value
            # and not the two raw characters: `prin$'\164'f` is `printf`, `gre$'\x70'` is `grep`,
            # `$'\147rep'` is `grep`. All of them were CLEAN at rc 141 (#864 review). An escape
            # this decoder does not know is taken literally, which is what the shell does with an
            # unknown escape too.
            j++
            if (j > CHN) break
            if (CH[j] == "x" || CH[j] == "u" || CH[j] == "U") {
              mx = (CH[j] == "x") ? 2 : ((CH[j] == "u") ? 4 : 8)
              j++; hs = ""
              while (j <= CHN && length(hs) < mx && CH[j] ~ /[0-9A-Fa-f]/) { hs = hs CH[j]; j++ }
              if (hs == "") c = "x"
              else c = sprintf("%c", numval(hs, 16))
            } else if (CH[j] ~ /[0-7]/) {
              hs = ""
              while (j <= CHN && length(hs) < 3 && CH[j] ~ /[0-7]/) { hs = hs CH[j]; j++ }
              c = sprintf("%c", numval(hs, 8))
            } else {
              c = ctrl_char(CH[j]); j++
            }
            word = word c; n++
            continue
          }
          if (c == "\\") { j++; if (j > CHN) break; c = CH[j] }
          else if (c == "\047" || c == "\"") { if (c == "\047") an = 0; j++; continue }
          else if (c ~ /[ \t;&|()<>`{}]/) break
          word = word c; j++; n++
        }
        # A `grep` is a PRODUCER for this predicate (#864): the mechanism is `pipefail` plus the
        # downstream quiet grep early exit, so a grep upstream takes the signal exactly as a
        # builtin writer does. No quietness model: a producer that writes nothing is flagged as a
        # SHAPE, which is the documented over-block (see the SCOPE header).
        if (word != "echo" && word != "printf" && word != "grep") return 0
        w = j - i
        # A backtick starts a command substitution, so a writer right after one is a writer.
        prev = (i == 1) ? " " : CH[i - 1]
        # A PATH-PREFIXED command word is the SAME command, and the producer side must accept
        # the path the consumer side already accepts (GREPRE carries ([A-Za-z0-9._~+-]*/)*):
        # without this, `/usr/bin/grep -E "a|b" f | grep -q p` was seen by NEITHER matcher —
        # raw_idiom cannot cross the quoted pipe, and scan_idiom rejected the path — and that
        # shape is a measured false CLEAN at rc 141 (#864 review). The walk runs only when the
        # word is preceded by `/`, so the common case pays nothing.
        if (prev == "/") {
          p = i - 1
          while (p >= 1 && CH[p] == "/") {
            q = p - 1
            while (q >= 1 && CH[q] ~ /[A-Za-z0-9._~+{}$-]/) q--
            p = q
          }
          prev = (p < 1) ? " " : CH[p]
        }
        # A QUOTED or ESCAPED command word is the same command (the shell removes the quoting), and
        # `raw_idiom` was deliberately left unanchored to keep exactly these spellings flagged — but
        # a data pipe inside the producer argument defeats that matcher, so scan_idiom has to see
        # them too, or the two blind spots meet: both were CLEAN at rc 141 (#864 review).
        if (prev !~ /[ \t;&|({`"\\\047]/) return 0
        nxt = CH[i + w]
        # A quote or a backslash DIRECTLY after the word is its own quoting (`"grep"`, `'grep'`),
        # not the start of another word: `grepx` must stay rejected, `grep"` must not.
        if (nxt != "" && nxt !~ /[ \t"\047\\]/) return 0
        if (w != 0 && word == "printf" && substr(s, i + w, 10) ~ /^[ \t]+-v/) return 0
        j = i - 1
        while (j >= 1 && (CH[j] == " " || CH[j] == "\t")) j--
        k = j
        while (k >= 1 && CH[k] !~ /[ \t;&|({]/) k--
        tokn = substr(s, k + 1, j - k)
        if (tokn ~ /^-/) {
          # The preceding token is an OPTION — but an option belongs to the command BEFORE it, and a
          # WRAPPER option does not stop the word being a command: in `env -i grep` the option
          # belongs to env, and `grep` is the operand whose stdout owns the pipe. The case this test
          # exists for is a writer that is an OPTION ARGUMENT of another command (`foo -e echo -e
          # …`), and there no wrapper precedes the option, so it stays rejected.
          #
          # Walk back over EVERY token of the simple command — options, the SEPARATED ARGUMENT of an
          # option (`env -u FOO -i grep`, `stdbuf -i0 -o0 grep`) and `--` — and accept the word if ANY
          # of them names a wrapper. One token back is not enough: it lands on the separated argument
          # (`FOO`) or on an earlier option (`-i0`), the wrapper is never reached, and the line was
          # reported CLEAN at rc 141 (#864 review). The walk stops at a statement separator, so a
          # producer in the PREVIOUS command cannot vouch for this one.
          pw = k - 1
          ok = 0
          while (pw >= 1) {
            while (pw >= 1 && (CH[pw] == " " || CH[pw] == "\t")) pw--
            if (pw < 1) break
            ph = pw
            # A token boundary is ` \t;&|` and NOTHING else — but only an UNQUOTED one counts.
            # `(`, `)`, `{` and `}` are ORDINARY CHARACTERS inside a quoted word (unquoted they are
            # shell metacharacters, which is why the walk never needed them as boundaries), and a
            # quoted or escaped `;`/`&`/`|` is DATA, not a statement separator: breaking on them
            # ended the walk before the wrapper was reached (`env -u "x(y" -- grep …`,
            # `env -u x} -- grep …`, and a quoted or escaped separator in the option argument) —
            # reported CLEAN at rc 141 (#864
            # review). QI marks quoted/escaped positions; only a real statement separator stops the
            # walk, so a producer in the PREVIOUS command cannot vouch for this one.
            while (ph >= 1 && (QI[ph] || CH[ph] !~ /[ \t;&|]/)) ph--
            pto = substr(s, ph + 1, pw - ph)
            # A QUOTED or ESCAPED wrapper word (`"env" -i grep`, `\env -i grep`), and the
            # ANSI-C or locale dollar-quoted spellings of it, is still that command, and
            # this walk reads RAW text, so its quoting is stripped before the match — the same
            # allowance `writer_at` already makes for the producer word itself. Comparing the
            # quoted forms against the WRAPWORDS list failed and reported CLEAN at rc 141
            # (#864 review).
            gsub(/[$"\\\047]/, "", pto)
            sub(/.*\//, "", pto)
            if (pto ~ "^(" WRAPWORDS ")$") { ok = 1; break }
            if (ph < 1 || CH[ph] ~ /[;&|]/) break
            pw = ph - 1
          }
          if (!ok) return 0
        }
        # A QUOTE-CLOSED word (`"grep"`, `'grep'`) carries its own quoting: report the length
        # INCLUDING the closing quote, so the caller restarts OUTSIDE it. Restarting ON the closing
        # quote mis-pairs the rest of the line — `"grep" -E "a|b" f | grep -q p` reopened a quote at
        # the closing one, re-paired `"a|b"` as unquoted, and charged the DATA pipe to the writer,
        # reporting CLEAN at rc 141 (#864 review).
        if ((prev == "\"" || prev == "\047") && nxt == prev) return w + 1
        return w
      }
      # Try EVERY writer at a command boundary — a line may hold more than one shell invocation,
      # and stopping at the first writer was itself a false clean (#1645 review).
      #
      # ONE left-to-right pass over the characters (CH), tracking quote state (single, double,
      # ANSI-C dollar-single), backslash escapes, statement boundaries (`;`, `&&`, `||`, `)`) and
      # whether a writer still owns the next pipe. The previous shape called a per-writer scanner
      # that re-walked the remainder for every writer — quadratic in the number of writers on a line
      # — and that is the ONLY reason a per-line scan budget existed. A budget can be spent two
      # ways, scan less (a false clean) or refuse a verdict, so removing the rescan removes the need
      # for it rather than choosing which failure to accept.
      function scan_idiom(s,   i, c, q, ansi, esc, w, active, g, br, pb, pd, ad, bt, d, inside) {
        q = ""; ansi = 0; esc = 0; active = 0; br = 0; pb = 0; pd = 0; ad = 0; bt = 0
        delete SA; delete SAd
        # Nothing to find on a line with no pipe at all, and this is the common case for the
        # many-writers pathology (`echo ` repeated): without it every writer drove a walk.
        if (index(s, "|") == 0) return 0
        for (i = 1; i <= CHN; i++) {
          c = CH[i]
          # An ESCAPED command word is still that command (`\grep` runs grep), so the word after a
          # backslash is tested too — otherwise `\grep -E "a|b" f | grep -q p` is CLEAN while the
          # unescaped form is flagged (#864 review).
          if (esc) { esc = 0; w = writer_at(s, i); if (w && scan_from(i + w)) return 1; continue }
          if (q != "") {
            # A writer inside the quoted region: scan it in its OWN quoting context (see scan_from).
            w = writer_at(s, i)
            if (w && scan_from(i + w)) return 1
            # ...and keep it as the active writer for the ENCLOSING context too. A wrapper BODY is a
            # quoted region holding the command whose stdout owns the outer pipe, and the apostrophes
            # in this comment had to be removed because the awk program is ONE SHELL WORD: an
            # apostrophe anywhere in it ends the quoting and breaks the whole script. Restarting at
            # the body closing quote re-opened quoting, so the outer pipe was never charged and the
            # line was CLEAN at rc 141 (#864 review).
            if (w) { active = 1; ad = pd }
            if ((q == "\"" || ansi) && c == "\\") { esc = 1; continue }
            if (c == q) { q = ""; ansi = 0 }
            continue
          }
          if (c == "$" && CH[i + 1] == "\047") {
            # The word can OPEN with the ANSI-C span (`$'\147rep'` IS grep), so test it at the
            # DOLLAR: this branch is about to consume both characters and enter the quoted region,
            # which would leave the escape the word depends on BEHIND the entry point.
            w = writer_at(s, i); if (w && scan_from(i + w)) return 1
            q = "\047"; ansi = 1; i++; continue
          }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"" || c == "\047") { q = c; ansi = 0; continue }
          # GROUPING. A `( ... )` SUBSHELL passes its stdout on, so a writer inside it keeps the
          # pipe across the closer (`( printf ... ) | grep -q p`); a `$( ... )` COMMAND SUBSTITUTION
          # CAPTURES its stdout, so a writer inside it does not (and a writer OUTSIDE it keeps the
          # pipe across the closer). Clearing the writer on every `)` lost the first case and, when
          # the substitution was merely an ARGUMENT of the writer, lost a pipe that was never
          # captured. CS[d] marks the depth at which the output is captured; AD is the depth of the
          # writer that owns the pipe, and the closer only clears a writer inside the capture.
          #
          # The writer state is SAVED ON ENTRY and RESTORED ON EXIT, not merely masked: a writer
          # INSIDE the capture overwrites `active`/`ad` (a single pair of globals), so a pipe inside
          # the capture is judged against the INNER writer — the enclosing writer OWNERSHIP of the
          # pipe is gone by the time the capture closes, and its real pipe is never evaluated:
          #     grep -f <(grep -v x f | head) f | grep -q p      # rc 141, reported CLEAN before this
          #     grep -f $(grep -v x f | head -1) f | grep -q p  # rc 141, reported CLEAN before this
          # `ad >= pd` cleared the INNER writer correctly, but that is not enough, because the
          # INNER pipe had already reset `active` to 0 and the OUTER writer was never re-seated.
          # The stack re-seats it, so the outer writer is still holding the pipe at the outer `|`
          # (CS[pd] distinguishes a capture — restore — from a subshell `( … )`, which passes its
          # stdout on and therefore keeps the inner writer as the owner of it).
          if (c == "$" && CH[i + 1] == "(") {
            pd++; CS[pd] = 1; SA[pd] = active; SAd[pd] = ad; i++; continue
          }
          if (c == "<" && CH[i + 1] == "(") {
            # `<(` is INPUT redirection: it feeds one ARGUMENT and does NOT move the stdout of the
            # command it belongs to off the pipe. Clearing the writer here lost `grep -f <(cat
            # list) f | grep -q p`, a measured 141 reported CLEAN (#864 review). `CS[pd]` still marks
            # the depth as captured, so a writer INSIDE the substitution is cleared at its closer.
            pd++; CS[pd] = 1; SA[pd] = active; SAd[pd] = ad; i++; continue
          }
          if (c == "`") {
            if (bt == 0) { pd++; CS[pd] = 1; SA[pd] = active; SAd[pd] = ad; bt = 1 }
            else { active = SA[pd]; ad = SAd[pd]; pd--; bt = 0 }
            continue
          }
          if (c == "(") { pd++; CS[pd] = 0; continue }
          if (c == ")") {
            if (pd > 0) { if (CS[pd]) { active = SA[pd]; ad = SAd[pd] }; pd-- }
            else active = 0
            continue
          }
          # `{ ...; }` groups: a `;` inside the group does not take the writer off the pipe, and the
          # closing brace does not either — the GROUP stdout is the pipe. `${x}` is NOT a group: its
          # `{` follows a `$`, so it opens none — and its `}` must close none either, or it lands in
          # the `br == 0` branch and CLEARS THE WRITER: `/usr/bin/grep -E "a|b" ${y} f | grep -q p`
          # was reported CLEAN at rc 141 by an unquoted braced variable among the producer arguments
          # (#864 review). PB counts parameter expansions, so the two braces are matched to each
          # other.
          if (c == "{") {
            if (i > 1 && CH[i - 1] == "$") pb++
            else if (i == 1 || CH[i - 1] ~ /[ \t;&|(]/) br++
            continue
          }
          if (c == "}") {
            # A `}` that closes neither a counted `{ …; }` group nor a counted `${…}` parameter is
            # not a group close at all: bash treats it as an ORDINARY WORD CHARACTER there (brace
            # expansion `f{1,2}.txt`, `f{,}`, an argument that is a bare `}`, and a second `}` after
            # `${y}`). Clearing the writer on it took the producer off the pipe and reported CLEAN
            # at rc 141 (#864 review). It now stays conservative in the OTHER direction: an
            # unmatched `}` leaves the writer ACTIVE, which can only over-block.
            if (pb > 0) pb--
            else if (br > 0) br--
            continue
          }
          if (c == ";") { if (br == 0) active = 0; continue }
          # `&&` ends the command; a bare `&` backgrounds the writer, so its stdout is not this
          # pipe. `2>&1` is NOT that case: there the `&` is preceded by `>`.
          if (c == "&" && CH[i + 1] == "&") { active = 0; i++; continue }
          if (c == "&" && CH[i - 1] != ">") { active = 0; continue }
          # `>` after a digit is an fd redirection and keeps stdout on the pipe; a bare `>`
          # redirects stdout away. A process substitution is handled ABOVE (`<(` is input
          # redirection and does NOT take stdout off the pipe), so there is no second `<(` test
          # here — the only one that existed was unreachable and stated the opposite rule.
          if (c == ">" && CH[i - 1] !~ /[0-9]/) { active = 0; continue }
          if (c == "|") {
            if (CH[i + 1] == "|") { active = 0; i++; continue }
            # A pipe INSIDE a capture (`$( … )`, `<( … )`, backticks) belongs to the nested command,
            # not to a writer outside it: `grep -f <(cat list | head -2) f | grep -q p` charged the
            # INNER pipe to the outer grep, so the real pipe was never owned and the line was
            # reported CLEAN at rc 141 (#864 review).
            if (active) {
              inside = 0
              for (d = ad + 1; d <= pd; d++) if (CS[d]) { inside = 1; break }
              if (inside) continue
            }
            # The FIRST unquoted pipe after a writer takes its stdout. If the command that reads it
            # is not a quiet grep, nothing further along the line belongs to this writer:
            # `printf ... | sed ... | grep -q` is two stages down, not the adjacent-writer idiom
            # this guard defines, and charging a later pipe to it would be a false block.
            if (active) {
              g = is_grep_cmd(i + 1)
              # -1 is the body sentinel from a shell-out wrapper: the quiet grep is the BODY, so
              # there is no flag index to walk (`printf x | sh -c "grep -q p"`).
              if (g == -1) return 1
              if (g && has_quiet(g)) return 1
            }
            active = 0
            continue
          }
          w = writer_at(s, i)
          if (w) { active = 1; ad = pd }
        }
        return 0
      }
      # THE WRAPPER-BODY PRODUCER (the fourth declared class in 13a).
      # -------------------------------------------------------------
      # The two matchers above BOTH miss the same conjunction: a `grep` producer whose own
      # argument carries a literal `|`, inside a quoted body. raw_idiom cannot cross that data
      # pipe with its `[^|]*` bridge, and scan_from abandons at the first pipe it meets because
      # the level-0 backslash that escapes the inner quote is read as a level-1 escape, so the
      # data pipe looks like a real break:
      #     eval "grep -vE \"x|y\" f | grep -q needle"      # rc 141, reported CLEAN before this
      #     env -S "grep -vE x|y f" | grep -q needle        # rc 141, reported CLEAN before this
      # A body is a shell program in its own right, so the pass below RE-READS each quoted
      # region the way the inner shell will. The inner shell removes the level-0 escape
      # backslashes before it parses, so those are removed here too, and the resolved body is
      # fed BACK THROUGH the two matchers above - it is not re-decided by a third, weaker
      # predicate. That is what keeps this from over-blocking: a plain string that merely
      # MENTIONS a pipe and a grep (an echo of a message, a `--status` option) is not an idiom,
      # and the full matchers say so.
      #
      # The worklist is ITERATIVE, never recursive: a body can itself contain a body (an eval
      # inside an eval), and recursing into `matchers` would clobber the global CH that the
      # outer walk is mid-way through. `is_idiom` therefore drives a queue, and each entry is
      # analysed only after the previous one has finished with CH.
      #
      # Only a body carrying BOTH a pipe and a producer word can hold the self-contained idiom,
      # so the cheap filter keeps the queue (and the O(body count) re-scan) off the common
      # clean line. The other shape - the body is the PRODUCER and the wrapper stdout is piped
      # straight on - is decided directly on the line, with no queue entry.
      function body_enqueue(b,   QK) {
        # A quoted body often repeats (`"$a"` and `"$a"` on one line); the queue only needs
        # the distinct strings, so skip a body already queued.
        for (QK = 1; QK <= QN; QK++) if (QB[QK] == b) return
        QN++; QB[QN] = b
      }
      function bodies_of(s,   i, c, q, ansi, beg, end, body, nb, j, g) {
        for (i = 1; i <= CHN; i++) {
          c = CH[i]
          if (q == "") {
            if (c == "$" && CH[i + 1] == "\047") { q = "\047"; ansi = 1; i++; beg = i + 1; continue }
            if (c == "\"" || c == "\047") { q = c; ansi = 0; beg = i + 1; continue }
            continue
          }
          # The quote flavours resolve escapes differently: a backslash escapes the next
          # character inside double quotes and inside an ANSI-C dollar-single form, and is literal inside
          # a plain single-quoted body.
          if ((q == "\"" || ansi) && c == "\\") { i++; continue }
          if (c != q) continue
          end = i
          body = substr(s, beg, end - beg)
          q = ""; ansi = 0
          # The inner shell has already removed the level-0 backslashes here; dropping them all
          # is the coarse approximation body_quiet makes too, and the matchers still decide.
          nb = body
          gsub(/\\/, "", nb)
          if (index(nb, "|") > 0 && nb ~ WRITERRE "[ \t]") body_enqueue(nb)
          # The wrapper whose BODY is the producer and whose stdout is piped straight on:
          # `env -S "grep -vE x|y f" | grep -q needle`. Only the FIRST command of a resolved
          # body can be the wrapper command, so the test is anchored at its start.
          j = end + 1
          while (j <= CHN && (CH[j] == " " || CH[j] == "\t")) j++
          if (j <= CHN && CH[j] == "|" && CH[j + 1] != "|") {
            if (nb ~ "^[ \t]*" GREPRE WRITERRE "([ \t]|$)") {
              g = is_grep_cmd(j + 1)
              if (g == -1 || (g && has_quiet(g))) return 1
            }
          }
        }
        return 0
      }
      # The two original matchers in one place; also rebuilds CH for the body walk of the caller.
      function matchers(s,   i, qq, sdd, btt) {
        # The line is split into characters ONCE per logical line and the walks read CH: in this awk
        # `substr(s, i, 1)` is O(n) PER CALL, so a character walk built on it is quadratic in the
        # line length (measured: an 800 KB token took 24 s, a 1 MB option list 28 s).
        # Nothing to find on a line with NO pipe at all, and this is the common case for the
        # many-producers pathology: `raw_idiom` bridges `[^|]*[|]` from EVERY producer word and
        # rescans the rest of the line looking for the `|` that is not there, so the cost is
        # quadratic in the line length. `grep` appears far more often in shell text than printf or
        # echo, so widening WRITERRE extended a latent hazard into a reachable one (measured on the
        # order of tens of seconds for a ~256 KB single-line fixture on a loaded box, against under
        # half a second through this fast path). THE FAST PATH COVERS ONLY A LINE WITH NO PIPE AT
        # ALL: a line that DOES carry a pipe and holds many producer words is still superlinear
        # (measured 3-32 s at ~78 KB and 22-52 s at ~234 KB across runs, wall time varying with
        # fleet load). That residual is a STATED LIMIT, not closed, and it does not occur in the
        # scanned corpus (the whole-repo run is rc 0 over 116 files in ~5 s).
        if (index(s, "|") == 0) return 0
        CHN = length(s); delete CH; split(s, CH, "")
        # QI[p] = 1 when index p is a quote character, lies INSIDE a quoted region, or is a
        # character an unquoted backslash escapes. The wrapper walk reads RAW text and must not
        # treat a quoted or escaped `;`/`&`/`|` as a statement separator: with a quoted separator
        # in a wrapper option argument the walk stopped at that separator, never reached the
        # wrapper, and the line was
        # reported CLEAN at rc 141 (#864 review). One O(n) pass here replaces a quote scan per walk.
        delete QI
        qq = 0; sdd = 0; btt = 0
        for (i = 1; i <= CHN; i++) {
          if (btt) { QI[i] = 1; if (CH[i] == "`") btt = 0; continue }
          if (sdd > 0) {
            # Inside a `${…}`, `$(…)` or backtick region: the whole substitution is opaque to the
            # wrapper walk, because a separator there belongs to the substitution, not to the
            # simple command. `env -u $(echo a;b) -i grep …` and `env -u ${x:-a;b} -i grep …`
            # were CLEAN at rc 141 (#864 review). The depth is a single counter over both brace
            # and paren nesting — an approximation, and one that errs toward marking MORE as
            # opaque (over-block), never toward letting a real separator through.
            QI[i] = 1
            if (CH[i] == "$" && (CH[i + 1] == "(" || CH[i + 1] == "{")) { i++; QI[i] = 1; sdd++; continue }
            if (CH[i] == "(" || CH[i] == "{") sdd++
            else if (CH[i] == ")" || CH[i] == "}") sdd--
            continue
          }
          if (qq == 0) {
            if (CH[i] == "`") { QI[i] = 1; btt = 1; continue }
            if (CH[i] == "$" && CH[i + 1] == "{") { QI[i] = 1; i++; QI[i] = 1; sdd = 1; continue }
            if (CH[i] == "$" && CH[i + 1] == "(") { QI[i] = 1; i++; QI[i] = 1; sdd = 1; continue }
            if (CH[i] == "<" && CH[i + 1] == "(") { QI[i] = 1; i++; QI[i] = 1; sdd = 1; continue }
            if (CH[i] == "\\") { QI[i] = 1; if (i < CHN) { i++; QI[i] = 1 }; continue }
            if (CH[i] == "$" && CH[i + 1] == "\047") { QI[i] = 1; i++; QI[i] = 1; qq = 3; continue }
            if (CH[i] == "$" && CH[i + 1] == "\"") { QI[i] = 1; i++; QI[i] = 1; qq = 2; continue }
            if (CH[i] == "\047") { QI[i] = 1; qq = 1; continue }
            if (CH[i] == "\"") { QI[i] = 1; qq = 2; continue }
          } else {
            QI[i] = 1
            if ((qq == 1 || qq == 3) && CH[i] == "\047") qq = 0
            else if (qq == 2 && CH[i] == "\"") qq = 0
            else if ((qq == 2 || qq == 3) && CH[i] == "\\") { if (i < CHN) { i++; QI[i] = 1 } }
          }
        }
        # The LINE is kept as a global too, because a wrapper body must be read WHOLE from it (TOK is
        # capped) - see body_text.
        CURLINE = s
        return (raw_idiom(s) || scan_idiom(s))
      }
      function is_idiom(s,   k) {
        delete QB; QN = 0
        if (matchers(s)) return 1
        if (bodies_of(s)) return 1
        # Drain the queue breadth-first. Every enqueued body is strictly shorter than the line
        # that produced it, so the loop terminates; CH is rebuilt per entry and never clobbered
        # mid-walk because no entry is analysed from inside the walk of another entry.
        k = 1
        while (k <= QN) {
          if (matchers(QB[k])) return 1
          if (bodies_of(QB[k])) return 1
          k++
        }
        return 0
      }
      # a pure comment or blank line is documentation: it cannot execute, so it is skipped
      # (otherwise a script that merely DOCUMENTS the anti-pattern fails the build).
      /^[ \t]*#/ || /^[ \t]*$/ { if (buf != "") { if (is_idiom(buf)) print F ":" start ": " buf } ; buf = ""; start = 0; next }
      {
        raw = $0
        if (start == 0) start = NR
        # join a continuation: an explicit trailing backslash AND a pipeline broken after a
        # bare `|` (both are legal bash line breaks). THE TWO JOINS DIFFER: the shell deletes a
        # backslash-newline with NOTHING at all (`gr\<newline>ep` is the single word `grep`), while a
        # bare `|` is a real pipe the next line continues. Joining both with a space split `grep`
        # into `gr ep` and reported the body clean.
        if (raw ~ /\\[ \t]*$/) {
          sub(/\\[ \t]*$/, "", raw)
          buf = buf raw
          next
        }
        if (raw ~ /\|[ \t]*$/) {
          sub(/\|[ \t]*$/, "|", raw)
          buf = buf raw " "
          next
        }
        joined = buf raw; buf = ""
        if (is_idiom(joined)) print F ":" start ": " joined
        start = 0
      }
      END {
        if (buf != "") {
          if (is_idiom(buf)) print F ":" start ": " buf
        }
      }
    ' "$f" || { printf 'check-no-sigpipe-grep: the scanner failed on %s — refusing a verdict over files it may not have read\n' "$f" >&2; exit 2; }
  done
)"
# The scan pass's OWN status is part of the fail-closed contract: a scanner that is MISSING or that
# fails prints no hits, and no hits is indistinguishable from a clean tree. The scanner aborts the
# loop itself on the first file it fails on, so the loop's status does carry that case — but the
# assignment's status is discarded entirely unless it is read here, and reading it also covers a
# `sed`/`sort`/`cd` failure in the other stages. (`find`/`cat`/`mktemp` failures were already fatal
# around the SINK; this applies the same rule around the SCANNER.)
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
  echo "❌ SIGPIPE false-negative idiom (a recognised producer piped into a quiet grep under pipefail) — #841/#864:" >&2
  printf '%s' "$fails" >&2
  printf '%s\n' "$HITS" | sed '/^$/d' | sed 's/^/     /' >&2
  echo "" >&2
  echo "Fix: drop the pipe. A builtin writer inverts to a here-string; any other producer" >&2
  echo "(e.g. a non-quiet grep) CAPTURES first and tests in the shell — a case needs no pipe:" >&2
  echo "  BAD   printf '%s' \"\$TEXT\" piped into grep -q 'PATTERN'" >&2
  echo "  GOOD  grep -q 'PATTERN' <<<\"\$TEXT\"" >&2
  echo "  BAD   grep -vxF -f list f piped into grep -q '[^[:space:]]'" >&2
  echo "  GOOD  out=\"\$(grep -vxF -f list f || true)\"; case \"\$out\" in *[![:space:]]*) … ;; esac" >&2
  echo 'If the producer itself is quiet or counts (grep -q, grep -c) it writes nothing to the' >&2
  echo "pipe at all — the PIPE is the bug: drop it and test the source directly, do not capture it." >&2
  echo "(bash-only for the here-string form; every grep flag still applies. See the header of this" >&2
  echo " script for the windows of failure and for the POSIX-sh variant that .husky/ hooks need.)" >&2
  exit 1
fi

echo "✅ no recognised-producer SIGPIPE false-negative idiom in ${SCAN_DIRS[*]} (scanned $FILE_COUNT file(s) under $ROOT)"
echo "   NOTE: producers recognised are printf|echo|grep — any OTHER producer piped into a quiet grep has the same failure mode (#864)."
exit 0
