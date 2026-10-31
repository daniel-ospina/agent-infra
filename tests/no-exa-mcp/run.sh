#!/usr/bin/env bash
# tests/no-exa-mcp/run.sh — the "exa is gone and stays gone" guard.
#
# WHY THIS FILE EXISTS
# --------------------
# `exa` was an MCP search server that nobody wanted. The owner's ruling (2026-10-31):
#   "exa should be uninstalled because I never wanted it. external research should be perplexity."
# It was removed from `templates/.mcp.base.json` and `.mcp.json` — but those are the SOURCE
# two files from which EVERY repo `.mcp.json`, every derived worktree copy, and
# `~/.pi/agent/.mcp.json` is materialised (`pi-bootstrap/setup.sh`, `bin/agent-infra.js`).
# A bring-up, a consumer `agent-infra install`, or a well-meaning "let me re-add the lazy
# search server" edit re-introduces it silently — nothing reads the file to check. That is a
# **silent** regression of an owner decision: no error, no red check, the server simply
# reappears in the config a lane loads and the next lane starts calling it.
#
# So the invariant is asserted on the SOURCE, not on one derived copy:
#   NO `.mcp.json` in this repo may declare an `exa` MCP server.
#
# WHAT THIS FILE DOES *NOT* CLAIM
# -------------------------------
# A consumer repo's own `.mcp.json` (e.g. tortoise's) is that repo's tracked file and is
# outside this population. The template is what it is materialised FROM, so fixing the
# template is what makes the next bring-up clean; this guard keeps the template from
# regressing.
#
# ⛔ A PASS HERE IS NOT FLEET-WIDE. The population is THIS CHECKOUT's index. Two classes are
# structurally invisible to it and a green run says nothing about them:
#   * `.worktrees/` is gitignored, so the derived copy inside every linked worktree —
#     including this repo's own — is not enumerated. Each one is a checkout of this tracked
#     file, so it is fixed by the NEXT checkout after this lands, not by this run; until
#     then a lane sitting in an older worktree still loads exa.
#   * a consumer repo's tracked `.mcp.json` (tortoise's) is a different repo's file and needs
#     its own PR there.
# That is why a passing run prints a census of sibling worktrees that STILL name exa:
# informational, never a failure — failing on them would be a false block on another
# branch's tracked file, and this repo has already paid for that class of over-block.
#
# DISCRIMINATION (the reason this suite is not a no-op)
# ---------------------------------------------------
# A check that reads a population and prints ✅ is satisfied vacuously when the population is
# empty, when the JSON parse silently fails, or when the match rule is wrong. So every arm is
# asserted, and the population scan and the self-tests use the SAME detector code (a second
# copy of the rule could pass while the real one is broken):
#   (1) the population is NON-EMPTY (an empty population is UNMEASURED, never green);
#   (2) the detector FIRES on a fixture declaring `exa`   → nonzero, names the file;
#   (2b) the detector fires on a RENAMED key              → matches the binary, not the name;
#   (3) the detector PASSES on a clean fixture            → zero, no false positive;
#   (4) malformed JSON is a FAILURE, not a silent skip (fail-open is the defect class).
#
# Discovery: this file lives at `tests/*/run.sh`, which `scripts/run-bash-shards.sh`
# DERIVES its list from — so it runs in BOTH lanes (PR + main) by construction, and no
# workflow file is touched (ci.yml/ci-main.yml/node-ci.yml are byte-locked).
#
# Primitives: bash + python3 + git only (no rg/fd — absent on ubuntu-latest).
# ⚠️ NO `mapfile`/`readarray`: those are bash 4+ and the mac this fleet also runs on ships
# bash 3.2, where `mapfile: command not found` would empty the population and the guard
# would still print a cheery ✅ for zero files — the vacuous-pass defect this suite exists
# to catch. The `while read` loop below is the bash-3.2-safe spelling.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

fails=0
ok()  { echo "   ✅ $1"; }
bad() { echo "   ❌ $1"; fails=$((fails + 1)); }

echo "== no-exa-mcp guard (owner ruling 2026-10-31) =="

# ── the detector — ONE implementation, used by both the population scan and the ──
#    self-tests below. `grade <file>...` prints one line per offender and exits
#    nonzero if any file declares exa OR cannot be parsed.
#
#    IDENTITY, NOT JUST THE KEY NAME. A first cut matched only a server literally
#    keyed `exa`, so `"exa-search": {"command":"npx","args":["…exa-mcp-server"]}`
#    passed every arm while remaining perfectly loadable — a rename is exactly what
#    a well-meaning re-add looks like. So a server is exa if ANY of these hold:
#      * its key matches ^exa$ or ^exa[-_]              (exa, exa-search, exa_mcp)
#      * `exa-mcp-server` appears in its command/args    (a renamed key, same binary)
#      * its env declares EXA_API_KEY                    (same credential, same service)
#    Arm (2b) below pins the renamed-key case so the widening cannot silently rot.
grade() {
  python3 - "$@" <<'PY'
import json
import re
import sys

KEY_RE = re.compile(r"^exa($|[-_])", re.IGNORECASE)


def _identifies_exa(name, server):
    """True when this server IS exa, whatever it is called."""
    if KEY_RE.match(name or ""):
        return f"server key {name!r} matches ^exa"
    if not isinstance(server, dict):
        return None
    argv = [str(server.get("command", ""))] + [str(a) for a in server.get("args", []) or []]
    blob = " ".join(argv).lower()
    if "exa-mcp-server" in blob or re.search(r"(^|[/\s@_-])exa($|[\s@_-])", blob):
        return "invokes the exa-mcp-server package"
    env = server.get("env") or {}
    if isinstance(env, dict) and any("EXA_API_KEY" in str(k).upper() for k in env):
        return "declares EXA_API_KEY in its env"
    return None


offenders = []
unparseable = []
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:                       # malformed != clean
        unparseable.append((path, f"{type(exc).__name__}: {exc}"))
        continue
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        unparseable.append((path, "no `mcpServers` object"))
        continue
    for name, server in servers.items():
        why = _identifies_exa(name, server)
        if why:
            offenders.append((path, name, why))

for path, name, why in offenders:
    print(f"OFFENDER {path}: server {name!r} — {why}")
for path, why in unparseable:
    print(f"UNPARSEABLE {path}: {why}")
sys.exit(1 if (offenders or unparseable) else 0)
PY
}

# ── (1) the population, index-bounded (never a recursive walk at a root) ────────
# Tracked + untracked-but-not-ignored; basename `.mcp.json`. `--exclude-standard`
# keeps build output and vendored trees out without a hand-maintained prune list.
POP=()
while IFS= read -r p; do
  [ -n "$p" ] && POP+=("$p")
done < <(
  { git ls-files                 -- '*.mcp.json'
    git ls-files --others --exclude-standard -- '*.mcp.json'
  } | grep -E '(^|/)\.mcp\.json$' | sort -u
)

POP_N="${#POP[@]}"
echo "   population: $POP_N .mcp.json file(s) — ${POP[*]:-<none>}"

if [ "$POP_N" -eq 0 ]; then
  # An empty population must never read as compliance: the glob or the git index broke.
  bad "UNMEASURED: population is EMPTY — no .mcp.json found, so nothing was graded"
else
  ok "population is non-empty ($POP_N file(s) graded)"
fi

# ── (2) the real scan ──────────────────────────────────────────────────────────
if out="$(grade "${POP[@]}" 2>&1)"; then
  ok "no .mcp.json declares an 'exa' MCP server"
else
  bad "a .mcp.json declares an 'exa' MCP server (or could not be parsed):"
  printf '      %s\n' "$out"
fi

# ── (3) the template is the SOURCE every derived copy comes from ────────────────
TMPL="templates/.mcp.base.json"
if [ ! -f "$TMPL" ]; then
  bad "$TMPL is missing — the materialisation source is gone, so this guard is UNMEASURED"
elif out="$(grade "$TMPL" 2>&1)"; then
  ok "$TMPL declares no 'exa' server"
else
  bad "$TMPL still declares an 'exa' server (every bring-up would reintroduce it):"
  printf '      %s\n' "$out"
fi

# ── (4) self-tests: the detector must BOTH fire and pass ───────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/no-exa-mcp.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/dirty" "$FIX/clean"

cat > "$FIX/dirty/.mcp.json" <<'JSON'
{ "mcpServers": { "exa": { "command": "npx", "args": ["-y", "exa-mcp-server"] } } }
JSON
cat > "$FIX/clean/.mcp.json" <<'JSON'
{ "mcpServers": { "example": { "command": "node", "args": ["server.js"] } } }
JSON
printf '{ "mcpServers": { "exa": ' > "$FIX/clean/broken.json"   # deliberately malformed

if grade "$FIX/dirty/.mcp.json" >/dev/null 2>&1; then
  bad "detector did NOT fire on a fixture that declares 'exa' — the guard is a no-op"
else
  ok "detector fires on a fixture declaring 'exa' (exit nonzero)"
fi

# (2b) A RENAMED key must still be caught. This is the arm that makes widening the
#      match to server IDENTITY falsifiable: key `search-semantic`, binary exa-mcp-server.
cat > "$FIX/dirty/renamed.json" <<'JSON'
{ "mcpServers": { "search-semantic": { "command": "npx", "args": ["-y", "exa-mcp-server"], "env": { "EXA_API_KEY": "x" } } } }
JSON
if grade "$FIX/dirty/renamed.json" >/dev/null 2>&1; then
  bad "detector MISSED exa under a renamed key — 'search-semantic' still spawns exa-mcp-server"
else
  ok "detector catches exa under a renamed key (matches the binary, not just the key)"
fi

if grade "$FIX/clean/.mcp.json" >/dev/null 2>&1; then
  ok "detector passes on a clean fixture (no false positive)"
else
  bad "detector flagged a clean fixture — false positive"
fi

if grade "$FIX/clean/broken.json" >/dev/null 2>&1; then
  bad "detector read malformed JSON as clean — fail-open"
else
  ok "malformed JSON is a FAILURE, not a silent skip"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "== no-exa-mcp: PASS ($POP_N file(s) graded) =="
  # Informational census: copies OUTSIDE this population that still name exa. Never a
  # failure (see the stated limit in the header) — but silence would let a green tick read
  # as fleet-wide when a live lane in an older worktree is still loading the server.
  STALE="$(grep -rlE --include='.mcp.json' '"exa"|exa-mcp-server' \
             ../*/.mcp.json ../../tortoise/.mcp.json 2>/dev/null || true)"
  if [ -n "$STALE" ]; then
    echo "   ℹ️  NOT graded here (outside this checkout's index) — still naming exa:"
    printf '      %s\n' $STALE
    echo "      Other branches'/repos' tracked files: they clear on their next checkout, or"
    echo "      need their own PR. This run's PASS covers only the $POP_N file(s) above."
  fi
  exit 0
fi
echo "== no-exa-mcp: FAIL ($fails finding(s)) =="
echo "   The owner's ruling stands: exa is uninstalled; external research is Perplexity"
echo "   (the built-in web_search, or the seo-intelligence MCP server — both Perplexity)."
exit 1
