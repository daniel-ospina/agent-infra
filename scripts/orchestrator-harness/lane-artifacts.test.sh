#!/usr/bin/env bash
# Tests for lane-artifacts.sh — the pull verb that makes a CELL lane's artifact reachable from the
# machine the orchestrator runs on.
#
# The stub CMUX_BIN answers `vm list` from a fixture and runs `vm exec … sh -c '<script>' ARG0 ARG1…`
# LOCALLY, retargeting the root argument to that label's own fixture directory, and — critically —
# MODELLING THE CHANNEL'S STDIN BEHAVIOUR (see T3). So every case here is hermetic: no cloud VM, no
# network, no dependency on whatever happens to sit in a live box's /tmp.
#
# The cases are chosen from the failures that ACTUALLY HAPPENED while building this:
#   T1  a real artifact found on ONE box is collected, byte-exact (compared by sha, not by `cat`)
#   T2  a file held by a DIFFERENT box is collected from that box
#   T3  ⛔ the stdin-eat regression: an inner exec inside the `while read … <<< "$MAP"` loop must not
#       consume the loop's remaining rows. The stub CONSUMES ONE LINE OF STDIN on every exec, exactly
#       as the real channel does — without that, the guard cannot be tested and this case passes with
#       the bug present (that is how the bug survived the first round).
#   T4  nothing anywhere, every box reached ⇒ exit 3 ABSENT-EVERYWHERE
#   T5  every box UNMEASURED ⇒ exit 4, never "absent", never 0
#   T5b ⛔ a box UNMEASURED + nothing found ⇒ exit 4, NOT exit 3 — "absent" is not claimed
#   T6  one dead box does not lose the file a live box holds
#   T7  a KILLED writer's artifact is collectable (the case that matters most)
#   T8  `ls` on a dead fleet says UNMEASURED, not an empty healthy inventory
#   T9  a 0-byte artifact (lane killed between create and write) is a SUCCESSFUL pull, not a failure
#   T10 a truncation is caught: decoded size != the size the box reported ⇒ discarded, exit 5
#   T11 an apostrophe in a filename does not break the pull
#   T12 `logs` takes the EXACT path — a `.log.bak` decoy is not collected
#   T13 a truncated invocation (`--out` with no value) ERRORS, it does not spin forever
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/lane-artifacts.sh"
Q="$(mktemp -d "${TMPDIR:-/tmp}/lane-artifacts-test.XXXXXX")"
trap 'rm -rf "$Q"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗ %s\033[0m\n     %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

# ⛔ THE HASHER MUST BE PROBED, NOT ASSUMED. `shasum` is a perl script that is not on every image
# (ubuntu-latest ships `sha256sum` and no `shasum`); an unprobed hasher leaves BOTH sides of an equality
# empty, so the assertion passes over NO evidence — the repo's already-paid-for false-PASS class, which
# `deploy-harness.test.sh` resolves the same way. `SHA_CMD` is unquoted at the call sites on purpose: the
# `shasum` arm is two words.
if command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"
else printf 'FATAL: no sha256 hasher (sha256sum or shasum) on PATH — refusing to report byte assertions as passed\n' >&2; exit 1
fi

# ── the stub ─────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$Q/bin"
cat > "$Q/bin/stub-cmux" <<'STUB'
#!/usr/bin/env bash
# STUB_BOXES: "label=path" pairs, one per line. STUB_DEAD: labels whose exec always fails.
# STUB_SUFFIX_TAG: appended to a pulled file's base64 so a truncation can be simulated.
boxes="${STUB_BOXES:-}"
dead="${STUB_DEAD:-}"
if [ "${1:-}" = "vm" ] && [ "${2:-}" = "list" ]; then
  echo "NAME                                 LABEL      STATE"
  while IFS='=' read -r label path; do
    [ -n "$label" ] && echo "vm-$label  $label  running"
  done <<< "$boxes"
  exit 0
fi
if [ "${1:-}" = "vm" ] && [ "${2:-}" = "exec" ]; then
  shift 2
  [ "${1:-}" = "--timeout" ] && shift 2
  vm="${1:-}"; shift
  [ "${1:-}" = "--" ] && shift
  label="${vm#vm-}"
  case " $dead " in *" $label "*) echo "Error: The Cloud VM request failed." >&2; exit 1 ;; esac
  # STUB_SILENT: the channel EXITS 0 AND PRINTS NOTHING — no `__OK__` sentinel, no rows, no error. This is
  # the one fail-open shape the honesty contract has to survive (an answered-but-empty transport), and it
  # was reached by NO case until T37: every other dead-box arm exits non-zero and is therefore caught one
  # check earlier. Measured by review on a mutant: deleting the `first != __OK__` abstention left the suite
  # at 96/96 while the tool started reporting a confident ABSENT-EVERYWHERE (exit 3) for a box that never
  # answered. A fixture nothing reaches pins nothing.
  if [ -n "${STUB_SILENT:-}" ]; then exit 0; fi
  # STUB_SLEEP: hold the exec open so a run can be signalled MID-FLIGHT (T43). A tool that is never
  # interrupted cannot be tested for what it leaves behind.
  if [ -n "${STUB_SLEEP:-}" ]; then sleep "${STUB_SLEEP}"; fi
  # STUB_DEAD_LOG: let ONLY the `.log` scan fail, so the `ls` verb's second scan can be tested — the
  # reviewer found its failure was silently an empty list at exit 0 because only the `.md` scan was guarded.
  if [ -n "${STUB_DEAD_LOG:-}" ] && [ "${5:-}" != "${5%%.log*}" ]; then
    echo "Error: The Cloud VM request failed." >&2; exit 1
  fi
  # ⛔ MODEL THE CHANNEL: the real `cmux vm exec` READS THE CALLER'S STDIN. Swallow one line here so an
  # exec with no `</dev/null` inside a `while read … <<< "$MAP"` loop visibly eats the loop's rows and
  # T3 goes red. A stub that ignores stdin cannot test the guard at all.
  IFS= read -r _dropped || true
  root=""
  while IFS='=' read -r l p; do [ "$l" = "$label" ] && root="$p"; done <<< "$boxes"
  args=("$@")
  # Retarget the root ARGUMENT to this label's OWN fixture root. The tool passes the root as an
  # argument (never interpolated into the script text) precisely so a stub can retarget it per box —
  # which is also why a multi-box run stays honest about which box a file came from. Match by VALUE,
  # not by index: an index-based version silently stopped matching when an argument was added.
  for i in "${!args[@]}"; do
    [ "${args[$i]}" = "${LANE_ARTIFACT_ROOT:-}" ] && args[$i]="$root"
  done
  # Simulate a TRUNCATED transfer: drop the last 8 base64 chars of the PAYLOAD, keeping the status line.
  # ⛔ The previous version used `$"\n"` (locale quoting) instead of `$'\n'`, so the pattern never
  # matched, `payload` became the WHOLE output, and the case appended a duplicate copy rather than
  # truncating — it passed for a reason its comment did not describe. Measured by review: "decoded 17
  # bytes, the box reported 11" — doubled, not truncated.
  if [ -n "${STUB_TRUNCATE:-}" ] && [ "${args[2]:-}" != "${args[2]%%base64*}" ]; then
    out="$("${args[@]}" 2>/dev/null)"
    # Line 1 is the status (`RC=n SIZE=m`); everything after it is the payload. A real cut loses payload
    # bytes, NOT the status line — so truncate `rest`, keep `payload` whole. (The first fix truncated the
    # wrong one and the case went green by falling back to the scan size.)
    payload="${out%%$'\n'*}"
    rest="${out#*$'\n'}"
    [ "$rest" = "$out" ] && rest=""
    printf '%s\n%s\n' "$payload" "${rest%????????}"
    exit 0
  fi
  # Simulate a transfer whose TAIL is lost entirely (status line included). Only a PREFIX marker survives
  # this, so T18 can discriminate the round-2 "status line first" fix: a suffix marker yields
  # `remote exit ?` instead of the SIZE MISMATCH the check is supposed to report.
  if [ -n "${STUB_CUT_TAIL:-}" ] && [ "${args[2]:-}" != "${args[2]%%base64*}" ]; then
    out="$("${args[@]}" 2>/dev/null)"
    printf '%s' "${out%????????????}"
    exit 0
  fi
  # STUB_SCAN_ERROR: the remote scan ANSWERS but reports a failure (`__NOK__ find-failed`). Without this
  # arm the find-errored guard has no test that would go red on regression — the stub could only simulate
  # a DEAD exec, which is a different branch.
  if [ -n "${STUB_SCAN_ERROR:-}" ] && [ "${args[2]:-}" != "${args[2]%%find *}" ]; then
    printf '__NOK__ find-failed(rc=1)\n'; exit 0
  fi
  # STUB_BAD_SIZE: a row the listing cannot parse — what a NEWLINE in a filename produces. The path is
  # the LAST field in a row (see T28 for why), so a TAB in a name is carried intact; a newline still
  # splits the record, and the tail line's first field is then a fragment of the NAME — non-numeric, so
  # the row must ABSTAIN rather than be carried into a pull as a bogus path.
  if [ -n "${STUB_BAD_SIZE:-}" ] && [ "${args[2]:-}" != "${args[2]%%find *}" ]; then
    printf '__OK__ 2\n5\t2026-01-01T00:00:00\t%s/has\ntab.md\n' "$root"; exit 0
  fi
  # STUB_BAD_SIZE_NUM: the SAME split record as STUB_BAD_SIZE, but the continuation line is NUMERIC — the
  # shape a filename like `has<newline>2026` actually produces. STUB_BAD_SIZE's tail (`tab.md`) is
  # non-numeric, so a guard that only asks "is field 1 numeric?" passes T48/T49 while the numeric tail —
  # the case that was MEASURED shipping a false PASS — stays completely uncovered. The sentinel count is
  # `2` and the caller parses `2`, so the count check agrees with itself and only the SHAPE can abstain.
  if [ -n "${STUB_BAD_SIZE_NUM:-}" ] && [ "${args[2]:-}" != "${args[2]%%find *}" ]; then
    printf '__OK__ 2\n9\t2026-01-01T00:00:00\t%s/has\n2026\n' "$root"; exit 0
  fi
  # STUB_TAB_NAME: a TAB inside a real filename, with the size/metadata intact. The path is the LAST
  # field, so `read -r sz mt p` must keep the whole name — the earlier order accepted this row as a
  # valid measurement of the name's HEAD and pulled a different file, at exit 0.
  if [ -n "${STUB_TAB_NAME:-}" ] && [ "${args[2]:-}" != "${args[2]%%find *}" ]; then
    printf '__OK__ 1\n9\t2026-01-01T00:00:00\t%s/has\ttab.md\n' "$root"; exit 0
  fi
  # STUB_WRAP: model the PRODUCTION encoder. This host's `base64` is FreeBSD and does NOT wrap, so a
  # wrap-guard test cannot fire here — the fix would look right and be untestable. A shim on PATH wraps
  # at 76 columns like GNU coreutils, so the length check (which must count CHARACTERS, not newlines) is
  # host-independent and reds on a revert.
  if [ -n "${STUB_WRAP:-}" ]; then
    _sh="$STUB_WRAP/shim"; mkdir -p "$_sh"
    if [ ! -x "$_sh/base64" ]; then
      printf '#!/bin/sh\nexec /usr/bin/base64 "$@" | fold -w 76\n' > "$_sh/base64"
      printf '#!/bin/sh\nexec /usr/bin/base64 "$@" | fold -w 76\n' > "$_sh/base64.tmp"
      chmod +x "$_sh/base64"
    fi
    PATH="$_sh:$PATH"; export PATH
  fi
  # STUB_GROW: simulate a lane writing WHILE the pull runs. Appending before the exec is not enough — a
  # first read and a second read inside the same exec then see the same size and the atomicity fix looks
  # tested when it is not. So append on the base64 read AND again when the script would take a SECOND
  # read of the file (`wc -c < "$1"`), which is exactly the window the fix closes.
  if [ -n "${STUB_GROW:-}" ]; then
    case "${args[2]:-}" in
      *base64*) printf 'line-appended-by-the-live-lane\n' >> "$STUB_GROW" 2>/dev/null ;;
    esac
    case "${args[2]:-}" in
      *'wc -c < "$1"'*) printf 'line-appended-by-the-live-lane\n' >> "$STUB_GROW" 2>/dev/null ;;
    esac
  fi
  # STUB_READ_FAIL: the READER fails while `find` succeeded — the asymmetry round 5 fixed (find was
  # converted to __NOK__, the reader was not) and which had no arm to test it.
  if [ -n "${STUB_READ_FAIL:-}" ] && [ "${args[2]:-}" != "${args[2]%%head -n*}" ]; then
    echo 'stub: reader exploded' >&2; exit 1
  fi
  # STUB_BULK: a directory with more matches than ROW_CAP, so the truncation notice is exercised.
  # Rows are `size<TAB>mtime<TAB>path` — the SAME order the real remote emits (a stub with a different
  # order would test a parser that does not exist in production).
  if [ -n "${STUB_BULK:-}" ] && [ "${args[2]:-}" != "${args[2]%%find *}" ]; then
    echo '__OK__ 240'
    i=0; while [ $i -lt 240 ]; do printf '1\t2026-01-01T00:00:00\t%s/bulk-%s.md\n' "$STUB_BULK" "$i"; i=$((i+1)); done
    exit 0
  fi
  # STUB_UNREADABLE: the file exists for the scan but the pull's read FAILS (chmod 000 / vanished). This
  # is the case where `rc=$?` after a pipeline used to capture *tr*'s status and report a 0-byte SUCCESS.
  if [ -n "${STUB_UNREADABLE:-}" ] && [ "${args[2]:-}" != "${args[2]%%base64*}" ]; then
    printf 'RC=1 LEN=0\n\n'; exit 0
  fi
  # STUB_ZERO_PULL: the pull itself SUCCEEDS (rc 0) but returns nothing, while the scan row said the file
  # has bytes — the "vanished mid-flight" cross-check. It has no other way to be reached: STUB_UNREADABLE
  # fails the read (rc 1), which is a different branch.
  if [ -n "${STUB_ZERO_PULL:-}" ] && [ "${args[2]:-}" != "${args[2]%%base64*}" ]; then
    printf 'RC=0 LEN=0\n\n'; exit 0
  fi
  # STUB_PREVIEW_FAIL: the PREVIEW exec fails while the scan and the pull are fine. Matched on the preview
  # script's own argv shape (`head -n "$1" -- "$2"`) — matching on `head -n` alone would also fail the
  # SCAN, which has its own `head -n N` cap.
  if [ -n "${STUB_PREVIEW_FAIL:-}" ]; then
    case "${args[2]:-}" in
      *'head -n "$1" -- "$2"'*) exit 1 ;;
    esac
  fi
  exec "${args[@]}" 2>/dev/null
fi
echo "stub: unsupported: $*" >&2
exit 99
STUB
chmod +x "$Q/bin/stub-cmux"
export CMUX_BIN="$Q/bin/stub-cmux"

mk() { mkdir -p "$Q/$1"; printf '%s' "$2" > "$Q/$1/$3"; }
mk box-a 'artifact-a-body
second line
' ci-cause.md
mk box-a 'older' other.md
mk box-b 'histogram on b' blocked-histogram.md
mk box-c 'ledger on c' epic-ledger.md
mk box-c 'p1 on c' p1-10515.md
mk box-c 'killproof: written then the writer was SIGKILLed' killproof-lane.md
mk box-c '' empty-artifact.md
mk box-c 'apostrophe body' "don't-panic.md"
mk box-c 'exact log' t-lane.log
mk box-c 'decoy' t-lane.log.bak

export LANE_ARTIFACT_BOXES="pi-cell-1 pi-cell-3 pi-cell-4"
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
export STUB_DEAD=""
export LANE_ARTIFACT_ROOT="$Q/never-used"   # the stub retargets it per box

run() { bash "$TOOL" "$@" 2>&1; }

echo "T1 — a real artifact found on one box is collected, byte-exact"
out="$Q/out1"; mkdir -p "$out"
run collect ci-cause --out "$out" --lines 1 > "$Q/t1.txt" 2>&1
grep -q 'artifact-a-body' "$Q/t1.txt" && ok "T1 body printed" || bad "T1 body printed" "$(head -5 "$Q/t1.txt")"
[ -f "$out/pi-cell-1-ci-cause.md" ] && ok "T1 wrote pi-cell-1-ci-cause.md" || bad "T1 wrote the file" "$(ls "$out")"
# sha, not `cat`: command substitution strips trailing newlines, so a `cat` comparison would pass even
# if the final newline were lost.
eq "T1 byte-exact (sha256)" "$($SHA_CMD < "$out/pi-cell-1-ci-cause.md" | cut -d' ' -f1)" \
   "$($SHA_CMD < "$Q/box-a/ci-cause.md" | cut -d' ' -f1)"

echo "T2 — a name held by a DIFFERENT box is collected from that box"
run collect blocked-histogram > "$Q/t2.txt" 2>&1
grep -q 'histogram on b' "$Q/t2.txt" && ok "T2 found the file on pi-cell-3" || bad "T2 found it" "$(head -8 "$Q/t2.txt")"
grep -q 'pi-cell-3' "$Q/t2.txt" && ok "T2 names the box it came from" || bad "T2 names the box" ""

echo "T3 — REGRESSION: no exec may eat the loop's rows (stub consumes stdin like the real channel)"
out="$Q/out3"; mkdir -p "$out"
run collect .md --out "$out" --lines 1 > "$Q/t3.txt" 2>&1
n="$(ls "$Q/out3" | grep -c '^pi-cell-4-.*\.md$')"
[ -n "$(ls "$Q/out3" | grep '^pi-cell-1-' || true)" ] && ok "T3 the FIRST box was scanned" || bad "T3 first box scanned" "$(head -6 "$Q/t3.txt")"
[ -n "$(ls "$Q/out3" | grep '^pi-cell-4-' || true)" ] && ok "T3 the LAST box was scanned (not eaten)" || bad "T3 last box scanned" "$(head -8 "$Q/t3.txt")"
[ "$n" -ge 4 ] && ok "T3 all 4 box-c .md files pulled ($n)" || bad "T3 all box-c files pulled" "got $n from: $(ls "$Q/out3")"

echo "T4 — nothing anywhere, every box reached ⇒ exit 3 ABSENT-EVERYWHERE"
run collect no-such-artifact-anywhere > "$Q/t4.txt" 2>&1
rc=$?
eq "T4 exit 3" "$rc" "3"
grep -q 'ABSENT-EVERYWHERE' "$Q/t4.txt" && ok "T4 says ABSENT-EVERYWHERE" || bad "T4 wording" "$(cat "$Q/t4.txt")"

echo "T5 — every box UNMEASURED ⇒ exit 4 and the word UNMEASURED (never absent, never 0)"
STUB_DEAD="pi-cell-1 pi-cell-3 pi-cell-4"; run collect ci-cause > "$Q/t5.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T5 exit 4" "$rc" "4"
grep -q 'UNMEASURED' "$Q/t5.txt" && ok "T5 says UNMEASURED" || bad "T5 wording" "$(cat "$Q/t5.txt")"
grep -q 'ABSENT-EVERYWHERE' "$Q/t5.txt" && bad "T5 must NOT claim absent" "$(cat "$Q/t5.txt")" \
  || ok "T5 does not claim absent"

echo "T5b — a box UNMEASURED + nothing found ⇒ exit 4, and ABSENT is NOT claimed"
STUB_DEAD="pi-cell-3"; run collect no-such-artifact > "$Q/t5b.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T5b exit 4 (not 3)" "$rc" "4"
grep -q 'ABSENT-EVERYWHERE' "$Q/t5b.txt" && bad "T5b must not claim absent" "$(cat "$Q/t5b.txt")" \
  || ok "T5b does not claim absent while a box is unmeasured"

echo "T6 — one dead box does not lose the file a live box holds"
STUB_DEAD="pi-cell-1 pi-cell-3"; run collect epic-ledger > "$Q/t6.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T6 exit 0" "$rc" "0"
grep -q 'ledger on c' "$Q/t6.txt" && ok "T6 collected from the live box" || bad "T6 collected" "$(head -6 "$Q/t6.txt")"
grep -q 'pi-cell-1.*UNMEASURED' "$Q/t6.txt" && ok "T6 names the dead box as UNMEASURED" || bad "T6 names the dead box" "$(head -6 "$Q/t6.txt")"
# ⛔ The SUCCESS-path disclosure is a separate line from emit_box's per-box line, and it had no assertion:
# deleting the whole block left the suite green. Exit 0 with 2 of 3 boxes silent reads as a complete
# result to any caller keying on the status, so this line is the only thing that says otherwise.
grep -q 'COVERAGE INCOMPLETE' "$Q/t6.txt" && ok "T6 discloses incomplete coverage on the SUCCESS path" \
  || bad "T6 does not disclose partial coverage" "$(tail -4 "$Q/t6.txt")"

echo "T7 — a process that wrote a file and was then SIGKILLed leaves a collectable artifact (the case that matters most)"
# ⛔ The writer below REALLY IS killed with SIGKILL before the tool runs, so the pull cannot depend on the
# writer surviving, cooperating, or executing anything after the write. The earlier version of this case
# only contained the word "SIGKILLed" in the fixture body — it was T1 with different bytes and could not
# fail if killed-lane survival were false. (The live CROSS-BOX proof needs a real `cmux vm exec` and is
# quoted in the PR body, not asserted here.)
rm -f "$Q/box-c/killed-lane.md"
# The writer is killed FROM OUTSIDE, exactly as a reaped lane is: it writes, then blocks, and the test
# SIGKILLs it. (Killing itself with `kill -9 $$` also works but makes the shell print a "Killed" job
# notice into the suite's output, which reads like a failure in a CI log.)
sh -c 'printf "written mid-run, before any chance to upload\n" > "$1"; sleep 30' lane-writer "$Q/box-c/killed-lane.md" &
wpid=$!
_i=0; while [ "$_i" -lt 50 ] && [ ! -s "$Q/box-c/killed-lane.md" ]; do sleep 0.1; _i=$((_i + 1)); done
kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
[ -s "$Q/box-c/killed-lane.md" ] && ok "T7 the writer left its file behind" || bad "T7 fixture was not written" "$(ls "$Q/box-c")"
kill -0 "$wpid" 2>/dev/null && bad "T7 the writer is still alive — this is not the killed-lane case" "pid $wpid" \
  || ok "T7 the writer is provably GONE (SIGKILLed) before the pull"
out="$Q/out7"; mkdir -p "$out"
run collect killed-lane --out "$out" --lines 2 > "$Q/t7.txt" 2>&1
rc=$?
eq "T7 exit 0" "$rc" "0"
grep -q 'before any chance to upload' "$out/pi-cell-4-killed-lane.md" 2>/dev/null && ok "T7 the dead writer's artifact was collected" \
  || bad "T7 collected" "$(head -6 "$Q/t7.txt")"

echo "T8 — \`ls\` on a dead fleet says UNMEASURED, not an empty healthy inventory"
STUB_DEAD="pi-cell-1 pi-cell-3 pi-cell-4"; run ls > "$Q/t8.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T8 exit 4" "$rc" "4"
grep -q 'UNMEASURED' "$Q/t8.txt" && ok "T8 says UNMEASURED" || bad "T8 wording" "$(head -8 "$Q/t8.txt")"

echo "T9 — a 0-byte artifact is a SUCCESSFUL pull (lane killed between create and write)"
out="$Q/out9"; mkdir -p "$out"
run collect empty-artifact --out "$out" > "$Q/t9.txt" 2>&1
rc=$?
eq "T9 exit 0" "$rc" "0"
[ -f "$out/pi-cell-4-empty-artifact.md" ] && ok "T9 wrote the 0-byte file" || bad "T9 wrote it" "$(cat "$Q/t9.txt")"
eq "T9 size" "$(wc -c < "$out/pi-cell-4-empty-artifact.md" | tr -d ' ')" "0"

echo "T10 — a truncated transfer is caught by the size check and discarded, exit 5"
out="$Q/out10"; mkdir -p "$out"
STUB_TRUNCATE=1 bash "$TOOL" collect epic-ledger --out "$out" > "$Q/t10.txt" 2>&1
rc=$?
eq "T10 exit 5" "$rc" "5"
[ -f "$out/pi-cell-4-epic-ledger.md" ] && bad "T10 truncated file must be discarded" "$(ls "$out")" \
  || ok "T10 truncated file discarded"
grep -qi 'SIZE MISMATCH\|TRUNCATED' "$Q/t10.txt" && ok "T10 says why" || bad "T10 says why" "$(cat "$Q/t10.txt")"

echo "T11 — an apostrophe in a filename does not break the pull"
out="$Q/out11"; mkdir -p "$out"
run collect "don't-panic" --out "$out" > "$Q/t11.txt" 2>&1
expect="$out/pi-cell-4-don't-panic.md"
grep -q 'apostrophe body' "$expect" 2>/dev/null && ok "T11 pulled and printed it" \
  || bad "T11 pulled it" "$(head -8 "$Q/t11.txt"); files: $(ls "$out" 2>/dev/null)"

echo "T12 — \`logs\` takes the EXACT path; a .log.bak decoy is not collected"
out="$Q/out12"; mkdir -p "$out"
run logs t-lane --out "$out" > "$Q/t12.txt" 2>&1
[ -f "$out/pi-cell-4-t-lane.log" ] && ok "T12 took the exact log" || bad "T12 exact log" "$(cat "$Q/t12.txt")"
grep -q 'exact log' "$out/pi-cell-4-t-lane.log" 2>/dev/null && ok "T12 log body is the exact file's" \
  || bad "T12 log body" "$(cat "$out/pi-cell-4-t-lane.log" 2>/dev/null)"
ls "$out" | grep -q 'log.bak' && bad "T12 must not collect the decoy" "$(ls "$out")" || ok "T12 decoy not collected"

echo "T13 — a truncated invocation errors instead of spinning forever"
# `timeout` is GNU coreutils and absent on macOS; guard with a background pid + a bounded wait instead,
# so this case tests the tool and not the host's coreutils.
bash "$TOOL" collect ci-cause --out > "$Q/t13.txt" 2>&1 &
t13pid=$!
( sleep 5; kill -9 "$t13pid" 2>/dev/null ) &
watchdog=$!
wait "$t13pid" 2>/dev/null; rc=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
eq "T13 exit 64 on a missing option value" "$rc" "64"
grep -q 'missing value for --out' "$Q/t13.txt" && ok "T13 names the missing value" || bad "T13 wording" "$(cat "$Q/t13.txt")"

echo "T5c — a requested label that does not resolve ⇒ exit 4, NOT 3 (it was never attempted)"
OLD="$STUB_BOXES"
STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-4=$Q/box-c"
STUB_BOXES="$STUB_BOXES" run collect no-such-artifact > "$Q/t5c.txt" 2>&1
rc=$?
STUB_BOXES="$OLD"
eq "T5c exit 4" "$rc" "4"
grep -q '^ABSENT-EVERYWHERE' "$Q/t5c.txt" && bad "T5c must not claim absent" "$(cat "$Q/t5c.txt")" \
  || ok "T5c does not claim absent for a label it never resolved"

echo "T8b — ls: the .log scan failing is UNMEASURED, not an empty list at exit 0"
STUB_DEAD_LOG=1; export STUB_DEAD_LOG
run ls > "$Q/t8b.txt" 2>&1
unset STUB_DEAD_LOG
# The .md scan succeeded, so the box IS reached — but a partial inventory is not an inventory, so the
# verb still ABSTAINS (exit 4; that half is pinned by T20, which runs this same setup). The point here is
# that the failed .log scan is NAMED rather than silently rendering as "this box has no lane logs".
grep -q 'UNMEASURED(log' "$Q/t8b.txt" && ok "T8b names the failed log scan" || bad "T8b names it" "$(head -10 "$Q/t8b.txt")"

echo "T14 — --since 30m is a USAGE error (exit 64), never a false ABSENT"
run collect ci-cause --since 30m > "$Q/t14.txt" 2>&1
rc=$?
eq "T14 exit 64" "$rc" "64"
grep -q '^ABSENT-EVERYWHERE' "$Q/t14.txt" && bad "T14 must not claim absent" "$(cat "$Q/t14.txt")" \
  || ok "T14 does not claim absent on a bad duration"

echo "T15 — a COMPLETE reused --out does not leave the previous run's artifacts beside this run's index"
# The hazard this pins is a MISMATCHED PAIR (run 1's files beside run 2's index), not deletion for its own
# sake: a run that collected everything replaces the collection, so the pair stays consistent.
out="$Q/out15"; mkdir -p "$out"
run collect epic-ledger --out "$out" >/dev/null 2>&1
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T15 run 1 wrote its file" || bad "T15 run 1" "$(ls "$out")"
run collect p1-10515 --out "$out" >/dev/null 2>&1
ls "$out" | grep -q 'pi-cell-4-epic-ledger.md' && bad "T15 stale artifact survived a complete run 2" "$(ls "$out")" \
  || ok "T15 stale artifact from run 1 removed by a complete run 2"
grep -q 'p1-10515' "$out/.lane-artifacts-index" 2>/dev/null && ok "T15 the index names run 2's artifact" \
  || bad "T15 index" "$(cat "$out/.lane-artifacts-index" 2>/dev/null)"

echo "T16 — the ABSENT message echoes the --since it actually applied"
run collect no-such-file --since 60 > "$Q/t16.txt" 2>&1
rc=$?
eq "T16 exit 3" "$rc" "3"
grep -q -- '-mmin -60' "$Q/t16.txt" && ok "T16 echoes the mmin filter" || bad "T16 echoes --since" "$(cat "$Q/t16.txt")"
grep -q 'in the last 60 minutes' "$Q/t16.txt" && ok "T16 says the window in words" || bad "T16 window wording" "$(cat "$Q/t16.txt")"

echo "T17 — an unparseable scan row ABSTAINS instead of producing a wrong verdict"
# A NEWLINE in a filename splits the record; the tail line's leading field is a fragment of the name, so
# the size column is non-numeric and the row must abstain. (A TAB in a name is a different case and is
# carried correctly now that the path is the LAST field — see T28.) The old code carried the corruption
# into a pull: a bogus path, then PULL-FAILED — a wrong verdict.
out="$Q/out17"; mkdir -p "$out"
STUB_BAD_SIZE=1; export STUB_BAD_SIZE
run collect .md --out "$out" > "$Q/t17.txt" 2>&1
rc=$?; unset STUB_BAD_SIZE
eq "T17 exit 4 (abstain)" "$rc" "4"
grep -q 'unparseable scan row' "$Q/t17.txt" && ok "T17 names the unparseable row" || bad "T17 names it" "$(head -6 "$Q/t17.txt")"

echo "T18 — the transfer status is a PREFIX: a tail-cut still yields a specific verdict"
# This is the discrimination the round-2 fix never had: with the marker as a SUFFIX, cutting the tail
# destroys it and the tool says "remote exit ?" instead of the size mismatch it actually detected.
out="$Q/out18"; mkdir -p "$out"
STUB_CUT_TAIL=1; export STUB_CUT_TAIL
run collect epic-ledger --out "$out" > "$Q/t18.txt" 2>&1
rc=$?; unset STUB_CUT_TAIL
[ "$rc" -ne 0 ] && ok "T18 fails closed (exit $rc)" || bad "T18 must not report success" "$(cat "$Q/t18.txt")"
grep -qiE 'SIZE MISMATCH|TRUNCATED' "$Q/t18.txt" && ok "T18 names a specific verdict (prefix marker survived)" \
  || bad "T18 should name TRUNCATED, not a lost status" "$(cat "$Q/t18.txt" | tail -4)"

echo "T19 — a scan that ANSWERS but reports failure is UNMEASURED, never ABSENT"
STUB_SCAN_ERROR=1; export STUB_SCAN_ERROR
run collect no-such-file > "$Q/t19.txt" 2>&1
rc=$?; unset STUB_SCAN_ERROR
eq "T19 exit 4" "$rc" "4"
grep -q 'find-failed' "$Q/t19.txt" && ok "T19 propagates the find failure" || bad "T19 find-failed" "$(head -6 "$Q/t19.txt")"
grep -q '^ABSENT-EVERYWHERE' "$Q/t19.txt" && bad "T19 must not claim absent" "$(cat "$Q/t19.txt")" \
  || ok "T19 does not claim absent on a failed scan"

echo "T20 — ls on a PARTIAL inventory abstains instead of exiting 0"
STUB_DEAD_LOG=1; export STUB_DEAD_LOG
run ls > "$Q/t20.txt" 2>&1
rc=$?; unset STUB_DEAD_LOG
eq "T20 exit 4 (partial inventory)" "$rc" "4"
grep -q 'NOT complete' "$Q/t20.txt" && ok "T20 says the list is not complete" || bad "T20 wording" "$(tail -3 "$Q/t20.txt")"

echo "T21 — a LIVE lane's growing log is NOT falsely rejected (the primary use case)"
# The pull reads the file ONCE and takes the length from that same payload, so a file appended between
# the scan and the transfer cannot disagree with itself. Two earlier versions compared against a second
# read and failed 2 of 3 runs on a fixture appended every few ms — a byte-perfect artifact discarded as
# "TRUNCATED" at exit 5, on exactly the case `logs` exists for.
mkdir -p "$Q/box-c"
printf 'line1\n' > "$Q/box-c/growing.log"
STUB_GROW="$Q/box-c/growing.log"; export STUB_GROW
STUB_WRAP="$Q/wrap"; export STUB_WRAP   # model the PRODUCTION (GNU) encoder, which wraps at 76 — this
                                         # host's base64 is FreeBSD and does NOT wrap, so without the
                                         # shim the wrap guard cannot fire where the suite actually runs.
out="$Q/out21"; mkdir -p "$out"
run logs growing --out "$out" > "$Q/t21.txt" 2>&1
rc=$?; unset STUB_GROW
eq "T21 exit 0 (a growing file is not a truncation)" "$rc" "0"
[ -s "$out/pi-cell-4-growing.log" ] && ok "T21 the artifact was written" || bad "T21 written" "$(cat "$Q/t21.txt")"

# T23 — a file large enough that `base64` WRAPS. The length check must count base64 CHARACTERS, not
# newlines: `${#b}` on wrapped output includes them. All the other fixtures are under the 76-char wrap
# width, so the suite was blind to this and only a LIVE pull caught it (11788 arrived vs 11943 "sent").
echo "T23 — a >76-byte artifact (base64 wraps) is pulled, not falsely rejected"
mkdir -p "$Q/box-c"
python3 -c "open('$Q/box-c/big-artifact.md','w').write('x'*500 + '\n')"
out="$Q/out23"; mkdir -p "$out"
run collect big-artifact --out "$out" > "$Q/t23.txt" 2>&1
rc=$?
eq "T23 exit 0" "$rc" "0"
eq "T23 byte-exact size" "$(wc -c < "$out/pi-cell-4-big-artifact.md" 2>/dev/null | tr -d ' ')" "501"

# T22 — a row-capped list is a PARTIAL list: it must not be reported as success.
echo "T22 — a truncated (row-capped) result abstains instead of exiting 0"
mkdir -p "$Q/box-bulkmany"
for i in $(seq 1 240); do printf 'x' > "$Q/box-bulkmany/bulk-$i.md"; done
export STUB_BULK="$Q/box-bulkmany"
run collect bulk- --box pi-cell-1 > "$Q/t22.txt" 2>&1
rc=$?; unset STUB_BULK
eq "T22 exit 4 (list is NOT complete)" "$rc" "4"
grep -q 'NOT complete' "$Q/t22.txt" && ok "T22 says the list is not complete" || bad "T22 wording" "$(tail -3 "$Q/t22.txt")"

# T24 — an UNREADABLE artifact must FAIL, not report a 0-byte success. `rc=$?` after a pipeline captured
# tr's status (always 0), so a vanished/chmod-000 file looked like a legitimately empty one — a false PASS
# on the verb whose whole purpose is to stop exactly that.
echo "T24 — an unreadable artifact is a FAILED pull, not a silent 0-byte success"
# ⚠ This must exercise the REAL remote script: the bug was that `rc=$?` captured the status of a
# PIPELINE (`base64 | tr`) rather than base64's own, so an unreadable file reported rc=0 and a 0-byte
# success. A stub that simply answers `RC=1` tests nothing — it never opens the window. A chmod-000
# fixture on the box does, because `base64 < f` fails while `find` still lists the file.
mkdir -p "$Q/box-c"
printf 'unreadable artifact body' > "$Q/box-c/unreadable.md"
chmod 000 "$Q/box-c/unreadable.md"
out="$Q/out24"; mkdir -p "$out"
run collect unreadable --out "$out" > "$Q/t24.txt" 2>&1
rc=$?
chmod 644 "$Q/box-c/unreadable.md" 2>/dev/null
[ "$rc" -ne 0 ] && ok "T24 fails closed (exit $rc)" || bad "T24 must not exit 0 on an unreadable artifact" "$(cat "$Q/t24.txt")"
grep -qE 'pull failed|UNMEASURED' "$Q/t24.txt" && ok "T24 says the pull failed" || bad "T24 wording" "$(tail -3 "$Q/t24.txt")"
[ -f "$out/pi-cell-4-unreadable.md" ] && bad "T24 must not 'write' a 0-byte success" "$(ls -l "$out")" \
  || ok "T24 wrote no artifact"

# T25 — the READER failing (find succeeded) must be UNMEASURED, not "matched nothing".
echo "T25 — a failing row-reader is UNMEASURED, never ABSENT"
STUB_READ_FAIL=1; export STUB_READ_FAIL
run collect no-such-file > "$Q/t25.txt" 2>&1
rc=$?; unset STUB_READ_FAIL
eq "T25 exit 4" "$rc" "4"
grep -qE 'read-failed|UNMEASURED' "$Q/t25.txt" && ok "T25 abstains" || bad "T25 abstain" "$(head -4 "$Q/t25.txt")"
grep -q '^ABSENT-EVERYWHERE' "$Q/t25.txt" && bad "T25 must not claim absent" "$(cat "$Q/t25.txt")" \
  || ok "T25 does not claim absent"

# T26 — the published index records the size WRITTEN, not the stale scan size.
echo "T26 — the index records the size actually written"
mkdir -p "$Q/box-c"; printf 'a%.0s' $(seq 1 400) > "$Q/box-c/idxcheck.md"
out="$Q/out26"; mkdir -p "$out"
run collect idxcheck --out "$out" >/dev/null 2>&1
# The row is `label<TAB>SIZE<TAB>path` — SIZE is field 2 and the path is field 3-onward (path LAST, so a
# TAB in a name cannot split the record; see T39).
idx_size="$(awk -F"$(printf '\t')" '{print $2}' "$out/.lane-artifacts-index" 2>/dev/null | head -1)"
file_size="$(wc -c < "$out/pi-cell-4-idxcheck.md" 2>/dev/null | tr -d ' ')"
eq "T26 index size == file size" "${idx_size:-none}" "${file_size:-none}"

echo "T27 — ⛔ a FAILED re-run must NOT destroy the previous collection (a failed run is not a replacement)"
# Measured before the fix: the startup pass deleted every file the old index recorded and truncated the
# index BEFORE scanning, so a typo'd or all-boxes-dead re-run left the directory EMPTY — destroying the
# only orchestrator-side copy of a cell lane's artifact, which is the durability this tool exists for.
out="$Q/out27"; mkdir -p "$out"
run collect epic-ledger --out "$out" >/dev/null 2>&1
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T27 run 1 collected the artifact" || bad "T27 run 1" "$(ls -a "$out")"
idx_before="$(cat "$out/.lane-artifacts-index" 2>/dev/null)"
STUB_DEAD="pi-cell-1 pi-cell-3 pi-cell-4"; run collect epic-ledger --out "$out" > "$Q/t27.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T27 the failed re-run exits 4" "$rc" "4"
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T27 the previous artifact SURVIVED the failed run" \
  || bad "T27 the failed run destroyed the only copy" "$(ls -a "$out")"
eq "T27 the index still describes the surviving collection" "$(cat "$out/.lane-artifacts-index" 2>/dev/null)" "$idx_before"
grep -q 'still holds the PREVIOUS collection' "$Q/t27.txt" && ok "T27 says which collection the directory holds" \
  || bad "T27 does not say what survived" "$(tail -3 "$Q/t27.txt")"
[ -e "$out/.lane-artifacts-index.new" ] && bad "T27 left a side index behind" "$(ls -a "$out")" \
  || ok "T27 no side index left behind"

echo "T28 — a TAB inside a filename is carried intact, not truncated into a DIFFERENT file that pulls clean"
# The decoy is real, readable and is the name's HEAD. With the path FIRST in the scan row, `zz<TAB>7`
# parsed as size=7 for path `zz`, so the decoy was pulled, written as the artifact and COUNTED at exit 0 —
# while the matched artifact was never collected and no warning was printed.
out="$Q/out28"; mkdir -p "$out"; mkdir -p "$Q/box-tab"
printf 'DECOY' > "$Q/box-tab/has"
printf 'THE REAL ARTIFACT' > "$Q/box-tab/has$(printf '\t')tab.md"
bx_stub="$STUB_BOXES"; bx_labels="$LANE_ARTIFACT_BOXES"
export STUB_BOXES="pi-cell-1=$Q/box-tab"; export LANE_ARTIFACT_BOXES="pi-cell-1"
STUB_TAB_NAME=1; export STUB_TAB_NAME
run collect has --out "$out" > "$Q/t28.txt" 2>&1
rc=$?; unset STUB_TAB_NAME
export STUB_BOXES="$bx_stub"; export LANE_ARTIFACT_BOXES="$bx_labels"
eq "T28 exit 0" "$rc" "0"
got_sha="$($SHA_CMD < "$out/pi-cell-1-has$(printf '\t')tab.md" 2>/dev/null | cut -d' ' -f1)"
want_sha="$($SHA_CMD < "$Q/box-tab/has$(printf '\t')tab.md" | cut -d' ' -f1)"
eq "T28 the TAB-named artifact is collected byte-exact" "${got_sha:-missing}" "$want_sha"
decoy_sha="$($SHA_CMD < "$Q/box-tab/has" | cut -d' ' -f1)"
[ -n "$got_sha" ] && [ "$got_sha" = "$decoy_sha" ] && bad "T28 collected the DECOY (the name's head) instead" "" \
  || ok "T28 did not collect the name's head as the artifact"

echo "T29 — \`--since 0\` is a USAGE error: \`find -mmin -0\` matches nothing, so it would become an absence verdict"
run collect epic-ledger --since 0 > "$Q/t29.txt" 2>&1
rc=$?
eq "T29 exit 64" "$rc" "64"
grep -q '^ABSENT-EVERYWHERE' "$Q/t29.txt" && bad "T29 must not claim absent" "$(cat "$Q/t29.txt")" \
  || ok "T29 does not claim absent on a filter it cannot honour"
# The usage text legitimately NAMES the verdict, so the check above is anchored: an unanchored `grep
# ABSENT-EVERYWHERE` reads the help output as a claim, which is how a fix can look red for a non-reason.

echo "T30 — an EMPTY \`--box\` is a usage error: it widened a one-box request to the whole default fleet"
run collect epic-ledger --box "" > "$Q/t30.txt" 2>&1
rc=$?
eq "T30 exit 64" "$rc" "64"
grep -q 'collected from' "$Q/t30.txt" && bad "T30 must not scan the default fleet" "$(cat "$Q/t30.txt")" \
  || ok "T30 does not widen the universe"

echo "T31 — \`ls\` ABSTAINS on a row-capped scan instead of printing a short list as a total"
# Measured before the fix: a box holding 250 `.md` files was reported as "shown 25 of 201" at exit 0 — a
# measured total the inventory never measured, in the verb an operator uses to ask what EXISTS.
mkdir -p "$Q/box-bulkmany"
export STUB_BULK="$Q/box-bulkmany"
run ls > "$Q/t31.txt" 2>&1
rc=$?; unset STUB_BULK
eq "T31 exit 4" "$rc" "4"
grep -q 'row-capped' "$Q/t31.txt" && ok "T31 names the row cap" || bad "T31 names the row cap" "$(tail -4 "$Q/t31.txt")"

echo "T32 — \`logs\` ESCAPES glob metacharacters: an exact name is exact, not a glob that finds nothing"
# The metacharacter escaping is a measured false-ABSENT fix (the previous escape form was a silent no-op,
# so `logs 'x[1]'` glob-matched and returned ABSENT-EVERYWHERE about a file that existed). It had NO test:
# reverting it to `NAME="$1"` left the whole suite green, because T12's name has no metacharacters.
mk box-c 'metachar log' 'x[1].log'
mk box-c 'the decoy that a GLOB would also match' 'x1.log'
out="$Q/out32"; mkdir -p "$out"
run logs 'x[1]' --out "$out" > "$Q/t32.txt" 2>&1
rc=$?
eq "T32 exit 0" "$rc" "0"
grep -q 'metachar log' "$out/pi-cell-4-x[1].log" 2>/dev/null && ok "T32 collected the bracketed name exactly" \
  || bad "T32 did not collect x[1].log" "$(head -6 "$Q/t32.txt")"
[ -e "$out/pi-cell-4-x1.log" ] && bad "T32 collected the GLOB decoy x1.log" "$(ls "$out")" \
  || ok "T32 did not glob-match the decoy"

echo "T33 — a PATH pasted as the pattern is a USAGE error, never an ABSENT-EVERYWHERE"
# `find -name` cannot match a `/`, so a pasted path is the likely first invocation and used to return a
# confident "absent everywhere" about a file the tool was pointed straight at. No case reached this guard.
run collect /tmp/ci-cause.md > "$Q/t33.txt" 2>&1
rc=$?
eq "T33 exit 64" "$rc" "64"
grep -q '^ABSENT-EVERYWHERE' "$Q/t33.txt" && bad "T33 must not claim absent" "$(cat "$Q/t33.txt")" \
  || ok "T33 does not claim absent for a pasted path"

echo "T34 — a FAILED PREVIEW is disclosed, not rendered as an empty artifact at exit 0"
out="$Q/out34"; mkdir -p "$out"
STUB_PREVIEW_FAIL=1; export STUB_PREVIEW_FAIL
run collect ci-cause --out "$out" --lines 3 > "$Q/t34.txt" 2>&1
rc=$?; unset STUB_PREVIEW_FAIL
eq "T34 exit 0 (the PULL is what matters)" "$rc" "0"
grep -q 'preview failed' "$Q/t34.txt" && ok "T34 discloses the failed preview" || bad "T34 renders an empty artifact" "$(head -8 "$Q/t34.txt")"
grep -q 'artifact-a-body' "$out/pi-cell-1-ci-cause.md" 2>/dev/null && ok "T34 the full artifact was still collected" \
  || bad "T34 pull lost" "$(ls "$out")"

echo "T35 — a pull that returns NOTHING while the scan measured bytes is flagged (vanished mid-flight)"
# T9 asserts a genuine 0-byte artifact is a SUCCESS, but its fixture's scan size is also 0, so the
# cross-check's condition was never true in the suite.
out="$Q/out35"; mkdir -p "$out"
STUB_ZERO_PULL=1; export STUB_ZERO_PULL
run collect epic-ledger --out "$out" > "$Q/t35.txt" 2>&1
rc=$?; unset STUB_ZERO_PULL
eq "T35 exit 0 (rc=0 from the box)" "$rc" "0"
grep -q 'pulled 0 bytes but the scan measured' "$Q/t35.txt" && ok "T35 flags the vanished-mid-flight case" \
  || bad "T35 did not flag a 0-byte pull over a non-empty scan" "$(head -8 "$Q/t35.txt")"

echo "T36 — the preview scratch file is created with mktemp in TMPDIR, never a fixed /tmp path"
# STRUCTURAL pin, deliberately: the old code wrote `/tmp/.la-prev.$$`, which ignores TMPDIR and leaks the
# file when the tool is killed mid-preview. It cannot be observed from outside (the file is removed on
# every normal exit path), so the only honest assertion is about the shape of the code.
if grep -q 'mktemp "${TMPDIR:-/tmp}/la-prev' "$TOOL" && ! grep -q 'prev="/tmp/\.la-prev' "$TOOL"; then
  ok "T36 the preview scratch path is mktemp'd under TMPDIR"
else
  bad "T36 the preview uses a fixed /tmp scratch path" "$(grep -n 'la-prev' "$TOOL" | head -3)"
fi

echo "T37 — a transport that EXITS 0 BUT PRINTS NOTHING is UNMEASURED (exit 4), never absent, and \`ls\` is not an empty healthy inventory"
# The fail-open arm with no pin: `emit_box`/`show`'s `[ "$first" != "__OK__" ]`. Every other dead-box
# stub exits non-zero and is caught by the earlier `_src != 0` check, so this branch — the only protection
# when the channel answers successfully with no payload — was reached by no case and could be deleted with
# the suite still green (measured by review: 96/96 on that mutant).
out="$Q/out37"; mkdir -p "$out"
STUB_SILENT=1; export STUB_SILENT
run collect ci-cause --out "$out" > "$Q/t37.txt" 2>&1
rc=$?; unset STUB_SILENT
eq "T37 collect exit 4 (unmeasured, not absent)" "$rc" "4"
grep -q 'ABSENT-EVERYWHERE' "$Q/t37.txt" && bad "T37 claimed absent on a silent transport" "$(head -8 "$Q/t37.txt")" \
  || ok "T37 does not claim absent on a silent transport"
grep -q 'did not answer' "$Q/t37.txt" && ok "T37 says the exec did not answer" \
  || bad "T37 does not name the silent transport" "$(head -8 "$Q/t37.txt")"
[ -f "$out/pi-cell-1-ci-cause.md" ] && bad "T37 wrote an artifact from a silent transport" "$(ls "$out")" \
  || ok "T37 collected nothing from a silent transport"
STUB_SILENT=1; export STUB_SILENT
run ls > "$Q/t37b.txt" 2>&1
rc=$?; unset STUB_SILENT
eq "T37 ls exit 4 on a silent transport" "$rc" "4"
grep -q 'UNMEASURED' "$Q/t37b.txt" && ok "T37 ls says UNMEASURED" || bad "T37 ls rendered an empty inventory" "$(head -8 "$Q/t37b.txt")"

echo "T38 — a FAILED re-run leaves the PREVIOUS collection byte-identical (and no orphan) — the round-7 claim"
# The head commit claimed "a failed re-run no longer destroys the collection". It was true only for the
# absent/UNMEASURED path (no rows => no pull). Once a row IS found, `pull` wrote straight at the
# deterministic destination and unlinked it on EVERY failure path, so the one good copy from run 1 was
# deleted while `finish` printed "still holds the PREVIOUS collection". The box copy may already be gone
# after a recycle or a kill, so the orchestrator-side copy IS the durability this tool exists to provide.
out="$Q/out38"; mkdir -p "$out"
run collect epic-ledger --out "$out" > "$Q/t38a.txt" 2>&1
rc=$?
eq "T38 run 1 (complete) exit 0" "$rc" "0"
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T38 run 1 wrote the artifact" || bad "T38 run 1 wrote nothing" "$(ls "$out")"
sha1=$($SHA_CMD "$out/pi-cell-4-epic-ledger.md" 2>/dev/null | cut -d' ' -f1)
STUB_TRUNCATE=1; export STUB_TRUNCATE
run collect epic-ledger --out "$out" > "$Q/t38b.txt" 2>&1
rc=$?; unset STUB_TRUNCATE
eq "T38 run 2 (truncated) exit 5" "$rc" "5"
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T38 the previous artifact SURVIVES a failed re-pull" \
  || bad "T38 a failed re-pull DESTROYED the only copy" "$(ls -a "$out")"
sha2=$($SHA_CMD "$out/pi-cell-4-epic-ledger.md" 2>/dev/null | cut -d' ' -f1)
eq "T38 the surviving artifact is byte-identical" "$sha2" "$sha1"
# An orphan: a file this failed run staged and the committed index does not describe.
for f in "$out"/*; do
  case "$f" in *.lane-artifacts-index) continue ;; esac
  grep -qxF "pi-cell-4	$f" "$out/.lane-artifacts-index" 2>/dev/null && continue
  # Only the pre-existing artifact is legitimate here; anything else is an orphan from the failed run.
  [ "$(basename "$f")" = "pi-cell-4-epic-ledger.md" ] || bad "T38 orphan left by a failed run" "$f"
done
ls -a "$out" | grep -q '^\.la-stage\.' && bad "T38 staging directory leaked" "$(ls -a "$out")" \
  || ok "T38 no staging directory leaks"
# A partial run must also not leave a NEW artifact the index does not describe.
out="$Q/out38b"; mkdir -p "$out"
run collect p1-10515 --out "$out" > /dev/null 2>&1
STUB_TRUNCATE=1; export STUB_TRUNCATE
run collect .md --out "$out" > "$Q/t38c.txt" 2>&1
rc=$?; unset STUB_TRUNCATE
eq "T38 partial re-run exit 5" "$rc" "5"
[ -f "$out/pi-cell-4-p1-10515.md" ] && ok "T38 the pre-existing artifact survives a partial run" \
  || bad "T38 partial run destroyed the previous collection" "$(ls -a "$out")"
for f in "$out"/*; do
  case "$(basename "$f")" in pi-cell-4-p1-10515.md) continue ;; esac
  bad "T38 orphan from a PARTIAL run" "$f"
done

echo "T39 — a TAB in a filename does not corrupt the index, and a COMPLETE run still removes a stale artifact"
# The row was `label<TAB>path<TAB>size` with the path UNESCAPED, so a TAB in the name split it and
# `cut -f1,2` collapsed two different artifacts onto one key. Measured: after a complete run that
# collected only the TAB-named file, run 1's ordinary-named artifact SURVIVED — breaking the stale-file
# invariant T15 pins for every other name, while the index kept misreporting the row.
mk box-f 'has tab' "$(printf 'has\ttab.md')"
mk box-f 'has plain' has
# `cut -f2` must be the SIZE (numeric) and `cut -f3-` the whole path: path LAST, because it is the only
# field that can contain a TAB.
export STUB_BOXES="$STUB_BOXES
f=$Q/box-f"
out="$Q/out39"; mkdir -p "$out"
run collect has --out "$out" --box f > "$Q/t39a.txt" 2>&1
rc=$?
eq "T39 run 1 exit 0 (both artifacts collected)" "$rc" "0"
bad_rows=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  size_field="$(printf '%s' "$row" | cut -f2)"
  path_field="$(printf '%s' "$row" | cut -f3-)"
  case "$size_field" in ''|*[!0-9]*) bad_rows=$((bad_rows+1)) ;; esac
  case "$path_field" in "$Q/box-f/has"|"$Q/box-f/"*"") ;; *) bad_rows=$((bad_rows+1)) ;; esac
done < "$out/.lane-artifacts-index"
[ "$bad_rows" -eq 0 ] && ok "T39 every index row has a numeric size and an unsplit path" \
  || bad "T39 index row was split by the TAB" "$(cat -A "$out/.lane-artifacts-index" | head -3)"
# The TAB-bearing artifact is the one whose recorded path contains the TAB, and it must be present.
grep -q "$(printf 'has\ttab.md')" "$out/.lane-artifacts-index" 2>/dev/null \
  && ok "T39 the index records the TAB-bearing name" \
  || bad "T39 the TAB-bearing name is missing from the index" "$(cat -A "$out/.lane-artifacts-index")"
# A COMPLETE run that now collects only the ORDINARY name must delete the stale TAB-named artifact.
# This is the invariant T15 pins for ordinary names; it silently failed for a TAB name because both
# rows collapsed onto one key, so the stale file was never recognised as stale.
rm -f "$Q/box-f/$(printf 'has\ttab.md')"
run collect has --out "$out" --box f > "$Q/t39b.txt" 2>&1
rc=$?
eq "T39 run 2 (complete) exit 0" "$rc" "0"
if ls "$out" | grep -q "$(printf 'has\ttab')"; then
  bad "T39 a stale TAB-named artifact survived a COMPLETE run" "$(ls "$out")"
else
  ok "T39 a complete run removed the stale artifact it did not collect"
fi
[ -f "$out/f-has" ] && ok "T39 the freshly collected artifact is present" \
  || bad "T39 the run's own artifact is missing" "$(ls "$out")"
rm -rf "$Q/box-f"
unset STUB_BOXES; export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"

echo "T40 — an INCOMPLETE-coverage run must NOT replace the collection (a reached-because-some-box-answered exit 0 is not 'everything')"
# `collect` deliberately exits 0 when SOME boxes answered — T6 pins that, and the COVERAGE INCOMPLETE
# line discloses it. `finish` used to treat that exit 0 as "complete": it promoted and ran the stale
# sweep, which DELETED the unreachable box's only orchestrator-side copy while the usage text and the
# promote comment both promised a run that "cannot reach a box" leaves the previous collection untouched.
# That is the durability this tool exists for, destroyed by the case that most needs it.
out="$Q/out40"; mkdir -p "$out"
run collect .md --out "$out" > "$Q/t40a.txt" 2>&1
rc=$?
eq "T40 run 1 (all boxes) exit 0" "$rc" "0"
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T40 run 1 collected the pi-cell-4 artifact" \
  || bad "T40 run 1 collected nothing from pi-cell-4" "$(ls "$out")"
idx_before="$(cat "$out/.lane-artifacts-index" 2>/dev/null)"
STUB_DEAD="pi-cell-4"; run collect .md --out "$out" > "$Q/t40b.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T40 run 2 (pi-cell-4 dead) still exits 0 — the contract is unchanged" "$rc" "0"
grep -q 'COVERAGE INCOMPLETE' "$Q/t40b.txt" && ok "T40 run 2 discloses incomplete coverage" \
  || bad "T40 run 2 hid the coverage hole" "$(tail -5 "$Q/t40b.txt")"
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T40 the unreachable box's artifact SURVIVES" \
  || bad "T40 an incomplete run DELETED the unreachable box's only copy" "$(ls "$out")"
eq "T40 the index still describes the previous collection" "$(cat "$out/.lane-artifacts-index" 2>/dev/null)" "$idx_before"
grep -q "still holds the PREVIOUS collection — 1 requested box(es) were NOT measured" "$Q/t40b.txt" \
  && ok "T40 names the real reason (not 'ended at exit 0')" \
  || bad "T40 gives the wrong reason" "$(tail -4 "$Q/t40b.txt")"
ls -a "$out" | grep -q '^\.la-stage\.' && bad "T40 staging directory leaked" "$(ls -a "$out")" \
  || ok "T40 no staging directory leaks"

echo "T41 — a FAILED promotion is not a success: it must not claim the collection, and must not destroy the staged bytes"
# `mv` only warned, `rm -rf` then deleted the pulled bytes, the index was committed naming the file, and
# the run exited 0 — a false PASS with the only copy destroyed.
out="$Q/out41"; mkdir -p "$out/pi-cell-1-ci-cause.md"   # occupy the destination name with a DIRECTORY
run collect ci-cause --out "$out" > "$Q/t41.txt" 2>&1
rc=$?
eq "T41 exit 5 (not 0)" "$rc" "5"
grep -q 'could not promote' "$Q/t41.txt" && ok "T41 names the promotion failure" || bad "T41 silent failure" "$(tail -4 "$Q/t41.txt")"
grep -q 'were NOT measured\|was NOT replaced' "$Q/t41.txt" && ok "T41 does not claim the run succeeded" \
  || bad "T41 claimed success after a failed promotion" "$(tail -4 "$Q/t41.txt")"
# ⛔ AND IT MUST NOT CLAIM THE COLLECTION EITHER. The summary used to assert "N pulled into $outdir" on
# this very path (the predicate it keyed on was true), while `finish` said the opposite — two statements
# about one directory, both printed, disagreeing. A reviewer measured the pair and the suite stayed green,
# because the only guard was the `was NOT replaced` grep above, which `finish`'s own line satisfies.
grep -q 'pulled into' "$Q/t41.txt" \
  && bad "T41 still claims files were 'pulled into' a directory it refused to install them in" "$(grep 'pulled' "$Q/t41.txt")" \
  || ok "T41 makes NO placement claim on the summary line"
grep -q "now holds this run" "$Q/t41.txt" \
  && bad "T41 claims the directory now holds this run's collection" "$(grep 'holds' "$Q/t41.txt")" \
  || ok "T41 does not claim the collection was installed"
grep -q 'PARTIALLY' "$Q/t41.txt" \
  && bad "T41 says PARTIALLY when NOTHING landed" "$(grep 'PARTIALLY' "$Q/t41.txt")" \
  || ok "T41 says NOT replaced when nothing landed (the truthful arm)"
[ -f "$out/.lane-artifacts-index" ] && bad "T41 committed an index for files it did not promote" \
  || ok "T41 committed no index"
staged="$(find "$out" -maxdepth 2 -name 'pi-cell-1-ci-cause.md' -type f 2>/dev/null | head -1)"
[ -n "$staged" ] && ok "T41 the staged bytes are KEPT for recovery" \
  || bad "T41 a failed promotion DESTROYED the pulled bytes" "$(ls -aR "$out")"
# the trap must not reap the stage we deliberately kept
[ -n "$staged" ] && [ -d "$(dirname "$staged")" ] && ok "T41 the kept stage survives the exit trap" \
  || bad "T41 the exit trap reaped the stage it was told to keep" "$(ls -aR "$out")"

echo "T41b — a PARTIALLY promoted run says so, and it STOPS: a failure must not keep overwriting"
# `promote_stage` moves each file onto its final name as it goes. A failure on the SECOND file leaves the
# FIRST already installed — overwriting the previous collection's copy — while `finish` said "was NOT
# replaced". Measured by review: the first artifact held the NEW bytes while the published index still
# recorded the OLD size and path for it.
# ⛔ THREE FILES, AND THE FAILURE IN THE MIDDLE — `break` AND `continue` ARE INDISTINGUISHABLE OTHERWISE.
# The first version of this arm had two files with the failing destination sorting LAST, and a reviewer
# measured the regression it was supposed to pin (`break` → `continue`) staying green at 167/0: with
# nothing left to promote after the failure, stopping and continuing produce the same directory. The
# failing destination is therefore `...-ci-cause.md`, which is neither first nor last in the glob order
# (`-2.md` < `.md` < `0.md` in byte order — asserted by the two "landed"/"untouched" arms below), so the
# THIRD file is the evidence: with `continue` it is overwritten with this run's bytes, with `break` it
# keeps the previous collection's.
b41b="$Q/box-41b"; rm -rf "$b41b"; mkdir -p "$b41b"
printf 'OLD-BODY-one' > "$b41b/ci-cause-2.md"
printf 'OLD-BODY-two' > "$b41b/ci-cause.md"
printf 'OLD-BODY-three' > "$b41b/ci-cause0.md"
out="$Q/out41b"; mkdir -p "$out"
STUB_BOXES="pi-cell-1=$b41b"; export STUB_BOXES
run collect ci-cause --out "$out" --box pi-cell-1 > /dev/null 2>&1
rc=$?
eq "T41b run 1 (the previous collection) exit 0" "$rc" "0"
idx_before="$(cat "$out/.lane-artifacts-index" 2>/dev/null)"
printf 'NEW-BODY-one' > "$b41b/ci-cause-2.md"
printf 'NEW-BODY-two' > "$b41b/ci-cause.md"
printf 'NEW-BODY-three' > "$b41b/ci-cause0.md"
rm -f "$out/pi-cell-1-ci-cause.md"; mkdir -p "$out/pi-cell-1-ci-cause.md"
run collect ci-cause --out "$out" --box pi-cell-1 > "$Q/t41b.txt" 2>&1
rc=$?
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T41b exit 5 (not 0)" "$rc" "5"
grep -q 'could not promote pi-cell-1-ci-cause.md' "$Q/t41b.txt" \
  && ok "T41b names the file it could not promote" || bad "T41b did not name the failure" "$(tail -5 "$Q/t41b.txt")"
grep -q 'was PARTIALLY replaced' "$Q/t41b.txt" \
  && ok "T41b says PARTIALLY replaced — the message matches the directory" \
  || bad "T41b said the directory was untouched after installing a file into it" "$(tail -5 "$Q/t41b.txt")"
grep -q 'was NOT replaced' "$Q/t41b.txt" \
  && bad "T41b still claims 'was NOT replaced' while a file had already landed" "$(grep 'NOT replaced' "$Q/t41b.txt")" \
  || ok "T41b does not claim the directory was untouched"
grep -q 'the index was NOT updated' "$Q/t41b.txt" \
  && ok "T41b discloses that the index still describes the previous collection" \
  || bad "T41b left a stale index undisclosed" "$(tail -5 "$Q/t41b.txt")"
eq "T41b the landed file holds THIS run's bytes" "$(cat "$out/pi-cell-1-ci-cause-2.md" 2>/dev/null)" "NEW-BODY-one"
# ⛔ THE `break` EVIDENCE: the file AFTER the failure must still hold the PREVIOUS collection's bytes.
[ "$(cat "$out/pi-cell-1-ci-cause0.md" 2>/dev/null)" = 'OLD-BODY-three' ] \
  && ok "T41b STOPPED at the failure — the file after it was NOT overwritten" \
  || bad "T41b kept promoting after the failure and overwrote the next file's previous copy" "$(cat "$out/pi-cell-1-ci-cause0.md" 2>/dev/null)"
eq "T41b the index was NOT updated (it still describes the previous collection)" \
  "$(cat "$out/.lane-artifacts-index" 2>/dev/null)" "$idx_before"
grep -q "now holds this run" "$Q/t41b.txt" \
  && bad "T41b claimed the collection was installed after a partial promotion" "$(grep 'holds' "$Q/t41b.txt")" \
  || ok "T41b makes no 'installed' claim"
grep -q 'pulled into' "$Q/t41b.txt" \
  && bad "T41b claims placement on the summary line" "$(grep 'pulled' "$Q/t41b.txt")" \
  || ok "T41b makes no placement claim on the summary line"

echo "T42 — the stale sweep keys on the DESTINATION NAME, so a re-collected file is never deleted by its own run"
# Keying on the remote path made the sweep delete a file THIS RUN had just promoted whenever the same
# label+basename arrived under a different remote root — the run exited 0 with its own artifact GONE.
# The destination name (`<label>-<basename>`) is the file's actual identity in `--out`, and it is
export _bx_saved="$STUB_BOXES"
mkdir -p "$Q/box-r1" "$Q/box-r2"
printf 'first body' > "$Q/box-r1/ci-cause.md"
printf 'second body' > "$Q/box-r2/ci-cause.md"
out="$Q/out42"; mkdir -p "$out"
STUB_BOXES="pi-cell-1=$Q/box-r1"; export STUB_BOXES
run collect ci-cause --box pi-cell-1 --out "$out" > "$Q/t42a.txt" 2>&1
rc=$?
eq "T42 run 1 exit 0" "$rc" "0"
STUB_BOXES="pi-cell-1=$Q/box-r2"; export STUB_BOXES
run collect ci-cause --box pi-cell-1 --out "$out" > "$Q/t42b.txt" 2>&1
rc=$?
STUB_BOXES="$_bx_saved"; export STUB_BOXES
eq "T42 run 2 (same name, different root) exit 0" "$rc" "0"
[ -f "$out/pi-cell-1-ci-cause.md" ] && ok "T42 the file this run promoted SURVIVES its own stale sweep" \
  || bad "T42 a run deleted the artifact it had just collected" "$(ls -a "$out")"
grep -q 'second body' "$out/pi-cell-1-ci-cause.md" 2>/dev/null && ok "T42 it holds THIS run's bytes" \
  || bad "T42 holds the wrong bytes" "$(cat "$out/pi-cell-1-ci-cause.md" 2>/dev/null)"

echo "T43 — a SIGNALLED run leaves no staging directory behind (SIGKILL is stated, not claimed)"
# Nothing reaped the stage: both cleanup paths are reachable only from `finish`, so one directory leaked
# per killed run — the defect this file already records for the preview scratch. SIGKILL cannot be
# trapped, so this asserts the TERM/INT case and the comment records the SIGKILL residual honestly.
out="$Q/out43"; mkdir -p "$out"
STUB_SLEEP=5; export STUB_SLEEP
bash "$TOOL" collect ci-cause --out "$out" > "$Q/t43.txt" 2>&1 &
bg=$!
sleep 1
kill -TERM "$bg" 2>/dev/null
wait "$bg" 2>/dev/null
rc=$?
unset STUB_SLEEP
ls -a "$out" 2>/dev/null | grep -q '^\.la-stage\.' \
  && bad "T43 SIGTERM leaked a staging directory" "$(ls -a "$out")" \
  || ok "T43 SIGTERM leaves no staging directory"
# ⛔ THE SIGNAL MUST NOT REPORT SUCCESS. The first version of this case captured `rc` and never asserted
# it, so the defect it was written beside went unseen: the single `EXIT INT TERM` handler began `e=$?`,
# and bash defers an INT/TERM trap until the in-flight command returns — so `$?` was the status of the
# COMPLETED scan (0) and the run EXITED 0, which is this tool's code for "found", from a run that
# measured nothing. A test that observes a value and does not assert it pins nothing.
eq "T43 SIGTERM is not reported as success (143)" "$rc" "143"
# ⛔ ANCHORED ON THE INSTALL, not on `trap .*EXIT INT TERM`: the handler body contains its own
# `trap - EXIT INT TERM` disarm, so the old pattern was satisfied BY the disarm and stayed green even
# with the INT/TERM installs deleted entirely.
grep -q "trap 'trap - EXIT INT TERM; la_cleanup_stage; exit 143' TERM" "$TOOL" \
  && ok "T43 the tool installs a TERM handler that carries 143" \
  || bad "T43 no TERM handler carrying 143" "$(grep -n 'trap ' "$TOOL")"

echo "T44 — an EMPTY --out is a usage error, not a silent preview"
# `need_val` only checked ARITY, so `--out "$unset"` fell through to the `[ -n "$outdir" ]` gate and the
# run silently behaved as a preview-only invocation: exit 0, nothing written, no mention of --out. The
# caller believes DIR was written. Same defect the PR already fixed one option over for `--box`.
run collect ci-cause --out "" > "$Q/t44.txt" 2>&1
rc=$?
eq "T44 empty --out exits 64" "$rc" "64"
grep -q 'needs a non-empty directory' "$Q/t44.txt" && ok "T44 names the empty --out" \
  || bad "T44 silent on an empty --out" "$(head -3 "$Q/t44.txt")"

echo "T45 — a FRESH --out is told it was NOT written when the run is incomplete"
# With no PREVIOUS index, `finish` printed NOTHING: the `[ -f "$IDX" ]` guard suppressed the only line
# that would have said so. Silence is not a disclosure. And the summary line two lines earlier claimed
# ``$R_PULLED pulled into $outdir`` on a run that then DISCARDED the stage and left the directory empty.
out="$Q/out45"; mkdir -p "$out"
STUB_DEAD="pi-cell-3"; run collect ci-cause --out "$out" > "$Q/t45.txt" 2>&1
rc=$?; STUB_DEAD=""
eq "T45 exit 0 (the per-box contract is unchanged)" "$rc" "0"
# ⛔ ASSERT THE `finish` LINE SPECIFICALLY. The summary line also contains "was NOT written (run
# incomplete)", so a bare `was NOT written` grep was satisfied by the summary and stayed GREEN with the
# `finish` disclosure deleted entirely (measured: mutant m3 = 150 passed). Pin the finish-only wording.
grep -q "did not collect everything, so nothing was installed" "$Q/t45.txt" \
  && ok "T45 finish says plainly that the directory was not written" \
  || bad "T45 finish said nothing about the unwritten directory" "$(tail -4 "$Q/t45.txt")"
grep -q 'pulled into' "$Q/t45.txt" \
  && bad "T45 still claims files were 'pulled into' an empty directory" "$(grep 'pulled' "$Q/t45.txt")" \
  || ok "T45 does not claim a collection it discarded"
ls -A "$out" | grep -q . && bad "T45 the fresh --out is NOT empty" "$(ls -A "$out")" \
  || ok "T45 nothing was installed in the fresh --out"

echo "T46 — the scan does not match the tool's OWN scratch file"
# `mktemp` with no template creates the scratch in TMPDIR, which on a cell IS the scanned root
# (ATIF_ROOT = /tmp), BEFORE `find` runs — and `find` was never told to exclude it. So the documented
# full sweep always matched the scratch, whose pull then failed (it is deleted by then): the run ended
# PULL-FAILED at exit 5 and collected nothing. Reproduced by making TMPDIR and the scanned root the
# same directory, which is the production relationship.
b46="$Q/box-46"; rm -rf "$b46"; mkdir -p "$b46"; printf 'sole artifact' > "$b46/ci-cause.md"
out="$Q/out46"; mkdir -p "$out"
LANE_ARTIFACT_ROOT="$b46" TMPDIR="$b46" STUB_BOXES="pi-cell-1=$b46" \
  run collect '*' --out "$out" --box pi-cell-1 > "$Q/t46.txt" 2>&1
rc=$?
eq "T46 exit 0 (the sweep is not poisoned by its own scratch)" "$rc" "0"
grep -q "\.lane-artifacts\." "$Q/t46.txt" \
  && bad "T46 the scratch file appears in the scan" "$(grep 'lane-artifacts' "$Q/t46.txt")" \
  || ok "T46 the scratch file is excluded from the scan"
eq "T46 exactly one row matched" "$(grep -c 'bytes,' "$Q/t46.txt")" "1"
[ -f "$out/pi-cell-1-ci-cause.md" ] && ok "T46 the real artifact was collected" \
  || bad "T46 collected nothing" "$(ls -A "$out")"

# put the shared universe back for anything after this
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"

echo "T47 — a filename ENDING in a TAB is collected from the right file"
# `IFS=<tab> read -r sz mt p` treats TAB as IFS WHITESPACE, so it strips TABs at the END of the last
# field: a file named `has<TAB>` was read back as `$Q/box-47/has` — a DIFFERENT file — which was pulled
# and written as the artifact at exit 0 while the matched artifact was never collected. This is T28/T39's
# class relocated from an interior TAB to a trailing one.
b47="$Q/box-47"; rm -rf "$b47"; mkdir -p "$b47"
printf 'TRAILING-TAB-BODY' > "$b47/has$(printf '\t')"
printf 'DECOY-BODY' > "$b47/has"
out="$Q/out47"; mkdir -p "$out"
STUB_BOXES="pi-cell-1=$b47"; export STUB_BOXES
run collect 'has' --out "$out" --box pi-cell-1 > "$Q/t47.txt" 2>&1
rc=$?
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T47 exit 0" "$rc" "0"
# The row for the TAB-named file must carry the WHOLE name, so its destination keeps the TAB.
f47="$out/pi-cell-1-has$(printf '\t')"
[ -f "$f47" ] && ok "T47 the TAB-named file was collected under its real name" \
  || bad "T47 the trailing TAB was truncated (wrong file pulled or none)" "$(ls -A "$out")"
[ -f "$f47" ] && eq "T47 it holds the TAB-named file's bytes" "$(cat "$f47")" "TRAILING-TAB-BODY"

echo "T48 — a filename ENDING in a NEWLINE ABSTAINS: the listing is not a map, so nothing is graded"
# The third form of T28/T47's class, and the one that was NOT caught: a path ending in a newline emits its
# record plus an EMPTY continuation line. A command substitution strips trailing newlines and
# `grep -v '^$'` removes interior empties, so the head row (`<size>\t<mtime>\t<path-minus-its-newline>`)
# parsed CLEANLY — a numeric size, a real path — and was accepted as a measurement of a DIFFERENT file.
# Measured on the real `find` path with `has` = DECOY and `has<newline>` = the real artifact: the decoy was
# pulled, written as the artifact, and the run exited 0, while the matched artifact was never collected
# and no warning was emitted. The size guard cannot catch this one: the size IS numeric.
# The sentinel's row COUNT is the fix — the box sent two lines, the caller could parse one, so the map
# split and the box must ABSTAIN (exit 4) rather than grade a short list as the truth.
b48="$Q/box-48"; rm -rf "$b48"; mkdir -p "$b48"
printf 'DECOY-BODY' > "$b48/has"
printf 'REAL-BODY' > "$b48/has"$'\n'
out="$Q/out48"; mkdir -p "$out"
STUB_BOXES="pi-cell-1=$b48"; export STUB_BOXES
run collect 'has' --out "$out" --box pi-cell-1 > "$Q/t48.txt" 2>&1
rc=$?
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T48 exit 4 (UNMEASURED — a split listing is not a result)" "$rc" "4"
grep -q 'record SPLIT' "$Q/t48.txt" \
  && ok "T48 names the split record (not a generic failure)" \
  || bad "T48 abstained without naming why" "$(tail -4 "$Q/t48.txt")"
ls -A "$out" | grep -q . \
  && bad "T48 installed something into --out from a listing it could not read" "$(ls -A "$out")" \
  || ok "T48 installed NOTHING (no decoy written under the artifact's name)"
grep -q 'DECOY-BODY' "$Q/t48.txt" \
  && bad "T48 rendered the DECOY's bytes as the artifact's content" "$(grep -n 'DECOY' "$Q/t48.txt")" \
  || ok "T48 did not present the decoy as the matched artifact"

echo "T49 — the INVENTORY verb has the same split-record hole: a name ending in a newline must ABSTAIN"
# Fix C was applied to `collect`/`logs` (`emit_box`) and mirrored in `ls` (`show`) — but only the
# `collect` half had an arm, and a reviewer measured the `ls` guard being deleted with the suite still
# green at 167/0. `ls` is the verb an operator uses to DISCOVER what exists, so an uncertified map there
# is the same class: the head row of a split record names a DIFFERENT, shorter path and the inventory
# presents it as an entry.
b49="$Q/box-49"; rm -rf "$b49"; mkdir -p "$b49"
printf 'DECOY-BODY' > "$b49/has.md"
printf 'REAL-BODY' > "$b49/has.md"$'\n'
STUB_BOXES="pi-cell-1=$b49"; export STUB_BOXES
run ls --box pi-cell-1 > "$Q/t49.txt" 2>&1
rc=$?
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T49 exit 4 (UNMEASURED — a split inventory is not an inventory)" "$rc" "4"
grep -q 'sent .* row line(s), .* parsed' "$Q/t49.txt" \
  && ok "T49 names the split record (sent vs parsed)" \
  || bad "T49 abstained without naming why" "$(tail -4 "$Q/t49.txt")"
n49="$(grep -c 'has\.md' "$Q/t49.txt")"
[ "$n49" -eq 0 ] \
  && ok "T49 printed no inventory row for a listing it could not certify" \
  || bad "T49 PRINTED the decoy path as an inventory entry" "$(grep 'has\.md' "$Q/t49.txt" | head -3)"

echo "T50 — the no-\`-printf\` FALLBACK arm must not grade a split listing either"
# The fallback exists for "a mac, or a stripped image": it builds the rows by re-reading raw path LINES,
# so a name ending in a newline contributes its row PLUS an empty one. BOTH count checks agree there (the
# box and the caller see the same split lines), so the sentinel cross-check is structurally incapable of
# firing — a ROW-SHAPE guard is what that arm needs. A reviewer measured `ls` printing the decoy twice at
# exit 0 on a box whose `find` refuses `-printf`, while the `-printf` arm abstained correctly.
REAL_FIND="$(command -v find)"
b50="$Q/box-50"; rm -rf "$b50"; mkdir -p "$b50"
printf 'DECOY-BODY' > "$b50/has.md"
printf 'REAL-BODY' > "$b50/has.md"$'\n'
printf 'plain artifact' > "$b50/plain.md"
mkdir -p "$Q/nofind"
cat > "$Q/nofind/find" <<NOFIND
#!/usr/bin/env bash
# A find WITHOUT -printf (BSD/busybox shape). Only the probe and the scan are refused; the fallback's own
# plain \`find > list\` must still reach the real binary, or the arm tests nothing at all.
for a in "\$@"; do case "\$a" in -printf*) exit 1 ;; esac; done
exec "$REAL_FIND" "\$@"
NOFIND
chmod +x "$Q/nofind/find"
STUB_BOXES="pi-cell-1=$b50"; export STUB_BOXES
# `export`, not a command prefix: `run` is a FUNCTION, and a prefix assignment is not guaranteed to reach
# the `bash "$TOOL"` it spawns — an arm that silently ran the REAL find would pass for the wrong reason.
_saved_path="$PATH"
export PATH="$Q/nofind:$PATH"
run ls --box pi-cell-1 > "$Q/t50.txt" 2>&1
rc=$?
export PATH="$_saved_path"
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T50 the FALLBACK arm abstains on a split listing (exit 4)" "$rc" "4"
if grep -q 'has\.md' "$Q/t50.txt"; then
  bad "T50 the fallback still printed an inventory row it could not certify" "$(grep 'has\.md' "$Q/t50.txt" | head -3)"
else
  ok "T50 the fallback printed no uncertified inventory row"
fi
# ⛔ AND THE FALLBACK MUST STILL WORK ON A CLEAN LISTING — an abstention that fires always is not a guard.
b50b="$Q/box-50b"; rm -rf "$b50b"; mkdir -p "$b50b"
printf 'plain artifact' > "$b50b/plain.md"
STUB_BOXES="pi-cell-1=$b50b"; export STUB_BOXES
export PATH="$Q/nofind:$PATH"
run ls --box pi-cell-1 > "$Q/t50b.txt" 2>&1
rc=$?
export PATH="$_saved_path"
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T50b the FALLBACK arm still inventories a clean listing (exit 0)" "$rc" "0"
grep -q 'plain\.md' "$Q/t50b.txt" \
  && ok "T50b the clean artifact is listed" \
  || bad "T50b the fallback listed nothing" "$(tail -4 "$Q/t50b.txt")"

echo "T51 — a NUMERIC tail line is a SPLIT record too, and must ABSTAIN"
# The guard that only checked 'is the size numeric?' shipped a false PASS: a phantom path, the decoy pulled `has<newline>2026` = the artifact (10 B).
# The record splits into `9\t<mt>\t/root/has` and `2026`. BOTH lines parse as rows under a numeric-size-only
# guard — `2026` is numeric and its "path" is non-empty — so the tool reported a phantom path at exit 0,
# never collected the artifact, and pulled the decoy twice. The count check cannot see it (box sends 2,
# caller parses 2), so this arm is the ONLY thing that pins the shape guard.
b51="$Q/box-51"; rm -rf "$b51"; mkdir -p "$b51"
printf 'DECOY-BODY' > "$b51/has"
printf 'REAL-BODY!' > "$b51/has"$'\n'"2026"
out="$Q/out51"; mkdir -p "$out"
STUB_BOXES="pi-cell-1=$b51"; export STUB_BOXES
export STUB_BAD_SIZE_NUM=1
run collect 'has' --out "$out" --box pi-cell-1 > "$Q/t51.txt" 2>&1
rc=$?
unset STUB_BAD_SIZE_NUM
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T51 exit 4 (UNMEASURED — a numeric split row is not a measurement)" "$rc" "4"
grep -q 'UNMEASURED' "$Q/t51.txt" \
  && ok "T51 abstained" \
  || bad "T51 did not abstain on a numeric split row" "$(tail -4 "$Q/t51.txt")"
grep -qE '── .*  2026  \(' "$Q/t51.txt" \
  && bad "T51 reported a phantom path row" "$(grep -E '2026' "$Q/t51.txt" | head -2)" \
  || ok "T51 reported no phantom row for a path that does not exist"
grep -q 'file(s) collected from' "$Q/t51.txt" \
  && bad "T51 claimed a collection from a listing it could not certify" "$(grep 'collected from' "$Q/t51.txt")" \
  || ok "T51 claimed no collection"
ls -A "$out" | grep -q . \
  && bad "T51 installed something from a listing it could not certify" "$(ls -A "$out")" \
  || ok "T51 installed NOTHING from the split listing"

# ⛔ AND THE GUARD MUST NOT FIRE ON A REAL ROW — an abstention that always fires is not a guard.
b51b="$Q/box-51b"; rm -rf "$b51b"; mkdir -p "$b51b"
printf 'REAL-BODY!' > "$b51b/has.md"
STUB_BOXES="pi-cell-1=$b51b"; export STUB_BOXES
run ls --box pi-cell-1 > "$Q/t51b.txt" 2>&1
rc=$?
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T51b a NORMAL row still inventories (exit 0)" "$rc" "0"
grep -q 'has\.md' "$Q/t51b.txt" \
  && ok "T51b the ordinary artifact is still listed" \
  || bad "T51b the shape guard swallowed a legitimate row" "$(tail -4 "$Q/t51b.txt")"

echo "T52 — \`ls\` REFUSES --out instead of silently discarding it"
# `--out` was parsed for every verb and read by none of `ls`'s branches: exit 0, directory never created,
# no warning — a caller asking for a durable inventory got a success code and nothing. Same class as the
# `--out ""` arm; the usage text never offered --out for `ls`.
b52="$Q/box-52"; rm -rf "$b52"; mkdir -p "$b52"
printf 'REAL-BODY!' > "$b52/thing.md"
STUB_BOXES="pi-cell-1=$b52"; export STUB_BOXES
run ls --box pi-cell-1 --out "$Q/out52" > "$Q/t52.txt" 2>&1
rc=$?
export STUB_BOXES="pi-cell-1=$Q/box-a
pi-cell-3=$Q/box-b
pi-cell-4=$Q/box-c"
eq "T52 exit 64 (usage error, not a silent success)" "$rc" "64"
grep -q 'ls takes no --out' "$Q/t52.txt" \
  && ok "T52 names the option it refused" \
  || bad "T52 refused without naming why" "$(head -3 "$Q/t52.txt")"
[ -d "$Q/out52" ] \
  && bad "T52 created the --out directory it refused" "$(ls -A "$Q/out52")" \
  || ok "T52 wrote nothing"

echo
printf 'lane-artifacts.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
