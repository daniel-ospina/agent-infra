#!/bin/bash
# ============================================================
# test-setup-no-nesting.sh — regression test for issue #93
#
# Verifies that pi-bootstrap/setup.sh:
#   (a) never NESTS cp -R copies into existing destination dirs
#       (BSD `cp -R SRC DEST` with an existing DEST creates
#        dest/agents/agents/... and never updates the active files);
#   (b) refreshes the ACTIVE ~/.pi/agent files on re-runs (repo
#       updates flow in, dest mutations get overwritten by source);
#   (c) preserves the extension/skills symlink farm regardless of
#       the repo's clone path (realpath comparison, not a
#       "/agent-infra" path substring).
#
# Runs the REAL setup.sh against a temp HOME. npm is stubbed so the
# test is hermetic and needs no network. The repo itself is only read
# (a single temporary marker file is added to pi-config and removed
# on exit via trap).
#
# Usage:  bash pi-bootstrap/tests/test-setup-no-nesting.sh
# Exit:   0 = all assertions passed, 1 = at least one failure.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-setup-test.XXXXXX")"
HOME_DIR="$TMP/home"
CLONE="$TMP/repos/clone"          # symlink alias of the repo — no "agent-infra" in path
DEST="$HOME_DIR/.pi/agent"
RUNS_LOG="$TMP/runs.log"
FAILURES=0
SRC_MARKER=""                     # set later; guarded in cleanup

cleanup() {
  [ -n "$SRC_MARKER" ] && rm -f "$SRC_MARKER"
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

# --- hermetic environment -------------------------------------------------
mkdir -p "$HOME_DIR" "$TMP/bin" "$TMP/repos"
cat > "$TMP/bin/npm" <<'EOF'
#!/bin/bash
# Stub: setup.sh runs `npm install` per extension; keep the test offline.
exit 0
EOF
chmod +x "$TMP/bin/npm"
# #446 regression: this test runs the REAL setup.sh under a temp HOME, and
# setup.sh invokes scripts/install-launchd.sh (real launchd, real gui domain).
# Pre-fix, install-launchd bootstrapped the REAL domain with temp-home plists
# whose paths die with this test's TMP dir — observed: provider-latency-
# tripwire registered to a deleted pi-setup-test.*/home path, runs=0 (#446).
# Two-layer defense: (1) this shim shadows the real launchctl so ANY call is
# recorded (exit 99 — a call is a test failure by definition); (2) the
# installer's own temp-HOME guard refuses before calling launchctl, so the
# shim log stays empty. A non-empty log or a missing guard message fails the
# test. The installer happy-path stays covered hermetically by
# scripts/install-launchd.test.sh (fake HOME + shim + ELDATO_ALLOW_TEST_HOME=1).
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/bash
# #446: real launchctl must NEVER be reachable from this temp-HOME setup test.
echo "UNEXPECTED launchctl call: $*" >> "${LAUNCHCTL_LOG:?}"
exit 99
EOF
chmod +x "$TMP/bin/launchctl"
export LAUNCHCTL_LOG="$TMP/launchctl.log"
: > "$LAUNCHCTL_LOG"
export PATH="$TMP/bin:$PATH"
export HOME="$HOME_DIR"

# Run setup.sh from a clone path that does NOT contain "agent-infra", proving
# farm-link recognition is realpath-based, not substring-based.
ln -s "$ROOT" "$CLONE"

# Pre-created farm links, both spellings:
#   1. target via the clone path (no "agent-infra" substring) — old code missed this
#   2. target via the physical repo path (like the live farm) — old code passed by luck
mkdir -p "$DEST/extensions"
ln -s "$CLONE/extensions/mcp-client" "$DEST/extensions/mcp-client"
ln -s "$ROOT/extensions/shared"      "$DEST/extensions/shared"

# --- helpers --------------------------------------------------------------
# Assert no directory exists whose basename equals its parent's basename
# (the `dest/agents/agents` nesting signature) under $1.
check_no_nesting() {
  local base="$1" label="$2" found d
  found="$(find "$base" -type d -print 2>/dev/null | while IFS= read -r d; do
    if [ "$(basename "$(dirname "$d")")" = "$(basename "$d")" ]; then
      echo "$d"
    fi
  done)"
  if [ -n "$found" ]; then
    fail "$label: self-nesting directories found under $base:"
    echo "$found" >&2
  else
    echo "ok: no self-nesting under $base"
  fi
}

# Assert every materialized extension under $1 matches extensions/ byte-for-byte
# (single source of truth, issue #95). Entries named after $2... are skipped
# (they are farm symlinks in this run, not materialized copies). Test files are
# never shipped (pi-config wires only real extensions).
check_content_matches() {
  local dest_ext="$1" label="$2" base e s
  shift 2
  for e in "$ROOT"/extensions/*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in
      *.test.ts) continue ;;
    esac
    for s in "$@"; do
      [ "$s" = "$base" ] && continue 2
    done
    [ -e "$dest_ext/$base" ] || { fail "$label: installed $base missing"; continue; }
    if diff -rq "$e" "$dest_ext/$base" >/dev/null 2>&1; then
      echo "ok: $label installed $base == extensions/$base"
    else
      fail "$label: installed $base differs from extensions/$base (stale copy!)"
    fi
  done
}

# Assert the #36/#101 fixes are present in the INSTALLED code (the exact drift
# issue #95 caught: fresh machines shipping pre-fix extensions).
check_fix_markers() {
  local ext="$1" label="$2"
  grep -q "getSubAgentPath" "$ext/subagent/index.ts" \
    || fail "$label: installed subagent missing getSubAgentPath (#101 fix not shipped)"
  grep -q "#36" "$ext/builtin-tools/index.ts" \
    || fail "$label: installed builtin-tools missing #36 PATH augmentation"
}

run_setup() {
  echo "---- setup.sh run (HOME=$HOME_DIR) ----" >> "$RUNS_LOG"
  bash "$CLONE/pi-bootstrap/setup.sh" >> "$RUNS_LOG" 2>&1
}

# --- run 1: fresh install -------------------------------------------------
echo "== run 1: fresh install"
run_setup

[ -f "$DEST/agents/verifier.md" ] \
  || fail "agents not materialized (verifier.md missing)"
[ -f "$DEST/behavior-control/config.json" ] \
  || fail "behavior-control not materialized (config.json missing)"
if [ -d "$DEST/skills" ] && [ ! -L "$DEST/skills" ]; then
  echo "ok: skills is a real folder"
else
  fail "skills should be a real folder after fresh install"
fi
[ -f "$DEST/extensions/subagent/index.ts" ] \
  || fail "subagent extension not materialized at top level"
[ -f "$DEST/extensions/audit-logger.ts" ] \
  || fail "single-file extension not copied (audit-logger.ts missing)"
check_no_nesting "$DEST" "dest"
check_no_nesting "$ROOT/extensions" "repo-extensions"
if [ -L "$DEST/extensions/mcp-client" ]; then
  echo "ok: farm link mcp-client kept"
else
  fail "farm link mcp-client was replaced by a materialized copy"
fi
if [ -L "$DEST/extensions/shared" ]; then
  echo "ok: farm link shared kept"
else
  fail "farm link shared was replaced by a materialized copy"
fi
[ "$(readlink "$DEST/extensions/mcp-client")" = "$CLONE/extensions/mcp-client" ] \
  || fail "mcp-client link target changed (now: $(readlink "$DEST/extensions/mcp-client" 2>/dev/null))"
[ "$(readlink "$DEST/extensions/shared")" = "$ROOT/extensions/shared" ] \
  || fail "shared link target changed (now: $(readlink "$DEST/extensions/shared" 2>/dev/null))"
grep -q "farm symlinks kept" "$RUNS_LOG" \
  || fail "run 1 did not report kept farm links"
check_content_matches "$DEST/extensions" "run1" mcp-client shared
check_fix_markers "$DEST/extensions" "run1"

# --- run 2: re-run must refresh the ACTIVE files --------------------------
# (a) a dest mutation must be overwritten by the source (content-merge);
# (b) a NEW source file must propagate to the active dir.
echo "== run 2: re-run refresh"
echo "# machine-local mutation" >> "$DEST/agents/verifier.md"
SRC_MARKER="$ROOT/pi-bootstrap/pi-config/agents/zz-setup-test-marker.md"
echo "# issue-93 test marker" > "$SRC_MARKER"

run_setup

if [ -f "$DEST/agents/zz-setup-test-marker.md" ]; then
  echo "ok: new source file propagated to active dir on re-run"
else
  fail "new source file did not propagate to active dir on re-run"
fi
if grep -q "machine-local mutation" "$DEST/agents/verifier.md"; then
  fail "dest mutation survived re-run (active file was not refreshed)"
else
  echo "ok: dest mutation reverted by source on re-run"
fi
[ ! -d "$DEST/agents/agents" ] || fail "nesting appeared after re-run"
check_no_nesting "$DEST" "dest-after-rerun"
check_no_nesting "$ROOT/extensions" "repo-extensions-after-rerun"
if [ -L "$DEST/extensions/mcp-client" ] && [ -L "$DEST/extensions/shared" ]; then
  echo "ok: farm links survived re-run"
else
  fail "farm links lost on re-run"
fi

# --- run 3: stale/foreign links are replaced, not followed -----------------
echo "== run 3: stale/foreign symlink replacement"
ln -s "/nonexistent/pi-93-target" "$DEST/extensions/tortoise-capture"   # broken
ln -s "$TMP/foreign-checkout/extensions" "$DEST/extensions/slack-bridge" # foreign

run_setup

if [ -d "$DEST/extensions/tortoise-capture" ] && [ ! -L "$DEST/extensions/tortoise-capture" ]; then
  echo "ok: broken symlink tortoise-capture replaced with a real folder"
else
  fail "broken symlink tortoise-capture was not replaced (still a link or missing)"
fi
if [ -d "$DEST/extensions/slack-bridge" ] && [ ! -L "$DEST/extensions/slack-bridge" ]; then
  echo "ok: foreign symlink slack-bridge replaced with a real folder"
else
  fail "foreign symlink slack-bridge was not replaced"
fi
[ -f "$DEST/extensions/tortoise-capture/index.ts" ] \
  || fail "replaced tortoise-capture is missing content"
check_no_nesting "$DEST" "dest-after-run3"
if [ -L "$DEST/extensions/mcp-client" ] && [ -L "$DEST/extensions/shared" ]; then
  echo "ok: good farm links still kept after run 3"
else
  fail "good farm links lost during stale-link replacement"
fi

# --- run 4: skills farm symlink preservation ---------------------------------
echo "== run 4: skills farm"
# Point the skills farm into this repo via the clone path (no "agent-infra") —
# the realpath comparison must keep it; the old substring grep would miss it.
rm -rf "$DEST/skills"
ln -s "$CLONE/skills" "$DEST/skills"

run_setup

if [ -L "$DEST/skills" ] && [ "$(readlink "$DEST/skills")" = "$CLONE/skills" ]; then
  echo "ok: skills farm symlink kept (clone-path target)"
else
  fail "skills farm symlink was not kept (now: $(readlink "$DEST/skills" 2>/dev/null || echo 'not a link'))"
fi

# Foreign skills symlink → must be replaced with a real folder.
rm -rf "$DEST/skills"
ln -s "$TMP/foreign-skills" "$DEST/skills"

run_setup

if [ -d "$DEST/skills" ] && [ ! -L "$DEST/skills" ]; then
  echo "ok: foreign skills symlink replaced with a real folder"
else
  fail "foreign skills symlink was not replaced with a real folder"
fi
[ -d "$DEST/skills" ] && [ -n "$(ls -A "$DEST/skills" | head -1)" ] \
  || fail "replaced skills folder is empty"

# --- run 5: completely fresh extensions install (no pre-existing farm) --------
# The exact issue #95 acceptance: a machine with NO prior state must receive the
# CURRENT extension code, as real materialized copies (not links to a clone).
echo "== run 5: fresh extensions install, zero pre-existing links"
rm -rf "$DEST/extensions"
run_setup

links_found="$(find "$DEST/extensions" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
if [ "$links_found" -eq 0 ]; then
  echo "ok: fresh install materialized real copies (no symlinks)"
else
  fail "fresh install left $links_found symlink(s) in $DEST/extensions"
fi
check_content_matches "$DEST/extensions" "run5"
check_fix_markers "$DEST/extensions" "run5"
check_no_nesting "$DEST" "dest-after-run5"

# --- run 6: stale materialized copies self-heal on re-run ---------------------
# A previously-bootstrapped machine has real copies (possibly stale). Re-running
# setup.sh must refresh them to CURRENT extensions/ content.
echo "== run 6: stale DEST copies refreshed to current extensions/ content"
echo "# stale mutation" >> "$DEST/extensions/subagent/index.ts"
echo "# stale mutation" >> "$DEST/extensions/builtin-tools/index.ts"
run_setup
check_content_matches "$DEST/extensions" "run6"
check_fix_markers "$DEST/extensions" "run6"

# --- done -----------------------------------------------------------------
# #446: seven setup.sh runs happened under the temp HOME; the launchctl shim
# must be SILENT (no call escaped to any launchctl) and the installer's
# temp-HOME guard must have refused every time (message present per run).
# Darwin-only in practice (setup.sh reaches install-launchd only on Darwin);
# guarded so a hypothetical Linux CI run can't fail on these assertions.
if [[ "$(uname)" == "Darwin" ]]; then
  setup_runs="$(grep -c '^---- setup.sh run' "$RUNS_LOG")"
  if [ -s "$LAUNCHCTL_LOG" ]; then
    fail "launchctl was called $setup_runs setup-run(s) in: $(cat "$LAUNCHCTL_LOG" | head -1)"
  elif [ "$setup_runs" -ge 1 ]; then
    echo "ok: zero launchctl calls across $setup_runs setup runs (real domain untouched)"
  else
    fail "no setup.sh runs recorded — cannot verify launchctl isolation"
  fi
  guard_hits="$(grep -c 'refusing to manage launchd jobs' "$RUNS_LOG" || true)"
  if [ "$guard_hits" -eq "$setup_runs" ] && [ "$setup_runs" -ge 1 ]; then
    echo "ok: temp-HOME guard fired on all $setup_runs runs"
  else
    fail "temp-HOME guard fired $guard_hits/$setup_runs runs (expected every run)"
  fi
else
  echo "ok: launchctl-isolation assertions skipped (non-Darwin)"
fi
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "FAILURES: $FAILURES — full output: $RUNS_LOG" >&2
  echo "---- last run log ----" >&2
  tail -40 "$RUNS_LOG" >&2 || true
  exit 1
fi
echo ""
echo "OK: no nesting, active files refreshed, farm links preserved (clone path: $CLONE)"
