#!/usr/bin/env bash
# controllers.test.sh — the controller COUNT must not be a subprocess count (agent-infra#2043).
#
# HOW THESE CHECKS ARE WRITTEN. Every arm drives the SHIPPED `controllers.sh` through its real
# contract (env in, stdout/stderr/rc out) and asserts the reading. Two families:
#
#   §1–§9   a STUBBED `ps` (the `PS_BIN` seam the script exists with) feeding tables that reproduce
#           the measured shapes exactly — the count is asserted, not re-derived.
#   §10–§12 REAL processes in a scratch `$O`: a synthetic controller whose subshells inherit its argv
#           (the exact defect), then a GENUINE second controller started with an independent parent.
#           The issue requires that proof, and a stub table cannot give it.
#
# ⛔ §1 AND §10 ASSERT THAT THE NAIVE COUNT WOULD HAVE BEEN WRONG. A suite that only checks "the
# number is 1" also passes on an implementation that counts nothing when the fixture is empty; the raw
# argv count in the same scope is the control, so the arm is not vacuous.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJ="$HERE/controllers.sh"
SUP="$HERE/../cloud-cell-supervisor.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
O="$TMP/O"; mkdir -p "$O"
say() { printf '\n-- %s\n' "$1"; }
nums() { tr ' ' '\n' | awk 'NF' | sort -n | tr '\n' ' ' | sed 's/ *$//'; }   # stdin → "p1 p2 "
contains_pid() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }  # <pids> <pid>
# ⛔ `has` is a `case`, not `printf … | grep -q`: under `pipefail` a quiet grep exits at its first
# match, the writer takes SIGPIPE, and the pipeline reports FAILURE on text that WAS there — the
# false negative scripts/check-no-sigpipe-grep.sh exists for (#841/#864). It flagged this file's
# first draft, correctly.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }                # <text> <literal substring>
has_prefix() { case "$1" in "$2"*) return 0 ;; esac; return 1; }         # <text> <literal prefix>

echo "==> controllers.sh self-test ($HERE)"

[ -s "$SUBJ" ] && bash -n "$SUBJ"; ck "controllers.sh exists and parses" $?

# ── a stubbed ps: prints the table in $FAKE_TABLE, never the host's processes ─────────────────────
cat > "$TMP/bin/ps" <<'EOS'
#!/usr/bin/env bash
[ -n "${FAKE_TABLE:-}" ] || exit 1
[ -f "$FAKE_TABLE" ] || exit 1
cat "$FAKE_TABLE"
EOS
chmod +x "$TMP/bin/ps"

# run_subj <table|-> <lock-content|-> [args…]  → OUT/ERR/RC against the stubbed table and a scratch $O
run_subj() {
  local table="$1" lock="$2"; shift 2
  rm -f "$O/.orch.lock"
  [ "$lock" = "-" ] || printf '%s\n' "$lock" > "$O/.orch.lock"
  if [ "$table" = "-" ]; then : > "$TMP/table"; else printf '%s\n' "$table" > "$TMP/table"; fi
  OUT="$(FAKE_TABLE="$TMP/table" PS_BIN="$TMP/bin/ps" O="$O" bash "$SUBJ" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  PIDS="$(printf '%s' "$OUT" | sed -n 's/.*pids="\(.*\)"/\1/p')"
}
# naive_argv_count <table> — what `ps ax -o command | grep -c "[o]rch-loop.sh"` would have said
naive_argv_count() { printf '%s\n' "$1" | awk -v a="bash $O/orch-loop.sh" 'index($0,a)' | wc -l | tr -d ' '; }

# ── §1 THE MEASURED SHAPE: one controller, its subshell, and that subshell's subshell ────────────
say "§1 a controller + 2 nested subshells reads 1 (the measured 2026-10-18 shape)"
T1="$(printf '  %s     1 bash %s/orch-loop.sh\n  200   %s bash %s/orch-loop.sh\n  300   200 bash %s/orch-loop.sh\n  400     1 bash /elsewhere/orch-loop.sh\n' "$$" "$O" "$$" "$O" "$O")"
run_subj "$T1" "$$"
ck "controllers=1 pids=\"$$\"" "$([ "$OUT" = "controllers=1 pids=\"$$\"" ]; echo $?)"
ck "the naive argv count for the SAME table is 3 — so this arm is not vacuous" "$([ "$(naive_argv_count "$T1")" = 3 ]; echo $?)"
ck "another runtime's controller (different path) is not counted as ours" "$(has "$OUT" 'elsewhere' && echo 1 || echo 0)"

# ── §2 A GENUINE SECOND CONTROLLER: independent parent, same program ─────────────────────────────
say "§2 two independent controllers read 2 — ancestry is the discriminator, not argv"
T2="$(printf '  %s     1 bash %s/orch-loop.sh\n  4242     1 bash %s/orch-loop.sh\n  4243  4242 bash %s/orch-loop.sh\n' "$$" "$O" "$O" "$O")"
run_subj "$T2" "$$"
ck "controllers=2" "$([ "${OUT%% *}" = "controllers=2" ]; echo $?)"
ck "the second is the INDEPENDENT parent only (4243, its subshell, is dropped)" \
  "$([ "$(printf '%s' "$PIDS" | nums)" = "$(printf '%s 4242' "$$" | nums)" ]; echo $?)"

# ── §3 THE LOCK NAMES A NON-CONTROLLER — named, never silently included or excluded ──────────────
say "§3 a claimed pid that is not a controller is NAMED"
sleep 5 & SP=$!; disown "$SP" 2>/dev/null
T3="$(printf '  %s     1 bash %s/orch-loop.sh\n  %s     1 sleep 5\n' "$$" "$O" "$SP")"
run_subj "$T3" "$SP"
ck "stderr says: lock names a non-controller pid $SP" "$(has "$ERR" "lock names a non-controller pid $SP"; echo $?)"
ck "it is not counted (the reading is the table's one controller)" "$([ "$OUT" = "controllers=1 pids=\"$$\"" ]; echo $?)"
kill "$SP" 2>/dev/null

# ── §4 A DEAD lock pid (the lock outlived a kill -9) ─────────────────────────────────────────────
say "§4 a stale lock naming a dead pid is NAMED and contributes nothing"
T4="$(printf '  %s     1 bash %s/orch-loop.sh\n' "$$" "$O")"
run_subj "$T4" 9999999
ck "stderr says: lock names a dead pid 9999999" "$(has "$ERR" 'lock names a dead pid 9999999'; echo $?)"
ck "the count still comes from the table (a stale lock cannot read as 0)" "$([ "$OUT" = "controllers=1 pids=\"$$\"" ]; echo $?)"

# ── §5 A RECYCLED pid landing on a SUBSHELL — the miscount this file exists to remove ────────────
say "§5 a lock naming a pid recycled onto a subshell counts once, as the controller"
sleep 5 & RP=$!; disown "$RP" 2>/dev/null
T5="$(printf '  %s     1 bash %s/orch-loop.sh\n  %s   %s bash %s/orch-loop.sh\n' "$$" "$O" "$RP" "$$" "$O")"
run_subj "$T5" "$RP"
ck "count is 1, not 2: the claimed pid is a descendant of the controller" "$([ "$OUT" = "controllers=1 pids=\"$$\"" ]; echo $?)"
ck "and the reduction is NAMED on stderr, not silent" "$(has "$ERR" "subshell of controller $$"; echo $?)"
kill "$RP" 2>/dev/null

# ── §6 AN UNREADABLE READ IS NOT ZERO ────────────────────────────────────────────────────────────
say "§6 a failed ps read is cannot-determine, never 'no controller'"
rm -f "$O/.orch.lock"
OUT="$(FAKE_TABLE="$TMP/table" PS_BIN=/bin/false O="$O" bash "$SUBJ" 2>"$TMP/err")"; RC=$?
ck "rc 2 (cannot determine)" "$([ "$RC" = 2 ]; echo $?)"
ck "stdout says controllers=unknown, NOT controllers=0" "$([ "$OUT" = 'controllers=unknown pids=""' ]; echo $?)"
ck "the reason is named on stderr" "$(grep -q 'cannot read the process table' "$TMP/err" && echo 0 || echo 1)"
: > "$TMP/empty"
OUT="$(FAKE_TABLE="$TMP/empty" PS_BIN="$TMP/bin/ps" O="$O" bash "$SUBJ" --count 2>/dev/null)"; RC=$?
ck "an EMPTY table is also cannot-determine (--count prints 'unknown', rc 2)" "$([ "$OUT" = unknown ] && [ "$RC" = 2 ]; echo $?)"

# ── §7 A READABLE BOX WITH NOTHING ON IT is 0, distinctly (rc 1) ─────────────────────────────────
say "§7 a readable table with no controller reads 0, with its own exit code"
run_subj "$(printf '  %s     1 -zsh\n  2     1 /sbin/launchd\n' "$$")" "-"
ck "controllers=0 pids=\"\"" "$([ "$OUT" = 'controllers=0 pids=""' ]; echo $?)"
ck "rc 1 distinguishes 'nothing running' from 'could not read' (rc 2)" "$([ "$RC" = 1 ]; echo $?)"

# ── §8 THE LOCK'S OWN UNREADABLE SHAPES ─────────────────────────────────────────────────────────
say "§8 absent, empty and non-regular locks are each handled and named"
T8="$(printf '  %s     1 bash %s/orch-loop.sh\n' "$$" "$O")"
run_subj "$T8" "-"
ck "no lock file at all is silent (a controller that has not written it yet is normal)" "$([ -z "$ERR" ] && [ "$OUT" = "controllers=1 pids=\"$$\"" ]; echo $?)"
rm -f "$O/.orch.lock"; : > "$O/.orch.lock"
OUT="$(FAKE_TABLE="$TMP/table" PS_BIN="$TMP/bin/ps" O="$O" bash "$SUBJ" 2>"$TMP/err")"
ck "an empty lock is named (never read as pid 0)" "$(grep -q 'lock is empty' "$TMP/err" && echo 0 || echo 1)"
rm -f "$O/.orch.lock"; mkdir -p "$O/.orch.lock"
OUT="$(FAKE_TABLE="$TMP/table" PS_BIN="$TMP/bin/ps" O="$O" bash "$SUBJ" 2>"$TMP/err")"; RC=$?
ck "a non-regular lock is named and does NOT block (the FIFO guard)" "$(grep -q 'not a regular file' "$TMP/err" && [ "$RC" = 0 ]; echo $?)"
rmdir "$O/.orch.lock"

# ── §9 THE OUTPUT CONTRACT bg/status.sh CONSUMES ────────────────────────────────────────────────
say "§9 --count / --pids are one clean token; warnings never pollute stdout"
run_subj "$T1" "$$"
OUT="$(FAKE_TABLE="$TMP/table" PS_BIN="$TMP/bin/ps" O="$O" bash "$SUBJ" --count 2>/dev/null)"
ck "--count prints exactly '1'" "$([ "$OUT" = 1 ]; echo $?)"
OUT="$(FAKE_TABLE="$TMP/table" PS_BIN="$TMP/bin/ps" O="$O" bash "$SUBJ" --pids 2>/dev/null)"
ck "--pids prints exactly the controller pid" "$([ "$OUT" = "$$" ]; echo $?)"
sleep 5 & SP2=$!; disown "$SP2" 2>/dev/null
run_subj "$(printf '  %s     1 bash %s/orch-loop.sh\n  %s     1 sleep 5\n' "$$" "$O" "$SP2")" "$SP2"
ck "a warning goes to stderr only — stdout stays ONE clean reading line" \
  "$([ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && has_prefix "$OUT" 'controllers=1 '; echo $?)"
kill "$SP2" 2>/dev/null

# ── §10 REAL PROCESSES: the defect as the OS actually renders it ────────────────────────────────
say "§10 REAL: a synthetic controller + real subshells in a scratch \$O (never the live runtime)"
RO="$TMP/rt"; mkdir -p "$RO"
# The stub stands in for `orch-loop.sh` only in that it idles: the SUBSHELL SHAPE is what is under
# test, and a bash subshell inherits its parent's argv on fork whatever the script does.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'PIDS=%s\n' "'$RO/subshells.pids'"
  printf '%s\n' '( sleep 5; : ) & echo $! >> "$PIDS"'
  printf '%s\n' '( ( sleep 5; : ); : ) & echo $! >> "$PIDS"'
  printf '%s\n' 'sleep 5'
} > "$RO/orch-loop.sh"
: > "$RO/subshells.pids"
raw_rows() { ps -eo pid=,ppid=,command= | awk -v a="bash $RO/orch-loop.sh" 'index($0,a)' | wc -l | tr -d ' '; }

bash "$RO/orch-loop.sh" & C1=$!; disown "$C1" 2>/dev/null
i=0; while [ "$i" -lt 50 ] && [ "$(raw_rows)" -lt 3 ]; do sleep 0.1; i=$((i+1)); done
NAIVE="$(raw_rows)"
ck "fixture: the controller + 2 real subshells wear the same argv (raw rows=$NAIVE >= 3)" "$([ "$NAIVE" -ge 3 ]; echo $?)"
printf '%s\n' "$C1" > "$RO/.orch.lock"
OUT="$(O="$RO" bash "$SUBJ")"; RC=$?
PIDS="$(printf '%s' "$OUT" | sed -n 's/.*pids="\(.*\)"/\1/p')"
ck "REAL: controllers=1 for that one controller (a naive count said $NAIVE)" "$([ "$OUT" = "controllers=1 pids=\"$C1\"" ]; echo $?)"
ck "REAL: rc 0" "$([ "$RC" = 0 ]; echo $?)"

# ── §11 REAL: a GENUINE second controller — same program, INDEPENDENT parent ─────────────────────
say "§11 REAL: a second controller started outside launchd is still detected"
bash "$RO/orch-loop.sh" & C2=$!; disown "$C2" 2>/dev/null
i=0; while [ "$i" -lt 50 ] && [ "$(raw_rows)" -lt 6 ]; do sleep 0.1; i=$((i+1)); done
OUT="$(O="$RO" bash "$SUBJ")"; RC=$?
PIDS="$(printf '%s' "$OUT" | sed -n 's/.*pids="\(.*\)"/\1/p')"
WANT="$(printf '%s %s' "$C1" "$C2" | nums)"
ck "REAL: controllers=2 — the independent controller is not deduped away by argv" "$([ "${OUT%% *}" = "controllers=2" ]; echo $?)"
ck "REAL: the two pids are exactly the two controllers" "$([ "$(printf '%s' "$PIDS" | nums)" = "$WANT" ]; echo $?)"
SUBPIDS="$(cat "$RO/subshells.pids" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
leaked=0
for p in $SUBPIDS; do contains_pid "$PIDS" "$p" && leaked=1; done
ck "REAL: no subshell pid appears in the reading (fixture captured ${SUBPIDS:-"none"})" "$([ -n "$SUBPIDS" ] && [ "$leaked" = 0 ]; echo $?)"
ck "REAL: rc 0" "$([ "$RC" = 0 ]; echo $?)"

# ── §12 REAL: the lock naming a live non-controller, against a live table ───────────────────────
say "§12 REAL: a lock naming a live non-controller is NAMED against a real process table"
sleep 5 & REAL_SLEEP=$!; disown "$REAL_SLEEP" 2>/dev/null
printf '%s\n' "$REAL_SLEEP" > "$RO/.orch.lock"
OUT="$(O="$RO" bash "$SUBJ" 2>"$TMP/err")"
ck "REAL: stderr names it (lock names a non-controller pid $REAL_SLEEP)" "$(grep -q "lock names a non-controller pid $REAL_SLEEP" "$TMP/err" && echo 0 || echo 1)"
ck "REAL: the count still comes from the table (2 controllers; the sleep is not one)" "$([ "${OUT%% *}" = "controllers=2" ]; echo $?)"

kill "$C1" "$C2" "$REAL_SLEEP" 2>/dev/null
for p in $(cat "$RO/subshells.pids" 2>/dev/null); do kill "$p" 2>/dev/null; done


# ── §13 THE TWO COPIES OF THE DESCENDANT RULE MUST NOT DRIFT (#1178) ────────────────────────────
# cloud-cell-supervisor.sh carries the same awk and cannot be sourced from here (both files ship
# STANDALONE into a runtime dir), so the duplication is real and the pin has to be real too. The
# bodies are compared verbatim: "improving" one copy alone reddens this arm instead of becoming a
# second process-identity rule.
say "§13 the descendant-exclusion awk does not drift from cloud-cell-supervisor.sh"
# ⛔ The body ends with `'` at the END of the last code line, not on a line of its own: a
# line-anchored terminator (`/^'$/`) reads past the block and compares the wrong text — which is how
# this pin first produced a false DRIFT report while both copies were in fact identical.
extract_awk() {
  awk -v q="'" '/^_controller_ps_awk='"'"'/ {p=1; next} p { if (sub(q "$", "")) { print; exit } print }' "$1"
}
A_SUBJ="$(extract_awk "$SUBJ")"; A_SUP="$(extract_awk "$SUP")"
ck "both copies of _controller_ps_awk were found (a rename must update this pin)" "$([ -n "$A_SUBJ" ] && [ -n "$A_SUP" ]; echo $?)"
if [ -n "$A_SUBJ" ] && [ "$A_SUBJ" = "$A_SUP" ]; then
  ck "controllers.sh's awk is IDENTICAL to the supervisor's (no drift)" 0
else
  ck "controllers.sh's awk is IDENTICAL to the supervisor's (no drift)" 1
  diff <(printf '%s\n' "$A_SUP") <(printf '%s\n' "$A_SUBJ") | sed 's/^/      /' | head -20
fi

echo
printf 'controllers.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
