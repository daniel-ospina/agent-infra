#!/usr/bin/env bash
# orphaned-harness.test.sh — hermetic tests for scripts/orchestrator-harness/orphaned-harness.sh.
#
# The report reads `systemctl`, `tmux`, and `ps`. This suite stubs all three (via the report's
# own TMUX_BIN / SYSTEMCTL_BIN / PS_BIN seams) so the verdicts are tested without a live box:
#   OH1  a dead harness lane (bare bash, no live `pi` descendant, old) is NAMED with its PR
#   OH2  a live harness lane (a live `pi` descendant) is NOT named
#   OH3  a harness unit pinned to a MISSING path is named
#   OH4  a harness unit pinned to a SCRATCH worktree path is named
#   OH5  a stock OS unit (dbus) is never read as an orphan
#   OH6  a harness unit on an existing durable path is NOT named
#   OH7  when NEITHER surface can be read, the report exits 2 (never a false "nothing to report")
#
# Mutations (same shape as claim-action-proof.test.sh) revert each judgeable rule in a temp copy
# and require the paired case to go RED, proving the rule is load-bearing.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/orphaned-harness.sh"
REAL_DATE="${DATE:-/bin/date}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi }

T="$(mktemp -d "${TMPDIR:-/tmp}/orphaned-harness.test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT

# Scenario files live under $T/scen; the stubs read them. Every path a unit is pinned to is
# under $T so the verdict is hermetic (never touches the real filesystem's /tmp or /usr/local).
mkdir -p "$T/scen" "$T/bin"

write_stub() {  # <name> — write the stub from a here-doc supplied by the caller
  : # body appended below
}

cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-sessions)
    if [ "$#" -ge 5 ]; then
      # -f '#{==:#{session_name},NAME}' -> print the created column for NAME
      name="${5##*,}"; name="${name%\}}"
      awk -v n="$name" '$1==n {print $2}' "$SCEN/sessions"
    else
      cut -d' ' -f1 "$SCEN/sessions"
    fi
    ;;
  list-panes)
    awk -v n="$3" '$1==n {print $2}' "$SCEN/panes"
    ;;
esac
EOF

cat > "$T/bin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-o" ] && [ "$2" = "comm=" ] && [ "$3" = "-p" ]; then
  awk -v p="$4" '$1==p {print $2}' "$SCEN/procs"
else
  awk '{print $1, $3}' "$SCEN/procs"
fi
EOF

cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-units) cat "$SCEN/units" ;;
  show) awk -v u="$2" '$1==u {sub(/^[^ ]* /, ""); print}' "$SCEN/execstart" ;;
esac
EOF
chmod +x "$T/bin/tmux" "$T/bin/ps" "$T/bin/systemctl"

# write_scen <sessions> <panes> <procs> <units> <execstart>
write_scen() {
  printf '%b' "$1" > "$T/scen/sessions"
  printf '%b' "$2" > "$T/scen/panes"
  printf '%b' "$3" > "$T/scen/procs"
  printf '%b' "$4" > "$T/scen/units"
  printf '%b' "$5" > "$T/scen/execstart"
}

# run_report [extra-env...] — run the report against the stubs; echo stdout + "RC=<n>".
run_report() {
  local out rc
  out="$( SCEN="$T/scen" TMUX_BIN="$T/bin/tmux" SYSTEMCTL_BIN="$T/bin/systemctl" \
          PS_BIN="$T/bin/ps" SCRATCH_ROOTS="$T/wt-" "$@" bash "$REPORT" 2>&1 )"; rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}

NOW="$("$REAL_DATE" +%s)"
OLD=$((NOW - 1000))   # 1000 s old -> past MIN_SESSION_AGE_S (600): reportable
NEW=$((NOW - 5))      # 5 s old -> still launching: must NOT be named

# ── OH1/OH2: dead lane named with its PR, live lane not named ──────────────────────────────
# sessions: "name created"; panes: "name pane_pid"; procs: "pid comm ppid".
#   merge-10090 (OLD): pane 100 -> procs 100 bash (no pi descendant) -> DEAD
#   merge-10091 (OLD): pane 200 -> procs 200 bash, 201 pi ppid 200 -> LIVE
write_scen \
  "merge-10090 $OLD\nmerge-10091 $OLD\n" \
  "merge-10090 100\nmerge-10091 200\n" \
  "100 bash 0\n200 bash 0\n201 pi 200\n" \
  "" ""
OH12="$(run_report)"
grep -q 'orphan:kind=tmux name=merge-10090 prs=10090 .*reason=no-live-agent-child' <<< "$OH12"
ck "OH1 a dead harness lane (no live pi descendant, old) is named with its PR" $?
if grep -q 'name=merge-10091' <<< "$OH12"; then
  bad "OH2 a live harness lane (live pi descendant) is NOT named"
else
  ok "OH2 a live harness lane (live pi descendant) is NOT named"
fi

# ── OH8: THE FLOOR IS A TRUE FLOOR — a just-spawned session is NEVER named ─────────────────
# `NEW` (5 s old) is the shape of a worker that has been spawned and is still launching its agent: it
# has no `pi` descendant YET, so a report that judged it dead would name EVERY lane for its first
# MIN_SESSION_AGE_S (600 s) — and would do it exactly when an operator is hunting the real orphans.
# ⛔ WHY THIS ARM EXISTS: `NEW` was computed and documented from the day this suite landed, but no
# case ever drove it, so only the PAST-the-floor direction was asserted and a floor lowered to 0 —
# which reports every freshly-spawned lane — stayed green (agent-infra#2788).
write_scen \
  "merge-10092 $NEW\n" \
  "merge-10092 300\n" \
  "300 bash 0\n" \
  "" ""
OH8="$(run_report)"
if grep -q 'name=merge-10092' <<< "$OH8"; then
  bad "OH8 a just-spawned dead-looking session (younger than MIN_SESSION_AGE_S) is NOT named"
else
  ok "OH8 a just-spawned dead-looking session (younger than MIN_SESSION_AGE_S) is NOT named"
fi

# ── OH3/OH4/OH5/OH6: unit signals ───────────────────────────────────────────────────────────
mkdir -p "$T/wt-2433-fu" "$T/usr/local/bin"
touch "$T/wt-2433-fu/run.sh" "$T/usr/local/bin/ok.sh"
write_scen \
  "" "" "" \
  "eldato-dead.service loaded active running desc\ncell-stale.service loaded active running desc\ndbus.service loaded active running desc\neldato-ok.service loaded active running desc\n" \
  "eldato-dead.service { path=/bin/bash ; argv[]=/bin/bash $T/gone/script.sh ; }\ncell-stale.service { path=/bin/bash ; argv[]=/bin/bash $T/wt-2433-fu/run.sh ; }\neldato-ok.service { path=/bin/bash ; argv[]=/bin/bash $T/usr/local/bin/ok.sh ; }\n"
# dbus has NO execstart line (direct-binary ExecStart) -> execstart_path "" -> never judged.
OH3456="$(run_report)"
grep -q 'orphan:kind=unit name=eldato-dead.service .*reason=missing' <<< "$OH3456"
ck "OH3 a harness unit pinned to a MISSING path is named" $?
grep -q 'orphan:kind=unit name=cell-stale.service .*reason=scratch-pinned' <<< "$OH3456"
ck "OH4 a harness unit pinned to a SCRATCH worktree path is named" $?
if grep -q 'name=dbus' <<< "$OH3456"; then
  bad "OH5 a stock OS unit (dbus) is never read as an orphan"
else
  ok "OH5 a stock OS unit (dbus) is never read as an orphan"
fi
if grep -q 'name=eldato-ok' <<< "$OH3456"; then
  bad "OH6 a harness unit on an existing durable path is NOT named"
else
  ok "OH6 a harness unit on an existing durable path is NOT named"
fi

# ── OH7: neither surface readable -> exit 2, never a false "nothing to report" ─────────────
write_scen "" "" "" "" ""
out="$( SCEN="$T/scen" TMUX_BIN="$T/bin/no-tmux" SYSTEMCTL_BIN="$T/bin/no-systemctl" \
        PS_BIN="$T/bin/ps" bash "$REPORT" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ck "OH7 neither surface readable -> exit 2 (never a false 'nothing to report')" 0 \
                 || ck "OH7 neither surface readable -> exit 2 (got rc=$rc)" 1

# ── MUTATIONS: each rule reverted, the paired case must go RED ─────────────────────────────
run_mutations() {
  local mut_dir out
  mut_dir="$(mktemp -d "${TMPDIR:-/tmp}/orphaned-harness-mut.XXXXXX")" || exit 2
  echo
  echo "── MUTATIONS: each rule reverted, its paired case must go RED ────────────────────────"

  mut() {  # <name> <python-old> <python-new> <needle>
    local name="$1" old="$2" new="$3" needle="$4"
    cp "$REPORT" "$mut_dir/report.sh" || { bad "MUTATION $name: copy failed"; return; }
    python3 - "$mut_dir/report.sh" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p).read()
assert old in t, "anchor not found: %r" % old
open(p, "w").write(t.replace(old, new, 1))
PY
    [ $? -eq 0 ] || { bad "MUTATION $name: anchor not found"; return; }
    bash -n "$mut_dir/report.sh" 2>/dev/null || { bad "MUTATION $name: temp report no longer parses"; return; }
    write_scen \
      "merge-10090 $OLD\n" "merge-10090 100\n" "100 bash 0\n" \
      "eldato-dead.service loaded active running desc\n" \
      "eldato-dead.service { path=/bin/bash ; argv[]=/bin/bash $T/gone/script.sh ; }\n"
    out="$( SCEN="$T/scen" TMUX_BIN="$T/bin/tmux" SYSTEMCTL_BIN="$T/bin/systemctl" \
            PS_BIN="$T/bin/ps" SCRATCH_ROOTS="$T/wt-" bash "$mut_dir/report.sh" 2>&1 )"
    if grep -qF "$needle" <<< "$out"; then
      bad "MUTATION $name: INERT (reverted, the paired case is STILL reported)"
    else
      ok "MUTATION $name: load-bearing (reverted, the paired case went RED — no longer reported)"
    fi
  }

  # M1: revert the dead-lane rule -> a dead lane must no longer be named.
  mut "M1-dead-lane" \
      '  if [ "$dead" -eq 1 ] && [ -n "$age" ] && [ "$age" -ge "${MIN_SESSION_AGE_S}" ]; then' \
      '  if false; then' \
      "orphan:kind=tmux name=merge-10090"
  # M2: revert the missing-path rule -> a missing pinned path must no longer be named.
  mut "M2-missing-unit" \
      '    if [ ! -e "$path" ]; then' \
      '    if false; then' \
      "orphan:kind=unit name=eldato-dead.service"
  # M3: the FLOOR's VALUE (not just the clause) — raise it past every fixture and the old dead lane
  # must stop being named. M1 proves the clause is load-bearing; M3 proves the 600 is what it rests on,
  # which is the half that a floor silently lowered to 0 would keep green (#2788).
  mut "M3-age-floor" \
      '"$age" -ge "${MIN_SESSION_AGE_S}"' \
      '"$age" -ge 1000000000' \
      "orphan:kind=tmux name=merge-10090"

  rm -rf "$mut_dir"
}
run_mutations

echo
echo "── RESULT: $PASS passed, $FAIL failed ────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
