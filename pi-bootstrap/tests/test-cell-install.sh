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
# ARTIFACT back — never by trusting its output. The list below is the load-bearing set, not an
# inventory of every assertion:
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
#   (e2) `--verify` compares the WHOLE skills tree against the checkout (a missing SKILL.md, a
#       missing support file under references//workflow//templates/, or a hand-edited skill is
#       refused, and so is a tree it cannot compare IN FULL: an unreadable subtree or a
#       symlinked entry) and refuses an EMPTY AGENTS.md — skills/ was existence-plus-non-empty
#       until #1723's `--check` began verifying before it installs, which made a weak read-back
#       the difference between repairing a partial tree and certifying it;
#   (f) an npm-less cell is refused rather than certified with a partial layer;
#   (g) the npm child runs with a SCRUBBED environment — an allowlisted proxy/registry only,
#       never the keys.env the cell exported — and with --ignore-scripts;
#   (h) `--verify` refuses a hand-edited guard EXTENSION and a missing config artifact
#       (agents/) — existence alone was certified before;
#   (i) `--verify` on a tree it cannot compare IN FULL: a shipped SYMLINK is REFUSED (copied
#       as a link, never byte-compared), a LINKED node_modules is NOT (an excluded namespace),
#       and a shipped file whose name carries a newline is REFUSED (the line-based list is
#       lossy) — as are an emptied tree (either loop) and a subtree it cannot read; a
#       symlinked source DIRECTORY is followed rather than called empty;
#   (j) `--verify` refuses an extension whose dependency tree is MISSING (it declares runtime
#       deps but has no node_modules), and refuses a CONFIG copy that fails instead of
#       reporting the config set as installed.
#   (k) the pi SPAWN-POINT gate (#1884) lands byte-identical at $DEST/bin/pi, is executable, and
#       REFUSES an over-ceiling spawn when RUN as `pi` — the installed artifact is driven, not
#       just compared — while `--verify` refuses a stale, missing or non-executable copy. The
#       defect: a hand-written runner that never sources spawn-gate.sh started lanes on a box at
#       load 258 against its own ceiling of 100, and nothing refused, logged or counted.
#   (l) the ARGV-LEVEL `gh` SHIM (#984) lands from the SAME farm declaration the laptop uses, is
#       executable, sits on the path the review-enforcer actually resolves, CONSULTS the installed
#       evidence verifier, refuses an unevidenced admin merge when DRIVEN, and is REFUSED BY NAME by
#       `--verify` when absent, non-executable, or missing its verifier. The defect: on a cell the
#       extensions are copies, so `EXTENSION_DIR/../../scripts/gh-shim` was a directory nothing
#       farmed — every lane ran the merge gate DEGRADED (string scanner only) while the cell
#       reported its layer verified.
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
# The argv-level `gh` shim (#984) is part of what this suite certifies, so its runtime switches
# must not leak in from the operator's shell: `AGENT_GH_SHIM_DIR` would MOVE the shim the verifier
# checks, `AGENT_GH_SHIM=0` would switch the layer off, and `AGENT_GH_REAL` would point the probe
# below at the operator's gh. Section (l) sets its own values deliberately.
unset AGENT_GH_SHIM_DIR AGENT_GH_SHIM AGENT_GH_REAL AGENT_GH_GATE_DIR AGENT_GH_GATE_INTERVAL_MS
mkdir -p "$FAKEBIN" "$CELL_HOME"
SPY="$TMP/npm-spy.log"
cat > "$FAKEBIN/npm" <<EOF
#!/bin/bash
# Stub: cell-install.sh runs npm install per extension; keep this suite offline — but DO
# create node_modules, because the artifact the installer's own --verify reads back is the
# dependency tree npm would have produced — POPULATED: a real npm install always writes at
# least the lockfile it resolved, and --verify refuses a directory that holds nothing (a wiped
# tree is a cell whose extensions cannot load, and the install path is what repairs it).
# (No backticks or dollar-paren anywhere in this comment block: the heredoc below is UNQUOTED
# — it expands the SPY variable — so a backticked npm install here is EXECUTED while the stub is
# written. Measured: it ran the real npm in the repo root and left a package-lock.json in the
# checkout this suite documents as read-only.)
#
# It also records one line per invocation: the merge key and the npm registry it can SEE in
# its environment, then its argv. The installer must call it with a SCRUBBED environment —
# an allowlisted proxy/registry only (a package's lifecycle script inherits the rest
# otherwise) — and with --ignore-scripts, so a compromised dependency cannot execute at
# install time. The path is baked in because the child deliberately gets no environment to
# pass one through.
mkdir -p node_modules
echo x > node_modules/.package-lock.json
{ printf 'KEY=%s REG=%s\n' "\${AI_REVIEW_GATE_KEY-CELL_INSTALL_TEST_UNSET}" "\${npm_config_registry-CELL_INSTALL_TEST_NOREG}"; printf '%s\n' "\$*"; } >> "$SPY"
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
              "lane_srcs||scripts/lane|optional"; do
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
# ... and `--verify` must enforce that same deny against a cell that already has it, with the
# install half's predicate: `-e` FOLLOWS a symlink, so a dangling link at the denied path is
# invisible to it and the deny would certify what it exists to refuse.
ln -sfn "$TMP/nowhere" "$DEST/extensions/cmux-session.ts"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "denied extension is PRESENT on the cell: extensions/cmux-session.ts" "$LOG" \
  && ok "--verify refuses a cell where the DENIED extension is present (as a dangling symlink, which -e cannot see)" \
  || fail "--verify CERTIFIED a cell holding the denied cmux-session.ts"
rm -f "$DEST/extensions/cmux-session.ts"
run_verify >/dev/null 2>&1
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

# (g) The npm child must see NO inherited secret, must keep the operator's registry
# allowlist, and must not be allowed to run package scripts. Proven by what the stub SAW, not
# by reading the installer's source.
if [ ! -s "$SPY" ]; then
  fail "npm was never invoked — the dependency step is not running, so these assertions would be vacuous"
else
  if grep -q "CELL-INSTALL-TEST-MERGE-KEY" "$SPY"; then
    fail "the npm child INHERITED AI_REVIEW_GATE_KEY — a dependency lifecycle script can read the merge authority"
  else
    ok "npm runs with a SCRUBBED environment — the exported merge key never reaches a dependency"
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
  # The allowlist is what keeps a mirrored or proxied cell able to install at all; without a
  # pin, deleting it leaves this suite green.
  : > "$SPY"
  npm_config_registry="https://mirror.invalid/simple" run_install >/dev/null 2>&1
  if grep -q "REG=https://mirror.invalid/simple" "$SPY"; then
    ok "the npm child keeps the operator's registry (env -i does not strip the allowlist)"
  else
    fail "the npm child did NOT receive npm_config_registry — a mirrored cell could not install deps"
  fi
  grep -q "CELL-INSTALL-TEST-MERGE-KEY" "$SPY" \
    && fail "the allowlisted run leaked the merge key" \
    || ok "the allowlist carries the registry and nothing else of the operator's environment"
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

# ── (k) the pi SPAWN-POINT gate (#1884) ─────────────────────────────────────────────
# The gate lives where `pi` is BORN, not where a caller remembers to source it: spawn-gate.sh is
# double-duty and installs AS `pi` at $DEST/bin — first on a cell's PATH — so a hand-written runner
# (`tmux new-session -d -s x "… pi -p …"`) inherits the ceiling it never asked for. On 2026-10-16 a
# box reached load 258 against MAX_LOAD=100 because that path was ungated AND silent.
GATE_SRC="$ROOT/scripts/orchestrator-harness/spawn-gate.sh"
GATE_DST="$DEST/bin/pi"
if [ -f "$GATE_DST" ] && cmp -s "$GATE_SRC" "$GATE_DST"; then
  ok "the spawn-point gate is installed BYTE-IDENTICAL at \$DEST/bin/pi (#1884)"
else
  fail "the spawn-point gate is missing or stale at $GATE_DST — every \`pi\` a caller starts without sourcing spawn-gate.sh would be ungated and silent"
fi
[ -x "$GATE_DST" ] && ok "…and it is executable (PATH resolves PAST a non-executable entry, silently)" \
  || fail "$GATE_DST is not executable — PATH would skip the gate"
# BEHAVIOUR, not just the artifact: RUN the installed file as `pi`. MAX_LOAD=0 is the deterministic
# refusal lever and keeps its documented meaning ("spawn nothing"); the fake real pi behind it is
# what proves the refusal happened AT the spawn point instead of before the gate ever ran.
mkdir -p "$TMP/gate-real" "$TMP/gate-home"
printf '#!/usr/bin/env bash\nprintf RAN > "%s"\n' "$TMP/gate-ran" > "$TMP/gate-real/pi"
chmod +x "$TMP/gate-real/pi"
rm -f "$TMP/gate-ran"
HOME="$TMP/gate-home" MAX_LOAD=0 PATH="$DEST/bin:$TMP/gate-real:$PATH" pi -p "gate probe" >/dev/null 2>&1
grc=$?
if [ "$grc" -eq 76 ] && [ ! -e "$TMP/gate-ran" ]; then
  ok "the INSTALLED gate REFUSES a spawn at MAX_LOAD=0 (exit 76) and the real pi never runs"
else
  fail "the installed gate did not refuse an over-ceiling spawn (rc=$grc, real pi ran=$([ -e "$TMP/gate-ran" ] && echo yes || echo no))"
fi
rm -f "$TMP/gate-ran"
HOME="$TMP/gate-home" MAX_LOAD=999999999 PATH="$DEST/bin:$TMP/gate-real:$PATH" pi -p "gate probe" >/dev/null 2>&1
grc=$?
if [ "$grc" -eq 0 ] && [ -e "$TMP/gate-ran" ]; then
  ok "POSITIVE CONTROL: below the ceiling the installed gate EXECs the real pi (it is not a wall)"
else
  fail "the installed gate blocked a spawn below the ceiling (rc=$grc) — every refusal above would then be vacuous"
fi
rm -f "$TMP/gate-ran"
# A stale or hand-edited GATE is worse than a missing one: the missing one is loud, the stale one
# certifies a ceiling it no longer applies. All three mutations must be refused.
echo "# drift injected by the test" >> "$GATE_DST"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'spawn-point gate DIFFERS' "$LOG" \
  && ok "--verify refuses a HAND-EDITED spawn-point gate and exits 1" \
  || fail "--verify certified a hand-edited spawn-point gate (rc=$rc)"
rm -f "$GATE_DST"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'spawn-point gate MISSING' "$LOG" \
  && ok "--verify refuses a MISSING spawn-point gate, naming the consequence" \
  || fail "--verify passed with the spawn-point gate missing (rc=$rc)"
run_install >/dev/null 2>&1
chmod -x "$GATE_DST"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'spawn-point gate is NOT EXECUTABLE' "$LOG" \
  && ok "--verify refuses a NON-EXECUTABLE spawn-point gate (PATH would resolve past it)" \
  || fail "--verify certified a non-executable spawn-point gate (rc=$rc)"
run_install >/dev/null 2>&1
cmp -s "$GATE_SRC" "$GATE_DST" && [ -x "$GATE_DST" ] \
  && ok "re-install restored the gate byte-identical and executable" \
  || fail "re-install did not restore the spawn-point gate"

# ── (l) the argv-level gh SHIM (#984) — the merge gate must not be DEGRADED on a cell ──
# MEASURED on a live cell, on every lane:
#   `[review-enforcer] ⚠️  #984 argv-level gh shim not found — only the string scanner is
#    active, so bash token splicing can still hide an admin merge.`
# The extension resolves its shim as `EXTENSION_DIR/../../scripts/gh-shim`. On a laptop that is
# THE CHECKOUT, because setup.sh keeps the extensions as farm symlinks into it — so the shim is
# found without ever being installed. On a cell the extensions are real COPIES, so the same
# expression is `~/.pi/agent/scripts/gh-shim`, which nothing farmed. The cell then ran the merge
# gate in its DEGRADED mode — string scanner only, no argv inspection — while `--verify` certified
# the layer. What is asserted here is artifact + WIRING + BEHAVIOUR + the refusal, in that order:
# a file that exists but is not on the path the extension resolves is exactly the inert layer this
# section exists to rule out.
SHIM_DST="$DEST/scripts/gh-shim/gh"
VERIFIER_DST="$DEST/scripts/verify-admin-merge-evidence.sh"
if [ -f "$SHIM_DST" ] && cmp -s "$ROOT/scripts/gh-shim/gh" "$SHIM_DST"; then
  ok "the argv-level gh shim is installed BYTE-IDENTICAL at scripts/gh-shim/gh (#984)"
else
  fail "the argv-level gh shim is missing or stale at $SHIM_DST — a cell lane's merge gate would run DEGRADED (string scanner only)"
fi
[ -x "$SHIM_DST" ] \
  && ok "…and it is executable (bash SKIPS a non-executable PATH entry → the real gh runs, silently)" \
  || fail "$SHIM_DST is not executable — PATH would resolve past it and the gate would be inert"
if [ -s "$VERIFIER_DST" ] && cmp -s "$ROOT/scripts/verify-admin-merge-evidence.sh" "$VERIFIER_DST"; then
  ok "the evidence verifier landed as the shim's own ../verify-admin-merge-evidence.sh sibling (#984)"
else
  fail "the evidence verifier is missing or stale at $VERIFIER_DST — the shim fails CLOSED without it, refusing every admin merge"
fi
# (1) THE WIRING — the directory the EXTENSION will put on PATH must be the directory holding the
# shim. Derived from the extension's own location with `cd -P`, i.e. the same two-`..` walk
# `resolveGhShimDir()` does; a hard-coded `$DEST/scripts` here would agree with the installer and
# not with the extension.
EXT_RESOLVED="$(CDPATH= cd -- "$DEST/extensions/review-enforcer/../.." 2>/dev/null && pwd -P)"
if [ -n "$EXT_RESOLVED" ] && [ -f "$EXT_RESOLVED/scripts/gh-shim/gh" ] && [ "$EXT_RESOLVED/scripts/gh-shim/gh" -ef "$SHIM_DST" ]; then
  ok "the shim sits on the exact path the review-enforcer resolves (\$EXTENSION_DIR/../../scripts/gh-shim)"
else
  fail "the review-enforcer resolves '$EXT_RESOLVED/scripts/gh-shim' and there is no shim there — the installed one is INERT"
fi
# (2) THE BEHAVIOUR — drive the INSTALLED shim, not the repo copy, through PATH (the same way the
# extension injects it) and require that it (a) is what `gh` resolves to, (b) CONSULTS the installed
# verifier on an admin merge, and (c) refuses one it cannot certify — while an ordinary gh call
# passes through. Without this the assertions above only prove a file was copied.
STUB="$TMP/shim-real"; mkdir -p "$STUB"
CALLS="$TMP/shim-calls"; : > "$CALLS"
printf '#!/usr/bin/env bash\nprintf %%s\\n "$*" >> "${SHIM_PROBE_CALLS:?}"\nexit 0\n' > "$STUB/gh"
chmod +x "$STUB/gh"
PATH_SHIM="$DEST/scripts/gh-shim:$PATH"
resolved="$(PATH="$PATH_SHIM" command -v gh 2>/dev/null)"
if [ "$resolved" = "$SHIM_DST" ]; then
  ok "with the shim directory first on PATH, \`gh\` resolves to the INSTALLED shim"
else
  fail "PATH resolved \`gh\` to '${resolved:-<nothing>}' instead of $SHIM_DST — the injected PATH entry is inert"
fi
out="$(SHIM_PROBE_CALLS="$CALLS" AGENT_GH_REAL="$STUB/gh" AGENT_GH_GATE_DIR="$TMP/shim-gate" \
       AGENT_GH_GATE_INTERVAL_MS=0 PATH="$PATH_SHIM" gh pr merge 424242 --admin 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'admin merge' <<<"$out"; then
  ok "the INSTALLED shim REFUSES an unevidenced admin merge (rc=$rc) on this cell"
else
  fail "the installed shim ALLOWED an unevidenced admin merge (rc=$rc) — the argv layer is not enforcing: $(head -2 <<<"$out" | tr '\n' ' ')"
fi
grep -q 'pr view' "$CALLS" \
  && ok "…and it reached the INSTALLED verifier (the sibling relation survives the copy, so the chain is whole)" \
  || fail "the shim refused without ever calling the verifier — the sibling path is broken, so the refusal is not the gate working"
out="$(SHIM_PROBE_CALLS="$CALLS" AGENT_GH_REAL="$STUB/gh" AGENT_GH_GATE_DIR="$TMP/shim-gate" \
       AGENT_GH_GATE_INTERVAL_MS=0 PATH="$PATH_SHIM" gh pr view 424242 --json headRefOid 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "POSITIVE CONTROL: an ordinary gh call passes through the installed shim untouched (it is a gate, not a wall)"
else
  fail "the installed shim blocked an ordinary \`gh pr view\` (rc=$rc) — every refusal above would then be vacuous"
fi
# (3) THE REFUSAL — the defect is a cell that reports itself READY with a degraded gate, so the
# absence of the shim must FAIL BY NAME in `--verify` (and therefore in `--install`, which ends by
# verifying). Simulated the way it actually happens: the artifact is gone, everything else is fine.
rm -f "$SHIM_DST"
run_verify
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'argv-level gh SHIM is MISSING' "$LOG" && grep -q 'gh-shim/gh' "$LOG"; then
  ok "--verify FAILS BY NAME when the shim is absent (rc=1, naming the shim) — the cell never certifies a degraded gate"
else
  fail "--verify rc=$rc did not refuse a cell whose argv-level gh shim is ABSENT (or did not name it)"
fi
run_install >/dev/null 2>&1
if cmp -s "$ROOT/scripts/gh-shim/gh" "$SHIM_DST" && [ -x "$SHIM_DST" ]; then
  ok "--install restores the shim (no manual copy, byte-identical, executable)"
else
  fail "--install did not restore the argv-level gh shim"
fi
run_verify
[ $? -eq 0 ] && ok "--verify passes again once the shim is installed" \
  || fail "--verify still failed after the shim was restored"
# ... and a shim that is present but NOT EXECUTABLE is the silent variant: bash skips the PATH entry
# and the real gh runs, so the gate is absent with nothing on any stream. It must be refused too.
chmod -x "$SHIM_DST"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'argv-level gh SHIM is NOT EXECUTABLE' "$LOG" \
  && ok "--verify refuses a NON-EXECUTABLE shim (PATH would skip it and run the real gh)" \
  || fail "--verify certified a non-executable shim (rc=$rc)"
run_install >/dev/null 2>&1
# ... and the verifier is the other half of the pair: the shim fails CLOSED without it, so a cell
# missing it cannot land an evidenced admin merge at all.
rm -f "$VERIFIER_DST"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'admin-merge EVIDENCE VERIFIER' "$LOG" \
  && ok "--verify names the missing EVIDENCE VERIFIER (the shim's other half, not just the shim)" \
  || fail "--verify certified a cell whose evidence verifier is gone (rc=$rc)"
run_install >/dev/null 2>&1
run_verify
[ $? -eq 0 ] && ok "--verify passes once the shim + verifier pair is complete" \
  || fail "--verify still failed after the shim/verifier pair was restored"
# (4) THE PREFERENCE RULE — `AGENT_GH_SHIM_DIR` is a PREFERENCE, not an override: `resolveGhShimDir()`
# tries the named directory and FALLS BACK to `EXTENSION_DIR/../../scripts/gh-shim`, returning the
# first one that holds an EXECUTABLE `gh`. A verifier that treated the env var as the only candidate
# would FAIL a cell whose gate the extension is enforcing correctly — and since `--install` ends by
# verifying, `bringup --check` would then die on a healthy box while prescribing `--install` as the
# remedy for a failure `--install` had just produced. Pinned because the two behaviours are
# indistinguishable from the outside when everything is healthy.
AGENT_GH_SHIM_DIR="/nonexistent/shim" run_verify
[ $? -eq 0 ] && ok "--verify PASSES when AGENT_GH_SHIM_DIR points nowhere — it falls back to the installed shim, exactly as the extension does" \
  || fail "--verify failed a healthy cell because AGENT_GH_SHIM_DIR was stale — the extension would have fallen back and enforced"

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
[ "$rc" -eq 1 ] && grep -q "extension CONTENT DIFFERS from the checkout: extensions/review-enforcer" "$LOG" \
  && ok "--verify refuses a hand-edited guard extension (existence is not certification)" \
  || fail "--verify CERTIFIED a hand-edited guard extension — a stale guard would load on the cell"
# ... but a cell-local EXTRA inside an extension directory must NOT fail: the installer never
# deletes one (its own contract), so refusing it would be a false block it cannot repair.
cp "$ROOT/extensions/review-enforcer/index.ts" "$DEST/extensions/review-enforcer/index.ts"
echo "# cell-local extra" > "$DEST/extensions/review-enforcer/cell-local-helper.ts"
run_verify
[ $? -eq 0 ] && ok "a cell-local extra in an extension directory is tolerated (extras survive, drift does not)" \
  || fail "--verify refused a cell-local extra — a false block the installer cannot repair"
rm -f "$DEST/extensions/review-enforcer/cell-local-helper.ts"
# skills/ was `[ -d ]` plus a non-empty `ls` until #1723's `--check` began verifying BEFORE it
# installs: a cell holding 1 of the checkout's 124 SKILL.md files passed that check, so the fast
# path would CERTIFY it and skip the re-copy that repairs it. It now compares the WHOLE tree —
# `skills/` ships 304 files, and a skill whose entry point survived but whose references/,
# workflow/ and templates/ files are gone is not the skill those files describe.
rm -f "$DEST/skills/commit-workflow/workflow/01-preflight.md"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "SKILLS CONTENT DIFFERS from the checkout: skills/" "$LOG" \
  && ok "--verify refuses a skills tree missing a SUPPORT file the checkout ships (not just SKILL.md)" \
  || fail "--verify CERTIFIED a cell missing skills/commit-workflow/workflow/01-preflight.md"
run_install >/dev/null 2>&1
[ -f "$DEST/skills/commit-workflow/workflow/01-preflight.md" ] \
  && ok "re-install restored the missing support file" \
  || fail "re-install did not restore the missing support file"
rm -f "$DEST/skills/commit-workflow/SKILL.md"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "SKILLS CONTENT DIFFERS from the checkout: skills/" "$LOG" \
  && ok "--verify refuses a skills tree missing a SKILL.md the checkout ships" \
  || fail "--verify CERTIFIED a cell missing skills/commit-workflow/SKILL.md (a partial skills tree)"
run_install >/dev/null 2>&1
[ -f "$DEST/skills/commit-workflow/SKILL.md" ] && ok "re-install restored the removed SKILL.md" \
  || fail "re-install did not restore the removed SKILL.md"
echo "# hand-edited" >> "$DEST/skills/commit-workflow/SKILL.md"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "SKILLS CONTENT DIFFERS from the checkout: skills/" "$LOG" \
  && ok "--verify refuses a hand-edited SKILL.md (a skill is read back, not just counted)" \
  || fail "--verify CERTIFIED a hand-edited SKILL.md"
run_install >/dev/null 2>&1   # refresh the hand-edited skill before the AGENTS.md pin
[ $? -eq 0 ] || fail "re-install failed after the skills pins — the pins left the cell unusable"
# An EMPTY AGENTS.md used to satisfy `[ -f ]` — 'no global rules' reported as verified.
printf '' > "$DEST/AGENTS.md"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "AGENTS.md is missing or empty" "$LOG" \
  && ok "--verify refuses an EMPTY AGENTS.md (a cell lane with no global rules)" \
  || fail "--verify CERTIFIED an empty AGENTS.md"
# An install can never repair this one (a global rules file is hand-edited state, so the
# installer only writes AGENTS.md when it is ABSENT) — restore the fixture by hand.
cp "$ROOT/templates/AGENTS.base.md" "$DEST/AGENTS.md"
run_verify
[ $? -eq 0 ] && ok "--verify passes again once AGENTS.md carries the base artifact" \
  || fail "--verify still refused after AGENTS.md was restored"
# A hand-edited CONFIG artifact is the same class as a hand-edited guard: agents/ is where pi
# resolves the sub-agent definitions a lane dispatches reviewers with.
echo "# edited" >> "$DEST/agents/verifier.md"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "config artifact CONTENT DIFFERS from the checkout: agents" "$LOG" \
  && ok "--verify refuses a hand-edited config artifact (agents/ is read back, not just listed)" \
  || fail "--verify CERTIFIED a hand-edited agents/ definition"
# The SHAPE branch: a cell whose `agents` is a FILE where the checkout has a directory used to
# fall through every branch of the read-back chain and be certified (the extension loop has
# had this check all along).
rm -rf "$DEST/agents" && printf 'not a directory\n' > "$DEST/agents"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "config artifact SHAPE CHANGED: agents" "$LOG" \
  && ok "--verify refuses a config artifact whose SHAPE changed (a file where the checkout has a directory)" \
  || fail "--verify CERTIFIED a cell whose agents/ is a file"
# ... and the mirror shape: a FILE artifact made a DIRECTORY on the cell (the arm the split
# `[ -f "$csrc" ]` / `[ ! -f "$cdst" ]` branch covers — otherwise unpinned).
rm -f "$DEST/coding-rules.md" && mkdir -p "$DEST/coding-rules.md"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "config artifact SHAPE CHANGED: coding-rules.md" "$LOG" \
  && ok "--verify refuses a config artifact whose SHAPE changed the other way (a directory where the checkout has a file)" \
  || fail "--verify CERTIFIED a cell whose coding-rules.md is a directory"
rm -rf "$DEST/coding-rules.md" && cp "$ROOT/pi-bootstrap/pi-config/coding-rules.md" "$DEST/coding-rules.md"
# ... and the INSTALL side must COUNT that copy failure, not merely muffle the success line.
run_install
rc=$?
{ [ "$rc" -eq 1 ] && grep -q "could not install pi-bootstrap/pi-config/agents" "$LOG"; } \
  && ok "a config copy that FAILS is counted as a failure (rc=$rc), not just a muffled success line" \
  || fail "an install over a wrong-shaped dest exited $rc without recording the copy failure"
rm -f "$DEST/agents"
run_install >/dev/null 2>&1
# A shipped directory that carries NO files cannot be compared, and must not read as a match
# (`find` returns nothing, so the one-directional check used to pass over an empty tree). The
# fixture links the OTHER extension dirs in as symlinks, which is what pins the second half of
# this control: `find` must FOLLOW a symlinked source dir (`-H`) — without it every one of those
# siblings reports the same "ships NO files" text, so the count and the two named messages below
# are the assertion. A fixture of all-empty dirs would prove only that the refusal exists; it
# could not tell an empty tree from a symlinked one, and the false BLOCK would read as a pass.
EMPTY_EXT="$TMP/empty-ext-checkout"
mkdir -p "$EMPTY_EXT/extensions" "$EMPTY_EXT/pi-bootstrap/pi-config"
for d in scripts skills templates tools manifest.json; do ln -s "$ROOT/$d" "$EMPTY_EXT/$d"; done
ln -s "$ROOT/pi-bootstrap/setup.sh" "$EMPTY_EXT/pi-bootstrap/setup.sh"
# #1924: the UNFARM leg lives beside setup.sh ($INFRA_ROOT/pi-bootstrap/lib/farm-retire.sh)
# and reads its declared retirements from $INFRA_ROOT/pi-bootstrap/farm-retired.txt, so a
# checkout-shaped fixture has to carry both — a real checkout does.
ln -s "$ROOT/pi-bootstrap/lib" "$EMPTY_EXT/pi-bootstrap/lib"
ln -s "$ROOT/pi-bootstrap/farm-retired.txt" "$EMPTY_EXT/pi-bootstrap/farm-retired.txt"
cp -R "$ROOT/pi-bootstrap/pi-config/." "$EMPTY_EXT/pi-bootstrap/pi-config/"
for d in "$ROOT"/extensions/*; do
  b="$(basename "$d")"; [ "$b" = review-enforcer ] && continue
  ln -s "$d" "$EMPTY_EXT/extensions/$b"
done
mkdir -p "$EMPTY_EXT/extensions/review-enforcer"               # exists, ships NO files
rm -rf "$EMPTY_EXT/pi-bootstrap/pi-config/agents"               # and a config dir that ships NO files
mkdir -p "$EMPTY_EXT/pi-bootstrap/pi-config/agents"
out="$(CELL_HOME="$TMP/emptyext-home" INFRA_ROOT="$EMPTY_EXT" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --install 2>&1)"
rc=$?
if [ "$rc" -ne 1 ]; then
  fail "a zero-file extension directory was certified as the layer (rc=$rc)"
else
  empties="$(grep -c 'ships NO files in the checkout' <<<"$out")"
  if [ "$empties" = "2" ]; then
    ok "exactly the two zero-file source trees are refused (the symlinked sibling DIRECTORIES verify CLEAN — find follows a symlinked source)"
  else
    fail "$empties zero-file refusals for a fixture holding 2 of them — an empty tree and a symlinked tree are not being told apart"
  fi
  # The count above only says the MESSAGE appeared twice; this says the run refused exactly two
  # things, so a sibling failing for any other reason cannot hide behind the "verify CLEAN" claim.
  grep -q 'FAILED: 2 problem(s)' <<<"$out" \
    && ok "the run refused exactly two things — no symlinked sibling failed for some other reason" \
    || fail "the fixture produced a problem count other than 2 ($(grep -o 'FAILED: [0-9]* problem(s)' <<<"$out" | head -1)): a sibling is failing for an unasserted reason"
  grep -q 'extension review-enforcer ships NO files in the checkout' <<<"$out" \
    && ok "an extension directory that ships NO files is refused, not certified on an empty tree" \
    || fail "the refusal did not name the empty extension (review-enforcer)"
  grep -q 'config artifact agents ships NO files in the checkout' <<<"$out" \
    && ok "a config artifact that ships NO files is refused (the config loop's arm, not just the extension loop's)" \
    || fail "the config loop certified a zero-file agents/ source"
fi
# A source tree that cannot be READ in FULL must not be certified over the part `find` managed to
# reach: it exits non-zero and prints a PARTIAL list, and a `find` whose status is discarded
# (`done < <(find … 2>/dev/null)`) leaves the comparison covering a subset while the rest goes
# unvouched for — in a tree whose every file is later executed.
if [ "$(id -u)" = "0" ]; then
  ok "skipped the unreadable-subtree pin: running as root, where chmod 000 does not block a read"
else
  rm -rf "$EMPTY_EXT/pi-bootstrap/pi-config/agents"
  cp -R "$ROOT/pi-bootstrap/pi-config/agents" "$EMPTY_EXT/pi-bootstrap/pi-config/agents"
  mkdir -p "$EMPTY_EXT/pi-bootstrap/pi-config/agents/.unreadable"
  chmod 000 "$EMPTY_EXT/pi-bootstrap/pi-config/agents/.unreadable"
  out2="$(CELL_HOME="$TMP/emptyext-home" INFRA_ROOT="$EMPTY_EXT" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --install 2>&1)"
  chmod 700 "$EMPTY_EXT/pi-bootstrap/pi-config/agents/.unreadable" 2>/dev/null
  grep -q 'config artifact agents could not be compared IN FULL' <<<"$out2" \
    && ok "a source tree that cannot be read in full is REFUSED, not certified over a partial file list" \
    || fail "an unreadable subtree produced a certified comparison over the files find could reach"
fi
rm -f "$EMPTY_EXT/extensions/task-cwd-guard"
mkdir -p "$EMPTY_EXT/extensions/task-cwd-guard"
cp -R "$ROOT/extensions/task-cwd-guard/." "$EMPTY_EXT/extensions/task-cwd-guard/"
# (1) a shipped SYMLINK.
ln -s /etc/hostname "$EMPTY_EXT/extensions/task-cwd-guard/link.ts"
out3="$(CELL_HOME="$TMP/emptyext-home" INFRA_ROOT="$EMPTY_EXT" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --verify 2>&1)"
grep -q 'extension task-cwd-guard could not be compared IN FULL' <<<"$out3" \
  && ok "a shipped SYMLINK is refused (cp -R copies it as a link, so it was never byte-compared)" \
  || fail "a shipped symlink was certified without ever being compared"
rm -f "$EMPTY_EXT/extensions/task-cwd-guard/link.ts"
# (2) a LINKED node_modules, which must NOT be refused. Compared against a baseline measured
# immediately before the link is added, so a problem that was ALREADY there cannot be read as
# caused by the link.
base="$(CELL_HOME="$TMP/emptyext-home" INFRA_ROOT="$EMPTY_EXT" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --verify 2>&1)"
ln -s "$TMP/emptynm" "$EMPTY_EXT/extensions/task-cwd-guard/node_modules"
mkdir -p "$TMP/emptynm"
out4="$(CELL_HOME="$TMP/emptyext-home" INFRA_ROOT="$EMPTY_EXT" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --verify 2>&1)"
if [ "$(grep '^FAIL: ' <<<"$out4" | sort)" = "$(grep '^FAIL: ' <<<"$base" | sort)" ]; then
  ok "a LINKED node_modules is not refused (excluded by construction — no new FAIL line)"
else
  fail "a linked node_modules added or removed a FAIL line: $(diff <(grep '^FAIL: ' <<<"$base") <(grep '^FAIL: ' <<<"$out4") | head -3 | tr '\n' ' ')"
fi
rm -f "$EMPTY_EXT/extensions/task-cwd-guard/node_modules"; rmdir "$TMP/emptynm"
# (3) a name containing a NEWLINE: the sibling is what the lossy list duplicates in its place.
printf 'same\n' > "$EMPTY_EXT/extensions/task-cwd-guard/evil"
printf 'same\n' > "$TMP/emptyext-home/.pi/agent/extensions/task-cwd-guard/evil"
printf 'EVIL\n' > "$EMPTY_EXT/extensions/task-cwd-guard/evil"$'\n'"evil"
out5="$(CELL_HOME="$TMP/emptyext-home" INFRA_ROOT="$EMPTY_EXT" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --verify 2>&1)"
grep -q 'extension task-cwd-guard could not be compared IN FULL' <<<"$out5" \
  && ok "a shipped filename containing a NEWLINE is refused, not lost from the comparison" \
  || fail "a newline-bearing filename was not refused — the list is lossy, so no comparison over it can be trusted"
rm -f "$EMPTY_EXT/extensions/task-cwd-guard/evil"$'\n'"evil"
rm -rf "$EMPTY_EXT" "$TMP/emptyext-home"
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
# settings.json is MERGED, so it can never be byte-compared — but the checkout's keys must all
# be present on the cell. A checkout whose settings.json went missing used to install nothing,
# say nothing, and verify clean over whatever stale settings the cell already had.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["cellOnlySetting"]=True; json.dump(d,open(sys.argv[1],"w"))' \
  "$DEST/settings.json"
run_verify
[ $? -eq 0 ] && ok "a cell-local settings key survives --verify (the merge is source-wins, per key)" \
  || fail "--verify refused a legitimate cell-local settings key"
# ... but a cell that lost the CHECKOUT's keys is running stale settings, and the merge is
# exactly what is supposed to have prevented that.
cp "$DEST/settings.json" "$TMP/settings-backup.json"
python3 -c 'import json,sys; json.dump({"defaultProvider":"stale"}, open(sys.argv[1],"w"))' "$DEST/settings.json"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "settings.json does not carry the checkout's keys" "$LOG" \
  && ok "--verify refuses a cell whose settings.json lost the checkout's keys (stale cell copy)" \
  || fail "--verify CERTIFIED a cell running stale settings"
cp "$TMP/settings-backup.json" "$DEST/settings.json"
FAKE_CFG="$TMP/no-settings-checkout"
# A checkout-shaped tree built from SYMLINKS to the real ones — never a `cp -R` of the repo
# (this worktree's .worktrees/ holds a full second checkout). Only pi-bootstrap/pi-config is
# real, and its settings.json is the one thing removed.
mkdir -p "$FAKE_CFG/pi-bootstrap/pi-config"
for d in scripts extensions skills templates tools manifest.json; do ln -s "$ROOT/$d" "$FAKE_CFG/$d"; done
ln -s "$ROOT/pi-bootstrap/setup.sh" "$FAKE_CFG/pi-bootstrap/setup.sh"
ln -s "$ROOT/pi-bootstrap/lib" "$FAKE_CFG/pi-bootstrap/lib"                 # #1924 the UNFARM leg
ln -s "$ROOT/pi-bootstrap/farm-retired.txt" "$FAKE_CFG/pi-bootstrap/farm-retired.txt"   # #1924 its declaration
cp -R "$ROOT/pi-bootstrap/pi-config/." "$FAKE_CFG/pi-bootstrap/pi-config/"
rm -f "$FAKE_CFG/pi-bootstrap/pi-config/settings.json"   # ONLY settings.json: the five loop sources are present
out="$(CELL_HOME="$TMP/nosettings-home" INFRA_ROOT="$FAKE_CFG" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --install 2>&1)"
rc=$?
[ "$rc" -eq 1 ] && grep -q "pi-config/settings.json is MISSING" <<<"$out" \
  && ok "a checkout with no settings.json fails the install (it used to succeed in silence)" \
  || fail "a missing settings.json exited $rc without refusing"
grep -q "small config files installed" <<<"$out" \
  && fail "the config step printed its success line after a recorded failure (settings.json)" \
  || ok "the config step does not print its success line when settings.json was missing"
rm -rf "$FAKE_CFG/pi-bootstrap/pi-config/agents"   # now one of the config LOOP's five sources
out="$(CELL_HOME="$TMP/nosettings-home" INFRA_ROOT="$FAKE_CFG" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --install 2>&1)"
rc=$?
grep -q "declared config path pi-bootstrap/pi-config/agents is MISSING" <<<"$out" \
  && ok "a missing config source is a recorded failure, not a skip (rc=$rc)" \
  || fail "a missing config source was not reported"
grep -q "small config files installed" <<<"$out" \
  && fail "the config step printed its success line after a recorded failure (agents)" \
  || ok "the config step does not print its success line when a loop source was missing"
rm -rf "$FAKE_CFG" "$TMP/nosettings-home"

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
  # A WIPED tree is the same failure one step later: the directory is still there, so `-d`
  # certified it. With `--check` verifying before it installs, a certified-yet-unloadable
  # extension is never re-installed.
  rm -rf "$DEP/node_modules" && mkdir -p "$DEP/node_modules"   # exists, holds nothing
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -q "DEPENDENCIES EMPTY: extensions/builtin-tools" "$LOG" \
    && ok "--verify refuses an EMPTIED node_modules (exists but holds nothing)" \
    || fail "--verify CERTIFIED an empty builtin-tools/node_modules — the dep tree is what loads"
  run_install >/dev/null 2>&1
  [ -n "$(ls -A "$DEP/node_modules" 2>/dev/null)" ] \
    && ok "re-install repopulated the wiped dependency tree" \
    || fail "re-install did not repopulate the wiped node_modules"
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
mkdir -p "$FAKE/pi-bootstrap/lib" "$FAKE/scripts/checkout-hygiene" "$FAKE/extensions"
{
  echo '#!/bin/bash'
  echo 'fleet_srcs=(record-review.sh)'
  echo 'scripts_dir="$INFRA_ROOT/scripts/checkout-hygiene"'
} > "$FAKE/pi-bootstrap/setup.sh"
# A checkout only counts if it carries the UNFARM leg (#1924). Without these two files the
# resolver correctly declines $FAKE and falls back to this repo — so the case would install
# the REAL farm and prove nothing about the floor.
cp "$ROOT/pi-bootstrap/lib/farm-retire.sh" "$FAKE/pi-bootstrap/lib/farm-retire.sh"
printf '# no retirements\n' > "$FAKE/pi-bootstrap/farm-retired.txt"
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
hdr "run 8: the skills read-back refuses a tree it cannot compare in full"
# The reviewer's P1: `find` prints a PARTIAL list when it cannot descend, and exits non-zero. A
# read-back that discards that status (and its stderr) compares the part it reached and reports a
# match — so a cell missing an unreachable SKILL.md is certified. The fixture is a COMPLETE
# checkout with a real (mutable) skills tree; its sibling links are the find -H shape run 3 uses.
SK="$TMP/skills-checkout"
SKHOME="$TMP/skills-checkout-home"
mkdir -p "$SK/pi-bootstrap/pi-config" "$SK/extensions" "$SK/skills"
for d in scripts templates tools manifest.json; do ln -s "$ROOT/$d" "$SK/$d"; done
ln -s "$ROOT/pi-bootstrap/setup.sh" "$SK/pi-bootstrap/setup.sh"
ln -s "$ROOT/pi-bootstrap/lib" "$SK/pi-bootstrap/lib"                 # #1924 the UNFARM leg
ln -s "$ROOT/pi-bootstrap/farm-retired.txt" "$SK/pi-bootstrap/farm-retired.txt"   # #1924 its declaration
cp -R "$ROOT/pi-bootstrap/pi-config/." "$SK/pi-bootstrap/pi-config/"
for d in "$ROOT"/extensions/*; do b="$(basename "$d")"; ln -s "$d" "$SK/extensions/$b"; done
cp -R "$ROOT/skills/." "$SK/skills/"
out="$(CELL_HOME="$SKHOME" INFRA_ROOT="$SK" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --install 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "a complete fixture with a real skills tree installs clean" \
  || fail "the run-8 fixture did not install (rc=$rc): $(grep -m1 'FAIL:' <<<"$out")"
if [ "$(id -u)" = "0" ]; then
  ok "skipped the unreadable-skills pin: running as root, where chmod 000 does not block a read"
else
  mkdir -p "$SK/skills/.unreadable" && printf '# hidden\n' > "$SK/skills/.unreadable/SKILL.md"
  chmod 000 "$SK/skills/.unreadable"
  out="$(CELL_HOME="$SKHOME" INFRA_ROOT="$SK" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --verify 2>&1)"
  rc=$?
  chmod 700 "$SK/skills/.unreadable"
  [ "$rc" -eq 1 ] && grep -q "skills/ could not be compared IN FULL" <<<"$out" \
    && ok "an unreadable skills subtree is REFUSED, not certified over the part find reached" \
    || fail "an unreadable source subtree produced a certified skills comparison (rc=$rc)"
fi
# `cp -R` copies a symlink AS a link, so the cell's skill would point outside the cell and nothing
# descends into it to compare — the same refusal the extension and config loops make.
ln -s "$ROOT/skills/commit-workflow" "$SK/skills/linked-skill"
out="$(CELL_HOME="$SKHOME" INFRA_ROOT="$SK" PATH="$FAKEBIN:$PATH" bash "$INSTALLER" --verify 2>&1)"
rc=$?
[ "$rc" -eq 1 ] && grep -q "skills/ could not be compared IN FULL" <<<"$out" \
  && ok "a symlinked entry under skills/ is refused, not followed into the cell" \
  || fail "a symlinked skills entry was certified — the install copies it as a link"
rm -f "$SK/skills/linked-skill"

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
