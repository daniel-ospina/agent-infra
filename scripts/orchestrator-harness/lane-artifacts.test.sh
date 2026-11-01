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
  # STUB_BAD_SIZE: a row whose size column is not numeric — what a TAB/newline in a filename produces.
  if [ -n "${STUB_BAD_SIZE:-}" ] && [ "${args[2]:-}" != "${args[2]%%find *}" ]; then
    printf '__OK__\n%s/has\ttab.md\t2026-01-01T00:00:00\n' "$root"; exit 0
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
eq "T1 byte-exact (sha256)" "$(shasum -a 256 < "$out/pi-cell-1-ci-cause.md" | cut -d' ' -f1)" \
   "$(shasum -a 256 < "$Q/box-a/ci-cause.md" | cut -d' ' -f1)"

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

echo "T7 — a KILLED writer's artifact is collectable (the case that matters most)"
# Asserted STRUCTURALLY: the fixture file is written and then nothing ever touches it again, and
# collection is a PULL from the orchestrator side — so it cannot depend on the writer surviving,
# cooperating, or running any code after the write. The live proof (a process SIGKILLed, then its file
# collected over a real `cmux vm exec`) needs a real box and is quoted in the PR body, not asserted here.
out="$Q/out7"; mkdir -p "$out"
run collect killproof --out "$out" --lines 2 > "$Q/t7.txt" 2>&1
grep -q 'SIGKILLed' "$out/pi-cell-4-killproof-lane.md" 2>/dev/null && ok "T7 killed writer's file collected" \
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
# The .md scan succeeded, so the box is REACHED and the verb exits 0; the point is that the failed
# .log scan is NAMED rather than silently rendering as "this box has no lane logs".
grep -q 'UNMEASURED(log' "$Q/t8b.txt" && ok "T8b names the failed log scan" || bad "T8b names it" "$(head -10 "$Q/t8b.txt")"

echo "T14 — --since 30m is a USAGE error (exit 64), never a false ABSENT"
run collect ci-cause --since 30m > "$Q/t14.txt" 2>&1
rc=$?
eq "T14 exit 64" "$rc" "64"
grep -q '^ABSENT-EVERYWHERE' "$Q/t14.txt" && bad "T14 must not claim absent" "$(cat "$Q/t14.txt")" \
  || ok "T14 does not claim absent on a bad duration"

echo "T15 — a reused --out does not leave the previous run's artifacts beside this run's index"
out="$Q/out15"; mkdir -p "$out"
run collect epic-ledger --out "$out" >/dev/null 2>&1
[ -f "$out/pi-cell-4-epic-ledger.md" ] && ok "T15 run 1 wrote its file" || bad "T15 run 1" "$(ls "$out")"
STUB_DEAD="pi-cell-1 pi-cell-3 pi-cell-4"; run collect epic-ledger --out "$out" >/dev/null 2>&1
STUB_DEAD=""
ls "$out" | grep -q 'pi-cell-4-epic-ledger.md' && bad "T15 stale artifact survived run 2" "$(ls "$out")" \
  || ok "T15 stale artifact from run 1 removed"

echo "T16 — the ABSENT message echoes the --since it actually applied"
run collect no-such-file --since 60 > "$Q/t16.txt" 2>&1
rc=$?
eq "T16 exit 3" "$rc" "3"
grep -q -- '-mmin -60' "$Q/t16.txt" && ok "T16 echoes the mmin filter" || bad "T16 echoes --since" "$(cat "$Q/t16.txt")"
grep -q 'in the last 60 minutes' "$Q/t16.txt" && ok "T16 says the window in words" || bad "T16 window wording" "$(cat "$Q/t16.txt")"

echo "T17 — an unparseable scan row ABSTAINS instead of producing a wrong verdict"
# A TAB/newline in a filename splits the TAB-delimited fields, so the size column lands on the tail of
# the name. The old code carried that into a pull: a bogus path, then PULL-FAILED — a wrong verdict.
out="$Q/out17"; mkdir -p "$out"
STUB_BAD_SIZE=1; export STUB_BAD_SIZE
run collect .md --out "$out" > "$Q/t17.txt" 2>&1
rc=$?; unset STUB_BAD_SIZE
eq "T17 exit 4 (abstain)" "$rc" "4"
grep -q 'unparseable scan row' "$Q/t17.txt" && ok "T17 names the unparseable row" || bad "T17 names it" "$(head -6 "$Q/t17.txt")"

echo "T18 — the transfer status is a PREFIX: a tail-cut still reports SIZE MISMATCH"
# This is the discrimination the round-2 fix never had: with the marker as a SUFFIX, cutting the tail
# destroys it and the tool says "remote exit ?" instead of the size mismatch it actually detected.
out="$Q/out18"; mkdir -p "$out"
STUB_CUT_TAIL=1; export STUB_CUT_TAIL
run collect epic-ledger --out "$out" > "$Q/t18.txt" 2>&1
rc=$?; unset STUB_CUT_TAIL
[ "$rc" -ne 0 ] && ok "T18 fails closed (exit $rc)" || bad "T18 must not report success" "$(cat "$Q/t18.txt")"
grep -qi 'SIZE MISMATCH' "$Q/t18.txt" && ok "T18 names the size mismatch (prefix marker survived)" \
  || bad "T18 should name SIZE MISMATCH, not a lost status" "$(cat "$Q/t18.txt" | tail -4)"

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

echo
printf 'lane-artifacts.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
