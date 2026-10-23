#!/usr/bin/env bash
# tests/pi-shim/run.sh — the SPAWN-POINT load gate (agent-infra#1884).
#
# ⛔ THE PROPERTY UNDER TEST IS NOT "the gate refuses". It is "the gate refuses a caller that never
# agreed to be gated". Before #1884 the load gate was a LIBRARY (`scripts/orchestrator-harness/
# spawn-gate.sh`) that a caller had to SOURCE: lane.sh, fix-one.sh and nonblocking-dispatch.sh did,
# and a hand-written runner did not. On 2026-10-16 the orchestrator started three lanes from
#
#     tmux new-session -d -s <name> "… pi -p \"$(cat <brief>)\" …"
#
# — no lane.sh, therefore no source line, therefore MAX_LOAD was never read, on a box already at
# load 258 against its own ceiling of 100. Nothing refused, printed or counted: an ungated spawn was
# not merely untracked, it was INVISIBLE. §1 drives exactly that caller — a script that runs `pi`
# and nothing else — and asserts the refusal lands anyway.
#
# The mechanism is the one this tree already ships for `gh` (#984, tests/gh-shim/run.sh): the shim
# on PATH. spawn-gate.sh is now ALSO an executable installed as `$HOME/.pi/agent/bin/pi`, a
# directory that is first on PATH on both surfaces, so every `pi` resolves through the gate. Its
# SELF-EXCLUSION is `-ef` (device+inode through symlinks) for the reason the gh shim records: a
# neutral directory holding a symlink back to the shim made `exec` re-enter forever, and EVERY call
# hung (§8 pins that shape here).
#
# Hermetic: a fake real-`pi` records its argv, its PPID and its own pid; the load READING is driven
# by fake `awk`/`sysctl` (the two branches `load1` picks between), so "above the ceiling" is a
# controlled value instead of this box's current 1-minute average. HOME is a temp dir, so no
# operator state is touched and the ledger assertions are exact.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/orchestrator-harness/spawn-gate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-shim-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "   ❌ $1"; }

export HOME="$TMP/home"
LEDGER="$HOME/.pi/agent/state/spawn-gate.tsv"
mkdir -p "$HOME" "$TMP/shim" "$TMP/real" "$TMP/runner" "$TMP/fakebin" "$TMP/O/state"

# ── the fake REAL pi: records argv, its own PPID and its own pid ──────────────
# A real executable in a PATH directory BEHIND the shim — the production shape: the shim finds the
# first `pi` on PATH that is not itself, and execs it.
cat > "$TMP/real/pi" <<'PIEOF'
#!/usr/bin/env bash
{
  printf 'ARGV:%s\n' "$*"
  printf 'PPID:%s\n' "$PPID"
  printf 'SELF:%s\n' "$$"
} >> "${PI_PROBE:?}"
exit "${PI_FAKE_RC:-0}"
PIEOF
chmod +x "$TMP/real/pi"

# ── the shim, installed the way the installers install it ─────────────────────
# A REAL COPY of the shipped file, not a symlink into this checkout: that is what
# pi-bootstrap/setup.sh and cell-install.sh write (the #427 reason), and it is what makes the
# "one artifact, one definition" claim testable — the copy is byte-identical to the library the
# harness callers source.
SHIM="$TMP/shim/pi"
cp "$GATE" "$SHIM"
chmod +x "$SHIM"

# ── THE CALLER THAT FAILED: a hand-written runner that sources nothing ────────
# Verbatim in spirit to the runner that started three lanes on 2026-10-16: a shell, an item, and
# `pi -p`. Nothing in this file knows that spawn-gate.sh exists — which is the whole point.
cat > "$TMP/runner/lane-runner.sh" <<'RUNEOF'
#!/usr/bin/env bash
# A hand-written lane runner. NOT a harness caller: it sources nothing, so before #1884 nothing on
# this path consulted the ceiling.
printf 'aligned\n' > "$BRIEF"
pi -p "$(cat "$BRIEF")" --provider deepseek --model deepseek-v4-flash --no-session
RUNEOF
chmod +x "$TMP/runner/lane-runner.sh"

# The argv the runner is expected to hand the model — asserted below, unchanged.
RUNNER_ARGV='-p aligned --provider deepseek --model deepseek-v4-flash --no-session'

# ── the load-reading seam ─────────────────────────────────────────────────────
# `load1` reads /proc/loadavg on Linux and `sysctl -n vm.loadavg` on macOS, and the shim inherits
# whichever applies. Both branches are stubbed so this suite is deterministic on either surface.
REAL_AWK="$(command -v awk)"
REAL_SYSCTL="$(command -v sysctl || true)"
LSHIMDIR="$TMP/loadshim"
mkdir -p "$LSHIMDIR"
cat > "$LSHIMDIR/awk" <<AWKEOF
#!/usr/bin/env bash
# Fake for the LOAD PROBE only: load1 runs \`awk '{printf "%d\\n", \$1}' <loadavg-file>\`.
# Every other awk call in the gate — the ledger's refusal count — is delegated to the real one, so
# a control that stops at this shim cannot silently disable the counting it is being checked for.
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in
  *loadavg*) printf '%s\n' "\${FAKE_LOAD:?}"; exit 0 ;;
esac
exec "$REAL_AWK" "\$@"
AWKEOF
chmod +x "$LSHIMDIR/awk"
if [ -n "$REAL_SYSCTL" ]; then
  cat > "$LSHIMDIR/sysctl" <<SYSCTLEOF
#!/usr/bin/env bash
# macOS branch of the same seam: load1 pipes \`sysctl -n vm.loadavg\` into awk. Everything else
# (hw.ncpu, which the DEFAULT ceiling is derived from) is delegated, so that derivation still runs.
if [ "\${1:-}" = "-n" ] && [ "\${2:-}" = "vm.loadavg" ]; then printf '{ %s %s %s }\n' "\${FAKE_LOAD:?}" "\${FAKE_LOAD}" "\${FAKE_LOAD}"; exit 0; fi
exec "$REAL_SYSCTL" "\$@"
SYSCTLEOF
else
  # Linux: no real sysctl to delegate to. hw.ncpu only feeds the DEFAULT ceiling, and every arm
  # below sets MAX_LOAD explicitly, so failing this probe is enough to keep the chain honest.
  cat > "$LSHIMDIR/sysctl" <<'SYSCTLEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ] && [ "${2:-}" = "vm.loadavg" ]; then printf '{ %s %s %s }\n' "${FAKE_LOAD:?}" "${FAKE_LOAD}" "${FAKE_LOAD}"; exit 0; fi
exit 1
SYSCTLEOF
fi
chmod +x "$LSHIMDIR/sysctl"

# run_shim runner|direct [argv…] — drives the INSTALLED shim as `pi`, with the fake reading.
#   runner → the hand-written lane runner (which sources nothing)
#   direct → `pi …` typed straight into a shell
# The PATH order is the production order: the shim directory is FIRST, so `pi` IS the gate.
# FAKE_LOAD / MAX_LOAD / TAG / PI_FAKE_RC come from the caller's environment.
run_shim() { # run_shim runner|direct [argv…]
  local how="$1"; shift
  PI_PROBE="$TMP/probe" BRIEF="$TMP/brief.txt" \
  PATH="$LSHIMDIR:$TMP/shim:$TMP/real:$PATH" \
  bash -c '
    how="$1"; runner="$2"; shift 2
    if [ "$how" = runner ]; then exec bash "$runner"; fi
    pi "$@"
  ' _ "$how" "$TMP/runner/lane-runner.sh" "$@"
}

reset_probe() { : > "$TMP/probe"; }
probe_field() { sed -n "s/^$1://p" "$TMP/probe" 2>/dev/null | tail -1; }
ledger_rows() { if [ -r "$LEDGER" ]; then wc -l < "$LEDGER" | tr -d ' '; else printf '0'; fi; }
ledger_field() { sed -n "${1}p" "$LEDGER" 2>/dev/null | cut -f"$2"; }

echo "==> pi-shim suite ($GATE)"

# ── 0. the artifact is the shipped gate, byte for byte ───────────────────────
cmp -s "$GATE" "$SHIM"; rc=$?
[ "$rc" -eq 0 ] && pass "the installed shim IS the shipped spawn-gate.sh (one artifact, one definition)" \
  || fail "the installed shim is not byte-identical to the shipped gate — a second definition would drift"
[ -x "$SHIM" ]; rc=$?
[ "$rc" -eq 0 ] && pass "the installed shim is executable (a non-executable one is skipped by PATH, silently)" \
  || fail "the installed shim is not executable — PATH would resolve past it"

# ── 1. THE PROPERTY THAT FAILED: a caller that sources NOTHING is still gated ─
reset_probe
err="$(FAKE_LOAD=999 MAX_LOAD=10 run_shim runner 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 76 ] && pass "a caller that sources NOTHING is REFUSED at the spawn point (exit $rc)" \
  || fail "a caller with no source line ran ungated (exit $rc) — the #1884 defect is back"
[ ! -s "$TMP/probe" ] && pass "the real pi was NOT started on that refusal (no argv reached it)" \
  || fail "a refused spawn still started the real pi: $(tr '\n' ' ' < "$TMP/probe")"

# ── 2. the refusal is LOUD, and names the facts the issue requires ────────────
reset_probe
err="$(TAG=review-1884 FAKE_LOAD=999 MAX_LOAD=10 run_shim runner 2>&1 >/dev/null)"
grep -q 'REFUSED load=999 >= max_load=10' <<<"$err" && pass "the line names the READING and the CEILING" \
  || fail "the refusal line does not name load and ceiling: $(head -1 <<<"$err")"
grep -q 'item NOT started: review-1884' <<<"$err" && pass "the line names the ITEM that was not started" \
  || fail "the refusal does not name what was not started: $(head -1 <<<"$err")"
# The caller is named too: the operator's question is "who tried to start this", and the failure mode
# was a path nobody could see. The parent's command line is the only general answer a shim has.
grep -q 'caller=.*lane-runner.sh' <<<"$err" && pass "the line names the CALLER (the hand-written runner), not just the load" \
  || fail "the refusal does not name the calling process: $(head -1 <<<"$err")"
# The remedy must include the operator's rescue route: a gate the operator cannot get past is a gate
# that stops the box from being fixed.
grep -q 'absolute path' <<<"$err" && pass "the refusal names the operator's rescue route (the real pi by absolute path)" \
  || fail "the refusal gives no rescue route — an operator could not start a pi on the refused box"

# ── 3. the refusal is COUNTED, durably ───────────────────────────────────────
# "An ungated spawn is silent, which is why this reached load 258 without anything reporting it."
# The ledger row is the part that survives the log: the per-spawn logs are truncated on re-run.
reset_probe
before="$(ledger_rows)"
FAKE_LOAD=999 MAX_LOAD=10 TAG=t3 run_shim runner >/dev/null 2>&1
after="$(ledger_rows)"
[ "$after" -eq "$(( before + 1 ))" ] && pass "a refusal appends exactly one durable ledger row ($before -> $after)" \
  || fail "a refusal did not append a ledger row ($before -> $after)"
{ [ "$(ledger_field "$after" 2)" = "refused" ] && [ "$(ledger_field "$after" 3)" = "999" ] \
  && [ "$(ledger_field "$after" 4)" = "10" ] && [ "$(ledger_field "$after" 8)" = "t3" ]; }; rc=$?
[ "$rc" -eq 0 ] \
  && pass "the row carries verdict=refused, the reading (999), the ceiling (10) and the item tag (t3)" \
  || fail "the ledger row does not record verdict/load/ceiling/tag: $(sed -n "${after}p" "$LEDGER" | cut -f2-4,8)"
nf="$(sed -n "${after}p" "$LEDGER" | awk -F'\t' '{print NF}')"
[ "$nf" = "10" ] && pass "the row has all 10 fields (epoch, verdict, load, max, pid, ppid, KIND, TAG, cwd, caller)" \
  || fail "the ledger row has $nf fields, expected 10 — a truncated row cannot be counted reliably"
# The running count is in the message too: "counted" must be visible in the log line, not only in a
# file an operator has to know to look for.
reset_probe
err="$(FAKE_LOAD=999 MAX_LOAD=10 run_shim runner 2>&1 >/dev/null)"
grep -qE 'refusal #[0-9]+' <<<"$err" && pass "the refusal is NUMBERED, so a log line alone shows it was counted" \
  || fail "the refusal carries no refusal number: $(sed -n 2p <<<"$err")"

# ── 4. MAX_LOAD=0 still means "spawn nothing" (right semantics; they were simply unreached) ──
reset_probe
err="$(FAKE_LOAD=0 MAX_LOAD=0 run_shim runner 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 76 ] && [ ! -s "$TMP/probe" ]; }; rc2=$?
[ "$rc2" -eq 0 ] && pass "MAX_LOAD=0 spawns NOTHING through the spawn point (exit $rc, no real pi)" \
  || fail "MAX_LOAD=0 allowed a spawn (exit $rc) — the documented 'spawn nothing' is gone"
grep -q 'max_load=0' <<<"$err" && pass "…and the refusal reports the ceiling as 0, not as a derived default" \
  || fail "MAX_LOAD=0 was silently replaced by a default ceiling"

# ── 5. POSITIVE CONTROL: below the ceiling the real pi RUNS, argv intact, rc propagated ──
# Without this arm every refusal above would pass on a shim that simply never works.
reset_probe
FAKE_LOAD=3 MAX_LOAD=10 PI_FAKE_RC=7 run_shim runner 2>/dev/null; rc=$?
[ "$rc" -eq 7 ] && pass "below the ceiling the real pi RUNS and its exit status propagates (rc=$rc)" \
  || fail "below the ceiling the spawn did not reach the real pi (rc=$rc)"
grep -qF "ARGV:$RUNNER_ARGV" "$TMP/probe" \
  && pass "argv is passed through UNCHANGED (the shim is not a rewriter)" \
  || fail "argv was altered by the shim: $(tr '\n' ' ' < "$TMP/probe")"
# An ALLOWED run is recorded too: a series that keeps only refusals cannot answer "how close did we
# get", which is the question that would have caught this early.
[ "$(ledger_field "$(ledger_rows)" 2)" = "allowed" ] && pass "an allowed run is recorded as well (verdict=allowed)" \
  || fail "allowed runs are not recorded — the ledger would be refusal-only"

# ── 6. an EXEC, not a wrapper: the shim adds no process to the tree ───────────
# `exec` matters twice: the agent owns the caller's fds and signals (a TUI pi keeps working), and a
# caller that watches its child's pid is not handed a shell that outlives the agent. Asserted on the
# agent's PPID: with an `exec` the chain is `runner -> agent` and nothing in between; a wrapper that
# spawned the agent would put the shim's own pid there instead, and would outlive the agent.
reset_probe
cat > "$TMP/runner/ppid-runner.sh" <<'PPIDEOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$RUNNER_PID"
pi -p "ppid check" --no-session
PPIDEOF
chmod +x "$TMP/runner/ppid-runner.sh"
RUNNER_PID="$TMP/runner.pid" PI_PROBE="$TMP/probe" FAKE_LOAD=1 MAX_LOAD=10 \
  PATH="$LSHIMDIR:$TMP/shim:$TMP/real:$PATH" bash "$TMP/runner/ppid-runner.sh" >/dev/null 2>&1
agent_ppid="$(probe_field PPID)"; caller_pid="$(cat "$TMP/runner.pid" 2>/dev/null)"
{ [ -n "$agent_ppid" ] && [ -n "$caller_pid" ] && [ "$agent_ppid" = "$caller_pid" ]; }; rc=$?
[ "$rc" -eq 0 ] && pass "the shim EXECs: the agent's parent IS the caller ($agent_ppid), no wrapper process in the tree" \
  || fail "a wrapper process sits between the caller and the agent (agent PPID=${agent_ppid:-<none>}, caller=${caller_pid:-<none>}) — not an exec"

# ── 7. a real reading above a POSITIVE ceiling refuses, and the boundary is `<` ──
# §1-§6 use MAX_LOAD=0 in the refusal arms because it is deterministic; on its own that would prove
# only the degenerate case. These arms drive a plausible pair, and pin the comparison: a ceiling is a
# MAXIMUM, so a reading AT it must refuse and one BELOW it must run (the pair discriminates).
reset_probe
err="$(FAKE_LOAD=999 MAX_LOAD=10 run_shim direct -p "real ceiling" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 76 ] && [ ! -s "$TMP/probe" ] && grep -q 'load=999 >= max_load=10' <<<"$err"; }; rc2=$?
[ "$rc2" -eq 0 ] && pass "load 999 vs MAX_LOAD=10 refuses, with both numbers in the line" \
  || fail "a real reading above a positive ceiling was allowed (rc=$rc)"
reset_probe
FAKE_LOAD=10 MAX_LOAD=10 run_shim direct -p "at the ceiling" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 76 ] && pass "a reading AT the ceiling is refused (< is strict: the ceiling is a maximum)" \
  || fail "a reading exactly at MAX_LOAD was allowed (rc=$rc)"
reset_probe
FAKE_LOAD=9 MAX_LOAD=10 run_shim direct -p "just under" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "…and one BELOW the ceiling is allowed (the pair discriminates)" \
  || fail "a reading one below the ceiling was refused (rc=$rc)"

# ── 8. the recursion guard: a symlink farm must not re-enter, and must not hang ──
# The gh shim records the exact failure this pins: a NEUTRAL directory holding a SYMLINK back to the
# shim made `-x` accept the shim itself, `exec` re-entered forever, and EVERY call hung. A hang is
# worse than a refusal — it holds a lane slot and looks like a slow model call. `-ef` compares
# device+inode THROUGH links, so the chain below is skipped and the real pi is still found.
# (No `timeout`: macOS ships none — this is the same bash watchdog run_agent uses.)
mkdir -p "$TMP/neutral"
ln -sf "$SHIM" "$TMP/neutral/pi"
reset_probe
PI_PROBE="$TMP/probe" FAKE_LOAD=1 MAX_LOAD=10 \
  PATH="$LSHIMDIR:$TMP/neutral:$TMP/real:$PATH" pi -p "through a symlink farm" >"$TMP/out8" 2>&1 &
p8=$!
( sleep 10; kill -KILL "$p8" 2>/dev/null ) >/dev/null 2>&1 &
w8=$!
wait "$p8" 2>/dev/null; rc=$?
kill "$w8" 2>/dev/null
[ "$rc" -ne 137 ] && pass "a symlinked shim on PATH does not hang (rc=$rc, not the 10s kill)" \
  || fail "the shim re-entered itself through a symlink and hung — the gh-shim VGATE failure"
{ [ "$rc" -eq 0 ] && grep -qF 'ARGV:-p through a symlink farm' "$TMP/probe"; }; rc2=$?
[ "$rc2" -eq 0 ] && pass "…and it still resolves the REAL pi behind the link farm" \
  || fail "a symlink-farm installation could not find the real pi (rc=$rc): $(head -2 "$TMP/out8")"

# ── 9. the harness's own layered path: run_agent translates the spawn point's 76 ──
# Both gates stay live on purpose (run_agent reads the load, then the shim reads it again — closing
# the millisecond band between them by trusting a caller-set marker would hand the bypass back). So
# the SECOND refusal must arrive as the FIRST: 76 -> AGENT_LOAD_REFUSED, AGENT_STARTED=0, no
# walltime row. Without that translation fix-one.sh re-runs the merge chain for a fixer that never
# ran, and merge-one.sh authorises a fixer for a REVIEW that never happened (the #1716/#1720 class).
mkdir -p "$TMP/bin76"
printf '#!/usr/bin/env bash\nexit 76\n' > "$TMP/bin76/pi"
chmod +x "$TMP/bin76/pi"
# ⛔ THE CREATION BACK-PRESSURE GATE IS SUPPLIED A READING, NOT SWITCHED OFF (#2409). `run_agent`
# now measures the repo's landing ratio before any spawn, through `gh`. This arm drives it from the
# harness checkout (whose origin IS agent-infra), so the SYSTEM gh would answer LAND-BACKLOG and the
# arm would return 74 before reaching the 76 -> 75 translation it exists to test (measured: 2 of 29
# red). The calm answer goes where the gate reads; nothing here disables the gate.
printf '#!/usr/bin/env bash\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$TMP/bin76/gh"
chmod +x "$TMP/bin76/gh"
# ⛔ AND THE REPO, NOT ONLY THE NUMBERS (review cycle 3, P2 — the SAME defect review cycle 2 found in
# spawn-gate.test.sh, left in this file). `land_backlog_repo` derives owner/name from the CURRENT
# worktree's origin, and this arm never `cd`s, so it only passed when the runner happened to start in a
# GitHub checkout: measured `cd /tmp` -> 2 of 29 red, `rc=74 started=0`. A fixture with a GitHub origin
# makes the input explicit, so the arm tests the 76 -> 75 translation and not the runner's ambient cwd.
FIXREPO="$TMP/repofix"; mkdir -p "$FIXREPO"
git init -q "$FIXREPO" && git -C "$FIXREPO" remote add origin https://github.com/owner/repo.git
: > "$TMP/agent.log"; rm -f "$TMP/O/state/walltime.tsv"
res="$(PATH="$TMP/bin76:$PATH" O="$TMP/O" MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 bash -c '
  . "$1"
  cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
  load1() { printf "1"; }
  run_agent 1 "$2" "$3" "layered refusal" >/dev/null 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$GATE" "$TMP/agent.log" "$TMP/brief.txt" "$FIXREPO" 2>/dev/null)"
[ "$res" = "rc=75 started=0" ] \
  && pass "run_agent turns a spawn-point refusal into AGENT_LOAD_REFUSED with AGENT_STARTED=0 ($res)" \
  || fail "a spawn-point refusal was not translated for the callers ($res)"
grep -q 'load-gate.*REFUSED.*spawn point' "$TMP/agent.log" \
  && pass "…and it logs a load-gate refusal, which is the line the callers' remedy text keys on" \
  || fail "the translated refusal left no load-gate line in the caller's log"
[ ! -s "$TMP/O/state/walltime.tsv" ] \
  && pass "…and writes NO walltime row (no agent ran, so no zero-duration sample may be fabricated)" \
  || fail "a spawn-point refusal fabricated a walltime row: $(cat "$TMP/O/state/walltime.tsv")"

# ── 10. the ledger is BOUNDED — the highest-volume sink in the tree ──────────
# One row per `pi` invocation (interactive sessions and sub-agents included) on boxes that have
# filled their filesystem twice (#1765 — the second time killing the controller mid-log). The bound
# is one-generation rotation at PI_GATE_LEDGER_MAX_BYTES, so the total stays ~2x the cap with no
# timer and no reaper dependency. Driven, not grepped: an over-cap ledger must rotate on the next
# write, and the live file must come back tiny.
reset_probe
CAP="$(bash -c '. "$1"; printf "%s" "$PI_GATE_LEDGER_MAX_BYTES"' _ "$GATE")"
case "$CAP" in ''|*[!0-9]*) CAP=0 ;; esac
if [ "$CAP" -gt 0 ]; then
  # Fill the live ledger past the cap in one write, then spawn once.
  head -c "$CAP" /dev/zero | tr '\0' 'x' >> "$LEDGER"
  sz_before=$(wc -c < "$LEDGER" | tr -d ' ')
  reset_probe
  FAKE_LOAD=1 MAX_LOAD=10 run_shim direct -p "rotation" >/dev/null 2>&1
  sz_after=$(wc -c < "$LEDGER" 2>/dev/null | tr -d ' ')
  if [ -f "$LEDGER.1" ] && [ "$sz_after" -lt "$CAP" ]; then
    pass "an over-cap ledger ROTATES (${sz_before}B -> ${sz_after}B live, previous kept as .1) — bounded growth, no reaper needed"
  else
    fail "the spawn-point ledger is UNBOUNDED (grew to ${sz_after:-<gone>}B against a ${CAP}B cap)"
  fi
  rm -f "$LEDGER.1"
else
  fail "PI_GATE_LEDGER_MAX_BYTES is unreadable from the shipped file — the rotation bound cannot be checked"
fi

# ── 11. the installers install it (an uninstalled gate is a convention again) ──
# Asserted as the SOURCE of the install — the file each installer copies, and the name it lands
# under — because driving both installers here would duplicate their fixtures; the ARTIFACT half is
# driven end to end by pi-bootstrap/tests/test-setup-no-nesting.sh (Mac) and test-cell-install.sh
# (cell). STATED LIMIT: a source-shaped check cannot see an install assembled at runtime, and
# neither installer does that.
SETUP_SH="$ROOT/pi-bootstrap/setup.sh"
CELL_INSTALL="$ROOT/pi-bootstrap/cell-install.sh"
for f in "$SETUP_SH" "$CELL_INSTALL"; do
  if grep -q 'scripts/orchestrator-harness/spawn-gate.sh' "$f" && grep -q 'DEST/bin' "$f"; then rc=0; else rc=1; fi
  label="$(basename "$f") installs the spawn-point gate as \$DEST/bin/pi"
  [ "$rc" -eq 0 ] && pass "$label" || fail "$label — the gate would reach no box through this installer"
done

echo
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks pi-shim test(s) failed"
  exit 1
fi
echo "✅ all $checks pi-shim tests passed"
