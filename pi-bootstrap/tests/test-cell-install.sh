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
#       ENFORCED, including against a previous hand-push — and (#2100) the deny is bound to
#       WHAT IS ON THE CELL, not to manifest.json's ship-list: run 2b runs both halves from a
#       checkout whose ship-list omits both denied rows, so a manifest-bound predicate (which
#       goes inert the moment a row is dropped) cannot satisfy it;
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
#       reported its layer verified. It also pins the READ-BACK's two-part contract: the INSTALLED
#       copy is verified on its own (a valid preference cannot stand in for it) while
#       `AGENT_GH_SHIM_DIR` only decides whose verifier sibling is REQUIRED — an override with no
#       sibling is refused (and the message does not prescribe an `--install` that cannot repair
#       it) — resolved PHYSICALLY, through a symlinked shim AND a symlinked candidate DIRECTORY
#       (both directions: healthy ⇒ pass, verifier gone ⇒ refused naming the resolved path) — and
#       the resolver's hop BOUND, which must also REFUSE a non-numeric bound (a `[ -gt ]` on
#       garbage is an error, not a false, so an unvalidated bound re-opens the spin), so a symlink
#       cycle fails closed instead of hanging the caller. BOTH PLATFORMS are exercised: the suite
#       installs extensions as copies, so a farm-SYMLINKED `review-enforcer` is pointed at a fixture
#       checkout, which must be certified at ITS OWN `scripts/gh-shim` — refused when it is absent
#       (the false PASS: the farmed copy beside it satisfied a lexical derivation) and passed when
#       it is there (the false BLOCK). NOTE: every arm reads a PER-RUN log ($LOG is truncated at the
#       start of each driven run), because append-only made two of these assertions vacuous (#2166
#       review).
#   (m) the DENY is enforced BY PATTERN and across BOTH HOMES a cell runs under (#2147, run 3) —
#       `pi` loads `extensions/*.ts|*.js` and any subdirectory holding an index, so a
#       `tortoise-capture.bak.ts`, a `tortoise-capture.old/index.ts` or a `cmux-session.disabled.js`
#       WAS being loaded while an exact-name deny certified the box (measured 2026-11-05: 1 / 0 / 7 /
#       3 / 2 surviving copies across the five cells). Both halves are pinned: `--verify` refuses
#       each copy NAMING ITS PATH, `--install` removes it (otherwise verify→install→verify loops
#       forever), a copy in the cell's OTHER home is caught when the bring-up declares it — and an
#       UNDECLARED home is neither scanned nor touched, because on a laptop that home is a
#       developer's own working `tortoise-capture` and deleting it would be a destructive guess.
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
CHECKED=0
trap 'rm -rf "$TMP"' EXIT

# ⛔ THE TOTALS ARE PRINTED, NOT COUNTED BY HAND (#3374 review, round 12 P3). This suite kept no
# counter, so every "N ok arms" in the plan doc and the PR body was a `grep -c '^ok:'` somebody ran
# once at one head — and by round 12 the SAME document carried 297, 291 and 305 for the same suite,
# with a stale "23 arms" beside a corrected "25". A number the suite prints cannot be quoted stale,
# because the only way to get it is to run the suite.
fail() { CHECKED=$((CHECKED + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $*" >&2; }
ok()   { CHECKED=$((CHECKED + 1)); echo "ok: $*"; }
hdr()  { echo "== $*"; }

# --- hermetic environment -------------------------------------------------
# The argv-level `gh` shim (#984) is part of what this suite certifies, so its runtime switches
# must not leak in from the operator's shell: `AGENT_GH_SHIM_DIR` would MOVE the shim the verifier
# checks, `AGENT_GH_SHIM=0` would switch the layer off, and `AGENT_GH_REAL` would point the probe
# below at the operator's gh. Section (l) sets its own values deliberately.
# `AGENT_ADMIN_MERGE_OVERRIDE` is the shim's audited "allow, loudly" hatch: it short-circuits the
# evidence check BEFORE anything is consulted, so an operator who exports it would have section
# (l)'s driven admin merge waved through and this suite would go RED on a CORRECT installer.
unset AGENT_GH_SHIM_DIR AGENT_GH_SHIM AGENT_GH_REAL AGENT_GH_GATE_DIR AGENT_GH_GATE_INTERVAL_MS \
      AGENT_ADMIN_MERGE_OVERRIDE
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

# run_install [PATH-override] — always under the temp CELL_HOME; output goes to $LOG.
# ⛔ $LOG IS TRUNCATED PER RUN, not appended for the whole suite. It used to be append-only, which
# made assertions VACUOUS: two arms that drive the same refusal grep the same string, so the LATER
# arm was satisfied by the EARLIER arm's line and could not tell whether its own run said anything
# (measured: with the fix it pins reverted, arm (3b) was satisfied by arm (3)'s identical line), and
# a `$(grep -m1 'FAIL:' "$LOG")` diagnostic reported the FIRST failure of the whole run instead of
# that arm's (measured: it printed an unrelated `denied extension` line from run 2). Truncating at
# the start of every run makes every assertion below read ONLY its own run's output.
# Every install this suite drives goes through here, and each one is COUNTED. The npm spy below
# asserts "one npm run per dependency-declaring extension PER INSTALL": without the counter the
# contract silently assumed exactly one install, so a second (correct) install read as a
# disagreement. The counter also makes the alternative failure loud — an install that never
# reaches the dependency step at all.
INSTALLS="$TMP/installs.count"
: > "$INSTALLS"
run_install() {
  local rc=0
  : > "$LOG"
  echo "---- cell-install --install ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" PATH="${1:-$FAKEBIN:$PATH}" \
    bash "$INSTALLER" --install >> "$LOG" 2>&1 || rc=$?
  printf '.' >> "$INSTALLS"
  return $rc
}
run_verify() {
  : > "$LOG"
  echo "---- cell-install --verify ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" PATH="${1:-$FAKEBIN:$PATH}" \
    bash "$INSTALLER" --verify >> "$LOG" 2>&1
}

# The same two drivers against a DIFFERENT checkout root. Needed because a template is read from
# `$INFRA_ROOT/templates/.mcp.base.json`, so every shape that only exists in a NON-SHIPPED template
# (a self-host url, a padded url) is invisible to an arm that installs from this repo's own file.
run_install_root() { # <infra-root> [path]
  local rc=0
  : > "$LOG"
  echo "---- cell-install --install (INFRA_ROOT=$1) ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$1" PATH="${2:-$FAKEBIN:$PATH}" \
    bash "$INSTALLER" --install >> "$LOG" 2>&1 || rc=$?
  printf '.' >> "$INSTALLS"
  return $rc
}
run_verify_root() { # <infra-root>
  : > "$LOG"
  echo "---- cell-install --verify (INFRA_ROOT=$1) ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$1" PATH="$FAKEBIN:$PATH" \
    bash "$INSTALLER" --verify >> "$LOG" 2>&1
}

# --- the INDEPENDENT expected farm set (never the installer's own reader) ---
# setup.sh declares each farm as a single-line array; this reader is deliberately the
# simplest thing that can be right, so agreeing with the installer's python parser means
# something. Emits `path-under-$DEST/scripts<TAB>path-under-$INFRA_ROOT`.
expected_farm_rows() {
  local name dest src rest rel base line req
  for spec in "fleet_srcs||scripts|required" \
              "mcp_harness_srcs||scripts/orchestrator-harness|required" \
              "merge_gate_srcs||scripts|required" \
              "graph_srcs||scripts|required" \
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
for g in review-enforcer verification-gate main-worktree-guard search-guard gui-device-guard audit-logger.ts shared; do
  [ -e "$DEST/extensions/$g" ] && ok "guard installed: extensions/$g" \
    || fail "GUARD MISSING: extensions/$g"
done
if [ -e "$DEST/extensions/cmux-session.ts" ]; then
  fail "cmux-session.ts was installed — a Linux cell has no cmux desktop app (and the repo snapshot is stale v2 vs the live v4, #1138)"
else
  ok "cmux-session.ts is NOT installed (surface-absent deny holds)"
fi
# #2100 — a cell must not carry the capture extension. Measured 2026-10-19: on the AFFECTED cell
# (`tortoise-capture` was present on all three, and the provider-probe half of the defect applied
# on all three; which box lost its turns depended on its spool/quota state) the extension consumed
# the turn and every turn ended with banner-only output (259-262 B) — the box looked dead while its
# provider was healthy. `cell-install.sh` re-shipped it from the manifest's ship-list on every
# bringup, so operationally disabling it did not survive; the deny is the fix, and it must hold
# WITHOUT anyone remembering to hand-remove the cell copy.
if [ -e "$DEST/extensions/tortoise-capture" ]; then
  fail "tortoise-capture was installed on a cell — it blocks session_start and re-breaks the box on every bringup (#2100)"
else
  ok "tortoise-capture is NOT installed (deny holds: it blocks session_start, #2100)"
fi
# ... and `--verify` must FAIL, with its own NAMED line, on a cell that carries it anyway (a
# hand-push, or a checkout from before this deny). The generic "denied extension is PRESENT"
# wording is not enough here: an operator grepping the bring-up log for the dead-lane cause must
# be able to find the sentence that explains it. Asserted on the EXACT line, so a reworded or
# softened failure goes red instead of quietly losing the diagnosis.
CAPTURE_LINE='capture extension present on a cell: it blocks session_start and corrupts the provider probe'
mkdir -p "$DEST/extensions/tortoise-capture"
echo '// hand-pushed by the test' > "$DEST/extensions/tortoise-capture/index.ts"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qF "FAIL: $CAPTURE_LINE" "$LOG" \
  && ok "--verify FAILS on a cell carrying tortoise-capture, with the named line" \
  || fail "--verify CERTIFIED (or mis-named) a cell carrying tortoise-capture: $(grep -F 'capture' "$LOG" | tail -1)"
# ... and the INSTALL half must remove a present copy, because that is the direction the defect
# ran: the artifact was re-shipped on every bringup, so a deny that only reports is the same
# re-break with a log line. That is asserted in run 2 below, on a re-run (the exact operation that
# used to re-ship it), so this run's npm invocation count stays one-per-install. The fixture is
# removed here so the rest of run 1 sees a clean cell.
rm -rf "$DEST/extensions/tortoise-capture"
run_verify
[ $? -eq 0 ] && ok "--verify is clean again once the capture extension is gone" \
  || fail "--verify still fails after the capture extension was removed"
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
    # The TEST's own deny contract, stated here rather than read from the installer's
    # DENY_EXTENSIONS: a reader that agreed with the installer would pass when an entry is
    # dropped from the deny list, which is the regression these two lines exist to catch.
    case "$base" in cmux-session.ts|tortoise-capture) continue ;; esac
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

# (m) the HOSTED graph MCP (graph-mcp-provision). Before this, a cell had NO .mcp.json at all,
# so the owner's "every lane reads and writes the graph through the MCP" mandate was unobeyable
# there and every lane wrote GRAPH-UNREACHABLE. Pinned on the ARTIFACT: the entry is HTTP (not
# the legacy stdio command that needs a checkout+venv a cell does not have), the header is
# env-indirect, and no credential is written into the shared file.
if [ -f "$DEST/.mcp.json" ]; then
  python3 - "$DEST/.mcp.json" <<'PY' && ok ".mcp.json carries the HOSTED tortoise entry (http + env-indirect Bearer, no literal key)" \
    || fail ".mcp.json landed but not as the hosted entry (stdio shape, a literal credential, or no entry)"
import json, re, sys
raw = open(sys.argv[1]).read()
t = (json.loads(raw).get("mcpServers") or {}).get("tortoise") or {}
a = ((t.get("headers") or {}).get("Authorization") or "")
ok = (not t.get("command")) and (t.get("type") == "http") and bool(t.get("url")) \
     and "${" in a and not re.search(r"\b(t[tk])_[A-Za-z0-9]{10,}", raw)
sys.exit(0 if ok else 1)
PY
else
  fail ".mcp.json was NOT installed — the cell has zero MCP servers (no lane can reach the hosted graph)"
fi
# the hosted-graph FALLBACK half must land executable — the documented invocation TYPES the path
[ -x "$DEST/scripts/tortoise-graph.sh" ] && ok "the hosted-graph fallback landed executable (scripts/tortoise-graph.sh)" \
  || fail "scripts/tortoise-graph.sh missing or not executable — the documented fallback invocation would fail"
# A cell must NOT be handed the base config's other servers: `seo-intelligence` spawns
# ${AGENT_INFRA_PATH}/mcp-servers/.../node_modules/.bin/tsx and a cell ships extensions/ only
# (manifest.json carries no mcp-servers/), so the entry cannot spawn — a catalog that advertises
# an unspawnable tool is worse than a short catalog.
if python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
s = (json.load(open(sys.argv[1])).get("mcpServers") or {})
want = {"tortoise"}
extra = sorted(set(s) - want)
if extra:
    print("unexpected server(s) installed on a cell: %s" % extra)
sys.exit(0 if not extra else 1)
PY
then ok "a cell gets the graph server only (no unspawnable base servers)"
else fail "the installer put base servers a cell cannot spawn into .mcp.json (seo-intelligence needs mcp-servers/ deps, brave/gemini need keys)"
fi
# ...while a server the CELL already declared is state, not drift, and must survive a re-install.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("mcpServers", {})["cell-local"] = {"command": "/bin/true"}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a cell-local MCP server survives a re-install (state, not drift)" \
  || fail "re-install dropped a cell-local MCP server"
import json, sys
sys.exit(0 if "cell-local" in ((json.load(open(sys.argv[1])).get("mcpServers")) or {}) else 1)
PY
# ⛔ HEADERS THIS MACHINE ADDED ARE KEPT **AND NAMED** (#3374 review P2). `entry = dict(want)`
# discarded every non-Authorization header with no output at all, while the merge's own contract
# (merge-mcp.py:65) is that every decision is a `NOTE:` line and "nothing here is silent". A cell
# behind a gateway that requires `X-Tenant` lost it on EVERY install.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t["headers"] = dict(t.get("headers") or {})
t["headers"]["X-Tenant"] = "acme-prod"
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a header this machine added to the hosted tortoise entry SURVIVES a re-install" \
  || fail "re-install discarded a machine-added header on the tortoise entry — a gateway/tenant header vanishes with no signal"
import json, sys
h = ((json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}).get("headers") or {}
sys.exit(0 if h.get("X-Tenant") == "acme-prod" and "Authorization" in h else 1)
PY
grep -qF "kept this machine's own header(s) on the tortoise entry: X-Tenant" "$LOG" \
  && ok "...and the merge NAMES the header it kept (nothing here is silent)" \
  || fail "...a kept header was not named in a NOTE — the operator cannot see what the merge did to their config"
grep -qF "hosted tortoise entry installed" "$LOG" \
  && ok "...and the summary still says the HOSTED entry is installed, because this file carries it" \
  || fail "...the summary did not report the hosted entry on a file that carries it (the opposite falsehood)"
# Restore the fixture to the uninterpolated entry so the arms below mutate a known shape.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t["headers"] = {k: v for k, v in (t.get("headers") or {}).items() if k != "X-Tenant"}
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
# ...and a SELF-HOSTED tortoise url is preserved (the template's own comment tells self-host users
# to set it; a source-wins merge would silently repoint them at the hosted endpoint, where they
# have no key, and the failure would read as an auth error rather than the repoint it is).
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = dict(d["mcpServers"]["tortoise"], url="http://localhost:8000/mcp")
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a self-hosted tortoise url is preserved, not silently repointed at the hosted endpoint" \
  || fail "re-install silently repointed a self-hosted tortoise entry"
import json, sys
u = (json.load(open(sys.argv[1])).get("mcpServers", {}).get("tortoise", {}) or {}).get("url")
sys.exit(0 if u == "http://localhost:8000/mcp" else 1)
PY
# The preserved entry must be MARKED, and --verify must accept it BY NAME rather than silently:
# accepting any non-empty url is what certified a typo'd endpoint LAYER VERIFIED.
python3 - "$DEST/.mcp.json" <<'PY' && ok "a preserved self-hosted tortoise entry is marked _selfHosted" \
  || fail "a preserved non-default tortoise url was not marked, so it is indistinguishable from a stale copy"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("_selfHosted") is True else 1)
PY
# ⛔ THE INSTALL SUMMARY MUST DESCRIBE THE FILE, NOT THE INTENT (#3374 review P2). THIS run KEPT a
# self-hosted url, so a summary that says "hosted tortoise entry installed" sends the operator to
# inspect the wrong artifact. The positive polarity of this pair is asserted above, where the file
# really does carry the hosted entry — a log line that is right in only one state is still a lie.
if grep -qF "hosted tortoise entry installed" "$LOG"; then
  fail "the install log claimed the HOSTED entry was installed while the merge KEPT a self-hosted url — the summary contradicts the artifact it just wrote"
elif grep -qF "the tortoise entry is NOT the hosted default" "$LOG"; then
  ok "a self-hosted install says the tortoise entry is NOT the hosted default (the summary describes the file)"
else
  fail "a self-hosted install neither reported the hosted entry nor named the kept url — the summary is silent about the decision"
fi
run_verify
[ $? -eq 0 ] && grep -q "SELFHOSTED:http://localhost:8000/mcp" "$LOG" \
  && ok "--verify ACCEPTS a marked self-hosted url and says so by name" \
  || fail "--verify refused a marked self-hosted url, or accepted it without naming it (a false green)"
# ...but a DIFFERING url that is NOT marked is refused: that is the typo/copied-config case.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t.pop("_selfHosted", None)
t["url"] = "https://api.premiselabs.co/mcp"     # no trailing slash — plausible, and wrong
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
[ $? -eq 1 ] && grep -q "not the hosted shape the layer installs" "$LOG" \
  && ok "--verify REFUSES an unmarked non-default url (a typo'd endpoint is not 'self-hosted')" \
  || fail "--verify certified an unmarked non-default tortoise url — a false green of exactly the class this closes"
# A NON-http transport is refused too (the verifier must not be weaker than the test that pins it).
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"], type="sse", url="https://api.premiselabs.co/mcp/")
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
[ $? -eq 1 ] && grep -q "not the hosted shape the layer installs" "$LOG" \
  && ok "--verify REFUSES a non-http tortoise transport (sse/stdio is not the hosted shape)" \
  || fail "--verify certified a non-http tortoise transport"

# ⛔ THE DOCUMENTED SELF-HOST SHAPE CARRIES NO KEY — and must survive a sync UNCHANGED.
# `tortoise`'s docs/quickstart-selfhosted.md spells it exactly like this ("no key here: a local
# daemon needs none"), and SETUP-NEW-MACHINE.md tells self-host users to do the same. A
# well-formedness rule that demanded an Authorization unconditionally declared THIS shape
# "unusable", replaced it with the hosted default, and then had --verify print OK over an endpoint
# the operator never chose — the silent repoint, reproduced by the rule meant to prevent it.
cp "$DEST/.mcp.json" "$DEST/.mcp.json.keep"
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"url": "http://localhost:8000/mcp"}   # no type, no headers
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "the DOCUMENTED keyless self-host entry is preserved, not repointed at the hosted endpoint" \
  || fail "install replaced the documented keyless self-host entry — a self-host user's url is silently moved to the hosted endpoint they have no key for"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "http://localhost:8000/mcp" and t.get("_selfHosted") is True else 1)
PY
run_verify
[ $? -eq 0 ] && grep -q "SELFHOSTED:http://localhost:8000/mcp" "$LOG" \
  && ok "--verify ACCEPTS the keyless self-host entry (a local daemon needs no key) and names it" \
  || fail "--verify refused a marked keyless self-host entry — install preserves it and verify refuses it, so the cell cannot be repaired"
cp "$DEST/.mcp.json.keep" "$DEST/.mcp.json"

# An UNUSABLE preserved entry must be REPLACED by the installer, or the cell is unrecoverable:
# install preserves it, verify refuses it, and the operator's only remedy re-creates it. The
# unusable case is the HOSTED url with no credential — a guaranteed 401 — not a self-host url.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "http", "url": "https://api.premiselabs.co/mcp/"}   # no auth
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a HOSTED url with no credential is replaced (an empty Bearer is a guaranteed 401)" \
  || fail "install preserved a hosted-url entry with no Authorization — --verify refuses it, so install and verify disagree and the cell cannot be repaired"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
auth = (t.get("headers") or {}).get("Authorization") or ""
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and auth.startswith("Bearer ${") else 1)
PY
# ...and a LITERAL key in the file is replaced too (never preserved, never certified).
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
# built at runtime: spelling a token here would trip the transcript redactor and test nothing more
t["headers"] = {"Authorization": "Bearer " + "t" + "t" + "_" + "A" * 24}
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a LITERAL key in the entry is replaced by the env-indirect header" \
  || fail "install preserved a literal credential in .mcp.json — the shared config is the leak"
import json, sys
raw = open(sys.argv[1]).read()
sys.exit(1 if ("t" + "t" + "_") in raw else 0)
PY
# the LEGACY stdio entry is replaced without ceremony (it can never work here)
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"command": "/x/.venv/bin/python3", "args": ["-m", "tortoise.mcp_server"]}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "the legacy stdio entry is replaced by the hosted one on install" \
  || fail "install left the legacy stdio tortoise entry in place"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("type") == "http" and not t.get("command") else 1)
PY
rm -f "$DEST/.mcp.json.keep"
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
  installs="$(tr -cd '.' < "$INSTALLS" | wc -c | tr -d ' ')"
  n="$(awk 'NR % 2 == 1' "$SPY" | wc -l | tr -d ' ')"
  [ "$installs" -ge 1 ] || fail "no install was counted — the spy assertions below would be vacuous"
  [ "$n" = "$((deps * installs))" ] \
    && ok "npm ran once per dependency-declaring extension, for each of the $installs install(s) — $((deps * installs)) run(s) for $deps extension(s)" \
    || fail "npm ran $n time(s) across $installs install(s); $deps extension(s) declare dependencies, so $((deps * installs)) were expected — the two halves of the contract disagree"
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
# The #2100 re-break, replayed: the extension is on the cell (hand-pushed, or installed by an
# older checkout) and a re-run is exactly the operation that used to re-ship it from the
# manifest. A re-run must leave the cell WITHOUT it.
mkdir -p "$DEST/extensions/tortoise-capture"
echo '// hand-pushed by the test' > "$DEST/extensions/tortoise-capture/index.ts"
run_install >/dev/null 2>&1
if [ ! -e "$DEST/extensions/tortoise-capture" ]; then
  ok "a hand-pushed tortoise-capture was REMOVED by the re-run (#2100: bringup no longer re-ships it)"
else
  fail "a hand-pushed tortoise-capture survived the re-run — bringup re-ships the box-breaking extension"
fi
# ... and the same removal must hold when the denied path is a DANGLING SYMLINK, not a directory.
# `-e` follows a link, so a predicate written with `-e` alone sees nothing here: the copy survives
# every re-run while `--verify` fails on it, so `--check` loops verify-FAIL -> install-that-cannot-
# repair -> FATAL forever. The install half duplicates the verify half's predicate, so it can drift
# alone; this is the case that catches that drift.
ln -sfn "$TMP/nowhere" "$DEST/extensions/tortoise-capture"
run_install >/dev/null 2>&1
if [ ! -e "$DEST/extensions/tortoise-capture" ] && [ ! -L "$DEST/extensions/tortoise-capture" ]; then
  ok "a DANGLING SYMLINK at the denied path was removed by the re-run (the deny follows the same predicate as --verify)"
else
  fail "a dangling symlink at the denied tortoise-capture path SURVIVED the re-run — the install half's predicate has drifted from --verify's"
fi
# -------------------------------------------------------------------------
hdr "run 2b: the deny is enforced against the CELL, not against manifest.json (#2100 review)"
# The deny exists because binding it to the SHIP-LIST makes it go INERT the moment an entry leaves
# manifest.json: the install half stops reaching a copy left on the cell (a hand-push, or an install
# from an older checkout) and the verify half certifies that copy clean — the #2100 re-break with a
# quieter cause. The cases above do NOT discriminate that: `tortoise-capture` is still a manifest
# ROW, so a manifest-bound enforcement matches it there too and every one of those assertions stays
# green. This fixture removes BOTH denied rows from a COPY of manifest.json (everything else is the
# real checkout), so the only way either half can still remove/refuse the copy is by reading the
# CELL. Replace both deny loops with `denied_extension "$base" && continue`-only enforcement and
# the four assertions below go red.
NOENTRY="$TMP/noentry-checkout"; NOEHOME="$TMP/noentry-home"
NOELOG="$TMP/noentry.log"; NEDEST="$NOEHOME/.pi/agent"
mkdir -p "$NOENTRY"
for e in "$ROOT"/*; do
  b="$(basename "$e")"
  [ "$b" = manifest.json ] && continue
  ln -s "$e" "$NOENTRY/$b"
done
python3 - "$MANIFEST" "$NOENTRY/manifest.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
m = json.load(open(src))
rows = m["files"]["extensions/"]["entries"]
denied = ("tortoise-capture", "cmux-session.ts")
kept = [r for r in rows if r.rstrip("/") not in denied]
if len(rows) - len(kept) != 2:
    sys.exit("fixture setup: expected to drop exactly 2 ship-list rows, dropped %d" % (len(rows) - len(kept)))
m["files"]["extensions/"]["entries"] = kept
json.dump(m, open(dst, "w"), indent=2)
PY
# NON-VACUITY, both directions: the fixture copy really omits both rows, and the REAL manifest
# really carries them (which is what makes the run-1/run-2 cases pass through the row path and
# prove nothing about the cell path).
if grep -q 'tortoise-capture' "$NOENTRY/manifest.json" || grep -q 'cmux-session.ts' "$NOENTRY/manifest.json"; then
  fail "the fixture manifest.json still lists a denied entry — this case would pass for the wrong reason"
else
  ok "the fixture's manifest.json carries NEITHER denied entry (the ship-list cannot satisfy the deny)"
fi
if grep -q 'tortoise-capture/' "$MANIFEST"; then
  ok "non-vacuity: the REAL manifest.json does ship tortoise-capture/, so the cases above take the row path"
else
  fail "the real manifest.json no longer lists tortoise-capture — the deny contract below no longer describes this repo"
fi
# A cell that already CARRIES both denied artifacts (hand-pushed, or from an older checkout) and a
# checkout whose ship-list does not mention them: the install half must still remove them.
mkdir -p "$NEDEST/extensions/tortoise-capture"
echo '// hand-pushed by the test' > "$NEDEST/extensions/tortoise-capture/index.ts"
echo '// stale cmux bridge' > "$NEDEST/extensions/cmux-session.ts"
: > "$NOELOG"
CELL_HOME="$NOEHOME" INFRA_ROOT="$NOENTRY" PATH="$FAKEBIN:$PATH" \
  bash "$INSTALLER" --install >> "$NOELOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "the fixture checkout installs cleanly (rc=0) — the assertions below are attributable to the deny" \
  || fail "the no-entry fixture did not install (rc=$rc): $(grep -m1 -E 'FAIL:|FATAL:' "$NOELOG")"
if [ ! -e "$NEDEST/extensions/tortoise-capture" ]; then
  ok "a hand-pushed tortoise-capture was REMOVED by an install whose manifest.json does NOT list it (the deny reads the cell)"
else
  fail "a hand-pushed tortoise-capture SURVIVED an install whose ship-list omits it — the deny is bound to the manifest and goes inert when a row is dropped"
fi
if [ ! -e "$NEDEST/extensions/cmux-session.ts" ]; then
  ok "a hand-pushed cmux-session.ts was REMOVED by the same install (both deny entries are cell-bound, not just the capture one)"
else
  fail "a hand-pushed cmux-session.ts SURVIVED an install whose ship-list omits it — the deny is manifest-bound"
fi
# The read-back must refuse the same copies, with the same named lines, on the same no-entry
# checkout — this is the half `--check` surfaces to an operator, so a manifest-bound predicate here
# silently CERTIFIES the box that is re-breaking itself.
if CELL_HOME="$NOEHOME" INFRA_ROOT="$NOENTRY" PATH="$FAKEBIN:$PATH" \
     bash "$INSTALLER" --verify >> "$NOELOG" 2>&1; then
  ok "--verify is clean on the fixture cell it just installed (the fixture is a VALID cell, so the refusal below is attributable to the deny)"
else
  fail "--verify refused a freshly installed no-entry fixture cell: $(grep -m1 'FAIL:' "$NOELOG")"
fi
: > "$NOELOG"
mkdir -p "$NEDEST/extensions/tortoise-capture"
echo '// hand-pushed by the test' > "$NEDEST/extensions/tortoise-capture/index.ts"
echo '// stale cmux bridge' > "$NEDEST/extensions/cmux-session.ts"
CELL_HOME="$NOEHOME" INFRA_ROOT="$NOENTRY" PATH="$FAKEBIN:$PATH" \
  bash "$INSTALLER" --verify >> "$NOELOG" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -qF "FAIL: $CAPTURE_LINE" "$NOELOG" \
  && ok "--verify FAILS with the named line on a capture copy its manifest.json does not list" \
  || fail "--verify CERTIFIED a cell carrying tortoise-capture when the ship-list omits the row: $(grep -m1 -E 'capture|FAIL:' "$NOELOG")"
grep -q "denied extension is PRESENT on the cell: extensions/cmux-session.ts" "$NOELOG" \
  && ok "--verify refuses the omitted cmux-session.ts too (both halves read the cell, not the ship-list)" \
  || fail "--verify certified a cell carrying cmux-session.ts that its ship-list omits"

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
: > "$LOG"   # per-run, like run_verify: the assertion below reads ONLY this run
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
# ⛔ AND THE FORK INSTRUMENT IS DEPLOYED FIRST (agent-infra#2293 / #2843), because the spawn point now
# HARD-REQUIRES `capacity.sh` and refuses under 83 (`AGENT_HARNESS_SKEW_REFUSED`) when it cannot read
# the fork floor — which is the whole point of that fix and NOT a wall this arm may assume away. A
# `HOME` with no harness is a HALF-DEPLOYED box: both drives below would answer 83 and this arm would
# stop testing the load gate at all. `$HOME/orchestrator` is the DOCUMENTED default harness home (one
# of the resolver's candidates), so seeding it there is the production shape, not a fixture-only
# dodge; the INSTALL half (shipping the instrument beside the installed `pi`) is #2843's open half.
# ⛔ A STUB, NOT THE SHIPPED FILE: the shipped `capacity.sh` reads THIS HOST's process population, so
# the arm's verdict would be decided by the runner's fork headroom instead of by the gate under test.
mkdir -p "$TMP/gate-home/orchestrator"
cat > "$TMP/gate-home/orchestrator/capacity.sh" <<'CAPEOF'
# Hermetic HEALTHY instrument stub: the three functions the spawn gate hard-requires, fixed readings.
cap_procs_pair_vars() { printf -v "${1:?}" '%s' 100; printf -v "${2:?}" '%s' 10000; printf -v "${3:?}" '%s' 'fixture'; }
cap_h_for_vars() { printf -v "${3:?}" '%s' "$(( ${2:-0} - ${1:-0} ))"; }
cap_fork_probe() { return 0; }
CAPEOF
# ⛔ MEM_MIN_AVAIL_MB=1 IS THE MEMORY GATE'S NEUTRALISER (#2387), and it is NOT optional here. The
# installed shim checks MEMORY before load, so on a box whose MemAvailable is under the shipped 2048
# floor this arm was decided by the memory gate (rc=84) and the suite reported its own subject — the
# LOAD ceiling — as broken. Both arms pin the lever they are about; the refusal arm asserts the exit
# code, so a memory refusal can never satisfy the load assertion again.
mkdir -p "$TMP/gate-real" "$TMP/gate-home"
printf '#!/usr/bin/env bash\nprintf RAN > "%s"\n' "$TMP/gate-ran" > "$TMP/gate-real/pi"
chmod +x "$TMP/gate-real/pi"
rm -f "$TMP/gate-ran"
HOME="$TMP/gate-home" MAX_LOAD=0 MEM_MIN_AVAIL_MB=1 PATH="$DEST/bin:$TMP/gate-real:$PATH" pi -p "gate probe" >/dev/null 2>&1
grc=$?
if [ "$grc" -eq 76 ] && [ ! -e "$TMP/gate-ran" ]; then
  ok "the INSTALLED gate REFUSES a spawn at MAX_LOAD=0 (exit 76) and the real pi never runs"
else
  fail "the installed gate did not refuse an over-ceiling spawn (rc=$grc, real pi ran=$([ -e "$TMP/gate-ran" ] && echo yes || echo no))"
fi
rm -f "$TMP/gate-ran"
HOME="$TMP/gate-home" MAX_LOAD=999999999 MEM_MIN_AVAIL_MB=1 PATH="$DEST/bin:$TMP/gate-real:$PATH" pi -p "gate probe" >/dev/null 2>&1
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
# shim. Derived from the extension's own location: `EXTENSION_DIR` in `review-enforcer` is
# `dirname(fileURLToPath(import.meta.url))`, i.e. the REALPATH of the loaded module, so this walks
# the extension directory PHYSICALLY (`cd -P`) and only then applies the two-`..` step — exactly
# what `gh_shim_extension_dir()` does in the installer. ⛔ A LEXICAL `cd -- …/../..` cannot do this
# job: bash strips `..` by string, so it answers `$DEST` whether the extension is a copy OR a farm
# symlink into the checkout, and a hard-coded `$DEST/scripts` would then satisfy this assertion
# (MEASURED: replacing the installer's real derivation with `installed="$DEST/scripts/gh-shim"`
# produced ZERO new failures here).
EXT_REAL="$(CDPATH= cd -P -- "$DEST/extensions/review-enforcer" 2>/dev/null && pwd -P)"
EXT_RESOLVED=""
if [ -n "$EXT_REAL" ]; then EXT_RESOLVED="$(dirname "$(dirname "$EXT_REAL")")"; fi
if [ -n "$EXT_RESOLVED" ] && [ -f "$EXT_RESOLVED/scripts/gh-shim/gh" ] && [ "$EXT_RESOLVED/scripts/gh-shim/gh" -ef "$SHIM_DST" ]; then
  ok "the shim sits on the exact path the review-enforcer resolves (\$EXTENSION_DIR/../../scripts/gh-shim, taken PHYSICALLY)"
else
  fail "the review-enforcer resolves '$EXT_RESOLVED/scripts/gh-shim' and there is no shim there — the installed one is INERT"
fi
# (1b) THE OTHER PLATFORM — setup.sh keeps the extensions as farm SYMLINKS into the checkout on a
# laptop, so `EXTENSION_DIR/../../scripts/gh-shim` is `<checkout>/scripts/gh-shim`, a DIFFERENT
# directory from the farmed `$DEST` copy; on a cell the extensions are copies and the two coincide.
# This suite installs copies, so the symlink platform was NEVER exercised: the arms below point the
# cell's `review-enforcer` at a fixture and require the guard to certify THE FIXTURE'S sibling —
# refusing when it is missing (the false PASS: `LAYER VERIFIED` while every lane logs
# `#984 … not found`) and passing when it is there (the false BLOCK: a healthy symlink platform
# refused with a diagnostic naming a path the gate never reads).
EXT_SAVED="$TMP/ext-review-enforcer.saved"
FIX_BARE="$TMP/ext-fixture-bare"      # a checkout WITH the extension, WITHOUT scripts/gh-shim
mkdir -p "$FIX_BARE/extensions"
cp -R "$DEST/extensions/review-enforcer" "$FIX_BARE/extensions/review-enforcer"
mv "$DEST/extensions/review-enforcer" "$EXT_SAVED"
ln -s "$FIX_BARE/extensions/review-enforcer" "$DEST/extensions/review-enforcer"
AGENT_GH_SHIM_DIR= run_verify
rc=$?
if [ "$rc" -eq 1 ] && grep -q "argv-level gh SHIM is MISSING: $FIX_BARE/scripts/gh-shim/gh" "$LOG"; then
  ok "a farm-SYMLINKED extension is certified at the directory IT resolves — a checkout with no scripts/gh-shim is REFUSED (naming that path), never satisfied by the farmed copy beside it"
else
  fail "a cell whose review-enforcer resolves '$FIX_BARE/scripts/gh-shim' VERIFIED (rc=$rc) — the guard certified a different directory than the extension reads (the #984 false PASS): $(grep -m1 'FAIL:' "$LOG")"
fi
# … and the other direction: with that fixture's pair in place the same cell is HEALTHY and must pass.
FIX_PAIR="$TMP/ext-fixture-pair"      # a checkout WITH the extension AND the merge-gate pair
mkdir -p "$FIX_PAIR/extensions" "$FIX_PAIR/scripts/gh-shim"
# From the SAVED real directory (`cp -R` on a symlink would copy the LINK, so the fixture would
# quietly be the bare one again — measured while writing this arm).
cp -R "$EXT_SAVED" "$FIX_PAIR/extensions/review-enforcer"
cp "$SHIM_DST" "$FIX_PAIR/scripts/gh-shim/gh"; chmod +x "$FIX_PAIR/scripts/gh-shim/gh"
cp "$VERIFIER_DST" "$FIX_PAIR/scripts/verify-admin-merge-evidence.sh"
rm -f "$DEST/extensions/review-enforcer"
ln -s "$FIX_PAIR/extensions/review-enforcer" "$DEST/extensions/review-enforcer"
AGENT_GH_SHIM_DIR= run_verify
rc=$?
[ "$rc" -eq 0 ] \
  && ok "POSITIVE CONTROL: the same symlinked platform PASSES once its own scripts/gh-shim exists (the check follows the extension, it is not a cell-shaped hard-code)" \
  || fail "a HEALTHY farm-symlinked cell was refused (rc=$rc): $(grep -m1 'FAIL:' "$LOG")"
rm -f "$DEST/extensions/review-enforcer"
mv "$EXT_SAVED" "$DEST/extensions/review-enforcer"
run_verify
[ $? -eq 0 ] && ok "the cell is clean again after the extension was put back" \
  || fail "--verify still failed after the symlink-platform arms restored the cell"
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
# (3b) THE INSTALLED COPY IS CHECKED ON ITS OWN — an operator's AGENT_GH_SHIM_DIR may not stand
# in for it. A 644 installed shim with a VALID preference exported used to VERIFY CLEAN, because
# the candidate loop picked the override (executable, verifier sibling present) and never looked
# at the copy the cell's lanes — started WITHOUT the variable — resolve. Bash then SKIPS the
# non-executable entry and the real gh runs with nothing enforcing: the silent fail-open this
# whole section exists to refuse, certified as healthy.
OVR="$TMP/shim-override"; mkdir -p "$OVR"
cp "$SHIM_DST" "$OVR/gh"; chmod +x "$OVR/gh"
cp "$ROOT/scripts/verify-admin-merge-evidence.sh" "$TMP/verify-admin-merge-evidence.sh"
chmod 644 "$SHIM_DST"
AGENT_GH_SHIM_DIR="$OVR" run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'argv-level gh SHIM is NOT EXECUTABLE' "$LOG" \
  && ok "--verify refuses a 644 INSTALLED shim even when a valid AGENT_GH_SHIM_DIR is exported (the preference is not a substitute)" \
  || fail "--verify CERTIFIED a 644 installed shim because AGENT_GH_SHIM_DIR was set (rc=$rc) — the cell's env-less lanes would run the real gh"
rm -f "$TMP/verify-admin-merge-evidence.sh"
run_install >/dev/null 2>&1
# (3b2) … and the OTHER half of that rule, which nothing covered: the override decides whose verifier
# is REQUIRED, so an override that holds an executable `gh` with NO `../verify-admin-merge-evidence.sh`
# beside it is a cell whose gate REFUSES EVERY admin merge (the shim fails closed) — the installed
# pair being intact does not help, because `resolveGhShimDir()` PREFERS the override. Without this
# arm the candidate loop could be deleted outright (`[ -n "$chosen" ] || chosen="$installed"` would
# silently take the installed copy) and every other arm stayed green — MEASURED: the loop's removal
# was invisible to this suite.
# ⛔ … and the remedy it prints must FIT the candidate that failed: `--install` writes the installed
# pair only, so "Re-run --install" is a false trail when the broken candidate is an operator's
# override. The layout is two levels deep so the SIBLING path is unmistakably outside $DEST/scripts.
OVR_NOSIB="$TMP/ovr-nosib"
mkdir -p "$OVR_NOSIB/ghshim"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OVR_NOSIB/ghshim/gh"; chmod +x "$OVR_NOSIB/ghshim/gh"
[ ! -e "$OVR_NOSIB/verify-admin-merge-evidence.sh" ] || fail "the (3b2) fixture is not bare — $OVR_NOSIB already has a verifier sibling"
AGENT_GH_SHIM_DIR="$OVR_NOSIB/ghshim" run_verify
rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q "admin-merge EVIDENCE VERIFIER is missing or empty: $OVR_NOSIB/verify-admin-merge-evidence.sh" "$LOG" \
   && grep -q "$OVR_NOSIB/ghshim" "$LOG" \
   && ! grep -q 'Re-run --install' "$LOG" \
   && grep -q 'AGENT_GH_SHIM_DIR' "$LOG" \
   && ! grep -q 'taken PHYSICALLY' "$LOG"; then
  ok "--verify REFUSES an AGENT_GH_SHIM_DIR override with no verifier sibling (the extension prefers it, so the intact installed pair cannot stand in) — naming the override, NOT prescribing --install (which cannot repair it), and NOT claiming a symlink was involved when none was"
else
  fail "an override holding an executable gh with no ../verify-admin-merge-evidence.sh returned rc=$rc without the override-specific refusal and remedy: $(grep -m1 'FAIL:' "$LOG")"
fi
run_verify
[ $? -eq 0 ] && ok "--verify passes again once the override is out of the environment" \
  || fail "--verify still failed after the override arm (it must not have modified the cell)"
# (3c) THE VERIFIER SIBLING IS RESOLVED THROUGH SYMLINKS. The normal state on a cell is
# `~/.pi/agent/shims/gh` as a LINK to the farmed shim (the harness injects that neutral entry), and
# the shim resolves its own directory by FOLLOWING links. A lexical `$dir/../` join checked
# `$DEST/verify-admin-merge-evidence.sh` — a path nothing installs — so a HEALTHY cell was refused
# and the prescribed `--install` could never repair it.
mkdir -p "$DEST/shims"; ln -s "$SHIM_DST" "$DEST/shims/gh"
AGENT_GH_SHIM_DIR="$DEST/shims" run_verify
rc=$?
[ "$rc" -eq 0 ] \
  && ok "--verify PASSES when AGENT_GH_SHIM_DIR holds a SYMLINK to an installed shim (the verifier sibling resolves through the link, as the shim does)" \
  || fail "--verify refused a healthy cell whose AGENT_GH_SHIM_DIR is the symlinked shims/ dir (rc=$rc): $(grep -m1 'FAIL:' "$LOG")"
rm -f "$DEST/shims/gh"; rmdir "$DEST/shims" 2>/dev/null
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
# (3d) A SYMLINKED CANDIDATE **DIRECTORY** IS THE SAME CLASS as (3c)'s symlinked shim, and it was
# NOT covered by it: walking only the FINAL component never sees a directory that is a link, and the
# `..` was taken LOGICALLY (bash's `cd` strips a component of the LEXICAL path), so the guard tested
# `<the link's lexical parent>/verify-admin-merge-evidence.sh` — a path nothing installs — and REFUSED
# A HEALTHY CELL while the shim itself resolved that sibling fine (the kernel's stat follows the link).
ln -s "$DEST/scripts/gh-shim" "$TMP/ghshim-link"
AGENT_GH_SHIM_DIR="$TMP/ghshim-link" run_verify
rc=$?
[ "$rc" -eq 0 ] \
  && ok "--verify PASSES when AGENT_GH_SHIM_DIR is itself a SYMLINK to the installed gh-shim dir (the verifier is resolved PHYSICALLY, as the kernel resolves it)" \
  || fail "--verify refused a healthy cell whose AGENT_GH_SHIM_DIR is a symlink TO the installed shim dir (rc=$rc): $(grep -m1 'FAIL:' "$LOG")"
# ... and the other direction: with that dir's verifier gone the cell IS unhealthy, so it must be
# refused AND the message must name the RESOLVED path — naming the lexical one sends the operator to
# a path nothing installs, which is the false block again in a different costume.
rm -f "$VERIFIER_DST"
AGENT_GH_SHIM_DIR="$TMP/ghshim-link" run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "admin-merge EVIDENCE VERIFIER is missing or empty: $DEST/scripts/verify-admin-merge-evidence.sh" "$LOG" \
  && grep -q 'Re-run --install' "$LOG" \
  && ok "--verify still REFUSES when the verifier is gone behind the symlinked dir, naming the RESOLVED path (not the link's lexical parent) — and it still prescribes --install, because this candidate IS the installed copy" \
  || fail "--verify did not refuse via the resolved verifier path, or stopped prescribing --install for the installed copy (rc=$rc): $(grep -m1 'FAIL:' "$LOG")"
run_install >/dev/null 2>&1
run_verify
[ $? -eq 0 ] && ok "--verify passes again after the symlinked-dir arm restored the cell" \
  || fail "--verify still failed after the symlinked-dir arm"
rm -f "$TMP/ghshim-link"
# (3e) THE RESOLVER IS BOUNDED — a symlink CYCLE must FAIL CLOSED, not spin. `[ -L ]` on a
# self-referential link is TRUE FOREVER, so an unbounded walk never returns and does not fail: the
# caller HANGS (`--install` ends by verifying, so the hang lands on `cloud-cell-bringup.sh --check`).
# Driven at the FUNCTION level — the resolver is extracted from the installer rather than retyped —
# because `guard_gh_shim`'s own `[ -f ]`/`[ -x ]` hit ELOOP first, so the hang is latent for the
# next caller and for a cycle that appears between that stat and the walk ($CELL_HOME lives under a
# world-writable /tmp).
REALPATH_FNS="$TMP/gh-shim-realpath.sh"
awk '/^GH_SHIM_MAX_LINK_HOPS=/{f=1} f{print} f&&/^}$/{exit}' "$INSTALLER" > "$REALPATH_FNS"
if ! grep -q '^gh_shim_realpath() {' "$REALPATH_FNS"; then
  fail "could not extract gh_shim_realpath from $INSTALLER — the cycle arms would be inconclusive"
else
  RP_DRIVER="$TMP/realpath-driver.sh"
  # The optional 3rd argument sets GH_SHIM_MAX_LINK_HOPS AFTER the function is sourced (the bound is
  # a script-level constant, so an env var cannot reach it in the installer itself) — that is the
  # only way a corrupt bound can arrive today, and it is exactly what the next arm drives.
  printf '%s\n' 'source "$1"' '[ -z "${3:-}" ] || GH_SHIM_MAX_LINK_HOPS="$3"' 'gh_shim_realpath "$2"' 'exit $?' > "$RP_DRIVER"
  # realpath_bounded <link> [bound] — print the resolver's answer; rc is the resolver's, or 124 when
  # it did not return within 30s (which for a CYCLE is the pre-fix behaviour: it spins). No
  # `timeout(1)`: macOS does not ship it, and this suite runs on both.
  # ⛔ THE CAP IS A LOAD GUARD, NOT A MEASUREMENT (#3374 review P2). It was 10 s, and the arms that
  # USE it as a positive control (a 3-hop chain must resolve) fork a bash that sources a library —
  # on a cell hosting lanes at load 100+ that fork can take longer than the cap, and the arm then
  # reported rc=124 as "the hop bound broke the normal case": a FALSE RED on a correct resolver,
  # which is the failure mode that teaches an operator to ignore this suite. Measured: 1 run in 6.
  # The two arms that WANT the timeout (a real cycle must not spin) are unaffected — a correct
  # resolver refuses those by link shape / hop bound immediately, never by reaching this cap.
  realpath_bounded() {
    local out="$TMP/realpath.out" pid i=0 rc
    : > "$out"
    ( bash "$RP_DRIVER" "$REALPATH_FNS" "$1" "${2:-}" >"$out" 2>/dev/null ) &
    pid=$!
    while [ "$i" -lt 300 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; cat "$out"; return 124
    fi
    wait "$pid"; rc=$?
    cat "$out"; return "$rc"
  }
  CY="$TMP/gh-shim-cycles"; mkdir -p "$CY"
  ln -s "$CY/self" "$CY/self"
  out="$(realpath_bounded "$CY/self")"; rc=$?
  { [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
    && ok "the gh-shim path resolver FAILS CLOSED on a SELF-referential link (rc=1, no path returned) — a cycle cannot spin the caller" \
    || fail "a self-referential gh-shim link returned rc=$rc out='$out' (124 = it never returned for 10s) — it must refuse, not hang, and must not guess a path"
  ln -s "$CY/q" "$CY/p"; ln -s "$CY/p" "$CY/q"
  out="$(realpath_bounded "$CY/p")"; rc=$?
  { [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
    && ok "…and on a MUTUAL loop (p -> q -> p) — the hop bound is what stops it, not the link shape" \
    || fail "a mutual gh-shim link loop returned rc=$rc out='$out' (124 = it never returned for 10s) — the resolver has no hop bound"
  # POSITIVE CONTROL: the bound must not break a legitimate chain (the cell's normal state is one
  # link, the farmed install one more), so a 3-hop chain still has to resolve to its target.
  printf '#!/bin/bash\nexit 0\n' > "$CY/target"; chmod +x "$CY/target"
  ln -s "$CY/target" "$CY/hop1"; ln -s "$CY/hop1" "$CY/hop2"
  out="$(realpath_bounded "$CY/hop2")"; rc=$?
  { [ "$rc" -eq 0 ] && [ "$out" = "$CY/target" ]; } \
    && ok "POSITIVE CONTROL: a legitimate multi-hop chain still resolves to its target (the bound is a cycle guard, not a link limit)" \
    || fail "a 3-hop symlink chain no longer resolves (rc=$rc out='$out') — $([ "$rc" -eq 124 ] && echo 'the HARNESS hit its own 30s wait (a loaded box), which is not a resolver verdict: re-run serially' || echo 'the hop bound broke the normal case')"
  # … AND THE BOUND ITSELF MUST BE A PLAIN NON-NEGATIVE INTEGER. `[ N -gt abc ]` is an ERROR (rc 2),
  # not a false, so `&& return 1` never fires and the walk continues — with a self-referential link
  # that is the SAME infinite hang, reached THROUGH the guard. MEASURED pre-fix: rc=124 (still
  # spinning at 10s) with `integer expression expected` on stderr; a caller that sources the function
  # with a corrupted value must still get a bounded resolver. (`-3` is bounded either way — `-gt -3`
  # fires at hop 1 — so it pins the NORMALISATION, not the spin; the garbage values are the spin.)
  for bad in abc 12x '-3' ' '; do
    out="$(realpath_bounded "$CY/self" "$bad")"; rc=$?
    { [ "$rc" -eq 1 ] && [ -z "$out" ]; } \
      && ok "the hop bound REJECTS a value that is not a plain non-negative integer ('$bad') and falls back to the default — a corrupt bound cannot re-open the spin (rc=1, no path)" \
      || fail "a corrupt hop bound ('$bad') returned rc=$rc out='$out' (124 = it spun: [ -gt ] errored, so '&& return 1' never fired)"
  done
fi
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

# The hosted-graph entry is verified on the ARTIFACT, so a hand-edited or stale cell copy is
# refused BY NAME rather than certified. Three shapes that a lane cannot fix from inside the
# lane: the LEGACY stdio entry (needs a checkout+venv+FalkorDB a cell does not have), a LITERAL
# credential written into the shared file, and a missing file. Each must fail --verify.
cp "$DEST/.mcp.json" "$DEST/.mcp.json.keep"
# ⛔ THREE shapes, and each must be refused by ITS OWN rule — the marker is the operator's remedy.
# ⛔ `literal` DELIBERATELY USES A NON-`tt_`/`tk_` TOKEN (#3374 review P2). The whole-file leak scan
# now runs BEFORE every shape exit (so a `tt_`/`tk_` literal in a stdio `command` cannot be echoed
# into the log), which means a `tt_`-shaped Authorization is reported as SECRET_IN_FILE:<path> — the
# stronger message, since it names where. LITERAL_AUTH is still the rule for a literal the token
# pattern does not recognise (`sk-…`, a bare secret), and THAT is the case this shape now pins.
# `secret` remains the env-indirect header + stray token elsewhere case.
for shape in stdio literal secret; do
  python3 - "$DEST/.mcp.json" "$shape" <<'PY'
import json, sys
p, shape = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = d["mcpServers"]["tortoise"]
if shape == "stdio":
    d["mcpServers"]["tortoise"] = {"command": "/x/.venv/bin/python3", "args": ["-m", "tortoise.mcp_server"]}
elif shape == "literal":
    # a literal the tt_/tk_ token pattern does NOT match, so LITERAL_AUTH (not SECRET_IN_FILE) is the
    # rule under test; built at runtime so the transcript redactor does not blank the fixture.
    t["headers"] = {"Authorization": "Bearer " + "sk-" + "live_" + "A" * 24}
else:
    # the header stays env-indirect, so LITERAL_AUTH does NOT fire; the token hides in a comment
    t["_comment"] = "pasted for convenience: " + "t" + "t" + "_" + "A" * 24
json.dump(t and d, open(p, "w"))
PY
  run_verify
  rc=$?
  # each shape is refused by ITS OWN rule: a literal Bearer is LITERAL_AUTH, a leaked token
  # elsewhere is SECRET_IN_FILE, the stdio entry is the shape refusal.
  want="\.mcp.json's tortoise entry is not the hosted shape"
  [ "$shape" = "literal" ] && want="LITERAL bearer token"
  [ "$shape" = "secret" ] && want="SECRET_IN_FILE"
  if [ "$rc" -eq 1 ] && grep -q "$want" "$LOG"; then
    ok "--verify refuses a .mcp.json with the $shape tortoise entry (the cell must not be started)"
  else
    fail "--verify CERTIFIED a .mcp.json with the $shape tortoise entry (rc=$rc, expected refusal by: $want)"
  fi
  cp "$DEST/.mcp.json.keep" "$DEST/.mcp.json"
done
rm -f "$DEST/.mcp.json.keep"

# ⛔ A LEAK IN ANOTHER SERVER IS NOT A BROKEN TORTOISE ENTRY. The token scan covers the whole file,
# so a literal pasted into a cell-local server lands in the same refusal as a broken tortoise entry —
# and reporting it as "tortoise entry is not the hosted shape" points the operator at the one entry
# that is correct. The marker carries the PATH, so the remedy names the entry that actually leaks.
cp "$DEST/.mcp.json" "$DEST/.mcp.json.keep"
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["cell-local"] = {
    "command": "/bin/true",
    # runtime-built: a literal token here would trip the transcript redactor, not the verifier
    "env": {"K": "t" + "t" + "_" + "A" * 24},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "credential LITERAL is written into .mcp.json at cell-local.env.K" "$LOG" \
  && ok "--verify names the entry that actually holds a leaked token (cell-local.env.K), not tortoise" \
  || fail "--verify refused a leak in another server but blamed the tortoise entry (rc=$rc) — the operator is pointed at the entry that is right"
cp "$DEST/.mcp.json.keep" "$DEST/.mcp.json"
rm -f "$DEST/.mcp.json.keep"
# ⛔ A SECRET IN A FAIL LINE (#3374 review P2). The shape exits (STDIO/URLTYPE/…) ran BEFORE the
# whole-file literal scan, so a legacy stdio entry carrying the key in its `command` was echoed
# VERBATIM by the marker — which `verify_graph_mcp` prints into the bring-up log — and the leak was
# never NAMED as a leak: the operator was told "not the hosted shape". Both directions are asserted
# here: the leak is named by PATH, and the key does not appear anywhere in the log.
LEAKKEY="t""t_""$(printf 'Z%.0s' $(seq 1 24))"    # runtime-built: a literal here would trip the redactor, not the verifier
python3 - "$DEST/.mcp.json" "$LEAKKEY" <<'PY'
import json, sys
p, key = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"command": "python3 -m tortoise.mcp_server --key " + key}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qF "credential LITERAL is written into .mcp.json at tortoise.command" "$LOG" \
  && ok "a literal key inside a legacy stdio COMMAND is named as a leak (SECRET_IN_FILE), not as 'the wrong shape'" \
  || fail "a literal key in the stdio command was reported as a shape problem (rc=$rc) — the operator fixes the wrong thing and the leak stays"
grep -qF "$LEAKKEY" "$LOG" \
  && fail "the live key was ECHOED into the run log by the STDIO marker — a secret in a FAIL line is the leak, and the bring-up log carries it" \
  || ok "...and the key never appears in the log (the marker is redacted, not echoed)"
run_install                                              # re-converge on the hosted entry
# ⛔ `_selfHosted` IS AN EXEMPTION, NOT A LICENCE TO CERTIFY ANY STRING (#3374 review P2). A
# SCHEME-LESS url was certified SELFHOSTED rc=0; the client's `new URL()` reads `localhost:8000/mcp`
# as protocol `localhost:` with NO host, so the cell points at nothing and still says LAYER VERIFIED.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "http", "url": "localhost:8000/mcp", "_selfHosted": True}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qF "is not an absolute http(s) url" "$LOG" \
  && ok "a marked self-host with a SCHEME-LESS url is refused BY NAME (the exemption does not certify a string)" \
  || fail "--verify certified a scheme-less self-hosted url (rc=$rc) — a cell pointing at nothing reports LAYER VERIFIED, and the client throws building a transport"
run_install                                              # re-converge before the next section

# ⛔ A TYPO IS NOT A SELF-HOST. Marking ANY differing url `_selfHosted` let the INSTALLER mint the
# exemption `--verify` honours — so the "unmarked non-default url" refusal could never fire after a
# repair, and a cell pointed at a mangled endpoint by a copy/paste was certified. Same HOST spelled
# differently is a typo and the default wins; a different host is a real self-host and is preserved.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t.pop("_selfHosted", None)
t["url"] = "https://api.premiselabs.co/mcp"      # trailing slash missing — same host, wrong spelling
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a near-miss of the hosted url is REPLACED, not marked _selfHosted (a typo is not a self-host)" \
  || fail "install blessed a typo'd hosted url as _selfHosted — the verifier then certifies an endpoint nobody intended"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and not t.get("_selfHosted") else 1)
PY
# ⛔ A LOOKALIKE HOST IS A TYPO TOO (#3374 review P1). `near_miss` compares only the AUTHORITY, so a
# host one letter off (`api.premiselab.co`) read as "a genuine self-host", was preserved AND marked
# `_selfHosted` — and cloud-cell-bringup.sh runs verify → install → verify, so the repair minted the
# very exemption `--verify` had just refused, on an entry still carrying `Bearer
# ${TORTOISE_MCP_API_KEY}`. The live tenant key went to a host nobody vetted.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselab.co/mcp/",      # ONE letter short of the hosted host
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a LOOKALIKE of the hosted host is REPLACED with the default — a repair cannot mint the exemption --verify refused" \
  || fail "install preserved and marked a host-level typo _selfHosted — --verify then certifies it, and the live tenant key is sent to a host nobody vetted (P1)"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and not t.get("_selfHosted") else 1)
PY
# ⛔ THE INSTALLER MUST NOT PRESERVE A URL `--verify` REFUSES (#3374 review P2). The `_selfHosted`
# exemption only certifies an ABSOLUTE http(s) url (`BADURL:`), and the merge's `usable()` did not
# apply that floor — so `--install` (the REPAIR path `cloud-cell-bringup.sh` runs after a verify
# refusal: verify → install → verify) PRESERVED a scheme-less url, marked it `_selfHosted`, and
# handed back a file the very next verify refused. The bring-up could NEVER converge: it died loudly
# on a config its own installer had just re-created. Measured on the real repair path, and the reason
# `usable()` now carries the verifier's floor rather than a second opinion about it.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "http", "url": "localhost:8000/mcp", "_selfHosted": True}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "install REPLACES a scheme-less tortoise url instead of preserving it (the verifier's own BADURL floor)" \
  || fail "install preserved a SCHEME-LESS url — --verify refuses the file the installer just wrote, so verify → install → verify never converges"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and not t.get("_selfHosted") else 1)
PY
run_verify
[ $? -eq 0 ] && ok "...and the repair CONVERGES: the file install wrote is one --verify certifies" \
  || fail "verify still refuses the entry install just wrote — the repair path is a loop, not a repair"
# ⛔ A WHITESPACE-PADDED url IS THE SAME url, AND THE VERIFIER WAS THE ONLY SIDE THAT DISAGREED
# (#3374 review, round 9 P2). `usable()` normalizes with `.strip()` before every predicate, so the
# merge preserves a padded self-host on its STRIPPED form; `graph_mcp_marker` read the RAW value, so
# a leading pad failed its `^scheme://` match and it refused `INSECURE_URL:` / `BADURL:` — while the
# client's own parser builds a working transport from exactly those bytes (`node -e 'new URL(" \
# https://localhost:8000/mcp")'` → host `localhost:8000`, measured). A FALSE BLOCK on a config that
# works, and because `--install` ends in this same verify, the repair re-created the refusal for ever.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": " https://localhost:8000/mcp",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "install PRESERVES a whitespace-padded loopback self-host and marks it (the same url, padded)" \
  || fail "install did not preserve+mark the padded loopback self-host — the convergence arm below would then be vacuous"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if str(t.get("url") or "").strip() == "https://localhost:8000/mcp" and t.get("_selfHosted") else 1)
PY
run_verify
[ $? -eq 0 ] && ok "...and --verify CERTIFIES the padded url: both sides normalize it the way the client's parser does" \
  || fail "--verify refused a padded url the merge preserves and the client parses — verify -> install -> verify never converges (a FALSE BLOCK, not a certification gap)"
# ⛔ THREE SHAPES THAT ONLY EXIST WHEN THE TEMPLATE IS NOT THE SHIPPED ONE (#3374 review, round 11).
# Every arm above installs from `$ROOT/templates/.mcp.base.json`, which is why two rules could be
# right for the shipped file and wrong for the documented self-host one, and one leak shape could be
# named for `mcpServers` and nowhere else. Each arm below therefore builds its own checkout root.
PADTPL="$TMP/padtpl-checkout"; SELFTPL="$TMP/selftpl-checkout"
for _fx in "$PADTPL" "$SELFTPL"; do
  mkdir -p "$_fx"
  for e in "$ROOT"/*; do
    b="$(basename "$e")"
    [ "$b" = templates ] && continue
    ln -s "$e" "$_fx/$b"
  done
  # The WHOLE templates dir, not just its `*.json`: `templates/AGENTS.base.md` is part of what the
  # installer certifies (`a cell would get no global rules`), so a fixture without it fails for a
  # reason that has nothing to do with the arm.
  cp -R "$ROOT/templates" "$_fx/templates"
done
python3 - "$ROOT/templates/.mcp.base.json" "$PADTPL/templates/.mcp.base.json" "$SELFTPL/templates/.mcp.base.json" <<'PY'
import json, sys
src, pad, selfhost = sys.argv[1:4]
# Two SEPARATE fixtures, each from its own fresh read of the shipped template. (The first draft of
# this block re-read and re-assigned in sequence, so only the last write to `d` survived and the
# reader had to trace five assignments to learn that. Same bytes, stated once.)
for out, url in ((pad, " https://api.premiselabs.co/mcp/ "),   # the same endpoint, padded
                 (selfhost, "https://192.168.1.5/mcp")):       # a self-hosting operator's own daemon
    d = json.load(open(src))
    d["mcpServers"]["tortoise"]["url"] = url
    json.dump(d, open(out, "w"), indent=2, ensure_ascii=False)
PY
python3 - "$PADTPL/templates/.mcp.base.json" "$SELFTPL/templates/.mcp.base.json" <<'PY' \
  && ok "the template fixtures really differ from the shipped url (non-vacuity: the arms below cannot pass by reading the shipped file)" \
  || fail "the template fixtures were not written — every arm below would then be measuring the shipped template again"
import json, sys
pad = json.load(open(sys.argv[1]))["mcpServers"]["tortoise"]["url"]
selfhost = json.load(open(sys.argv[2]))["mcpServers"]["tortoise"]["url"]
sys.exit(0 if pad == " https://api.premiselabs.co/mcp/ " and selfhost == "https://192.168.1.5/mcp" else 1)
PY
# ⛔ THE TEMPLATE SIDE OF THE PAD RULE WAS NOT NORMALIZED (#3374 review, round 11 P2). `url` is
# stripped in the verifier and `want_url` was not, so with a padded TEMPLATE url the `url !=
# want_url` arm fired against a cell pointing at exactly the same endpoint: `URL_NOT_DEFAULT:` on a
# correct config, and because `--install` ends in this same verify, a repair loop that never
# converged. Measured pre-fix by deleting the strip: `URL_NOT_DEFAULT:https://api.premiselabs.co/mcp/`.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselabs.co/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install_root "$PADTPL"
[ $? -eq 0 ] && ok "install accepts a template whose url carries a pad (it is the same endpoint, per the client's own parser)" \
  || fail "install refused a template whose url is the hosted endpoint with surrounding space — a hand-edited template then blocks every cell (log: $(grep -m2 -E 'FATAL|UNUSABLE|FAIL' "$LOG" | tr '\n' ' '))"
run_verify_root "$PADTPL"
[ $? -eq 0 ] && ok "…and --verify CERTIFIES it: the template side is normalized too, so verify -> install -> verify converges" \
  || fail "--verify refused URL_NOT_DEFAULT against a padded TEMPLATE url while the cell points at the same endpoint — the repair loop is a FALSE BLOCK that never converges (pre-fix: URL_NOT_DEFAULT:https://api.premiselabs.co/mcp/)"
# ⛔ THE LOOKALIKE RULE'S COMPARAND IS THE HOSTED ENDPOINT, NOT THE TEMPLATE'S URL (#3374 review,
# round 11 P2). With a self-hosting template, `host_typo(cur.url, want.url)` made a two-daemon LAN
# fleet (`192.168.1.5` in the template, `.6` on one cell) one character apart, so the merge REPOINTED
# that cell at its neighbour's daemon — overriding rule 3's "a usable differing entry is PRESERVED"
# — and the NOTE it printed called the neighbour "the hosted host", with a tenant-key reason that is
# false on a keyless self-host.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://192.168.1.6/mcp",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
    "_selfHosted": True,
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install_root "$SELFTPL"
python3 - "$DEST/.mcp.json" <<'PY' && ok "a self-host template does NOT repoint a cell whose own daemon is one character away (192.168.1.6 vs the template's .5)" \
  || fail "install repointed a self-hosted cell at the template's NEIGHBOURING daemon — the lookalike rule was comparing against the template's url instead of the hosted endpoint, so rule 3's preserve-a-self-host was overridden"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://192.168.1.6/mcp" and t.get("_selfHosted") else 1)
PY
# …and the CONTROL: on that SAME self-host template, a lookalike of the HOSTED host is still replaced,
# so the arm above cannot pass by disabling the lookalike rule outright.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselab.co/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install_root "$SELFTPL"
python3 - "$DEST/.mcp.json" <<'PY' && ok "…while a LOOKALIKE of the hosted host is still REPLACED on a self-host template (the rule was narrowed, not disabled)" \
  || fail "a host-level typo of the hosted endpoint survived on a self-host template — the tenant key would go to a host nobody vetted"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://192.168.1.5/mcp" and not t.get("_selfHosted") else 1)
PY
# ⛔ A LITERAL CREDENTIAL OUTSIDE `mcpServers` WAS NAMED NOWHERE (#3374 review, round 11 P1). The
# verifier scans the WHOLE file but searched for the PATH under `mcpServers` only, so a literal in a
# TOP-LEVEL key — a `_noteboard`, a hand-added "token", the shape a curl-style paste produces —
# printed `SECRET_IN_FILE:(unlocatable)`: the operator was told a secret exists and given nowhere to
# look. The install side did not name it at all, so the repair loop never converged either.
python3 - "$DEST/.mcp.json" "$LEAKKEY" <<'PY'
import json, sys
p, key = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["_noteboard"] = key
json.dump(d, open(p, "w"), indent=2)
PY
run_verify_root "$ROOT"
grep -q 'SECRET_IN_FILE:_noteboard' "$LOG" \
  && ok "a literal in a TOP-LEVEL key is NAMED by --verify (not '(unlocatable)'), so the operator knows where to look" \
  || fail "--verify reported a top-level literal as unlocatable — the operator is told a secret exists and given no location (pre-fix: SECRET_IN_FILE:(unlocatable))"
run_install_root "$ROOT"
grep -q 'literal credential at _noteboard' "$LOG" \
  && ok "…and --install NAMES it too, so the install log cannot read as success over a file the verify refuses" \
  || fail "--install said nothing about the top-level literal it preserved — the log reads as a clean install over a file the next --verify refuses"
# CONTROL: the under-`mcpServers` spelling every earlier arm greps is UNCHANGED by the fix.
python3 - "$DEST/.mcp.json" "$LEAKKEY" <<'PY'
import json, sys
p, key = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.pop("_noteboard", None)
d["mcpServers"]["acme"] = {"type": "http", "url": "https://acme.example/mcp",
                           "headers": {"Authorization": "Bearer " + key}}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify_root "$ROOT"
grep -q 'SECRET_IN_FILE:acme.headers.Authorization' "$LOG" \
  && ok "…and a literal inside a server still reports the UNDER-mcpServers path (the fix widened the search, it did not change the spelling)" \
  || fail "the secret marker's spelling changed for an under-mcpServers literal — every arm and every operator grep that relied on it is now wrong"
run_install_root "$ROOT" >/dev/null 2>&1   # restore the shipped-template state for the arms below
# AND DROP THE FIXTURE KEYS: a merge never clobbers, so without this the `acme` literal above is still
# in the file and every later `--verify` arm would find `SECRET_IN_FILE:` before reaching the shape it
# is about (measured: the two USERINFO arms below failed on exactly that contamination).
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("_noteboard", None)
(d.get("mcpServers") or {}).pop("acme", None)
json.dump(d, open(p, "w"), indent=2)
PY
run_install >/dev/null 2>&1
# ⛔ USERINFO IN THE AUTHORITY IS A HOST-SPOOF SHAPE (#3374 review P1).
# `https://api.premiselabs.co@evil.example/mcp/` resolves to **evil.example** while its authority
# BEGINS with the hosted host. `near_miss`/`host_typo` read the authority verbatim, so this was "a
# genuine self-host": the merge PRESERVED it (key and all), marked it `_selfHosted`, and `--verify`
# then certified `SELFHOSTED:` — the live tenant key, sent to an attacker's host with this repo's
# blessing. `host_of()` strips userinfo (the rule `_loopback` already applied), and the shape is
# REPLACED rather than certified: a credential belongs in `headers`, never in the authority.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselabs.co@evil.example/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a USERINFO host-spoof of the hosted host is REPLACED, never certified with the key attached" \
  || fail "install preserved a userinfo URL whose real host is an attacker's — --verify then certifies SELFHOSTED: and the tenant key leaves the box"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and not t.get("_selfHosted") else 1)
PY
# ...and `--verify` must refuse the SAME shape by name. The merge half alone was not enough: a marked
# userinfo url was still certified `SELFHOSTED:` rc=0 — LAYER VERIFIED over the tenant key going to
# the host after the `@` — and the client cannot even build a request from a url with credentials
# (`new Request('http://u:p@h/')` throws), so verify was certifying a config that cannot run.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "url": "https://api.premiselabs.co@evil.example/mcp/",
    "_selfHosted": True,
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qF "carries USERINFO in its authority" "$LOG" \
  && ok "--verify REFUSES a userinfo url BY NAME (the exemption does not certify a spoof, key attached)" \
  || fail "--verify certified a userinfo url (rc=$rc) — the real host is the part after '@', and LAYER VERIFIED over an attacker's host is the false green this PR exists to close"
run_install                                             # the repair must converge from this shape
run_verify
[ $? -eq 0 ] && ok "...and the repair CONVERGES out of it" \
  || fail "verify still refuses what install produced from a userinfo entry"
# ⛔ A DEFAULT PORT IS THE SAME ENDPOINT, AND IT WAS THE SELF-HOST EXEMPTION'S WAY IN (#3374 review,
# round 12 P2). The "does this entry need the hosted credential" question compared BYTES against
# `HOSTED_DEFAULT_URL`, so every non-canonical spelling of the SAME endpoint — `:443` under https,
# `:80` under http, the bare `host:` — fell to the self-host branch, was PRESERVED, marked
# `_selfHosted`, and certified with NO credential check. Measured pre-fix, on the shipped template:
# the canonical spelling of an entry declaring `Bearer ${SOME_OTHER_VAR}` (which expands to an EMPTY
# Bearer — the #3275/#3289 401 this whole change exists to close) was REPLACED, while its `:443`
# spelling was kept, marked, and printed `SELFHOSTED:` rc=0 beside a note saying "a self-hosted
# daemon needs none" about the HOSTED host. WHATWG drops a default port (`new URL(':443')` href is the
# canonical form), so the two spellings ARE one endpoint; `endpoint_key()` is that identity.
# ⛔ AND A LEADING ZERO IS THE SAME PORT (#3374 round 12 residual, found by adversarial measurement AFTER
# the fix above): `new URL('https://api.premiselabs.co:0443/mcp/').href` is the CANONICAL hosted url —
# the parser reads the DIGITS — so `:0443` and `:00443` were the hosted endpoint spelled differently and
# still took the self-host exemption: measured pre-fix, install PRESERVED `:0443` + marked `_selfHosted`
# + `--verify` certified `SELFHOSTED:`, beside a `${SOME_OTHER_VAR}` header that expands to an EMPTY
# Bearer. Both spellings are in the loop, because a rule that only normalises the spelling its author
# typed is the class this PR keeps closing.
for _SPELL in "https://api.premiselabs.co:443/mcp/" "https://api.premiselabs.co:/mcp/" \
             "https://api.premiselabs.co:0443/mcp/" "https://api.premiselabs.co:00443/mcp/"; do
  python3 - "$DEST/.mcp.json" "$_SPELL" <<'PY'
import json, sys
p, spell = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": spell,
    "headers": {"Authorization": "Bearer ${SOME_OTHER_VAR}"},
}
d["mcpServers"].pop("acme", None)
json.dump(d, open(p, "w"), indent=2)
PY
  run_install
  python3 - "$DEST/.mcp.json" "$_SPELL" <<'PY' && ok "a DEFAULT-PORT spelling of the hosted endpoint ($_SPELL) is REPLACED, not exempted — the entry is the hosted host and needs the hosted credential" \
    || fail "install preserved $_SPELL as a self-host while it is the SAME endpoint as the hosted default (a default port is not part of an endpoint's identity) — the entry keeps a wrong credential variable, expands to an empty Bearer, and --verify then certifies it"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/"
         and not t.get("_selfHosted")
         and t.get("headers", {}).get("Authorization") == "Bearer ${TORTOISE_MCP_API_KEY}" else 1)
PY
  run_verify
  # ⛔ AN rc-ONLY ASSERTION HERE IS GREEN WITH THE FIX REVERTED (#3374 review, round 12 P2). Pre-fix,
  # `--verify` answered `SELFHOSTED:<the :443 spelling>` rc=0 for an entry STILL carrying
  # `${SOME_OTHER_VAR}`, so `[ $? -eq 0 ]` reported convergence on exactly the bypass. The marker is
  # the property: the canonical endpoint CERTIFIED, and no exemption claimed for a hosted url.
  [ $? -eq 0 ] && grep -qF 'OK:https://api.premiselabs.co/mcp/:${TORTOISE_MCP_API_KEY}' "$LOG" \
    && ! grep -qE 'SELFHOSTED:' "$LOG" \
    && ok "...and --verify CERTIFIES what install wrote — the repair loop converges on the hosted credential" \
    || fail "--verify did not certify the canonical hosted entry install just produced from a default-port spelling (or certified it as a SELF-HOST) — verify -> install -> verify never converges on the hosted credential"
done
# …and the CONTROL: a NON-default port is a genuinely different endpoint. It must stay a preserved,
# named self-host — so the arm above cannot pass by deleting the self-host exemption outright (that
# would repoint every operator's own daemon, the silent-repoint defect this file's rule 3 forbids).
# ⛔ THE CONTROL IS A LOOP FOR THE SAME REASON THE ARM IS: the leading-zero fix above normalises the
# PORT DIGITS, so a leading-zero NON-default port must still be a DIFFERENT endpoint (`:08443` is the
# operator's daemon on 8443, not a typo of anything). A control that only ever proved `:8443` would be
# green over a rule that had started eating `:08443` as well.
for _OWN in "8443" "08443"; do
python3 - "$DEST/.mcp.json" "$_OWN" <<'PY'
import json, sys
p, port = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselabs.co:%s/mcp/" % port,
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" "$_OWN" <<'PY' && ok "…while a NON-DEFAULT port ($_OWN) is still PRESERVED and marked a self-host (the rule was narrowed to DEFAULT ports, not disabled)" \
  || fail "install repointed an operator's own daemon on a non-default port ($_OWN) — a non-default port IS part of the endpoint, and repointing it is the silent-repoint defect this merge exists to prevent"
import json, re, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
m = re.match(r"^https://api\.premiselabs\.co:(\d+)/mcp/$", t.get("url") or "")
# The BYTES are preserved as written (a merge never rewrites an operator's daemon), so the port is
# compared NUMERICALLY — that is the same rule `endpoint_key` applies, and it is what makes `08443`
# and `8443` the one endpoint they are.
sys.exit(0 if m and int(m.group(1)) == int(sys.argv[2]) and t.get("_selfHosted") else 1)
PY
run_verify
[ $? -eq 0 ] && ok "...and --verify certifies it BY NAME (SELFHOSTED:)" \
  || fail "--verify refused a preserved non-default-port self-host ($_OWN) — install and verify disagree about one file"
done
run_install >/dev/null 2>&1
# ⛔ THE MARKER THAT FIRES FOR THE COMMON CASE ECHOED THE RAW URL (#3374 review, round 12 P2), and a
# url may carry a userinfo PASSWORD. `URL_NOT_DEFAULT` is the arm an operator sees whenever an entry
# differs from the template — and it printed the url verbatim, so
# `URL_NOT_DEFAULT:https://alice:hunter2@evil.example/mcp/` put the password into a bring-up log that
# gets pasted into issues, while `USERINFO:` and `INSECURE_URL:` on the SAME url printed `<redacted>`.
# `WRONG_AUTH` echoed the whole header for the same reason (it is not a `tt_`/`tk_` shape, so
# `redact()` was never applied). Both are pinned here by SECRET, not by marker text: a marker that is
# present with the secret beside it is exactly the failure.
# ⛔ THE FIXTURE BELOW IS THE *REACHABLE* WRONG_AUTH SHAPE, AND THAT IS NOT A DETAIL (#3374 round 12).
# The first draft of this arm used a bare literal (`Bearer hunter2NOTATOKEN`) — which never reaches
# `WRONG_AUTH` at all: the marker refuses a `${`-less header as `LITERAL_AUTH` one branch earlier and
# prints no value, so the arm failed on a marker the shape cannot produce (measured: LATEST/OLD both
# `LITERAL_AUTH`). WRONG_AUTH is reached only by a header that DOES carry `${` but is not the exact
# env-indirect form, and the leak needs a trailing literal: measured on the PRE-FIX marker,
# `Bearer ${TORTOISE_MCP_API_KEY} hunter2NOTATOKEN` printed the whole header including the token,
# and post-fix prints `${TORTOISE_MCP_API_KEY}`. That makes this arm RED against the old code.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://alice:hunter2@evil.example/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qE 'URL_NOT_DEFAULT:' "$LOG" && ! grep -qF 'hunter2' "$LOG" \
  && ok "URL_NOT_DEFAULT reports the url WITHOUT the userinfo password (the common-case marker was the one that leaked)" \
  || fail "URL_NOT_DEFAULT is missing, or it echoed the userinfo password into the bring-up log (rc=$rc) — a log that gets pasted into issues and PRs fleet-wide"
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselabs.co/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY} hunter2NOTATOKEN"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qE 'WRONG_AUTH:' "$LOG" && ! grep -qF 'hunter2NOTATOKEN' "$LOG" \
  && ok "WRONG_AUTH names the VARIABLE and withholds everything after it (a trailing literal, which redact() never sees, stayed in the log)" \
  || fail "WRONG_AUTH echoed the header verbatim into the log (rc=$rc) — a credential that is not tt_/tk_-shaped still lands in a pasted log"
run_install >/dev/null 2>&1
# ⛔ THE LEAK ALSO SAT ONE BRANCH OVER, ON THE BRANCH THAT FIRES FOR A *CORRECT* CONFIG (#3374 review,
# round 12 P2). The success marker printed the Authorization header VERBATIM, and `HOSTED_AUTH`
# admits `${VAR:-<anything>}` — a spelling the client really supports (`extensions/mcp-client/index.ts`:
# "${VAR:-default}", expanded recursively) — so a literal DEFAULT is a value that reaches the wire and
# it went into BOTH the `--verify` and the `--install` log. Measured pre-fix:
# `OK:https://api.premiselabs.co/mcp/:Bearer ${TORTOISE_MCP_API_KEY:-hunter2NOTATOKEN}` rc=0.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselabs.co/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY:-hunter2NOTATOKEN}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 0 ] && grep -qE 'OK:https://api.premiselabs.co/mcp/' "$LOG" && ! grep -qF 'hunter2NOTATOKEN' "$LOG" \
  && ok "the OK: marker reports WHICH VARIABLE and withholds a \${VAR:-default}'s literal — a supported spelling whose default is a real credential (rc=$rc)" \
  || fail "the success marker echoed the Authorization header verbatim (rc=$rc) — a \${VAR:-literal} default landed in a bring-up log that gets pasted into issues"
run_install >/dev/null 2>&1
# ⛔ THE INSTALL SUMMARY CLAIMED "hosted" OVER A SELF-HOST TEMPLATE (#3374 review, round 12 P3).
# `merge_tortoise_is_hosted` compared the written file against the TEMPLATE's url, so a cell correctly
# matching its own `localhost` daemon satisfied it and the log said "hosted tortoise entry installed"
# about an entry pointing at localhost — the same false-sentence class round 11 fixed one file over.
# ⛔ AND THE FIXTURE MUST ACTUALLY PLANT THAT STATE (#3374 review, round 12 P2). The first version of
# this arm ran over a `.mcp.json` that still held the HOSTED url, and BOTH predicates answer 1 for it
# (pre-fix: have==want; post-fix: want is not hosted), so the arm printed `ok` against the PRE-FIX
# code — it was measuring its own silence. Planting the entry at the template's own url makes it
# discriminating: measured, pre-fix prints "hosted tortoise entry installed" (RED) and the fix prints
# "NOT the hosted default" (green).
python3 - "$DEST/.mcp.json" "$SELFTPL/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
json.dump(d, open(p, "w"), indent=2)
PY
run_install_root "$SELFTPL" >/dev/null 2>&1
! grep -q 'hosted tortoise entry installed' "$LOG" \
  && grep -q 'NOT the hosted default' "$LOG" \
  && ok "a self-host template's install does NOT claim a HOSTED entry was installed (the summary compares against the hosted endpoint, not the template)" \
  || fail "the install summary printed 'hosted tortoise entry installed' over an entry pointing at the template's own daemon — a sentence that is false about the artifact"
run_install_root "$ROOT" >/dev/null 2>&1   # back to the shipped template
run_install >/dev/null 2>&1
# ⛔ A NON-OBJECT `tortoise` IS OPERATOR CONTENT, AND IT VANISHED SILENTLY (#3374 review P2). Every
# sibling container shape names its replacement and keeps the bytes; this one was replaced with no
# `NOTE:` and no `.bak` — against the merge's own "nothing here is silent" contract.
rm -f "$DEST/.mcp.json.bak"
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = ["/x/python3", "-m", "tortoise.mcp_server"]
json.dump(d, open(p, "w"), indent=2)
PY
run_install
[ -f "$DEST/.mcp.json.bak" ] && grep -qF "REPLACED a list tortoise entry" "$LOG" \
  && ok "a non-object tortoise entry is REPLACED BY NAME, and its bytes are kept as .bak" \
  || fail "install replaced a hand-written non-object tortoise entry SILENTLY — no NOTE, no backup, and --verify then reports NOENTRY over a file the installer rewrote"
python3 - "$DEST/.mcp.json.bak" <<'PY' && ok "...and the .bak really holds the replaced entry (a backup that is not the old bytes is a lie)" \
  || fail "the .bak does not hold the entry the merge replaced"
import json, sys
sys.exit(0 if (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise") == ["/x/python3", "-m", "tortoise.mcp_server"] else 1)
PY
# ⛔ THE NOTE MUST NAME THE FILE THAT EXISTS (#3374 review P2). `_keep_backup` writes beside the
# RESOLVED path — a dotfiles-SYMLINKED `.mcp.json` is the common case this branch exists for — so a
# message that printed `<dst>.bak` sent the operator to an empty path while their bytes sat beside
# the symlink's target. Asserted by parsing the NOTE for the path it names and opening exactly that.
python3 - "$DEST/.mcp.json" "$TMP/mcp-real.json" <<'PY'
import json, os, shutil, sys
dest, real = sys.argv[1], sys.argv[2]
shutil.copy2(dest, real)
os.unlink(dest)
os.symlink(real, dest)
d = json.load(open(real))
d["mcpServers"]["tortoise"] = ["/x/python3", "-m", "tortoise.mcp_server"]
json.dump(d, open(real, "w"), indent=2)
PY
run_install
BAK_NAMED="$(sed -n 's/.*the previous file was saved as \([^ ]*\)$/\1/p' "$LOG" | tail -1)"
[ -n "$BAK_NAMED" ] && [ -f "$BAK_NAMED" ] \
  && ok "the backup NOTE names a path that EXISTS when .mcp.json is a symlink (followed, not replaced)" \
  || fail "the NOTE named '$BAK_NAMED', which does not exist — the operator is sent to an empty path to recover a hand-written entry"
[ -L "$DEST/.mcp.json" ] && ok "...and the symlinked .mcp.json is still a symlink (the write follows it)" \
  || fail "install replaced a symlinked .mcp.json with a regular file — a dotfiles-managed config is silently detached"
rm -f "$DEST/.mcp.json" "$TMP/mcp-real.json" "$TMP/mcp-real.json.bak"
run_install
# ⛔ THE TEMPLATE WAS THE ONE INPUT WHOSE FAILURE WAS A PYTHON TRACEBACK (#3374 review P2). Every other
# unreadable shape is a NAMED refusal; a missing or CORRUPT template raised straight out of `main`
# (rc=1, `FileNotFoundError:` on stderr) while the docstring documents 0 / 2 / 3. It is reachable:
# `setup.sh` guards only `[ -f ]`, so a corrupt template printed a traceback under `set -e`.
printf '{oops' > "$TMP/corrupt-template.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/corrupt-template.json" "$DEST/.mcp.json" --cell > "$TMP/badtpl.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'FATAL: cannot read the template' "$TMP/badtpl.out" \
  && ! grep -q 'Traceback' "$TMP/badtpl.out" \
  && ok "an UNPARSEABLE template is a named FATAL with the documented exit 3, not a traceback" \
  || fail "a corrupt template produced rc=$rc / a traceback instead of the documented named refusal (exit 3) — setup.sh then aborts with Python internals"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/absent-template.json" "$DEST/.mcp.json" --cell > "$TMP/notpl.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'FATAL: cannot read the template' "$TMP/notpl.out" && ! grep -q 'Traceback' "$TMP/notpl.out" \
  && ok "...and a MISSING template takes the same named path (a missing file is not a crash)" \
  || fail "a missing template produced rc=$rc / a traceback instead of a named FATAL (exit 3)"
# ⛔ A TEMPLATE THAT PARSES BUT IS THE WRONG **SHAPE** WAS STILL A TRACEBACK (#3374 review P2). Guarding
# `json.load` alone left `tpl.get` on a list (and `base.get` on a non-object `mcpServers`) raising
# straight out of `main` — rc=1 and Python internals, the exact contract the parse guard declares
# closed. A shape this file cannot read gets the same named answer as a file it cannot parse.
printf '[]' > "$TMP/list-template.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/list-template.json" "$DEST/.mcp.json" --cell > "$TMP/listtpl.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'FATAL: the template' "$TMP/listtpl.out" && ! grep -q 'Traceback' "$TMP/listtpl.out" \
  && ok "a template whose ROOT is not an object is a named FATAL (exit 3), not a traceback" \
  || fail "a list-shaped template produced rc=$rc / a traceback instead of a named FATAL"
printf '{"mcpServers": 5}' > "$TMP/badservers-template.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/badservers-template.json" "$DEST/.mcp.json" --cell > "$TMP/badsrv.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'FATAL: the template' "$TMP/badsrv.out" && ! grep -q 'Traceback' "$TMP/badsrv.out" \
  && ok "...and a non-object template 'mcpServers' takes the same named path" \
  || fail "a non-object template mcpServers produced rc=$rc / a traceback instead of a named FATAL"
# ...while a GENUINE self-host stays preserved: the rule "a different host is a real self-host" is
# recorded, and this arm is what keeps the lookalike fix from quietly overriding it.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "http", "url": "http://localhost:8000/mcp"}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "...and a genuine self-host (localhost) is still preserved and marked (the lookalike rule is narrow)" \
  || fail "the lookalike rule swallowed a GENUINE self-host — that reverses the recorded preserve-a-self-host behaviour"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "http://localhost:8000/mcp" and t.get("_selfHosted") is True else 1)
PY
# ⛔ THE PORT IS PART OF THE ENDPOINT, NOT PART OF ITS SPELLING (#3374 review P2). A `near_miss` that
# compared the HOST alone made an operator's OWN daemon on a non-default port
# (`https://api.premiselabs.co:8443/mcp/`) compare equal to the hosted default — so the merge REPLACED
# it and told them it was "a typo", destroying a config that works. The comparand is the AUTHORITY
# (`host[:port]`, userinfo stripped), which is what near_miss's own docstring always said.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "http", "url": "https://api.premiselabs.co:8443/mcp/"}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a self-host differing only by PORT is PRESERVED (the port is part of the endpoint, not the spelling)" \
  || fail "install replaced an operator's daemon on a non-default port and called it a typo — a working self-host destroyed"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co:8443/mcp/" and t.get("_selfHosted") is True else 1)
PY
# ...and a self-hosted entry that spells its OWN transport still works: the client never reads `type`
# (it selects StreamableHTTP from `url` alone), so replacing it would destroy the operator's config.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "sse", "url": "http://localhost:8000/mcp"}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a self-hosted entry declaring its own transport is PRESERVED (the client ignores type)" \
  || fail "install replaced a working self-hosted entry because of its \`type\` — the operator's daemon is destroyed and they are pointed at a hosted endpoint they have no key for"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "http://localhost:8000/mcp" else 1)
PY
# ⛔ INSTALL AND VERIFY MUST AGREE ABOUT THE ENTRY INSTALL JUST PRESERVED. They did not: the merge
# deliberately kept a self-hosted `type: "sse"` entry, while `--verify` refused EVERY non-http `type`
# before it ever looked at the url. ⛔ THE MECHANISM IS A FALSE **BLOCK**, NOT A FALSE PASS, and the
# difference matters to whoever reads this next: `--install` runs this same verify (`verify_layer`) and
# exits 1 on a recorded failure, and `cloud-cell-bringup.sh` turns a non-zero install rc into a `die`
# — so the repair loop re-created the refusal and the cell could NEVER converge: every bringup failed
# loudly, on a config the installer had itself just preserved. Certification was never the hole (it
# comes from the install's rc, which already carries the verdict); convergence was. The client picks
# its transport from `url` alone (`extensions/mcp-client/index.ts`: `if (config.url) …
# StreamableHTTPClientTransport`), so `sse` on a self-hosted daemon is the operator's spelling, not a
# fault. ONE rule, both sides.
run_verify
rc=$?
[ "$rc" -eq 0 ] && grep -q "SELFHOSTED:http://localhost:8000/mcp" "$LOG" \
  && ok "install and verify AGREE on a preserved self-hosted entry (certified BY NAME, not refused for its transport)" \
  || fail "--verify refused (rc=$rc) an entry install had just deliberately preserved, or did not certify it by name — the cell then fails every bring-up with no repair that can clear it"
# ⛔ THE EXACT BYTES THE FIX IS ABOUT, DRIVEN AGAINST `--verify` ALONE. The arm above reaches the
# preserved state by running `--install` first, so it only proves the two agree AFTER the merge has
# written `_selfHosted`. The shape that could never be certified is the FILE ON DISK — hand-written,
# or restored from a backup, already carrying the marking — and there `--verify` is the only thing
# that runs (the review reproduced exactly this and got `NOTHTTP:sse` -> FAIL). Byte for byte:
#     {"type": "sse", "url": "http://localhost:8000/mcp", "_selfHosted": true}
# Before the fix the `type` test ran UNCONDITIONALLY and FIRST, so this file was refused whatever the
# url and whatever the marking said; `--install` preserved the very entry, ran this same verify, and
# exited 1, which `cloud-cell-bringup.sh` turns into a `die` — so the repair loop re-created the
# refusal and the cell could never converge. This arm contains NO install, so nothing the merge did
# can satisfy it.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"type": "sse", "url": "http://localhost:8000/mcp", "_selfHosted": True}
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 0 ] && grep -q "SELFHOSTED:http://localhost:8000/mcp" "$LOG" \
  && ok "--verify ALONE certifies the exact self-hosted bytes {\"type\":\"sse\",\"url\":\"http://localhost:8000/mcp\",\"_selfHosted\":true}" \
  || fail "--verify refused (rc=$rc) the exact self-hosted bytes {\"type\":\"sse\",\"url\":\"http://localhost:8000/mcp\",\"_selfHosted\":true} — install preserves this shape and verify refuses it, so no repair can make the cell converge (marker: $(grep -m1 'verify:' "$LOG" | sed 's/^ *//'))"
# …and a re-install over exactly those bytes must leave them alone: a merge that "normalised" the
# entry into a second spelling would re-open the same disagreement from the other side.
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "…and a re-install over those bytes leaves the entry untouched (no second spelling, no repoint)" \
  || fail "re-install rewrote the self-hosted entry --verify had just certified — the two sides disagree again"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if (t.get("url"), t.get("type"), t.get("_selfHosted")) == ("http://localhost:8000/mcp", "sse", True) else 1)
PY
# ⛔ A SCHEME-ONLY TYPO MUST NOT MINT THE `_selfHosted` EXEMPTION. `http://` for `https://` on the
# SAME host is a typo, not a self-host — but the merge compared (scheme, host), so it read as a
# self-host, PRESERVED the cleartext url, marked it `_selfHosted`, and `--verify` then honoured the
# exemption it had just been handed (rc=0, `SELFHOSTED:` printed). The hosted entry carries a live
# `Bearer ${TORTOISE_MCP_API_KEY}`, so the cost is not a 401: the tenant key crosses the wire in
# cleartext while the cell prints LAYER VERIFIED beside a green `graph credential: resolves from …`.
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
t["url"] = "http://api.premiselabs.co/mcp/"      # SCHEME downgraded — SAME host
# the credential header is the TEMPLATE's own, so this fixture never has to spell one (and cannot
# drift from the canonical bytes the verifier accepts)
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a SCHEME-only downgrade of the hosted url is REPLACED, not blessed with _selfHosted (a typo is not a self-host)" \
  || fail "install marked http://api.premiselabs.co/mcp/ as _selfHosted and kept it — the verifier then certifies a cell that sends its tenant key in cleartext"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and not t.get("_selfHosted") else 1)
PY
# ...and the verifier must refuse a credential on a non-https url on its OWN evidence: a hand-edited
# file can carry the exemption without any install having blessed it, and `_selfHosted` is an
# assertion by the operator, never a licence to leak.
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
t["url"] = "http://api.premiselabs.co/mcp/"
t["_selfHosted"] = True                        # the exemption, asserted by hand
# again the TEMPLATE's own credential header: the arm is about the SCHEME, not about the header
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q "carries a credential over a NON-https scheme" "$LOG" \
  && ok "--verify refuses a credential on a non-https url even when it is marked _selfHosted (no exemption for cleartext)" \
  || fail "--verify certified a tortoise url that would send the tenant key over cleartext (rc=$rc) — _selfHosted must not licence a credential in the clear"
# ⛔ THE FLAG THAT DECIDES A CELL'S MCP SURFACE MUST NOT FAIL OPEN ON A TYPO. The parser dropped
# every unknown `--flag` and matched `--cell` by exact string, so `--cel` exited 0 having installed
# the FULL base catalog — the unspawnable set the cell rule exists to keep off a small box — and a
# longer catalog reads as richer, not wrong, so nothing downstream reports it.
printf '{"mcpServers":{}}' > "$TMP/typo-dest.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/typo-dest.json" --cel > "$LOG" 2>&1
rc=$?
[ "$rc" -eq 2 ] \
  && ! python3 -c 'import json,sys; sys.exit(0 if (json.load(open(sys.argv[1])).get("mcpServers") or {}) else 1)' "$TMP/typo-dest.json" \
  && ok "a mistyped --cell is a USAGE ERROR (rc=2) that writes nothing, not a silent full-catalog install" \
  || fail "merge-mcp.py accepted a mistyped flag (rc=$rc) and installed the full base catalog on a cell"
# ⛔ A CELL THAT ALREADY DECLARES A BASE SERVER: the merge KEEPS it (never clobber, rule 2) — and
# must SAY SO. `dropped` was computed as `k not in have`, so the NOTE listed only the servers that
# were MISSING: a cell carrying a hand-installed `seo-intelligence` (which cannot spawn there at
# all) printed "not installed on a cell: gemini, playwright-browser" and nothing else, which reads as
# "the base catalog is not here" while the unspawnable entry sat in the file, `--verify` certifying.
printf '{"mcpServers":{"seo-intelligence":{"command":"hand-installed","args":[]}}}' > "$TMP/kept-dest.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/kept-dest.json" --cell > "$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q "already declares seo-intelligence" "$LOG" && grep -q 'KEPT' "$LOG" \
  && ok "--cell NAMES a base server the cell already declares (KEPT, not silently absent from the note)" \
  || fail "--cell left a pre-existing base server unreported (rc=$rc) — the log implies the base catalog is not installed while an unspawnable entry sits in the file, certified"
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = json.load(open(tpl))["mcpServers"]["tortoise"]
json.dump(d, open(p, "w"), indent=2)
PY

# ⛔ INSTALL AND VERIFY MUST ALSO AGREE ABOUT A CREDENTIAL IN THE CLEAR. `usable()` accepted ANY
# non-default url, so a remote http self-host carrying the template's credential header was PRESERVED
# and marked `_selfHosted` while `--verify` refused it (`INSECURE_URL`) — the same "install preserves
# what verify refuses" loop c990c780 closed for `type`, on the credential surface, where each repair
# re-mints the config the verifier refuses. One rule on both sides: the arm INSTALLS and then VERIFIES.
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
t["url"] = "http://graph.example:8000/mcp"        # remote, plaintext, template's own credential
# the credential header is the TEMPLATE's own, so this arm is about the SCHEME and cannot drift
# from the canonical bytes the verifier accepts
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
run_verify
rc=$?
[ "$rc" -eq 0 ] && grep -q "OK:https://api.premiselabs.co/mcp/" "$LOG" \
  && ok "install REPLACES a remote plaintext self-host carrying a credential, and --verify agrees (no unrecoverable loop)" \
  || fail "install preserved (or verify refused) an entry that would send the credential over cleartext (verify rc=$rc) — the repair can never converge"
# ⛔ ...AND THE LOOPBACK EXEMPTION IS AN IP-LITERAL TEST, NEVER A PREFIX TEST. `127.evil.com` is an
# ordinary DNS name its owner can point anywhere, and `127.0.0.1@evil.example` is the loopback
# spelling followed by userinfo and an ATTACKER'S host. A `startswith("127.")` exemption certified
# both `SELFHOSTED:` rc=0 with the tenant key attached (measured).
for LOOKALIKE in "http://127.evil.com/mcp/" "http://127.0.0.1@evil.example/mcp/"; do
  python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" "$LOOKALIKE" <<'PY'
import json, sys
p, tpl, u = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
t["url"] = u
t["_selfHosted"] = True
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -q "carries a credential over a NON-https scheme" "$LOG" \
    && ok "--verify refuses the lookalike host $LOOKALIKE (loopback is an IP test, not a prefix test)" \
    || fail "--verify certified $LOOKALIKE — a host that merely STARTS with 127 was treated as loopback, and the tenant key would go to it in cleartext"
done
# ⛔ THE LOOPBACK EXEMPTION MUST ACCEPT EVERY SPELLING OF LOOPBACK, not just the one this suite
# happened to write. The bracketed-IPv6 arm string-matched `::1`, so the fully expanded
# `[0:0:0:0:0:0:0:1]` was called REMOTE and refused `INSECURE_URL` — a false block on the documented
# local self-host, in the direction that bricks a bring-up (verify refuses → install preserves it
# again → verify refuses). It asks `ipaddress` now, and THIS ARM is what makes a revert to the string
# match red: before it existed, nothing in the suite noticed the predicate at all. Install AND
# verify, because the defect lived on both sides (`merge-mcp.py` `usable()` carries the same copy).
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
t["url"] = "http://[0:0:0:0:0:0:0:1]:8000/mcp"     # loopback, spelled out in full
t["_selfHosted"] = True
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
run_verify
rc=$?
[ "$rc" -eq 0 ] && grep -qF 'SELFHOSTED:http://[0:0:0:0:0:0:0:1]:8000/mcp' "$LOG" \
  && ok "a fully-expanded IPv6 loopback self-host is PRESERVED and certified (loopback is an IP test in both files)" \
  || fail "a legal loopback spelling (http://[0:0:0:0:0:0:0:1]:8000/mcp) was refused (rc=$rc) — a false block on the documented local self-host, and the repair cannot converge"
# ⛔ AN IPv6 LITERAL IS ONE HOST TOKEN — AND THIS ARM IS THE ONLY THING THAT SAYS SO (#3374 review P3).
# The host class used to stop at the first colon INSIDE the brackets, so `[::1]` and `[::2]` both read
# as `[` and ANY comparison built on it called two DISTINCT hosts equal. The commit that fixed it
# shipped with no arm: reverting just the bracketed alternative left this suite byte-identically
# green (223 ok / 0 FAIL, measured), i.e. a correct hardening nobody could regress. Driven at the
# PREDICATE, on purpose — `near_miss` is called with the template's `want_url`, which is never a
# bracketed literal, so the bracket branch is reachable on ONE side only and no install/verify arm
# could ever see a difference.
python3 - "$ROOT/pi-bootstrap/lib/merge-mcp.py" <<'PY' \
  && ok "an IPv6 literal stays ONE host token — [::1] and [::2] do not collapse to the same host" \
  || fail "the IPv6 host parse collapsed distinct literals to one token — every comparison built on host_of/authority_of would call two different hosts equal"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mm", sys.argv[1])
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
# the literal must survive WHOLE, port outside it
assert mm.host_of("http://[::1]:8000/mcp") == "[::1]", mm.host_of("http://[::1]:8000/mcp")
assert mm.host_of("http://[::2]:8000/mcp") == "[::2]", mm.host_of("http://[::2]:8000/mcp")
assert mm.authority_of("http://[::1]:8000/mcp") == "[::1]:8000", mm.authority_of("http://[::1]:8000/mcp")
assert mm.host_of("http://[::1]:8000/mcp") != mm.host_of("http://[::2]:8000/mcp")
sys.exit(0)
PY
# ⛔ `_selfHosted` IS AN EXEMPTION, AND AN EXEMPTION MAY ONLY CERTIFY SOMETHING REACHABLE (#3374
# review P3). The floor was "one character after //", so an entry with NO host was printed
# `SELFHOSTED:` and exited 0 — LAYER VERIFIED over an endpoint that points at nothing, the same false
# green the scheme-less `BADURL:` arm closes. Every shape below is one `new URL(u)` THROWS on in the
# client (measured `ERR_INVALID_URL`), so refusing it cannot over-block a config that works: no
# request can be built from it either. And because `merge-mcp.py`'s `authority_names_a_host` is the
# SAME predicate, install REPLACES each one — asserted, because a refusal with no repair is a cell
# that can never converge.
for _bad in 'https://:8443/mcp/' 'https://my daemon:8000/mcp' 'https://./mcp/' 'https://-/mcp/' \
            'https://api.premiselabs.co:8443x/mcp/' 'https://api.premiselabs.co%40evil.example/mcp/' \
            'https://host:65536/mcp/' 'https://host:-1/mcp/' 'https://a..b/mcp/' \
            'https://api.premiselabs.co|evil.example/mcp/' 'https://a^b.example/mcp/' \
            'https://a<b.example/mcp/' 'https://١.example/mcp/'; do
  python3 - "$DEST/.mcp.json" "$_bad" <<'PY'
import json, sys
p, u = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "url": u, "_selfHosted": True,
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'names no usable host' "$LOG" \
    && ok "--verify REFUSES a _selfHosted url that names no usable host ($_bad)" \
    || fail "--verify CERTIFIED a url naming no usable host ($_bad, rc=$rc) — LAYER VERIFIED over an entry the client cannot build a request from"
  run_install
  run_verify
  rc=$?
  [ "$rc" -eq 0 ] \
    && ok "...and install REPAIRS it into the hosted default, so verify converges ($_bad)" \
    || fail "install did not converge from a no-host _selfHosted entry ($_bad): verify still fails (rc=$rc) — a cell that can never come up"
done
# ⛔ THE REFUSE SIDE ALONE IS HALF A GATE, AND THE OTHER HALF IS THE ONE THAT BREAKS A BOX (#3374
# review, round 2 P3). A predicate that over-blocks does not fail safe — `merge-mcp.py` REPLACES
# what it cannot certify, so refusing a spelling that WORKS silently destroys an operator's config
# and repoints them at an endpoint they have no key for. Every shape below is one `new URL(u)`
# ACCEPTS (measured), so it must stay certified AND preserved:
#   bare `host:` (URL reads no port) · trailing root dot · underscore · IDN (punycoded by URL) ·
#   an already-punycoded host · `[v6]:port` · loopback over plain http · a non-default port.
# ⛔ AND THE UPPERCASE AND DECOMPOSED SPELLINGS OF THE SAME IDN (#3374 review, round 15 P2). Byte
# equality against the UTS46 mapping refused both: `MÜNCHEN` maps to `münchen` and the decomposed
# `mu\u0308nchen` composes to it, so neither is a fixed point — and their `--install` REPLACED the
# operator's own daemon with the hosted default (measured), while the ASCII fast path accepted the
# identical case change on `MYHOST.example`. They are the SAME HOST under DNS identity, so they belong
# here; the arm is what makes "the rule is identity, not bytes" a red-able claim.
# ⛔ AND THIS IS ALSO WHAT MAKES THE `idna` VERSION A TESTED FACT RATHER THAN AN ASSUMPTION (#3374
# review, round 15 P2). Every other arm that depends on the UTS46 mapping could pass on a box with no
# `idna` — the stdlib-only branch declines non-ASCII, so a refused spoof looks the same whether the
# mapping rule ran or not. `münchen` must CERTIFY, and only the real mapping can certify it, so a
# runner without `idna` REDS here instead of silently testing a rule it never executed.
# ⛔ AND THE UTS46 **`mapped`** CLASS — a compatibility DECOMPOSITION, which is the same character and
# therefore the SAME HOST (#3572 review P1, ANSWERED here rather than obeyed). `a\ufb00b` is mapped by
# UTS46 to `affb`, so neither side of the identity comparison is a fixed point — exactly like `MÜNCHEN`
# — and the host the client dials IS the host this name denotes, because the mapping is a Unicode
# compatibility decomposition (~NFKD) and not a substitution. So it belongs on the CERTIFY side.
# ⛔ THIS ARM IS THE MUTANT-PIN FOR `casefold` vs `lower`, and the reason not to "tighten" it: the
# suggested fix of comparing case-ONLY (`lower`) REFUSES this spelling, i.e. re-introduces the false
# block on a legitimate IDN that the rule exists to remove — measured on this box, `_label_ok('a\ufb00b')`
# is True under `casefold` and False under `lower`. Measured over all of Unicode: 0 of the UTS46
# DELETIONS are erased by `casefold`, and of the 1097 non-case renames it hides, 1096 satisfy
# `NFKD(ch) == uts46_remap(ch)` while the 1 exception (U+0345 COMBINING GREEK YPOGEGRAMMENI)
# satisfies `casefold(ch) == uts46_remap(ch)` — every hidden rename is another spelling of the SAME
# character, never a substitution. So the deleting class still cannot hide, and this spelling must stay.
for _good in 'https://localhost:8000/mcp' 'http://localhost:8000/mcp' \
             'https://127.0.0.1:8000/mcp' 'http://[::1]:8000/mcp' \
             'https://myhost.example./mcp/' 'https://my_host:8000/mcp' \
             'https://host:/mcp/' 'https://münchen.example/mcp/' \
             'https://MÜNCHEN.example/mcp/' "https://mu$(printf '\u0308')nchen.example/mcp/" \
             "https://a$(printf '\ufb00')b.example/mcp/" \
             'https://xn--mnchen-3ya.example/mcp/' 'https://api.premiselabs.co:8443/mcp/'; do
  python3 - "$DEST/.mcp.json" "$_good" <<'PY'
import json, sys
p, u = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "url": u, "_selfHosted": True,
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
  run_install
  run_verify
  rc=$?
  [ "$rc" -eq 0 ] && grep -qF "SELFHOSTED:$_good" "$LOG" \
    && ok "a usable self-host is PRESERVED and certified — no over-block ($_good)" \
    || fail "a self-host the CLIENT accepts ($_good) was refused or replaced (rc=$rc) — a false block on a working config, and for a self-host the repair destroys it"
done
# ⛔ DOT-EQUIVALENT **AND** DELETING-MAPPING SPOOFS ARE REFUSED BY NAME (#3374 review, round 13 P1,
# widened in round 15 P1). `new URL` applies UTS46, which maps U+3002/U+FF0E/U+FF61/U+FE52/U+2024 to
# `.`, and which DELETES a set of code points outright — so each of these resolves in the CLIENT to a
# DIFFERENT host (`api.premiselabs.co。evil.example` -> `api.premiselabs.co.evil.example`,
# `api.premiselabs.co<filler>.evil.example` -> `api.premiselabs.co.evil.example`) while the predicate
# read one harmless label, printed `SELFHOSTED:` rc=0 and left `Bearer ${TORTOISE_MCP_API_KEY}`
# attached: the tenant key blessed to an attacker's host. The `_good` loop above is the other half:
# `münchen.example` must STAY certified, so the fix cannot be "refuse all non-ASCII".
# ⛔ THE TWO CLASSES ARE NAMED SEPARATELY ON PURPOSE. `\u00ad` (Cf) and `\u200b` (Cf) and the HANGUL
# FILLERS are refused because UTS46 DELETES them; only `\u3002`/`\uff0e`/`\uff61`/`\ufe52`/`\u2024`
# are dot-equivalents. They arrive by the same ordinary-category mechanism, which is why the same
# loop drives them — but a red on a filler must not send anyone to `_DOT_EQUIVALENT`, which is not
# what refuses it.
for _spoof in "https://api.premiselabs.co$(printf '\u00ad')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\u200b')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\u3164')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\u115f')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\u1160')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\uffa0')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\u3002')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\uff0e')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\uff61')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\ufe52')evil.example/mcp/" \
              "https://api.premiselabs.co$(printf '\u2024')evil.example/mcp/"; do
  python3 - "$DEST/.mcp.json" "$_spoof" <<'PY'
import json, sys
p, u = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "url": u, "_selfHosted": True,
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'names no usable host' "$LOG" \
    && ok "a DOT-EQUIVALENT authority is REFUSED, never certified with the key attached ($_spoof)" \
    || fail "a dot-equivalent spoof was CERTIFIED (rc=$rc, $_spoof) — the client resolves it to a different host while the gate certifies it SELFHOSTED with the key still attached"
  run_install
  run_verify
  rc=$?
  [ "$rc" -eq 0 ] \
    && ok "...and install REPAIRS the dot-equivalent spoof into the hosted default, so verify converges ($_spoof)" \
    || fail "install did not converge from a dot-equivalent spoof entry ($_spoof): verify still fails (rc=$rc)"
done
# ⛔ AND THE TWO COPIES MUST AGREE — THE FILE SAYS SO TWICE AND NOTHING CHECKED IT (#3374 review,
# round 2 P3). `cell-install.sh`'s marker and `merge-mcp.py` both claim "the SAME predicate under the
# SAME name", and drift in EITHER direction is a severe defect this PR exists to close: install
# preserving what verify refuses is a cell that can never come up; install refusing what verify
# accepts silently replaces a working self-host. Driven over one table through BOTH implementations.
python3 - "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/pi-bootstrap/cell-install.sh" <<'PY' \
  && ok "the marker's authority_names_a_host and merge-mcp.py's agree on every shape (no drift)" \
  || fail "the two copies of authority_names_a_host DISAGREE — install and verify no longer judge the same url the same way"
import importlib.util, re, sys
table = ["https://api.premiselabs.co/mcp/", "http://localhost:8000/mcp", "https://127.0.0.1:8000/mcp",
         "http://[::1]:8000/mcp", "http://[::2]:8000/mcp", "https://api.premiselabs.co./mcp/",
         "https://my_host:8000/mcp", "https://host:/mcp/", "https://münchen.example/mcp/",
         "https://xn--mnchen-3ya.example/mcp/", "https://:8443/mcp/", "https://my daemon:8000/mcp",
         "https://./mcp/", "https://-/mcp/", "https://api.premiselabs.co:8443x/mcp/",
         "https://api.premiselabs.co%40evil.example/mcp/", "https://host:65536/mcp/",
         "https://host:-1/mcp/", "https://a..b/mcp/", "https://api.premiselabs.co|evil.example/mcp/",
         "https://a^b.example/mcp/", "https://a<b.example/mcp/", "https://١.example/mcp/",
         "https://api.premiselabs.co\u00adevil.example/mcp/",
         "https://api.premiselabs.co\u200bevil.example/mcp/",
         "https://api.premiselabs.co\u3002evil.example/mcp/",
         "https://api.premiselabs.co\uff0eevil.example/mcp/",
         "https://api.premiselabs.co\uff61evil.example/mcp/",
         "https://api.premiselabs.co\ufe52evil.example/mcp/",
         "https://api.premiselabs.co\u2024evil.example/mcp/",
         "https://api.premiselabs.co:8443/mcp/"]
spec = importlib.util.spec_from_file_location("mm", sys.argv[1])
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
# the marker's copy, exec'd from the heredoc it really runs from (not a paraphrase)
src = open(sys.argv[2]).read()
start = src.index("def _port_ok(")
end = src.index("    return all(_label_ok(lab) for lab in labels)") + len("    return all(_label_ok(lab) for lab in labels)")
ns = {"re": re, "ipaddress": __import__("ipaddress"), "unicodedata": __import__("unicodedata")}
try:
    import idna as _pkg
    ns["idna"] = _pkg
except ImportError:
    pass
exec(compile(src[start:end], "<marker>", "exec"), ns)
marker_p = ns["authority_names_a_host"]
for u in table:
    m = re.match(r"^[a-z][a-z0-9+.\-]*://([^/?#]*)", u, re.I)
    auth = m.group(1) if m else ""
    if mm.authority_names_a_host(auth) != marker_p(auth):
        print("DRIFT on %r: merge-mcp.py=%r marker=%r" % (
            u, mm.authority_names_a_host(auth), marker_p(auth)), file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
# ⛔ AND THE GUARD MUST HOLD ON A BOX WITH NO `idna` — the branch that DECLINES every non-ASCII
# label (#3374 review, rounds 14-15). Two successive category-deny-list attempts were wrong in BOTH
# directions, and the second was still a false PASS: U+115F/U+1160/U+3164/U+FFA0 (HANGUL FILLERS) are
# category `Lo` and are UTS46-ignored, i.e. DELETED — so a `Cf`/`Mn`/`Me` list CERTIFIED
# `api.premiselabs.co\u3164.evil.example` with the key attached — while 1737 of the 2027 Cf/Mn/Me code
# points are NOT deleted, so that same list false-BLOCKED real combining-mark IDNs. The branch now
# declines instead of enumerating, and this arm pins BOTH halves of that decision so neither
# "certify any non-ASCII" nor "certify the Cf/Mn/Me-free ones" can come back green.
NOIDNA_CHECK="$TMP/noidna_check.py"
cat > "$NOIDNA_CHECK" <<'NOIDNA'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mm", sys.argv[1])
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
mm._idna = None                      # simulate the stdlib-only box after the module loaded
bad = 0
# (i) the spoofs a category deny-list MISSES — the HANGUL FILLERS are `Lo`, so only a branch that
# declines the whole non-ASCII class can refuse them.
for host in ("api.premiselabs.co\u115f.evil.example", "api.premiselabs.co\u1160.evil.example",
             "api.premiselabs.co\u3164.evil.example", "api.premiselabs.co\uffa0.evil.example",
             "api.premiselabs.co\u00ad.evil.example", "api.premiselabs.co\u200b.evil.example",
             "api.premiselabs.co\u3002.evil.example", "api.premiselabs.co\uff0eevil.example",
             "api.premiselabs.co\u2024evil.example"):
    if mm.authority_names_a_host(host) is not False:
        print("CERTIFIED with idna absent: %r" % host, file=sys.stderr)
        bad += 1
# (ii) a legitimate non-ASCII self-host is DECLINED here TOO — deliberately: the branch does not
# guess the client's mapping, it declines (the merge then repairs the entry to the hosted default).
# Pinned in BOTH directions: a mutant that accepts every non-ASCII label reds here, and so does one
# that accepts only the Cf/Mn/Me-free labels.
for host in ("münchen.example", "mu\u0308nchen.example"):
    if mm.authority_names_a_host(host) is not False:
        print("not DECLINED with idna absent: %r" % host, file=sys.stderr)
        bad += 1
# (iii) and nothing ASCII is touched by the branch — no over-block on the common config.
for host in ("api.premiselabs.co", "localhost", "127.0.0.1", "my_host", "my-daemon.internal",
             "xn--mnchen-3ya.example"):
    if mm.authority_names_a_host(host) is not True:
        print("FALSE BLOCK with idna absent: %r" % host, file=sys.stderr)
        bad += 1
sys.exit(1 if bad else 0)
NOIDNA
python3 "$NOIDNA_CHECK" "$ROOT/pi-bootstrap/lib/merge-mcp.py" \
  && ok "with no idna the HANGUL-FILLER and DELETING spoofs are DECLINED, and no ASCII host is over-blocked" \
  || fail "with idna absent a spoof was CERTIFIED (or an ASCII host was blocked) — the stdlib-only branch must decline the class, not enumerate it"
# ⛔ THE SAME ARM, DRIVEN OVER **BOTH** COPIES (round 15 P2). `--verify` is certified by the marker
# inside `cell-install.sh`, and the drift arm below cannot cover it here because with `idna`
# importable NEITHER copy takes the fallback — so emptying the marker's guard left every arm GREEN.
# The marker's own heredoc is exec'd here (not a paraphrase), with its `import idna` forced to fail.
NOIDNA="$TMP/noidna_marker.py"
cat > "$NOIDNA" <<'NOIDNA'
import importlib.util, re, sys
src = open(sys.argv[2]).read()
start = src.index("def _port_ok(")   # NOT `_dns_identity`: the slice must carry `_HOST_FORBIDDEN`
end = src.index("    return all(_label_ok(lab) for lab in labels)") + len("    return all(_label_ok(lab) for lab in labels)")
slice_ = src[start:end]
assert "import idna as _idna" in slice_, "the marker no longer imports idna here — update this arm"
ns = {"re": re, "ipaddress": __import__("ipaddress"), "unicodedata": __import__("unicodedata")}
exec(compile(slice_.replace("import idna as _idna", "raise ImportError"), "<marker-noidna>", "exec"), ns)
assert ns["_idna"] is None, "the forced-ImportError arm did not land on the stdlib-only branch"
# the marker's copy must decline the same class the module's copy declines
spec = importlib.util.spec_from_file_location("mm", sys.argv[1])
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
mm._idna = None
bad = 0
for host in ("api.premiselabs.co\u115f.evil.example", "api.premiselabs.co\u3164.evil.example",
             "api.premiselabs.co\u00ad.evil.example", "api.premiselabs.co\u200b.evil.example",
             "api.premiselabs.co\u3002.evil.example", "api.premiselabs.co\uff0eevil.example",
             "münchen.example", "localhost", "api.premiselabs.co", "my_host"):
    a, b = ns["authority_names_a_host"](host), mm.authority_names_a_host(host)
    if a is not b:
        print("DRIFT with idna absent on %r: marker=%r merge-mcp.py=%r" % (host, a, b), file=sys.stderr)
        bad += 1
    if a is not (host in ("localhost", "api.premiselabs.co", "my_host")):
        print("WRONG VERDICT with idna absent on %r: %r" % (host, a), file=sys.stderr)
        bad += 1
sys.exit(1 if bad else 0)
NOIDNA
python3 "$NOIDNA" "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/pi-bootstrap/cell-install.sh" \
  && ok "the MARKER's copy agrees with merge-mcp.py on the no-idna branch — the box --verify actually runs" \
  || fail "the marker's stdlib-only branch DISAGREES with merge-mcp.py — install and verify judge the same url differently on a box with no idna, and the marker is the one that certifies a cell"
# ⛔ THE TEMPLATE READ WAS THE ONE REMAINING RAW TRACEBACK ON THE **VERIFY** SIDE (#3374 review P3).
# `merge-mcp.py` got a named FATAL for a template that is missing, unparseable, or the wrong SHAPE;
# the marker kept `json.load(open(...))` then `tpl.get(...)`, so all of them raised straight out and
# left stdout EMPTY — `verify_graph_mcp` then printed `verify failed (marker: none)` above Python
# internals instead of naming the cause, the exact "marker: none beside a traceback" shape this
# file's own BADDERS/URLTYPE arms exist to prevent. It fails closed, but a checker that cannot say
# WHY is the instrument defect, not the audit. Reachable: `is_infra_checkout` does not require
# `templates/.mcp.base.json` to exist.
MARKER_FN="$TMP/graph_mcp_marker.sh"
sed -n '/^graph_mcp_marker()/,/^}/p' "$ROOT/pi-bootstrap/cell-install.sh" > "$MARKER_FN"
printf '[1,2]'        > "$TMP/tpl-list.json"
printf '{"mcpServers": 5}' > "$TMP/tpl-srv.json"
printf '{not json'    > "$TMP/tpl-corrupt.json"
for _tpl in "$TMP/tpl-corrupt.json" "$TMP/tpl-list.json" "$TMP/tpl-srv.json" "$TMP/tpl-absent.json"; do
  out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$DEST/.mcp.json" "$_tpl" 2>&1)"
  rc=$?
  [ "$rc" -eq 1 ] && case "$out" in BADTPL:*) true ;; *) false ;; esac \
    && ! grep -q 'Traceback' <<<"$out" \
    && ok "the verifier names an unusable TEMPLATE (BADTPL:) instead of raising — $(basename "$_tpl")" \
    || fail "an unusable template ($(basename "$_tpl")) produced rc=$rc / '${out:0:60}' instead of a named BADTPL refusal (a traceback in the marker leaves the operator with 'marker: none' and no cause)"
done
# ⛔ A TEMPLATE WHOSE `tortoise.url` IS NOT A STRING WAS A TRACEBACK ON ONE SIDE AND A **WRONG
# SENTENCE** ON THE OTHER (#3374 review, round 2 P3). The merge's guard checked only that `url` was
# TRUTHY, so `"url": 123` died at `(want.get("url") or "").strip()` — AttributeError, rc=1, file
# unchanged, i.e. the repair path could not repair it. The verifier had the mirror: `want_url` became
# an int, so `url != want_url` fired and `--verify` printed `URL_NOT_DEFAULT:` against the cell's
# CORRECT hosted entry — a refusal sentence asserting the right config is wrong. Both name it now.
printf '{"mcpServers":{"tortoise":{"url":123,"headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}}}' > "$TMP/tpl-inturl.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/tpl-inturl.json" "$DEST/.mcp.json" --cell > "$TMP/inturl.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'declares a tortoise url of type int' "$TMP/inturl.out" && ! grep -q 'Traceback' "$TMP/inturl.out" \
  && ok "a template whose tortoise url is not a string is a named FATAL (exit 3), not a traceback" \
  || fail "a non-string template url produced rc=$rc / '$(head -1 "$TMP/inturl.out" | cut -c1-60)' — the repair path cannot run, which is the contract the template guard declares closed"
out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$DEST/.mcp.json" "$TMP/tpl-inturl.json" 2>&1)"
rc=$?
case "$out" in BADTPL:*) _named=1 ;; *) _named=0 ;; esac
[ "$rc" -eq 1 ] && [ "$_named" -eq 1 ] && ! grep -q 'URL_NOT_DEFAULT' <<<"$out" \
  && ok "...and --verify names the TEMPLATE instead of blaming the cell's correct hosted entry" \
  || fail "a non-string template url made --verify answer '$out' — it must name the template, never assert the cell's correct entry is not the hosted shape"
# ⛔ A TEMPLATE WITH NO `tortoise.url` CERTIFIED **ANY** URL, rc=0 (#3374 review, round 10 P1).
# The only arm that refuses a wrong endpoint is `if want_url and url != want_url` — so an EMPTY
# `want_url` (a template whose `tortoise` entry carries no `url`: the pre-#3374 stdio shape, a fork, a
# hand-edit) skipped URL_NOT_DEFAULT/BADURL/NOHOST/USERINFO entirely and fell through to the
# hosted-default `else`, which accepts any url whose Authorization is env-indirect. Measured before
# the fix: a one-letter-typo host and `https://evil.example/mcp/` both returned `OK:<url>:…` rc=0 with
# the tenant key attached — a false PASS of exactly the class this function exists to close, on the
# box this PR is about. `merge-mcp.py` already REFUSES the same template (exit 3), so the two sides
# DISAGREED about one file; both name it now, and `--verify` fails CLOSED: a template that cannot
# establish the hosted default certifies NOTHING.
printf '{"mcpServers":{"tortoise":{"type":"stdio","command":"python3","args":["-m","tortoise.mcp_server"]}}}' > "$TMP/tpl-nourl.json"
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "type": "http", "url": "https://api.premiselab.co/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$DEST/.mcp.json" "$TMP/tpl-nourl.json" 2>&1)"
rc=$?
case "$out" in BADTPL:no-url:*) _named=1 ;; *) _named=0 ;; esac
[ "$rc" -eq 1 ] && [ "$_named" -eq 1 ] && ! grep -q '^OK:' <<<"$out" && ! grep -q 'Traceback' <<<"$out" \
  && ok "a template declaring NO tortoise url certifies NOTHING (BADTPL:no-url:, rc=1) — it cannot pass a typo'd host through as OK" \
  || fail "a url-less template produced rc=$rc / '${out:0:70}' — an empty template url NULLIFIES the comparison arm, so every url (including https://evil.example/mcp/) is certified OK with the tenant key attached"
# ...and the CONTROL, so the arm above cannot pass for the wrong reason: the SAME typo'd host IS
# refused when the template does declare a url. Without this, 'BADTPL for any template at all' would
# satisfy the assertion above while the comparison arm stayed dead.
out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" 2>&1)"
rc=$?
case "$out" in URL_NOT_DEFAULT:*) _ref=1 ;; *) _ref=0 ;; esac
[ "$rc" -eq 1 ] && [ "$_ref" -eq 1 ] \
  && ok "...and the same typo'd host IS refused against the real template (URL_NOT_DEFAULT) — the comparison arm is alive" \
  || fail "the typo'd host was not refused against the shipped template (rc=$rc, '${out:0:70}') — the no-url arm above would then be passing vacuously"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/tpl-nourl.json" "$DEST/.mcp.json" --cell > "$TMP/nourl.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'declares no usable tortoise entry' "$TMP/nourl.out" \
  && ok "...and the MERGE refuses the same url-less template (exit 3) — install and verify agree about one file" \
  || fail "the merge answered rc=$rc for the url-less template ('$(head -1 "$TMP/nourl.out" | cut -c1-60)') while --verify answered BADTPL:no-url — the two sides disagree about the same template"
# ⛔ THE TEMPLATE WAS THE ONE ENTRY THIS FILE INSTALLED **WITHOUT EVER RUNNING `usable()` ON IT**
# (#3374 review, round 10 P1). `usable()` is total over every entry the merge REPLACES or PRESERVES,
# but the template's own `want` went straight into `.mcp.json` on every branch — so a template no lane
# could use was installed VERBATIM into a SHARED config file, and `--verify` then REFUSED the file the
# installer had just written. That makes the repair loop (`cloud-cell-bringup.sh`: verify → install →
# verify) non-convergent BY CONSTRUCTION: the next `--install` reads the literal, replaces it with
# `want`, and writes the same literal back. Measured pre-fix, rc=0 both times: a template carrying
# `Bearer <a literal token>` landed in `.mcp.json` verbatim (R2 of this change's own contract), and a
# template carrying `http://api.premiselabs.co/mcp/` was installed as the hosted default.
# Each arm below ALSO asserts the destination was never created: refusing to write is the contract, and
# a refusal that still wrote would satisfy a message-only assertion.
_mk_tpl() {   # _mk_tpl <out> <python-expr over `t` (the tortoise entry)> — fixture from the SHIPPED base
  python3 - "$ROOT/templates/.mcp.base.json" "$1" "$2" <<'PY'
import json, sys
base, out, expr = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(base))
t = d["mcpServers"]["tortoise"]
exec(expr)
d["mcpServers"]["tortoise"] = t
json.dump(d, open(out, "w"), indent=2)
PY
}
_mk_tpl "$TMP/tpl-literal.json" "t[\"headers\"][\"Authorization\"] = \"Bearer $LEAKKEY\""
_mk_tpl "$TMP/tpl-http.json"    't["url"] = "http://api.premiselabs.co/mcp/"'
_mk_tpl "$TMP/tpl-nokey.json"   't.pop("headers", None)'
for _case in literal:literal@headers.Authorization http:insecure nokey:nokey; do
  _name="${_case%%:*}"; _why="${_case#*:}"
  _dst="$TMP/tpl-${_name}-dest.json"; rm -f "$_dst"
  python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/tpl-${_name}.json" "$_dst" --cell > "$TMP/tpl-${_name}.out" 2>&1
  rc=$?
  [ "$rc" -eq 3 ] && grep -qF "UNUSABLE tortoise entry (${_why})" "$TMP/tpl-${_name}.out" \
    && [ ! -e "$_dst" ] && ! grep -q 'Traceback' "$TMP/tpl-${_name}.out" \
    && ok "a template declaring an UNUSABLE tortoise entry is refused by name (${_why}, exit 3) and NOTHING is written" \
    || fail "the merge answered rc=$rc for a template whose tortoise entry is unusable (${_why}) and left \$([ -e "$_dst" ] && echo a destination || echo no destination) — a template is what this file INSTALLS, so installing one --verify refuses is a repair loop that can never converge"
done
# ...and the CONTROL, so the three arms above cannot pass by refusing EVERY template: the SHIPPED
# template still installs. Without it, an over-eager `usable()` call on `want` (the false-block
# direction, which would stop every fresh box from getting a graph at all) satisfies all three.
rm -f "$TMP/tpl-real-dest.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/tpl-real-dest.json" --cell > "$TMP/tpl-real.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$TMP/tpl-real-dest.json" ] \
  && ok "...and the SHIPPED template still installs (rc=0) — the new guard refuses unusable templates, not all of them" \
  || fail "the shipped template was refused (rc=$rc, '$(head -1 "$TMP/tpl-real.out" | cut -c1-70)') — validating the template must not block the one template every box installs"
# ⛔ AND THE OTHER FALSE-BLOCK DIRECTION, WHICH THE SHIPPED-TEMPLATE CONTROL CANNOT SEE (#3374 review
# P1). The control above only proves the SHIPPED template installs, so a guard that refuses every
# SELF-HOST template satisfied it — and those are the templates the docs tell operators to write
# (`templates/.mcp.base.json`'s own `_comment`, `pi-bootstrap/SETUP-NEW-MACHINE.md`,
# tortoise's `docs/quickstart-selfhosted.md`: "a local daemon needs none"). Measured at 3db7779f4:
# `{"type":"http","url":"http://localhost:8000/mcp"}` exited `FATAL … (nokey)` rc=3, and because
# setup.sh's merge call was bare under `set -e` the WHOLE layer was skipped (no extensions, no skills,
# no farm). At `origin/main` the same template installed rc=0. Each arm below therefore asserts BOTH
# halves of the answer — the merge INSTALLS the operator's own endpoint, and `--verify` CERTIFIES the
# file it wrote (convergence, not just a non-refusal).
_MARKER_FN2="$TMP/graph_mcp_marker_p1.sh"
sed -n '/^graph_mcp_marker()/,/^}/p' "$ROOT/pi-bootstrap/cell-install.sh" > "$_MARKER_FN2"
for _case in loopback:'{"type": "http", "url": "http://localhost:8000/mcp"}' \
             loopback-sse:'{"type": "sse", "url": "http://localhost:8000/mcp"}' \
             loopback-ipv6:'{"type": "http", "url": "http://[0:0:0:0:0:0:0:1]:8000/mcp"}'; do
  _name="${_case%%:*}"; _entry="${_case#*:}"
  _tpl="$TMP/selfhost-${_name}.json"; _dst="$TMP/selfhost-${_name}-dest.json"; rm -f "$_dst"
  python3 - "$ROOT/templates/.mcp.base.json" "$_tpl" "$_entry" <<'PY'
import json, sys
base, out, entry = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(base))
d["mcpServers"]["tortoise"] = json.loads(entry)
json.dump(d, open(out, "w"), indent=2)
PY
  python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$_tpl" "$_dst" --cell > "$TMP/selfhost-${_name}.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "a SELF-HOST template (${_name}) was refused (rc=$rc, '$(head -1 "$TMP/selfhost-${_name}.out" | cut -c1-80)') — the docs tell operators to point url at their own daemon; refusing it leaves the box with no graph AND, because setup.sh aborts on this, no layer either"
    continue
  fi
  _mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_dst" "$_tpl" 2>&1)"; _mrc=$?
  # The operator's own endpoint is certified BY NAME, never as the hosted default (which would demand
  # a credential it does not need), and the installed entry is the one the operator wrote.
  if [ "$_mrc" -eq 0 ] && grep -qF 'SELFHOSTED:' <<<"$_mk" \
     && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["mcpServers"]["tortoise"]["url"]==json.load(open(sys.argv[2]))["mcpServers"]["tortoise"]["url"] else 1)' "$_dst" "$_tpl"; then
    ok "a SELF-HOST template (${_name}) INSTALLS and the file it wrote is CERTIFIED SELFHOSTED — the repair path converges, and the hosted credential is not demanded of a daemon that needs none"
  else
    fail "a self-host template installed but \`--verify\` answered '${_mk}' (rc=$_mrc) — install wrote a file verify refuses, so verify → install → verify can never converge"
  fi
done
# ⛔ THE SELF-HOST EXEMPTION USED TO REACH THE HOSTED ENDPOINT ITSELF, AND THAT IS A FALSE PASS
# (#3374 review, round 12 P2). Both paths into `_selfhosted_shape` ask about the TEMPLATE and the
# marker; neither asked whether the url IS the hosted endpoint. So with a self-host TEMPLATE, a
# `_selfHosted`-marked entry AT the hosted url — a marker `merge-mcp.py` minted itself, see the arm
# below — was certified `SELFHOSTED:` rc=0 without ever reading its credential. Measured pre-fix:
# `SELFHOSTED:https://api.premiselabs.co/mcp/` rc=0 over `Bearer ${SOME_OTHER_VAR}` (an EMPTY Bearer),
# while the SAME file against the shipped template is refused `WRONG_AUTH`. The endpoint decides, not
# the marker and not the template — so the marker must not exonerate it.
_sha_marked="$TMP/selfhost-marked-hosted.json"
python3 - "$ROOT/templates/.mcp.base.json" "$_sha_marked" 'Bearer ${SOME_OTHER_VAR}' <<'PY'
import json, sys
base, out, auth = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(base))
t = d["mcpServers"]["tortoise"]
t["headers"] = {"Authorization": auth}
t["_selfHosted"] = True          # the marker the merge used to mint, and the verifier used to honour
d["mcpServers"]["tortoise"] = t
json.dump(d, open(out, "w"), indent=2)
PY
_mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_sha_marked" "$SELFTPL/templates/.mcp.base.json" 2>&1)"; _mrc=$?
[ "$_mrc" -eq 1 ] && grep -qF 'WRONG_AUTH:' <<<"$_mk" \
  && ok "a _selfHosted-marked entry AT THE HOSTED URL still needs the hosted credential — the exemption does not exonerate the endpoint that requires it" \
  || fail "--verify certified the HOSTED endpoint as a SELF-HOST (rc=$_mrc, '${_mk}') — a marker or a self-host template can exempt the hosted url from its own credential check, so an empty Bearer is certified LAYER VERIFIED"
# …and the FALSE-BLOCK direction: the same marked shape WITH the hosted credential is certified, so
# the fix is "the hosted endpoint is judged as the hosted endpoint", not "a marked entry is refused".
python3 - "$_sha_marked" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"]["headers"] = {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"}
json.dump(d, open(p, "w"), indent=2)
PY
_mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_sha_marked" "$SELFTPL/templates/.mcp.base.json" 2>&1)"; _mrc=$?
[ "$_mrc" -eq 0 ] && grep -qF 'OK:https://api.premiselabs.co/mcp/:${TORTOISE_MCP_API_KEY}' <<<"$_mk" \
  && ok "…and WITH the hosted credential the same marked entry is certified normally (the rule is not 'refuse anything marked')" \
  || fail "--verify refused a marked entry that carries the hosted endpoint AND the hosted credential (rc=$_mrc, '${_mk}') — that is a false block on a config that works"
# ⛔ THE PRODUCER OF THAT MARKER, ON THE REAL MERGE PATH (#3374 review, round 12 P2). With a SELF-HOST
# template, the merge's `elif ok_entry` branch marked ANY url differing from the template — including
# the HOSTED one, printing "kept this machine's own tortoise url (https://api.premiselabs.co/mcp/)".
# Measured pre-fix: `_selfHosted: true` written onto the hosted url, and `--verify` then took the
# exemption. The hosted endpoint is never "this machine's own", so it is never marked — and the pair
# must CONVERGE: the file the merge writes is one `--verify` certifies.
_shm_dst="$TMP/selfhost-marked-merge.json"; rm -f "$_shm_dst"
python3 - "$ROOT/templates/.mcp.base.json" "$_shm_dst" <<'PY'
import json, sys
base, out = sys.argv[1], sys.argv[2]
d = json.load(open(base))
d["mcpServers"]["tortoise"] = {
    "type": "http",
    "url": "https://api.premiselabs.co/mcp/",
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(out, "w"), indent=2)
PY
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$SELFTPL/templates/.mcp.base.json" "$_shm_dst" --cell > "$TMP/selfhost-marked-merge.out" 2>&1
rc=$?
python3 - "$_shm_dst" <<'PY' && ok "…so a self-host template does NOT mark this cell's HOSTED entry _selfHosted, and the sentence no longer calls the hosted url 'this machine's own'" \
  || fail "install marked the HOSTED url _selfHosted under a self-host template — that marker is what let --verify skip the hosted credential check, and the NOTE called the hosted endpoint 'this machine's own'"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" and not t.get("_selfHosted") else 1)
PY
_mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_shm_dst" "$SELFTPL/templates/.mcp.base.json" 2>&1)"; _mrc=$?
[ "$_mrc" -eq 0 ] && grep -qF 'OK:https://api.premiselabs.co/mcp/:${TORTOISE_MCP_API_KEY}' <<<"$_mk" \
  && ok "…and the file that merge just wrote is one --verify CERTIFIES (verify -> install -> verify converges, rather than repairing a certification into a refusal or back)" \
  || fail "the merge wrote a file --verify refuses (rc=$_mrc, '${_mk}') — a self-hosting checkout could never bring a hosted cell up"
# ⛔ THE NOTE ITSELF WAS ASSERTED NOWHERE (#3374 review, round 12 P3). The arm above captures the
# merge's output to `selfhost-marked-merge.out` and never reads it, so deleting the sentence — or
# reverting it to the "this machine's own tortoise url (https://api.premiselabs.co/mcp/)" wording this
# round removed — kept the suite green on a correct FILE. The file is not the whole artifact: the
# operator reads the log, and a sentence calling the hosted endpoint "this machine's own" is false.
[ "$rc" -eq 0 ] && grep -qF "kept this cell's HOSTED tortoise endpoint" "$TMP/selfhost-marked-merge.out" \
  && ! grep -q "machine's own tortoise url.*api[.]premiselabs[.]co" "$TMP/selfhost-marked-merge.out" \
  && ok "…and the NOTE the operator reads says the HOSTED entry was kept, and never calls the hosted url 'this machine's own' (rc=$rc)" \
  || fail "the merge's NOTE does not say the HOSTED entry was kept, or still calls the hosted url 'this machine's own' (rc=$rc) — the log is the artifact the operator reads, and a false sentence about it is the round-11 defect class"
# ⛔ "IS THIS THE HOSTED ENDPOINT?" WAS ASKED OF THE WHOLE KEY, SO EVERY PATH SPELLING ESCAPED THE
# HOSTED BRANCH (#3374 review, round 12 P1 — a FALSE PASS, and the most REACHABLE one in this file).
# `_endpoint_key` appends the path/query/fragment verbatim, so only the byte-exact `/mcp/` reached the
# hosted credential check. `node -e 'new URL(u).href'` normalises EVERY spelling below onto the
# canonical hosted url, which answers HTTP 401 to an unauthenticated POST — they are the live hosted
# endpoint, not self-hosts. Measured pre-fix, each one `SELFHOSTED:` rc=0 over `Bearer
# ${SOME_OTHER_VAR}` (an EMPTY Bearer). ⛔ THE REACHABLE-BY-ACCIDENT FORM NEEDED NO MARKER AT ALL: a
# TEMPLATE whose own url was the hosted host without the trailing slash installed `headers: null` and
# `--verify` CERTIFIED it, so install and verify CONVERGED on the false pass this change exists to
# close. The assertion is "refused, and never certified" rather than a named marker: which refusal is
# correct differs by spelling (`:0443` normalises to the canonical endpoint and is refused for its
# CREDENTIAL; a path spelling is refused for its spelling), and pinning one name would make the arm
# pass on the wrong one.
for _HSPELL in "https://api.premiselabs.co/mcp" "https://api.premiselabs.co/foo/../mcp/" \
               "https://api.premiselabs.co/mcp/?x=1" "https://api.premiselabs.co/mcp/#x" \
               "https://api.premiselabs.co:0443/mcp/"; do
  _hlabel="${_HSPELL#https://api.premiselabs.co}"
  python3 - "$ROOT/templates/.mcp.base.json" "$_sha_marked" "$_HSPELL" 'Bearer ${SOME_OTHER_VAR}' <<'PY'
import json, sys
base, out, url, auth = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(base))
t = d["mcpServers"]["tortoise"]
t["url"] = url
t["headers"] = {"Authorization": auth}
t["_selfHosted"] = True          # the marker the verifier used to honour over the hosted endpoint
d["mcpServers"]["tortoise"] = t
json.dump(d, open(out, "w"), indent=2)
PY
  _mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_sha_marked" "$SELFTPL/templates/.mcp.base.json" 2>&1)"; _mrc=$?
  [ "$_mrc" -ne 0 ] && ! grep -qE 'SELFHOSTED:|^OK:' <<<"$_mk" \
    && ok "a HOSTED endpoint spelled '$_hlabel' is NOT a self-host — refused (rc=$_mrc) over an EMPTY Bearer, never certified" \
    || fail "--verify CERTIFIED the HOSTED endpoint spelled '$_HSPELL' (rc=$_mrc, '${_mk}') — the client parses this spelling as the canonical hosted url, so an empty Bearer is certified LAYER VERIFIED"
done
# …and the FALSE-BLOCK control: the rule is "the hosted AUTHORITY needs the hosted credential", not
# "refuse anything that looks hosted". A genuine self-host — another host, or THIS host on a
# non-default port (the documented own-daemon shape) — stays exempt, or the fix would repoint every
# operator's own daemon, the silent-repoint defect this file's rule 3 forbids.
for _SELF in "https://192.168.1.9/mcp/" "https://api.premiselabs.co:8443/mcp/"; do
  python3 - "$ROOT/templates/.mcp.base.json" "$_sha_marked" "$_SELF" 'Bearer ${SOME_OTHER_VAR}' <<'PY'
import json, sys
base, out, url, auth = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(base))
t = d["mcpServers"]["tortoise"]
t["url"] = url
t["headers"] = {"Authorization": auth}
t["_selfHosted"] = True
d["mcpServers"]["tortoise"] = t
json.dump(d, open(out, "w"), indent=2)
PY
  _mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_sha_marked" "$SELFTPL/templates/.mcp.base.json" 2>&1)"; _mrc=$?
  [ "$_mrc" -eq 0 ] && grep -qF 'SELFHOSTED:' <<<"$_mk" \
    && ok "…while a GENUINE self-host ($_SELF) is still certified BY NAME with no credential — the exemption was narrowed to the hosted AUTHORITY, not disabled" \
    || fail "--verify refused a genuine self-host ($_SELF) that the operator marked (rc=$_mrc, '${_mk}') — the hosted-authority rule is eating endpoints it must not touch"
done
# ⛔ AND THE INSTALL DIRECTION HAD TO CONVERGE WITH IT (#3374 review, round 12 P1). A template whose
# OWN url is the hosted authority spelled some other way was installed VERBATIM, so the repair wrote
# the very bytes the verifier now refuses — `verify -> install -> verify` could never converge. The
# hosted endpoint is a fixed fact, so the merge writes the CANONICAL url whatever the template spelled.
for _TSPELL in "https://api.premiselabs.co/mcp" "https://api.premiselabs.co/foo/../mcp/" \
                "https://api.premiselabs.co/mcp/?x=1" "https://api.premiselabs.co/mcp/#x" \
                "https://api.premiselabs.co:0443/mcp/"; do
  _tlbl="${_TSPELL#https://api.premiselabs.co}"
  _tcell="$TMP/hosted-spell.tpl.json"
  python3 - "$_tcell" "$_TSPELL" <<'PY'
import json, sys
json.dump({"mcpServers": {"tortoise": {
    "type": "http", "url": sys.argv[2],
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"}}}}, open(sys.argv[1], "w"))
PY
  _tget="$TMP/hosted-spell.cell.json"; printf '{"mcpServers":{}}' > "$_tget"
  python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$_tcell" "$_tget" --cell >/dev/null 2>&1 || { fail "merge refused a template that is the HOSTED endpoint spelled '$_TSPELL' — a hosted spelling is not a bad template"; continue; }
  _mk="$(bash -c 'source "$1"; graph_mcp_marker "$2" "$3"' _ "$_MARKER_FN2" "$_tget" "$_tcell" 2>&1)"; _mrc=$?
  python3 - "$_tget" <<'PY' && [ "$_mrc" -eq 0 ] && grep -qF 'OK:https://api.premiselabs.co/mcp/:${TORTOISE_MCP_API_KEY}' <<<"$_mk" \
    && ok "…and a template spelled '$_tlbl' installs the CANONICAL url and --verify CERTIFIES it (verify -> install -> verify converges)" \
    || fail "a template spelled '$_TSPELL' produced a cell --verify refuses (rc=$_mrc, '${_mk}') — install writes what verify rejects, so the repair loop rewrites the same bytes forever"
import json, sys
t = (json.load(open(sys.argv[1])).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
sys.exit(0 if t.get("url") == "https://api.premiselabs.co/mcp/" else 1)
PY
done
# ⛔ THE HOSTED DEFAULT IS NOW A DEFINED FACT IN TWO LANGUAGES (and in THREE assignments), SO PIN
# EVERY ONE OF THEM TO THE ARTIFACT IT NAMES. `HOSTED_DEFAULT_URL` in merge-mcp.py and in
# cell-install.sh's verifier, plus `GRAPH_HOSTED_DEFAULT_URL` in cell-install.sh's BASH, must all equal
# the endpoint the SHIPPED template declares — otherwise the constant silently diverges from the
# template every box installs, and "is this the hosted endpoint?" starts answering about an endpoint
# nobody uses. ⛔ EVERY ASSIGNMENT IS CHECKED, not just the first per file (round 12): a file with two
# spellings is exactly how the bash one would have drifted unseen, and the count per file is asserted
# so a rename cannot turn this arm into a check of zero things.
_pin_out="$(python3 - "$ROOT" <<'PY'
import json, re, sys
root = sys.argv[1]
tpl = json.load(open(root + "/templates/.mcp.base.json"))["mcpServers"]["tortoise"]["url"]
bad = []
seen = {}
for rel in ("pi-bootstrap/lib/merge-mcp.py", "pi-bootstrap/cell-install.sh"):
    src = open(root + "/" + rel).read()
    hits = re.findall(r'^\s*(?:GRAPH_)?HOSTED_DEFAULT_URL\s*=\s*"([^"]+)"', src, re.M)
    seen[rel] = len(hits)
    if not hits:
        bad.append(rel + ": no HOSTED_DEFAULT_URL")
    bad += ["%s: %r != template %r" % (rel, h, tpl) for h in hits if h != tpl]
if seen.get("pi-bootstrap/cell-install.sh") != 2:
    bad.append("cell-install.sh: expected 2 assignments (verifier python + bash), found %s"
               % seen.get("pi-bootstrap/cell-install.sh"))
print("; ".join(bad))
PY
)"
[ -z "$_pin_out" ] \
  && ok "HOSTED_DEFAULT_URL is the SHIPPED template's endpoint in EVERY assignment (merge-mcp.py, and both the verifier's python and the bash in cell-install.sh) — 'the hosted default' cannot drift away from the endpoint every box installs" \
  || fail "HOSTED_DEFAULT_URL has drifted from templates/.mcp.base.json: $_pin_out — the constant that decides whether an entry needs the hosted credential no longer names the hosted endpoint"
# ⛔ THE DESTINATION READ WAS THE LAST BARE `open()` IN THIS FILE (#3374 review, round 10 P2).
# `except ValueError` caught the JSONDecodeError and let every OSError through, so an unreadable
# `.mcp.json` escaped as a TRACEBACK with the undocumented rc=1 while the docstring advertises 0/2/3 —
# and `--verify` names exactly this shape (`UNREADABLE:`). Measured pre-fix:
# `mkdir dst.json; merge-mcp.py tpl dst.json --cell` → IsADirectoryError traceback, rc=1. It is
# reachable from the repair loop, which then dies on Python internals for a file the verifier had just
# named correctly. A directory is the fixture because it raises in EVERY environment.
mkdir -p "$TMP/unreadable-dest.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/unreadable-dest.json" --cell > "$TMP/unreadable-dest.out" 2>&1
rc=$?
[ "$rc" -eq 3 ] && grep -qF 'is not a readable config file' "$TMP/unreadable-dest.out" && ! grep -q 'Traceback' "$TMP/unreadable-dest.out" \
  && ok "an unreadable DESTINATION is a named FATAL (exit 3), not a traceback with the undocumented rc=1" \
  || fail "an unreadable destination produced rc=$rc / '$(head -1 "$TMP/unreadable-dest.out" | cut -c1-70)' — the documented contract is 0/2/3, and the repair path must not die on Python internals"
# ...and the CONTROL, so the arm above cannot pass by refusing a destination that is merely ABSENT.
# `os.path.exists` guards the read, so a missing dest must take the fresh-install path; if the OSError
# branch ever swallowed it, every first install on every box would stop — the false-block direction.
# ⛔ A DANGLING SYMLINK IS *NOT* THIS BRANCH'S SHAPE, AND THE CODE COMMENT CLAIMED IT WAS. `os.path.exists`
# follows the link, so it is FALSE for a dangling one, the read is SKIPPED, and the write goes THROUGH the
# link and creates the target. Measured, and pinned here as data so the comment cannot drift back: the
# repair loop converges either way, but it converges by creating the link's target, not by refusing.
rm -f "$TMP/absent-dest.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/absent-dest.json" --cell > "$TMP/absent-dest.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$TMP/absent-dest.json" ] \
  && ok "...and an ABSENT destination is still a fresh install (rc=0) — the unreadable guard does not catch a first run" \
  || fail "an absent destination produced rc=$rc — the unreadable-destination branch is swallowing the fresh-install path, which would stop the very first install on every box"
rm -f "$TMP/dangling-target.json" "$TMP/dangling-dest.json"
ln -s "$TMP/dangling-target.json" "$TMP/dangling-dest.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/dangling-dest.json" --cell > "$TMP/dangling.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$TMP/dangling-target.json" ] && [ -L "$TMP/dangling-dest.json" ] \
  && ok "a DANGLING-SYMLINK destination is written THROUGH the link (rc=0, target created) — measured, not the FATAL branch" \
  || fail "a dangling-symlink destination produced rc=$rc with \$([ -f "$TMP/dangling-target.json" ] && echo a target || echo NO target) — the OSError branch cannot see this shape (os.path.exists follows the link), so the code comment must not claim it"
# ⛔ THE WRITE WAS THE LAST PATH IN THIS FILE THAT WAS NOT A NAMED REFUSAL (#3374 review P3). Every READ
# shape above is named; an unwritable destination DIRECTORY raised straight out of `main` —
# `PermissionError … dst.json.tmp.<pid>`, rc=1, Python internals — against a docstring advertising
# 0/2/3, and it did so AFTER a `NOTE:` line had printed, so the log read as a partly-successful merge.
# A mode-0500 directory is the fixture: the file may be writable while its directory is not, which is
# exactly the shape the temp-file write hits. `chmod` is restored below so the suite can clean up.
RODEST="$TMP/ro-dest"
mkdir -p "$RODEST" && chmod 500 "$RODEST"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$RODEST/dst.json" --cell > "$TMP/ro-dest.out" 2>&1
rc=$?
chmod 700 "$RODEST"
[ "$rc" -eq 3 ] && grep -qF 'cannot write' "$TMP/ro-dest.out" && grep -qF 'NOT written' "$TMP/ro-dest.out" && ! grep -q 'Traceback' "$TMP/ro-dest.out" \
  && ok "an UNWRITABLE destination directory is a named FATAL (exit 3) that states nothing was written — not a traceback with the undocumented rc=1" \
  || fail "an unwritable destination produced rc=$rc / '$(head -1 "$TMP/ro-dest.out" | cut -c1-70)' — the documented contract is 0/2/3 and the log must not read as a partly-successful merge"
# ...and an unreadable-by-PERMISSION REGULAR file is REPLACED, not refused, and the bytes it
# discards are BACKED UP. Two directions are asserted, because the first draft of this arm only
# asserted "a `.bak` exists" and thereby certified a WARNING: `_keep_backup` needs READ on the source,
# so for the one shape that reaches this fallback the copy FAILED and the content was LOST while the
# NOTE printed "the previous file was saved as (backup FAILED …)" — a sentence asserting a save that
# did not happen, against this file's own rule that operator content is never silently deleted
# (measured pre-fix: mode-0000 dest → rc=0, no `.bak`, content GONE). The second direction is the
# CONVERGENCE one: the replacement must be readable, or `--verify` refuses the file this installer
# just wrote and verify → install → verify never converges. Skipped as root, which reads a 0000 file
# regardless and would make both arms assert nothing.
# ⛔ ONE PORTABLE DEFINITION, USED BY EVERY ARM BELOW (#3374 review, round 11 P2). `stat -c` is
# GNU-only: on macOS it fails outright, the substitution is EMPTY, and the sentence this file prints
# then reads "is mode  and cannot be read/parsed" — a failure message with the fact missing. The two
# siblings already carried the BSD counterpart; the third — the `fail` branch, i.e. the one that only
# runs when something is ALREADY wrong — did not, and `scripts/check-portability-traps.sh` reported it
# as `stat-c-gnu: baseline=0 live=1`: a NEW trap in a baselined file, which the gate refuses (and it
# was red in the `bash-suites (8)` shard). The guarded chain is the detector's blessed idiom —
# `stat -c … || stat -f …` inside ONE command unit, which `gnu_only_unit()` reads as portable — and
# naming it ONCE is what stops the three call sites drifting apart again. The BSD field for mtime is
# `%m`, but these arms need SIZE (`%z`) and MODE (`%Lp`), which is why `box_mtime` is not the helper
# here: it answers a different question.
_stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
_stat_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null; }
if [ "$(id -u)" -ne 0 ]; then
  _orig='{"mcpServers":{"mine":{"command":"keep-me"}}}'
  printf '%s' "$_orig" > "$TMP/eperm-dest.json"
  chmod 000 "$TMP/eperm-dest.json"
  python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/eperm-dest.json" --cell > "$TMP/eperm.out" 2>&1
  rc=$?
  # stat works without READ permission; the byte count is what proves the copy happened.
  _want="$(printf '%s' "$_orig" | wc -c | tr -d ' ')"
  _got="$(_stat_size "$TMP/eperm-dest.json.bak" || echo 0)"
  [ "$rc" -eq 0 ] && grep -qF 'REPLACED an UNREADABLE .mcp.json' "$TMP/eperm.out" \
    && ! grep -qF 'backup FAILED' "$TMP/eperm.out" && [ "$_got" = "$_want" ] \
    && ok "an unreadable-by-PERMISSION regular file is REPLACED with its bytes KEPT in the backup (rc=0, ${_got}B)" \
    || fail "a permission-unreadable regular destination produced rc=$rc with a ${_got}B backup (wanted ${_want}B) — a file that may hold hand-written work must be replaced AND backed up, never refused or dropped"
  # the CONVERGENCE direction: the file the installer just wrote must be one the verifier can read.
  [ -r "$TMP/eperm-dest.json" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "tortoise" in d["mcpServers"] else 1)' "$TMP/eperm-dest.json" \
    && ok "...and the replacement is READABLE and parses (mode $(_stat_mode "$TMP/eperm-dest.json")) — the repair loop can converge" \
    || fail "the replacement written over an unreadable dest is mode $(_stat_mode "$TMP/eperm-dest.json") and cannot be read/parsed — --verify would refuse the file this installer just wrote, so verify -> install -> verify never converges (restoring the 0000 mode here is what causes it)"
else
  ok "an unreadable-by-PERMISSION destination is REPLACED and backed up (arm skipped: running as root, which reads a 0000 file)"
fi
# ⛔ AN UNREADABLE `.mcp.json` WAS THE LAST BARE `open()` ON THE VERIFY PATH (#3374 review P2): every
# sibling shape error (BADROOT/BADSERVERS/BADDERS/NOTJSON) is a NAMED refusal, but the read itself
# raised straight out, so stdout was EMPTY and `verify_graph_mcp` printed `FAIL … (marker: none)`
# over a traceback. A directory is used as the unreadable target because it raises in EVERY
# environment (an EACCES arm needs a non-root runner to mean anything).
mkdir -p "$TMP/unreadable-config.json"
out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$TMP/unreadable-config.json" "$ROOT/templates/.mcp.base.json" 2>&1)"
rc=$?
case "$out" in UNREADABLE:*) _named=1 ;; *) _named=0 ;; esac
[ "$rc" -eq 1 ] && [ "$_named" -eq 1 ] && ! grep -q 'Traceback' <<<"$out" \
  && ok "an UNREADABLE .mcp.json is a named refusal (UNREADABLE:, rc=1), not a traceback with an empty marker" \
  || fail "an unreadable .mcp.json produced rc=$rc / '${out:0:70}' — an empty stdout becomes 'marker: none' in the bring-up log, which names no cause and is the instrument defect this file's marker set exists to close"
# ...and the operator-facing sentence exists for it. The marker is only half the contract: a marker
# no `case` arm matches falls to the generic "could not be certified" and loses the remedy.
grep -q 'could not be READ at all' "$ROOT/pi-bootstrap/cell-install.sh" \
  && ok "...and verify_graph_mcp has an arm for it that carries the remedy (no generic 'could not be certified')" \
  || fail "UNREADABLE: has no case arm in verify_graph_mcp — the operator gets the generic sentence and no remedy"
# ⛔ A MARKER IS ECHOED INTO LOGS THAT GET PASTED INTO ISSUES (#3374 review, round 2 P3). `redact()`
# only matches `tt_`/`tk_` token shapes, so `INSECURE_URL:http://user:hunter2@evil.example/mcp/` put
# a PASSWORD in the bring-up log while correctly refusing the entry. Every url-echoing marker now
# goes through `shown_url()`, which replaces the userinfo wholesale. Fails closed already — this is
# a leak, not a false PASS, and a leak in a fleet-wide log is the one that outlives the run.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {
    "url": "http://user:hunter2-secret@evil.example/mcp/", "_selfHosted": True,
    "headers": {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"},
}
json.dump(d, open(p, "w"), indent=2)
PY
for _kind in marker verify; do
  if [ "$_kind" = marker ]; then
    out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" 2>&1)"
  else
    run_verify; out="$(cat "$LOG")"
  fi
  case "$out" in *hunter2-secret*) _leak=1 ;; *) _leak=0 ;; esac
  [ "$_leak" -eq 0 ] && ok "no credential reaches the log through $_kind (url userinfo is redacted)" \
    || fail "$_kind echoed a url USERINFO into the log verbatim — the password lands in any issue or PR that pastes it"
done
rm -f "$TMP/tpl-list.json" "$TMP/tpl-srv.json" "$TMP/tpl-corrupt.json" "$TMP/tpl-inturl.json" "$MARKER_FN"
# ⛔ A `headers` THAT IS NOT AN OBJECT IS REFUSED BY NAME **AND** REPAIRABLE BY INSTALL. `.get` on a
# str/list raised before the write on the install side and left an EMPTY marker on the verify side,
# so `--install` — the repair path — could not fix the entry either: the "config nothing can repair"
# class, one step earlier than the shape rule. Refused by name here; replaced on install.
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
t["headers"] = "Bearer ${TORTOISE_MCP_API_KEY}"    # a curl-style paste: a STRING, not an object
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'BADDERS:str' "$LOG" \
  && grep -qF 'declares its headers value as a str, not an object' "$LOG" \
  && ok "--verify refuses a tortoise entry whose headers is a STRING, BY NAME (BADDERS:str AND the named FAIL sentence — not an empty marker beside a traceback)" \
  || fail "--verify did not name a non-object headers in the FAIL sentence (rc=$rc) — an unescaped \${VAR} in that message aborts the verifier under strict-unset, so the operator gets 'marker: none' instead of the shape that is wrong"
run_install
run_verify
rc=$?
[ "$rc" -eq 0 ] \
  && ok "install REPAIRS a non-object headers into the hosted entry (the repair path can clear the refusal)" \
  || fail "install could not repair a non-object headers (verify rc=$rc) — the cell is stuck with a config nothing can fix"
# ⛔ A MERGE MUST NOT REWRITE LINES IT HAS NO OPINION ABOUT. `json.dump`'s default re-encodes every
# non-ASCII character as `\uXXXX`, so a cell-local entry carrying a literal em dash came back
# rewritten on every sync — byte churn that reads as a content change in every diff of a file this
# PR has no reason to touch.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("mcpServers", {})["cell-local"] = {"type": "http", "url": "http://127.0.0.1:9/mcp", "purpose": "a \u2014 b"}
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a merge leaves a literal non-ASCII character ALONE (ensure_ascii=False — no churn in a line it has no opinion about)" \
  || fail "a merge re-encoded a literal em dash as \\u2014 — byte churn in every consumer's diff on every sync"
import io, sys
raw = io.open(sys.argv[1], encoding="utf-8").read()
sys.exit(0 if ("a \u2014 b" in raw and "\\u2014" not in raw) else 1)
PY
# ⛔ A MERGE MUST NOT WIDEN WHAT IT REPLACES. temp+`os.replace` hands the destination the TEMP file's
# mode, so a hardened 0600 came back 0644 — on a credential-adjacent file, the wrong direction.
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = json.load(open(tpl))["mcpServers"]["tortoise"]
json.dump(d, open(p, "w"), indent=2)
PY
chmod 600 "$DEST/.mcp.json"
run_install >/dev/null 2>&1
[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$DEST/.mcp.json")" = "0o600" ] \
  && ok "a merge PRESERVES the destination's mode (0600 in, 0600 out)" \
  || fail "a merge WIDENED .mcp.json's mode — a credentialed config's permissions must not be a side effect of a re-sync"
# ⛔ "NO READABLE ENTRY" IS NOT "NEEDS NO KEY", **AND** AN UNPARSEABLE FILE IS NOT UNREPAIRABLE.
# Two arms, because the old single arm pinned the wrong half of the pair. It asserted that an
# unparseable `.mcp.json` FAILED the install (rc≠0) and reported `graph credential: UNKNOWN`: true at
# the time, and the reason the file could never converge. `cloud-cell-bringup.sh` runs `--install`
# ONLY on a verify failure, so an unparseable file was a bring-up that died every time, on a box, with
# no remedy but a hand-edit — the same class as the non-object containers above, one level up, and
# reachable: the pre-#3374 merge wrote with `json.dump(open(dst,"w"))` (truncate-in-place), so an
# interrupted legacy run left a truncated file on an already-provisioned box.
cp "$DEST/.mcp.json" "$TMP/mcp-keep.json"      # the arm corrupts the file below; keep a COPY to restore
printf 'not json at all' > "$DEST/.mcp.json"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'NOTJSON' "$LOG" \
  && ! grep -qF "declares no Authorization" "$LOG" \
  && ! grep -q 'marker: none' "$LOG" \
  && ok "--verify NAMES an unparseable .mcp.json (NOTJSON), never as 'this entry needs no key' and never an empty marker beside a traceback" \
  || fail "--verify handled an unparseable .mcp.json badly (rc=$rc) — either it did not name NOTJSON, or it reported the credential state as 'no Authorization' for a file it could not read, or it printed 'marker: none' over a traceback"
rm -f "$DEST/.mcp.json.bak"
run_install
rc=$?
run_verify
rc2=$?
[ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -f "$DEST/.mcp.json.bak" ] \
  && [ "$(cat "$DEST/.mcp.json.bak")" = "not json at all" ] \
  && ok "install REPAIRS an unparseable .mcp.json (rc=0, and --verify then certifies) and KEEPS the discarded bytes as .mcp.json.bak" \
  || fail "install could not repair an unparseable .mcp.json (install rc=$rc, verify rc=$rc2, .bak=$([ -f "$DEST/.mcp.json.bak" ] && echo present || echo missing)) — cloud-cell-bringup dies on every attempt and no operator instruction can clear it"
rm -f "$DEST/.mcp.json.bak"
cp "$TMP/mcp-keep.json" "$DEST/.mcp.json"      # restore from the COPY, not by re-reading an unparseable file

# ⛔ A MERGE MUST NOT PRESERVE A LEAK SILENTLY. The token scan only ever sees the TORTOISE entry, so a
# literal credential in ANY OTHER server was preserved with rc=0 and the log reading
# `hosted tortoise entry installed (cell-local servers preserved)` — while `--verify` then refused the
# very file the merge had just written (`SECRET_IN_FILE`), so the layer failed and `--install` could
# never converge. The merge now NAMES the path. It does not refuse (the bytes are ALREADY in the
# destination, a merge never clobbers, and setup.sh merges on laptops where no verifier runs), so the
# arm asserts the SENTENCE, which is the half that was missing.
printf '{"mcpServers":{"cell-local":{"command":"/bin/true","env":{"K":"%s"}}}}' "t$(printf 't_%s' "$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)")" > "$TMP/leak.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/leak.json" --cell > "$TMP/leak.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q 'STILL carries a literal credential at cell-local.env.K' "$TMP/leak.out" \
  && ok "the merge NAMES a literal credential it PRESERVED in another server (cell-local.env.K), so its rc and its log agree with the layer's verdict" \
  || fail "the merge preserved a credential in another server and said nothing (rc=$rc) — the install log reports success over a file --verify refuses, and the operator is never told which entry holds it"

# (The HOME-LESS arm lives further down, with the other credential-state arms: it needs
# `CRED_ON_CERT`, and the property it asserts — the credential state ON the certification line — is a
# property of the same LAYER VERIFIED line those arms pin.)

# ⛔ THE INSTALL SIDE MUST ENFORCE THE HOSTED HEADER TOO. The verifier has three arms for it; the
# merge carries its own copy of the predicate, so an install that PRESERVED a foreign variable would
# write a config `--verify` refuses for ever — the unrecoverable disagreement.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t["headers"] = {"Authorization": "Bearer ${SOME_OTHER_KEY}"}
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "install REPLACES a hosted entry naming a foreign variable (install and verify agree)" \
  || fail "install preserved a hosted header naming a variable the client cannot resolve — --verify refuses it, so the cell can never be repaired"
import json, sys
auth = (((json.load(open(sys.argv[1], encoding="utf-8")).get("mcpServers", {}) or {}).get("tortoise", {}) or {}).get("headers") or {}).get("Authorization") or ""
# EXACT — see the re-sync arm below: a substring test on the legacy name is satisfied by the standard
# one, so it cannot see the rewrite it is meant to forbid.
sys.exit(0 if auth == "Bearer ${TORTOISE_MCP_API_KEY}" else 1)
PY

# ⛔ THE HOSTED HEADER MUST BE THE CANONICAL SHAPE, not merely "contains ${". The client DOES expand
# `${VAR}` (extensions/mcp-client/index.ts:819-821) and then sends the value as-is — it adds no scheme —
# so a header without the `Bearer ` scheme reaches the server as `Authorization: tt_…` and gets a 401 — while `--verify` used to pass it, and
# `scripts/cloud-cell-bringup.sh` SKIPS the repair install on a passing verify. Two shapes, both
# certified before this arm existed.
cp "$DEST/.mcp.json" "$DEST/.mcp.json.keep"
for bad in no-scheme foreign-var; do
  python3 - "$DEST/.mcp.json" "$bad" <<'PY'
import json, sys
p, bad = sys.argv[1], sys.argv[2]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
if bad == "no-scheme":
    t["headers"] = {"Authorization": "${TORTOISE_MCP_API_KEY}"}      # no `Bearer ` prefix
else:
    t["headers"] = {"Authorization": "Bearer ${SOME_OTHER_KEY}"}     # a var the resolver never reads
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
  run_verify
  [ $? -eq 1 ] && grep -q "Authorization is not 'Bearer" "$LOG" \
    && ok "--verify REFUSES a hosted Authorization that is not 'Bearer \${TORTOISE_MCP_API_KEY}' ($bad)" \
    || fail "--verify certified a hosted header the client would send with no scheme ($bad) — the lane gets a 401 with LAYER VERIFIED behind it"
  cp "$DEST/.mcp.json.keep" "$DEST/.mcp.json"
done
# ...and the LEGACY name is accepted, because the resolver reads it too (so the certification line
# and the entry can never describe different variables), while the STANDARD name is what the layer
# installs.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t["headers"] = {"Authorization": "Bearer ${TORTOISE_API_KEY}"}
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_verify
[ $? -eq 0 ] && ok "--verify ACCEPTS the LEGACY Bearer \${TORTOISE_API_KEY} (the resolver reads it)" \
  || fail "--verify refused the legacy-name header it is supposed to accept"
cp "$DEST/.mcp.json.keep" "$DEST/.mcp.json"
rm -f "$DEST/.mcp.json.keep"

# ⛔ THE RESOLVER MUST RESOLVE THE VARIABLE THE ARTIFACT NAMES. The installed entry expands exactly
# one (`${TORTOISE_MCP_API_KEY}`), and pi's mcp-client resolves `process.env[NAME]` VERBATIM — no alias
# mapping exists. A resolver that also accepted the fleet alias printed "the hosted MCP will
# authenticate" on a box whose entry expands to the EMPTY string: the exact opposite of the artifact.
# Here the LEGACY name is the ONLY thing set, and the entry names the STANDARD var — so the verdict must
# be UNRESOLVED, and the remedy it prints must name the alias it found.
ALIAS_KEY="t"
ALIAS_KEY="${ALIAS_KEY}t_$(printf 'A%.0s' $(seq 24))"
HOME="$TMP/nohome" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" \
  env -u TORTOISE_MCP_API_KEY TORTOISE_API_KEY="$ALIAS_KEY" \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
grep -q "graph credential: UNRESOLVED" "$LOG" \
  && ok "a legacy-name-only box is NOT certified as authenticating when the entry expands the STANDARD var" \
  || fail "a legacy-name-only box was certified 'will authenticate' while the installed entry expands an unset variable — the certification contradicts the artifact"
grep -q "the LEGACY name TORTOISE_API_KEY IS set" "$LOG" \
  && ok "the refusal names the legacy variable it found, with the line that connects them (#5153)" \
  || fail "a legacy-name-only box got no alias-specific remedy — it is told to push a key it already has"

# ...and a RE-SYNC must not rewrite that alias-named entry into an empty Bearer.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
t = dict(d["mcpServers"]["tortoise"])
t["headers"] = {"Authorization": "Bearer ${TORTOISE_API_KEY}"}
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a re-sync KEEPS an entry's own credential variable (a legacy-named entry is not silently rewritten)" \
  || fail "a re-sync rewrote a working legacy-named Authorization to the standard variable — on a legacy-name-only box that is an empty Bearer"
import json, sys
# ⛔ AN EXACT COMPARE, NOT A SUBSTRING (#3374 review, round 10 P2). `"TORTOISE_API_KEY" in auth` is
# TRUE of `Bearer ${TORTOISE_MCP_API_KEY}` — the standard name CONTAINS the legacy one — so this arm
# stayed green under exactly the regression its own `fail` sentence names (a re-sync rewriting the
# entry to the standard variable on a legacy-name-only box, i.e. an empty Bearer and a 401). The
# behaviour was correct; the assertion could not see it break. Same rule as the arm above, which
# accepted either name and so had a dead first conjunct.
t = (json.load(open(sys.argv[1], encoding="utf-8")).get("mcpServers", {}) or {}).get("tortoise", {}) or {}
auth = (t.get("headers") or {}).get("Authorization") or ""
sys.exit(0 if auth == "Bearer ${TORTOISE_API_KEY}" else 1)
PY
run_verify
[ $? -eq 0 ] && ok "--verify accepts the kept legacy-named entry (install and verify agree)" \
  || fail "--verify refused the legacy-named entry the install just kept"
# restore the canonical entry so the arms below start from the shape the layer installs
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = json.load(open(tpl))["mcpServers"]["tortoise"]
json.dump(d, open(p, "w"), indent=2)
PY

# ⛔ THE VERDICT MUST DESCRIBE THE TORTOISE ENTRY, NOT ANY SERVER'S HEADER. A cell may declare its
# own servers (`merge-mcp.py` preserves them on purpose), so a file-wide first-`Authorization` read
# made `LAYER VERIFIED` say "will authenticate" about a variable the TORTOISE entry does not expand —
# while that entry expanded an unset one and the lane got a 401. Here another server's header comes
# FIRST and names the LEGACY var; the tortoise entry names the STANDARD var, which is unset.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
servers = {"acme-hosted": {"type": "http", "url": "https://example.invalid/mcp/",
                           "headers": {"Authorization": "Bearer ${TORTOISE_API_KEY}"}}}
servers.update(d["mcpServers"])
d["mcpServers"] = servers
json.dump(d, open(p, "w"), indent=2)
PY
HOME="$TMP/nohome" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" \
  env -u TORTOISE_MCP_API_KEY TORTOISE_API_KEY="$ALIAS_KEY" \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
grep -q "graph credential: UNRESOLVED" "$LOG" \
  && ok "the verdict follows the TORTOISE entry's variable, not another server's header" \
  || fail "a cell-local server's Authorization decided the tortoise credential verdict — false green about the entry that actually 401s"

# ...and an entry that declares NO Authorization is NOT reported as missing a key: the documented
# self-host shape has no header because a local daemon needs none. Reporting UNRESOLVED there is a
# false red that also tells the operator to push a key they must not use.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"] = {"tortoise": {"url": "http://localhost:8000/mcp", "_selfHosted": True}}
json.dump(d, open(p, "w"), indent=2)
PY
HOME="$TMP/nohome" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" env -u TORTOISE_API_KEY \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q "declares no Authorization" "$LOG" \
  && ! grep -q "NOT resolvable" "$LOG" \
  && ok "a keyless self-host entry is certified with 'nothing to resolve', not UNRESOLVED" \
  || fail "a keyless self-host entry was reported as missing a credential (rc=$rc) — a false red that also demands a key it must not use"
python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" <<'PY'
import json, sys
p, tpl = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = json.load(open(tpl))["mcpServers"]["tortoise"]
json.dump(d, open(p, "w"), indent=2)
PY

# ⛔ A LITERAL TOKEN ANYWHERE IN THE ENTRY IS REPLACED, not only one in Authorization: a token in
# `env`/`_comment` is still a credential in a shared 0644 file, `--verify` refuses that file, and an
# install that preserved it would re-write a config it then refuses — for ever, silently.
python3 - "$DEST/.mcp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcpServers"]["tortoise"] = {"url": "http://localhost:8000/mcp",
                               "env": {"K": "t" + "t" + "_" + "A" * 24}}
json.dump(d, open(p, "w"), indent=2)
PY
run_install
python3 - "$DEST/.mcp.json" <<'PY' && ok "a token pasted into the entry's env is replaced on install (never preserved into the shared file)" \
  || fail "install preserved a literal token in a self-host entry's env — it re-writes a config --verify then refuses, silently"
import json, sys
raw = open(sys.argv[1]).read()
sys.exit(1 if ("t" + "t" + "_") in raw else 0)
PY

# ⛔ LAYER VERIFIED CARRIES THE CREDENTIAL STATE. Before this, a cell whose TORTOISE_MCP_API_KEY did not
# resolve was certified LAYER VERIFIED with the 401 warning scrolled away above it — and nothing else
# catches it (the key is not part of the layer; cloud-cell-bringup.sh does not check it). Exit 0 is
# deliberate; the STATE has to be unmissable instead. Both directions, so neither can be vacuous.
# ⛔ AND THE POSITIVE ARM MUST READ THE CERTIFICATION LINE ITSELF: `graph_credential_note` prints
# `graph credential: resolves from …` on the SAME run (`cell-install.sh`), so a whole-log grep stays
# green with the state removed from the cert line entirely — i.e. it could not detect the very
# regression the code comment names. Measured: a synthetic two-line log (cert line without the state,
# state on its own line) passed the old grep.
# ⛔ SO THE PATTERN IS ITSELF ASSERTED, not just used. A named `CRED_ON_CERT` with a fixture log that
# it must NOT match is the difference between "this arm is placement-sensitive" and "this arm was
# written to be"; without it the next edit can widen the pattern back over the whole log and every
# assertion below stays green while the property silently disappears. `CRED_ON_CERT` is shared by
# both directions and by the self-check, so they cannot drift apart.
CRED_ON_CERT='^[[:space:]]*LAYER VERIFIED .*graph credential: '
CERT_TWO_LINE="$TMP/cert-two-line.log"
{
  printf '  LAYER VERIFIED — %s carries the farmed scripts, the guards, the skills and the config\n' "$DEST"
  printf 'graph credential: resolves from the environment (TORTOISE_MCP_API_KEY) (len 27) — the hosted MCP will authenticate\n'
} > "$CERT_TWO_LINE"
if grep -qE "${CRED_ON_CERT}resolves from the environment" "$CERT_TWO_LINE"; then
  fail "the credential-state assertion is VACUOUS: its pattern matched a log where the state sits on its OWN line, so it cannot detect the state being removed from LAYER VERIFIED"
else
  ok "the credential-state assertion is placement-sensitive (it does NOT match a two-line log: cert line + separate state line)"
fi
KEY="t"
KEY="${KEY}t_$(printf 'A%.0s' $(seq 24))"
CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" TORTOISE_MCP_API_KEY="$KEY" \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qE "${CRED_ON_CERT}resolves from the environment" "$LOG" \
  && ok "LAYER VERIFIED states the graph credential resolves ON the certification line (a cell certified with a working key)" \
  || fail "LAYER VERIFIED did not report a resolving graph credential ON THE CERTIFICATION LINE (rc=$rc) — a reader cannot tell a working cell from a 401 one"
mkdir -p "$TMP/nohome"
# BOTH names are cleared: a box that exports the legacy alias would
# otherwise resolve and the arm would go red on a correctly-configured machine.
HOME="$TMP/nohome" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" \
  env -u TORTOISE_API_KEY -u TORTOISE_MCP_API_KEY \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
rc=$?
# ⛔ AND THE NEGATIVE ARM MUST READ THE SAME LINE, THROUGH THE SAME PATTERN — one rule, both
# directions. It grepped the whole log, so a revert that moved the UNRESOLVED state onto its own
# `log_line` — the regression the code comment names, and the one `cloud-cell-bringup.sh`'s
# `grep -E 'mode=--verify|LAYER VERIFIED'` silently drops — stayed green.
grep -qE "${CRED_ON_CERT}UNRESOLVED" "$LOG" \
  && ok "…and the UNRESOLVED state is ON the certification line, not on a line the bring-up drops" \
  || fail "the UNRESOLVED state was not on the LAYER VERIFIED line (rc=$rc) — cloud-cell-bringup.sh filters for that line, so a separate one is silently invisible"

# ⛔ A HOME-LESS CONTEXT MUST NOT ABORT THE VERIFIER. This script runs under `set -uo pipefail`, so an
# unguarded `$HOME/keys.env` aborted `--verify` with `HOME: unbound variable` — and it aborted LATE,
# after `.mcp.json verify: OK`, so the log looked like a graph problem while `guard_tools_dir`,
# `guard_spawn_gate`, `guard_gh_shim` and the `LAYER VERIFIED` verdict were all SKIPPED. systemd units,
# `sudo -u`, `env -i` and CI steps all run without HOME, and a correctly-installed cell could not be
# certified from any of them. Two sites had it; this arm reaches one of them (the credential note's
# legacy-alias probe is the other, and it is only reached on a box with no resolvable key).
# ⛔ AND THE ARM MUST CLEAR THE KEY NAMES, OR IT NEVER REACHES THE LINE IT GUARDS (#3374 review P1).
# `graph_key_resolve` probes `"${HOME:-}/keys.env"` only when `printenv "$GRAPH_VAR"` is EMPTY, so on a
# box that exports the key the fixed line is never executed: reverting `${HOME:-}` to `$HOME` left this
# arm GREEN (measured: `rc=0`, `graph credential: resolves from the environment`) while the suite's only
# red was the unrelated group-writable keys.env arm. Both names are cleared, for the same reason the
# negative arm above clears them.
: > "$TMP/nohome.log"
env -u HOME -u TORTOISE_API_KEY -u TORTOISE_MCP_API_KEY \
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
  bash "$INSTALLER" --verify >> "$TMP/nohome.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'unbound variable' "$TMP/nohome.log" \
  && grep -q 'LAYER VERIFIED' "$TMP/nohome.log" \
  && grep -qE "${CRED_ON_CERT}UNRESOLVED" "$TMP/nohome.log" \
  && ok "--verify completes with HOME UNSET and NO key in the environment (rc=0, LAYER VERIFIED reached, credential UNRESOLVED) — a systemd/\`env -i\` context certifies the layer instead of aborting mid-run" \
  || fail "--verify aborted or refused with HOME unset and the key cleared (rc=$rc) — the unbound-variable abort skips every guard after the graph check and reports a graph problem for a HOME problem; or the arm never reached the keys.env probe (no UNRESOLVED on the cert line)"
# ⛔ AND UNRESOLVED ALONE PROVES NOTHING (#3374 review P3): it is ALSO what the resolver prints when the
# candidate loop never ran at all (measured: delete the whole `for base … done` and this arm's previous
# wording still printed its green — the three later keys.env arms were the only reds). So the SAME
# HOME-less context is run again with a 0600 `$CELL_HOME/keys.env` holding a real key: the verdict must
# name THAT FILE, which is a positive only the loop can produce.
printf 'export TORTOISE_MCP_API_KEY="tt_%s"\n' "$(printf 'C%.0s' $(seq 24))" > "$CELL_HOME/keys.env"
chmod 600 "$CELL_HOME/keys.env"
env -u HOME -u TORTOISE_API_KEY -u TORTOISE_MCP_API_KEY \
  CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
  bash "$INSTALLER" --verify > "$TMP/nohome-key.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qF "resolves from $CELL_HOME/keys.env (TORTOISE_MCP_API_KEY)" "$TMP/nohome-key.log" \
  && ok "…and the SAME HOME-less run RESOLVES a 0600 \$CELL_HOME/keys.env by reading it (rc=0) — the candidate loop really ran; UNRESOLVED above would also be printed by a loop that never ran" \
  || fail "a HOME-less run with a 0600 \$CELL_HOME/keys.env did not resolve from it (rc=$rc) — the credential source is the one thing the layer cannot lose to a HOME problem, and the arm above cannot tell 'the loop ran and found nothing' from 'the loop never ran'"
rm -f "$CELL_HOME/keys.env"

# ⛔ NO UNESCAPED BACKTICK IN A MESSAGE THAT IS PART OF AN ASSERTION (#3374 review, round 9). Two
# `fail` messages carried one, and a backtick inside a double-quoted string is COMMAND SUBSTITUTION:
# the suite ran `--verify` from inside a `fail` argument (measured: `line 2053: --verify: command not
# found` above a message with a hole where the word belongs) and ran `type` at :1428. The arm still
# reddened, so nothing was hidden — but the sentence an operator reads on a red was broken, and a
# SUITE must never execute a word it is only trying to print. Escaped at both sites; this guard is
# what keeps the next one from being written, and it is a plain line scan, not a parse.
# ⛔ AND IT SCANS EVERY POSITION, NOT LINE-START (#3374 review, round 10). The first version anchored
# on `^[[:space:]]*(\|\| )?` and therefore inspected only 243 of the file's 411 `ok`/`fail` call
# sites — it missed the suite's DOMINANT `[ … ] && ok "…"` form entirely, i.e. it would have stayed
# silent on the shape an author is most likely to write. The pattern is now position-independent; the
# message says "any line", which is what it now means.
# ⛔ THE SCAN MUST BE ABLE TO CATCH SOMETHING (#3374 review, round 12 P2). The arm ran one awk and
# asserted the RESULT WAS EMPTY — and an absence-of-violations scan is green under ANY narrowing of
# its own pattern. Measured: restoring the pre-round-10 line-start anchor still printed 0 hits over
# this whole file, so reverting that fix (the one whose own comment says the anchor "missed the
# suite's DOMINANT form entirely") reddened NOTHING, and a backtick inside an assertion would silently
# execute a word again. The scan is a named function now, and a MUTANT fixture proves it fires on the
# shape an author actually writes — the same control the R5 suite and the 'label' argument checker
# carry, for the same reason: a guard nothing can fail is not a guard.
_bt_scan() {   # _bt_scan <file> — lines carrying an unescaped backtick inside an ok/fail message
  awk -v bt="$(printf '\140')" '
    $0 !~ /^[[:space:]]*#/ && (index($0, "ok \"") > 0 || index($0, "fail \"") > 0) {
      s = $0; gsub("\\\\" bt, "", s)
      if (index(s, bt) > 0) printf "%d:%s\n", NR, $0
    }' "$1"
}
BT_FIX="$TMP/bt-mutant.sh"
# ⛔ THE MUTANT IS BUILT AT RUNTIME, AND THAT IS NOT PEDANTRY: a literal backtick here would make THIS
# LINE the violation the scan below reports (measured — the first draft of this arm did exactly that,
# and the suite reddened on its own fixture). `$(printf '\140')` emits one into the FILE while the
# suite's own text carries none, so the scanner is tested without being tripped.
printf '%s\n' "[ -n \"\$x\" ] && ok \"an edge case: run $(printf '\140')type x$(printf '\140')\"" > "$BT_FIX"
[ -n "$(_bt_scan "$BT_FIX")" ] \
  && ok "the backtick scanner CATCHES a planted one in the suite's dominant conditional-ok form (so the arm below is not measuring its own silence)" \
  || fail "the backtick scanner did not flag a planted unescaped backtick — it is an absence check that can no longer redden, which is the defect class this PR keeps closing"
bad_bt="$(_bt_scan "${BASH_SOURCE[0]}")"
[ -z "$bad_bt" ] \
  && ok "no unescaped backtick inside ANY ok/fail message on any line (one there would EXECUTE from inside the assertion)" \
  || fail "an ok/fail message carries an unescaped backtick, so the suite executes it: $bad_bt"

# ⛔ A MALFORMED ENTRY IS ITS OWN STATE, NOT "no readable entry" AND NOT "needs no key" (#3374 review
# P3, then round 9). The note only runs on the --verify SUCCESS path, which a refused file never
# reaches, so this arm drives the resolver the note reads — extracted from the installer under test,
# never re-implemented. EVERY sibling shape is pinned here, because fixing only the non-string auth
# left the other two borrowing the wrong sentence (measured: headers-as-string rendered "there is no
# readable tortoise entry" about a file that reads perfectly, whitespace-only rendered "declares no
# Authorization" about an entry that declares one) while --verify said BADDERS:str / LITERAL_AUTH.
mcp_var_for() {   # mcp_var_for <dest-dir> — run the installer's OWN graph_mcp_var against that DEST
  DEST="$1" bash -c 'eval "$(sed -n "/^graph_mcp_var()/,/^}/p" "$1")"; graph_mcp_var' _ "$INSTALLER" 2>/dev/null
}
BADSHAPE_DEST="$TMP/badshape"; mkdir -p "$BADSHAPE_DEST"
for SHAPE in 'non-string auth|"headers":{"Authorization":12345}|BADSHAPE:BADAUTH:int' \
             'string headers|"headers":"Bearer ${TORTOISE_MCP_API_KEY}"|BADSHAPE:BADDERS:str' \
             'blank auth|"headers":{"Authorization":"   "}|LITERAL' \
             'non-object entry|__NOE__|NOENTRY'; do
  KIND="${SHAPE%%|*}"; REST="${SHAPE#*|}"; EXPFOR="${REST##*|}"; BODY="${REST%|*}"
  if [ "$BODY" = "__NOE__" ]; then
    printf '{"mcpServers":{"tortoise":"nope"}}' > "$BADSHAPE_DEST/.mcp.json"
  else
    printf '{"mcpServers":{"tortoise":{"url":"https://api.premiselabs.co/mcp/",%s}}}' "$BODY" > "$BADSHAPE_DEST/.mcp.json"
  fi
  GOT="$(mcp_var_for "$BADSHAPE_DEST")"
  [ "$GOT" = "$EXPFOR" ] \
    && ok "resolver: $KIND → $EXPFOR (its own state — a healthy .mcp.json is never reported as unreadable or keyless)" \
    || fail "resolver: $KIND → '${GOT:-<empty>}' (expected $EXPFOR) — the note then contradicts --verify about the same file, and the empty case is the old 'declares no Authorization' lie; the real cause is a shape --verify names"
done

# ⛔ THE FILE PATH OF THE ALIAS RESOLVER IS THE WHOLE POINT OF THE RESOLVER, AND IT HAD NO COVERAGE.
# Every arm above feeds the credential through the ENVIRONMENT, so `graph_key_from_env_file` could
# regress to a line-parser — which reads `export TORTOISE_MCP_API_KEY="$TORTOISE_API_KEY"` as the
# literal 19-character string and calls a live key malformed — with the suite still green. That is
# the exact mistake measured while building this, so it gets an arm that can only pass by SOURCING.
KEYHOME="$TMP/keyshome"
mkdir -p "$KEYHOME"
ALIAS_KEY35="t"
ALIAS_KEY35="${ALIAS_KEY35}t_$(printf 'B%.0s' $(seq 32))"
cat > "$KEYHOME/keys.env" <<EOF
# the shape a LEGACY-name box carries: the standard name is an ALIAS, not a value.
export TORTOISE_API_KEY="$ALIAS_KEY35"
export TORTOISE_MCP_API_KEY="\$TORTOISE_API_KEY"
EOF
chmod 600 "$KEYHOME/keys.env"
HOME="$KEYHOME" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" \
  env -u TORTOISE_API_KEY -u TORTOISE_MCP_API_KEY \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF "graph credential: resolves from $KEYHOME/keys.env (TORTOISE_MCP_API_KEY)" "$LOG" \
   && ! grep -qF "not tt_/tk_-shaped" "$LOG"; then
  ok "an ALIASED keys.env resolves by SOURCING (not by line-parsing), and the verdict names the file it read"
else
  fail "an aliased keys.env (export TORTOISE_MCP_API_KEY=\"\$TORTOISE_API_KEY\") did not resolve — a line-parser reads that as the literal string and reports a live key as malformed (rc=$rc; log: $LOG)"
fi
# ⛔ SOURCING A FILE IS CODE EXECUTION, SO THE FILE MUST BELONG TO THIS USER AND NOT BE WRITABLE BY
# ANYONE ELSE. One candidate is `$CELL_HOME/keys.env`, and CELL_HOME defaults to `/tmp/cell-home` — a
# path under a WORLD-WRITABLE parent — so a planted file would be executed as whoever provisions the
# cell, from a script whose every comment says the file is operator-pushed and 0600. Both
# directions, and the polarity too: a refused file is a WARNING (the layer is still certified, the
# key is not), and `UNRESOLVED` still rides the certification line.
MODHOME="$TMP/modehome"
mkdir -p "$MODHOME" "$CELL_HOME"
printf 'export TORTOISE_MCP_API_KEY="%s"\n' "$ALIAS_KEY35" > "$CELL_HOME/keys.env"
chmod 660 "$CELL_HOME/keys.env"
HOME="$MODHOME" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" \
  env -u TORTOISE_API_KEY -u TORTOISE_MCP_API_KEY \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
rc=$?
# ⛔ NO PIPE INTO `grep -q` (#841/#864): a quiet consumer exits on first match, the producer
# takes SIGPIPE, and `pipefail` turns a MATCH into a FAILURE — the arm would go green on the
# defect it exists to catch. Capture the produced lines, then test them from a here-string.
cert_line="$(grep -E 'LAYER VERIFIED' "$LOG" || true)"
if [ "$rc" -eq 0 ] \
   && grep -qF "$CELL_HOME/keys.env is NOT a credential source" "$LOG" \
   && grep -q 'graph credential: UNRESOLVED' <<<"$cert_line"; then
  ok "a GROUP-WRITABLE keys.env is refused as a credential source (not sourced, not hidden), and the cell still certifies with UNRESOLVED"
else
  fail "a group-writable keys.env was SOURCED (rc=$rc) — \`--verify\` would execute a file any local user can rewrite, as the provisioning user (log: $LOG)"
fi
chmod 600 "$CELL_HOME/keys.env"
HOME="$MODHOME" CELL_HOME="$CELL_HOME" INFRA_ROOT="$ROOT" \
  env -u TORTOISE_API_KEY -u TORTOISE_MCP_API_KEY \
  bash "$INSTALLER" --verify > "$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qF "graph credential: resolves from $CELL_HOME/keys.env (TORTOISE_MCP_API_KEY)" "$LOG" \
  && ok "…and the SAME file at 0600 DOES resolve (the gate refuses the mode, not the path)" \
  || fail "the ownership/mode gate refused a 0600 file of the right owner (rc=$rc) — a false block on a correctly-provisioned cell"
rm -f "$CELL_HOME/keys.env"
# ⛔ THE OWNERSHIP HALF OF THAT GATE HAD NO ARM AT ALL (#3374 review P3). The arms above exercise
# `_no_group_world_write` only — both fixtures are files THIS USER CREATED, so `-O` is trivially true
# for them, and deleting `[ ! -O "$f" ]` from the gate left the suite green. That is the half that
# refuses a `keys.env` PLANTED BY ANOTHER LOCAL USER under the world-writable `/tmp/cell-home` — the
# exact attack the gate's own comment describes, and the one a mode test cannot see (a planted 0600
# file owned by somebody else passes it). Driven directly against a real file owned by ANOTHER user,
# which needs no privileges to find: `/etc/hostname` is root-owned and 0644, so the MODE half passes
# and only the OWNERSHIP half can refuse it. Reverting the gate to mode-only turns this arm red.
CREDFN="$TMP/graph_key_from_env_file.sh"
sed -n '/^graph_key_from_env_file()/,/^}/p;/^_no_group_world_write()/,/^}/p' "$ROOT/pi-bootstrap/cell-install.sh" > "$CREDFN"
FOREIGN="${FOREIGN_CRED_PROBE:-/etc/hostname}"
if [ -f "$FOREIGN" ] && [ ! -O "$FOREIGN" ]; then
  cred_out="$(bash -c 'source "$1"; graph_key_from_env_file "$2" TORTOISE_MCP_API_KEY; printf "rc=%s" "$?"' _ "$CREDFN" "$FOREIGN" 2>&1 || true)"
  # NO PIPE INTO `grep -q` (#841/#864): a quiet consumer exits on first match and `pipefail` turns a
  # MATCH into a FAILURE. Same rule as every other arm in this file.
  if grep -qF "$FOREIGN is NOT a credential source" <<<"$cred_out" && grep -qF 'rc=1' <<<"$cred_out"; then
    ok "a credential file owned by ANOTHER user is refused on OWNERSHIP alone (it is 0644, so the mode half passes — only -O can say no)"
  else
    fail "a credential source owned by another user was NOT refused (got: $cred_out) — the ownership half of the gate is not enforced, so a file planted by another local user under /tmp/cell-home would be SOURCED as the provisioning user"
  fi
else
  # Not silently green: an absent probe file is reported as the unproven thing it is.
  ok "UNPROVEN-ON(no foreign-owned probe file at $FOREIGN): the OWNERSHIP half of the credential-source gate was not exercised"
fi
# ⛔ `usable()` AND THE VERIFIER MUST BE TOTAL OVER ARBITRARY JSON. A hand-edit can produce
# `"Authorization": 12345` or `"url": 123`; both used to raise (TypeError / AttributeError) BEFORE
# the write, so the merge exited 1 with the file unchanged and `--verify` left an empty marker — the
# "config nothing can repair" class, one level below the `headers` shape fixed in the same commit.
for BADSHAPE in auth url; do
  python3 - "$DEST/.mcp.json" "$ROOT/templates/.mcp.base.json" "$BADSHAPE" <<'PY'
import json, sys
p, tpl, bad = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
t = dict(json.load(open(tpl))["mcpServers"]["tortoise"])
if bad == "auth":
    t["headers"] = {"Authorization": 12345}
else:
    t["url"] = 123
    t["headers"] = {"Authorization": "Bearer ${TORTOISE_MCP_API_KEY}"}
d["mcpServers"]["tortoise"] = t
json.dump(d, open(p, "w"), indent=2)
PY
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -qE 'BADAUTH:int|URLTYPE:int' "$LOG" \
    && ok "--verify names a non-string $BADSHAPE in the tortoise entry (a marker, not a traceback and an empty marker)" \
    || fail "--verify did not name a non-string $BADSHAPE (rc=$rc) — the entry reports as 'nothing can be certified' with no shape and no repair"
  run_install
  run_verify
  rc=$?
  [ "$rc" -eq 0 ] \
    && ok "install REPAIRS a non-string $BADSHAPE into the hosted entry (the repair path converges)" \
    || fail "install could not repair a non-string $BADSHAPE (rc=$rc) — the cell is stuck"
done
# ⛔ AND THE CONTAINERS, not only the entries. A `.mcp.json` whose ROOT is a JSON array/string/number,
# or whose `mcpServers` is not an object, raised on BOTH sides before the write: `--verify` printed
# `marker: none` above a traceback and `--install` — the repair path — failed on its own copy of the
# assumption, so nothing could clear it and `cloud-cell-bringup.sh` died on every bring-up. The shape,
# the NAMED refusal, the repair, and the `.bak` that keeps the discarded bytes.
for BADCONTAINER in root servers; do
  if [ "$BADCONTAINER" = root ]; then
    printf '[]' > "$DEST/.mcp.json"
    EXPECT="BADROOT:list"
  else
    printf '{"mcpServers": 5}' > "$DEST/.mcp.json"
    EXPECT="BADSERVERS:int"
  fi
  rm -f "$DEST/.mcp.json.bak"
  run_verify
  rc=$?
  [ "$rc" -eq 1 ] && grep -q "$EXPECT" "$LOG" \
    && ok "--verify names a non-object .mcp.json $BADCONTAINER ($EXPECT, not an empty marker beside a traceback)" \
    || fail "--verify did not name a non-object $BADCONTAINER (rc=$rc) — the operator gets 'marker: none' and a traceback, and install cannot clear it"
  run_install
  run_verify
  rc=$?
  [ "$rc" -eq 0 ] && [ -f "$DEST/.mcp.json.bak" ] \
    && ok "install REPAIRS a non-object $BADCONTAINER (rc=0) and KEEPS the discarded bytes as .mcp.json.bak" \
    || fail "install could not repair a non-object $BADCONTAINER, or silently destroyed the bytes it replaced (rc=$rc) — the cell is stuck, or operator content is gone"
done
rm -f "$DEST/.mcp.json.bak"

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
# (l) the `activation:` line for the argv-level gh shim (docs/ops/ACTIVATION-MATRIX.md row 1).
# It is a REPORT of the activation state — `guard_gh_shim` is the authority, and it fails the cell —
# but a report that is not pinned is still a lie: flipping its `AGENT_GH_SHIM=0` test or reordering
# its branches would silently restore the defect the first review round found — "PRESENT … (armed)"
# printed on a box where the extension injects nothing. The four states below are the ones that
# change the verdict (present+armed, present+disarmed, absent, absent-but-refused-by-the-guard).
hdr "the gh-shim activation line is truthful in every state"
SHIMSTUB="$TMP/shimstub"
mkdir -p "$SHIMSTUB"
printf '#!/bin/bash\nexit 0\n' > "$SHIMSTUB/gh"
chmod +x "$SHIMSTUB/gh"

out="$(AGENT_GH_SHIM_DIR="$SHIMSTUB" bash -c 'unset AGENT_GH_SHIM; CELL_HOME="$1" INFRA_ROOT="$2" PATH="$3:$PATH" bash "$4" --verify' _ "$CELL_HOME" "$ROOT" "$FAKEBIN" "$INSTALLER" 2>&1)"
grep -q "activation: gh shim PRESENT at $SHIMSTUB" <<<"$out" && ! grep -q DISARMED <<<"$out" \
  && [ "$(grep -c 'activation:' <<<"$out")" -eq 1 ] \
  && ok "a resolvable shim with no kill switch reports PRESENT … armed (one line)" \
  || fail "a resolvable shim did not report PRESENT+armed, or reported more than one activation line"

out="$(AGENT_GH_SHIM_DIR="$SHIMSTUB" AGENT_GH_SHIM=0 bash -c 'CELL_HOME="$1" INFRA_ROOT="$2" PATH="$3:$PATH" bash "$4" --verify' _ "$CELL_HOME" "$ROOT" "$FAKEBIN" "$INSTALLER" 2>&1)"
grep -q 'activation: gh shim PRESENT' <<<"$out" && grep -q DISARMED <<<"$out" \
  && ! grep -q 'guard armed' <<<"$out" \
  && ok "AGENT_GH_SHIM=0 reports PRESENT but DISARMED — never 'armed'" \
  || fail "the kill switch still reported the shim as armed (the exact false green round 1 found)"

# ⛔ THE FIXTURE MUST ACTUALLY HAVE NO SHIM. `AGENT_GH_SHIM_DIR=` was enough while nothing farmed
# the shim; since the farm delivers it, `$DEST/scripts/gh-shim` is the resolver's SECOND candidate
# and resolves — so this arm asserted ABSENT against a state an installed cell no longer has, and
# the suite went red on a CORRECT install (`FAIL: an unresolvable shim was reported as present` in
# both CI lanes). Drive the state instead: remove the installed copy for the length of the
# assertion, then let `--install` put it back — the same mechanism §(l)(3) above uses.
rm -f "$SHIM_DST"
out="$(AGENT_GH_SHIM_DIR= bash -c 'unset AGENT_GH_SHIM; CELL_HOME="$1" INFRA_ROOT="$2" PATH="$3:$PATH" bash "$4" --verify' _ "$CELL_HOME" "$ROOT" "$FAKEBIN" "$INSTALLER" 2>&1)"
grep -q 'activation: gh shim ABSENT' <<<"$out" && ! grep -q 'shim PRESENT' <<<"$out" \
  && ok "no resolvable shim reports ABSENT, and the installed layer is not named armed" \
  || fail "an unresolvable shim was reported as present"
# … and with the shim gone the READ-BACK refuses the cell: the activation line reports, the guard
# decides — so the two states cannot disagree about a layer with no argv gate on it.
grep -q 'argv-level gh SHIM is MISSING' <<<"$out" \
  && ok "…while guard_gh_shim (the authority) refuses that same cell by name, so ABSENT is never printed beside LAYER VERIFIED" \
  || fail "a cell with no argv-level gh shim was not refused by the guard — the activation line reported it and nothing acted on it"
run_install >/dev/null 2>&1
[ -x "$SHIM_DST" ] \
  && ok "the fixture restored the installed shim after the ABSENT arm" \
  || fail "the ABSENT arm left the cell without an installed shim — later sections would measure the wrong tree"

# ── (m) round 13: canonicalise BEFORE judging, a DNS root dot, and two credential sinks ─────────
# Every arm below was measured RED against the pre-fix code before it was accepted.
hdr "the template is judged on the url that is WRITTEN (verify -> install -> verify converges)"

# The marker is extracted ONCE for this section too: an earlier section's copy is not guaranteed to
# still exist by the time these arms run, and an arm that cannot find its instrument reports a
# FAILURE it cannot attribute (measured while writing this: rc=127 read as "NON-CONVERGENT").
MARKER_FN="$TMP/graph_mcp_marker_r13.sh"
sed -n '/^graph_mcp_marker()/,/^}/p' "$ROOT/pi-bootstrap/cell-install.sh" > "$MARKER_FN"
[ -s "$MARKER_FN" ] && ok "the round-13 arms found their instrument (graph_mcp_marker extracted)" \
  || fail "graph_mcp_marker could not be extracted — every arm below would measure nothing"

# ⛔ THE MERGE AND THE VERIFIER ASKED THE SAME QUESTION WITH DIFFERENT PREDICATES (#3374 round 13
# P1). `usable()` answers by ENDPOINT (path-SENSITIVE); the canonicalisation answers by AUTHORITY
# (path-insensitive) and REWRITES the url. With the check first, a template spelling the hosted host
# `/mcp` (no trailing slash) took `usable()`'s SELF-HOST early return ("a daemon may need no key")
# and was THEN written as THE hosted endpoint — so the installer wrote exactly what `--verify`
# refuses, on a loop `cloud-cell-bringup.sh` runs as verify -> install -> verify. Measured pre-fix:
# no Authorization -> merge rc=0 then `NOAUTH` rc=1; `Bearer ${OTHER}` -> rc=0 then `WRONG_AUTH`
# rc=1; `type: "sse"` -> rc=0 then `NOTHTTP:sse` rc=1. A cell could never come up.
# The invariant is one line, so it is asserted as one line over every shape: THE MERGE MUST EITHER
# REFUSE (non-zero, nothing written) OR WRITE A FILE THE MARKER CERTIFIES.
_converge_case() { # <name> <template-json>
  printf '%s' "$2" > "$TMP/cv-tpl.json"
  printf '{"mcpServers":{}}' > "$TMP/cv-dst.json"
  cp "$TMP/cv-dst.json" "$TMP/cv-before.json"
  python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/cv-tpl.json" "$TMP/cv-dst.json" --cell \
    > "$TMP/cv-merge.out" 2>&1
  _mrc=$?
  _mout="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" \
             "$TMP/cv-dst.json" "$TMP/cv-tpl.json" 2>&1)"
  _vrc=$?
  if [ "$_mrc" -ne 0 ]; then
    cmp -s "$TMP/cv-dst.json" "$TMP/cv-before.json" \
      && ok "CONVERGES-BY-REFUSAL: $1 — merge rc=$_mrc and the destination is UNCHANGED" \
      || fail "$1: the merge refused (rc=$_mrc) but STILL WROTE the destination"
  elif [ "$_vrc" -eq 0 ]; then
    ok "CONVERGES: $1 — merge rc=0 and --verify certifies it ($_mout)"
  else
    fail "$1: NON-CONVERGENT — merge rc=0 wrote a file --verify REFUSES ($_mout rc=$_vrc); the repair loop can never clear it"
  fi
}
_converge_case "hosted /mcp, no trailing slash, NO Authorization" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co/mcp","lazy":true}}}'
_converge_case "hosted /mcp, no trailing slash, a FOREIGN credential variable" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co/mcp","headers":{"Authorization":"Bearer ${SOME_OTHER_VAR}"},"lazy":true}}}'
_converge_case "hosted /mcp, no trailing slash, a non-http transport" \
  '{"mcpServers":{"tortoise":{"type":"sse","url":"https://api.premiselabs.co/mcp","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}}}'
_converge_case "hosted /mcp/?x=1 with a query string" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co/mcp/?x=1","lazy":true}}}'
_converge_case "hosted /foo/../mcp/ dot-segment" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co/foo/../mcp/","lazy":true}}}'
# …and the CONTROL that stops the guard passing by refusing EVERYTHING (the false-block direction: a
# fresh box would get no graph at all). A correctly-credentialed non-canonical spelling must be
# NORMALISED and certified, not refused.
_converge_case "hosted /mcp, no trailing slash, the CORRECT credential (control)" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co/mcp","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"},"lazy":true}}}'
_converge_case "the SHIPPED template (control)" \
  "$(cat "$ROOT/templates/.mcp.base.json")"
_converge_case "a genuine self-host daemon (control)" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"http://localhost:8000/mcp","headers":{"Authorization":"Bearer ${SOME_OTHER_VAR}"}}}}'
# ⛔ A DOTTED HOSTED TEMPLATE MUST GO THROUGH THE *MERGE*, NOT ONLY THROUGH THE MARKER (#3374 review,
# round 14 P1). The arms above build a DESTINATION and call the marker; nothing drove a dotted
# TEMPLATE through `merge-mcp.py`, so it kept `endpoint_key` dot-BLIND while `cell-install.sh`'s two
# key functions stripped the dot — the "MUST MATCH" comment described code that did not exist
# (`merge-mcp.py`'s rationale was present and its `if host.endswith(".")` was NOT). Measured
# pre-fix: the merge accepted these, wrote the dotted spelling, and `--verify` refused the result
# `NOAUTH`/`WRONG_AUTH`/`NOTHTTP:sse` for ever — the non-convergent loop this whole section exists to
# close, one spelling deeper. The invariant is the same one line, so they are the same cases.
_converge_case "dotted hosted, no Authorization" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co./mcp/","lazy":true}}}'
_converge_case "dotted hosted, a FOREIGN credential variable" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co./mcp/","headers":{"Authorization":"Bearer ${SOME_OTHER_VAR}"},"lazy":true}}}'
_converge_case "dotted hosted, a non-http transport" \
  '{"mcpServers":{"tortoise":{"type":"sse","url":"https://api.premiselabs.co./mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}}}'
# …and the control: the dotted spelling with the CORRECT credential is the SAME endpoint, so it must be
# normalised and certified — a rule that refused the dot outright would be a false block.
_converge_case "dotted hosted, the CORRECT credential (control)" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co./mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"},"lazy":true}}}'
# ⛔ CLEARTEXT TO THE HOSTED HOST IS NOT A SELF-HOST (#3374 review, round 14 P2 — a FALSE PASS). The
# credential floor needs a CREDENTIAL to fire, so a template with NO Authorization escaped it and took
# the self-host early return; measured pre-fix: merge rc=0, `http://api.premiselabs.co/mcp/` installed
# verbatim, `--verify` `SELFHOSTED:` rc=0 — LAYER VERIFIED over the LIVE hosted host in cleartext with
# no key at all. Both ends now refuse it by name, so the loop converges by refusal.
_converge_case "cleartext hosted, no Authorization" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"http://api.premiselabs.co/mcp/","lazy":true}}}'
# …and the CONTROLS that stop that rule passing by refusing every non-https url: a LAN daemon with no
# key and a self-host on a NON-DEFAULT PORT are both legitimate and must stay preserved.
_converge_case "a LAN http daemon with no key (control)" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"http://192.168.1.5:8000/mcp"}}}'
_converge_case "the hosted HOST on a non-default port (control)" \
  '{"mcpServers":{"tortoise":{"type":"http","url":"http://api.premiselabs.co:8443/mcp"}}}'

# ⛔ THE INVARIANT WAS ONLY EVER DRIVEN FROM AN **EMPTY** DESTINATION (#3374 review, round 16 P1/P2 —
# both measured). Every `_converge_case` above writes `{"mcpServers":{}}` first, so the shape they
# exercise is always "what does the merge make of the TEMPLATE"; the cell's OWN entry — the one an
# already-provisioned box carries, i.e. the input the REPAIR path actually meets — never reached
# `usable()`. It diverged. `usable()` answers "does this need the hosted credential?" by
# `endpoint_key` (path-SENSITIVE) while the rewrite below it normalises by `authority_key`
# (path-insensitive), so a hosted url spelled `/mcp` was classified as a self-host that needs no key
# and was THEN written as the canonical hosted endpoint with that empty credential. Measured pre-fix:
# merge rc=0 wrote `{"url":"https://api.premiselabs.co/mcp/"}` with NO Authorization and `--verify`
# answered `NOAUTH` rc=1; and on the SHIPPED template a `:443` spelling carrying `type:"sse"` came out
# merge rc=0 / `NOTHTTP:sse` rc=1 — reachable on the COMMON path, not only the exotic one. Same
# one-line invariant, asked of the other input.
_converge_case_dst() { # <name> <template-json> <pre-existing destination `tortoise` entry json>
  printf '%s' "$2" > "$TMP/cvd-tpl.json"
  printf '{"mcpServers":{%s}}' "$3" > "$TMP/cvd-dst.json"
  cp "$TMP/cvd-dst.json" "$TMP/cvd-before.json"
  python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/cvd-tpl.json" "$TMP/cvd-dst.json" --cell \
    > "$TMP/cvd-merge.out" 2>&1
  _mrc=$?
  _mout="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" \
             "$TMP/cvd-dst.json" "$TMP/cvd-tpl.json" 2>&1)"
  _vrc=$?
  if [ "$_mrc" -ne 0 ]; then
    cmp -s "$TMP/cvd-dst.json" "$TMP/cvd-before.json" \
      && ok "CONVERGES-BY-REFUSAL: $1 — merge rc=$_mrc and the cell's entry is UNCHANGED" \
      || fail "$1: the merge refused (rc=$_mrc) but STILL WROTE the destination"
  elif [ "$_vrc" -eq 0 ]; then
    ok "CONVERGES: $1 — merge rc=0 and --verify certifies what it wrote ($_mout)"
  else
    fail "$1: NON-CONVERGENT — a PRE-EXISTING cell entry was rewritten (rc=0) into a file --verify REFUSES ($_mout rc=$_vrc); the repair loop can never clear it"
  fi
}
_SELF_TPL='{"mcpServers":{"tortoise":{"type":"http","url":"http://localhost:8000/mcp"}}}'
_converge_case_dst "self-host template + a cell entry spelling the hosted host /mcp with no Authorization" \
  "$_SELF_TPL" '"tortoise":{"url":"https://api.premiselabs.co/mcp"}'
_converge_case_dst "self-host template + a cell entry at the hosted :443 with a non-http transport" \
  "$_SELF_TPL" '"tortoise":{"type":"sse","url":"https://api.premiselabs.co:443/mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}'
_converge_case_dst "the SHIPPED template + a cell entry at the hosted :443 with a non-http transport" \
  "$(cat "$ROOT/templates/.mcp.base.json")" '"tortoise":{"type":"sse","url":"https://api.premiselabs.co:443/mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}'
_converge_case_dst "the SHIPPED template + a cell entry spelling the hosted host /mcp with no Authorization" \
  "$(cat "$ROOT/templates/.mcp.base.json")" '"tortoise":{"url":"https://api.premiselabs.co/mcp"}'
# …and the CONTROLS that keep the fix from being bought cheaply. It must not have repointed every cell
# at the template, and it must not have started refusing non-canonical spellings: a genuine self-host
# daemon is still PRESERVED and certified, and a default-port spelling with a GOOD credential is still
# NORMALISED with that credential KEPT.
_converge_case_dst "the SHIPPED template + a genuine self-host daemon entry (control)" \
  "$(cat "$ROOT/templates/.mcp.base.json")" '"tortoise":{"type":"sse","url":"http://localhost:8000/mcp","_selfHosted":true}'
_converge_case_dst "the SHIPPED template + a cell entry at the hosted :443 with a GOOD credential (control)" \
  "$(cat "$ROOT/templates/.mcp.base.json")" '"tortoise":{"type":"http","url":"https://api.premiselabs.co:443/mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}'
# ⛔ …AND THE SENTENCE THAT SAYS WHAT IT WROTE. The unusable-entry branch said "with the hosted
# default" while, on a SELF-HOST template, writing the TEMPLATE's url — false about the artifact on
# exactly the input round 16's P1 was reached from (a sentence-false-about-the-artifact is this PR's
# most-repeated defect class). It now names the url actually written.
printf '%s' "$_SELF_TPL" > "$TMP/cvd-tpl.json"
printf '%s' '{"mcpServers":{"tortoise":{"url":"https://api.premiselabs.co/mcp"}}}' > "$TMP/cvd-dst.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$TMP/cvd-tpl.json" "$TMP/cvd-dst.json" --cell \
  > "$TMP/cvd-note.out" 2>&1
grep -qF 'with the template' "$TMP/cvd-note.out" \
  && grep -qF '(http://localhost:8000/mcp)' "$TMP/cvd-note.out" \
  && ok "the REPLACED note names the url it ACTUALLY wrote (a self-host template's), not 'the hosted default'" \
  || fail "the replacement note does not name the url it wrote (got '$(tr '\n' '|' < "$TMP/cvd-note.out" | cut -c1-170)') — the operator is told a url the file does not carry"

# and the VERIFIER's own side of it: a hand-edited config that names the hosted host in cleartext with
# no credential must be REFUSED BY NAME, never certified as a self-host.
printf '{"mcpServers":{"tortoise":{"type":"http","url":"http://localhost:8000/mcp","headers":{"Authorization":"Bearer ${SOME_OTHER_VAR}"}}}}' > "$TMP/clear-tpl.json"
for _clear in '{"mcpServers":{"tortoise":{"type":"http","url":"http://api.premiselabs.co/mcp/"}}}' \
              '{"mcpServers":{"tortoise":{"type":"http","url":"http://api.premiselabs.co./mcp/"}}}'; do
  printf '%s' "$_clear" > "$TMP/clear-cfg.json"
  out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$TMP/clear-cfg.json" "$TMP/clear-tpl.json" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && case "$out" in INSECURE_URL:*) true ;; *) false ;; esac \
    && ok "a CLEARTEXT hosted url is refused by name, never certified as a self-host — '$out'" \
    || fail "a cleartext hosted url was NOT refused as INSECURE_URL (got '$out' rc=$rc) — LAYER VERIFIED over an endpoint that cannot answer"
done

# ⛔ A TRAILING ROOT DOT IS THE SAME DNS NAME, AND IT WAS CERTIFIED WITH AN EMPTY BEARER (#3374
# round 13 P1 — a FALSE PASS). `api.premiselabs.co.` is the FQDN spelling of the hosted host: the
# client's own parser keeps the dot and DNS resolves it to the same server, so a request there
# reaches the LIVE hosted endpoint and needs the hosted key. Measured pre-fix:
# `https://api.premiselabs.co./mcp/` + `_selfHosted: true` + `Bearer ${SOME_OTHER_VAR}` (an EMPTY
# Bearer — the #3275/#3289 401 this change exists to close) was certified `SELFHOSTED:` rc=0, and
# with no header at all too. Both directions are asserted: the dotted spelling must not be
# EXEMPTED, and the dotted spelling carrying a real credential must still certify (same endpoint —
# a rule that refused the dot outright would be a false block on a working config).
printf '{"mcpServers":{"tortoise":{"type":"http","url":"http://localhost:8000/mcp","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}}}' > "$TMP/dot-tpl.json"
for _dot in '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co./mcp/","_selfHosted":true,"headers":{"Authorization":"Bearer ${SOME_OTHER_VAR}"}}}}' \
            '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co./mcp/","_selfHosted":true}}}'; do
  printf '%s' "$_dot" > "$TMP/dot-cfg.json"
  out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$TMP/dot-cfg.json" "$TMP/dot-tpl.json" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ! grep -q SELFHOSTED <<<"$out" \
    && ok "a trailing ROOT DOT on the hosted host is NOT a self-host exemption — refused '$out'" \
    || fail "a trailing-dot hosted url was certified '$out' rc=$rc — the empty-Bearer 401 blessed as 'a self-host needs none'"
done
printf '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co./mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}}}' > "$TMP/dot-good.json"
out="$(bash -c 'source "$1"; shift; graph_mcp_marker "$@"' _ "$MARKER_FN" "$TMP/dot-good.json" "$TMP/dot-tpl.json" 2>&1)"
rc=$?
# the marker reports the CONFIG'S OWN spelling (`shown_url`), so the assertion is on the VERDICT
# (`OK:` = the hosted branch, credential present) and not on the normalised text it prints.
[ "$rc" -eq 0 ] && case "$out" in OK:*) true ;; *) false ;; esac \
  && ok "...while the dotted spelling carrying the REAL credential certifies (same endpoint, not a false block)" \
  || fail "a correctly-credentialed dotted hosted url was refused '$out' rc=$rc — that is a false block on a working config"

# ⛔ A BACKUP IS A SECOND COPY OF THE CREDENTIAL (#3374 round 13 P2). `copy2` preserved the SOURCE
# mode, so a 0644 `.mcp.json` — the common case, and the one an operator hand-edits — produced a
# 0644 `.mcp.json.bak` holding whatever literal credential it had, while `--verify` scans the
# destination ONLY and certified the layer `OK:`. Measured pre-fix: a `Bearer tt_…` inside an
# unparseable `.mcp.json` survived into `.bak` at the source's mode beside a green verdict. The
# merge must not DELETE operator bytes, so the assertion is on the MODE, not on the bytes.
printf '%s' '{"mcpServers":{"acme":{"headers":{"Authorization":"Bearer tt_AAAABBBBCCCCDDDD"}}},}' > "$TMP/bak-dst.json"
chmod 644 "$TMP/bak-dst.json"
python3 "$ROOT/pi-bootstrap/lib/merge-mcp.py" "$ROOT/templates/.mcp.base.json" "$TMP/bak-dst.json" --cell > "$TMP/bak.out" 2>&1
rc=$?
_bakwide="$(python3 -c 'import os,stat,sys
try: print(stat.S_IMODE(os.stat(sys.argv[1]).st_mode) & 0o077)
except OSError: print("absent")' "$TMP/bak-dst.json.bak")"
[ "$rc" -eq 0 ] && [ "$_bakwide" = "0" ] && grep -q 'tt_AAAABBBBCCCCDDDD' "$TMP/bak-dst.json.bak" \
  && ok "the replaced config's bytes are KEPT in .bak, but the backup is OWNER-ONLY (no group/other bits) — a credential is not widened by being backed up" \
  || fail "the .bak of a 0644 config kept group/other bits ($_bakwide) — the credential survives in a second, unscanned file"

# ⛔ THE ASSIGNMENT IS WHERE THE PLAINTEXT APPEARS (#3374 round 13 P2). bash traces the SUBSTITUTED
# VALUE of a plain assignment, so a `bash -x` bring-up printed the resolved key — past every
# redaction the installer does — into a log that gets pasted into issues fleet-wide. Asserted as
# DATA on the two functions themselves (hermetic, and it cannot pass by breaking resolution): the
# sentinel must be ABSENT from the trace, and the value must still resolve to its full length.
_SENTINEL="tt_SENTINELSENTINELSENTINEL12345"
printf 'TORTOISE_MCP_API_KEY=%s\n' "$_SENTINEL" > "$TMP/sent-keys.env"
chmod 600 "$TMP/sent-keys.env"
# ⛔ DRIVE THE *REAL* FUNCTION, NOT A COPY OF ITS GUARD (#3374 round 14 P1 — round 13's arm could
# not fail). bash traces the SUBSTITUTED VALUE not only of the assignment that reads the key but of
# EVERY later expansion of it: `+ '[' -n tt_… ']'`, `+ GRAPH_KEY=tt_…`, `+ case tt_… in`,
# `+ local key=tt_…`. Round 13 guarded only the first of those four and this arm re-implemented THAT
# guard beside a plain assignment, so the real function leaked the key twice under `bash -x` while
# the arm stayed green — a test that cannot fail for the property it names. The arm therefore calls
# `graph_key_resolve` itself, and asserts the negative control below so that a FIX THAT MOVES BACK
# to holding the secret in a variable goes RED rather than silently passing.
{
  sed -n '/^_no_group_world_write()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_mcp_var()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_key_from_env_file()/,/^}/p' "$INSTALLER"
  sed -n '/^_graph_key_read()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_key_resolve()/,/^}/p' "$INSTALLER"
} > "$TMP/keyfn.sh"
[ -s "$TMP/keyfn.sh" ] && grep -q '^_graph_key_read()' "$TMP/keyfn.sh" \
  && ok "the round-14 arms found their instrument (the REAL resolver, including _graph_key_read)" \
  || fail "the resolver could not be extracted — every arm below would measure nothing"
mkdir -p "$TMP/xt-dest" "$TMP/xt-home"
printf '{"mcpServers":{"tortoise":{"type":"http","url":"https://api.premiselabs.co/mcp/","headers":{"Authorization":"Bearer ${TORTOISE_MCP_API_KEY}"}}}}' \
  > "$TMP/xt-dest/.mcp.json"
cp "$TMP/sent-keys.env" "$TMP/xt-home/keys.env"
chmod 600 "$TMP/xt-home/keys.env"
cat > "$TMP/xtrace.sh" <<'XT'
#!/usr/bin/env bash
set -uo pipefail
KEYFN="$1"; DEST="$2"; HOME="$3"; CELL_HOME=""; GRAPH_VAR=""
. "$KEYFN"
set -x
graph_key_resolve
set +x
echo "RESOLVED set=$GRAPH_KEY_SET shaped=$GRAPH_KEY_SHAPED len=$GRAPH_KEY_LEN src=$GRAPH_KEY_SRC"
XT
# the FILE path (HOME/keys.env) — `env -u` so the operator's own environment cannot satisfy the
# lookup first and make the arm measure the wrong branch
_out="$(env -u TORTOISE_MCP_API_KEY -u TORTOISE_API_KEY \
        bash "$TMP/xtrace.sh" "$TMP/keyfn.sh" "$TMP/xt-dest" "$TMP/xt-home" 2>&1)"
if grep -qF "$_SENTINEL" <<<"$_out"; then
  fail "a 'bash -x' run of the REAL resolver printed the graph key verbatim — every bring-up log can carry the tenant key"
elif ! grep -q "RESOLVED set=1 shaped=1 len=${#_SENTINEL}" <<<"$_out"; then
  fail "the xtrace arm could not resolve the key from HOME/keys.env (got '$(tr '\n' ' ' <<<"$_out" | cut -c1-100)') — the arm is vacuous"
else
  ok "a 'bash -x' run of the REAL resolver does NOT trace the key, and still RESOLVES it (the guard is not a silent disable)"
fi
# the ENVIRONMENT path (`printenv`) — round 13 never guarded this one at ALL
_out="$(env TORTOISE_MCP_API_KEY="$_SENTINEL" bash "$TMP/xtrace.sh" "$TMP/keyfn.sh" "$TMP/xt-dest" "$TMP/xt-empty-home" 2>&1)"
if grep -qF "$_SENTINEL" <<<"$_out"; then
  fail "a 'bash -x' run printed the key when it resolved from the ENVIRONMENT — the printenv path was never guarded"
elif ! grep -q "RESOLVED set=1 shaped=1 len=${#_SENTINEL}" <<<"$_out"; then
  fail "the environment-path arm could not resolve the key (got '$(tr '\n' ' ' <<<"$_out" | cut -c1-100)')"
else
  ok "...nor when it resolves from the ENVIRONMENT (the round-13 guard covered only the file read)"
fi
# ⛔ THE NEGATIVE CONTROL — without it this arm cannot fail. Delete the guard from a COPY of the
# extracted resolver; the sentinel MUST appear. If it does not, the assertions above are vacuous and
# a stream of future regressions would be certified clean (which is exactly what round 13 shipped).
grep -q '^  set +x$' "$TMP/keyfn.sh" \
  && sed '/^  set +x$/d' "$TMP/keyfn.sh" > "$TMP/keyfn-unguarded.sh" \
  || : > "$TMP/keyfn-unguarded.sh"
_out="$(env -u TORTOISE_MCP_API_KEY -u TORTOISE_API_KEY \
        bash "$TMP/xtrace.sh" "$TMP/keyfn-unguarded.sh" "$TMP/xt-dest" "$TMP/xt-home" 2>&1)"
[ -s "$TMP/keyfn-unguarded.sh" ] && grep -qF "$_SENTINEL" <<<"$_out" \
  && ok "NEGATIVE CONTROL: with the guard removed the same arm DOES print the key — so the two arms above can fail" \
  || fail "the xtrace arm is VACUOUS — removing the guard still does not surface the key, so it would certify a leak as clean"
# ⛔ …AND THE SAME GUARD MUST COVER THE LEGACY-ALIAS HINT (#3374 review, round 15 P1). `graph_
# credential_note` read the ALIAS through `[ -n "${TORTOISE_API_KEY:-}" ]` and `[ -n "$(…)" ]`, and
# `set -x` traces both WITH THE VALUE — measured `+ '[' -n tt_… ']'` on exactly the population the hint
# exists for (primary name unset, legacy alias set). This arm drives the REAL note through that branch.
{
  sed -n '/^_no_group_world_write()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_mcp_var()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_key_from_env_file()/,/^}/p' "$INSTALLER"
  sed -n '/^_graph_key_read()/,/^}/p' "$INSTALLER"
  sed -n '/^_graph_key_present()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_key_resolve()/,/^}/p' "$INSTALLER"
  sed -n '/^graph_credential_note()/,/^}/p' "$INSTALLER"
} > "$TMP/notefn.sh"
mkdir -p "$TMP/xt-legacy-home"
printf 'TORTOISE_API_KEY=%s\n' "$_SENTINEL" > "$TMP/xt-legacy-home/keys.env"
chmod 600 "$TMP/xt-legacy-home/keys.env"
cat > "$TMP/xtnote.sh" <<'XT'
#!/usr/bin/env bash
set -uo pipefail
KEYFN="$1"; DEST="$2"; HOME="$3"; CELL_HOME="$HOME"; GRAPH_VAR=""
. "$KEYFN"
log_line() { printf '%s\n' "$*"; }
set -x
graph_credential_note || true
set +x
XT
_out="$(env -u TORTOISE_MCP_API_KEY -u TORTOISE_API_KEY \
        bash "$TMP/xtnote.sh" "$TMP/notefn.sh" "$TMP/xt-dest" "$TMP/xt-legacy-home" 2>&1)"
if grep -qF "$_SENTINEL" <<<"$_out"; then
  fail "a 'bash -x' run of graph_credential_note printed the LEGACY key — the alias hint expands it inside the traced test"
elif ! grep -q 'LEGACY name TORTOISE_API_KEY IS set' <<<"$_out"; then
  fail "the legacy-alias arm did not reach the hint branch at all (got '$(tr '\n' ' ' <<<"$_out" | cut -c1-100)') — it would pass whether or not the leak is fixed"
else
  ok "the legacy-alias hint fires under 'bash -x' WITHOUT printing the key it just found"
fi

# -------------------------------------------------------------------------
hdr "run 3: the deny is enforced BY PATTERN, across EVERY home the cell runs under (#2147)"
# MEASURED 2026-11-05, five cells: the deny was NAME-scoped (one exact path) and PER-HOME (only
# $DEST), and denied copies survived BOTH ways — 1 / 0 / 7 / 3 / 2 per box. `pi` discovers extensions
# by RULE (`dist/core/extensions/loader.js`: any top-level `extensions/*.ts`/`*.js`, and any
# subdirectory holding `index.ts`/`index.js`), so every arm below is a copy that WAS being LOADED
# while the exact-name test certified the box.
# These arms are the sibling of run 2b, one axis over: 2b proves the deny does not depend on
# manifest.json; this run proves it does not depend on the SPELLING of the path or on which home the
# copy happens to live in.
run_alt_verify() {   # <alt-home>  — the shipped read-back WITH the cell's other home declared
  : > "$LOG"
  echo "---- cell-install --verify (CELL_ALT_HOMES=$1) ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" CELL_ALT_HOMES="$1" INFRA_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
    bash "$INSTALLER" --verify >> "$LOG" 2>&1
}
run_alt_install() {  # <alt-home>
  : > "$LOG"
  echo "---- cell-install --install (CELL_ALT_HOMES=$1) ----" >> "$LOG"
  CELL_HOME="$CELL_HOME" CELL_ALT_HOMES="$1" INFRA_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
    bash "$INSTALLER" --install >> "$LOG" 2>&1
}

# (3a) A SUFFIXED copy in $DEST. `tortoise-capture.bak.ts` is a top-level `*.ts` — pi loads it.
echo '// a suffixed copy pi WOULD load' > "$DEST/extensions/tortoise-capture.bak.ts"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -qF "FAIL: $CAPTURE_LINE" "$LOG" \
  && ok "--verify FAILS, with the named line, on a SUFFIXED capture copy (tortoise-capture.bak.ts)" \
  || fail "--verify certified a suffixed capture copy the exact-name deny cannot see: $(grep -m1 -E 'capture|FAIL' "$LOG")"
grep -q 'tortoise-capture.bak.ts' "$LOG" \
  && ok "…and names the offending PATH, so the operator knows which copy to remove" \
  || fail "the refusal does not name the suffixed copy — an operator cannot act on it"
run_install >/dev/null 2>&1
{ [ ! -e "$DEST/extensions/tortoise-capture.bak.ts" ]; } \
  && ok "--install REMOVES the suffixed copy (the deny repairs, it does not only report)" \
  || fail "a suffixed capture copy SURVIVED --install — the verify half would loop: refuse, install, refuse"

# (3b) A suffixed copy of the other denied entry, with the `.ts` inside the suffix rather than after
# it: `cmux-session.disabled.js` shares the STEM, which is why the match is on the stem and not on
# the literal entry name.
echo '// a suffixed copy of the surface-absent deny' > "$DEST/extensions/cmux-session.disabled.js"
run_verify
rc=$?
[ "$rc" -eq 1 ] && grep -q 'denied extension is PRESENT on the cell: extensions/cmux-session.disabled.js' "$LOG" \
  && ok "--verify refuses a suffixed cmux-session copy (stem match, not a literal name match)" \
  || fail "--verify certified cmux-session.disabled.js"
run_install >/dev/null 2>&1
[ ! -e "$DEST/extensions/cmux-session.disabled.js" ] \
  && ok "--install removes the suffixed cmux-session copy too" \
  || fail "a suffixed cmux-session copy survived --install"

# (3c) A file that merely MENTIONS the denied name is NOT a copy of it, and must not be refused:
# this is the over-block direction, and a deny that fires on it would fail a healthy cell.
echo 'notes about tortoise-capture, which lives in the checkout' > "$DEST/extensions/tortoise-capture-notes.txt"
# …and neither is a DIRECTORY pi would not index. `pi` loads `extensions/<dir>` only when it holds an
# `index.ts`/`index.js`; a directory of notes is inert, and `--install` would `rm -rf` it if the
# predicate were just the name prefix.
mkdir -p "$DEST/extensions/tortoise-capture-noindex"
echo 'notes' > "$DEST/extensions/tortoise-capture-noindex/README.md"
# …nor is a directory with a package.json that carries NO pi manifest: pi's `resolveExtensionEntries`
# needs `pi.extensions`, else it falls through to the index check and loads nothing.
mkdir -p "$DEST/extensions/tortoise-capture-data"
printf '{"name":"capture-data","version":"1.0.0"}\n' > "$DEST/extensions/tortoise-capture-data/package.json"
# …and a `<stem>-helper.ts` is a DIFFERENT, loadable extension, not a copy of the denied one: the
# sweep may `rm -rf`, so the remainder has to reduce to a copy MARKER, not merely start with a dash.
printf '// a different, loadable extension sharing the prefix\n' > "$DEST/extensions/tortoise-capture-helper.ts"
# …nor is a directory whose `pi.extensions` names a file that is NOT THERE: pi falls through to the
# index check and loads nothing, so it is not a copy either.
mkdir -p "$DEST/extensions/tortoise-capture-pkgmissing"
printf '{"name":"x","pi":{"extensions":["missing.js"]}}\n' > "$DEST/extensions/tortoise-capture-pkgmissing/package.json"
# ⛔ DRIVEN THROUGH `--install`, because the DELETE is the risk: `--verify` cannot remove anything,
# so an arm that only verified would never see the damage a prefix-wide sweep does.
run_install >/dev/null 2>&1
run_verify \
  && ok "--verify does NOT refuse an unrelated file/directory that merely starts with the denied name (no over-block)" \
  || fail "--verify refused an unrelated path whose name starts with tortoise-capture — the pattern is too broad: $(grep -m1 'FAIL' "$LOG")"
[ -d "$DEST/extensions/tortoise-capture-noindex" ] && [ -f "$DEST/extensions/tortoise-capture-notes.txt" ] \
  && [ -f "$DEST/extensions/tortoise-capture-data/package.json" ] \
  && [ -f "$DEST/extensions/tortoise-capture-helper.ts" ] \
  && [ -f "$DEST/extensions/tortoise-capture-pkgmissing/package.json" ] \
  && ok "…and none of the non-copies was DELETED by --install (a copy MARKER is required, not just the prefix)" \
  || fail "--install DELETED a path that is not a copy of the denied entry — the sweep's predicate is too broad"
rm -rf "$DEST/extensions/tortoise-capture-notes.txt" "$DEST/extensions/tortoise-capture-noindex" \
       "$DEST/extensions/tortoise-capture-data" "$DEST/extensions/tortoise-capture-helper.ts" \
       "$DEST/extensions/tortoise-capture-pkgmissing"

# (3d) A copy in the CELL'S OTHER HOME. #2916's two-home state is the measured cause: the operating
# home kept its copies while the installer scanned the account home.
ALT_HOME="$TMP/alt-home"
ALT_DEST="$ALT_HOME/.pi/agent"
mkdir -p "$ALT_DEST/extensions/tortoise-capture.old"
echo '// a copy left in the OTHER home' > "$ALT_DEST/extensions/tortoise-capture.old/index.ts"
run_alt_verify "$ALT_HOME"
rc=$?
[ "$rc" -eq 1 ] && grep -qF "FAIL: $CAPTURE_LINE" "$LOG" \
  && ok "--verify FAILS on a copy in the DECLARED other home (CELL_ALT_HOMES), with the named line" \
  || fail "--verify certified a capture copy in the cell's other home: $(grep -m1 -E 'capture|FAIL' "$LOG")"
grep -q "$ALT_DEST/extensions/tortoise-capture.old" "$LOG" \
  && ok "…and names the path in that home, so the operator edits the right tree" \
  || fail "the refusal does not name the copy's path in the other home"
run_alt_install "$ALT_HOME" >/dev/null 2>&1
{ [ ! -e "$ALT_DEST/extensions/tortoise-capture.old" ]; } \
  && ok "--install removes the copy from the other home (the sweep reaches both trees)" \
  || fail "a capture copy in the other home SURVIVED --install — verify would loop forever on this cell"
# ⛔ AND THE DEFAULT MUST NOT TOUCH AN UNDECLARED HOME. This is the LAPTOP case: a developer's own
# `~/.pi/agent/extensions/tortoise-capture` is a working feature there, so an installer that swept the
# ambient $HOME unconditionally would DELETE it. The extra homes are declared by the bring-up (the
# only path that certifies a cell), never guessed.
mkdir -p "$ALT_DEST/extensions/tortoise-capture"
echo '// the operator home the installer was NOT told about' > "$ALT_DEST/extensions/tortoise-capture/index.ts"
run_verify \
  && ok "with NO CELL_ALT_HOMES the installer neither refuses nor touches an undeclared home (no laptop deletion)" \
  || fail "--verify refused a home it was never told about — the scan is guessing homes: $(grep -m1 'FAIL' "$LOG")"
[ -e "$ALT_DEST/extensions/tortoise-capture/index.ts" ] \
  && ok "…and the undeclared home's extension is still there (the default is non-destructive)" \
  || fail "the installer DELETED an extension from a home it was not told about"
rm -rf "$ALT_HOME"
run_verify >/dev/null 2>&1 \
  && ok "the cell verifies clean again once the suffixed and other-home copies are gone" \
  || fail "--verify still fails after the copies were removed: $(grep -m1 'FAIL' "$LOG")"

# -------------------------------------------------------------------------
hdr "syntax"
bash -n "$INSTALLER" && ok "cell-install.sh parses (bash -n)" || fail "cell-install.sh has a syntax error"

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILURES: $FAILURES of $CHECKED arms — full run log: $LOG" >&2
  tail -30 "$LOG" >&2 || true
  exit 1
fi
echo "OK: $CHECKED arms — the operational layer installs to a cell, is verified by reading it back, and refuses a partial one."
