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
# WHAT THIS SUITE PINS (each item is a real failure mode, not a restatement of the code):
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
#       a glob, TAB or space, shell metacharacters, the farm root itself) is REFUSED; a
#       DIRECTORY is refused (never `rm -rf`); a symlink is unlinked but its TARGET
#       survives; a symlinked parent directory cannot be used to reach outside the farm,
#       and FOUR different symlink redirects that stay INSIDE $DEST are refused too
#       (`scripts -> state`, `scripts/lib -> ../state`, `scripts/fleet -> scripts`) —
#       "inside $DEST" is not the guard, "exactly the directory the entry names" is.
#   (e) LOUD WHEN UNREADABLE — a missing retirement list AND a present-but-unreadable one
#       (chmod 000) are both ERRORS, never "nothing to retire": an unreadable list is a
#       retirement that is not applied. Plus the SNAPSHOT half: a name that was farmed by
#       a previous apply and is now neither farmed nor retired fails the run.
#   (f) THE REPO'S OWN DECLARATION — the real pi-bootstrap/farm-retired.txt does not
#       intersect the real farm (read by an INDEPENDENT parser in this file, never the
#       leg's own reader), every entry passes the path rules, and every entry's basename
#       is not still targeted by a LIVE launchd plist (edit 3 of the retirement rule —
#       without it, every later sync fails on a broken target).
#   (g) END-TO-END, REAL setup.sh — farms two scripts, records the snapshot, then retires
#       one: FIRST the natural mistake (array entry dropped, nothing declared) must FAIL
#       and leave the file installed; then the declaration (the second edit) removes it
#       while the other script survives byte-identical; a third run is a clean no-op; and
#       putting the array entry BACK (a contradictory list) fails the run and re-creates
#       the farmed file rather than deleting it. The snapshot written here must equal the
#       independent parse, which is what makes a dropped `farm_declared_rel` recording
#       line — or a sixth farm wired into only one place — go red.
#   (h) THE CELL HALF — `cell-install.sh` applies the same leg (so a retirement reaches
#       Linux cells too), records the snapshot, and `--verify` REFUSES a cell that still
#       carries the retired artifact (without it, a cell would be certified while
#       executing a retired script — the false PASS this issue exists to remove).
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
# setup.sh derives INFRA_ROOT from its own location, so a retirement has to be made IN
# a checkout. Copying is what keeps the real repo read-only; only the copy is edited, and
# only in the two places a real retirement edits (the farm array, the manifest). `tools/`
# is required by cell-install.sh (it farms tools/fleet/*.py), not by setup.sh.
mkdir -p "$COPY"
cp -R "$ROOT/pi-bootstrap" "$ROOT/scripts" "$ROOT/extensions" "$ROOT/skills" "$ROOT/templates" "$ROOT/tools" "$COPY/"
cp "$ROOT/manifest.json" "$COPY/manifest.json"

# declared_set.py <setup.sh> <checkout-root> — print the paths a farm DECLARES, relative
# to $DEST, one per line, sorted. An INDEPENDENT reader: never the leg's own code and
# never cell-install.sh's parser, so agreeing with what the installers record means
# something. It FAILS on an array it does not know, so a farm added to setup.sh without
# being wired here cannot pass silently (the same rule as cell-install.sh's FARM_LAYOUT).
cat > "$TMP/declared_set.py" <<'PY'
import os
import re
import sys

setup_path, root = sys.argv[1:3]
# array name -> destination dir under $DEST/scripts
LAYOUT = {
    "fleet_srcs": "scripts",
    "merge_gate_srcs": "scripts",
    "lane_root_srcs": "scripts",
    "lane_srcs": "scripts",      # FARM_LAYOUT: src scripts/lane, DEST scripts (flat)
    "lib_srcs": "scripts/lib",
    "fleet_tools": "scripts/fleet",   # source tools/fleet, DEST scripts/fleet
}

src = open(setup_path).read()
arrays = dict(
    (m.group(1), re.findall(r"[^\s\\]+", m.group(2)))
    for m in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)=\((.*?)\)\s*$", src, re.M | re.S)
)
unknown = sorted(n for n in arrays if n not in LAYOUT)
if unknown:
    sys.exit(
        "pi-bootstrap/setup.sh declares array(s) this suite does not know: %s\n"
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
    sys.exit("setup.sh no longer declares scripts_dir=$INFRA_ROOT/... — the checkout-hygiene farm cannot be located")
hyg = os.path.join(root, m.group(1))
rel_hyg = m.group(1)   # dest path == checkout-relative path (FARM_LAYOUT: scripts/checkout-hygiene)
for base in sorted(os.listdir(hyg)):
    if base.endswith(".plist") or ".test." in base:
        continue
    if os.path.isfile(os.path.join(hyg, base)):
        declared.add(rel_hyg + "/" + base)

print("\n".join(sorted(declared)))
PY

# manifest_entries — the real retirement list's entries (comments/blank lines skipped).
manifest_entries() {
  grep -v '^[[:space:]]*#' "${1:-$MANIFEST}" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

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

# declare_retired <path> — append to the COPY's retirement list (the second of the
# edits a retirement is).
declare_retired() {
  printf '%s\n' "$1" >> "$COPY/pi-bootstrap/farm-retired.txt"
}

run_setup() {
  echo "---- setup.sh (HOME=$HOME_DIR) ----" >> "$LOG"
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
hdr "(c2) lib: a refusal on ONE entry removes NOTHING (the set is validated first)"
# An unfarm is a deletion, so a refusal on the last entry must not leave the earlier ones
# already gone: setup.sh would then abort before launchd convergence with a plist whose
# target the partial deletion removed — a half-applied retirement nobody reviewed.
ATOM="$TMP/atomic"
mkdir -p "$ATOM/dest/scripts/fleet"
printf 'removable\n' > "$ATOM/dest/scripts/a.sh"
printf 'x\n'         > "$ATOM/dest/scripts/fleet/liveness.py"
printf 'scripts/a.sh\nscripts/fleet\n' > "$ATOM/manifest.txt"   # 2nd entry is a DIRECTORY
out="$(farm_unfarm "$ATOM/dest" "$ATOM/manifest.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(c2) a retirement set with an unremovable entry exited 0"
elif [ ! -f "$ATOM/dest/scripts/a.sh" ]; then
  fail "(c2) PARTIAL APPLY: a.sh was removed even though the set could not be applied ($out)"
elif ! grep -q 'NOTHING was removed' <<<"$out"; then
  fail "(c2) the refusal did not say nothing was removed ($out)"
else
  ok "(c2) a set with one unremovable entry removes NOTHING (validated before the first rm)"
fi

# A target that provably cannot be unlinked (read-only parent directory) must be refused by
# VALIDATION, before the first removal — otherwise the removal would fail in pass 2 after
# earlier entries were already deleted (a half-applied retirement).
if [ "$(id -u)" = "0" ]; then
  ok "(c2) skipped the read-only-parent case: running as root, where write permission is not enforced"
else
  RO="$TMP/readonly-parent"
  mkdir -p "$RO/dest/scripts/locked"
  printf 'removable\n' > "$RO/dest/scripts/a.sh"
  printf 'stuck\n'     > "$RO/dest/scripts/locked/b.sh"
  printf 'scripts/a.sh\nscripts/locked/b.sh\n' > "$RO/manifest.txt"
  chmod 555 "$RO/dest/scripts/locked"
  out="$(farm_unfarm "$RO/dest" "$RO/manifest.txt" '' 2>&1)"; rc=$?
  chmod 755 "$RO/dest/scripts/locked"
  if [ "$rc" -eq 0 ]; then
    fail "(c2) a read-only parent was not refused (rc=0)"
  elif [ ! -f "$RO/dest/scripts/a.sh" ]; then
    fail "(c2) a removal failed AFTER earlier entries were deleted (half-applied: $out)"
  elif ! grep -q 'not writable' <<<"$out"; then
    fail "(c2) the read-only parent was not named as the reason ($out)"
  else
    ok "(c2) a read-only parent is refused by validation, so nothing was removed"
  fi

  # ...and the SYMLINK variant: unlinking a link needs write permission on its parent just as
  # a regular file does, so a link in a read-only directory must be refused by VALIDATION too
  # (otherwise it passes pass 1 and fails at the `rm`, after earlier entries are gone).
  ln -s "$RO/outside-target" "$RO/dest/scripts/locked/lnk"
  printf 'scripts/a.sh\nscripts/locked/lnk\n' > "$RO/manifest-link.txt"
  chmod 555 "$RO/dest/scripts/locked"
  out="$(farm_unfarm "$RO/dest" "$RO/manifest-link.txt" '' 2>&1)"; rc=$?
  chmod 755 "$RO/dest/scripts/locked"
  if [ "$rc" -eq 0 ]; then
    fail "(c2) a symlink in a read-only parent was not refused (rc=0)"
  elif [ ! -f "$RO/dest/scripts/a.sh" ]; then
    fail "(c2) a SYMLINK removal failed after earlier entries were deleted (half-applied: $out)"
  elif ! grep -q 'not writable' <<<"$out"; then
    fail "(c2) the symlink's read-only parent was not named as the reason ($out)"
  else
    ok "(c2) a symlink in a read-only parent is refused by validation, so nothing was removed"
  fi
fi

# ===========================================================================
hdr "(d) lib: unsafe entries are refused; directories and symlink targets are safe"
SAFE="$TMP/safe"
mkdir -p "$SAFE/dest/scripts"
printf 'canary\n' > "$SAFE/dest/scripts/canary.sh"
printf 'outside\n' > "$SAFE/outside.sh"
mkdir -p "$SAFE/outside-dir" && printf 'outside-dir\n' > "$SAFE/outside-dir/f.sh"
refused_entry() {   # $1 = entry, tab and space spellings handled by the caller
  printf '%s\n' "$1" > "$SAFE/bad.txt"
  if farm_retired_entries "$SAFE/bad.txt" > "$SAFE/bad.out" 2> "$SAFE/bad.err"; then
    fail "(d) unsafe entry ACCEPTED: $1"
  elif [ -s "$SAFE/bad.out" ]; then
    fail "(d) unsafe entry $1 still produced an entry to act on"
  else
    ok "(d) refused: $1"
  fi
}
refused_entry '../outside.sh'
refused_entry "$SAFE/outside.sh"
refused_entry 'scripts/*'
refused_entry 'scripts/../outside.sh'
refused_entry 'extensions/vision-interceptor'
refused_entry 'scripts/a b.sh'
refused_entry 'scripts/a	b.sh'
refused_entry 'scripts/'
printf 'scripts\n' > "$SAFE/root.txt"
if farm_retired_entries "$SAFE/root.txt" > "$SAFE/root.out" 2> "$SAFE/root.err"; then
  fail "(d) the farm root itself was accepted as a retirement entry"
elif ! grep -q 'farm root itself' "$SAFE/root.err"; then
  fail "(d) 'scripts' was refused by an unrelated branch — the farm-root guard is unreachable: $(cat "$SAFE/root.err")"
else
  ok "(d) refused: scripts (named as the farm root)"
fi
refused_entry 'scripts/$(id).sh'
refused_entry 'scripts/;rm -rf x'
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

# A HARDLINK ALIAS to a still-farmed artifact is refused on SAME-FILE identity. The string
# contradiction check cannot see it, and on a case-insensitive volume (macOS APFS/HFS+, where
# setup.sh runs) `scripts/Record-Review.sh` and `scripts/record-review.sh` are one file — so
# this case stands in for every "different spelling, same artifact" alias.
ALIAS="$TMP/alias"
mkdir -p "$ALIAS/dest/scripts"
printf 'farmed\n' > "$ALIAS/dest/scripts/keep.sh"
ln "$ALIAS/dest/scripts/keep.sh" "$ALIAS/dest/scripts/keep-alias.sh" 2>/dev/null \
  || fail "(d) could not create the hardlink fixture"
printf 'scripts/keep-alias.sh\n' > "$ALIAS/alias.txt"
out="$(farm_unfarm "$ALIAS/dest" "$ALIAS/alias.txt" $'scripts/keep.sh\n' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] || [ ! -f "$ALIAS/dest/scripts/keep.sh" ]; then
  fail "(d) a HARDLINK/case alias of a still-farmed artifact was removed (rc=$rc): $out"
elif ! grep -q 'SAME FILE' <<<"$out"; then
  fail "(d) the same-file refusal was not named ($out)"
else
  ok "(d) a hardlink alias of a still-farmed artifact is refused (SAME FILE)"
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

# ...and the harder half: redirects that stay INSIDE $DEST. "The parent is inside $DEST"
# is NOT the guard — the parent must BE the directory the entry names.
RED="$TMP/redirect"
mkdir -p "$RED/dest/state" "$RED/dest/scripts"
printf 'a runtime lock\n' > "$RED/dest/state/pi-reap-idle.lock"
printf 'still farmed\n' > "$RED/dest/scripts/liveness.py"
ln -s "$RED/dest/state" "$RED/dest/scripts/dirlink"          # farm subdir -> state/
printf 'scripts/dirlink/pi-reap-idle.lock\n' > "$RED/state.txt"
out="$(farm_unfarm "$RED/dest" "$RED/state.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] || [ ! -f "$RED/dest/state/pi-reap-idle.lock" ]; then
  fail "(d) a symlinked farm subdirectory redirected a removal INTO \$DEST/state (rc=$rc): $out"
else
  ok "(d) symlink-into-state refused, the runtime lock survives"
fi
mkdir -p "$RED/dest/scripts/fleet"
ln -s "$RED/dest/scripts" "$RED/dest/scripts/fleet/up"        # fleet/up -> scripts/
printf 'scripts/fleet/up/liveness.py\n' > "$RED/sibling.txt"
out="$(farm_unfarm "$RED/dest" "$RED/sibling.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] || [ ! -f "$RED/dest/scripts/liveness.py" ]; then
  fail "(d) a symlinked sibling subdirectory unlinked a DIFFERENT still-farmed file (rc=$rc): $out"
else
  ok "(d) sibling-redirect refused, the still-farmed file survives"
fi

# ===========================================================================
hdr "(e) lib: a missing or UNREADABLE list is loud, and an orphaned name fails"
out="$(farm_unfarm "$SAFE/dest" "$TMP/does-not-exist.txt" '' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(e) a MISSING retirement list was accepted as 'nothing to retire'"
elif ! grep -q 'missing' <<<"$out"; then
  fail "(e) the missing list was not named in the output ($out)"
else
  ok "(e) missing list is an error"
fi
if [ "$(id -u)" = "0" ]; then
  ok "(e) skipped the unreadable-list pin: running as root, where chmod 000 does not block a read"
else
  printf 'scripts/canary.sh\n' > "$SAFE/unreadable.txt"
  chmod 000 "$SAFE/unreadable.txt"
  out="$(farm_unfarm "$SAFE/dest" "$SAFE/unreadable.txt" '' 2>&1)"; rc=$?
  chmod 644 "$SAFE/unreadable.txt"
  if [ "$rc" -eq 0 ]; then
    fail "(e) an UNREADABLE retirement list was accepted as 'nothing to retire' (rc=0): $out"
  elif grep -q 'no retirements declared' <<<"$out"; then
    fail "(e) an unreadable list reported 'no retirements declared' — a false PASS: $out"
  elif [ ! -f "$SAFE/dest/scripts/canary.sh" ]; then
    fail "(e) a refused (unreadable) run removed something"
  else
    ok "(e) unreadable list is an error, nothing removed"
  fi
fi

# `[ -e ]` answers FALSE for "cannot be read" exactly as it does for "absent", so an artifact
# under a directory that is not searchable (mode 000, another user's, an ACL, NFS root-squash)
# read as ALREADY RETIRED: rc 0, "0 removed", and `--verify` certified the cell while the
# retired script was still deployed. The three states must stay three.
if [ "$(id -u)" = "0" ]; then
  ok "(e) skipped the unreadable-location pins: running as root, where directory permissions are not enforced"
else
  HID="$TMP/hidden"
  mkdir -p "$HID/dest/scripts/legacy"
  printf 'stale dispatcher\n' > "$HID/dest/scripts/legacy/old.sh"
  printf 'scripts/legacy/old.sh\n' > "$HID/manifest.txt"
  chmod 000 "$HID/dest/scripts/legacy"
  out="$(farm_unfarm "$HID/dest" "$HID/manifest.txt" '' 2>&1)"; rc=$?
  chmod 755 "$HID/dest/scripts/legacy"
  if [ "$rc" -eq 0 ]; then
    fail "(e) a retirement under an UNREADABLE directory exited 0 ('already absent') while the artifact was still there: $out"
  elif ! grep -q 'cannot be read' <<<"$out"; then
    fail "(e) the unreadable location was not named as the reason ($out)"
  elif grep -q 'already absent' <<<"$out"; then
    fail "(e) an unreadable location was counted as 'already absent' (indistinguishable from a real retirement): $out"
  else
    ok "(e) an unreadable location is a refusal, not 'already absent'"
  fi
  # ...and the shrink check must not read it as "nothing deployed, nothing to orphan".
  : > "$HID/empty.txt"
  farm_record_declared "$HID/dest" $'scripts/legacy/old.sh\nscripts/other.sh\n' >/dev/null 2>&1
  chmod 000 "$HID/dest/scripts/legacy"
  out="$(farm_check_declared_shrink "$HID/dest" "$HID/empty.txt" $'scripts/other.sh\n' 2>&1)"; rc=$?
  chmod 755 "$HID/dest/scripts/legacy"
  if [ "$rc" -eq 0 ]; then
    fail "(e) the shrink check treated an unreadable location as 'not installed' and stayed green"
  elif ! grep -q 'cannot tell whether' <<<"$out"; then
    fail "(e) the shrink check did not say the answer was unknowable ($out)"
  else
    ok "(e) the shrink check refuses to guess when the location cannot be read"
  fi
fi

# THE SNAPSHOT HALF: a name farmed by the previous apply and now neither farmed nor
# retired is the "dropped from the array, forgot to declare it" mistake, which no set
# comparison can see.
SNAP="$TMP/snap"
mkdir -p "$SNAP/dest/scripts"
printf 'a\n' > "$SNAP/dest/scripts/a.sh"
printf 'b\n' > "$SNAP/dest/scripts/b.sh"   # deployed: an orphan is a file that EXISTS here
printf 'scripts/a.sh\nscripts/b.sh\n' > "$SNAP/manifest.txt"
: > "$SNAP/manifest-empty.txt"
farm_record_declared "$SNAP/dest" $'scripts/a.sh\nscripts/b.sh\n' >/dev/null 2>&1
out="$(farm_check_declared_shrink "$SNAP/dest" "$SNAP/manifest-empty.txt" $'scripts/a.sh\n' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(e) a name dropped from the farm and not declared was NOT reported (the silent-orphan case)"
elif ! grep -q 'scripts/b.sh' <<<"$out"; then
  fail "(e) the orphan report did not name the orphaned path ($out)"
else
  ok "(e) a farmed-but-now-undeclared name is reported as orphaned"
fi
out="$(farm_check_declared_shrink "$SNAP/dest" "$SNAP/manifest-empty.txt" $'scripts/a.sh\nscripts/b.sh\n' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "(e) nothing dropped -> clean" || fail "(e) a clean declaration was reported as a shrink ($out)"
out="$(farm_check_declared_shrink "$SNAP/dest" "$SNAP/manifest.txt" $'scripts/a.sh\n' 2>&1)"; rc=$?
# b.sh is retired now, so it is not an orphan — a retirement must not read as a shrink
[ "$rc" -eq 0 ] && ok "(e) a RETIRED name is not reported as an orphan" || fail "(e) a declared retirement read as a shrink ($out)"

# A DECLARED-BUT-NEVER-INSTALLED path is not an orphan either. The snapshot records what a
# previous run DECLARED (appended before the copy leg decides the file exists), so a box whose
# checkout was incomplete has entries with nothing behind them. Reporting those would block
# every later sync over a file that is not on disk, and the prescribed remedy (declare it
# retired) would remove nothing.
rm -f "$SNAP/dest/scripts/b.sh"
out="$(farm_check_declared_shrink "$SNAP/dest" "$SNAP/manifest-empty.txt" $'scripts/a.sh\n' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  fail "(e) a path with NOTHING DEPLOYED was reported as an orphan and would block the sync: $out"
elif grep -q 'ORPHAN\|NEITHER' <<<"$out"; then
  fail "(e) an undeployed path produced orphan wording: $out"
else
  ok "(e) a declared-but-never-installed path is not an orphan"
fi

# ===========================================================================
hdr "(f) the repo's own declaration: no intersection, no live plist, valid entries"
DECLARED_REPO="$(python3 "$TMP/declared_set.py" "$SETUP" "$ROOT")" \
  || fail "(f) the independent farm reader failed (see above)"
RETIRED_REPO="$(manifest_entries "$MANIFEST")"
overlap=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if grep -qxF -- "$entry" <<<"$DECLARED_REPO"; then overlap="$overlap $entry"; fi
done <<<"$RETIRED_REPO"
if [ -n "$overlap" ]; then
  fail "(f) pi-bootstrap/farm-retired.txt declares RETIRED path(s) that a farm array STILL declares:$overlap — the copy leg re-creates them, so every sync would fail"
else
  ok "(f) no intersection between $(printf '%s' "$RETIRED_REPO" | grep -c . || true) declared retirement(s) and $(printf '%s' "$DECLARED_REPO" | grep -c . || true) farmed path(s)"
fi
if farm_retired_entries "$MANIFEST" > "$TMP/real-entries.txt" 2> "$TMP/real-entries.err"; then
  ok "(f) every real retirement entry passes the path rules"
else
  fail "(f) the REAL pi-bootstrap/farm-retired.txt has an unsafe entry: $(cat "$TMP/real-entries.err")"
fi
# EDIT 3 of the retirement rule: a retired script whose plist is still installed makes
# install-launchd fail on a broken target — on EVERY box, on EVERY sync (sync.sh runs the
# installer bare under `set -e`). Catch the pairing at merge time instead.
plist_gap=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  base="$(basename "$entry")"
  for plist in "$ROOT"/templates/launchd/*.plist; do
    [ -f "$plist" ] || continue
    grep -qF -- "$base" "$plist" || continue
    label="$(basename "$plist" .plist)"
    if ! grep -qxF -- "$label" <<<"$(grep -v '^[[:space:]]*#' "$ROOT/templates/launchd/RETIRED" | grep -v '^[[:space:]]*$')"; then
      plist_gap="$plist_gap $label($base)"
    fi
  done
done <<<"$RETIRED_REPO"
if [ -n "$plist_gap" ]; then
  fail "(f) a retired script is still targeted by a LIVE plist:$plist_gap — add the label to templates/launchd/RETIRED (edit 3), or every later sync fails on a broken target"
else
  ok "(f) no retired script is still targeted by a live launchd plist"
fi

# ===========================================================================
hdr "(g) end-to-end: setup.sh farms two scripts, one is retired, re-applied"
RETIRED_NAME="probe-one.py"
KEPT_NAME="turn-end.py"

run_setup
if [ ! -f "$DEST_HOME/scripts/$RETIRED_NAME" ] || [ ! -f "$DEST_HOME/scripts/$KEPT_NAME" ]; then
  fail "(g) run 1 did not farm both scripts — the retirement case cannot be judged (see $LOG)"
else
  kept_sum_before="$(cksum < "$DEST_HOME/scripts/$KEPT_NAME")"
  ok "(g) run 1: both farmed ($RETIRED_NAME, $KEPT_NAME)"

  # The snapshot is the assertion that the DECLARED-SET WIRING is complete: every farm
  # loop must record what it declares. Drop one recording line, or wire a sixth farm in
  # only one place, and this comparison goes red — otherwise the contradiction guard
  # silently stops covering that farm.
  snapshot="$DEST_HOME/state/farm-declared.txt"
  declared_copy="$(python3 "$TMP/declared_set.py" "$COPY/pi-bootstrap/setup.sh" "$COPY")"
  if [ ! -f "$snapshot" ]; then
    fail "(g) run 1 did not record the farm declaration snapshot ($snapshot)"
  elif [ "$(LC_ALL=C sort -u "$snapshot")" = "$(printf '%s\n' "$declared_copy" | LC_ALL=C sort -u)" ]; then
    ok "(g) run 1: the recorded snapshot equals the independent parse of the declared set"
  else
    fail "(g) the recorded snapshot DIFFERS from the independent parse — a farm loop is not recording what it declares:
$(diff <(LC_ALL=C sort -u "$snapshot") <(printf '%s\n' "$declared_copy" | LC_ALL=C sort -u) | head -10)"
  fi

  # run 2 — the NATURAL MISTAKE: the array entry is dropped and nothing is declared.
  # The deployed copy would be orphaned; the snapshot check must catch it and NOT delete.
  set_fleet_srcs remove "$RETIRED_NAME" || fail "(g) could not edit the COPY's fleet_srcs"
  if HOME="$HOME_DIR" bash "$COPY/pi-bootstrap/setup.sh" >> "$LOG" 2>&1; then
    fail "(g) setup.sh ACCEPTED a name dropped from the farm without a retirement declaration"
  elif [ ! -f "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) the orphan case DELETED the file instead of refusing"
  elif ! grep -q 'NEITHER farmed NOR retired' "$LOG"; then
    fail "(g) the orphan case was not reported by setup.sh"
  else
    ok "(g) run 2: a name dropped without a declaration fails the sync and stays installed"
  fi

  # run 3 — the second edit: declare it. Now it is removed, and the survivor is untouched.
  declare_retired "scripts/$RETIRED_NAME"
  if ! run_setup; then
    fail "(g) setup.sh run 3 (the declared retirement) failed (see $LOG)"
  fi
  if [ -e "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) RETIREMENT DID NOT REACH THE MACHINE: $RETIRED_NAME is still in \$DEST/scripts"
  elif [ ! -f "$DEST_HOME/scripts/$KEPT_NAME" ]; then
    fail "(g) OVER-DELETE: the still-farmed $KEPT_NAME was removed"
  elif [ "$(cksum < "$DEST_HOME/scripts/$KEPT_NAME")" != "$kept_sum_before" ]; then
    fail "(g) the still-farmed $KEPT_NAME changed"
  elif ! grep -q "REMOVED scripts/$RETIRED_NAME" "$LOG"; then
    fail "(g) the removal was not reported in the setup output"
  elif grep -qxF -- "scripts/$RETIRED_NAME" "$snapshot"; then
    fail "(g) the snapshot still lists the retired path — the next run would report it as orphaned"
  else
    ok "(g) run 3: retired script gone, still-farmed script survived byte-identical, snapshot updated"
  fi

  # run 4 — re-apply: still gone, sibling still there, nothing removed
  : > "$LOG"
  if ! run_setup; then
    fail "(g) setup.sh run 4 (re-apply) failed (see $LOG)"
  fi
  if [ -e "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) a re-apply re-created the retired script"
  elif [ ! -f "$DEST_HOME/scripts/$KEPT_NAME" ]; then
    fail "(g) a re-apply lost the still-farmed script"
  elif ! grep -q 'unfarm: 0 removed' "$LOG"; then
    fail "(g) a re-apply did not report ' 0 removed' (idempotency is not observable)"
  else
    ok "(g) run 4 (re-apply): retired still gone, survivor intact, 'unfarm: 0 removed'"
  fi

  # run 5 — the half-done retirement: the array entry is put BACK while the declaration
  # stays. setup.sh must FAIL and must NOT delete what the farm still declares.
  set_fleet_srcs add "$RETIRED_NAME" || fail "(g) could not restore the COPY's fleet_srcs entry"
  : > "$LOG"
  if HOME="$HOME_DIR" bash "$COPY/pi-bootstrap/setup.sh" >> "$LOG" 2>&1; then
    fail "(g) setup.sh ACCEPTED a contradictory state (retired + still farmed)"
  elif [ ! -f "$DEST_HOME/scripts/$RETIRED_NAME" ]; then
    fail "(g) a contradictory state DELETED a script the farm still declares"
  elif ! grep -q 'still declares it' "$LOG"; then
    fail "(g) the contradiction was not reported by setup.sh"
  else
    ok "(g) run 5: contradictory list fails the run and the farmed script is (re-)present"
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
elif [ ! -f "$CELL_DEST/state/farm-declared.txt" ]; then
  fail "(h) the cell install did not record the farm declaration snapshot"
else
  ok "(h) cell install: retired script absent, still-farmed script present, snapshot recorded"
fi
if CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify >> "$LOG" 2>&1; then
  ok "(h) cell --verify passes on the retired-absent cell"
else
  fail "(h) cell --verify failed on a correctly retired cell (see $LOG)"
fi
# a stale copy left behind on an existing cell must be REFUSED by --verify (a cell is
# certified by reading the artifact back, never by trusting the installer's own output)
printf 'stale retired dispatcher\n' > "$CELL_DEST/scripts/$RETIRED_NAME"
out="$(CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(h) cell --verify CERTIFIED a cell that still carries a retired artifact (the false PASS)"
elif grep -q 'declared retirement(s) absent from the cell' <<<"$out"; then
  fail "(h) cell --verify printed 'verified … absent' for the leg it just FAILED (its report contradicts its verdict)"
else
  ok "(h) cell --verify refuses a cell carrying the retired artifact, and does not claim it verified it"
fi
if CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --install >> "$LOG" 2>&1 \
   && [ ! -e "$CELL_DEST/scripts/$RETIRED_NAME" ] \
   && CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify >> "$LOG" 2>&1; then
  ok "(h) cell --install removes the stale artifact and --verify then passes"
else
  fail "(h) cell --install did not repair the stale retired artifact (see $LOG)"
fi
# --- the two DIRECTIONS of a snapshot mismatch advise different things -----------------
# The cell's layer is OLDER than its checkout: a newly farmed file was never installed here.
# The remedy is --install. A message prescribing "declare it retired" would be wrong, and
# following it puts a name in the retirement list that the farm still declares — after which
# every --install refuses (the contradiction path). This pins both the advice and the remedy.
printf 'probe\n' > "$COPY/scripts/new-probe.sh"
set_fleet_srcs add new-probe.sh || fail "(h) could not add a farmed file to the COPY"
out="$(CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(h) --verify passed although the checkout declares a file the cell never installed"
elif ! grep -q 'NOT installed here: scripts/new-probe.sh' <<<"$out"; then
  fail "(h) the older-layer direction was not reported as 'not installed here': $(grep -m1 'DIFFERS\|not this checkout' <<<"$out")"
elif grep -q 'must ALSO be declared' <<<"$out"; then
  fail "(h) the older-layer direction was reported as a RETIREMENT (following that advice makes --install refuse forever)"
else
  ok "(h) an older cell layer is reported as 'not installed here' + 're-run --install', not as a retirement"
fi
if CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --install >> "$LOG" 2>&1 \
   && CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify >> "$LOG" 2>&1; then
  ok "(h) --install is the remedy for an older layer: the snapshot re-records and --verify passes"
else
  fail "(h) --install did not resolve an older-layer snapshot mismatch (see $LOG)"
fi

# The OTHER direction: the cell has a file the checkout no longer farms (a retirement that
# was not declared, or a checkout older than the installed layer). --verify must name it as
# "no longer farmed" and --install must REFUSE (it does not delete what it no longer farms,
# and it will not orphan it either) — so the advice must not be "just re-run --install".
set_fleet_srcs remove new-probe.sh || fail "(h) could not remove the farm entry from the COPY"
out="$(CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --verify 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "(h) --verify passed although the cell carries a farmed file this checkout no longer farms"
elif ! grep -q 'no longer farmed by this checkout: scripts/new-probe.sh' <<<"$out"; then
  fail "(h) the older-checkout direction was not named: $(grep -m1 'no longer farmed\|not this checkout' <<<"$out")"
elif ! grep -q 'refuses to orphan' <<<"$out"; then
  fail "(h) the gone direction did not say --install refuses to orphan it"
else
  ok "(h) a file the checkout no longer farms is named, and the advice does not promise --install will fix it"
fi
if CELL_HOME="$CELL_HOME" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --install >> "$LOG" 2>&1; then
  fail "(h) --install did NOT refuse to orphan the still-installed name"
elif [ ! -f "$CELL_DEST/scripts/new-probe.sh" ]; then
  fail "(h) --install deleted the orphaned name instead of refusing"
else
  ok "(h) --install refuses to orphan a still-installed name (and deletes nothing)"
fi
set_fleet_srcs add new-probe.sh || fail "(h) could not restore the COPY's farm entry"

# a checkout without the UNFARM leg must be refused BEFORE anything is copied (a cell
# half-installed by a resolver that accepted an incomplete tree is #1723's state)
NOLIB="$TMP/nolib-checkout"
mkdir -p "$NOLIB"
cp -R "$COPY/pi-bootstrap" "$COPY/scripts" "$COPY/extensions" "$COPY/skills" "$COPY/templates" "$COPY/tools" "$NOLIB/"
cp "$COPY/manifest.json" "$NOLIB/"
rm -rf "$NOLIB/pi-bootstrap/lib"
# AGENT_INFRA_PATH/HARNESS are UNSET on purpose: with them set, the resolver falls back to
# the ambient checkout (a valid candidate) and the case would install from THAT instead of
# proving anything about the incomplete tree.
# The script is invoked from the INCOMPLETE tree on purpose: `$SELF_DIR/..` is one of the
# resolver's own candidates, so invoking the real repo's copy would resolve to a valid
# checkout and prove nothing.
if env -u AGENT_INFRA_PATH -u HARNESS CELL_HOME="$TMP/nolib-home" INFRA_ROOT="$NOLIB" \
     bash "$NOLIB/pi-bootstrap/cell-install.sh" --install >> "$LOG" 2>&1; then
  fail "(h) cell-install accepted a checkout with no UNFARM leg (it would half-install)"
elif [ -e "$TMP/nolib-home/.pi/agent/scripts" ]; then
  fail "(h) cell-install MUTATED the cell before refusing a checkout with no UNFARM leg"
else
  ok "(h) a checkout with no UNFARM leg is refused before anything is written"
fi

# A PRESENT-but-EMPTY checkout-hygiene farm must be refused by the cell too. It emits zero
# rows, MIN_FARM_FILES is satisfied by the other ~50 files, and nothing else counts the leg —
# so without this the cell installs an EMPTY leg and certifies it (a false PASS). setup.sh
# refuses the same shape; the two installers must agree, or a Linux cell is the blind one.
mv "$COPY/scripts/checkout-hygiene" "$TMP/hyg-save"
mkdir -p "$COPY/scripts/checkout-hygiene"
out="$(CELL_HOME="$TMP/empty-hyg-home" INFRA_ROOT="$COPY" bash "$CELL_INSTALL" --install 2>&1)"; rc=$?
rmdir "$COPY/scripts/checkout-hygiene"
mv "$TMP/hyg-save" "$COPY/scripts/checkout-hygiene"
if [ "$rc" -eq 0 ]; then
  fail "(h) cell-install accepted a checkout whose checkout-hygiene farm is EMPTY (it would install and certify an empty leg)"
elif ! grep -q 'would install as EMPTY' <<<"$out"; then
  fail "(h) the empty farm leg was refused for the wrong reason: $(head -1 <<<"$out")"
elif [ -e "$TMP/empty-hyg-home/.pi/agent/scripts" ]; then
  fail "(h) the cell was mutated before the empty-farm refusal"
else
  ok "(h) an EMPTY checkout-hygiene farm is refused by the cell before anything is installed"
fi

# An EXPLICIT INFRA_ROOT that is not a checkout must not be replaced SILENTLY by a different
# one: the farm arrays would then be paired with a checkout (and, since #1924, a retirement
# list) the operator never named. The run still falls through to a complete checkout — that is
# the ambient default — but it says so where the swap happens.
out="$(env -u HARNESS AGENT_INFRA_PATH="$COPY" CELL_HOME="$TMP/warn-home" INFRA_ROOT="$NOLIB" \
        bash "$NOLIB/pi-bootstrap/cell-install.sh" --install 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  fail "(h) the run with an invalid INFRA_ROOT and a valid fallback failed instead of falling back (rc=$rc): $(head -2 <<<"$out")"
elif ! grep -q 'refused (INFRA_ROOT is not a checkout' <<<"$out"; then
  fail "(h) an invalid INFRA_ROOT was replaced by another checkout in SILENCE"
else
  ok "(h) an invalid INFRA_ROOT is named as refused before the fallback is used"
fi

# ===========================================================================
hdr "(i) an INCOMPLETE checkout fails loudly instead of reading as a retirement"
# A farm array DECLARES what the checkout ships. A listed name that is not in the checkout
# used to be skipped in silence (#1931), and since #1924 that silence is worse: the name is
# recorded as declared, so on a later run it looks orphaned — and the orphan advice ("declare
# it retired") would then delete an artifact the repo still ships. Measured on the real
# script: a checkout missing scripts/checkout-hygiene/ produced eight "retirements".
rm -f "$COPY/scripts/$KEPT_NAME"
: > "$LOG"
if HOME="$HOME_DIR" bash "$COPY/pi-bootstrap/setup.sh" >> "$LOG" 2>&1; then
  fail "(i) setup.sh accepted a checkout that is missing a farm file it declares"
elif ! grep -q 'INCOMPLETE' "$LOG"; then
  fail "(i) the incomplete checkout was not named as such"
elif ! grep -q "scripts/$KEPT_NAME" "$LOG"; then
  fail "(i) the missing farm file was not named in the failure"
elif grep -q 'NEITHER farmed NOR retired' "$LOG"; then
  fail "(i) a missing farm file reached the orphan advice (which would lead to a WRONG retirement)"
else
  ok "(i) a missing farm file fails the run, names it, and never reaches the orphan advice"
fi
cp "$ROOT/scripts/$KEPT_NAME" "$COPY/scripts/$KEPT_NAME"

# ===========================================================================
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "FAILED: $FAILURES assertion(s) — full log: $LOG" >&2
  exit 1
fi
echo ""
echo "OK: retirement reaches both the laptop (setup.sh) and a cell (cell-install.sh),"
echo "    over-deletion is refused, an undeclared drop is caught, and a contradictory"
echo "    declaration fails loudly."
