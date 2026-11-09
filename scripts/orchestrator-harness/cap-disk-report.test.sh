#!/usr/bin/env bash
# cap-disk-report.test.sh — the `[cap]` line's DISK figure and one lane's COST (agent-infra#2159).
#
# THE DEFECT THIS PINS. Measured on a cell on 2026-10-19: six LIVE worktrees at ~1.1 GB each on a
# 32 GB disk, 179 MB free — while the reaper ran and passed and the controller's capacity line read
#
#     [cap] load=… lanes=8/20 max_lanes=20 zombie=… mem_avail=…M/512M swap_free=…M/600M …
#
# with NO disk figure and NO per-lane cost anywhere on it. The box therefore ADVERTISED capacity it
# did not have, an orchestrator acting on that line filled it, and four `merge-*` lanes died with
# 0-BYTE logs — the log write itself failed, so the dispatch looked quiet rather than broken.
#
# ⛔ THE DATUM WAS NEVER MISSING. `spawn-gate.sh` measures free space and one lane's cost on every
# admission and appends both to `state/disk.tsv`; nothing printed them on the line an operator reads.
# So the fix is a REPORT, and this suite pins the three properties that make a report trustworthy:
#
#   1. ONE MEASUREMENT — the figure on `[cap]` comes from the gate's own `disk_admit` (via
#      `--disk-report`), never from a second `df` in the controller. A gate that measures twice is a
#      gate whose report can disagree with its verdict (agent-infra#2721's own defect).
#   2. NO FABRICATION — an unreadable probe reports `?` and `unknown`, never `0` (which reads as
#      "full") and never a number nobody took (the "instrument reports a number it did not take"
#      class this repo names everywhere).
#   3. NEVER SILENT — a box whose `spawn-gate.sh` is missing or predates the verb says so ONCE per
#      cycle. That is a deploy-skew disclosure, not a capacity change: the ENFORCING gate is
#      unchanged, and the controller must not refuse to run over a missing log field.
#
# ⛔ EVERY READING IS STUBBED (`df` on PATH, and `SPAWN_GATE_SH` for the controller block). An arm
# that used THIS host's free space would be green on a roomy box and red on a full one — a test of
# the host rather than of the gate, the defect `disk-admission.test.sh` records for its own early
# stub. The `df` stub is POSIX `df -Pk`-shaped: a header row, then the 4th column is the free 1 KiB
# blocks, set by `FAKE_DF_AVAIL_MB`.
#
# ⛔ IT IS A REPORT, NOT A FIFTH GATE. `orch-loop.sh`'s gate vector records the decision in its own
# words — "DISK is not repeated here because the spawn point (spawn-gate.sh) is its ONE
# implementation" — so this suite asserts a report and deliberately asserts NO refusal arm: the
# refusal is the pre-start seam's (`disk_admit` → 77) and the spawn point's (`DISK-NOHEADROOM`), both
# pinned by their own suites. A controller-side disk gate would be a second disk gate, which
# agent-infra#1178 forbids and #3395 already settled.
#
# Run:  bash scripts/orchestrator-harness/cap-disk-report.test.sh
set -uo pipefail

bash -n "$0" || { echo "FATAL: the suite itself does not parse (see above)" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/spawn-gate.sh"
LOOP="$HERE/orch-loop.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
ck()   { local msg="$1" rc="$2"; if [ "$rc" -eq 0 ]; then ok "$msg"; else bad "$msg"; fi; }
eq()   { local msg="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok "$msg"; else bad "$msg (want '$want', got '$got')"; fi; }
has()  { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 (missing '$1' in '${2:0:400}')" ;; esac; }
hasnt(){ case "$2" in *"$1"*) bad "$3 (unexpectedly found '$1')" ;; *) ok "$3" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cap-disk-report.XXXXXX")" || { echo "FATAL: no temp dir" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

[ -f "$GATE" ] || { echo "FATAL: no spawn-gate.sh beside this suite" >&2; exit 2; }
[ -f "$LOOP" ] || { echo "FATAL: no orch-loop.sh beside this suite" >&2; exit 2; }

# ⛔ HERMETIC AGAINST THE AMBIENT OVERRIDES. The arms below assert the SHIPPED terms (350 / 6,144 /
# 4x the floor), so an operator's `DISK_LANE_SELF_MB=1024` — the very remedy the gate's refusal text
# recommends — would turn this suite red on a healthy box. Cleared here; the arms that MEAN to vary
# them pass them explicitly.
export DISK_LANE_TREE_MB= DISK_LANE_SELF_MB= DISK_LANE_RESERVE_MB= DISK_MIN_FREE_MB= MIN_FREE_MB=
export DISK_ADMIT_VERBOSE=

# ── the `df` stubs ───────────────────────────────────────────────────────────────────────────────
# Two directories, never one PATH prefix: "readable, N MB" and "UNREADABLE" must not share state.
mkdir -p "$T/bin-ok" "$T/bin-dead"
printf '#!/bin/sh\navail=$(( ${FAKE_DF_AVAIL_MB:-0} * 1024 ))\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "fake 9999999 0 $avail 1%% /"\n' > "$T/bin-ok/df"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-dead/df"
chmod +x "$T/bin-ok/df" "$T/bin-dead/df"

# ── the REPORT verb, driven through the shipped binary ───────────────────────────────────────────
# report <bin-dir> <avail-mb> [env assignments…] -> the one line on stdout, then rc on the next line
report() {
    local bindir="$1" avail="$2"; shift 2
    ( env PATH="$bindir:$PATH" FAKE_DF_AVAIL_MB="$avail" DISK_BOX=cell-test "$@" \
        bash "$GATE" --disk-report "$T" 2>&1; printf '\nrc=%s\n' "$?" )
}
# field <n> <report-output> — the nth whitespace-separated field of the report's FIRST line
field() { printf '%s' "$2" | head -1 | awk -v n="$1" '{ print $n }'; }
# kv <key> <report-output> — the value of `<key>=` on the first line (e.g. tree=350)
kv() { printf '%s' "$2" | head -1 | awk -v k="$1=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }'; }

echo "── cap-disk-report.test.sh (agent-infra#2159) ────────────────────────────────────────"

# ── A) THE VERB: one parseable line, in the documented positions ────────────────────────────────
echo
echo "── A) the verb: [disk-report] <STATE> <free|?> <need> … ──"
R="$(report "$T/bin-ok" 999999)"
eq "A1 the tag is '[disk-report]' (field 1) — the row is greppable and cannot be confused with the human verdict" "[disk-report]" "$(field 1 "$R")"
eq "A2 the STATE is field 2" "ADMITTED" "$(field 2 "$R")"
eq "A3 free is field 3, in MEBIBYTES, from the one df probe" "999999" "$(field 3 "$R")"
eq "A4 need is field 4 — one lane's admission bound" "8144" "$(field 4 "$R")"
eq "A5 the verb exits 0 on a produced report" "rc=0" "$(printf '%s' "$R" | tail -1)"

# ⛔ THE ARITHMETIC IS CHECKABLE FROM THE LINE ALONE (the refusal text's own rule: a number an operator
# cannot re-derive is a number an operator has to trust). need == max(tree, self) + reserve, using the
# terms the SAME line prints.
tree="$(kv tree "$R")"; self="$(kv self "$R")"; reserve="$(kv reserve "$R")"
[ -n "$tree" ] && [ -n "$self" ] && [ -n "$reserve" ] && [ "$(field 4 "$R")" = "$(( (tree > self ? tree : self) + reserve ))" ]; rc=$?
ck "A6 need == max(tree=$tree, self=$self) + reserve=$reserve — printed terms re-derive the printed bound" $rc
eq "A7 the shipped terms are the gate's own constants (tree=350 self=6144 reserve=2000 = 4x the 500 MB floor)" "350/6144/2000" "$tree/$self/$reserve"

# ── B) BELOW the bound: the verdict changes, the rc does NOT ────────────────────────────────────
# ⛔ A REPORT IS NOT A GATE. If this verb exited non-zero on a refusal, a caller would read it as
# admission and a caller that merely PRINTS capacity would inherit a refusal it never asked for. The
# verdict is field 2; the exit code is "the report was produced".
echo
echo "── B) below the bound: REFUSED-DISK, rc 0, and the numbers still printed ──"
R="$(report "$T/bin-ok" 3584)"
eq "B1 the state names the arm that answered" "REFUSED-DISK" "$(field 2 "$R")"
eq "B2 the free figure is the measured one (3,584 MB — the reading the #1852 record quotes from cell-3)" "3584" "$(field 3 "$R")"
eq "B3 the bound is unchanged by the refusal" "8144" "$(field 4 "$R")"
eq "B4 a refusal is a PRODUCED report, so rc is still 0 (a report is not a gate)" "rc=0" "$(printf '%s' "$R" | tail -1)"

# ── C) an operator's own terms are the ones printed ─────────────────────────────────────────────
echo
echo "── C) an operator-stated cost is honoured and PRINTED (the remedy the refusal recommends) ──"
R="$(report "$T/bin-ok" 4000 DISK_LANE_SELF_MB=1024)"
eq "C1 need follows the stated self (max(350,1024) + 2000)" "3024" "$(field 4 "$R")"
eq "C2 the state admits on it — the same fixture that was refused at the default" "ADMITTED" "$(field 2 "$R")"
eq "C3 and the line PRINTS the term it used, so the number is re-derivable" "1024" "$(kv self "$R")"

# ── D) UNREADABLE is `?`, never 0 ───────────────────────────────────────────────────────────────
echo
echo "── D) an unreadable probe is '?' — never 0 (which reads as 'full'), never a fabricated number ──"
R="$(report "$T/bin-dead" 0)"
eq "D1 the state separates 'could not measure' from 'no room'" "REFUSED-UNKNOWN" "$(field 2 "$R")"
eq "D2 free is '?'" "?" "$(field 3 "$R")"
eq "D3 the bound is STILL printed (the terms need no df)" "8144" "$(field 4 "$R")"
hasnt "0 " "$(field 3 "$R") " "D4 an unreadable reading is not coerced to 0"

# ── E) ONE MEASUREMENT: the report and the admission are the same numbers ───────────────────────
# This is the property that makes the `[cap]` figure trustworthy: `disk_report` calls `disk_admit`, it
# does not re-measure. Both are driven on the SAME fixture here, so a future re-derivation that
# drifted (a second `df`, a copied literal) reddens this arm instead of printing a second answer.
echo
echo "── E) the report and the admission are ONE measurement ──"
ADMIT="$( env PATH="$T/bin-ok:$PATH" FAKE_DF_AVAIL_MB=3584 DISK_BOX=cell-test bash "$GATE" --disk-admit "$T" 2>&1 )"
R="$(report "$T/bin-ok" 3584)"
has "free_mb=3584" "$ADMIT" "E1 the admission line carries the raw free figure"
has "need_mb=8144" "$ADMIT" "E2 the admission line carries the same bound"
eq "E3 the REPORT's free is that figure" "3584" "$(field 3 "$R")"
eq "E4 the REPORT's need is that bound" "8144" "$(field 4 "$R")"
eq "E5 the box identity is the same on both surfaces" "$(printf '%s' "$ADMIT" | sed -n 's/.*box=\([^ ;)]*\).*/\1/p' | head -1)" "$(kv box "$R")"

# ── F) usage: a report with no target is a usage error, not an empty report ─────────────────────
echo
echo "── F) usage ──"
U="$(bash "$GATE" --disk-report 2>&1)"; urc=$?
eq "F1 no target is rc 64 (a report about nothing is not a report)" "64" "$urc"
has "target path is required" "$U" "F2 and it says what is missing"
H="$(bash "$GATE" --disk-report --help 2>&1)"; hrc=$?
eq "F3 --help exits 0" "0" "$hrc"
has "usage: spawn-gate.sh --disk-report" "$H" "F4 --help names the verb and its one-line format"

# ── G) THE `[cap]` BLOCK, extracted from the loop and driven ────────────────────────────────────
# ⛔ EXTRACTED AND DRIVEN, not grepped: a tripwire that only sees the words `disk_free=` in the file
# is satisfied by a line that prints a variable nothing ever sets. The markers are the seam.
echo
echo "── G) orch-loop.sh's [capdisk] block, driven against a fixture gate ──"
BLOCK="$T/capdisk.sh"
awk '/# \[capdisk:begin\]/ { f = 1 } f { print } /# \[capdisk:end\]/ { f = 0 }' "$LOOP" > "$BLOCK"
[ -s "$BLOCK" ] || { bad "G0 the [capdisk:begin]/[capdisk:end] markers are absent from orch-loop.sh — the block cannot be driven"; BLOCK=""; }
if [ -n "$BLOCK" ]; then
  ok "G0 the [capdisk] block is marked and extractable ($(wc -l < "$BLOCK" | tr -d ' ') lines)"

  # a fixture gate: prints whatever FIXTURE_ROW holds, exits FIXTURE_RC
  mkdir -p "$T/fixture"
  printf '#!/bin/sh\nprintf "%%s\\n" "${FIXTURE_ROW:-}"\nexit "${FIXTURE_RC:-0}"\n' > "$T/fixture/spawn-gate.sh"
  chmod +x "$T/fixture/spawn-gate.sh"

  # drive <gate-path> -> "src|state|free|need|headroom"; the fixture's row/rc come from the
  # caller's FIXTURE_ROW / FIXTURE_RC, and the loop's own diagnostics land in $T/drive.log
  drive() {
      local gate="${1:-}"
      : > "$T/drive.log"
      ( set -u
        SPAWN_GATE_SH="$gate"; REPO="$T"; LOG="$T/drive.log"
        is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
        . "$BLOCK"
        printf '%s|%s|%s|%s|%s\n' "${DISK_SRC:-unset}" "${DISK_STATE:-?}" "${DISK_FREE_MB:-}" "${DISK_NEED_MB:-}" "${DISK_HEADROOM:-?}"
      ) 2>/dev/null
  }
  G="$(FIXTURE_ROW='[disk-report] ADMITTED 9000 8144 tree=350 self=6144 reserve=2000 box=b target=/x' FIXTURE_RC=0 drive "$T/fixture/spawn-gate.sh")"
  eq "G1 an ADMITTED report lands on the line fields" "report|ADMITTED|9000|8144|ok" "$G"
  G="$(FIXTURE_ROW='[disk-report] REFUSED-DISK 179 8144 tree=350 self=6144 reserve=2000 box=b target=/x' FIXTURE_RC=0 drive "$T/fixture/spawn-gate.sh")"
  eq "G2 free BELOW the bound reports headroom=no — the 179 MB cell reads as 'no' and not as a capacity" "report|REFUSED-DISK|179|8144|no" "$G"
  G="$(FIXTURE_ROW='[disk-report] ADMITTED 8144 8144 tree=350 self=6144 reserve=2000 box=b target=/x' FIXTURE_RC=0 drive "$T/fixture/spawn-gate.sh")"
  eq "G3 AT the bound is ok (the gate's own predicate is '>=' - a boundary that refuses would be a false block)" "report|ADMITTED|8144|8144|ok" "$G"
  G="$(FIXTURE_ROW='[disk-report] REFUSED-UNKNOWN ? 8144 tree=350 self=6144 reserve=2000 box=b target=/x' FIXTURE_RC=0 drive "$T/fixture/spawn-gate.sh")"
  eq "G4 an unreadable probe reads headroom=unknown and free='?'" "report|REFUSED-UNKNOWN|?|8144|unknown" "$G"

  # ⛔ THE DEPLOY-SKEW ARM, and it must be LOUD: a copy that predates the verb (a non-zero rc with no
  # row) is the #2033 half-deployed shape. It is NOT a capacity change — the enforcing gate is
  # elsewhere — so the cycle proceeds, but it says so once.
  G="$(FIXTURE_ROW='' FIXTURE_RC=64 drive "$T/fixture/spawn-gate.sh")"
  eq "G5 a gate that does not answer leaves the fields explicitly UNSET (src=absent, headroom='?')" "absent|?|||?" "$G"
  has "PREDATES the report verb" "$(cat "$T/drive.log")" "G6 …and the cycle SAYS SO (a silent absence is the defect)"
  # ⛔ ABSENT is the same class: the loop must not refuse to run because a log field cannot be produced.
  G="$(FIXTURE_ROW='' FIXTURE_RC=0 drive "$T/does-not-exist/spawn-gate.sh")"
  eq "G7 a missing spawn-gate.sh is also 'absent' (not a fabricated figure)" "absent|?|||?" "$G"
  has "no spawn-gate.sh found" "$(cat "$T/drive.log")" "G8 …and names what it looked for"

  # ⛔ AND THE BLOCK MEASURES NOTHING ITSELF. This is the property that keeps the `[cap]` figure equal
  # to the gate's verdict: no second `df`, no copied term. A future edit that re-implemented the
  # reading here would pass G1-G8 and redden this.
  noncomment="$(grep -vE '^[[:space:]]*#' "$BLOCK")"
  hasnt "df -Pk" "$noncomment" "G9 the block does NOT run a second df (one measurement, one source)"
  hasnt "DISK_LANE_SELF" "$noncomment" "G10 the block carries no copy of the gate's cost terms"
  has "disk-report" "$noncomment" "G11 it ASKS the gate (--disk-report) instead of reproducing it"

  # ── H) the fields are actually PRINTED on `[cap]`, after the block computed them ──────────────
  echo
  echo "── H) the [cap] line carries the fields the block sets ──"
  has 'disk_free=${DISK_FREE_MB:-?}M/${DISK_NEED_MB:-?}M' "$(cat "$LOOP")" "H1 [cap] prints free/bound as one pair, like mem_avail=<free>M/<floor>M"
  has 'disk_headroom=${DISK_HEADROOM:-?}' "$(cat "$LOOP")" "H2 [cap] prints the headroom verdict"
  has 'disk_src=${DISK_SRC:-unset}' "$(cat "$LOOP")" "H3 [cap] names the reading's SOURCE, so an absent probe is visible on the line itself"
  cap_ln="$(grep -n '^  echo "\[cap\] load=' "$LOOP" | head -1 | cut -d: -f1)"
  begin_ln="$(grep -n '# \[capdisk:begin\]' "$LOOP" | head -1 | cut -d: -f1)"
  { [ -n "$cap_ln" ] && [ -n "$begin_ln" ] && [ "$begin_ln" -lt "$cap_ln" ]; }; rc=$?
  ck "H4 the block runs BEFORE the [cap] echo (read after it, the line would print the PREVIOUS cycle's reading — the stale-record class #2159's sibling suites pin)" $rc
fi

echo
echo "── cap-disk-report.test.sh: ${PASS} passed, ${FAIL} failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
