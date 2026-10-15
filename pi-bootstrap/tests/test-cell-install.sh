#!/bin/bash
# ============================================================
# test-cell-install.sh — regression test for agent-infra#1723
#
# The defect: a cmux cloud cell's ~/.pi/agent carried ONLY models.json, auth.json,
# .ai-review-gate-key, reviews/, state/, audit/ and shims/ — no scripts/ (the directory did
# not exist), no extensions/, no skills/, no AGENTS.md, no settings.json. So a cell lane ran
# with no review-enforcer, no verification-gate, no main-worktree-guard, no search-guard and
# no audit-logger, and its merge path died rc=127 on the missing record-review.sh.
#
# This suite pins `pi-bootstrap/cell-install.sh` (the installer half) by reading the
# ARTIFACT back — never by trusting its output:
#
#   (a) the DECLARED farm set lands, byte-identical, at the layout setup.sh documents —
#       computed by an INDEPENDENT reader in this file, so "installed == declared" is a
#       real cross-check rather than the installer agreeing with itself;
#   (b) the guard extensions land and the surface-absent deny (`cmux-session.ts`) is
#       ENFORCED, including against a previous hand-push;
#   (c) skills + AGENTS.md + settings.json land, and settings.json MERGES (a cell-local key
#       survives a re-run) while AGENTS.md is never overwritten (a machine-global rules file
#       is hand-edited state);
#   (d) a re-run REFRESHES a mutated farm/guard file (the repo copy is the copy that runs);
#   (e) `--verify` refuses a cell missing a guard, a stray entry under ~/.pi/agent/tools/
#       (pi blocks every interactive boot on one, #1277), or an unlocatable checkout — and
#       the tools/ migration removes a legacy tools/fleet/ farm;
#   (f) an npm-less cell is refused rather than certified with a partial layer;
#   (g) the npm child runs with an EMPTY environment (the cell's keys.env is exported into
#       reach of this installer, so an inherited merge key would be readable by any
#       dependency's lifecycle script) and with --ignore-scripts;
#   (h) `--verify` refuses a hand-edited guard EXTENSION and a missing config artifact
#       (agents/) — existence alone was certified before.
#
# Hermetic: the repo is read ONLY, CELL_HOME is a temp dir, npm is stubbed (no network —
# same shape as test-setup-no-nesting.sh). The stub answers for real deps, and it also
# RECORDS what it can see (see (g)); the failure paths of the real npm call are pinned by (f).
#
# Usage:  bash pi-bootstrap/tests/test-cell-install.sh
# Exit:   0 = all assertions passed, 1 = at least one failure.
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$ROOT/pi-bootstrap/cell-install.sh"
SETUP="$ROOT/pi-bootstrap/setup.sh"
MANIFEST="$ROOT/manifest.json"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cell-install-test.XXXXXX")"
CELL_HOME="$TMP/cell-home"
DEST="$CELL_HOME/.pi/agent"
FAKEBIN="$TMP/bin"
LOG="$TMP/runs.log"
FAILURES=0
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "ok: $*"; }
hdr()  { echo "== $*"; }

# --- hermetic environment -------------------------------------------------
mkdir -p "$FAKEBIN" "$CELL_HOME"
SPY="$TMP/npm-spy.log"
cat > "$FAKEBIN/npm" <<EOF
#!/bin/bash
# Stub: cell-install.sh runs npm install per extension; keep this suite offline — but DO
# create node_modules, because the artifact the installer's own --verify reads back is the
# dependency tree npm would have produced.
#
# It also records one line per invocation: first the merge key it can SEE in its
# environment, then its argv. The installer must call it with an EMPTY environment (a
# package's lifecycle script inherits it otherwise) and with --ignore-scripts, so a
# compromised dependency cannot execute at install time. The path is baked in because the
# child deliberately gets no environment to pass one through.
mkdir -p node_modules
{ printf '%s\n' "\${AI_REVIEW_GATE_KEY-CELL_INSTALL_TEST_UNSET}"; printf '%s\n' "\$*"; } >> "$SPY"
exit 0
EOF
chmod +x "$FAKEBIN/npm"

# run_install [PATH-override] — always under the temp CELL_HOME; output appended to $LOG.
run_install() {
  echo "---- cell-install --install ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" PATH="${1:-$FAKEBIN:$PATH}" \
    bash "$INSTALLER" --install >> "$LOG" 2>&1
}
run_verify() {
  echo "---- cell-install --verify ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" PATH="${1:-$FAKEBIN:$PATH}" \
    bash "$INSTALLER" --verify >> "$LOG" 2>&1
}

# --- the INDEPENDENT expected farm set (never the installer's own reader) ---
# setup.sh declares each farm as a single-line array; this reader is deliberately the
# simplest thing that can be right, so agreeing with the installer's python parser means
# something. Emits `path-under-$DEST/scripts<TAB>path-under-$INFRA_ROOT`.
expected_farm_rows() {
  local name dest src rest rel base line req
  for spec in "fleet_srcs||scripts|required" \
              "merge_gate_srcs||scripts|required" \
              "lib_srcs|lib|scripts/lib|required" \
              "fleet_tools|fleet|tools/fleet|required" \
              "lane_root_srcs||scripts|optional" \
              "lane_srcs||scripts|optional"; do
    name="${spec%%|*}"; rest="${spec#*|}"; req="${rest##*|}"; rest="${rest%|*}"
    dest="${rest%%|*}"; src="${rest##*|}"
    line="$(sed -n "s/^${name}=(\(.*\))$/\1/p" "$SETUP")"
    if [ -z "$line" ]; then
      # `optional` = an array that does not exist YET (#1552/#1553's lane farm): the reader is
      # deliberately a SUPERSET of today's declaration, so this suite is not born red on the
      # tree where #1553 lands. The installer's own parser has no such escape (an unknown
      # array is a FATAL), so the two readers still agree on what is installed.
      [ "$req" = "optional" ] || fail "independent reader found no $name=(...) in setup.sh"
      continue
    fi
    for base in $line; do
      if [ -n "$dest" ]; then rel="$dest/$base"; else rel="$base"; fi
      printf '%s\t%s/%s\n' "$rel" "$src" "$base"
    done
  done
  # the checkout-hygiene farm is a directory glob, skipping *.plist and *.test.*
  local f b
  for f in "$ROOT/scripts/checkout-hygiene"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in *.plist|*.test.*) continue ;; esac
    printf 'checkout-hygiene/%s\tscripts/checkout-hygiene/%s\n' "$b" "$b"
  done
}

# --- the INDEPENDENT expected extension set --------------------------------
expected_extension_rows() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for e in ((m.get("files") or {}).get("extensions/") or {}).get("entries") or []:
    print(e.rstrip("/"))
PY
}

# The extensions whose package.json declares real dependencies — the ONLY ones the installer
# may spend an npm run on, and the same predicate --verify uses. Read from the checkout, never
# from the installer.
expected_dep_count() {
  local d n=0
  for d in "$ROOT"/extensions/*/; do
    [ -f "$d/package.json" ] || continue
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("dependencies") else 1)' \
         "$d/package.json" 2>/dev/null; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

# -------------------------------------------------------------------------
hdr "run 1: install into an empty cell home"
# The cell's bring-up sources keys.env with `set -a` BEFORE calling the installer, so the
# merge authority is in this process's environment for real. Export a sentinel so the
# assertion below is falsifiable: without the installer's `env -i`, the spy would see it.
export AI_REVIEW_GATE_KEY="CELL-INSTALL-TEST-MERGE-KEY"
run_install
rc=$?
[ "$rc" -eq 0 ] || fail "install exited $rc (expected 0); log: $LOG"
[ -f "$DEST/scripts/record-review.sh" ] && ok "scripts/ farmed (record-review.sh present)" \
  || fail "scripts/ was not farmed (record-review.sh absent)"

# (a) the declared farm set, byte-identical, at the documented layout — cross-checked
# against this file's own reader, and with NO extra file under $DEST/scripts.
declared="$TMP/declared.txt"; installed="$TMP/installed.txt"
expected_farm_rows > "$TMP/farm-raw.txt"
sort "$TMP/farm-raw.txt" > "$TMP/farm-sorted.txt"
cut -f1 "$TMP/farm-sorted.txt" > "$declared"
( cd "$DEST/scripts" 2>/dev/null && find . -type f | sed 's|^\./||' | sort ) > "$installed"
if [ ! -s "$declared" ]; then
  fail "the independent farm reader produced nothing — the cross-check did not run"
elif diff -q "$declared" "$installed" >/dev/null 2>&1; then
  ok "installed scripts/ == the declared farm set ($(wc -l < "$declared" | tr -d ' ') files, no extras, no gaps)"
else
  fail "installed scripts/ differs from setup.sh's declaration:"
  diff "$declared" "$installed" | sed 's/^/      /' >&2
fi
farm_mismatch=0
while IFS=$'\t' read -r rel srcpath; do
  [ -n "$rel" ] || continue
  [ -f "$DEST/scripts/$rel" ] || { farm_mismatch=1; continue; }
  cmp -s "$ROOT/$srcpath" "$DEST/scripts/$rel" || farm_mismatch=1
done < "$TMP/farm-sorted.txt"
[ "$farm_mismatch" -eq 0 ] && ok "every declared farm file is byte-identical to its repo source" \
  || fail "a declared farm file is missing or differs from the repo copy (stale copy!)"

# (b) guards + the deny
for g in review-enforcer verification-gate main-worktree-guard search-guard audit-logger.ts shared; do
  [ -e "$DEST/extensions/$g" ] && ok "guard installed: extensions/$g" \
    || fail "GUARD MISSING: extensions/$g"
done
if [ -e "$DEST/extensions/cmux-session.ts" ]; then
  fail "cmux-session.ts was installed — a Linux cell has no cmux desktop app (and the repo snapshot is stale v2 vs the live v4, #1138)"
else
  ok "cmux-session.ts is NOT installed (surface-absent deny holds)"
fi
ext_missing=""
ship_list="$(expected_extension_rows)"
if [ -z "$ship_list" ]; then
  fail "the independent manifest reader produced nothing — the extension cross-check did not run"
else
  while IFS= read -r base; do
    [ "$base" = "cmux-session.ts" ] && continue
    [ -e "$DEST/extensions/$base" ] || ext_missing="$ext_missing $base"
  done <<<"$ship_list"
  [ -z "$ext_missing" ] && ok "every manifest ship-list entry except the deny is installed" \
    || fail "manifest entries missing from the cell:$ext_missing"
fi

# (c) skills + config
[ -f "$DEST/skills/commit-workflow/SKILL.md" ] && ok "skills installed (commit-workflow/SKILL.md present)" \
  || fail "skills/ not installed (commit-workflow/SKILL.md absent)"
if cmp -s "$ROOT/templates/AGENTS.base.md" "$DEST/AGENTS.md"; then
  ok "AGENTS.md installed from templates/AGENTS.base.md"
else
  fail "AGENTS.md missing or not the base artifact"
fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("defaultProvider") else 1)' \
  "$DEST/settings.json" && ok "settings.json installed and valid" || fail "settings.json missing or invalid"
[ -f "$DEST/agents/verifier.md" ] && ok "sub-agent definitions installed (agents/verifier.md)" \
  || fail "agents/ not installed — a cell lane cannot dispatch a reviewer sub-agent"
if [ -d "$DEST/tools" ] && [ -n "$(ls -A "$DEST/tools" 2>/dev/null)" ]; then
  fail "installer left entries in \$DEST/tools/ — pi blocks every interactive boot on a non-fd/rg one (#1277)"
else
  ok "\$DEST/tools/ is absent or empty (pi's startup scan stays quiet)"
fi

# (g) The npm child must see NO inherited secret and must not be allowed to run package
# scripts. Proven by what the stub SAW, not by reading the installer's source.
if [ ! -s "$SPY" ]; then
  fail "npm was never invoked — the dependency step is not running, so these assertions would be vacuous"
else
  if grep -q "CELL-INSTALL-TEST-MERGE-KEY" "$SPY"; then
    fail "the npm child INHERITED AI_REVIEW_GATE_KEY — a dependency lifecycle script can read the merge authority"
  else
    ok "npm runs with an EMPTY environment — the exported merge key never reaches a dependency"
  fi
  noscripts="$(awk 'NR % 2 == 0 && $0 !~ /--ignore-scripts/' "$SPY" | wc -l | tr -d ' ')"
  [ "$noscripts" = "0" ] \
    && ok "every npm invocation carries --ignore-scripts (no dependency script executes at install time)" \
    || fail "$noscripts npm invocation(s) ran WITHOUT --ignore-scripts"
  deps="$(expected_dep_count)"
  n="$(awk 'NR % 2 == 1' "$SPY" | wc -l | tr -d ' ')"
  [ "$n" = "$deps" ] \
    && ok "npm ran for exactly the $deps extension(s) that declare dependencies (install and verify agree)" \
    || fail "npm ran $n time(s) but $deps extension(s) declare dependencies — the two halves of the contract disagree"
fi

# -------------------------------------------------------------------------
hdr "run 2: re-run refreshes the active copies and preserves cell-local state"
echo "# cell-local mutation" >> "$DEST/scripts/record-review.sh"
echo "# cell-local mutation" >> "$DEST/extensions/audit-logger.ts"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["cellLocalOnlyKey"]="keep"; json.dump(d, open(p,"w"))' \
  "$DEST/settings.json"
cp "$DEST/AGENTS.md" "$TMP/agents-local.md"
echo "" >> "$DEST/AGENTS.md"          # a hand-edited global rules file
cp "$DEST/AGENTS.md" "$TMP/agents-hand-edited.md"
echo "stale cmux bridge" > "$DEST/extensions/cmux-session.ts"   # a previous hand-push
mkdir -p "$DEST/tools/fleet" && echo "legacy" > "$DEST/tools/fleet/liveness.py"  # the #1277 farm

run_install
rc=$?
[ "$rc" -eq 0 ] || fail "re-run exited $rc (expected 0); log: $LOG"
cmp -s "$ROOT/scripts/record-review.sh" "$DEST/scripts/record-review.sh" \
  && ok "a mutated farmed script was REFRESHED by the re-run" \
  || fail "cell-local mutation to a farmed script survived the re-run"
cmp -s "$ROOT/extensions/audit-logger.ts" "$DEST/extensions/audit-logger.ts" \
  && ok "a mutated guard extension was REFRESHED by the re-run" \
  || fail "cell-local mutation to a guard extension survived the re-run"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("cellLocalOnlyKey")=="keep" else 1)' \
  "$DEST/settings.json" && ok "settings.json MERGED (cell-local key survived the re-run)" \
  || fail "settings.json was clobbered — the cell-local key was lost"
if [ ! -e "$DEST/extensions/cmux-session.ts" ]; then
  ok "a hand-pushed cmux-session.ts was REMOVED by the re-run (the deny is enforced, not decorative)"
else
  fail "a hand-pushed cmux-session.ts survived the re-run"
fi
if [ ! -e "$DEST/tools/fleet" ]; then
  ok "a legacy tools/fleet/ was migrated out of pi's boot-blocking namespace (#1277)"
else
  fail "the legacy tools/fleet/ survived — pi will block every interactive boot"
fi
if [ -f "$DEST/AGENTS.md" ] && cmp -s "$TMP/agents-hand-edited.md" "$DEST/AGENTS.md"; then
  ok "AGENTS.md was NOT overwritten (hand-edited global rules survive a re-run)"
else
  fail "AGENTS.md was replaced by the re-run — a hand-edited global rules file was lost"
fi

# -------------------------------------------------------------------------
hdr "run 3: --verify refuses a cell that is not the layer we certified"
run_verify
[ $? -eq 0 ] && ok "--verify passes on a complete layer" || fail "--verify failed on a complete layer"
# THE OTHER HALF OF THE CONTRACT: --verify must not CREATE the layer path either. A cell
# home with no ~/.pi/agent is a cell without the layer; naming that is not the same as
# creating the directory and then reporting thirty missing files.
FRESH="$TMP/fresh-home"; mkdir -p "$FRESH"
echo "---- cell-install --verify (fresh home) ----" >> "$LOG"
CELL_HOME="$FRESH" INFRA_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
  bash "$INSTALLER" --verify >> "$LOG" 2>&1
rc=$?
[ "$rc" -eq 1 ] || fail "--verify exited $rc against a cell home with no layer (expected 1)"
if [ -e "$FRESH/.pi/agent" ]; then
  fail "--verify CREATED $FRESH/.pi/agent — it is documented as writing nothing"
else
  ok "--verify refuses a cell home with no layer, and creates nothing"
fi
rm -rf "$DEST/extensions/main-worktree-guard"
run_verify
rc=$?
[ "$rc" -eq 1 ] || fail "--verify exited $rc with a GUARD missing (expected 1)"
grep -q "GUARD MISSING: extensions/main-worktree-guard" "$LOG" \
  && ok "--verify names the missing guard and exits 1" \
  || fail "--verify did not name the missing guard"
run_install >/dev/null 2>&1
[ -e "$DEST/extensions/main-worktree-guard" ] && ok "re-install restored the guard" \
  || fail "re-install did not restore the removed guard"

# `--verify` is pointed at LIVE cells, so the tools/ guard may REFUSE content but must not
# tidy: an empty tools/ has to survive it (setup.sh removes it during INSTALL, not verify).
mkdir -p "$DEST/tools"
run_verify
[ $? -eq 0 ] && ok "an empty \$DEST/tools/ is legal, and --verify leaves it in place" \
  || fail "--verify failed against an empty \$DEST/tools/"
[ -d "$DEST/tools" ] || fail "--verify REMOVED an empty \$DEST/tools/ — it writes to a live cell"
echo "# stray" > "$DEST/tools/custom-fleet-tool.py"
run_verify
rc=$?
[ "$rc" -eq 1 ] || fail "--verify exited $rc with a non-fd/rg entry in \$DEST/tools/ (expected 1)"
grep -q "non-fd/rg entries" "$LOG" && grep -q "custom-fleet-tool.py" "$LOG" \
  && ok "--verify refuses a non-fd/rg entry in \$DEST/tools/ and names it (#1277)" \
  || fail "--verify did not name the offending tools/ entry"
# pi's rule is an EXACT match (`dist/migrations.js`: lowercase, then fd/rg/fd.exe/rg.exe, plus
# hidden entries). A PREFIX match passes `rgfoo.py` — a custom tool pi blocks every boot on.
for b in rgfoo.py rg-stray.sh; do
  rm -f "$DEST/tools/custom-fleet-tool.py"; echo "# stray" > "$DEST/tools/$b"
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -q "non-fd/rg entries" "$LOG" \
    && ok "--verify refuses $b (a fd/rg PREFIX is not fd/rg — pi blocks that boot)" \
    || fail "--verify CERTIFIED $b in \$DEST/tools/ — a prefix match is a false PASS"
done
rm -f "$DEST/tools/rgfoo.py" "$DEST/tools/rg-stray.sh"
# fd/rg alone must NOT trip the guard — pi auto-extracts those binaries there.
for b in fd rg; do echo '#!/bin/sh' > "$DEST/tools/$b"; done
run_verify
[ $? -eq 0 ] && ok "fd/rg alone keep \$DEST/tools/ legal (pi's own binaries survive)" \
  || fail "fd/rg in \$DEST/tools/ tripped the guard"
rm -rf "$DEST/tools"

# A hand-edited guard is worse than a missing one: the missing one is loud, the edited one
# reports LAYER VERIFIED. Existence alone used to be the whole check here.
echo "# drift injected by the test" >> "$DEST/extensions/review-enforcer/index.ts"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "extension DIR DIFFERS from the checkout: extensions/review-enforcer" "$LOG" \
  && ok "--verify refuses a hand-edited guard extension (existence is not certification)" \
  || fail "--verify CERTIFIED a hand-edited guard extension — a stale guard would load on the cell"
# The config set used to be installed blind and never read back: a checkout missing
# pi-config/agents produced a certified cell whose lane could dispatch no sub-agent.
rm -rf "$DEST/agents"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "config artifact MISSING: agents" "$LOG" \
  && ok "--verify refuses a cell with no agents/ (pi resolves user-scope sub-agents from it)" \
  || fail "--verify CERTIFIED a cell with no agents/ — a lane could not dispatch a reviewer"
run_install >/dev/null 2>&1
cmp -s "$ROOT/extensions/review-enforcer/index.ts" "$DEST/extensions/review-enforcer/index.ts" \
  && ok "re-install restored the drifted guard and the config set" \
  || fail "re-install did not restore the drifted guard"

# A dependency tree that has VANISHED is a partial layer, and verify cannot see that npm ever
# ran — the install path is gated on npm's exit code, verify has only the artifact.
DEP="$DEST/extensions/builtin-tools"
if [ -d "$DEP/node_modules" ]; then
  mv "$DEP/node_modules" "$TMP/deps-parked"
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -q "DEPENDENCIES MISSING: extensions/builtin-tools" "$LOG" \
    && ok "--verify refuses an extension whose node_modules is gone, naming it (builtin-tools IS the task dispatcher)" \
    || fail "--verify CERTIFIED a cell whose builtin-tools has no node_modules — a partial layer passed"
  mv "$TMP/deps-parked" "$DEP/node_modules"
  run_verify
  [ $? -eq 0 ] && ok "restoring the dependency tree restores a clean --verify" \
    || fail "--verify still fails after the dependency tree was restored"
else
  fail "builtin-tools has no node_modules after an install — the dependency check would be vacuous"
fi

# -------------------------------------------------------------------------
hdr "run 4: an npm-less cell is refused, never certified with a partial layer"
# A curated PATH with no npm. Four extensions import bare packages resolved from their OWN
# node_modules (builtin-tools IS the `task` dispatcher), so a cell without npm cannot receive
# the layer — certifying it would be the same false PASS this installer exists to remove.
NONPM="$TMP/nonpm"; mkdir -p "$NONPM"
for d in /usr/bin /bin /usr/local/bin; do
  [ -d "$d" ] || continue
  for e in "$d"/*; do
    b="$(basename "$e")"
    case "$b" in npm|npx|yarn|pnpm) continue ;; esac
    [ -x "$e" ] || continue
    [ -e "$NONPM/$b" ] || ln -s "$e" "$NONPM/$b" 2>/dev/null
  done
done
P3="$(command -v python3)"; [ -n "$P3" ] && ln -sf "$P3" "$NONPM/python3"
if ! PATH="$NONPM" command -v python3 >/dev/null 2>&1; then
  fail "the npm-less fixture PATH has no python3 — the assertion would be inconclusive"
elif PATH="$NONPM" command -v npm >/dev/null 2>&1; then
  fail "the npm-less fixture PATH still resolves npm — the assertion would be vacuous"
else
  run_install "$NONPM"
  rc=$?
  [ "$rc" -eq 1 ] || fail "install exited $rc with no npm on PATH (expected 1)"
  grep -q "npm is missing" "$LOG" \
    && ok "an npm-less cell is refused, naming npm as the reason" \
    || fail "an npm-less cell was not refused for the missing npm"
fi

# -------------------------------------------------------------------------
hdr "run 5: a failing npm install is a failure, not a warning"
NPMFAIL="$TMP/npmfail"; mkdir -p "$NPMFAIL"
printf '#!/bin/bash\nexit 1\n' > "$NPMFAIL/npm"; chmod +x "$NPMFAIL/npm"
run_install "$NPMFAIL:$PATH"
rc=$?
[ "$rc" -eq 1 ] || fail "install exited $rc when npm failed (expected 1)"
grep -q "npm install failed for" "$LOG" \
  && ok "a failed extension npm install fails the install, naming the extension" \
  || fail "a failed npm install did not surface as a failure"

# -------------------------------------------------------------------------
hdr "run 6: no agent-infra checkout ⇒ refuse, do not half-install"
BARE="$TMP/bare"; mkdir -p "$BARE"; cp "$INSTALLER" "$BARE/cell-install.sh"
out="$(env -u AGENT_INFRA_PATH -u HARNESS -u INFRA_ROOT CELL_HOME="$CELL_HOME" bash "$BARE/cell-install.sh" --verify 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && grep -q "no agent-infra checkout found" <<<"$out"; then
  ok "an unlocatable checkout is refused (rc=1), naming the unguarded and rc=127 consequences"
else
  fail "with no checkout the installer exited $rc without refusing: $(head -1 <<<"$out")"
fi

# -------------------------------------------------------------------------
hdr "run 7: a silently SHRUNK farm parse is refused, never verified clean"
# The installer's own reader is a parse of setup.sh. A parse that stops early (a regex hitting
# the wrong ')', a renamed array) installs FEWER files and then verifies clean against its own
# truncated reading — the instrument agreeing with itself. The floor is what makes it loud.
FAKE="$TMP/fake-infra"
mkdir -p "$FAKE/pi-bootstrap" "$FAKE/scripts/checkout-hygiene" "$FAKE/extensions"
{
  echo '#!/bin/bash'
  echo 'fleet_srcs=(record-review.sh)'
  echo 'scripts_dir="$INFRA_ROOT/scripts/checkout-hygiene"'
} > "$FAKE/pi-bootstrap/setup.sh"
cp "$ROOT/scripts/record-review.sh" "$FAKE/scripts/record-review.sh"
echo "# stub" > "$FAKE/scripts/checkout-hygiene/hub-state-check.sh"
cp "$MANIFEST" "$FAKE/manifest.json"
out="$(CELL_HOME="$TMP/shrunk-home" INFRA_ROOT="$FAKE" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --install 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && grep -q "parsed to only" <<<"$out"; then
  ok "a truncated farm parse is refused by the floor (rc=1), not verified clean"
else
  fail "a truncated farm parse exited $rc without the floor refusing: $(head -2 <<<"$out" | tr '\n' ' ')"
fi

# -------------------------------------------------------------------------
hdr "syntax"
bash -n "$INSTALLER" && ok "cell-install.sh parses (bash -n)" || fail "cell-install.sh has a syntax error"

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILURES: $FAILURES — full run log: $LOG" >&2
  tail -30 "$LOG" >&2 || true
  exit 1
fi
echo "OK: the operational layer installs to a cell, is verified by reading it back, and refuses a partial one."
