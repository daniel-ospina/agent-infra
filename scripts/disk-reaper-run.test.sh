#!/usr/bin/env bash
# disk-reaper-run.test.sh — the scheduled WRAPPER's environment contract.
#
# Run: bash scripts/disk-reaper-run.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE, AND WHY IT DID NOT EXIST BEFORE. `disk-reaper-run.sh` is the
# `ExecStart` of `eldato-disk-reaper.service`, and its job is to hand its children a usable
# ENVIRONMENT, not to decide policy. It computed `CELL_HOME` and used it as a `HOME` fallback, but
# assigned it as a SHELL variable — so no child ever saw it.
#
# MEASURED CONSEQUENCE (#3278, 2026-11-06, owner, on a cell): the unit renders
# `Environment=HOME=/home/cmux`, which IS a real directory, so the fallback never substituted. The
# abandoned-worktree delegate's `home-or-state` guard compares a candidate against
# `"${HOME}" "${CELL_HOME}" "${REAP_AW_STATE_DIR}"`, so it compared against `/home/cmux` alone and
# `/tmp/cell-home` — a live ~20 GB operative home holding the cell's `.pi` state, with no `.git` so no
# `main-checkout` guard of its own — matched NONE of the three references. On the armed pass that tree
# was preserved by `reason=gitless-cap`, i.e. by a rate limit, and by nothing else.
#
# The case below is the regression guard for that: with `CELL_HOME` UNSET — the shape the unit actually
# runs in — the child must still receive a cell home. It goes red the moment the `export` is removed
# (verified by reverting it), which is why the assertion is written against the CHILD's environment
# rather than against the wrapper's source text.
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

# The stub IS the child: it reports the environment the delegate's guard will read.
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

# ── A: the unit's own environment shape — HOME real, CELL_HOME unset ─────────────────────────
case_a() {
    mkdir -p "$T/a/home" || { case_check 1 "fixture could not be built"; return 1; }
    # `env -u` so the case proves the UNSET shape, not an empty-string one.
    OUT="$(env -u CELL_HOME HOME="$T/a/home" DISK_REAPER="$T/bin/stub-reaper" \
           bash "$WRAPPER" 2>&1)"; OUT_RC=$?
    [ -n "${AW_DEBUG:-}" ] && printf '%s\n' "$OUT" >&2
    case_check "$([ "$OUT_RC" = 0 ] && echo 0 || echo 1)" "the wrapper runs to the child (rc=$OUT_RC)"
    case_check "$(grep -q 'CHILD_CELL_HOME=<unset>' <<<"$OUT" && echo 1 || echo 0)" \
               "CELL_HOME is NEVER <unset> in the child — the guard always gets a reference"
    case_check "$(grep -qxF 'CHILD_CELL_HOME=/tmp/cell-home' <<<"$OUT" && echo 0 || echo 1)" \
               "the child receives the wrapper's own resolved default, /tmp/cell-home"
    case_check "$(grep -qxF "CHILD_HOME=$T/a/home" <<<"$OUT" && echo 0 || echo 1)" \
               "a real HOME is left alone — the HOME fallback did not fire"
    case_check "$(grep -qF 'CHILD_ARGV=--apply' <<<"$OUT" && echo 0 || echo 1)" \
               "and with no mode argument the unit's default --apply is supplied"
    return $((CASE_FAIL > 0))
}

printf '\ndisk-reaper-run.test.sh — the scheduled wrapper hands its children the cell home\n\n'
mkstub || { printf 'FATAL: could not build the stub child\n'; exit 1; }
if ( CASE_FAIL=0; case_a ); then ok "A an unset CELL_HOME still reaches the child (the measured defect)"; else bad "A an unset CELL_HOME still reaches the child (the measured defect)"; fi

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
