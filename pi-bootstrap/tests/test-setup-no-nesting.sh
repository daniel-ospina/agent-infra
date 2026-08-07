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

# --- done -----------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "FAILURES: $FAILURES — full output: $RUNS_LOG" >&2
  echo "---- last run log ----" >&2
  tail -40 "$RUNS_LOG" >&2 || true
  exit 1
fi
echo ""
echo "OK: no nesting, active files refreshed, farm links preserved (clone path: $CLONE)"
