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
# HERMETIC *FIXTURES*: every fixture is built under $TMP, and the arms A–E scan ONLY fixture target
# lists (`--targets`) — no arm's verdict depends on a real file. But this suite is NOT tree-independent,
# and the earlier wording claimed it was (review finding, three cycles): F1 scans the detector+brief
# themselves, F4/F5 scan the REPO'S OWN TREE under the shipped baseline (that IS the gate), and F6 reads
# `scripts/run-bash-shards.sh` to prove the suite is discovered. The consequence a reader must know: a
# lane that adds a real trap reds THIS shard, by design.
#
#   bash scripts/check-portability-traps.test.sh
#   bash scripts/check-portability-traps.test.sh --verbose
#
# ⛔ IF THE LOCAL CHECKOUT GUARD REFUSES THIS SUITE (fails closed: "script-indirection — the discard's
# effect could not be verified", #709), do NOT work around it by weakening the arms: run the SAME bytes
# from a detached worktree, which the guard can read —
#   git worktree add --detach /var/tmp/ptc4 HEAD
#   cp scripts/check-portability-traps.sh scripts/check-portability-traps.test.sh /var/tmp/ptc4/scripts/
#   bash /var/tmp/ptc4/scripts/check-portability-traps.test.sh      # sha256 must match the repo copy
# (Measured 2026-10-31: the guard refused the in-repo invocation for a whole cycle while the identical
# bytes ran green in the detached worktree.)

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


# ⛔ THE MARKER MUST BE A REAL COMMENT, NOT MERELY THE TEXT (review cycle-18 P2). The hatch matched
# `raw`, so a `#` inside a QUOTED STRING silenced the line: program text could suppress the gate, and
# the diff would show nothing but a string. Both fixtures below carry the identical sed, so the ONLY
# difference is where the `#` sits — that is what makes this a discriminating pair.
mkdir -p "$TMP/tree/qmark"
printf '%s\n' '#!/usr/bin/env bash' 'echo "note # portability-ok: caller pins GNU sed" > f; sed -i "s/a/b/" g.txt' >"$TMP/tree/qmark/1-quoted.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "note nothing special" > f; sed -i "s/a/b/" g.txt' >"$TMP/tree/qmark/2-plain.sh"
# ⛔ ONE TARGET PER ARM, NOT BOTH (measured while mutation-testing this very arm): a list holding the
# quoted fixture AND a plain one satisfied `flags` through the plain file, so the arm stayed green
# against a detector with the raw-text hatch restored — a non-discriminating arm, which is exactly
# what C20 is here to prevent it from being.
printf 'qmark/1-quoted.sh\n' >"$TMP/qmark-quoted"
printf 'qmark/2-plain.sh\n' >"$TMP/qmark-plain"
flags "sed-in-place-gnu" "$TMP/qmark-quoted"
[ "$?" = 0 ] && ok "C19: a '# portability-ok:' INSIDE A QUOTED STRING does not suppress the trap on that line (program text cannot silence the gate)" \
  || bad "C19: a quoted '#' suppressed a real trap — the hatch is matching text, not comments"
# the positive control: the SIBLING fixture differs only in the quoted text, and it must flag — else
# nothing is proven about the quoted one above (a matcher that flags neither would pass C19 by silence).
flags "sed-in-place-gnu" "$TMP/qmark-plain"
[ "$?" = 0 ] && ok "C20: the sibling fixture, identical except for the quoted text, DOES flag (so C19 measures the hatch, not a broken fixture)" \
  || bad "C20: the control fixture did not flag — C19 proves nothing"

# ⛔ AND THE GLUED FORM, WHICH WAS A FALSE PASS TWICE OVER (review cycle-18b P1): bash starts a comment
# only where a `#` begins a WORD, so `${x}#` and `$(cmd)#` keep the text as DATA (measured:
# `x=abc; echo ${x}# portability-ok: r` prints it) — but this reader took the `#` as a comment, truncated
# the code view there, and then BLESSED the line through the marker. Both fixtures below failed to report
# their `sed -i` on `origin/main`; the same shape without the marker was equally silent, which is why the
# arm asserts the TRAP, not the marker.
mkdir -p "$TMP/tree/glued"
printf '%s\n' '#!/usr/bin/env bash' 'x=abc; echo ${x}# portability-ok: nothing special; sed -i "s/a/b/" g.txt' >"$TMP/tree/glued/1-brace.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=$(echo a)# portability-ok: nothing special; sed -i "s/a/b/" g.txt' >"$TMP/tree/glued/2-subst.sh"
printf 'glued/1-brace.sh\nglued/2-subst.sh\n' >"$TMP/glued-targets"
flags "sed-in-place-gnu" "$TMP/glued-targets"
[ "$?" = 0 ] && ok "C21: a '#' GLUED to \${ } / \$( ) is data, not a comment — the trap to its right is still reported (it was silently unscanned on main)" \
  || bad "C21: a glued '#' truncated the line and hid a real trap"

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
# 6 — ANSI-C quoting: `\` ESCAPES the quote inside `$'…'`, so the span does not close at the first
#     apostrophe. Reading it as closed RE-OPENS a phantom span and every later line becomes data.
mkdir -p "$TMP/tree/survive"
cat >"$TMP/tree/survive/6-ansi-c.sh" <<'C8ANSI'
#!/usr/bin/env bash
msg=$'it\'s a live lane\'s checkout'
echo "$msg"
sed -i 's/a/b/' f.txt
C8ANSI
printf '%s\n' survive/6-ansi-c.sh >>"$SW"
# 7 — a QUOTED argument that merely SPELLS a heredoc opener is DATA, not an opener.
mksw survive/7-phantom-open.sh \
  '#!/usr/bin/env bash' \
  'x="a \" cat <<EOF b"' \
  "sed -i 's/a/b/' f.txt"
# 8 — CRLF: an exact terminator compare that keeps the \r never matches, so the body never ends.
mkdir -p "$TMP/tree/survive"
printf '#!/bin/bash\r\ncat <<EOF\r\nbody\r\nEOF\r\nsed -i \x27s/a/b/\x27 f\r\n' >"$TMP/tree/survive/8-crlf.sh"
printf '%s\n' survive/8-crlf.sh >>"$SW"
# 9 — a LEGAL quoted `}` inside `${…}`: the default value is the quoted string `a}b`, so a brace
#     reader that pops on the first `}` leaves a phantom open quote and the rest of the file goes
#     unscanned (review cycle-6 P2, reported honestly as context-unbalanced — a false RED, not a
#     false PASS, but it also LOST the real trap one line below).
mksw survive/9-brace-quote.sh \
  '#!/usr/bin/env bash' \
  'x="${y:-"a}b"}"' \
  'p="${path#\"}"' \
  "sed -i 's/a/b/' f.txt"

run_check "$SW" --no-baseline
# EVERY ASSERTION IS PER FILE: a desync in ONE fixture must not be blamed on the other four (the
# first version grepped the whole output, so one bad fixture reddened all five arms).
for f in survive/1-comment-sub.sh survive/2-len-arith.sh survive/3-shift.sh \
         survive/4-heredoc-sub.sh survive/5-awk-multi.sh survive/6-ansi-c.sh \
         survive/7-phantom-open.sh survive/8-crlf.sh survive/9-brace-quote.sh; do
  mine="$(awk -v f="$f" 'index($0, f ":") == 1' "$OUT")"
  if grep -qE 'context-unbalanced|heredoc-unterminated' <<<"$mine"; then
    bad "C8: CONTEXT DESYNC on $f — the model lost the quote state on a real construct"
  elif grep -q 'sed-in-place-gnu' <<<"$mine"; then
    ok "C8: quote state survives $f — a trap AFTER the construct is still caught"
  else
    bad "C8: SCAN LOST after $f — the trap on its last line was not reported"
  fi
done

# C9 — the other direction: a context the file never closes must be REPORTED, never swallowed.
# C9b — a file that DECLARES itself out of scope must not report the EOF rules: its own remedy text
# ("declare the file `# portability: off <reason>`") is what it already does, so a finding there is
# unfixable by its own instruction.
SO="$TMP/offdecl"; : >"$SO"
mkso() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$SO"; }
mkso offdecl/1.sh '#!/bin/bash' '# portability: off the fixture body below is Python, not shell' "cat <<'EOF' > /dev/null" 'x = 1'
run_check "$SO" --no-baseline
if [ "$?" = 2 ]; then
  bad "C9b: the declared-off arm was REFUSED (rc=2) — an empty scan proves nothing"
elif grep -qE 'heredoc-unterminated|context-unbalanced' "$OUT"; then
  bad "C9b: a file declared '# portability: off' still reported an EOF rule — the remedy it prints is one it already applies"
else
  ok "C9b: a declared-off file reports no EOF rule"
fi

SX="$TMP/unbalanced"; : >"$SX"
mksx() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$SX"; }
mksx unbalanced/1.sh '#!/usr/bin/env bash' 'x="$( # an apostrophe here must not hide the rest' 'true'
flags "context-unbalanced" "$SX" && ok "C9: an UNCLOSED context is reported, not silently swallowed" \
  || bad "C9: an unclosed context was NOT reported — the scan ended without a word (false PASS)"

# ── C10. THE SHAPES A REVIEW CYCLE CORRECTED — one assertion each ───────────────────────────────
# Every entry below was WRONG at some point in this change review history, and each fix is only as
# durable as its arm: without these, a later edit can revert one and the suite still reports green.
# Two directions, because a detector fails in two ways: a MISSED trap (C10a) and a WRONGLY RED trap
# on portable code (C10b).
Z="$TMP/fixed"; : >"$Z"
mkz() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$Z"; }
mkz fixed/1-assign-timeout.sh   '#!/usr/bin/env bash' 'FOO=1 timeout 5 cmd'
mkz fixed/2-assign-sed.sh       '#!/usr/bin/env bash' "LC_ALL=C sed -i 's/a/b/' f.txt"
mkz fixed/3-probe-other.sh      '#!/usr/bin/env bash' 'command -v jq >/dev/null 2>&1' 'timeout 5 cmd'
mkz fixed/4-env-timeout.sh      '#!/usr/bin/env bash' 'env FOO=1 timeout 5 sleep 1'
mkz fixed/5-sudo-sed.sh         '#!/usr/bin/env bash' "sudo -u root sed -i 's/a/b/' f.txt"
mkz fixed/6-xargs-timeout.sh    '#!/usr/bin/env bash' 'xargs -n1 timeout 5 echo'
mkz fixed/7-sed-cluster-i.sh    '#!/usr/bin/env bash' "sed -Ei 's/a/b/' f.txt"
mkz fixed/8-sed-cluster-ni.sh   '#!/usr/bin/env bash' "sed -ni 'p' f.txt"
mkz fixed/9-sed-long.sh         '#!/usr/bin/env bash' "sed --in-place 's/a/b/' f.txt"
mkz fixed/10-stat-attached.sh   '#!/usr/bin/env bash' 'stat -c%s f.txt'
mkz fixed/11-date-attached.sh   '#!/usr/bin/env bash' 'd=$(date -d@0 +%s)'
mkz fixed/12-stat-long.sh       '#!/usr/bin/env bash' 'stat --format=%Y f.txt'
mkz fixed/13-date-long.sh       '#!/usr/bin/env bash' 'd=$(date --date=@0 +%s)'
mkz fixed/14-readlink-long.sh   '#!/usr/bin/env bash' 'p=$(readlink --canonicalize ./x)'
mkz fixed/15-local-A.sh         '#!/usr/bin/env bash' 'f() { local -A m; m[x]=1; }'
mkz fixed/16-typeset-A.sh       '#!/usr/bin/env bash' 'typeset -A n'
mkz fixed/17-stat-then-rm.sh    '#!/usr/bin/env bash' 'm="$(stat -c %Y "$f" 2>/dev/null || rm -f "$f")"'
mkz fixed/18-date-then-rm.sh    '#!/usr/bin/env bash' 'd="$(date -d @0 +%s)"; rm -r "$tmp"'
mkz fixed/19-wait-n-sep.sh      '#!/usr/bin/env bash' 'if wait -n; then echo ok; fi'
mkz fixed/20-subst-bare.sh      '#!/usr/bin/env bash' 'x="$(free)"'
mkz fixed/21-case-single.sh     '#!/usr/bin/env bash' 'v="x"; echo "${v,}"'
mkz fixed/22-nice-sed.sh        '#!/usr/bin/env bash' "nice -n 5 sed -i 's/a/b/' f"
mkz fixed/23-flock-sed.sh       '#!/usr/bin/env bash' 'flock /tmp/l sed -i s/a/b/ f'
mkz fixed/24-exec-sed.sh        '#!/usr/bin/env bash' 'find . -name "*.sh" -exec sed -i "s/a/b/" {} +'
mkz fixed/25-free-sep.sh        '#!/usr/bin/env bash' 'if free; then echo ok; fi'
mkz fixed/26-readlink-missing.sh '#!/usr/bin/env bash' 'p=$(readlink --canonicalize-missing x)'
# ⛔ THE PREFIX IS A CHAIN (review cycle-6 P0): a keyword followed by `!` or by a wrapper that takes
# its own arguments left the tool INVISIBLE — including a live
# `if ! timeout 300 docker run …` in scripts/orchestrator-harness/worker-terminal.test.sh:2309 that
# sat baselined as clean while the other three calls in that file were reported.
mkz fixed/27-if-not-timeout.sh  '#!/usr/bin/env bash' 'if ! timeout 5 ssh h true; then echo hung; fi'
mkz fixed/28-if-sudo-timeout.sh '#!/usr/bin/env bash' 'if sudo timeout 5 systemctl restart x; then :; fi'
mkz fixed/29-if-nice-sed.sh     '#!/usr/bin/env bash' "if nice -n 5 sed -i 's/a/b/' f; then :; fi"
mkz fixed/30-then-env-timeout.sh '#!/usr/bin/env bash' 'then env FOO=1 timeout 5 true'
# ⛔ A REPEAT IS NOT A CHAIN, AND A WORD IS NOT A MECHANISM (review cycle-6 P0): the cross-line CPU
# guard accepted a SUBSTRING on any earlier line, so a second `nproc` was cleared by the first (a
# repeat of the same mechanism) and an unguarded `sysctl -n hw.ncpu` was cleared by the variable name
# `nproc_` six lines above.
mkz fixed/31-cpu-repeat.sh      '#!/usr/bin/env bash' 'n="$(nproc)"' 'echo unrelated' 'm="$(nproc)"'
mkz fixed/32-cpu-word.sh        '#!/usr/bin/env bash' 'cpu_cap=$(( nproc_ / 2 ))' 'echo one' 'echo two'   'echo three' 'echo four' 'n="$(sysctl -n hw.ncpu)"'
run_check "$Z" --no-baseline
for pair in \
  "timeout-absent-on-macos fixed/1-assign-timeout.sh" \
  "sed-in-place-gnu fixed/2-assign-sed.sh" \
  "timeout-absent-on-macos fixed/3-probe-other.sh" \
  "timeout-absent-on-macos fixed/4-env-timeout.sh" \
  "sed-in-place-gnu fixed/5-sudo-sed.sh" \
  "timeout-absent-on-macos fixed/6-xargs-timeout.sh" \
  "sed-in-place-gnu fixed/7-sed-cluster-i.sh" \
  "sed-in-place-gnu fixed/8-sed-cluster-ni.sh" \
  "sed-in-place-gnu fixed/9-sed-long.sh" \
  "stat-c-gnu fixed/10-stat-attached.sh" \
  "date-d-gnu fixed/11-date-attached.sh" \
  "stat-c-gnu fixed/12-stat-long.sh" \
  "date-d-gnu fixed/13-date-long.sh" \
  "readlink-f-bsd-absent fixed/14-readlink-long.sh" \
  "bash4-declare-A fixed/15-local-A.sh" \
  "bash4-declare-A fixed/16-typeset-A.sh" \
  "stat-c-gnu fixed/17-stat-then-rm.sh" \
  "date-d-gnu fixed/18-date-then-rm.sh" \
  "bash4-wait-n fixed/19-wait-n-sep.sh" \
  "free-macos-absent fixed/20-subst-bare.sh" \
  "bash4-case-modify fixed/21-case-single.sh" \
  "sed-in-place-gnu fixed/22-nice-sed.sh" \
  "sed-in-place-gnu fixed/23-flock-sed.sh" \
  "sed-in-place-gnu fixed/24-exec-sed.sh" \
  "free-macos-absent fixed/25-free-sep.sh" \
  "readlink-f-bsd-absent fixed/26-readlink-missing.sh" \
  "timeout-absent-on-macos fixed/27-if-not-timeout.sh" \
  "timeout-absent-on-macos fixed/28-if-sudo-timeout.sh" \
  "sed-in-place-gnu fixed/29-if-nice-sed.sh" \
  "timeout-absent-on-macos fixed/30-then-env-timeout.sh" \
  "cpu-count-single-mechanism fixed/31-cpu-repeat.sh" \
  "cpu-count-single-mechanism fixed/32-cpu-word.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    ok "C10a: caught $1 in $(basename "$2")"
  else
    bad "C10a: MISSED $1 in $(basename "$2") — a corrected shape regressed"
  fi
done

Z2="$TMP/fixed-clean"; : >"$Z2"
mkz2() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$Z2"; }
mkz2 fixed-clean/1-grep-i-sed.sh '#!/usr/bin/env bash' "grep -i foo f.txt | sed -e 's/a/b/' g.txt"
mkz2 fixed-clean/2-ssh-i-sed.sh  '#!/usr/bin/env bash' "ssh -i key h true; sed -i.bak -e 's/a/b/' f"
mkz2 fixed-clean/3-readlink.sh   '#!/usr/bin/env bash' 'readlink x || grep -f pats f'
mkz2 fixed-clean/4-mapfile-arg.sh '#!/usr/bin/env bash' 'grep -n mapfile README.md'
mkz2 fixed-clean/5-probe-timeout.sh '#!/usr/bin/env bash' 'if command -v -- timeout >/dev/null 2>&1; then timeout 5 true; fi'
mkz2 fixed-clean/6-test-d-flag.sh '#!/usr/bin/env bash' '[ -d "$d" ] && date -u +%s'
mkz2 fixed-clean/7-test-c-flag.sh '#!/usr/bin/env bash' 'if [ -c "$f" ]; then stat "$f"; fi'
mkz2 fixed-clean/8-local-d.sh    '#!/usr/bin/env bash' 'local d; ls -A "$d"'
mkz2 fixed-clean/9-date-v-chain.sh '#!/usr/bin/env bash' 'YOUNG="$(date -u -d 4 minutes ago +%s 2>/dev/null || date -u -v-4M +%s)"'
mkz2 fixed-clean/10-readlink-probe.sh '#!/usr/bin/env bash' 'if command -v readlink >/dev/null 2>&1 && readlink -f -- "$d" >/dev/null 2>&1; then out="$(readlink -f -- "$d")"; fi'
mkz2 fixed-clean/11-arith-var.sh '#!/usr/bin/env bash' 'cpu_cap=$(( nproc_ / 2 ))'
mkz2 fixed-clean/12-proc-test.sh '#!/usr/bin/env bash' '[ -d /proc/self ]' 'if [ -r /proc/loadavg ]; then echo y; fi'
mkz2 fixed-clean/13-proc-value.sh '#!/usr/bin/env bash' 'OUT="$(TMPDIR=/proc/nope bash ./x)"' 'AGENT_GH_GATE_DIR="/proc/nope/gate" bash "$SHIM" api user'
# ⛔ A `command -v` PROBE LINE IS CLEAN WHOLESALE (review cycle-6 P1): `command` is itself a wrapper
# keyword, so the old "probe AND nothing else matched" guard never fired for the `command -v` spelling
# and `command -v free >/dev/null || :` reded a correct file.
mkz2 fixed-clean/15-command-v-free.sh '#!/usr/bin/env bash' 'command -v free >/dev/null 2>&1 || :'
mkz2 fixed-clean/14-probe-and-arg.sh '#!/usr/bin/env bash' 'if grep -q timeout scripts/x.sh; then :; fi' 'command -v free >/dev/null 2>&1' 'if have timeout; then :; fi' 'lc_err "after ${timeout}s"'
run_check "$Z2" --no-baseline
if [ "$?" = 2 ]; then
  bad "C10b: the portable-code arm was REFUSED (rc=2) — an empty scan proves nothing"
else
  for pair in \
    "sed-in-place-gnu fixed-clean/1-grep-i-sed.sh" \
    "sed-in-place-gnu fixed-clean/2-ssh-i-sed.sh" \
    "readlink-f-bsd-absent fixed-clean/3-readlink.sh" \
    "bash4-mapfile fixed-clean/4-mapfile-arg.sh" \
    "timeout-absent-on-macos fixed-clean/5-probe-timeout.sh" \
    "date-d-gnu fixed-clean/6-test-d-flag.sh" \
    "stat-c-gnu fixed-clean/7-test-c-flag.sh" \
    "bash4-declare-A fixed-clean/8-local-d.sh" \
    "date-d-gnu fixed-clean/9-date-v-chain.sh" \
    "readlink-f-bsd-absent fixed-clean/10-readlink-probe.sh" \
    "cpu-count-single-mechanism fixed-clean/11-arith-var.sh" \
    "procfs-macos-absent fixed-clean/12-proc-test.sh" \
    "procfs-macos-absent fixed-clean/13-proc-value.sh" \
    "timeout-absent-on-macos fixed-clean/14-probe-and-arg.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      bad "C10b: FALSE POSITIVE — $1 reded on portable $(basename "$2")"
    else
      ok "C10b: portable code NOT flagged ($(basename "$2"))"
    fi
  done
fi

# ── C11. A DECLARATION TAKES EFFECT FROM ITS OWN LINE ONWARD, WHEREVER IT IS (cycle-6 P2) ───────
# The header promised this from the first commit, but the reader only honoured a declaration in the
# first 20 lines, so a mid-file `# portability: off` was a silent no-op — the promise and the code
# disagreed, and the arm below is the agreement.
mkdir -p "$TMP/tree/midfile"
{ printf '#!/usr/bin/env bash\n'
  i=1; while [ "$i" -le 22 ]; do printf 'echo line%s\n' "$i"; i=$((i+1)); done
  printf '# portability: off this file is a Linux-only helper by design\n'
  printf "sed -i 's/a/b/' f.txt\n"; } >"$TMP/tree/midfile/late-off.sh"
printf 'midfile/late-off.sh\n' >"$TMP/midfile.list"
run_check "$TMP/midfile.list" --no-baseline
mine="$(awk -v f="midfile/late-off.sh" 'index($0, f ":") == 1' "$OUT")"
if grep -q 'sed-in-place-gnu' <<<"$mine"; then
  bad "C11: a mid-file \`# portability: off\` was IGNORED — the header promises it takes effect from its own line"
else
  ok "C11: a mid-file \`# portability: off\` takes effect from its own line (header and code agree)"
fi

# ── C12. THE SEVENTH CYCLE'S SHAPES — one assertion each, both directions ────────────────────────
# The cycle-7 fixes rewrote a regex prefix, a lookback function, a probe short-circuit and the
# `${…}` model, so each has an arm here AND a guard mutant in D2 (a guard that only SUPPRESSES a
# finding cannot be killed by deleting a `hit(…)` dispatch — see D2).
CY="$TMP/cyc7"; : >"$CY"
mkcy() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$CY"; }

# a REPEAT of the same mechanism is not a chain — and the mask bug was asymmetric, so both of the
# mechanisms that used to be cleared are fixtures of their own.
mkcy cyc7/1-repeat-sysctl.sh   '#!/usr/bin/env bash' 'n="$(sysctl -n hw.ncpu)"' 'echo "$n"' 'm="$(sysctl -n hw.ncpu)"'
mkcy cyc7/2-repeat-getconf.sh  '#!/usr/bin/env bash' 'a="$(getconf _NPROCESSORS_ONLN)"' 'echo x' 'b="$(getconf _NPROCESSORS_ONLN)"'
# `eval` takes the rest of its line as the command.
mkcy cyc7/3-eval-sed.sh        '#!/usr/bin/env bash' "eval sed -i 's/a/b/' f.txt"
mkcy cyc7/4-eval-timeout.sh    '#!/usr/bin/env bash' 'eval timeout 5 sleep 1'
# a probe guards only the `&&`-conditioned call: after `;` the call always runs, after `||` it runs
# exactly when the tool is ABSENT.
mkcy cyc7/5-probe-semi.sh      '#!/usr/bin/env bash' "command -v sed >/dev/null; sed -i 's/a/b/' f.txt"
mkcy cyc7/6-probe-or.sh        '#!/usr/bin/env bash' 'command -v free >/dev/null 2>&1 || free -m'
# `-exec` takes a command but is never in command position.
mkcy cyc7/7-find-exec.sh       '#!/usr/bin/env bash' 'find . -exec sed -i s/a/b/ {} +'
# a single-quoted span inside `${…}` is literal for delimiters, but `$( … )` still runs.
mkdir -p "$TMP/tree/cyc7"
cat >"$TMP/tree/cyc7/8-brace-squote.sh" <<'C7SQ'
#!/usr/bin/env bash
v="${x:-'$(nproc)'}"
echo "$v"
C7SQ
printf '%s\n' cyc7/8-brace-squote.sh >>"$CY"
# THE OTHER DIRECTION — clean shapes that must stay clean.
: >"$TMP/cyc7clean.list"
mkcyc() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$TMP/cyc7clean.list"; }
mkcyc cyc7clean/1-chain.sh     '#!/usr/bin/env bash' 'a="$(nproc)"' 'b="$(sysctl -n hw.ncpu)"'
mkcyc cyc7clean/2-chain-rev.sh '#!/usr/bin/env bash' 'a="$(sysctl -n hw.ncpu)"' 'b="$(nproc)"'
mkcyc cyc7clean/3-chain-1line.sh '#!/usr/bin/env bash' 'n="$(nproc 2>/dev/null)" || n="$(sysctl -n hw.ncpu)"'
mkcyc cyc7clean/4-brace-literal.sh '#!/usr/bin/env bash' 'v="${x:-'"'"'a}b'"'"'}"' 'echo "$v"'
mkcyc cyc7clean/5-probe-and.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 true'

run_check "$CY" --no-baseline
if [ "$?" = 2 ]; then
  bad "C12: the cycle-7 fixture tree was REFUSED (rc=2) — an empty scan proves nothing"
else
  for pair in \
    "cpu-count-single-mechanism cyc7/1-repeat-sysctl.sh" \
    "cpu-count-single-mechanism cyc7/2-repeat-getconf.sh" \
    "sed-in-place-gnu cyc7/3-eval-sed.sh" \
    "timeout-absent-on-macos cyc7/4-eval-timeout.sh" \
    "sed-in-place-gnu cyc7/5-probe-semi.sh" \
    "free-macos-absent cyc7/6-probe-or.sh" \
    "sed-in-place-gnu cyc7/7-find-exec.sh" \
    "cpu-count-single-mechanism cyc7/8-brace-squote.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      ok "C12a: caught $1 in $(basename "$2")"
    else
      bad "C12a: MISSED $1 in $(basename "$2") — a cycle-7 fix regressed"
    fi
  done
  run_check "$TMP/cyc7clean.list" --no-baseline
  # ⛔ A CHAIN'S FIRST ARM IS EXPECTED TO BE FLAGGED (the guard looks BACKWARD — nothing behind the
  # first line can tell it a second mechanism follows), so the chain arms assert on the SECOND line
  # by number rather than on the file. Deleting that distinction is how the cycle-7 mask bug hid: the
  # file-level assertion passed while the second `sysctl` was silently cleared.
  c7clean() {  # <fixture> <rule> <line|*>
    if [ "$3" = "any" ]; then
      awk -v f="$1" -v r="$2" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"
    else
      awk -v f="$1" -v ln="$3" '{ if (index($0, f ":" ln ":") == 1) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"
    fi
  }
  for triple in \
    "cyc7clean/1-chain.sh cpu-count-single-mechanism 3" \
    "cyc7clean/2-chain-rev.sh cpu-count-single-mechanism 3" \
    "cyc7clean/3-chain-1line.sh cpu-count-single-mechanism any" \
    "cyc7clean/4-brace-literal.sh cpu-count-single-mechanism any" \
    "cyc7clean/5-probe-and.sh timeout-absent-on-macos any"
  do
    set -- $triple
    if [ "$3" = "any" ]; then lbl="any line"; else lbl="line $3"; fi
    if c7clean "$1" "$2" "$3"; then
      bad "C12b: FALSE POSITIVE — $2 reded on portable $(basename "$1") ($lbl)"
    else
      ok "C12b: portable code NOT flagged ($(basename "$1") $lbl)"
    fi
  done
fi

# ── C13. THE EIGHTH CYCLE'S SHAPES — the probe does not bless a LINE, it guards a CALL ───────────
# Cycle 7 fixed the conditioning for the rules that go through cp() and left `probed()` blessing the
# whole line for timeout, setsid, readlink and cpu. Each shape below is a live macOS trap that was
# reported CLEAN at the previous head; the clean half is the guarded form the header promises.
C3="$TMP/cyc8"; : >"$C3"
C3C="$TMP/cyc8clean"; : >"$C3C"
mkc3()  { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C3"; }
mkc3c() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C3C"; }

# the `||` arm runs EXACTLY when the tool is absent — the host the rule exists for
mkc3 cyc8/1-probe-or-timeout.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 || timeout 5 sleep 1'
# a `;` arm runs unconditionally
mkc3 cyc8/2-probe-semi-setsid.sh '#!/usr/bin/env bash' 'command -v setsid >/dev/null 2>&1; setsid sleep 1'
# the `else` arm is the trap, and it is the arm a negated probe takes
mkc3 cyc8/3-probe-else-timeout.sh '#!/usr/bin/env bash' 'if command -v timeout >/dev/null 2>&1; then :; else timeout 5 sleep 1; fi'
# per TOOL, not per line: a nproc read is not conditioned on its own probe when it is in the `||` arm
mkc3 cyc8/4-probe-or-nproc.sh '#!/usr/bin/env bash' 'command -v nproc >/dev/null 2>&1 || n="$(nproc)"'
# a NEGATED probe guards nothing, and its `fi` is not a guard for the call after it
mkc3 cyc8/5-neg-probe.sh '#!/usr/bin/env bash' 'if ! command -v timeout >/dev/null 2>&1; then echo no-timeout; fi' 'timeout 5 sleep 1'
# find's sibling predicates take a command too
mkc3 cyc8/6-execdir-sed.sh '#!/usr/bin/env bash' 'find . -execdir sed -i s/a/b/ {} +'
# a declaration inside a COMPUTED-marker heredoc body is data (the extent is unknown)
mkc3 cyc8/7-computed-heredoc-decl.sh '#!/usr/bin/env bash' 'M=EOF' 'cat <<$M' '# portability: off the body of a heredoc is DATA, not a declaration' '$M' "sed -i 's/a/b/' f"
# the escape hatch must be a real comment, not text that merely appears
mkc3 cyc8/8-ok-in-pattern.sh '#!/usr/bin/env bash' "grep -n 'portability-ok:' f; sed -i 's/a/b/' f"
mkc3 cyc8/9-ok-in-string.sh  '#!/usr/bin/env bash' 'flag="portability-ok:1"; sed -i "s/a/b/" "$flag"'

# the guarded forms, which must stay clean
mkc3c cyc8clean/1-then-timeout.sh  '#!/usr/bin/env bash' 'if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi'
mkc3c cyc8clean/2-and-timeout.sh   '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 true'
mkc3c cyc8clean/3-then-sysctl.sh   '#!/usr/bin/env bash' 'if command -v sysctl >/dev/null 2>&1; then' '  n="$(sysctl -n hw.ncpu 2>/dev/null || true)"' 'fi'
mkc3c cyc8clean/4-then-nproc.sh    '#!/usr/bin/env bash' 'if command -v nproc >/dev/null 2>&1; then NCPU="$(nproc 2>/dev/null)"' 'elif command -v sysctl >/dev/null 2>&1; then NCPU="$(sysctl -n hw.ncpu 2>/dev/null)"; fi'
mkc3c cyc8clean/5-real-ok-marker.sh '#!/usr/bin/env bash' "sed -i 's/a/b/' f  # portability-ok: this file deliberately rewrites the fixture in place"
# a `\` inside the literal span means the substitution does NOT run — measured
mkdir -p "$TMP/tree/cyc8clean"
cat >"$TMP/tree/cyc8clean/6-literal-escape.sh" <<'C13ESC'
#!/usr/bin/env bash
unset x
v="${x:-'a\$(nproc)b'}"
echo "$v"
C13ESC
printf '%s\n' cyc8clean/6-literal-escape.sh >>"$C3C"

run_check "$C3" --no-baseline
if [ "$?" = 2 ]; then
  bad "C13: the cycle-8 fixture tree was REFUSED (rc=2) — an empty scan proves nothing"
else
  for pair in \
    "timeout-absent-on-macos cyc8/1-probe-or-timeout.sh" \
    "setsid-absent-on-macos cyc8/2-probe-semi-setsid.sh" \
    "timeout-absent-on-macos cyc8/3-probe-else-timeout.sh" \
    "cpu-count-single-mechanism cyc8/4-probe-or-nproc.sh" \
    "timeout-absent-on-macos cyc8/5-neg-probe.sh" \
    "sed-in-place-gnu cyc8/6-execdir-sed.sh" \
    "sed-in-place-gnu cyc8/7-computed-heredoc-decl.sh" \
    "sed-in-place-gnu cyc8/8-ok-in-pattern.sh" \
    "sed-in-place-gnu cyc8/9-ok-in-string.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      ok "C13a: caught $1 in $(basename "$2")"
    else
      bad "C13a: MISSED $1 in $(basename "$2") — a probe is blessing a line again"
    fi
  done
  run_check "$C3C" --no-baseline
  for pair in \
    "timeout-absent-on-macos cyc8clean/1-then-timeout.sh" \
    "timeout-absent-on-macos cyc8clean/2-and-timeout.sh" \
    "cpu-count-single-mechanism cyc8clean/3-then-sysctl.sh" \
    "cpu-count-single-mechanism cyc8clean/4-then-nproc.sh" \
    "sed-in-place-gnu cyc8clean/5-real-ok-marker.sh" \
    "cpu-count-single-mechanism cyc8clean/6-literal-escape.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      bad "C13b: FALSE POSITIVE — $1 reded on guarded $(basename "$2")"
    else
      ok "C13b: guarded code NOT flagged ($(basename "$2"))"
    fi
  done
fi

# ⛔ THE REPEAT ARMS ASSERT BY LINE, NOT BY FILE (review cycle-8 P2): with a file-level assertion a
# repeat fixture stays green under the very regression it was written for — the second occurrence is
# the one that matters, and a cleared second occurrence still leaves the first reported. Measured on
# the mask bug: both repeat fixtures passed while the repeat was being cleared.
printf 'cyc7/1-repeat-sysctl.sh\ncyc7/2-repeat-getconf.sh\n' >"$TMP/rep.list"
run_check "$TMP/rep.list" --no-baseline
for spec in "cyc7/1-repeat-sysctl.sh 2" "cyc7/1-repeat-sysctl.sh 4" \
            "cyc7/2-repeat-getconf.sh 2" "cyc7/2-repeat-getconf.sh 4"; do
  set -- $spec
  if awk -v f="$1" -v ln="$2" -v r="cpu-count-single-mechanism" \
       '{ if (index($0, f ":" ln ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    ok "C13c: a REPEATED mechanism is flagged on $(basename "$1") line $2"
  else
    bad "C13c: the repeat on $(basename "$1") line $2 was CLEARED — a repeat is not a chain"
  fi
done

# ── C14. THE NINTH CYCLE — a CONDITIONED CALL is not a conditioned LINE, and a shim MENTION is not a CALL
# The cycle-8 fix asked "is there a conditioned call on this line?", which a line carrying BOTH a
# guarded and an unguarded call of the same tool answers YES — the trap is blessed by its neighbour.
# Every fixture below was measured CLEAN at the previous head.
C4="$TMP/cyc9"; : >"$C4"
C4C="$TMP/cyc9clean"; : >"$C4C"
mkc4()  { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C4"; }
mkc4c() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C4C"; }

mkc4 cyc9/1-guarded-then-plain.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 a; timeout 5 b'
mkc4 cyc9/2-guarded-or-fallback.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 a || timeout 5 b'
mkc4 cyc9/3-then-else.sh '#!/usr/bin/env bash' 'if command -v timeout >/dev/null 2>&1; then timeout 5 a; else timeout 5 b; fi'
mkc4 cyc9/4-plain-then-guarded.sh '#!/usr/bin/env bash' 'timeout 5 a; command -v timeout >/dev/null 2>&1 && timeout 5 b'
mkc4 cyc9/5-shim-mentioned-cpu.sh '#!/usr/bin/env bash' 'grep -q box_ncpu lib/box.sh; n="$(nproc)"'
mkc4 cyc9/6-shim-mentioned-sed.sh '#!/usr/bin/env bash' "grep -c box_sed_i lib/box.sh >/dev/null; sed -i -e 's/a/b/' f"
# a BARE `&` ends the arm: the left arm is backgrounded and the right call runs unconditionally
mkc4 cyc9/8-guarded-then-background.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 a & timeout 5 b'
# …for every tool this class covers, because the cut is shared
mkc4 cyc9/9-background-breadth.sh '#!/usr/bin/env bash' 'command -v readlink >/dev/null 2>&1 && readlink -f a & readlink -f b'
mkc4 cyc9/10-background-cpu.sh '#!/usr/bin/env bash' 'command -v nproc >/dev/null 2>&1 && n="$(nproc)" & n="$(nproc)"'
# a PORTABLE sed spelling in one segment must not exonerate a GNU-only `-i` in the next
mkc4 cyc9/11-sed-portable-then-gnu.sh '#!/usr/bin/env bash' 'command -v sed >/dev/null 2>&1 && sed -i.bak -e s/a/b/ f & sed -i -e s/a/b/ g'
# a CORRECT shim call in one segment must not exonerate a GNU-only call in the next
mkc4 cyc9/12-shim-then-gnu-sed.sh '#!/usr/bin/env bash' 'box_sed_i "s/a/b/" f; sed -i "s/a/b/" g'
mkc4 cyc9/13-shim-then-plain-nproc.sh '#!/usr/bin/env bash' 'n="$(box_ncpu)"; m="$(nproc)"'
mkc4 cyc9/7-repeat-one-probed.sh '#!/usr/bin/env bash' 'command -v nproc >/dev/null 2>&1 && n="$(nproc)"; m="$(nproc)"'

# …and the forms that ARE conditioned must stay clean, including a whole `&&` chain
mkc4c cyc9clean/1-and-chain.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 a && timeout 5 b'
mkc4c cyc9clean/2-then-single.sh '#!/usr/bin/env bash' 'if command -v timeout >/dev/null 2>&1; then timeout 5 a; fi'
mkc4c cyc9clean/3-then-multiline.sh '#!/usr/bin/env bash' 'if command -v timeout >/dev/null 2>&1; then' '  timeout 5 a' 'fi'
mkc4c cyc9clean/4-shim-called.sh '#!/usr/bin/env bash' 'n="$(box_ncpu)"' 'box_sed_i "s/a/b/" f'
# the `&` that must NOT end the arm: an AND-join and a redirection
mkc4c cyc9clean/5-redirect-and-chain.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 a 2>/dev/null && timeout 5 b'
mkc4c cyc9clean/6-and-after-redirect.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 a >/dev/null 2>&1 && timeout 5 b'
# a portable sed spelling alone (its own segment) stays clean
mkc4c cyc9clean/7-sed-portable.sh '#!/usr/bin/env bash' "sed -i.bak -e 's/a/b/' f && rm -f f.bak"
# the shim on its own stays clean — the exemption is per call, not revoked
mkc4c cyc9clean/8-shim-only.sh '#!/usr/bin/env bash' 'box_sed_i "s/a/b/" f' 'n="$(box_ncpu)"' 'echo "$n"'

run_check "$C4" --no-baseline
if [ "$?" = 2 ]; then
  bad "C14: the cycle-9 fixture tree was REFUSED (rc=2) — an empty scan proves nothing"
else
  for pair in \
    "timeout-absent-on-macos cyc9/1-guarded-then-plain.sh" \
    "timeout-absent-on-macos cyc9/2-guarded-or-fallback.sh" \
    "timeout-absent-on-macos cyc9/3-then-else.sh" \
    "timeout-absent-on-macos cyc9/4-plain-then-guarded.sh" \
    "cpu-count-single-mechanism cyc9/5-shim-mentioned-cpu.sh" \
    "sed-in-place-gnu cyc9/6-shim-mentioned-sed.sh" \
    "cpu-count-single-mechanism cyc9/7-repeat-one-probed.sh" \
    "timeout-absent-on-macos cyc9/8-guarded-then-background.sh" \
    "readlink-f-bsd-absent cyc9/9-background-breadth.sh" \
    "cpu-count-single-mechanism cyc9/10-background-cpu.sh" \
    "sed-in-place-gnu cyc9/11-sed-portable-then-gnu.sh" \
    "sed-in-place-gnu cyc9/12-shim-then-gnu-sed.sh" \
    "cpu-count-single-mechanism cyc9/13-shim-then-plain-nproc.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      ok "C14a: caught $1 in $(basename "$2")"
    else
      bad "C14a: MISSED $1 in $(basename "$2") — a conditioned call is blessing the rest of its line"
    fi
  done
  run_check "$C4C" --no-baseline
  for pair in \
    "timeout-absent-on-macos cyc9clean/1-and-chain.sh" \
    "timeout-absent-on-macos cyc9clean/2-then-single.sh" \
    "timeout-absent-on-macos cyc9clean/3-then-multiline.sh" \
    "cpu-count-single-mechanism cyc9clean/4-shim-called.sh" \
    "timeout-absent-on-macos cyc9clean/5-redirect-and-chain.sh" \
    "timeout-absent-on-macos cyc9clean/6-and-after-redirect.sh" \
    "sed-in-place-gnu cyc9clean/7-sed-portable.sh" \
    "cpu-count-single-mechanism cyc9clean/8-shim-only.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      bad "C14b: FALSE POSITIVE — $1 reded on correctly guarded $(basename "$2")"
    else
      ok "C14b: guarded code NOT flagged ($(basename "$2"))"
    fi
  done

  # ⛔ THE COUNT IS THE MECHANISM, SO IT MUST BE LOAD-BEARING (review cycle-9): the `&&`-arm test
  # alone reads these CLEAN (that WAS the P0). Removing the count comparison must turn the fixture
  # back into a false PASS — if it does not, the count is not what catches it and the next edit can
  # drop it silently.
  # ⛔ THE BARE-`&` CUT IS PINNED BY OPPOSING ARMS, NOT BY A TEXT MUTANT: C14a/8 (background must be
  # CAUGHT) and C14b/5-6 (an `&&` join and a redirection must stay CLEAN) fail in opposite
  # directions — narrowing the class reds C14a/8, widening it without the masking reds C14b/5. A
  # string-surgery mutant here would be brittle (the pattern is an awk regex literal, and escaping it
  # from inside this file is its own quoting exercise), so the two arms carry the load and the
  # mutation section's other entries cover the dispatch/guard polarity.

  MUT9="$TMP/cyc9mut.sh"
  awk '{ if (index($0, "if (toolcalls(c2, tool) != toolcalls(m1, tool)) return 0") > 0) print "# MUT9"; else print }' "$CHECK" >"$MUT9"
  if cmp -s "$CHECK" "$MUT9"; then
    bad "C14c: the count guard was NOT FOUND in the detector — its text moved, so this arm is dead"
  else
    printf '%s\n' cyc9/1-guarded-then-plain.sh >"$TMP/cyc9mut.list"
    bash "$MUT9" --root "$TMP/tree" --targets "$TMP/cyc9mut.list" --no-baseline >"$OUT" 2>"$ERR"
    mrc=$?
    if [ "$mrc" = 0 ]; then
      ok "C14c: deleting the call-COUNT comparison re-opens the false PASS (the count is load-bearing)"
    else
      bad "C14c: the count guard survived its own deletion (rc=$mrc) — something else catches the fixture, so the count may be dead code"
    fi
  fi
fi

# ── C15. THE TWELFTH CYCLE — the last whole-line exemptions, and two constructs that were too narrow
# Cycles 9-11 closed the "one construct exonerates the rest of the line" class for the probe, the sed
# segments and the shims. An audit of every early `return`/`code ~` in the rule functions found the
# remaining ones, each measured CLEAN at the previous head.
C5="$TMP/cyc10"; : >"$C5"
C5C="$TMP/cyc10clean"; : >"$C5C"
mkc5()  { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C5"; }
mkc5c() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C5C"; }

# the BSD counterpart must belong to the SAME command: one guarded chain does not bless the next call
mkc5 cyc10/1-stat-chain-then-gnu.sh '#!/usr/bin/env bash' 'stat -c %Y f || stat -f %m f; stat -c %Y g'
mkc5 cyc10/2-date-chain-then-gnu.sh '#!/usr/bin/env bash' 't=$(date -d @0 +%s || date -r 0 +%s); echo "$(date -d "$t" +%F)"'
# a probe (or an assignment VALUE) masks ITS OWN construct, not every read on the line
mkc5 cyc10/3-probe-then-read.sh '#!/usr/bin/env bash' '[ -r /proc/loadavg ] && read -r load _ < /proc/loadavg'
# the flag letter need not END the cluster, and grep has a long spelling too
mkc5 cyc10/4-grep-cluster-mid.sh '#!/usr/bin/env bash' 'grep -Pq x f'
mkc5 cyc10/5-grep-long.sh '#!/usr/bin/env bash' 'grep --perl-regexp -q x f'
mkc5 cyc10/6-readlink-cluster-mid.sh '#!/usr/bin/env bash' 'readlink -fn -- d'

# and the constructs that must stay clean
mkc5c cyc10clean/1-guarded-chain.sh '#!/usr/bin/env bash' 'stat -c %Y f || stat -f %m f'
mkc5c cyc10clean/2-if-else-chain.sh '#!/usr/bin/env bash' 'if [ -n "$E" ]; then d=$(date -d @0 +%s); else d=$(date -r 0 +%s); fi'
mkc5c cyc10clean/3-probe-only.sh '#!/usr/bin/env bash' '[ -d /proc/self ]'
mkc5c cyc10clean/4-proc-as-value.sh '#!/usr/bin/env bash' 'AGENT_GH_GATE_DIR="/proc/nope/gate" bash "$SHIM" api user'
# an unrelated negated test later on the line must not destroy a correctly-probed call
mkc5c cyc10clean/5-trailing-negation.sh '#!/usr/bin/env bash' 'command -v timeout >/dev/null 2>&1 && timeout 5 sleep 1; if ! [ -d "$d" ]; then mkdir -p "$d"; fi'

# a QUOTED probe PATH is the read — masking must not swallow it
# (the fixture text carries the very shape it asserts, so the line needs the documented escape — the
# detector scans THIS file, and the quoted path would otherwise be a finding on data)
mkc5 cyc10/7-quoted-probe-read.sh '#!/usr/bin/env bash' 'if [ -r "/proc/$pid/cmdline" ]; then tr "\000" " " < "/proc/$pid/cmdline"; fi'  # portability-ok: fixture text for the C15a quoted-probe arm

run_check "$C5" --no-baseline
if [ "$?" = 2 ]; then
  bad "C15: the cycle-12 fixture tree was REFUSED (rc=2) — an empty scan proves nothing"
else
  for pair in \
    "stat-c-gnu cyc10/1-stat-chain-then-gnu.sh" \
    "date-d-gnu cyc10/2-date-chain-then-gnu.sh" \
    "procfs-macos-absent cyc10/3-probe-then-read.sh" \
    "grep-P-bsd-absent cyc10/4-grep-cluster-mid.sh" \
    "grep-P-bsd-absent cyc10/5-grep-long.sh" \
    "readlink-f-bsd-absent cyc10/6-readlink-cluster-mid.sh" \
    "procfs-macos-absent cyc10/7-quoted-probe-read.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      ok "C15a: caught $1 in $(basename "$2")"
    else
      bad "C15a: MISSED $1 in $(basename "$2") — a whole-line exemption is exonerating a real call"
    fi
  done
  run_check "$C5C" --no-baseline
  for pair in \
    "stat-c-gnu cyc10clean/1-guarded-chain.sh" \
    "date-d-gnu cyc10clean/2-if-else-chain.sh" \
    "procfs-macos-absent cyc10clean/3-probe-only.sh" \
    "procfs-macos-absent cyc10clean/4-proc-as-value.sh" \
    "timeout-absent-on-macos cyc10clean/5-trailing-negation.sh"
  do
    set -- $pair
    if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
      bad "C15b: FALSE POSITIVE — $1 reded on correct $(basename "$2")"
    else
      ok "C15b: guarded/data code NOT flagged ($(basename "$2"))"
    fi
  done
fi

# ── C16. THE THIRTEENTH CYCLE — the unit mask must stay a SEPARATOR, and a flag must be the TOOL flag ─
# Cycle 12 masked `&&`/arm-opening `;` with a control character so the unit stayed whole, but that
# character is NOT in SEP, so `cp()` could not see a command after it: every trap joined by `&&` or
# sitting in an `if/then`/loop arm went CLEAN, and a live trap appended to an already-counted row left
# the ratchet green. `||` keeps both properties: a separator to `cp()`, not split by cmdunits().
C6="$TMP/cyc11"; : >"$C6"
C6C="$TMP/cyc11clean"; : >"$C6C"
mkc6()  { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C6"; }
mkc6c() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C6C"; }

mkc6 cyc11/1-and-joined-stat.sh '#!/usr/bin/env bash' 'true && stat -c %Y f'
mkc6 cyc11/2-then-arm-date.sh '#!/usr/bin/env bash' 'if [ -d x ]; then date -d @0 +%s; fi'
mkc6 cyc11/3-else-arm-stat.sh '#!/usr/bin/env bash' 'if [ -d x ]; then :; else stat -c %Y f; fi'
mkc6 cyc11/4-do-arm-stat.sh '#!/usr/bin/env bash' 'while [ -d x ]; do stat -c %Y f; done'
mkc6c cyc11clean/1-or-chain.sh '#!/usr/bin/env bash' 'stat -c %Y f || stat -f %m f'
mkc6c cyc11clean/2-ifelse-uname.sh '#!/usr/bin/env bash' 'if [ "$(uname)" = Darwin ]; then stat -f %m f; else stat -c %Y f; fi'
mkc6c cyc11clean/3-probe-then-chain.sh '#!/usr/bin/env bash' 'if stat -f %m f >/dev/null 2>&1; then stat -f %m f; else stat -c %Y f; fi'
# `-P` here is xargs parallelism, present on both hosts — not a grep flag
mkc6c cyc11clean/4-xargs-parallel.sh '#!/usr/bin/env bash' 'xargs -P 4 grep foo'

run_check "$C6" --no-baseline
for pair in   "stat-c-gnu cyc11/1-and-joined-stat.sh"   "date-d-gnu cyc11/2-then-arm-date.sh"   "stat-c-gnu cyc11/3-else-arm-stat.sh"   "stat-c-gnu cyc11/4-do-arm-stat.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    ok "C16a: caught $1 in $(basename "$2")"
  else
    bad "C16a: MISSED $1 in $(basename "$2") — the unit mask swallowed command position"
  fi
done
run_check "$C6C" --no-baseline
for pair in   "stat-c-gnu cyc11clean/1-or-chain.sh"   "stat-c-gnu cyc11clean/2-ifelse-uname.sh"   "stat-c-gnu cyc11clean/3-probe-then-chain.sh"   "grep-P-bsd-absent cyc11clean/4-xargs-parallel.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    bad "C16b: FALSE POSITIVE — $1 reded on correct $(basename "$2")"
  else
    ok "C16b: guarded/wrapped code NOT flagged ($(basename "$2"))"
  fi
done

# the `--in-place` long form must not stop the SEGMENT loop: two traps on one line, one of each spelling
printf '%s\n' 'sed --in-place s/a/b/ f; sed -i s/c/d/ g' >"$TMP/tree/cyc11/5-long-then-short.sh"
printf '%s\n' cyc11/5-long-then-short.sh >"$TMP/ls.list"
run_check "$TMP/ls.list" --no-baseline
n_ls="$(awk -v r="sed-in-place-gnu" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) c++ } } END { print c + 0 }' "$OUT")"
[ "$n_ls" = 2 ] && ok "C16c: long-form then short-form sed on ONE line counts 2" \
  || bad "C16c: long-form then short-form counted $n_ls, not 2 — the first hit skipped the next segment"

# ── C17. THE FOURTEENTH CYCLE — counts are part of the finding, and a counterpart is a FALLBACK ────
# (a) every rule but `sed` reported at most ONE finding per line, so a second live trap appended to an
#     already-counted line left the ratchet green; (b) `&&` was treated as a fallback, so a BSD arm
#     that never runs on macOS blessed the GNU call before it; (c) a one-line `case` platform branch
#     and a `grep -q etimes` argument reded on portable code.
C7="$TMP/cyc12"; : >"$C7"
C7C="$TMP/cyc12clean"; : >"$C7C"
mkc7()  { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C7"; }
mkc7c() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C7C"; }

# `&&` is a SEQUENCE: on macOS the GNU call fails, so the BSD arm never runs and the value is empty
mkc7 cyc12/1-and-is-not-fallback.sh '#!/usr/bin/env bash' 'mt=$(stat -c %Y f && stat -f %m f)'
mkc7 cyc12/2-ps-etimes.sh '#!/usr/bin/env bash' 'ps -eo pid=,etimes= -p 1'
# two instances on ONE line
mkc7 cyc12/3-two-stat-one-line.sh '#!/usr/bin/env bash' 'mt="$(stat -c %Y f)"; mt2="$(stat -c %Y g)"'
mkc7 cyc12/4-two-timeout-one-line.sh '#!/usr/bin/env bash' 'timeout 5 a; timeout 5 b'

# the portable forms
mkc7c cyc12clean/1-case-platform.sh '#!/usr/bin/env bash' 'case "$(uname)" in Darwin) stat -f %m f ;; *) stat -c %Y f ;; esac'
mkc7c cyc12clean/2-probe-then-branch.sh '#!/usr/bin/env bash' 'mode_of() { if stat -c "%a" "$1" >/dev/null 2>&1; then stat -c "%a" "$1"; else stat -f "%Lp" "$1"; fi; }'
mkc7c cyc12clean/3-etimes-as-argument.sh '#!/usr/bin/env bash' 'ps -eo pid= -p 1 | grep -q etimes'
mkc7c cyc12clean/4-or-chain.sh '#!/usr/bin/env bash' 'stat -c %Y f || stat -f %m f'

run_check "$C7" --no-baseline
for pair in   "stat-c-gnu cyc12/1-and-is-not-fallback.sh"   "ps-etimes-macos-absent cyc12/2-ps-etimes.sh"   "stat-c-gnu cyc12/3-two-stat-one-line.sh"   "timeout-absent-on-macos cyc12/4-two-timeout-one-line.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    ok "C17a: caught $1 in $(basename "$2")"
  else
    bad "C17a: MISSED $1 in $(basename "$2")"
  fi
done
run_check "$C7C" --no-baseline
for pair in   "stat-c-gnu cyc12clean/1-case-platform.sh"   "stat-c-gnu cyc12clean/2-probe-then-branch.sh"   "ps-etimes-macos-absent cyc12clean/3-etimes-as-argument.sh"   "stat-c-gnu cyc12clean/4-or-chain.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    bad "C17b: FALSE POSITIVE — $1 reded on portable $(basename "$2")"
  else
    ok "C17b: portable platform branch NOT flagged ($(basename "$2"))"
  fi
done
# the COUNT is what the ratchet compares: two instances must emit two findings, for a rule too
printf '%s\n' cyc12/3-two-stat-one-line.sh cyc12/4-two-timeout-one-line.sh >"$TMP/cyc12.list"
run_check "$TMP/cyc12.list" --no-baseline
for pair in "stat-c-gnu cyc12/3-two-stat-one-line.sh" "timeout-absent-on-macos cyc12/4-two-timeout-one-line.sh"; do
  set -- $pair
  n_inst="$(awk -v f="$2" -v r="$1" '{ n = split($0, a, ": "); if (index($0, f ":") == 1 && n >= 2) { split(a[2], b, " "); if (b[1] == r) c++ } } END { print c + 0 }' "$OUT")"
  [ "$n_inst" = 2 ] && ok "C17c: two $1 instances on one line are counted twice" \
    || bad "C17c: two $1 instances on one line counted $n_inst, not 2 — the ratchet cannot see the second"
done

# ── C18. THE FIFTEENTH CYCLE — a unit can carry several traps, and a sequence is not a guard ──────
C8="$TMP/cyc13"; : >"$C8"
C8C="$TMP/cyc13clean"; : >"$C8C"
mkc8()  { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C8"; }
mkc8c() { local f="$1"; shift; mkdir -p "$TMP/tree/$(dirname "$f")"; printf '%s\n' "$@" >"$TMP/tree/$f"; printf '%s\n' "$f" >>"$C8C"; }

mkc8 cyc13/1-two-calls-one-unit-and.sh '#!/usr/bin/env bash' 'mt=$(stat -c %Y "$f" && stat -c %Z "$f")'
mkc8 cyc13/2-two-calls-case-arms.sh '#!/usr/bin/env bash' 'case x in a) stat -c %Y a ;; b) stat -c %Z b ;; esac'
# the BSD counterpart BEFORE the GNU call in a `&&` sequence is not a guard: both arms run on both hosts
mkc8 cyc13/3-counterpart-first-sequence.sh '#!/usr/bin/env bash' 'stat -f %m f && stat -c %Y f'
mkc8c cyc13clean/1-or-chain.sh '#!/usr/bin/env bash' 'stat -c %Y a || stat -f %m b'
mkc8c cyc13clean/2-if-else.sh '#!/usr/bin/env bash' 'if [ -n "$E" ]; then stat -c %Y a; else stat -f %m a; fi'

run_check "$C8" --no-baseline
for pair in \
  "stat-c-gnu cyc13/1-two-calls-one-unit-and.sh" \
  "stat-c-gnu cyc13/2-two-calls-case-arms.sh" \
  "stat-c-gnu cyc13/3-counterpart-first-sequence.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    ok "C18a: caught $1 in $(basename "$2")"
  else
    bad "C18a: MISSED $1 in $(basename "$2")"
  fi
done
# two GNU invocations inside ONE unit must be TWO findings — the ratchet compares the count
for f in cyc13/1-two-calls-one-unit-and.sh cyc13/2-two-calls-case-arms.sh; do
  printf '%s\n' "$f" >"$TMP/cyc13one.list"
  run_check "$TMP/cyc13one.list" --no-baseline
  n_u="$(awk -v r="stat-c-gnu" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) c++ } } END { print c + 0 }' "$OUT")"
  [ "$n_u" = 2 ] && ok "C18b: two GNU calls in one unit of $(basename "$f") count 2" \
    || bad "C18b: two GNU calls in one unit of $(basename "$f") counted $n_u, not 2"
done
run_check "$C8C" --no-baseline
for pair in \
  "stat-c-gnu cyc13clean/1-or-chain.sh" \
  "stat-c-gnu cyc13clean/2-if-else.sh"
do
  set -- $pair
  if awk -v f="$2" -v r="$1" '{ if (index($0, f ":") == 1 && index($0, r " ") > 0) found = 1 } END { exit(found ? 0 : 1) }' "$OUT"; then
    bad "C18c: FALSE POSITIVE — $1 reded on portable $(basename "$2")"
  else
    ok "C18c: portable fallback NOT flagged ($(basename "$2"))"
  fi
done

# two mapfile calls on one line must count twice too
printf '%s\n' 'mapfile a; mapfile b' >"$TMP/tree/cyc13/4-two-mapfile.sh"
printf '%s\n' cyc13/4-two-mapfile.sh >"$TMP/mf.list"
run_check "$TMP/mf.list" --no-baseline
n_mf="$(awk -v r="bash4-mapfile" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) c++ } } END { print c + 0 }' "$OUT")"
[ "$n_mf" = 2 ] && ok "C18d: two mapfile calls on one line are counted twice" \
  || bad "C18d: two mapfile calls on one line counted $n_mf, not 2"

# ⛔ A SECOND LIVE TRAP ON THE SAME LINE IS COUNTED (review cycle-12 P2): the ratchet is keyed on the
# COUNT, so a `return` after the first hit let `sed -i …; sed -i …` report 1 where two lines report 2
# — a fresh trap appended beside an existing one stayed green forever.
printf '%s\n' 'sed -i "s/a/b/" f; sed -i "s/c/d/" g' >"$TMP/tree/cyc10/8-two-sed-one-line.sh"
printf '%s\n' cyc10/8-two-sed-one-line.sh >"$TMP/two.list"
run_check "$TMP/two.list" --no-baseline
n_two="$(awk -v r="sed-in-place-gnu" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) c++ } } END { print c + 0 }' "$OUT")"
[ "$n_two" = 2 ] && ok "C15c: two sed-in-place traps on ONE line are counted twice (the ratchet can see the second)" \
  || bad "C15c: two sed-in-place traps on one line counted $n_two, not 2 — a trap added beside an existing one stays green"

# ⛔ D2. GUARD MUTANTS — the arms the `hit(…)` mutants cannot reach ──────────────────────────────
# Section D deletes a rule's DISPATCH, which makes a finding disappear. A CROSS-LINE GUARD works the
# other way round: it SUPPRESSES a finding, so deleting it makes the output larger and the D-style
# assertion ("the rule string is absent") would read a killed guard as SURVIVED. Each guard below is
# removed from a copy and the CLEAN fixture it protects is re-run: the fixture must go RED.
gmutants() {
  printf '%s\n' \
    'if (mech && cpu_other(cpu_mech(code))) return 0|cyc7clean/1-chain.sh|cpu-count-single-mechanism' \
    'if (n >= 2) return 0|cyc7clean/3-chain-1line.sh|cpu-count-single-mechanism' \
    'if (conditioned(tool, code)|cyc8clean/2-and-timeout.sh|timeout-absent-on-macos'
}
GDIR="$TMP/gmutant.sh"
# run_mutant_path <mutant> <list> — the same wrapper contract run_mutant (section D) uses, for the
# guard mutants, which run a DIFFERENT target list. A bare interpreter call on a mktemp path is the
# script-indirection the checkout guard fails closed on, so it goes through a function here too.
run_mutant_path() {
  bash "$1" --root "$TMP/tree" --targets "$2" --no-baseline >"$OUT" 2>"$ERR"
  return $?
}
gmutants | while IFS='|' read -r gl fixt rule; do
  awk -v pat="$gl" '{ if (index($0, pat) > 0) print "# GMUTANT: " pat; else print }' "$CHECK" >"$GDIR"
  if cmp -s "$CHECK" "$GDIR"; then
    echo "GMUTANT-NOT-APPLIED $gl (pattern did not match a line)"
    continue
  fi
  printf '%s\n' "$fixt" >"$TMP/gmut.list"
  run_mutant_path "$GDIR" "$TMP/gmut.list"; grc=$?
  if [ "$grc" != 1 ]; then
    # ⛔ AN INVALID MUTANT MUST SAY WHY (review cycle-8 P2): "exited 2, not 1" is a symptom with no
    # diagnosis, and every cause (a fixture that moved, a refusal, an awk fatal) needs a different
    # fix. The mutant's own stderr is the only thing that distinguishes them.
    echo "GMUTANT-INVALID $gl (mutant exited $grc, not 1)"
    sed 's/^/  stderr: /' "$ERR" | head -5
    continue
  fi
  if awk -v r="$rule" '{ n = split($0, a, ": "); if (n >= 2) { split(a[2], b, " "); if (b[1] == r) found = 1 } } END { exit(found ? 0 : 1) }' "$OUT"; then
    echo "GMUTANT-KILLED $gl"
  else
    echo "GMUTANT-SURVIVED $gl (deleting the guard left the clean fixture GREEN — the guard is untested)"
  fi
done >"$TMP/gmutants.log" 2>&1
gkilled="$(grep -c '^GMUTANT-KILLED' "$TMP/gmutants.log")"
gsurvived="$(grep -c '^GMUTANT-SURVIVED' "$TMP/gmutants.log")"
ginvalid="$(grep -cE '^GMUTANT-(INVALID|NOT-APPLIED)' "$TMP/gmutants.log")"
[ "$VERBOSE" = 1 ] && cat "$TMP/gmutants.log"
gn="$(gmutants | wc -l | tr -d ' ')"
if [ "$gkilled" = "$gn" ] && [ "$gsurvived" = 0 ]; then
  ok "D2: guard mutants $gkilled/$gn killed (a deleted cross-line guard reds its clean fixture)"
else
  bad "D2: guard mutants $gkilled/$gn killed, $gsurvived survived, $ginvalid invalid — a dead guard would pass unnoticed"
fi

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
printf '%s\n' '#!/usr/bin/env bash' 'timeout 5 true' >"$TMP/tree/ratchet/x.sh"
printf 'ratchet/x.sh\n' >>"$E"
eb="$TMP/base.tsv"
printf '# fake baseline\nratchet/x.sh\ttimeout-absent-on-macos\t1\t#2046 grandfathered for this arm\n' >"$eb"
run_check "$E" --baseline "$eb"
[ "$?" = 0 ] && ok "E1: a baselined finding does not red (ratchet holds)" || bad "E1: a baselined finding reddened"

printf 'ratchet/x.sh\nratchet/x.sh\n' >/dev/null   # (a count rise needs a second finding in the SAME file)
# ⛔ TWO `timeout` LINES, NOT TWO `nproc` LINES: the CPU rule has a cross-line CHAIN control (a
# different mechanism within the lookback means the author is choosing), so two mechanisms on
# adjacent lines are correctly CLEAN — a rise test built on them measured the chain control, not the
# ratchet. `timeout` has no such control, so its count rises 1 → 2 as the arm intends.
printf '%s\n' '#!/usr/bin/env bash' 'timeout 5 true' 'timeout 6 true' >"$TMP/tree/ratchet/x.sh"
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


# ── E8..E10: `--emit-baseline` IS A DOCUMENTED REGENERATION PATH, SO IT IS A GATE SURFACE ────────
# ⛔ THE DEFECT THESE PIN (review cycle-18 P1). The rule table reached awk as `-v rules="$RULES"` with
# LITERAL NEWLINES in it; one-true-awk — macOS, the host this class exists for — refuses that, the
# pipeline status was never checked, and `--emit-baseline` therefore printed 14 header lines, ZERO
# rows and `exit 0`. The maintainer's regression path minted a SILENTLY EMPTY baseline, and no arm
# touched the emit path at all (`grep -n emit-baseline` had no hits in this file). Three arms: the
# happy path is complete, and BOTH failure modes of a choked awk refuse instead of printing nothing.
mkdir -p "$TMP/tree/emit"
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' >"$TMP/tree/emit/1-cpu.sh"
printf 'emit/1-cpu.sh\n' >"$TMP/emit-targets"
"$CHECK" --root "$TMP/tree" --targets "$TMP/emit-targets" --emit-baseline >"$TMP/emit.tsv" 2>"$TMP/emit.err"; erc=$?
rows="$(grep -v '^#' "$TMP/emit.tsv" | grep -c . || true)"
cols="$(grep -v '^#' "$TMP/emit.tsv" | awk -F'\t' 'NF>=3 && $4 ~ /[^ \t]/' | grep -c . || true)"
if [ "$erc" = 0 ] && [ "$rows" = 1 ] && [ "$cols" = 1 ]; then
  ok "E8: --emit-baseline emits one row per finding, with the REQUIRED justification column filled"
else
  bad "E8: --emit-baseline emitted rows=$rows justified=$cols rc=$erc (expected 1/1/0) — an empty or short emit is a false PASS"
fi
# ⛔ A FAITHFUL ONE-TRUE-AWK MODEL, AND A SEPARATE STATUS-BARRIER ARM (review cycle-18b P2). The first
# version of this stub refused ANY `rules=` argument, so it passed through whichever barrier was left
# standing — measured: with the flattening reverted (`rules_flat="$RULES"`), the arm stayed GREEN, i.e.
# the transport fix was pinned by nothing. Two arms now: E9 refuses only a value carrying a literal
# newline (what one-true-awk actually does), and E11 is a stub that PRINTS a row and then FAILS, which
# only the status check can catch.
mkdir -p "$TMP/awkrefuse"
printf '#!/bin/sh\nfor a in "$@"; do\n  case "$a" in\n    rules=*) v="${a#rules=}"; n=$(printf %%s "$v" | wc -l | tr -d " ");\n             if [ "$n" != 0 ]; then echo "awk: newline in string" >&2; exit 2; fi;;\n  esac\ndone\nexec %s "$@"\n' "$(command -v awk)" >"$TMP/awkrefuse/awk"
chmod +x "$TMP/awkrefuse/awk"
PATH="$TMP/awkrefuse:$PATH" "$CHECK" --root "$TMP/tree" --targets "$TMP/emit-targets" --emit-baseline >"$TMP/emit2.tsv" 2>"$TMP/emit2.err"; erc2=$?
rows2="$(grep -v '^#' "$TMP/emit2.tsv" | grep -c . || true)"
if [ "$erc2" = 0 ] && [ "$rows2" = 1 ]; then
  ok "E9: the table reaches awk with NO literal newline in the -v value — a faithful one-true-awk model (which refuses exactly that) emits the row"
else
  bad "E9: the faithful one-true-awk model rejected the table (rc=$erc2, rows=$rows2) — the flattening is not in effect"
fi
mkdir -p "$TMP/awkfail"
printf '#!/bin/sh\nfor a in "$@"; do\n  case "$a" in\n    rules=*) printf "fake/row.sh\\ttimeout-absent-on-macos\\t1\\tplaceholder\\n"; echo "awk: device error" >&2; exit 2;;\n  esac\ndone\nexec %s "$@"\n' "$(command -v awk)" >"$TMP/awkfail/awk"
chmod +x "$TMP/awkfail/awk"
PATH="$TMP/awkfail:$PATH" "$CHECK" --root "$TMP/tree" --targets "$TMP/emit-targets" --emit-baseline >"$TMP/emit4.tsv" 2>"$TMP/emit4.err"; erc4=$?
if [ "$erc4" = 2 ] && ! grep -q '^fake/row.sh' "$TMP/emit4.tsv"; then
  ok "E11: an awk that PRINTS then FAILS is refused (rc=2, no rows) — the status barrier, which the row-count reconciliation cannot see"
else
  bad "E11: an awk that printed a row and then failed produced rc=$erc4 with $(grep -c '^fake/row.sh' "$TMP/emit4.tsv") row(s)"
fi

# ⛔ THE TABLE ITSELF IS AN INPUT WITH A REQUIRED COLUMN (review cycle-18b P2): a rule field carrying the
# transport separator or a TAB silently truncated the justification (rc=0, row count still reconciled),
# and an EMPTY replacement degraded to the placeholder. Both are refusals now, and both arms mutate a
# COPY of the detector — the table is the file’s own data, so this is the only way to exercise it.
tdir="$TMP/tbl"; mkdir -p "$tdir"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "cpu-count-single-mechanism" { $3 = "" } { print }' "$CHECK" >"$tdir/bad-empty.sh"
bash "$tdir/bad-empty.sh" --list-rules >"$TMP/e12.out" 2>"$TMP/e12.err"; e12=$?
if [ "$e12" = 2 ] && grep -q 'MALFORMED' "$TMP/e12.err"; then
  ok "E12: a rule row with an EMPTY replacement REFUSES the run (exit 2) instead of degrading to a placeholder"
else
  bad "E12: an empty replacement was accepted (rc=$e12, out=$(head -1 "$TMP/e12.out"))"
fi
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "cpu-count-single-mechanism" { $3 = $3 sprintf("%c", 28) "tail" } { print }' "$CHECK" >"$tdir/bad-sep.sh"
bash "$tdir/bad-sep.sh" --list-rules >"$TMP/e13.out" 2>"$TMP/e13.err"; e13=$?
if [ "$e13" = 2 ] && grep -q 'transport separator' "$TMP/e13.err"; then
  ok "E13: a rule field carrying the \034 transport separator REFUSES the run (exit 2) — a truncated justification is not shipped"
else
  bad "E13: a rule field carrying the transport separator was accepted (rc=$e13)"
fi

# ⛔ E14 — A FAILED COUNT IS NOT A ZERO COUNT (review cycle-18b P2): `grep -c … || true` conflated
# rc=1 (no match → prints 0) with rc>=2 (grep FAILED → prints nothing), and the emptiness fallback
# turned a failed count into `total=0`, i.e. `✅ no cross-platform traps` over a non-empty finding list.
# Measured before the fix with a grep stub exiting 2: 126 findings printed, exit 0.
mkdir -p "$TMP/badgrep"
printf '#!/bin/sh\nexit 2\n' >"$TMP/badgrep/grep"
chmod +x "$TMP/badgrep/grep"
printf 'emit/1-cpu.sh\n' >"$TMP/one-target"
PATH="$TMP/badgrep:$PATH" "$CHECK" --root "$TMP/tree" --targets "$TMP/one-target" --no-baseline >"$TMP/e14.out" 2>"$TMP/e14.err"; e14=$?
if [ "$e14" = 2 ] && grep -q 'finding count FAILED' "$TMP/e14.err"; then
  ok "E14: a FAILED finding count REFUSES (exit 2) — a broken count can no longer read as zero findings"
else
  bad "E14: a failed finding count produced rc=$e14 (expected 2) — the count barrier is not in effect"
fi
# and the quieter half: an awk that exits 0 having printed nothing must ALSO refuse, because the row
# COUNT is reconciled against the live finding pairs. This is the barrier a status check alone misses.
mkdir -p "$TMP/awkquiet"
# ⛔ THE STUB DRAINS STDIN BEFORE EXITING (measured): exiting with the pipe still full makes `printf`
# die of SIGPIPE, and `pipefail` then hands us a 141 — which the awk-status barrier catches, so the
# arm would pass through the WRONG branch and only by timing. `cat >/dev/null` makes the reconciliation
# the only barrier left standing, which is what this arm is for.
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in rules=*) cat >/dev/null; exit 0;; esac; done\nexec %s "$@"\n' "$(command -v awk)" >"$TMP/awkquiet/awk"
chmod +x "$TMP/awkquiet/awk"
PATH="$TMP/awkquiet:$PATH" "$CHECK" --root "$TMP/tree" --targets "$TMP/emit-targets" --emit-baseline >"$TMP/emit3.tsv" 2>"$TMP/emit3.err"; erc3=$?
if [ "$erc3" = 2 ] && grep -q 'INCOMPLETE baseline' "$TMP/emit3.err"; then
  ok "E10: an awk that exits 0 with NO rows is caught by the count reconciliation (rc=2) — a status check alone would have passed it"
else
  bad "E10: a silent zero-row emit was accepted (rc=$erc3) — the reconciliation is not doing its job"
fi

# ── F. SELF-CHECK: the detector obeys its own rules, and the shipped baseline is valid ──────────
# ⛔ THE SUITE IS IN ITS OWN SELF-SCAN (review finding 14). The first version scanned only the detector,
# so the SUITE — the file that is supposed to police BSD safety — was itself exempt, and a BSD-absent
# `grep -P` sat in it undetected. Scanning both makes the class self-policing.
SELF="$TMP/self"; printf 'scripts/check-portability-traps.sh\nscripts/check-portability-traps.test.sh\n' >"$SELF"
( cd "$HERE/.." && bash "$CHECK" --root "$(cd "$HERE/.." && pwd)" --targets "$SELF" --no-baseline >"$OUT" 2>"$ERR" )
if [ "$?" = 0 ]; then ok "F1: the detector is CLEAN under its own 19 rules (no trap in its own source) — bash-3.2 PARSABILITY is a SEPARATE arm, F9 (F1 was the only arm and it says so: a keyword list is not a parse)"
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

# ⛔ NO PIPELINE INTO `grep -q` — THE SIGPIPE FALSE-NEGATIVE (#841/#861). Under `pipefail` a `grep -q`
# that finds its match exits early, the writer takes SIGPIPE, and the PIPELINE reports failure — so a
# PRESENT verdict line read as "not found". Here that would be a guard asserting a guard. A here-string
# has no writer process to break, which is why this site and the three in C8/C11 use one.
grep -q 'no NEW cross-platform traps' <<<"$real_out"
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
  # ⛔ NO COMMAND SUBSTITUTION INSIDE THIS MESSAGE (measured 2026-10-31): the local checkout guard
  # fails CLOSED on a script whose arguments it cannot statically resolve, and a `$( … "$var" | … )`
  # inside a quoted string made it refuse to run this whole suite (#709, localized by prefix
  # bisection). The count is computed on its own line, which the guard can read.
  globn="$(printf '%s\n' "$globs" | grep -c .)"
  [ -n "$globs" ] && ok "F7: SUITE_GLOBS was readable from the runner ($globn globs)" \
    || bad "F7: SUITE_GLOBS is unreadable — the wiring arm above proved nothing"
else
  unproven "run-bash-shards.sh absent — the CI-wiring arm cannot run here"
fi

# ⛔ THE REFUSAL PATHS OF THE RATCHET ARE PART OF THE RATCHET (review cycle-8 P2): a MALFORMED row
# or a DUPLICATE key must refuse with exit 2 — last-wins would silently compare against ONE of two
# counts, which is the failure the code comment says was measured. Neither path had an arm.
printf 'x.sh\ttimeout-absent-on-macos\t1\tjust1\nx.sh\ttimeout-absent-on-macos\t2\tjust2\n' >"$TMP/dup.tsv"
printf 'x.sh\ttimeout-absent-on-macos\t1\n' >"$TMP/mal.tsv"
mkdir -p "$TMP/tree/rt"
printf '#!/usr/bin/env bash\ntimeout 5 true\n' >"$TMP/tree/rt/x.sh"
printf 'rt/x.sh\n' >"$TMP/rt.list"
run_check "$TMP/rt.list" --baseline "$TMP/dup.tsv"; rc=$?
[ "$rc" = 2 ] && ok "E5: a DUPLICATE baseline key REFUSES (exit 2) — no last-wins comparison" \
  || bad "E5: a duplicate baseline key did not refuse (rc=$rc) — the ratchet compared against one of two counts"
run_check "$TMP/rt.list" --baseline "$TMP/mal.tsv"; rc=$?
[ "$rc" = 2 ] && ok "E6: a MALFORMED baseline row REFUSES (exit 2) — a 3-column row is not a verdict" \
  || bad "E6: a malformed baseline row did not refuse (rc=$rc)"

# ── REPORT ──────────────────────────────────────────────────────────────────────────────────────
printf '\n────────────────────────────────────────\n'
# ── F8. `--help` IS THE FLAG DOCUMENTATION, SO IT MUST BE COMPLETE AND ACCURATE ─────────────────
# A pinned line range cut the header off mid-sentence and never printed USAGE or EXIT (review
# cycle-3 P2), and `--baseline FILE` was implemented but undocumented. Both are checked as text, so
# the help output cannot drift from the parser again without an arm going red.
det_run() { bash "$CHECK" "$@"; }
help_out="$(det_run --help 2>/dev/null)"
grep -q 'USAGE' <<<"$help_out" && grep -q 'EXIT:' <<<"$help_out" \
  && ok "F8a: --help prints the whole header (USAGE and EXIT are present, not truncated by a pinned range)" \
  || bad "F8a: --help output is truncated — it is missing USAGE and/or EXIT"
# ⛔ THE FLAG LIST IS DERIVED FROM THE PARSER (review cycle-4 P2): asserting one hard-coded flag let
# `--help` itself go undocumented. Every `--flag)` arm of the argument parser must appear in the text.
# ⛔ DERIVE THE FLAG TOKENS, NOT THE `)`-TERMINATED ARMS (review cycle-5 P1): `--help|-h)` does not
# end in `)` until the `|` is crossed, so the arm list silently omitted `--help` — the very flag the
# previous cycle added to the docs, which is exactly the drift this arm exists to catch.
# ⛔ SHORT ALIASES ARE FLAGS TOO (review cycle-6 P2): `--help|-h)` accepts `-h`, and a derivation
# that only greps `--[a-z-]*` cannot see it — so the arm claimed completeness while the short alias
# was undocumented. Both spellings are derived now, and both must appear in --help.
# ⛔ TAKE THE ARM TOKENS ONLY (review cycle-6 P2): grepping the whole `while` block for `-[A-Za-z]`
# also matched the loop CONDITION's `-gt`, so the arm demanded a documented `-g`. The flags are the
# `|`-split tokens at the head of each arm line, which is exactly what the parser accepts.
# ⛔ `[ \t]` IS NOT A WHITESPACE CLASS IN BSD `sed` (found by running this suite on macOS, cycle-17):
# BSD sed has no `\t` escape, so inside a bracket expression it is the two characters `\` and `t` —
# which made `s/[ \t]*$//` strip the trailing `t` off `--root` (derived as `--roo`) and reddened F8b on
# the one host this suite had never been run on. `[[:space:]]` is the portable spelling and is what the
# detector would flag a bare `[ \t]` in a `sed` script for.
flags="$(sed -n '/^while \[ \$# -gt 0 \]/,/^done/p' "$CHECK" \
  | sed -n 's/^[[:space:]]*\([^)]*\)).*/\1/p' | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -E -- '^-' | sort -u)"
# ⛔ A FLAG IS A TOKEN, NOT A SUBSTRING (review cycle-7 P2): `grep -q -- "-h"` matches inside
# `--help`, so dropping the documented `-h` alias left this arm green. The matcher is exercised
# against a help text with the alias REMOVED below, so it cannot silently degrade to a substring test.
# ⛔ NO PIPELINE INTO `grep -q` — IT IS FLAKY UNDER `pipefail` (review cycle-7, measured): `grep -q`
# exits at the first match, the writer gets SIGPIPE, and `pipefail` then reports the PIPELINE as
# failed — so this arm reported a random flag "missing" on some runs and not others. A here-string
# has no writer process to break.
flag_listed() { grep -Eq -- "(^|[ ,|(])$2([ ,|)]|\$)" <<<"$1"; }
missing=""
for fl in $flags; do
  flag_listed "$help_out" "$fl" || missing="$missing $fl"
done
# negative control: the matcher MUST report `-h` missing from a help text that does not list it
if flag_listed "$(printf '%s\n' "$help_out" | sed 's/--help, -h /--help      /')" "-h"; then
  bad "F8b: the flag matcher cannot fail — it reads -h inside --help, so it proves nothing"
elif [ -n "$flags" ] && ! grep -q -- '--help' <<<"$help_out"; then
  bad "F8b: --help does not document --help"
else
  ok "F8b-negative: the flag matcher distinguishes -h from --help (it reports the alias missing when removed)"
fi
[ -n "$flags" ] || bad "F8b: could not read the parser flag list from $CHECK"
[ -z "$missing" ] && ok "F8b: --help documents every flag the parser accepts ($(printf '%s' "$flags" | wc -w | tr -d ' ') flags)" \
  || bad "F8b: --help omits flag(s) the parser accepts:$missing"

# ── F9. THIS FILE MUST PARSE ON THE HOST THE CLASS EXISTS FOR (review cycle-17 P1) ─────────────
# ⛔ THE DEFECT THIS PINS. The rule table was built as a heredoc INSIDE `$( … )`. bash 3.2.57 — macOS
# `/bin/bash`, and the host this whole detector exists for — does not treat such a body as data: it
# PARSES it as code, so one apostrophe in a table line desynchronised the parse and every mode died at
# parse time (rc=2): `--help`, `--list-rules` and the scan. bash 5 parses it, and CI is
# ubuntu-latest-only, so the gate was inert exactly where the traps live and green where they do not —
# the same class as #2828/#2930 (a test suite that did not parse under 3.2 refused every install) and
# #2248 (a heredoc-in-`$( … )` body whose WORDS ran as commands). F1 says of itself "bash-3.2
# PARSABILITY is not what this arm measures": F9 is the arm that does.
#
# Three arms, because no single one is available everywhere:
#   F9a  the SHAPE is pinned TEXTUALLY — this is the half that fires on bash-5 CI, where a real 3.2
#        cannot speak. It is a textual pin and says so; #2976 chose the same trade for the same reason.
#   F9b  NEGATIVE CONTROL — the matcher must REPORT the shape on a fixture that carries it, so F9a
#        cannot pass by matching nothing (the class of arm this suite refuses to ship).
#   F9c  the detector PARSES under this host's own bash, and under a REAL bash 3.x when one exists —
#        parse AND a live `--list-rules` run, so an inert-on-3.2 gate cannot read as green. When the
#        host has no 3.x the arm prints `UNPROVEN-ON`, never a pass.
# ⛔ THE SHAPE IS MATCHED WITHOUT MATCHING THIS FILE'S OWN PROSE: only non-comment lines of the
# detector are read, so the comment block above (which names the shape) cannot red the arm.
# ⛔ AND THE MATCH IS STATE-AWARE, NOT SAME-LINE (review cycle-18 P2). The first version anchored on
# `$(... <<` WITHIN one line, so the equally fatal multi-line spelling
#     X="$(
#     cat <<\047EOF\047
#     it\047s a quote
#     EOF
#     )"
# scored 0 hits while `/bin/bash -n` on 3.2.57 refuses it (rc=2) — and because F9c32 is
# `UNPROVEN-ON` wherever no bash 3.x exists (CI is ubuntu-only), this pin is the ONLY 3.2 coverage
# there: the detector could go green in CI while every mode died at parse time on the host the trap
# class exists for. The scanner therefore tracks SUBSTITUTION DEPTH across lines (`$( … )` and
# backticks), skips heredoc BODIES at top level (a body is data, and its `$(` must not open a depth),
# and reports any heredoc opener seen while depth > 0.
subst_heredoc_pin() {
  # A CHAR-LEVEL CONTEXT-STACK scan across lines, NOT a per-line grep. Two measurements forced it:
  #   · a per-line quote model desynchronises on the detector own 1200-line SINGLE-QUOTED awk
  #     program, so a phantom `$(` reads every later `<<` as "inside a substitution" (5 false hits);
  #   · the same-line pattern missed the MULTI-LINE spelling entirely, which is an equal parse
  #     failure on bash 3.2.57 and therefore an equal hole in the only 3.2 coverage bash-5 CI has.
  # So this mirrors the model the detector itself uses: push on `$(`, `$((' (arithmetic), a double
  # quote, a single/ANSI-C quote and a backtick; pop on the matching close. A heredoc opener seen
  # while the stack sits on a COMMAND SUBSTITUTION is the defect. Two exclusions keep it honest:
  # `$(( … ))` is ARITHMETIC (a `<<` there is a left shift, not a heredoc) and a top-level heredoc
  # BODY is data, so a `$(` inside a body cannot open a depth.
  awk '
    BEGIN { SQ = sprintf("%c", 39); hd = ""; hdstrip = 0; ST = ""; cased = 0 }
    function s_top() { return (length(ST) > 0) ? substr(ST, length(ST), 1) : "" }
    
    function s_push(ch) { ST = ST ch }
    function s_pop() { ST = substr(ST, 1, length(ST) - 1) }
    {
      line = $0
      if (hd != "") { t = line; if (hdstrip) sub(/^\t+/, "", t); if (t == hd) hd = ""; next }
      n = length(line); i = 1; prev = " "
      while (i <= n) {
        c = substr(line, i, 1); nx = substr(line, i + 1, 1); t = s_top()
        if (t == "S") { if (c == SQ) s_pop(); prev = c; i++; continue }
        if (t == "A") { if (c == "\\") { i += 2; continue } if (c == SQ) s_pop(); prev = c; i++; continue }
        if (t == "D") {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { s_pop(); prev = c; i++; continue }
          if (c == "$" && nx == "(") { s_push("C"); i += 2; continue }
          if (c == "`") { s_push("K"); prev = c; i++; continue }
          prev = c; i++; continue
        }
        if (t == "K") { if (c == "\\") { i += 2; continue } if (c == "`") s_pop(); prev = c; i++; continue }
        if (t == "C") {
          if (c == "\\") { i += 2; continue }
          # ⛔ A `case` ARM INSIDE A SUBSTITUTION ENDS IN `)`, AND THAT `)` DOES NOT CLOSE THE
          # SUBSTITUTION (review cycle-2 of this pin, measured): without this, `RULES=$(case … in
          # all) cat <<\047EOF\047 … esac)` popped the substitution at the arm label, the opener was
          # then read as a TOP-LEVEL heredoc (body skipped as data, no hit), and bash 3.2.57 still
          # refused the file (`syntax error near unexpected token \047;;\047`). The pin exists to be
          # the only 3.2 coverage on bash-5 CI, so a shape it cannot see is a shape the gate cannot
          # see there either.
          if (c ~ /[A-Za-z]/ && (i == 1 || substr(line, i - 1, 1) ~ /[^A-Za-z0-9_]/)) {
            rest2 = substr(line, i)
            if (rest2 ~ /^case([ \t;)(|&]|$)/) { cased++; i += 4; prev = "e"; continue }
            if (rest2 ~ /^esac([ \t;)(|&]|$)/) { if (cased > 0) cased--; i += 4; prev = "c"; continue }
          }
          if (c == ")" && AR[length(ST)] == 0 && cased == 0) { s_pop(); prev = c; i++; continue }
          if (c == ")" && AR[length(ST)] == 1) { s_pop(); if (nd > 0) nd--; prev = c; i++; continue }
          if (c == SQ) {
            if (prev == "$") s_push("A"); else s_push("S")
            prev = c; i++; continue
          }
          if (c == "\"") { s_push("D"); prev = c; i++; continue }
          if (c == "`") { s_push("K"); prev = c; i++; continue }
          if (c == "$" && nx == "(") {
            if (substr(line, i + 2, 1) == "(") { s_push("C"); AR[length(ST)] = 1; nd++; i += 3; continue }
            s_push("C"); i += 2; continue
          }
          if (c == "<" && nx == "<" && substr(line, i + 2, 1) != "=" && AR[length(ST)] == 0) { print FNR; i += 2; prev = c; continue }
          prev = c; i++; continue
        }
        # top level
        if (c == "\\") { i += 2; prev = c; continue }
        if (c == "#" && (i == 1 || prev ~ /[ \t;&|(){}]/)) break
        if (c == SQ) { if (prev == "$") s_push("A"); else s_push("S"); prev = c; i++; continue }
        if (c == "\"") { s_push("D"); prev = c; i++; continue }
        if (c == "$" && nx == "(") { s_push("C"); AR[length(ST)] = (substr(line, i + 2, 1) == "(") ? 1 : 0; i += 2; continue }
        if (c == "`") { s_push("K"); prev = c; i++; continue }
        if (c == "<" && nx == "<" && substr(line, i + 2, 1) != "=") {
          rest = substr(line, i + 2)
          if (substr(rest, 1, 1) == "-") { rest = substr(rest, 2); hdstrip = 1 } else hdstrip = 0
          sub(/^[ \t]*/, "", rest)
          q2 = substr(rest, 1, 1)
          if (q2 == SQ || q2 == "\"") { rest = substr(rest, 2); j = index(rest, q2); if (j > 0) hd = substr(rest, 1, j - 1) }
          else { hd = rest; sub(/[^A-Za-z0-9_].*$/, "", hd) }
          if (hd != "") { i = n + 1; continue }
          i += 2; prev = c; continue
        }
        prev = c; i++
      }
    }' "$1" 2>/dev/null
}
subst_heredoc_pin "$CHECK" >"$TMP/f9.hits" 2>/dev/null
# ⛔ THE VERDICT IS "ANY HIT", NOT THE TOOL RC (review cycle-18 P2): the matcher is now awk, which
# exits 0 whether or not it printed anything — an `if subst_heredoc_pin …` test would have been
# ALWAYS TRUE, i.e. an arm that reds on the detector no matter what it contains (and, with the
# message's `head -1` empty, no evidence at all). `-s` is the only test that matches the question.
if [ -s "$TMP/f9.hits" ]; then
  bad "F9a: the detector carries a heredoc INSIDE a command substitution — bash 3.2 parses that body as CODE, so every mode dies at parse time ($(head -1 "$TMP/f9.hits"))"
else
  ok "F9a: no heredoc inside a \$( … ) in the detector (the shape that made every mode rc=2 on bash 3.2.57)"
fi
# the negative controls: a fixture carrying EITHER spelling MUST be reported, or F9a proves nothing.
# F9b is the single-line form (the one that actually shipped and broke the gate); F9d is the
# multi-line form, which the same-line matcher missed entirely.
printf 'RULES=$(cat <<%sRULES%s\na body with an apostrophe: it is fine\nRULES\n)\n' "'" "'" >"$TMP/f9-neg.sh"
if [ -n "$(subst_heredoc_pin "$TMP/f9-neg.sh")" ]; then
  ok "F9b-negative: the shape matcher REPORTS the single-line heredoc-in-\$( … ) form on a fixture that carries it (so F9a can fail)"
else
  bad "F9b: the shape matcher cannot fail — it reported nothing on a fixture that carries the exact old shape"
fi
{ printf 'X="$('; printf '\n'; printf 'cat <<%sEOF%s' "'" "'"; printf '\n'; printf 'it%ss a quote' "'"; printf '\n'; printf 'EOF'; printf '\n'; printf ')"'; printf '\n'; } >"$TMP/f9-multiline.sh"
if [ -n "$(subst_heredoc_pin "$TMP/f9-multiline.sh")" ]; then
  ok "F9d-negative: the shape matcher REPORTS the MULTI-LINE heredoc-in-\$( … ) form (an equal parse failure on 3.2.57, and the one the same-line matcher missed)"
else
  bad "F9d: the shape matcher missed the multi-line spelling — the pin would let a 3.2-fatal detector read as green on bash-5 CI"
fi
# F9e — the matcher must not fire on a heredoc at TOP LEVEL, nor on a `$(` inside a heredoc BODY:
# a matcher that reds on correct code is the over-block that gets the gate switched off.
printf 'cat <<%sEOF%s\nX="$(date)"\nEOF\n' "'" "'" >"$TMP/f9-toplevel.sh"
if [ -z "$(subst_heredoc_pin "$TMP/f9-toplevel.sh")" ]; then
  ok "F9e: a top-level heredoc whose BODY contains a substitution is NOT reported (bodies are data, not code)"
else
  bad "F9e: the shape matcher reported a legit top-level heredoc body — over-block on correct code"
fi
# F9f — the `case`-arm spelling: the arm label `)` does NOT close the substitution, so a matcher that
# pops there reads the opener as TOP LEVEL (records the heredoc, skips the body, reports nothing) and
# bash 3.2.57 still refuses the file. Measured with `bash:3.2` docker: `syntax error near unexpected
# token ';;'`. This is the shape a `$(case … esac)` rule table would carry.
{ printf 'RULES=$(case "${1:-}" in'; printf '\n'; printf '  all) cat <<%sMUTEOF%s' "'" "'"; printf '\n'; printf "it%ss a quote" "'"; printf '\n'; printf 'MUTEOF'; printf '\n'; printf '  ;;'; printf '\n'; printf 'esac)'; printf '\n'; } >"$TMP/f9-case.sh"
if [ -n "$(subst_heredoc_pin "$TMP/f9-case.sh")" ]; then
  ok "F9f-negative: the shape matcher REPORTS a heredoc opened inside a CASE ARM of a substitution (the arm-label ')' must not close it)"
else
  bad "F9f: the matcher popped the substitution at the case arm label and missed a 3.2-fatal heredoc"
fi
# F9c — the real parse, under this host's bash and under a real bash 3.x if the host has one
if bash -n "$CHECK" 2>"$TMP/f9.err"; then
  ok "F9c: the detector PARSES under this host's bash $BASHV (bash -n is clean)"
else
  bad "F9c: the detector does not parse under this host's bash $BASHV — $(head -2 "$TMP/f9.err" | tr '\n' ' ')"
fi
# a real bash 3.x, discovered (never assumed): the host's /bin/bash is 3.2.57 on macOS
B3=""
for cand in /bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash /opt/homebrew/opt/bash/bin/bash; do
  [ -x "$cand" ] || continue
  case "$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" in
    3) B3="$cand"; break ;;
  esac
done
if [ -n "$B3" ]; then
  b3v="$("$B3" -c 'echo "$BASH_VERSION"' 2>/dev/null)"
  if ! "$B3" -n "$CHECK" 2>"$TMP/f9b3.err"; then
    bad "F9c32: the detector does not PARSE under $B3 (bash $b3v) — $(head -2 "$TMP/f9b3.err" | tr '\n' ' ')"
  else
    b3rules="$("$B3" "$CHECK" --list-rules 2>"$TMP/f9b3.run" | grep -c '  trap:')"; b3rc=$?
    if [ "$b3rules" -ge 19 ]; then
      ok "F9c32: the detector parses AND prints its rule table under a real bash 3.x ($B3, $b3v): $b3rules rules"
    else
      bad "F9c32: bash 3.x parsed the file but the rule table was not produced ($b3rules rules, rc=$b3rc) — a parse-only pass would hide an inert gate"
    fi
  fi
else
  unproven "no bash 3.x interpreter on this host (probed /bin/bash, /usr/local/bin/bash, the homebrew paths) — F9a's textual pin is the only 3.2 coverage here"
fi

printf 'PASS %d · FAIL %d · SKIP %d · UNPROVEN %d   [ran on %s, bash %s]\n' \
  "$PASS" "$FAIL" "$SKIP" "$UNPROVEN" "$OS" "$BASHV"
if [ "$FAIL" -gt 0 ]; then
  printf '❌ %d arm(s) failed\n' "$FAIL"
  exit 1
fi
printf '✅ all arms green on %s\n' "$OS"
exit 0
