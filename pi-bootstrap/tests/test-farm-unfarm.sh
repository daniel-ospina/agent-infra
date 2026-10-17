#!/bin/bash
# ============================================================
# test-farm-unfarm.sh — the UNFARM leg of the pi-bootstrap farm (#1924)
#
# THE DEFECT. `pi-bootstrap/setup.sh`'s farms are COPY-ONLY: `cp -f` writes the names a
# farm array lists and does nothing at all to a name it does not list. So a script that
# left the repo — or a name that left `fleet_srcs` — keeps its deployed copy in
# $DEST/scripts, executable, in the directory the fleet launches from
# (heartbeat-loop.sh resolves its dispatchers there), while the repo says it is retired.
# Nothing reported it: install-launchd's broken-target check only sees a plist whose
# target is MISSING, and check-deployed-drift.sh compares $O harness *.sh only.
#
# WHAT THIS SUITE PINS (each line is a real failure mode, not a restatement of the code):
#
#   (a) LIB SEMANTICS — two scripts farmed, one retired, re-applied: the retired one is
#       GONE and the other SURVIVES byte-identical. The second half is the assertion that
#       matters: a removal leg that over-deletes is worse than the gap it closes.
#   (b) IDEMPOTENT — a second apply removes nothing, exits 0, and says so (never a silent
#       no-op that could equally be a leg that did not run).
#   (c) CONTRADICTION — a name that a farm array STILL declares is refused, and the leg
#       then removes NOTHING AT ALL: the farm would re-create it, so a half-applied
#       deletion set is a state nobody reviewed. Fails non-zero, loudly.
#   (d) SAFE BY CONSTRUCTION — an entry that escapes the farm (absolute path, `..`,
#       a glob, whitespace, shell metacharacters, the farm root itself) is REFUSED; a
#       DIRECTORY is refused (never `rm -rf`); a symlink is unlinked but its TARGET
#       survives; a symlinked parent directory cannot be used to reach outside the farm.
#   (e) LOUD WHEN UNREADABLE — a missing retirement list is an ERROR, never "nothing to
#       retire": an unreadable list is a retirement that is not applied.
#   (f) THE REPO'S OWN DECLARATION — the real pi-bootstrap/farm-retired.txt does not
#       intersect the real farm, read by an INDEPENDENT parser in this file (never the
#       leg's own reader), and every entry passes the path rules. This is the gate that
#       makes a contradictory manifest unmergeable.
#   (g) END-TO-END, REAL setup.sh — farms two scripts, retires one IN THE REPO COPY
#       (array edit + manifest entry, the two edits a real retirement is), re-applies:
#       the retired script is gone from $DEST/scripts, the other is present and
#       byte-identical, and a third re-apply is clean. Then the array entry is put BACK
#       (the natural half-done retirement): setup.sh must FAIL and re-create the file
#       rather than delete something the farm still declares.
#   (h) THE CELL HALF — `cell-install.sh` applies the same leg, so a retirement reaches
#       Linux cells too, and `--verify` REFUSES a cell that still carries the retired
#       artifact (without it, a cell would be certified while executing a retired
#       script — the false PASS this issue exists to remove).
#
# Hermetic: the repo is READ ONLY except for a throwaway copy made here ($COPY), HOME and
# CELL_HOME are temp dirs, npm and launchctl are stubs (no network; test-setup-no-nesting
# documents why launchctl must never be reachable from a temp-HOME setup run).
#
# Usage:  bash pi-bootstrap/tests/test-farm-unfarm.sh
# Exit:   0 = all assertions passed, 1 = at least one failure.
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="$ROOT/pi-bootstrap/setup.sh"
MANIFEST="$ROOT/pi-bootstrap/farm-retired.txt"
LIB="$ROOT/pi-bootstrap/lib/farm-retire.sh"
CELL_INSTALL="$ROOT/pi-bootstrap/cell-install.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/farm-unfarm-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
DEST_HOME="$HOME_DIR/.pi/agent"
CELL_HOME="$TMP/cell-home"
CELL_DEST="$CELL_HOME/.pi/agent"
COPY="$TMP/infra"
FAKEBIN="$TMP/bin"
LOG="$TMP/runs.log"
FAILURES=0

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "ok: $*"; }
hdr()  { echo "== $*"; }
: > "$LOG"

# --- hermetic environment -------------------------------------------------
mkdir -p "$HOME_DIR" "$FAKEBIN" "$CELL_HOME"
cat > "$FAKEBIN/npm" <<'EOF'
#!/bin/bash
# Stub: setup.sh / cell-install.sh run `npm install` per extension; keep this offline.
mkdir -p node_modules
echo x > node_modules/.package-lock.json
exit 0
EOF
cat > "$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
# #446: real launchctl must NEVER be reachable from a temp-HOME setup run. install-launchd
# refuses a non-real HOME before it calls launchctl, so a hit here is a failure.
echo "UNEXPECTED launchctl call: $*" >> "${LAUNCHCTL_LOG:?}"
exit 99
EOF
chmod +x "$FAKEBIN/npm" "$FAKEBIN/launchctl"
export LAUNCHCTL_LOG="$TMP/launchctl.log"
: > "$LAUNCHCTL_LOG"
export PATH="$FAKEBIN:$PATH"

# --- a throwaway checkout of this repo, for the end-to-end cases -----------
# setup.sh derives INFRA_ROOT from its own location, so the retirement has to be made IN
# a checkout. Copying is what keeps the real repo read-only; only the copy is edited, and
# only in the two places a real retirement edits (the farm array, the manifest).
mkdir -p "$COPY"
# `tools/` is required by cell-install.sh (`fleet_tools` farms tools/fleet/*.py into
# $DEST/scripts/fleet), not by setup.sh — the COPY has to satisfy both.
cp -R "$ROOT/pi-bootstrap" "$ROOT/scripts" "$ROOT/extensions" "$ROOT/skills" "$ROOT/templates" "$ROOT/tools" "$COPY/"
cp "$ROOT/manifest.json" "$COPY/manifest.json"

# set_fleet_srcs <add|remove> <name> — edit the COPY's fleet_srcs array (one line, as
# ci_runner_gate.test.sh and cell-install.sh also read it).
set_fleet_srcs() {
  python3 - "$1" "$2" "$COPY/pi-bootstrap/setup.sh" <<'PY'
import sys

mode, name, path = sys.argv[1:4]
lines = open(path).read().splitlines(True)
for i, line in enumerate(lines):
    if line.startswith("fleet_srcs=("):
        body = line[len("fleet_srcs=("):].rstrip("\n")
        assert body.endswith(")"), "fleet_srcs line does not end in )"
        names = body[:-1].split()
        if mode == "remove":
            names = [n for n in names if n != name]
        elif mode == "add":
            if name not in names:
                names.append(name)
        else:
            sys.exit("unknown mode %r" % mode)
        lines[i] = "fleet_srcs=(" + " ".join(names) + ")\n"
        open(path, "w").write("".join(lines))
        break
else:
    sys.exit("fleet_srcs=( not found in %s" % path)
PY
}

# declare_retired <path> — append to the COPY's retirement list (the second of the two
# edits a retirement is).
declare_retired() {
  printf '%s\n' "$1" >> "$COPY/pi-bootstrap/farm-retired.txt"
}

# run_setup — the REAL setup.sh, from the COPY, into the temp HOME.
run_setup() {
  echo "---- setup.sh (HOME=$HOME_DIR) ----" >> "$LOG"
  HOME="$HOME_DIR" bash "$COPY/pi-bootstrap/setup.sh" >> "$LOG" 2>&1
}
run_setup_rc() {
  echo "---- setup.sh (expect failure) ----" >> "$LOG"
  HOME="$HOME_DIR" bash "$COPY/pi-bootstrap/setup.sh" >> "$LOG" 2>&1
}

# --- the library, loaded directly for the unit-level cases -----------------
# shellcheck source=/dev/null
. "$LIB"

# ===========================================================================
hdr "(a)+(b) lib: farm two scripts, retire one, re-apply"
UNIT="$TMP/unit"
mkdir -p "$UNIT/dest/scripts"
printf 'survivor\n' > "$UNIT/dest/scripts/keep.sh"
printf 'retired\n'  > "$UNIT/dest/scripts/gone.sh"
printf '# a comment, indented entry below\n\n  scripts/gone.sh  \n' > "$UNIT/manifest.txt"
# The declared set the farm would pass: keep.sh is farmed, gone.sh is not.
DECLARED_UNIT=$'scripts/keep.sh\n'
out="$(farm_unfarm "$UNIT/dest" "$UNIT/manifest.txt" "$DECLARED_UNIT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  fail "(a) farm_unfarm refused a valid retirement (rc=$rc): $out"
elif [ -e "$UNIT/dest/scripts/gone.sh" ]; then
  fail "(a) the retired artifact was NOT removed"
elif [ ! -f "$UNIT/dest/scripts/keep.sh" ]; then
  fail "(a) OVER-DELETE: the still-farmed script was removed"
elif [ "$(cat "$UNIT/dest/scripts/keep.sh")" != "survivor" ]; then
  fail "(a) the surviving script's content changed"
elif ! grep -q 'REMOVED scripts/gone.sh' <<<"$out"; then
  fail "(a) the removal was not reported ($out)"
else
  ok "(a) retired script removed, still-farmed script survived byte-identical, removal reported"
fi
out2="$(farm_unfarm "$UNIT/dest" "$UNIT/manifest.txt" "$DECLARED_UNIT" 2>&1)"; rc2=$?
if [ "$rc2" -ne 0 ]; then
  fail "(b) a re-apply of the same retirement failed (rc=$rc2): $out2"
elif grep -q 'REMOVED' <<<"$out2"; then
  fail "(b) a re-apply removed something again (not idempotent): $out2"
elif ! grep -q 'unfarm: 0 removed' <<<"$out2"; then
  fail "(b) a re-apply did not say it removed nothing (a silent no-op): $out2"
else
  ok "(b) re-apply is idempotent and says ' 0 removed'"
fi

# ===========================================================================
hdr "(c) lib: a retirement that the farm STILL declares removes nothing"
CONTRA="$TMP/contra"
mkdir -p "$CONTRA/dest/scripts"
printf 'a\n' > "$CONTRA/dest/scripts/a.sh"
printf 'b\n' > "$CONTRA/dest/scripts/b.sh"
printf 'scripts/a.sh\nscripts/b.sh\n' > "$CONTRA/manifest.txt"
out="$(farm_unfarm "$CONTRA/dest" "$CONTRA/manifest.txt" $'scripts/b.sh\n' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(c) a contradictory retirement list was accepted (rc=0)"
elif [ ! -f "$CONTRA/dest/scripts/a.sh" ] || [ ! -f "$CONTRA/dest/scripts/b.sh" ]; then
  fail "(c) a contradictory list removed SOMETHING — a half-applied deletion set ($out)"
elif ! grep -q 'still declares it' <<<"$out"; then
  fail "(c) the contradiction was not named in the output ($out)"
else
  ok "(c) contradiction refused, nothing removed, message names it"
fi

# ===========================================================================
hdr "(d) lib: unsafe entries are refused; directories and symlink targets are safe"
SAFE="$TMP/safe"
mkdir -p "$SAFE/dest/scripts"
printf 'canary\n' > "$SAFE/dest/scripts/canary.sh"
printf 'outside\n' > "$SAFE/outside.sh"
mkdir -p "$SAFE/outside-dir" && printf 'outside-dir\n' > "$SAFE/outside-dir/f.sh"
for entry in '../outside.sh' "$SAFE/outside.sh" 'scripts/*' 'scripts/../outside.sh' \
             'extensions/vision-interceptor' 'scripts/a b.sh' 'scripts' 'scripts/' \
             'scripts/$(id).sh' 'scripts/;rm -rf x'; do
  printf '%s\n' "$entry" > "$SAFE/bad.txt"
  if farm_retired_entries "$SAFE/bad.txt" > "$SAFE/bad.out" 2> "$SAFE/bad.err"; then
    fail "(d) unsafe entry ACCEPTED: $entry"
  elif [ -s "$SAFE/bad.out" ]; then
    fail "(d) unsafe entry $entry still produced an entry to act on"
  else
    ok "(d) refused: $entry"
  fi
done
if [ -f "$SAFE/dest/scripts/canary.sh" ] && [ -f "$SAFE/outside.sh" ]; then
  ok "(d) refusals deleted nothing"
else
  fail "(d) a refused entry deleted a file"
fi

# a DIRECTORY is refused, never `rm -rf`
mkdir -p "$SAFE/dest/scripts/fleet" && printf 'x\n' > "$SAFE/dest/scripts/fleet/liveness.py"
printf 'scripts/fleet\n' > "$SAFE/dir.txt"
out="$(farm_unfarm "$SAFE/dest" "$SAFE/dir.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] || [ ! -d "$SAFE/dest/scripts/fleet" ]; then
  fail "(d) a DIRECTORY target was not refused (rc=$rc): $out"
else
  ok "(d) directory target refused, directory intact"
fi

# a symlink is a farm artifact: unlink the LINK, never touch its target
ln -s "$SAFE/outside.sh" "$SAFE/dest/scripts/link.sh"
printf 'scripts/link.sh\n' > "$SAFE/link.txt"
farm_unfarm "$SAFE/dest" "$SAFE/link.txt" '' >/dev/null 2>&1
if [ -e "$SAFE/dest/scripts/link.sh" ] || [ -L "$SAFE/dest/scripts/link.sh" ]; then
  fail "(d) the retired symlink was not removed"
elif [ ! -f "$SAFE/outside.sh" ] || [ "$(cat "$SAFE/outside.sh")" != "outside" ]; then
  fail "(d) removing the farm symlink destroyed its TARGET"
else
  ok "(d) symlink unlinked, target untouched"
fi

# a symlinked PARENT directory cannot be used to reach outside the farm
ln -s "$SAFE/outside-dir" "$SAFE/dest/scripts/escape"
printf 'scripts/escape/f.sh\n' > "$SAFE/escape.txt"
out="$(farm_unfarm "$SAFE/dest" "$SAFE/escape.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] || [ ! -f "$SAFE/outside-dir/f.sh" ]; then
  fail "(d) a symlinked parent escaped the farm (rc=$rc): $out"
else
  ok "(d) symlinked parent refused, outside file intact"
fi

# ===========================================================================
hdr "(e) lib: a missing retirement list is loud, not 'nothing to retire'"
out="$(farm_unfarm "$SAFE/dest" "$TMP/does-not-exist.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(e) a MISSING retirement list was accepted as 'nothing to retire'"
elif ! grep -q 'missing' <<<"$out"; then
  fail "(e) the missing list was not named in the output ($out)"
else
  ok "(e) missing list is an error"
fi

# ===========================================================================
hdr "(f) the repo's own declaration does not intersect the repo's farm"
# INDEPENDENT reader: never the leg's own code and never cell-install's python. It maps
# every farm array in setup.sh by name, plus the checkout-hygiene glob farm, to the paths
# they land at under $DEST — and FAILS on an array it does not know, so a farm added
# without being wired here cannot pass silently (same loud-failure rule as
# cell-install.sh's FARM_LAYOUT).
python3 - "$SETUP" "$ROOT" "$MANIFEST" <<'PY'
import os
import re
import sys

setup_path, root, manifest = sys.argv[1:4]
# array name -> destination dir under $DEST/scripts
LAYOUT = {
    "fleet_srcs": "scripts",
    "merge_gate_srcs": "scripts",
    "lane_root_srcs": "scripts",
    "lane_srcs": "scripts/lane",
    "lib_srcs": "scripts/lib",
    "fleet_tools": "scripts/fleet",
}

src = open(setup_path).read()
arrays = dict(
    (m.group(1), re.findall(r"[^\s\\]+", m.group(2)))
    for m in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)=\((.*?)\)\s*$", src, re.M | re.S)
)
unknown = sorted(n for n in arrays if n not in LAYOUT)
if unknown:
    sys.exit(
        "FAIL: pi-bootstrap/setup.sh declares array(s) this suite does not know: %s\n"
        "      A farm added to setup.sh must be mapped in test-farm-unfarm.sh's LAYOUT,\n"
        "      otherwise the retirement check silently stops covering it." % ", ".join(unknown)
    )

declared = set()
for name, bases in arrays.items():
    for base in bases:
        declared.add(LAYOUT[name] + "/" + base)

# the checkout-hygiene farm is a directory glob (setup.sh skips *.plist and *.test.*)
m = re.search(r'^scripts_dir="\$INFRA_ROOT/([^"]+)"', src, re.M)
if not m:
    sys.exit("FAIL: setup.sh no longer declares scripts_dir=$INFRA_ROOT/... — the checkout-hygiene farm cannot be located")
hyg = os.path.join(root, m.group(1))
for base in sorted(os.listdir(hyg)):
    if base.endswith(".plist") or ".test." in base:
        continue
    if os.path.isfile(os.path.join(hyg, base)):
        declared.add("scripts/" + m.group(1).split("scripts/")[-1] + "/" + base)

retired = []
for line in open(manifest):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    retired.append(line)

overlap = sorted(set(retired) & declared)
if overlap:
    sys.exit(
        "FAIL: pi-bootstrap/farm-retired.txt declares RETIRED path(s) that a farm array STILL declares: %s\n"
        "      The copy leg re-creates them, so the UNFARM leg would refuse on every box and\n"
        "      setup.sh would exit non-zero. Retire a name by removing it from the array too."
        % ", ".join(overlap)
    )
print("ok: (f) %d declared retirement(s), %d farmed path(s), no intersection"
      % (len(retired), len(declared)))
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

# every entry of the real manifest also has to satisfy the path rules
if farm_retired_entries "$MANIFEST" > "$TMP/real-entries.txt" 2> "$TMP/real-entries.err"; then
  ok "(f) every real retirement entry passes the path rules ($(grep -c . "$TMP/real-entries.txt" || true) entry/entries)"
else
  fail "(f) the REAL pi-bootstrap/farm-retired.txt has an unsafe entry: $(cat "$TMP/real-entries.err")"
fi

# ===========================================================================
hdr "(g) end-to-end: setup.sh farms two scripts, one is retired, re-applied"
RETIRED_NAME="probe-one.py"
KEPT_NAME="turn-end.py"

# run 1 — both are farmed
if ! run_setup; then
  fail "(g) setup.sh run 1 failed (see $LOG)"
fi
if [ ! -f "$DEST_HOME/scripts/$RETIRED_NAME" ] || [ ! -f "$DEST_HOME/scripts/$KEPT_NAME" ]; then
  fail "(g) run 1 did not farm both scripts — the retirement case cannot be judged"
else
  kept_sum_before="$(cksum < "$DEST_HOME/scripts/$KEPT_NAME")"
  ok "(g) run 1: both farmed ($RETIRED_NAME, $KEPT_NAME)"

  # run 2 — the retirement, made as a real one is made: array edit + declaration
  set_fleet_srcs remove "$RETIRED_NAME" || fail "(g) could not edit the COPY's fleet_srcs"
  declare_retired "scripts/$RETIRED_NAME"
  if ! run_setup; then
    fail "(g) setup.sh run 2 (the retirement) failed (see $LOG)"
  fi
  if [ -e "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) RETIREMENT DID NOT REACH THE MACHINE: $RETIRED_NAME is still in \$DEST/scripts"
  elif [ ! -f "$DEST_HOME/scripts/$KEPT_NAME" ]; then
    fail "(g) OVER-DELETE: the still-farmed $KEPT_NAME was removed"
  elif [ "$(cksum < "$DEST_HOME/scripts/$KEPT_NAME")" != "$kept_sum_before" ]; then
    fail "(g) the still-farmed $KEPT_NAME changed"
  elif ! grep -q "REMOVED scripts/$RETIRED_NAME" "$LOG"; then
    fail "(g) the removal was not reported in the setup output"
  else
    ok "(g) run 2: retired script gone, still-farmed script survived byte-identical, removal reported"
  fi

  # run 3 — re-apply: still gone, sibling still there, nothing removed
  : > "$LOG"
  if ! run_setup; then
    fail "(g) setup.sh run 3 (re-apply) failed (see $LOG)"
  fi
  if [ -e "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) a re-apply re-created the retired script"
  elif [ ! -f "$DEST_HOME/scripts/$KEPT_NAME" ]; then
    fail "(g) a re-apply lost the still-farmed script"
  elif ! grep -q 'unfarm: 0 removed' "$LOG"; then
    fail "(g) a re-apply did not report ' 0 removed' (idempotency is not observable)"
  else
    ok "(g) run 3 (re-apply): retired still gone, survivor intact, 'unfarm: 0 removed'"
  fi

  # run 4 — the half-done retirement: the array entry is put BACK while the declaration
  # stays. setup.sh must FAIL and must NOT delete what the farm still declares.
  set_fleet_srcs add "$RETIRED_NAME" || fail "(g) could not restore the COPY's fleet_srcs entry"
  : > "$LOG"
  if run_setup_rc; then
    fail "(g) setup.sh ACCEPTED a contradictory state (retired + still farmed)"
  elif [ ! -f "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) a contradictory state DELETED a script the farm still declares"
  elif ! grep -q 'still declares it' "$LOG"; then
    fail "(g) the contradiction was not reported by setup.sh"
  else
    ok "(g) run 4: contradictory list fails the run and the farmed script is (re-)present"
  fi
fi

# ===========================================================================
hdr "(h) the cell half: cell-install applies the same leg and verifies it"
# Back to the real retirement state (array entry removed; declaration kept), which is
# the state a merged retirement leaves the repo in.
set_fleet_srcs remove "$RETIRED_NAME"
: > "$LOG"
if ! CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --install >> "$LOG" 2>&1; then
  fail "(h) cell-install --install failed (see $LOG)"
elif [ -e "$CELL_DEST/scripts/$RETIRED_NAME" ]; then
  fail "(h) a cell still receives the RETIRED script — the unfarm leg did not reach the cell"
elif [ ! -f "$CELL_DEST/scripts/$KEPT_NAME" ]; then
  fail "(h) the cell is missing the still-farmed script"
else
  ok "(h) cell install: retired script absent, still-farmed script present"
fi
if CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify >> "$LOG" 2>&1; then
  ok "(h) cell --verify passes on the retired-absent cell"
else
  fail "(h) cell --verify failed on a correctly retired cell (see $LOG)"
fi
# a stale copy left behind on an existing cell must be REFUSED by --verify (a cell is
# certified by reading the artifact back, never by trusting the installer's own output)
printf 'stale retired dispatcher\n' > "$CELL_DEST/scripts/$RETIRED_NAME"
CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify >> "$LOG" 2>&1
if [ $? -eq 0 ]; then
  fail "(h) cell --verify CERTIFIED a cell that still carries a retired artifact (the false PASS)"
else
  ok "(h) cell --verify refuses a cell that still carries the retired artifact"
fi
if CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --install >> "$LOG" 2>&1 \
   && [ ! -e "$CELL_DEST/scripts/$RETIRED_NAME" ] \
   && CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify >> "$LOG" 2>&1; then
  ok "(h) cell --install removes the stale artifact and --verify then passes"
else
  fail "(h) cell --install did not repair the stale retired artifact (see $LOG)"
fi

# ===========================================================================
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "FAILED: $FAILURES assertion(s) — full log: $LOG" >&2
  exit 1
fi
echo ""
echo "OK: retirement reaches both the laptop (setup.sh) and a cell (cell-install.sh),"
echo "    over-deletion is refused, and a contradictory declaration fails loudly."
