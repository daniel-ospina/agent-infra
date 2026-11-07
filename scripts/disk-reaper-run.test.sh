#!/usr/bin/env bash
# disk-reaper-run.test.sh — the scheduled WRAPPER must not SYNTHESIZE a `CELL_HOME` for its children.
#
# Run: bash scripts/disk-reaper-run.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ SCOPE, STATED NARROWLY ON PURPOSE. The wrapper deliberately writes several environment variables
# (`HOME` `:44`, `GH_BIN` `:88`/`:96`, `AGENT_GH_GATE_NO_WAIT` `:102`, `REAP_WT_GH_TIMEOUT` `:105`,
# `PATH` `:113`) and unsets one (`AGENT_GH_REAL` `:55`); NONE of that is what this suite guards, and a
# maintainer who read it as "the wrapper never touches the environment" would be misled about the
# #2354 fail-closed gh pinning. The single property asserted here is `CELL_HOME`.
#
# ⛔ WHY IT EXISTS AT ALL. `disk-reaper-run.sh` computes a `CELL_HOME` and uses it for its own `HOME`
# fallback. The obvious next step — exporting it so children can see it — is WRONG. It was taken,
# measured, and reverted before it merged.
#
# WHY `CELL_HOME` MUST STAY LOCAL. The abandoned-worktree delegate reads that variable twice, and the
# two reads do not want the same thing:
#
#   1. the `home-or-state` guard wants a value — without one, a live ~20 GB `/tmp/cell-home` (no `.git`,
#      so no `main-checkout` guard of its own) matched no reference at all and was preserved only by
#      `reason=gitless-cap`, a rate limit (#3278, 2026-11-06). That is fixed in the DELEGATE, by a local
#      `CELL_HOME_DEFAULT` the guard loop reads.
#   2. `load_pin` (named, not line-numbered — the old `:332` went stale and pointed at `acquire_lock`)
#      wants NO value it did not already have: it reads
#      `"${CELL_HOME}/orchestrator/.agent-infra-stamp.json"` then `"${HOME}/.pi/orchestrator/…"` with
#      FIRST-MATCH-WINS and a `break`, so the list is a SUBSTITUTION, not a union. Exporting CELL_HOME
#      on a box whose two stamps disagree — exactly the `HOME=/home/cmux` vs `CELL_HOME=/tmp/cell-home`
#      divergence above — makes the HOME stamp stop being read, so a tree only that stamp pinned becomes
#      a candidate and `rm -rf` takes it.
#
# So (a) an unset `CELL_HOME` must arrive UNSET in the child, and (b) a caller-supplied one must arrive
# verbatim, so a re-added `export CELL_HOME` and a clobber are both caught.
#
# `disk-reaper-run.sh:34` still ASSIGNS `CELL_HOME` for its own `HOME` fallback: that local assignment is
# fine and is not what this suite forbids — the child's environment is.
#
# Hermetic: `HOME` is a fixture dir under $T and the child is a STUB reaper named through `DISK_REAPER`
# (the wrapper's own documented seam), so this suite runs no reaper and reads no real disk. `gh`
# resolution runs for real and its warning is expected — the child is the stub, so nothing downstream
# uses that binary.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/disk-reaper-run.sh"
[ -f "$WRAPPER" ] || { printf 'FATAL: %s missing — this suite tests the scheduled wrapper\n' "$WRAPPER"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-run-test.XXXXXX")" || exit 1
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
case_check() { # <0|1> <message>
    if [ "$1" = 0 ]; then printf '     · %s\n' "$2"; return 0; fi
    printf '     ✗ %s\n' "$2"; CASE_FAIL=$((CASE_FAIL + 1)); return 1
}

# The stub IS the child: it reports the environment the delegate's guard and `load_pin` will read.
mkstub() {
    mkdir -p "$T/bin" || return 1
    cat >"$T/bin/stub-reaper" <<'STUB'
#!/usr/bin/env bash
printf 'CHILD_HOME=%s\n' "${HOME:-<unset>}"
printf 'CHILD_CELL_HOME=%s\n' "${CELL_HOME:-<unset>}"
printf 'CHILD_ARGV=%s\n' "$*"
STUB
    chmod +x "$T/bin/stub-reaper"
}

# ── A: the unit's own shape — HOME real, CELL_HOME unset. The child must see it UNSET. ───────
case_a() {
    mkdir -p "$T/a/home" || { case_check 1 "fixture could not be built"; return 1; }
    # `env -u` so the case proves the UNSET shape, not an empty-string one.
    OUT="$(env -u CELL_HOME HOME="$T/a/home" DISK_REAPER="$T/bin/stub-reaper" \
           bash "$WRAPPER" 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the wrapper runs to the child (rc=$OUT_RC)"
    # ⛔ THE REGRESSION ASSERTION. Re-adding `export CELL_HOME` to the wrapper turns this red, and with
    # it the `load_pin` substitution described in the header comes back.
    case_check "$(grep -qxF 'CHILD_CELL_HOME=<unset>' <<<"$OUT" && echo 0 || echo 1)" \
               "an unset CELL_HOME stays UNSET in the child — the wrapper synthesizes no CELL_HOME"
    case_check "$(grep -qxF "CHILD_HOME=$T/a/home" <<<"$OUT" && echo 0 || echo 1)" \
               "a real HOME is left alone — the HOME fallback did not fire"
    case_check "$(grep -qF 'CHILD_ARGV=--apply' <<<"$OUT" && echo 0 || echo 1)" \
               "and with no mode argument the unit's default --apply is supplied"
    return $((CASE_FAIL > 0))
}

# ── B: a caller-supplied CELL_HOME arrives verbatim ──────────────────────────────────────────
case_b() {
    mkdir -p "$T/b/home" "$T/b/cell-home" || { case_check 1 "fixture could not be built"; return 1; }
    OUT="$(HOME="$T/b/home" CELL_HOME="$T/b/cell-home" DISK_REAPER="$T/bin/stub-reaper" \
           bash "$WRAPPER" --dry-run 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the wrapper runs to the child (rc=$OUT_RC)"
    case_check "$(grep -qxF "CHILD_CELL_HOME=$T/b/cell-home" <<<"$OUT" && echo 0 || echo 1)" \
               "a caller-supplied CELL_HOME passes through verbatim (the wrapper neither adds nor rewrites)"
    case_check "$(grep -qxF "CHILD_HOME=$T/b/home" <<<"$OUT" && echo 0 || echo 1)" \
               "and HOME is still the caller's"
    case_check "$(grep -qF 'CHILD_ARGV=--dry-run' <<<"$OUT" && echo 0 || echo 1)" \
               "an explicit mode is passed through unchanged"
    return $((CASE_FAIL > 0))
}

printf '\ndisk-reaper-run.test.sh — the wrapper must not synthesize a CELL_HOME for its children\n\n'
mkstub || { printf 'FATAL: could not build the stub child\n'; exit 1; }
if ( CASE_FAIL=0; case_a ); then ok "A an unset CELL_HOME stays unset in the child (load_pin's input is unchanged)"; else bad "A an unset CELL_HOME stays unset in the child (load_pin's input is unchanged)"; fi
if ( CASE_FAIL=0; case_b ); then ok "B a caller-supplied CELL_HOME passes through verbatim"; else bad "B a caller-supplied CELL_HOME passes through verbatim"; fi

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
