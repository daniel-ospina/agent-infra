#!/usr/bin/env bash
# merged-not-closed.test.sh — hermetic tests for the ported instrument (#8468).
#
# No network. Every assertion drives the SHIPPED script with a stub `gh` on PATH, so the contract is
# tested rather than re-implemented. Retiring tortoise's copy of the harness also retires the suite
# that guarded it (`tests/test_orchestrator_harness.py`), so the behaviours that suite covered for
# THIS tool are covered here.
#
# Covered:
#   * `--help` prints the header, never the source (a hardcoded `sed -n '2,40p'` overshot it once).
#   * repo resolution has THREE forms and two refusals: a slug is used verbatim, a checkout path is
#     derived from, an unresolvable origin exits 2, and a value that is neither is refused.
#     ⛔ A directory named `owner/name` must NOT shadow an explicit slug (#2040's class).
#   * a failed issue listing exits 2 — never 1, never 0 — so a caller cannot read "the API failed" as
#     "nothing to drain".
#   * a successful empty sweep exits 0 and says so (an empty answer is a real answer).
#   * `--label`/`--repo` with no value exit 2 (the header promises never to emit 1).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNC="$HERE/merged-not-closed.sh"
fails=0
ck() { # <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── a stub gh that answers the two surfaces this tool uses, and records what it was asked ────────
# `MODE=fail` makes every call fail (the unqueryable-surface arm). `MODE=ok` answers an empty repo.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
[ "${MODE:-ok}" = fail ] && exit 1
for a in "$@"; do
  case "$a" in
    *search/issues*) echo 0; exit 0 ;;
  esac
done
echo '[]'
SH
chmod +x "$TMP/bin/gh"

run() { # run <dir> [args...] -> stdout+stderr captured in $OUT, rc in $RC
  local dir="$1"; shift
  OUT="$( cd "$dir" && PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" MODE="${MODE:-ok}" REPO="${R:-}" \
          bash "$MNC" "$@" 2>&1 )"; RC=$?
}

# ── 1. --help prints the header, not the source ─────────────────────────────────────────────────
run "$TMP" --help
case "$OUT" in *'#!/usr/bin/env bash'*) rc=1 ;; *) rc=0 ;; esac
[ "$RC" -eq 0 ] && [ "$rc" -eq 0 ] && rc=0 || rc=1
ck "--help exits 0 and prints the header (never the script's own source)" $rc

# ── 2. an explicit SLUG is used verbatim, even when a directory of that name exists ──────────────
mkdir -p "$TMP/acme/widget"; git -C "$TMP/acme/widget" init -q 2>/dev/null
git -C "$TMP/acme/widget" remote add origin https://github.com/other/proj.git 2>/dev/null
: > "$TMP/gh.log"
R="acme/widget"; run "$TMP" --repo acme/widget
grep -q 'repos/acme/widget/issues' "$TMP/gh.log" && rc=0 || rc=1
ck "an explicit slug is used verbatim (a same-named DIRECTORY does not shadow it)" $rc
grep -q 'repos/other/proj/issues' "$TMP/gh.log" && rc=1 || rc=0
ck "the shadowing checkout's origin is NOT queried (the #2040 wrong-repo class)" $rc

# ── 3. a PATH-shaped $REPO is derived from, not passed to gh as a slug ───────────────────────────
: > "$TMP/gh.log"
R="$TMP/acme/widget"; run "$TMP"
# ⛔ NO `--repo` ON THIS LINE on purpose: the harness exports `REPO` as a CHECKOUT PATH, and an
# explicit `--repo ""` correctly CLEARS it — so the env-only form is what must be exercised here.
grep -q 'repos/other/proj/issues' "$TMP/gh.log" && rc=0 || rc=1
ck "a path-shaped repo is DERIVED from (owner/name from origin, not 'repos//tmp/...')" $rc

# ── 4. an unresolvable origin exits 2 (never 0, never 1) ────────────────────────────────────────
mkdir -p "$TMP/plain"
R=""; run "$TMP/plain" --repo ""
[ "$RC" -eq 2 ] && rc=0 || rc=1
ck "an unresolvable origin exits 2 — a non-answer is never a clean sweep" $rc

# ── 5. a value that is neither a slug nor a directory is refused with 2 ──────────────────────────
# ⛔ ONE TOKEN, ON PURPOSE (review P2, cycle 4). `--repo not a slug` is THREE argv words, so it exited
# 2 from the leftover-word arm (`unknown argument: a`) and never reached the shape guard — the very
# guard the case is named after, and where a real defect lived (`../tortoise` was classified as a
# slug because `.`/`..` passed the owner character class). A single token exercises the arm.
R=""; run "$TMP" --repo notaslug:thing
[ "$RC" -eq 2 ] && rc=0 || rc=1
ck "a --repo that is neither owner/name nor a directory exits 2" $rc
# …and the two DOT-segment shapes that slipped through, driven individually.
R=""; run "$TMP" --repo ../tortoise
[ "$RC" -eq 2 ] && rc=0 || rc=1
ck "a --repo of ../<name> is refused, never sent to gh as repos/../<name>" $rc
R=""; run "$TMP" --repo ./tortoise
[ "$RC" -eq 2 ] && rc=0 || rc=1
ck "a --repo of ./<name> is refused (no gh call for a relative path)" $rc

# ── 6. a FAILED listing exits 2 (the fail-closed contract) ───────────────────────────────────────
MODE=fail; R="acme/widget"; run "$TMP" --repo acme/widget
[ "$RC" -eq 2 ] && rc=0 || rc=1
ck "an unqueryable issue listing exits 2 — never 1, never an empty successful sweep" $rc
MODE=ok

# ── 7. a successful EMPTY sweep exits 0 and says so ──────────────────────────────────────────────
R="acme/widget"; run "$TMP" --repo acme/widget
[ "$RC" -eq 0 ] && rc=0 || rc=1
ck "an empty sweep exits 0 (an empty answer is a real answer)" $rc
case "$OUT" in *'no open issue'*) rc=0 ;; *) rc=1 ;; esac
ck "the empty sweep SAYS it swept nothing rather than printing nothing" $rc

# ── 8. an option with no value exits 2, not 1 ───────────────────────────────────────────────────
run "$TMP" --label
[ "$RC" -eq 2 ] && rc=0 || rc=1
ck "--label with no value exits 2 (the header promises never to emit 1)" $rc

echo "merged-not-closed.test.sh: $fails failure(s)"
[ "$fails" -eq 0 ]
