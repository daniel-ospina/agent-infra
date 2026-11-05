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
# THE NON-VACUITY FLOOR: the extraction must produce a non-empty function that PARSES, or the suite
# stops here with rc=1. Without it a probe that silently extracted nothing would report every later arm
# as a missing-string failure, which reads as "the fix is broken" instead of "the probe is broken".
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
# ⛔ HERMETIC. This suite reads the SAME two variables the check does, and a provisioned box EXPORTS them
# (`pi-bootstrap/setup.sh` wires `~/pi-keys.env` into the profile; a cell's `~/keys.env` is sourced by
# `worker-terminal.sh` under `set -a`). Without this scrub the suite reported a FALSE RED on exactly the
# boxes this PR provisions — `absent: expected [graph credential MISSING]` — while CI stayed green because
# no workflow exports them (measured 2026-11-03 on a copy). Cases 8/9/10 opt back in through
# RUN_CASE_KEEP_ENV, which is the only way an ambient value reaches a case.
run_case() {
    OUT=""
    if [ "${RUN_CASE_KEEP_ENV:-0}" != "1" ]; then
        unset TORTOISE_MCP_API_KEY TORTOISE_API_KEY
    fi
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
expect good "only once this box's checkout declares it in"
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
# a client that is not there has no SIBLING: "half-delivered" is a partial-farm diagnosis, and a box
# where nothing was farmed must not be told a farm half-ran.
expect_absent absent "beside it"
expect_absent absent "HALF-DELIVERED"
# the reading must not claim an ABSENT client's exit code (round 7), and the replacement is pinned the
# same way the `ok` scope words are — otherwise the old sentence can come back silently.
expect absent "with the client in place"
expect_absent absent "client exits 3"
clean absent

# ── case 3: a PY-ONLY box — the sibling is there, the client is not. This is the shape the
# `absent` case cannot produce (there BOTH are missing, so the pre-fix code printed HALF-DELIVERED and
# never the green `ok … beside it`). Measured 2026-11-03: with the sibling probe ungated, this box
# printed `warn: graph client MISSING` followed by `ok: … tortoise_graph_client.py beside it`.
H2b="$TMP/h2b"; E2b="$TMP/h2b/keys.env"
mkdir -p "$H2b/.pi/agent/scripts"
: >"$H2b/.pi/agent/scripts/tortoise_graph_client.py"
printf 'NOTHING=1\n' >"$E2b"
HOME="$H2b" ENV_FILE="$E2b" run_case pyonly >"$TMP/pyonly.stdout" 2>"$TMP/pyonly.err"
expect pyonly "graph client MISSING:"
expect_absent pyonly "beside it"
expect_absent pyonly "HALF-DELIVERED"
clean pyonly

# ── case 4: half-delivered — the .sh without its sibling dies on the first call ──────────────────
H3="$TMP/h3"; E3="$TMP/h3/keys.env"
mkdir -p "$H3/.pi/agent/scripts"
: >"$H3/.pi/agent/scripts/tortoise-graph.sh"
printf 'export TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E3"
HOME="$H3" ENV_FILE="$E3" run_case half >"$TMP/half.stdout" 2>"$TMP/half.err"
expect half "graph client: present at"
expect half "HALF-DELIVERED"
clean half

# ── case 5: the REST key only — a warn, never an ok (an `ok` here is the false-PASS shape) ───────
H4="$TMP/h4"; E4="$TMP/h4/keys.env"
mkdir -p "$H4/.pi/agent/scripts"
: >"$H4/.pi/agent/scripts/tortoise-graph.sh"; : >"$H4/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_API_KEY=%s\n' "$SECRET" >"$E4"
HOME="$H4" ENV_FILE="$E4" run_case rest >"$TMP/rest.stdout" 2>"$TMP/rest.err"
expect rest "graph credential UNCERTAIN"
expect_absent rest "graph credential: TORTOISE_MCP_API_KEY is set"
clean rest

# ── case 6: a keys.env with an early `exit 0` — the sentinel must catch it ────────────────────────
H5="$TMP/h5"; E5="$TMP/h5/keys.env"
mkdir -p "$H5/.pi/agent/scripts"
: >"$H5/.pi/agent/scripts/tortoise-graph.sh"; : >"$H5/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_MCP_API_KEY=%s\nexit 0\n' "$SECRET" >"$E5"
HOME="$H5" ENV_FILE="$E5" run_case earlyexit >"$TMP/earlyexit.stdout" 2>"$TMP/earlyexit.err"
expect_absent earlyexit "TORTOISE_MCP_API_KEY is set in"
clean earlyexit

# ── case 7: a keys.env with `trap "exit 1" EXIT` — the captured sentinel survives pipefail ───────
H6="$TMP/h6"; E6="$TMP/h6/keys.env"
mkdir -p "$H6/.pi/agent/scripts"
: >"$H6/.pi/agent/scripts/tortoise-graph.sh"; : >"$H6/.pi/agent/scripts/tortoise_graph_client.py"
printf 'trap "exit 1" EXIT\nexport TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E6"
HOME="$H6" ENV_FILE="$E6" run_case trapexit >"$TMP/trapexit.stdout" 2>"$TMP/trapexit.err"
expect trapexit "graph credential: TORTOISE_MCP_API_KEY is set in"
clean trapexit

# ── case 8: the file exists but is unreadable — UNKNOWN, never "neither key is set" ──────────────
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

# ── case 9: the key is in THIS SHELL but not in the file — a lane still has none ──────────
# (this arm and the two below also make case 12's leak assertion NON-VACUOUS: with no ambient value,
# a check that echoed the environment's key would echo an empty string and pass.)
H8="$TMP/h8"; E8="$TMP/h8/keys.env"
mkdir -p "$H8/.pi/agent/scripts"
: >"$H8/.pi/agent/scripts/tortoise-graph.sh"; : >"$H8/.pi/agent/scripts/tortoise_graph_client.py"
printf 'NOTHING=1\n' >"$E8"
RUN_CASE_KEEP_ENV=1 TORTOISE_MCP_API_KEY="$SECRET" HOME="$H8" ENV_FILE="$E8" run_case ambient_mcp >"$TMP/ambient_mcp.stdout" 2>"$TMP/ambient_mcp.err"
expect ambient_mcp "graph credential NOT REACHING LANES"
# ⛔ THE SIBLING ARMS PIN THIS ABSENCE AND THIS ONE MUST TOO: an ambient-only key is NOT provisioned
# for a lane (the lane environment comes from the file), so an `ok: graph credential: … is set` here
# would be the exact false PASS this function's comment names — and, unasserted, nothing would red.
expect_absent ambient_mcp "graph credential: TORTOISE_MCP_API_KEY is set"
expect_absent ambient_mcp "$SECRET"
clean ambient_mcp

# ── case 10: the REST key ambient, nothing in the file — UNCERTAIN, never ok ────────────────
H9="$TMP/h9"; E9="$TMP/h9/keys.env"
mkdir -p "$H9/.pi/agent/scripts"
: >"$H9/.pi/agent/scripts/tortoise-graph.sh"; : >"$H9/.pi/agent/scripts/tortoise_graph_client.py"
printf 'NOTHING=1\n' >"$E9"
RUN_CASE_KEEP_ENV=1 TORTOISE_API_KEY="$SECRET" HOME="$H9" ENV_FILE="$E9" run_case ambient_rest >"$TMP/ambient_rest.stdout" 2>"$TMP/ambient_rest.err"
expect ambient_rest "graph credential UNCERTAIN"
expect_absent ambient_rest "graph credential: TORTOISE_MCP_API_KEY is set"
expect_absent ambient_rest "$SECRET"
clean ambient_rest

# ── case 11: the file carries the key AND the shell does too — the ok line must not echo it ───
# This is the shape a real cell has (`check_provider` sources keys.env into the bring-up shell), so it
# is the case in which a `printf %s "$TORTOISE_MCP_API_KEY"` inside the ok line would actually leak.
H10="$TMP/h10"; E10="$TMP/h10/keys.env"
mkdir -p "$H10/.pi/agent/scripts"
: >"$H10/.pi/agent/scripts/tortoise-graph.sh"; : >"$H10/.pi/agent/scripts/tortoise_graph_client.py"
printf 'export TORTOISE_MCP_API_KEY=%s\n' "$SECRET" >"$E10"
RUN_CASE_KEEP_ENV=1 TORTOISE_MCP_API_KEY="$SECRET" HOME="$H10" ENV_FILE="$E10" run_case both >"$TMP/both.stdout" 2>"$TMP/both.err"
expect both "graph credential: TORTOISE_MCP_API_KEY is set in"
expect_absent both "$SECRET"
clean both

# ── case 12: THE WIRING — the reading must still be CALLED by `--check`, after the layer and the env
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

# ── case 13: THE RULE — the key's value never appears, in any arm ─────────────────────────────────
# ⛔ ONE SCAN, USED TWICE. The rule is about what an OPERATOR ends up pasting into an issue, so the
# sweep covers every stream the check can write to — the stub transcript AND the case's real stdout and
# stderr. The first version scanned only "$TMP"/*.out (a `printf` leak in the check went straight to the
# suite's own stdout, 43/43 green), and the SECOND version's "self-test" was a separate grep that never
# exercised the loop at all: deleting the loop, or narrowing it back to *.out, left the suite green while
# the value sat in a case file (both measured 2026-11-03). So the scan is a FUNCTION, both uses call it,
# and the self-test asserts the REAL arm's own output — a lost or narrowed arm is loud, not quiet.
LEAK_FILES=()
leak_scan() { # <file>... → fills LEAK_FILES with every file carrying the value; rc 0 when any does
    LEAK_FILES=()
    local f
    for f in "$@"; do
        [ -s "$f" ] || continue
        grep -qF -- "$SECRET" "$f" && LEAK_FILES+=("$f")
    done
    [ "${#LEAK_FILES[@]}" -gt 0 ]
}

# ⛔ THE FILE SET IS ENUMERATED, NOT GLOBBED. A glob (`"$TMP"/*.stdout`) cannot be asserted from inside:
# narrowing it back to `"$TMP"/*.out` is the round-4 defect exactly, and with a real `printf` leak in the
# check the suite still reported 50/50 green (measured 2026-11-03) — the narrowed set simply never looked
# at the file the value landed in. So the cases are NAMED and every stream of every case is scanned; the
# floor then asserts the enumeration produced a plausible population, which a narrowed list would shrink.
CASES="good absent pyonly half rest earlyexit trapexit unreadable ambient_mcp ambient_rest both"
SCAN_FILES=()
for c in $CASES; do
    SCAN_FILES+=("$TMP/$c.out" "$TMP/$c.stdout" "$TMP/$c.err")
done
# ⛔ COVERAGE, NOT A COUNT. A total of 30 is satisfied by enumerating 10 cases × `out,err,out` — the
# transcript twice and no stdout — which is a plausible slip and defeats the whole rule (measured
# 2026-11-03: 51/51 green with the value sitting in `ambient_mcp.stdout`). So each case must contribute
# each of its THREE streams by name.
missing_streams=""
for c in $CASES; do
    for st in out stdout err; do
        found=0
        for f in "${SCAN_FILES[@]}"; do [ "$f" = "$TMP/$c.$st" ] && { found=1; break; }; done
        [ "$found" -eq 1 ] || missing_streams="${missing_streams} $c.$st"
    done
done
if [ -z "$missing_streams" ]; then pass; else
    fail "leak sweep: the enumeration does not cover these stream(s):$missing_streams — a stream that is never scanned cannot report a leak"
fi
missing=0
for c in $CASES; do [ -s "$TMP/$c.out" ] || missing=$((missing + 1)); done
if [ "$missing" -eq 0 ]; then pass; else
    fail "leak sweep: $missing case(s) produced no transcript — those arms did not run"
fi

if leak_scan "${SCAN_FILES[@]}"; then
    fail "credential leak: the key's VALUE appears in —"$'\n'"$(printf '%s\n' "${LEAK_FILES[@]}" | sed 's/^/    /')"
else pass; fi

# ⛔ THE SELF-TEST RUNS THE REAL CALL, NOT A STAND-IN. Round 7 pinned the enumeration's contents and
# left the CALL unpinned: `leak_scan "$TMP"/*.out` instead of `leak_scan "${SCAN_FILES[@]}"` passed
# 53/53 while a `printf` leak sat in `<case>.stdout` (measured 2026-11-03). So: plant the value in a
# REAL case stream, re-run the SAME invocation the sweep uses, require LEAK_FILES to name that file,
# then restore it. And assert the call site itself, so narrowing it reds by name.
# Both call sites must pass the enumerated list — the sweep AND this self-test. A count is used rather
# than a presence test because the two lines are textually identical: grepping for the invocation once is
# satisfied by whichever site survived, which is exactly how a narrowed sweep passed 53/53.
# ⛔ ANCHORED AND DID-FREE: a plain `grep -cF` for the invocation counts its OWN source line (and the
# prose that quotes it) — measured 2026-11-03: 4 matches with only 2 call sites, so a narrowed sweep
# stayed green at `>= 2`. Anchoring to line-start matches exactly the two `if leak_scan ...` statements.
leak_calls="$(grep -cE '^if leak_scan "\$\{SCAN_FILES\[@\]}"; then' "$0")"
if [ "${leak_calls:-0}" -ge 2 ]; then pass; else
    fail "self-test: only ${leak_calls:-0} of 2 leak_scan call site(s) pass the enumerated SCAN_FILES — a narrowed call scans less than the coverage floor below asserts"
fi
cp "$TMP/ambient_mcp.stdout" "$TMP/ambient_mcp.stdout.bak"
printf 'planted %s\n' "$SECRET" >>"$TMP/ambient_mcp.stdout"
if leak_scan "${SCAN_FILES[@]}"; then
    case " ${LEAK_FILES[*]} " in
        *"$TMP/ambient_mcp.stdout"*) pass ;;
        *) fail "self-test: the real sweep did not name $TMP/ambient_mcp.stdout although it carries the value — it is not scanning that stream" ;;
    esac
else
    fail "self-test: the real sweep found nothing in a case stream that provably carries the value — the clean result above is an empty set, not a measurement"
fi
mv "$TMP/ambient_mcp.stdout.bak" "$TMP/ambient_mcp.stdout"

# THE PATTERN SELF-TEST, against the SAME function (kept as well: it pins the matcher, not the sweep).
printf 'planted %s\n' "$SECRET" >"$TMP/self_test.stdout"
if leak_scan "$TMP/self_test.stdout"; then pass; else
    fail "self-test: leak_scan did not flag a file that provably contains the value — the clean result above is an empty set, not a measurement"
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
