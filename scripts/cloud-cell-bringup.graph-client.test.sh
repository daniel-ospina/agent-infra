#!/usr/bin/env bash
# cloud-cell-bringup.graph-client.test.sh — the probe for `check_graph_client` (agent-infra#3253).
#
# WHY THIS EXISTS. The function is a multi-branch reading with one hard rule (never print the key's
# value) and one subtle mechanism (a CAPTURED `printf mcp` / `printf rest` sentinel whose ABSENCE — not
# an exit status — separates "the test ran and found the key" from "the file terminated the shell before
# the test"). Every branch carries the whole value of the reading, and none of them was exercised: a
# regression in the sentinel, in the REST-vs-MCP distinction, or in the never-print rule would be
# silent — the check would keep printing a confident line, and nobody could tell "reported absent" from
# "the probe never ran".
#
# HOW IT PROBES. The function is EXTRACTED VERBATIM from the shipped script (`sed` on the function
# body, not a copy) and sourced beside two stubs (`ok`/`warn`) that append to a transcript. A copy
# pasted into this file would pass on the broken original too — the same reason
# `cloud-cell-bringup.test.sh` drives the shipped script end-to-end.
#
# THE NON-VACUITY FLOOR: the extraction must produce a non-empty function and the FIRST case must pass,
# because a probe that silently extracted nothing would report every later arm as a missing-string
# failure and read as "the fix is broken" instead of "the probe is broken".
#
# Usage:  bash scripts/cloud-cell-bringup.graph-client.test.sh
# Exit:   0 = all arms pass, 1 = at least one arm failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/cloud-cell-bringup.sh"
[ -r "$SRC" ] || { echo "FAIL: cannot read $SRC" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cbg-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

FAILURES=0
OKS=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { OKS=$((OKS + 1)); }

# ── the function, verbatim ────────────────────────────────────────────────────────────────────────
FN="$TMP/check_graph_client.sh"
sed -n '/^check_graph_client() {$/,/^}$/p' "$SRC" >"$FN"
if [ ! -s "$FN" ] || ! grep -q '^check_graph_client() {$' "$FN" || ! grep -q '^}$' "$FN"; then
    fail "extraction: no \`check_graph_client\` function body found in $SRC — the probe would be vacuous"
    echo "FAILURES: $FAILURES" >&2
    exit 1
fi
bash -n "$FN" || { fail "extraction: the extracted body does not parse"; echo "FAILURES: $FAILURES" >&2; exit 1; }
pass

# The stubs the function expects, one transcript per case.
# ⛔ `die` IS STUBBED ON PURPOSE, AND `clean` IS RUN ON EVERY CASE. The function's contract is
# "WARNS, NEVER DIES" (`cloud-cell-bringup.sh`, above `check_graph_client`), and a stub set that only
# provides `ok`/`warn` cannot see the difference: measured 2026-11-03, inserting `die "..."` ahead of
# the client-missing warning turned the check into a hard refusal of readiness while the probe still
# reported 16/16 passed — the only trace was an unasserted `die: command not found` on stderr. The
# same hole accepts ANY undefined helper the body starts calling (a `log_line`, a new trap installer):
# the body runs, the calls 127, and no assertion notices.
OUT=""
ok()   { OUT="${OUT}ok: $*"$'\n'; }
warn() { OUT="${OUT}warn: $*"$'\n'; }
die()  { OUT="${OUT}fatal: $*"$'\n'; }

# run_case <label> — sources the extraction and records stdout AND stderr separately.
run_case() {
    OUT=""
    # shellcheck source=/dev/null
    . "$FN"
    check_graph_client
    printf '%s' "$OUT" >"$TMP/$1.out"
}

# clean <label> — no `die` path taken, and nothing escaped to stderr.
clean() {
    expect_absent "$1" "fatal:"
    if [ -s "$TMP/$1.err" ]; then
        fail "$1: the check wrote to STDERR — a die() it must not take, or a helper this harness does not stub:"$'\n'"$(sed 's/^/    /' "$TMP/$1.err")"
    else pass; fi
}
expect() { # <case> <substring>
    if grep -qF -- "$2" "$TMP/$1.out"; then pass; else
        fail "$1: expected output containing [$2]; got:"$'\n'"$(sed 's/^/    /' "$TMP/$1.out")"
    fi
}
expect_absent() { # <case> <substring>
    if grep -qF -- "$2" "$TMP/$1.out"; then
        fail "$1: output MUST NOT contain [$2]; got:"$'\n'"$(sed 's/^/    /' "$TMP/$1.out")"
    else pass; fi
}

SECRET="SUPERSECRET_VALUE_42"

# ── case 1: the good box — client, sibling, and the MCP key in the lane file ─────────────────────
H1="$TMP/h1"; E1="$TMP/h1/keys.env"
mkdir -p "$H1/.pi/agent/scripts"
: >"$H1/.pi/agent/scripts/tortoise-graph.sh"
: >"$H1/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E1"
HOME="$H1" ENV_FILE="$E1" run_case good >"$TMP/good.stdout" 2>"$TMP/good.err"
expect good "graph client: present at"
# \u26d4 THE SCOPE WORDS ARE THE ASSERTION. Round 4's P1 was an UNQUALIFIED `ok ... present` that read as a
# clean bill over the measured stale hand-copy; a regression that keeps "present at $client" and drops
# the sentence passes every other arm here (measured 2026-11-03: 46/46 green with the defect restored), so
# the sentence itself is pinned.
expect good "presence only"
expect good "cell-install.sh --verify"
expect good "tortoise_graph_client.py beside it"
expect good "graph credential: TORTOISE_MCP_API_KEY is set in"
expect_absent good "warn:"
clean good

# ── case 2: NOTHING delivered — BOTH findings must be reported in ONE run ────────────────────────
# (the regression this arm exists for: the client-missing branch used to `return 0`, so the credential
# finding arrived a whole bring-up cycle later)
H2="$TMP/h2"; E2="$TMP/h2/keys.env"
mkdir -p "$H2"
printf 'NOTHING=1\n' >"$E2"
HOME="$H2" ENV_FILE="$E2" run_case absent >"$TMP/absent.stdout" 2>"$TMP/absent.err"
expect absent "graph client MISSING:"
expect absent "graph credential MISSING:"
clean absent

# ── case 3: half-delivered — the .sh without its sibling dies on the first call ──────────────────
H3="$TMP/h3"; E3="$TMP/h3/keys.env"
mkdir -p "$H3/.pi/agent/scripts"
: >"$H3/.pi/agent/scripts/tortoise-graph.sh"
printf 'export TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E3"
HOME="$H3" ENV_FILE="$E3" run_case half >"$TMP/half.stdout" 2>"$TMP/half.err"
expect half "graph client: present at"
expect half "HALF-DELIVERED"
clean half

# ── case 4: the REST key only — a warn, never an ok (an `ok` here is the false-PASS shape) ───────
H4="$TMP/h4"; E4="$TMP/h4/keys.env"
mkdir -p "$H4/.pi/agent/scripts"
: >"$H4/.pi/agent/scripts/tortoise-graph.sh"; : >"$H4/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_API_KEY=%s\n' "$SECRET" >"$E4"
HOME="$H4" ENV_FILE="$E4" run_case rest >"$TMP/rest.stdout" 2>"$TMP/rest.err"
expect rest "graph credential UNCERTAIN"
expect_absent rest "graph credential: TORTOISE_MCP_API_KEY is set"
clean rest

# ── case 5: a keys.env with an early `exit 0` — the sentinel must catch it ────────────────────────
H5="$TMP/h5"; E5="$TMP/h5/keys.env"
mkdir -p "$H5/.pi/agent/scripts"
: >"$H5/.pi/agent/scripts/tortoise-graph.sh"; : >"$H5/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_MCP_API_KEY=%s\nexit 0\n' "$SECRET" >"$E5"
HOME="$H5" ENV_FILE="$E5" run_case earlyexit >"$TMP/earlyexit.stdout" 2>"$TMP/earlyexit.err"
expect_absent earlyexit "TORTOISE_MCP_API_KEY is set in"
clean earlyexit

# ── case 6: a keys.env with `trap "exit 1" EXIT` — the captured sentinel survives pipefail ───────
H6="$TMP/h6"; E6="$TMP/h6/keys.env"
mkdir -p "$H6/.pi/agent/scripts"
: >"$H6/.pi/agent/scripts/tortoise-graph.sh"; : >"$H6/.pi/agent/scripts/tortoise_graph_client.py"
printf 'trap "exit 1" EXIT\nexport TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E6"
HOME="$H6" ENV_FILE="$E6" run_case trapexit >"$TMP/trapexit.stdout" 2>"$TMP/trapexit.err"
expect trapexit "graph credential: TORTOISE_MCP_API_KEY is set in"
clean trapexit

# ── case 7: the file exists but is unreadable — UNKNOWN, never "neither key is set" ──────────────
H7="$TMP/h7"; E7="$TMP/h7/keys.env"
mkdir -p "$H7/.pi/agent/scripts"
: >"$H7/.pi/agent/scripts/tortoise-graph.sh"; : >"$H7/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E7"
chmod 000 "$E7"
ROOT_UNREADABLE=0
[ "$(id -u)" = "0" ] && ROOT_UNREADABLE=1
HOME="$H7" ENV_FILE="$E7" run_case unreadable >"$TMP/unreadable.stdout" 2>"$TMP/unreadable.err"
chmod 644 "$E7"
if [ "$ROOT_UNREADABLE" -eq 1 ]; then
    # root reads a mode-000 file, so this arm cannot reproduce "unreadable" here: say so instead of
    # asserting a state the environment cannot produce (a false RED on every cell, which runs as root).
    echo "note: case \`unreadable\` skipped — running as uid 0, where mode 000 is still readable"
else
    expect unreadable "graph credential UNKNOWN"
    expect_absent unreadable "graph credential MISSING"
    clean unreadable
fi

# ── case 8: the key is in THIS SHELL but not in the file — a lane still has none ──────────
# (this arm and the two below also make case 12's leak assertion NON-VACUOUS: with no ambient value,
# a check that echoed the environment's key would echo an empty string and pass.)
H9="$TMP/h9"; E9="$TMP/h9/keys.env"
mkdir -p "$H9/.pi/agent/scripts"
: >"$H9/.pi/agent/scripts/tortoise-graph.sh"; : >"$H9/.pi/agent/scripts/tortoise_graph_client.py"
printf 'NOTHING=1\n' >"$E9"
TORTOISE_MCP_API_KEY="$SECRET" HOME="$H9" ENV_FILE="$E9" run_case ambient_mcp >"$TMP/ambient_mcp.stdout" 2>"$TMP/ambient_mcp.err"
expect ambient_mcp "graph credential NOT REACHING LANES"
expect_absent ambient_mcp "$SECRET"
clean ambient_mcp

# ── case 9: the REST key ambient, nothing in the file — UNCERTAIN, never ok ────────────────
H10="$TMP/h10"; E10="$TMP/h10/keys.env"
mkdir -p "$H10/.pi/agent/scripts"
: >"$H10/.pi/agent/scripts/tortoise-graph.sh"; : >"$H10/.pi/agent/scripts/tortoise_graph_client.py"
printf 'NOTHING=1\n' >"$E10"
TORTOISE_API_KEY="$SECRET" HOME="$H10" ENV_FILE="$E10" run_case ambient_rest >"$TMP/ambient_rest.stdout" 2>"$TMP/ambient_rest.err"
expect ambient_rest "graph credential UNCERTAIN"
expect_absent ambient_rest "graph credential: TORTOISE_MCP_API_KEY is set"
expect_absent ambient_rest "$SECRET"
clean ambient_rest

# ── case 10: the file carries the key AND the shell does too — the ok line must not echo it ───
# This is the shape a real cell has (`check_provider` sources keys.env into the bring-up shell), so it
# is the case in which a `printf %s "$TORTOISE_MCP_API_KEY"` inside the ok line would actually leak.
H11="$TMP/h11"; E11="$TMP/h11/keys.env"
mkdir -p "$H11/.pi/agent/scripts"
: >"$H11/.pi/agent/scripts/tortoise-graph.sh"; : >"$H11/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E11"
TORTOISE_MCP_API_KEY="$SECRET" HOME="$H11" ENV_FILE="$E11" run_case both >"$TMP/both.stdout" 2>"$TMP/both.err"
expect both "graph credential: TORTOISE_MCP_API_KEY is set in"
expect_absent both "$SECRET"
clean both

# ── case 11: THE WIRING — the reading must still be CALLED by `--check`, after the layer and the env
# This probe sources the function body directly, so deleting the invocation in `main()` would leave every
# arm above green while the cell stops reporting the client at all. `pi-bootstrap/tests/test-setup-no-nesting.sh`
# names the same gap for its own suites ("a probe set alone cannot see the wiring") and proves it with a
# sentinel; this is that assertion for this check. The ORDER matters as much as the presence: `check_graph_client`
# must run AFTER `check_operational_layer` (which installs/verifies the farm) and AFTER `check_provider`
# (which sources `$ENV_FILE`), or it grades an empty farm and an unsourced environment.
main_body="$(sed -n '/^main() {$/,/^}$/p' "$SRC")"
if grep -q '^      check_graph_client$' <<<"$main_body"; then pass; else
    fail "wiring: \`check_graph_client\` is not invoked from main()'s --check arm — the reading would never run"
fi
order_ok=1
for before in check_operational_layer check_provider check_uv_env; do
    a="$(printf '%s\n' "$main_body" | grep -n "^      $before\$" | head -1 | cut -d: -f1)"
    b="$(printf '%s\n' "$main_body" | grep -n '^      check_graph_client$' | head -1 | cut -d: -f1)"
    if [ -z "$a" ] || [ -z "$b" ] || [ "$a" -ge "$b" ]; then order_ok=0; fi
done
if [ "$order_ok" -eq 1 ]; then pass; else
    fail "wiring: \`check_graph_client\` is not ordered AFTER check_operational_layer/check_provider/check_uv_env in main()"
fi

# ── case 12: THE RULE — the key's value never appears, in any arm ─────────────────────────────────
# ⛔ SCANNED: the stub transcript, the case's REAL STDOUT, and its STDERR. The first version scanned
# only "$TMP"/*.out — the `ok`/`warn` transcript — so a check that printed the value with `echo`/`printf`
# went straight to the suite's own stdout and the suite still reported 43/43 passed (measured
# 2026-11-03). The rule is about what an OPERATOR ends up pasting into an issue, so the sweep covers
# every stream the check can write to, not the one this harness happens to capture.
leaked=0
for f in "$TMP"/*.out "$TMP"/*.stdout "$TMP"/*.err; do
    [ -s "$f" ] || continue
    if grep -qF -- "$SECRET" "$f"; then
        fail "credential leak: $(basename "$f") contains the key's VALUE — this output is captured, mailed and pasted into issues"
        leaked=1
    fi
done
[ "$leaked" -eq 0 ] && pass
# ⛔ THE SWEEP'S OWN SELF-TEST — and the first version of this block was not one. It re-ran a narrower
# copy of the leak grep and printed "not vacuous", which measures nothing: a scan that finds nothing
# because nothing ever entered the log is indistinguishable from a scan that finds nothing because the
# value never leaked (the round-4 P1, one layer down). This plants the sentinel in a throwaway file and
# requires the SAME scan to flag it, so "clean" is a measurement rather than an empty set.
printf 'planted %s\n' "$SECRET" >"$TMP/self_test.stdout"
if grep -qF -- "$SECRET" "$TMP"/*.stdout "$TMP"/*.err "$TMP"/*.out; then pass; else
    fail "self-test: the leak scan did not flag a file that provably contains the value — the clean result above is an empty set, not a measurement"
fi
rm -f "$TMP/self_test.stdout"

# ⛔ NO SUCCESS PREFIX ON A RED RUN. `ok: ... FAILURES: 3` is a line a log-grepper reads as a pass; the
# sibling suites print a bare `FAILURES:` line instead, and `cell-install.sh` states the rule.
if [ "$FAILURES" -eq 0 ]; then
    echo "ok: $OKS assertion(s) passed"
else
    echo "FAILURES: $FAILURES of $((OKS + FAILURES)) assertion(s)"
    exit 1
fi
exit 0
