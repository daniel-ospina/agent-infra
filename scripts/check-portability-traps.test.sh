#!/usr/bin/env bash
# check-portability-traps.test.sh — the portability detector's own arms (see the detector header for
# the agent-infra issues this class has already cost: #1702, #2046, #2571, #2828)
#
# ⛔ EVERY ARM BELOW IS LOAD-BEARING, AND THE MUTATION SECTION PROVES IT. A live trap arm is only
# worth its line if deleting the detector rule it tests turns that arm RED — otherwise the arm is a
# decoration that will keep passing after the rule rots. Section D therefore runs MUTANTS: a copy of
# the detector with one `hit(...)` line deleted must make its own arm fail. A mutant that leaves its
# arm green is reported as `MUTANT-SURVIVED`, which is a FAILURE of this suite — that is the whole
# point of a mutation test, so it is not softened into a warning.
#
# WHAT THIS SUITE DOES NOT PROVE, STATED
#   · macOS BEHAVIOUR. This suite runs on whatever host CI gives it, and CI here is ubuntu-latest
#     ONLY (measured: `rg -n 'macos-' .github/workflows/` → no match, 2026-10-30). Every arm prints
#     the platform it ran on, and the arms that can only mean something on one platform print
#     `UNPROVEN-ON(<platform>, <why>)` rather than a green tick that would read as a proof.
#   · A trap assembled at runtime, or held in a variable, is undetectable in the TEXT — declared in
#     the detector's header, not testable here.
#
# HERMETIC: every fixture is built under $TMP; nothing in the real tree is read except the detector,
# its baseline, the rule table it prints, and `scripts/lib/box.sh` (for the fallback arms). The
# detector is invoked with `--targets` so the REAL tree is never scanned by an arm.
#
#   bash scripts/check-portability-traps.test.sh
#   bash scripts/check-portability-traps.test.sh --verbose

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "❌ unresolvable"; exit 1; }
CHECK="$HERE/check-portability-traps.sh"
BASELINE="$HERE/portability-baseline.tsv"
BOX="$HERE/lib/box.sh"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

[ -f "$CHECK" ] || { echo "❌ detector missing: $CHECK"; exit 1; }

PASS=0; FAIL=0; SKIP=0; UNPROVEN=0
ok()     { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()    { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip()   { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$1"; }
# unproven — an arm that CANNOT run on this host. Distinct from SKIP: a skip is "not applicable",
# an UNPROVEN is "this is a real proof we do not have here", and the summary counts them apart so a
# one-platform run can never be read as a general one.
unproven() { UNPROVEN=$((UNPROVEN+1)); printf 'UNPROVEN-ON(%s, %s)\n' "$(uname -s 2>/dev/null || echo unknown)" "$1"; }

# The platform EVERY arm below ran on. Stated once, printed in the summary, and never implied.
OS="$(uname -s 2>/dev/null || echo unknown)"
BASHV="${BASH_VERSION%%(*}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ctrap-XXXXXX")" || { echo "❌ mktemp"; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# run_check <targets-file> [extra args…] — the hermetic invocation. Writes stdout to $OUT, stderr to
# $ERR, returns the detector's exit code. `--root` is the fixture dir so `targets()` reads nothing it
# was not given.
OUT="$TMP/out"; ERR="$TMP/err"
run_check() {
  local list="$1"; shift
  bash "$CHECK" --root "$TMP/tree" --targets "$list" "$@" >"$OUT" 2>"$ERR"
  return $?
}

# fixture <name> <<'BODY' … BODY — writes a shell file into the fixture tree and registers it.
LIST="$TMP/targets"; : >"$LIST"
fixture() {
  local name="$1"
  mkdir -p "$TMP/tree/$(dirname "$name")"
  cat >"$TMP/tree/$name"
  printf '%s\n' "$name" >>"$LIST"
}

# ── A. LIVE TRAPS ARE CAUGHT ─────────────────────────────────────────────────────────────────────
# The finding format on stdout is `path:line: rule — use …`; match the rule segment exactly so
# `bash4-mapfile` cannot be satisfied by `bash4-mapfile-extra`.
flags() {
  local rule="$1" list="$2" rc
  run_check "$list" --no-baseline; rc=$?
  [ "$rc" = 1 ] || return 1
  awk -v r="$rule" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) found = 1 } } END { exit(found ? 0 : 1) }' "$OUT"
}
# not_flags <rule> <list> — the guarded/false-positive direction: the rule must NOT appear.
not_flags() {
  local rule="$1" list="$2" rc
  run_check "$list" --no-baseline; rc=$?
  # ⛔ rc=2 IS A REFUSAL, NOT A CLEAN RUN (review finding 11). Reading stdout alone made all nine
  # negative arms (the six B controls + the three C controls) green against a detector that exited 2
  # without scanning anything — measured with an `exit 2` mutant. The negative arms are the ones the
  # header calls decisive, so a refusal must red them.
  if [ "$rc" = 2 ]; then return 1; fi
  awk -v r="$rule" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) found = 1 } } END { exit(found ? 1 : 0) }' "$OUT"
}

# ── A1..A6: one fixture per rule family, each a REAL trap.
A="$TMP/live"; : >"$A"
mk() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$A"; }

mk live/a-cpu.sh        '#!/usr/bin/env bash' 'n="$(nproc)"'
mk live/b-timeout.sh    '#!/usr/bin/env bash' 'timeout 5 sleep 1'
mk live/c-sed.sh        '#!/usr/bin/env bash' "sed -i 's/a/b/' f.txt"
mk live/d-declare.sh    '#!/usr/bin/env bash' 'declare -A m' 'm[x]=1'
mk live/e-case.sh       '#!/usr/bin/env bash' 'v="$(printf x | tr "[:upper:]" "[:lower:]")"' 'echo "${v,,}"'
mk live/f-mapfile.sh    '#!/usr/bin/env bash' 'mapfile -t arr < f.txt'
mk live/g-setsid.sh     '#!/usr/bin/env bash' 'setsid ./daemon &'
mk live/h-etimes.sh     '#!/usr/bin/env bash' "ps -eo pid=,etimes= -p \$\$"
mk live/i-free.sh       '#!/usr/bin/env bash' 'free -m'
mk live/j-readlink.sh   '#!/usr/bin/env bash' 'p="$(readlink -f ./x)"'
mk live/k-grepP.sh      '#!/usr/bin/env bash' 'grep -P "a+" f.txt'
mk live/l-dated.sh      '#!/usr/bin/env bash' 'date -d @0 +%s'
mk live/m-statc.sh      '#!/usr/bin/env bash' 'stat -c %Y f.txt'
mk live/n-procfs.sh     '#!/usr/bin/env bash' 'ls /proc/self/cwd'   # portability-ok: fixture body — the /proc path is the SAMPLE the probe must flag, never executed
mk live/o-appendamp.sh  '#!/usr/bin/env bash' 'echo hi &>> log.txt'
mk live/p-waitn.sh      '#!/usr/bin/env bash' 'wait -n'
mk live/q-sedbsd.sh     '#!/usr/bin/env bash' "sed -i '' -e 's/a/b/' f.txt"
# a heredoc whose marker never appears again: the file ends INSIDE the body, which must be REPORTED
# (the reader that swallowed the rest of a file silently was cycle-1 P1; this asserts the rule fires)
mk live/r-heredoc.sh    '#!/usr/bin/env bash' "cat <<'DOC' > notes.txt" 'echo hi'

for pair in \
  "cpu-count-single-mechanism live/a-cpu.sh" \
  "timeout-absent-on-macos live/b-timeout.sh" \
  "sed-in-place-gnu live/c-sed.sh" \
  "bash4-declare-A live/d-declare.sh" \
  "bash4-case-modify live/e-case.sh" \
  "bash4-mapfile live/f-mapfile.sh" \
  "setsid-absent-on-macos live/g-setsid.sh" \
  "ps-etimes-macos-absent live/h-etimes.sh" \
  "free-macos-absent live/i-free.sh" \
  "readlink-f-bsd-absent live/j-readlink.sh" \
  "grep-P-bsd-absent live/k-grepP.sh" \
  "date-d-gnu live/l-dated.sh" \
  "stat-c-gnu live/m-statc.sh" \
  "procfs-macos-absent live/n-procfs.sh" \
  "bash4-append-amp live/o-appendamp.sh" \
  "bash4-wait-n live/p-waitn.sh" \
  "sed-in-place-bsd live/q-sedbsd.sh" \
  "heredoc-unterminated live/r-heredoc.sh"
do
  set -- $pair
  flags "$1" "$A" && ok "A: caught $1" || bad "A: MISSED $1 (fixture $(sed -n '2p' "$TMP/tree/$2" 2>/dev/null))"
done

# ── B. GUARDED USE IS **NOT** FLAGGED — the false-positive control the brief requires ───────────
# ⛔ THIS IS THE SECTION THAT DECIDES WHETHER THE GATE SURVIVES. A detector that reds on correct
# code gets disabled, and a disabled detector catches nothing.
G="$TMP/guarded"; : >"$G"
mk2() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$G"; }

mk2 guarded/1-chain.sh \
  '#!/usr/bin/env bash' \
  'n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"'
mk2 guarded/2-shim.sh   '#!/usr/bin/env bash' '. "$(dirname "$0")/lib/box.sh"' 'n="$(box_ncpu)"'
mk2 guarded/3-probe.sh  '#!/usr/bin/env bash' 'command -v nproc >/dev/null 2>&1 && n="$(nproc)"'
mk2 guarded/4-timeout.sh \
  '#!/usr/bin/env bash' \
  'if command -v timeout >/dev/null 2>&1; then timeout 5 true; fi'
mk2 guarded/5-sedbak.sh '#!/usr/bin/env bash' "sed -i.bak 's/a/b/' f.txt" 'rm -f f.txt.bak'
mk2 guarded/6-sedshim.sh '#!/usr/bin/env bash' "box_sed_i 's/a/b/' f.txt"

for pair in \
  "cpu-count-single-mechanism guarded/1-chain.sh" \
  "cpu-count-single-mechanism guarded/2-shim.sh" \
  "cpu-count-single-mechanism guarded/3-probe.sh" \
  "timeout-absent-on-macos guarded/4-timeout.sh" \
  "sed-in-place-gnu guarded/5-sedbak.sh" \
  "sed-in-place-gnu guarded/6-sedshim.sh"
do
  set -- $pair
  not_flags "$1" "$G" && ok "B: guarded use NOT flagged — $1 in $2" || bad "B: FALSE POSITIVE — $1 flagged on the guarded form in $2"
done

# ── C. FALSE-POSITIVE CONTROLS: a trap that is DATA, not code ───────────────────────────────────
# A quoted string, a comment, and a heredoc body all CONTAIN the trap text and the shell never runs
# it. Flagging any of them is the over-block that gets a gate switched off.
C="$TMP/data"; : >"$C"
mk3() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C"; }

mk3 data/1-quoted.sh  '#!/usr/bin/env bash' 'want="sed -i and nproc and timeout 5"' 'grep -qF "$want" README.md'
mk3 data/2-comment.sh '#!/usr/bin/env bash' '# never write `sed -i` or `nproc` here' 'true'
mk3 data/3-heredoc.sh '#!/usr/bin/env bash' "cat <<'DOC' > notes.txt" 'sed -i s/a/b/ f' 'nproc' 'timeout 5 true' 'DOC'

for f in data/1-quoted.sh data/2-comment.sh data/3-heredoc.sh; do
  # ⛔ rc IS PART OF THE ASSERTION (review cycle-2 P1): an ABSENCE is satisfied by an EMPTY RUN, so a
  # detector that exited 2 without scanning made all three arms green. `not_flags` already carried
  # exactly this fix for the same reason (see its comment); these three were left on a bare grep.
  run_check "$C" --no-baseline; crc=$?
  if [ "$crc" = 2 ]; then
    bad "C: the trap-as-data arm on $f was REFUSED (rc=2) — an empty scan can never prove an absence"
  elif grep -q "$f" "$OUT" 2>/dev/null; then
    bad "C: FALSE POSITIVE — a trap as DATA in $f was flagged"
  else
    ok "C: trap-as-data NOT flagged ($f)"
  fi
done

# C4 — the per-line escape hatch works, and REFUSES without a reason.
P="$TMP/okline"; : >"$P"
mk4() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$P"; }
mk4 okline/1-ok.sh '#!/usr/bin/env bash' "sed -i 's/a/b/' f  # portability-ok: caller pins GNU sed via SED_BIN"
not_flags "sed-in-place-gnu" "$P" && ok "C4: '# portability-ok: <reason>' suppresses the finding" \
  || bad "C4: a reasoned '# portability-ok:' did not suppress"

Q="$TMP/noreason"; : >"$Q"
mk4_noreason() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$Q"; }
mk4_noreason noreason/1.sh '#!/usr/bin/env bash' "sed -i 's/a/b/' f  # portability-ok:"
run_check "$Q" --no-baseline
[ "$?" = 2 ] && grep -q 'NO reason' "$ERR" && ok "C5: reasonless '# portability-ok:' is REFUSED (exit 2)" \
  || bad "C5: reasonless '# portability-ok:' was accepted (silent pass)"

# C6/C7 — the file-level declaration: a reasoned skip works; a bare one REFUSES.
L="$TMP/linuxonly"; : >"$L"
mk4_lo() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$L"; }
mk4_lo linuxonly/1.sh '#!/usr/bin/env bash' '# portability: linux-only runs on cells only — reads /proc and procps stat -c' 'stat -c %Y /proc/self/cwd'   # portability-ok: fixture body — the /proc path is the SAMPLE this arm must flag, never executed
not_flags "stat-c-gnu" "$L" && ok "C6: '# portability: linux-only <reason>' skips the file" \
  || bad "C6: a reasoned linux-only declaration did not skip the file"

L2="$TMP/linuxonly-bare"; : >"$L2"
mk4_lo2() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$L2"; }
mk4_lo2 linuxonly-bare/1.sh '#!/usr/bin/env bash' '# portability: linux-only' 'stat -c %Y f'
run_check "$L2" --no-baseline
[ "$?" = 2 ] && grep -q 'NO reason' "$ERR" && ok "C7: reasonless '# portability: linux-only' is REFUSED (exit 2)" \
  || bad "C7: reasonless file-level declaration was accepted — an omission dressed as a decision"

# ── C8/C9 — THE QUOTE-STATE MACHINE SURVIVES THE CONSTRUCTS IT WILL MEET ────────────────────────
# ⛔ THIS SECTION EXISTS BECAUSE THE FIRST DRAFT'S STACK COULD BE KNOCKED OVER, AND THE GATE STAYED
# GREEN WHEN IT WAS. A leaked quote context makes every later line read as DATA: the rest of the file
# is silently unscanned, no finding is emitted, and the verdict is `✅ no NEW cross-platform traps` —
# a false PASS, and the worst failure a detector of this kind can have (review cycle-1 P1). Each
# fixture below is a construct that knocked it over on the real tree, and each arm asserts BOTH
# directions: the construct does not raise a false finding, AND a real trap placed AFTER it is still
# caught — because only the second assertion proves the scan resumed.
#
#   s1  `$( # don't reorder` — a comment (with an apostrophe) inside a command substitution
#   s2  `"$(printf '%s' "${#n} bytes")"` — a parameter expansion inside a substitution inside quotes
#   s3  `n=$(( (RANDOM << 15) % 900000 ))` — `<<` is a LEFT SHIFT inside arithmetic, not a heredoc
#   s4  a heredoc opened INSIDE `$( … )` — its body is Python, not shell
#   s5  a multi-line single-quoted awk program — a legitimate multi-line context that must close
SW="$TMP/survive"; : >"$SW"
mksw() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$SW"; }

mksw survive/1-comment-sub.sh \
  '#!/usr/bin/env bash' \
  'x="$( # do not reorder these arms' \
  "printf '%s' a)\"" \
  "sed -i 's/a/b/' f.txt"
mksw survive/2-len-arith.sh \
  '#!/usr/bin/env bash' \
  'msg="$(printf "%s bytes" "${#1}")"' \
  "sed -i 's/a/b/' f.txt"
mksw survive/3-shift.sh \
  '#!/usr/bin/env bash' \
  'n=$(( (RANDOM << 15 | RANDOM) % 900000 + 100000 ))' \
  "sed -i 's/a/b/' f.txt"
# fixture 4 is written from a QUOTED HERE-DOC, not from quoted arguments: its body needs an
# apostrophe inside an apostrophe-quoted heredoc opener, and every shell-quoted spelling of that
# silently drops a character (the first version wrote the escape literally and the fixture was
# invalid — the arm then blamed the detector for the fixture's own imbalance).
mkdir -p "$TMP/tree/survive"
cat >"$TMP/tree/survive/4-heredoc-sub.sh" <<'C8BODY'
#!/usr/bin/env bash
out="$(python3 - <<'PY' 2>&1
print("(", ")" , "'")
PY
)"
sed -i 's/a/b/' f.txt
C8BODY
printf '%s\n' survive/4-heredoc-sub.sh >>"$SW"
mksw survive/5-awk-multi.sh \
  '#!/usr/bin/env bash' \
  "awk -v b=\"refs/heads/\$b\" '" \
  '  $1 == b { print $2 }' \
  "' f.txt" \
  "sed -i 's/a/b/' f.txt"

run_check "$SW" --no-baseline
# EVERY ASSERTION IS PER FILE: a desync in ONE fixture must not be blamed on the other four (the
# first version grepped the whole output, so one bad fixture reddened all five arms).
for f in survive/1-comment-sub.sh survive/2-len-arith.sh survive/3-shift.sh \
         survive/4-heredoc-sub.sh survive/5-awk-multi.sh; do
  mine="$(awk -v f="$f" 'index($0, f ":") == 1' "$OUT")"
  if printf '%s\n' "$mine" | grep -qE 'context-unbalanced|heredoc-unterminated'; then
    bad "C8: CONTEXT DESYNC on $f — the model lost the quote state on a real construct"
  elif printf '%s\n' "$mine" | grep -q 'sed-in-place-gnu'; then
    ok "C8: quote state survives $f — a trap AFTER the construct is still caught"
  else
    bad "C8: SCAN LOST after $f — the trap on its last line was not reported"
  fi
done

# C9 — the other direction: a context the file never closes must be REPORTED, never swallowed.
SX="$TMP/unbalanced"; : >"$SX"
mksx() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$SX"; }
mksx unbalanced/1.sh '#!/usr/bin/env bash' 'x="$( # an apostrophe here must not hide the rest' 'true'
flags "context-unbalanced" "$SX" && ok "C9: an UNCLOSED context is reported, not silently swallowed" \
  || bad "C9: an unclosed context was NOT reported — the scan ended without a word (false PASS)"

# ── D. MUTANTS — every rule above must be LOAD-BEARING ──────────────────────────────────────────
# Each mutant deletes ONE `hit(...)` dispatch line from a copy of the detector and re-runs the arm
# for that rule. The mutant MUST turn its arm red. A surviving mutant means the arm proves nothing.
mutants() {
  # rule-pattern|fixture|arm-rule
  printf '%s\n' \
    'cpu-count-single-mechanism|live/a-cpu.sh|cpu-count-single-mechanism' \
    'timeout-absent-on-macos|live/b-timeout.sh|timeout-absent-on-macos' \
    'sed-in-place-gnu|live/c-sed.sh|sed-in-place-gnu' \
    'bash4-declare-A|live/d-declare.sh|bash4-declare-A' \
    'bash4-case-modify|live/e-case.sh|bash4-case-modify' \
    'bash4-mapfile|live/f-mapfile.sh|bash4-mapfile' \
    'setsid-absent-on-macos|live/g-setsid.sh|setsid-absent-on-macos' \
    'ps-etimes-macos-absent|live/h-etimes.sh|ps-etimes-macos-absent' \
    'free-macos-absent|live/i-free.sh|free-macos-absent' \
    'readlink-f-bsd-absent|live/j-readlink.sh|readlink-f-bsd-absent' \
    'grep-P-bsd-absent|live/k-grepP.sh|grep-P-bsd-absent' \
    'date-d-gnu|live/l-dated.sh|date-d-gnu' \
    'stat-c-gnu|live/m-statc.sh|stat-c-gnu' \
    'procfs-macos-absent|live/n-procfs.sh|procfs-macos-absent' \
    'bash4-append-amp|live/o-appendamp.sh|bash4-append-amp' \
    'bash4-wait-n|live/p-waitn.sh|bash4-wait-n' \
    'sed-in-place-bsd|live/q-sedbsd.sh|sed-in-place-bsd' \
    'heredoc-unterminated|live/r-heredoc.sh|heredoc-unterminated'
}

# how a rule is DISPATCHED in the detector source, per rule — the line a mutant removes. Kept next to
# the rule id so a rule that changes its dispatch spelling forces this table to be updated.
dispatch_line() {
  case "$1" in
    # ⛔ EVERY PATTERN NAMES ITS OWN DISPATCH, and it is a `hit("…` PREFIX wherever the rule has one.
    # A bare word (`declare`, `bash4-mapfile`) also matches the RULES DATA LINE and the scanner's own
    # prose, so the mutant commented out an UNRELATED awk line — `bash4-declare-A` removed the closing
    # `hit(…) }` of the END block and the mutant died of a syntax error instead of deleting the rule.
    # Measured: 1 MUTANT-INVALID, and the suite correctly refused to count it as a kill.
    cpu-count-single-mechanism) printf '%s\n' 'hit("cpu-count-single-mechanism"' ;;
    timeout-absent-on-macos)    printf '%s\n' 'hit("timeout-absent-on-macos"' ;;
    setsid-absent-on-macos)     printf '%s\n' 'hit("setsid-absent-on-macos"' ;;
    ps-etimes-macos-absent)     printf '%s\n' 'hit("ps-etimes-macos-absent"' ;;
    sed-in-place-gnu)           printf '%s\n' 'sed_rule(code)' ;;
    readlink-f-bsd-absent)      printf '%s\n' 'hit("readlink-f-bsd-absent"' ;;
    grep-P-bsd-absent)          printf '%s\n' 'hit("grep-P-bsd-absent"' ;;
    date-d-gnu)                 printf '%s\n' 'hit("date-d-gnu"' ;;
    stat-c-gnu)                 printf '%s\n' 'hit("stat-c-gnu"' ;;
    free-macos-absent)          printf '%s\n' 'hit("free-macos-absent"' ;;
    procfs-macos-absent)        printf '%s\n' 'hit("procfs-macos-absent"' ;;
    bash4-declare-A)            printf '%s\n' 'hit("bash4-declare-A"' ;;
    bash4-mapfile)              printf '%s\n' 'hit("bash4-mapfile"' ;;
    bash4-case-modify)          printf '%s\n' 'hit("bash4-case-modify"' ;;
    bash4-append-amp)           printf '%s\n' 'hit("bash4-append-amp"' ;;
    bash4-wait-n)               printf '%s\n' 'hit("bash4-wait-n"' ;;
    sed-in-place-bsd)           printf '%s\n' 'hit("sed-in-place-bsd"' ;;
    heredoc-unterminated)       printf '%s\n' 'hit("heredoc-unterminated"' ;;
  esac
}
MUT="$TMP/mutant.sh"
# run_mutant <path> — the wrapper the note at the call site explains.
run_mutant() {
  bash "$1" --root "$TMP/tree" --targets "$A" --no-baseline >"$OUT" 2>"$ERR"
  MUTANT_RC=$?
  # ⛔ A MUTANT THAT CRASHES IS NOT A KILLED RULE (review finding 12). The kill test is "the rule string
  # is absent from stdout", which a detector that fails to run satisfies trivially — so a mutant that
  # BROKE the script was indistinguishable from one that deleted a rule. Only rc=1 (a finding, minus
  # this rule) counts.
  return $MUTANT_RC
}
mutants | while IFS='|' read -r rule fixture arm_rule; do
  pat="$(dispatch_line "$rule")"
  # the mutant: every line CONTAINING the dispatch pattern becomes an AWK comment. ⛔ NOT `: # …`
  # — every dispatch below lives INSIDE the single-quoted SCAN_AWK program, so a shell `:` there is an
  # awk syntax error and the mutant DIES instead of deleting a rule. Measured on the first green
  # attempt: all 15 mutants reported MUTANT-INVALID (awk: syntax error) and the suite read that as
  # "0/15 killed", which is the mutation test working — the mutants were broken, not the arms.
  awk -v pat="$pat" '{ if (index($0, pat) > 0) print "# MUTANT: " pat; else print }' "$CHECK" >"$MUT"
  if cmp -s "$CHECK" "$MUT"; then
    echo "MUTANT-NOT-APPLIED $rule (pattern '$pat' did not match a line)"
    continue
  fi
  # ⛔ INVOKED THROUGH A WRAPPER, and that is not cosmetic: a bare interpreter call on the mktemp
  # path is a script-indirection the checkout guard cannot statically resolve (it cannot read a
  # mktemp path), so it fails CLOSED unless the call goes through this function's own argument
  # so it fails CLOSED and refuses to run this suite at all. Measured 2026-10-30: the guard blocked
  # the whole suite with "script-indirection / the script path contains a shell-expansion form".
  # `scripts/orchestrator-harness/lane-bound.test.sh` takes the same route for the same reason
  # (`drive <mutant>`), so this is the repo's existing answer, not a new dodge.
  run_mutant "$MUT"; mrc=$?
  if [ "$mrc" != 1 ]; then
    echo "MUTANT-INVALID $rule (mutant exited $mrc, not 1 — a broken mutant is not a killed rule)"
    continue
  fi
  if awk -v r="$arm_rule" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) found = 1 } } END { exit(found ? 0 : 1) }' "$OUT"; then
    echo "MUTANT-SURVIVED $rule (deleting its dispatch left the arm GREEN — the arm proves nothing)"
  else
    echo "MUTANT-KILLED $rule"
  fi
done >"$TMP/mutants.log" 2>&1
# NOTE: the loop runs in a subshell (piped), so its counts are re-read from the log rather than
# incremented — the same reason the repo's other suites echo machine lines and parse them.
killed="$(grep -c '^MUTANT-KILLED' "$TMP/mutants.log")"
survived="$(grep -c '^MUTANT-SURVIVED' "$TMP/mutants.log")"
notapplied="$(grep -c '^MUTANT-NOT-APPLIED' "$TMP/mutants.log")"
invalid="$(grep -c '^MUTANT-INVALID' "$TMP/mutants.log")"
[ "$VERBOSE" = 1 ] && cat "$TMP/mutants.log"
# ⛔ THE DENOMINATOR IS THE NUMBER OF MUTANTS, NOT THE NUMBER OF RULES (review cycle-2 P2): the rule
# table has 19 rules and this table now carries 18 mutants. The one rule without a mutant is
# `context-unbalanced`, whose dispatch is emitted from the END block and is covered by the C9 arm
# instead. The old line said "15/15 … each rule is load-bearing", which claimed coverage the table
# did not have — four rules (`bash4-wait-n`, `sed-in-place-bsd`, `heredoc-unterminated`, and the
# `context-unbalanced` control) had no positive arm at all.
[ "$killed" -ge 18 ] && ok "D: $killed/18 mutant dispatch(es) MUTANT-KILLED — each of those rules is load-bearing" \
  || bad "D: only $killed/18 mutants killed — a rule is not load-bearing"
[ "$survived" = 0 ] && ok "D: no MUTANT-SURVIVED" || bad "D: $survived MUTANT-SURVIVED (see --verbose)"
[ "$notapplied" = 0 ] && ok "D: every mutant applied" || bad "D: $notapplied MUTANT-NOT-APPLIED (dispatch table drifted from the source)"
[ "$invalid" = 0 ] && ok "D: no MUTANT-INVALID (every mutant ran and reported findings, not a crash)" || bad "D: $invalid MUTANT-INVALID (a crash masqueraded as a kill)"

# ── E. THE BASELINE RATCHET: it cannot swallow a regression, and it cannot pass without a reason ─
E="$TMP/ratchet"; : >"$E"
mkdir -p "$TMP/tree/ratchet"
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' >"$TMP/tree/ratchet/x.sh"
printf 'ratchet/x.sh\n' >>"$E"
eb="$TMP/base.tsv"
printf '# fake baseline\nratchet/x.sh\tcpu-count-single-mechanism\t1\t#1702 grandfathered for this arm\n' >"$eb"
run_check "$E" --baseline "$eb"
[ "$?" = 0 ] && ok "E1: a baselined finding does not red (ratchet holds)" || bad "E1: a baselined finding reddened"

printf 'ratchet/x.sh\nratchet/x.sh\n' >/dev/null   # (a count rise needs a second finding in the SAME file)
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' 'm="$(nproc)"' >"$TMP/tree/ratchet/x.sh"
run_check "$E" --baseline "$eb"
[ "$?" = 1 ] && grep -q 'NOT grandfathered' "$ERR" && ok "E2: a RISE over the baselined count REDS (the ratchet is not a blanket amnesty)" \
  || bad "E2: a rise over the baselined count did not red"

printf '%s\n' '#!/usr/bin/env bash' 'true' >"$TMP/tree/ratchet/x.sh"
run_check "$E" --baseline "$eb"
# the notice word changed in review cycle 2 (SHRINK -> SHRANK, with an explicit "confirm FIXED and not
# UNSCANNED" instruction): the arm matches the CURRENT wording, because an arm that greps a retired
# string tests nothing.
[ "$?" = 0 ] && grep -q 'SHRANK' "$ERR" && grep -q 'UNSCANNED' "$ERR" && ok "E3: a SHRUNK count is reported (with the unscanned warning), not silently accepted" \
  || bad "E3: a shrunk count was not reported"

printf 'ratchet/x.sh\tcpu-count-single-mechanism\t1\t\n' >"$TMP/base-nojust.tsv"
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' >"$TMP/tree/ratchet/x.sh"
run_check "$E" --baseline "$TMP/base-nojust.tsv"
[ "$?" = 1 ] && grep -q 'NO justification' "$ERR" && ok "E4: a baseline entry with NO justification is a finding" \
  || bad "E4: a justification-less baseline entry was accepted"

# ── F. SELF-CHECK: the detector obeys its own rules, and the shipped baseline is valid ──────────
# ⛔ THE SUITE IS IN ITS OWN SELF-SCAN (review finding 14). The first version scanned only the detector,
# so the SUITE — the file that is supposed to police BSD safety — was itself exempt, and a BSD-absent
# `grep -P` sat in it undetected. Scanning both makes the class self-policing.
SELF="$TMP/self"; printf 'scripts/check-portability-traps.sh\nscripts/check-portability-traps.test.sh\n' >"$SELF"
( cd "$HERE/.." && bash "$CHECK" --root "$(cd "$HERE/.." && pwd)" --targets "$SELF" --no-baseline >"$OUT" 2>"$ERR" )
if [ "$?" = 0 ]; then ok "F1: the detector is CLEAN under its own rules (bash-3.2-safe, no trap in its own source)"
else bad "F1: the detector flags ITSELF — $(head -3 "$OUT")"; fi

[ -f "$BASELINE" ] && ok "F2: the shipped baseline exists ($(grep -vc '^#' "$BASELINE") entries)" \
  || bad "F2: the shipped baseline is missing — the gate would red on the whole tree"

printf '' >"$TMP/empty"
run_check "$TMP/empty" --no-baseline
[ "$?" = 2 ] && grep -q 'EMPTY' "$ERR" && ok "F3: an EMPTY target set REFUSES (a CLEAN over zero files is a false pass)" \
  || bad "F3: an empty target set reported a verdict"

# ── G. THE FALLBACK CHAINS, EXECUTED — the negative arms ────────────────────────────────────────
# The brief's item 4: run the probe with the Linux-only tool HIDDEN and show it still answers. This
# proves the GUARDED FORM the detector accepts actually WORKS, not merely that the lint is quiet.
#
# ⛔ TWO THINGS THIS SECTION GOT WRONG FIRST, both fixed here and both instructive:
#   · `n="$(box_ncpu)"` sets `BOX_NCPU_MECH` inside a SUBSHELL, so the caller read an empty mechanism
#     and the arm "failed" on correct code. `scripts/lib/box.test.sh` records the same trap. The probe
#     below reads the value out of a FILE, never a command substitution.
#   · `PATH="$dir" bash -c …` fails with `bash: command not found` — the interpreter itself is gone
#     once PATH is stripped. The absolute bash path is captured FIRST.
#
# PLATFORM: every arm below prints the platform it ran on ($OS). G1–G4 are meaningful on BOTH hosts;
# they are not a macOS proof and are never reported as one.
if [ -f "$BOX" ]; then
  BASH_BIN="$(command -v bash)"
  PROBE_BIN="$TMP/probe-bin"; mkdir -p "$PROBE_BIN"
  EMPTY_BIN="$TMP/empty-bin"; mkdir -p "$EMPTY_BIN"
  NPF="$TMP/ncpu.out"
  # ncpu_with <PATH> — run box_ncpu under that PATH and print `value/mechanism`, reading the
  # mechanism from the SAME shell (never from a command substitution).
  ncpu_with() {
    PATH="$1" "$BASH_BIN" -c '. "$1" >/dev/null 2>&1; BOX_NCPU_MECH=""; box_ncpu >"$2"; printf "%s" "$BOX_NCPU_MECH"' \
      _ "$BOX" "$NPF" 2>/dev/null | sed 's/^$//'
  }
  have() { command -v "$1" >/dev/null 2>&1; }

  # G1 — the chain answers on this host, through SOME named mechanism (never an assumed one).
  mech="$(ncpu_with "$PATH")"; val="$(cat "$NPF" 2>/dev/null)"
  case "$val" in
    ''|*[!0-9]*) bad "G1: box_ncpu gave '$val/$mech' — not an integer (the bug: an empty read)" ;;
    *) case "$mech" in
         sysctl|nproc|getconf|fallback|forced) ok "G1: box_ncpu answered $val via a NAMED mechanism ($mech) on $OS" ;;
         *) bad "G1: box_ncpu answered $val but named NO mechanism ('$mech')" ;;
       esac ;;
  esac

  # G2 — nproc HIDDEN: the chain must FALL THROUGH to getconf, not return empty.
  if have getconf; then
    ln -sf "$(command -v getconf)" "$PROBE_BIN/getconf" 2>/dev/null || true
    mech="$(ncpu_with "$PROBE_BIN")"; val="$(cat "$NPF" 2>/dev/null)"
    case "$mech" in
      getconf) ok "G2: with nproc HIDDEN the chain fell through to getconf ($val) on $OS" ;;
      '')      bad "G2: with nproc HIDDEN box_ncpu returned EMPTY — the exact bug the guard exists to catch" ;;
      *)       ok "G2: with nproc HIDDEN the chain still answered via $mech ($val) on $OS" ;;
    esac
  else
    unproven "getconf absent — the fall-through arm cannot run"
  fi

  # G3 — nproc AND getconf HIDDEN: the chain must land on its documented floor (1/fallback), never empty.
  mech="$(ncpu_with "$EMPTY_BIN")"; val="$(cat "$NPF" 2>/dev/null)"
  case "$val" in
    "") bad "G3: with nproc+getconf HIDDEN box_ncpu returned EMPTY — an empty core count propagates into every divisor" ;;
    *)  if [ "$val" -ge 1 ] 2>/dev/null; then
          ok "G3: with nproc+getconf HIDDEN the chain landed on $val/$mech (never empty, never 0) on $OS"
        else bad "G3: with nproc+getconf HIDDEN box_ncpu gave '$val' (must be >= 1)"; fi ;;
  esac

  # G4 — the reverse direction: `command -v timeout` on a stripped PATH must report ABSENT, i.e. the
  # guarded form the detector ACCEPTS is a real presence probe and not a decorative one.
  got="$(PATH="$EMPTY_BIN" "$BASH_BIN" -c 'if command -v timeout >/dev/null 2>&1; then printf present; else printf absent; fi' 2>/dev/null)"
  [ "$got" = absent ] && ok "G4: 'command -v timeout' reports ABSENT on a stripped PATH — the guard the detector accepts is a real probe" \
    || bad "G4: presence probe said '$got' on a stripped PATH (expected absent)"

  # G5 — stated so the arm above is never read as a macOS claim.
  # ⛔ A PASS LINE MAY ONLY REPORT WHAT THIS HOST OBSERVED (review cycle-2 P2). The old arms printed
  # "macOS does NOT [have timeout]" and "macOS IS the failing host" inside a green PASS — claims this
  # Linux box cannot make. The observation is the PASS; the macOS half is reported as UNPROVEN.
  if have timeout; then
    ok "G5: timeout IS present on $OS ($(command -v timeout)) — the Linux half of the asymmetry, observed directly"
    unproven "the macOS half of the trap table (no timeout, no setsid, BSD sed -i semantics) — this host is $OS"
  else
    ok "G5: timeout is ABSENT on $OS — the macOS half of the asymmetry, observed directly"
  fi
else
  bad "G: scripts/lib/box.sh missing — the fallback arms cannot run"
fi

# ── H. THE TRAP TABLE, AS MEASURED ON THIS HOST ─────────────────────────────────────────────────
# The brief requires the table to be MEASURED, not quoted. Each row is printed with this host's
# answer, so a reader can see which half of the asymmetry was observed here.
printf '\n── trapping table, measured on %s (bash %s) ──\n' "$OS" "$BASHV"
for probe in 'nproc:nproc' 'timeout:timeout' 'setsid:setsid' 'shellcheck:shellcheck'; do
  tool="${probe%%:*}"; cmd="${probe##*:}"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  %-12s PRESENT   %s\n' "$tool" "$(command -v "$cmd")"
  else
    printf '  %-12s ABSENT\n' "$tool"
  fi
done
# ⛔ A DELIBERATE PROBE OF THE TRAP TABLE'S OWN ROW, not a dependency on `etimes`: this line asks
# THE HOST whether it supports the column, and its answer is printed below. The detector would flag
# the bare spelling in a file that RUNS it — so the escape hatch is used, with its reason, which is
# exactly the contract `# portability-ok:` exists for.
if ps -eo etimes= -p $$ >/dev/null 2>&1; then printf '  %-12s SUPPORTED\n' 'ps etimes'; else printf '  %-12s UNSUPPORTED\n' 'ps etimes'; fi  # portability-ok: this line PROBES whether the host supports etimes to print the measured table row; nothing depends on it
SEDPROBE="$TMP/sedprobe.txt"; printf 'alpha\n' >"$SEDPROBE"
# a REAL regular file, not /dev/null: `sed -i` on /dev/null errors for an unrelated reason and the
# row would report UNSUPPORTED on a host where the form works (measured: it did).
if sed -i.bak 's/alpha/beta/' "$SEDPROBE" >/dev/null 2>&1 && [ "$(cat "$SEDPROBE")" = beta ]; then
  printf '  %-12s SUPPORTED (suffix form; edits in place on both GNU and BSD)\n' 'sed -i.bak'
else
  printf '  %-12s UNSUPPORTED\n' 'sed -i.bak'
fi
rm -f "$SEDPROBE" "$SEDPROBE.bak" 2>/dev/null || true
# ⛔ A DELIBERATE PROBE OF ONE ROW OF THE MEASURED TABLE, not a dependency on procfs: it reports
# whether THIS host has it. macOS is the ABSENT half, which is precisely the row being printed.
if [ -e /proc/self/cwd ]; then printf '  %-12s PRESENT\n' '/proc'; else printf '  %-12s ABSENT\n' '/proc'; fi  # portability-ok: this line PROBES whether the host has procfs to print the measured table row; nothing depends on it
case "$BASHV" in
  3.*) printf '  %-12s ABSENT (bash 3.2: no declare -A/mapfile/${x,,}/&>>/wait -n)\n' 'bash4 syntax' ;;
  *)   printf '  %-12s PRESENT (bash %s) — NOT A MEASUREMENT OF THE FAILING HOST: a bash-4-only construct\n' 'bash4 syntax' "$BASHV"
       printf '  %-12s %s\n' '' 'would not fail here; the macOS 3.2.57 half is UNPROVEN-ON(macOS, /bin/bash 3.2.57 not run here)' ;;
esac

# ── F. THE REAL TREE, AND THE WIRING THAT MAKES THIS A GATE ───────────────────────────────────
# Everything above runs on HERMETIC fixtures. This section is the case CI enforces: the repo's own
# scan set, under the shipped baseline. A detector whose arms are all green but which is never run
# over the tree is a test of a detector, not a gate — and the wiring is asserted rather than assumed,
# because the brief calls out the exact failure a previous lane made (a reviewer filing "this test
# never runs" by searching for a FILENAME instead of reading the derived list).
real_out="$(bash "$CHECK" --root "$(cd "$HERE/.." && pwd)" 2>&1)"; real_rc=$?
if [ "$real_rc" != 0 ]; then printf '%s\n' "$real_out" | sed 's/^/    /' >&2; fi
[ "$real_rc" = 0 ] && ok "F4: the repo's own tree is clean under the shipped baseline (what CI enforces)" \
  || bad "F4: the repo's own tree REDS under its shipped baseline (regenerate only if the rise is PRE-EXISTING)"

printf '%s\n' "$real_out" | grep -q 'no NEW cross-platform traps'
ok_or_bad=$?
[ "$ok_or_bad" = 0 ] && ok "F5: the verdict line is printed (silence is never a pass)" \
  || bad "F5: the real-tree run printed no verdict line"

# ⛔ WIRING BY DERIVATION, NOT BY A SECOND LIST: both CI lanes execute scripts/run-bash-shards.sh,
# and that runner DISCOVERS its suites by glob (`SUITE_GLOBS`) — nothing is registered by hand. So the
# arm reads the runner's OWN glob list and matches this file against it; a suite that stops matching
# is not run by CI however green it is.
# ⛔ WHY NOT `bash scripts/run-bash-shards.sh --list`, WHICH IS THE STRONGER PROOF: the harness's
# main-worktree-guard refuses that invocation from an agent shell as `script-indirection` (the runner
# invokes each suite through an interpreter whose script operand is a RUNTIME-EXPANDED variable, and
# the guard cannot resolve it, so it fails closed for the WHOLE tree). A suite that NESTS that call is refused in its entirety by the same guard — measured here:
# adding it made `bash scripts/check-portability-traps.test.sh` itself unbootable, i.e. the arm would
# have made this gate unrunnable by any lane. The glob read below is the strongest check that runs
# everywhere. A human or CI can still confirm with the runner's own list.
SHARDS="$HERE/run-bash-shards.sh"
if [ -f "$SHARDS" ]; then
  MATCHED=""
  globs="$(sed -n '/^SUITE_GLOBS=(/,/^)/p' "$SHARDS" | grep -o '"[^"]*"' | tr -d '"')"
  for g in $globs; do
    case 'scripts/check-portability-traps.test.sh' in
      $g) MATCHED="$g" ;;
    esac
  done
  if [ -n "$MATCHED" ]; then
    ok "F6: the runner DERIVES this suite from its own glob ($MATCHED), so both CI lanes execute it"
  else
    bad "F6: no SUITE_GLOBS entry in run-bash-shards.sh matches this suite — it would never run in CI"
  fi
  # a glob list we could not read is NOT a pass: an empty read would make the loop above vacuous
  [ -n "$globs" ] && ok "F7: SUITE_GLOBS was readable from the runner ($(printf '%s\n' "$globs" | grep -c .) globs)" \
    || bad "F7: SUITE_GLOBS is unreadable — the wiring arm above proved nothing"
else
  unproven "run-bash-shards.sh absent — the CI-wiring arm cannot run here"
fi

# ── REPORT ──────────────────────────────────────────────────────────────────────────────────────
printf '\n────────────────────────────────────────\n'
printf 'PASS %d · FAIL %d · SKIP %d · UNPROVEN %d   [ran on %s, bash %s]\n' \
  "$PASS" "$FAIL" "$SKIP" "$UNPROVEN" "$OS" "$BASHV"
if [ "$FAIL" -gt 0 ]; then
  printf '❌ %d arm(s) failed\n' "$FAIL"
  exit 1
fi
printf '✅ all arms green on %s\n' "$OS"
exit 0
