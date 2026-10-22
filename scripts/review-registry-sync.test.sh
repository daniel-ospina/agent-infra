#!/usr/bin/env bash
# review-registry-sync.test.sh — the registry-union contract.
#
# WHAT THIS PINS (and why each one is a data-loss case, not a style preference)
# ---------------------------------------------------------------------------
#  §1 pull copies every record byte-identically (a re-serialized record would drop `sig=` markers)
#  §2 pull is IDEMPOTENT — a second run changes nothing (a union that churns cannot be diffed)
#  §3 push restores a record that exists only in the union (the whole point: a PR reviewed on
#     another box becomes mergeable here)
#  §4 a NEWER record is never overwritten by an older one (the union must never travel backwards)
#  §5 a newer record IS adopted (staleness is not safety)
#  §6 equal `reviewed_at` + differing bytes → CONFLICT, exit 1, target untouched, source preserved
#  §7 ORDER IS NEVER GUESSED: a differing pair where either side has no usable clock (absent,
#     non-ISO, or NAIVE — no UTC offset, which would be read in the box's local zone) is a CONFLICT
#     (target untouched, source preserved, exit 1) in BOTH directions. Also pins the CARRY tiebreak at
#     an equal `reviewed_at` (a carried re-mint supersedes the record it was carried from).
#  §8 the same KEY with a different embedded `repo` → COLLISION (the enforcer's #426 cross-check
#     fails closed on it), exit 1, target untouched, source preserved
#  §9 the two key shapes never collapse: `<pr>.json` and `<owner>-<name>-<pr>.json` for the SAME PR
#     number both survive (measured on a real box: PR 900201 carried three repos' records)
# §10 an unparseable record is never adopted and never deleted
# §11 nothing is ever deleted — the registry's file set only grows
# §12 `status` reports a union record the registry lacks, and exits 1 (not converged)
# §13 `--dry-run` changes nothing on disk
# §14 a held lock makes a second sync exit 3 (UNKNOWN) — never a silent second writer
#
# Hermetic: every case builds its own temp registry/union under mktemp -d. No real registry, no
# network, no gh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/review-registry-sync.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/regsync-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

[ -x "$TOOL" ] || { echo "FAIL: $TOOL is not executable"; exit 1; }

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────
mkrec() { # mkrec <path> <pr> <head> <verdict> <repo-or-empty> <reviewed_at-or-empty>
  python3 - "$@" <<'PY'
import json, sys
path, pr, head, verdict, repo, ra = sys.argv[1:7]
d = {"pr": int(pr), "head_sha": head, "verdict": verdict}
if repo:
    d["repo"] = repo
if ra:
    d["reviewed_at"] = ra
open(path, "w").write(json.dumps(d))
PY
}

H40=1111111111111111111111111111111111111111
REG="$TMP/reg"; UNION="$TMP/union"; mkdir -p "$REG"
mkrec "$REG/1550.json"          1550 "$H40" clean daniel-ospina/tortoise 2026-08-20T13:47:35Z
mkrec "$REG/daniel-ospina-tortoise-2314.json" 2314 "$H40" clean daniel-ospina/tortoise 2026-10-01T00:00:00Z
mkrec "$REG/1784.json"          1784 "$H40" clean daniel-ospina/tortoise 2026-08-27T07:44:20Z
mkrec "$REG/daniel-ospina-agent-infra-1784.json" 1784 "$H40" clean daniel-ospina/agent-infra 2026-10-16T00:44:53Z

run() { python3 "$TOOL" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

# ⛔ THE CAS-LOSS ARMS ARE DRIVEN IN-PROCESS, NOT BY AN ENV FLAG IN THE TOOL (review cycle 4: an env
# seam was production-live — any ambient variable changed real behaviour, and the race variant wrote
# caller-supplied bytes into the live registry). This driver imports the module and replaces
# `atomic_write` for the duration of ONE run, so the shipping script has no test hook at all.
cat > "$TMP/casdriver.py" <<'DRIVER'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("rrs", os.environ["RRS_TOOL"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
state = {"n": int(os.environ.get("RRS_LOSE", "0"))}
race = os.environ.get("RRS_RACE")                     # file whose bytes simulate the concurrent mint
real = m.atomic_write
def fake(dst, raw, expect, retries=5):
    if state["n"] > 0:
        state["n"] -= 1
        if race:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(open(race).read())
        return False
    return real(dst, raw, expect, retries)
m.atomic_write = fake
sys.exit(m.main(sys.argv[1:]))
DRIVER
run_cas() { # run_cas <lose-n> <race-file-or-empty> <args...>
  local lose="$1" race="$2"; shift 2
  RRS_TOOL="$TOOL" RRS_LOSE="$lose" RRS_RACE="$race" python3 "$TMP/casdriver.py" "$@" >"$TMP/out" 2>"$TMP/err"
  echo $?
}

echo "== §1 pull copies every record byte-identically"
rc=$(run pull --registry "$REG" --union "$UNION")
check "exit 0" "[ $rc -eq 0 ]"
check "union has 4 records" "[ $(ls "$UNION"/*.json 2>/dev/null | wc -l) -eq 4 ]"
check "bytes identical for every key" "for f in '$REG'/*.json; do cmp -s \"\$f\" '$UNION'/\"\$(basename \"\$f\")\" || exit 1; done"

echo "== §2 pull is idempotent"
rc=$(run pull --registry "$REG" --union "$UNION")
check "second pull exits 0" "[ $rc -eq 0 ]"
check "second pull changed nothing" "grep -q '0 changed (0 added, 0 replaced)' '$TMP/out'"

echo "== §3 push restores a record that exists only in the union"
rm -f "$REG/1550.json"
rc=$(run push --registry "$REG" --union "$UNION")
check "exit 0" "[ $rc -eq 0 ]"
check "1550.json is back" "[ -f '$REG/1550.json' ]"
check "restored byte-identically" "cmp -s '$REG/1550.json' '$UNION/1550.json'"

echo "== §4 a newer target is never overwritten by an older source"
mkrec "$UNION/1784.json" 1784 "$H40" STALE-OLDER daniel-ospina/tortoise 2026-01-01T00:00:00Z
rc=$(run push --registry "$REG" --union "$UNION")
check "exit 0" "[ $rc -eq 0 ]"
check "registry verdict unchanged (clean, not STALE-OLDER)" \
  "python3 -c \"import json;assert json.load(open('$REG/1784.json'))['verdict']=='clean'\""

echo "== §5 a newer source IS adopted"
mkrec "$UNION/daniel-ospina-tortoise-2314.json" 2314 "$H40" NEWER-ADOPTED daniel-ospina/tortoise 2027-01-01T00:00:00Z
rc=$(run push --registry "$REG" --union "$UNION")
check "exit 0" "[ $rc -eq 0 ]"
check "registry adopted the newer verdict" \
  "python3 -c \"import json;assert json.load(open('$REG/daniel-ospina-tortoise-2314.json'))['verdict']=='NEWER-ADOPTED'\""

echo "== §6 equal reviewed_at + differing bytes → CONFLICT, target untouched, source preserved"
mkrec "$UNION/1550.json" 1550 "$H40" DIFFERENT-AT-SAME-TIME daniel-ospina/tortoise 2026-08-20T13:47:35Z
before="$(sha256sum "$REG/1550.json" | cut -d' ' -f1)"
rc=$(run push --registry "$REG" --union "$UNION")
check "exit 1 (needs a human)" "[ $rc -eq 1 ]"
check "target bytes untouched" "[ \"\$(sha256sum '$REG/1550.json' | cut -d' ' -f1)\" = '$before' ]"
check "source preserved under union/conflicts/" "[ -n \"\$(ls '$UNION/conflicts/'*1550* 2>/dev/null)\" ]"
cp "$UNION/1550.json" "$TMP/1550.dq"; mkrec "$UNION/1550.json" 1550 "$H40" clean daniel-ospina/tortoise 2026-08-20T13:47:35Z  # restore fixture

echo "== §7 order is never guessed: absent / non-ISO / NAIVE clock ⇒ CONFLICT, never a replacement"
# NB: repo-QUALIFIED keys throughout, so the repo-identity rule (§8/#P0) cannot be what fails here —
# this section must discriminate the CLOCK branch on its own (review cycle 2: the old fixture collided
# first and stayed green with the clock rule deleted).
mkdir -p "$TMP/reg7" "$TMP/uni7"
# (i) dateless SOURCE vs dated target — the union's copy is newer in wall-clock terms but cannot be ordered
mkrec "$TMP/reg7/daniel-ospina-tortoise-7001.json" 7001 "$H40" TARGET-DATED daniel-ospina/tortoise 2026-05-01T00:00:00Z
mkrec "$TMP/uni7/daniel-ospina-tortoise-7001.json" 7001 "$H40" SOURCE-DATELESS daniel-ospina/tortoise ""
rc=$(run push --registry "$TMP/reg7" --union "$TMP/uni7")
check "dateless source vs dated target → exit 1" "[ $rc -eq 1 ]"
check "dated target untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg7/daniel-ospina-tortoise-7001.json'))['verdict']=='TARGET-DATED'\""
# (ii) dated SOURCE vs dateless target — must NOT be resolved in the traveller's favour either
mkrec "$TMP/reg7/daniel-ospina-tortoise-7002.json" 7002 "$H40" TARGET-DATELESS daniel-ospina/tortoise ""
mkrec "$TMP/uni7/daniel-ospina-tortoise-7002.json" 7002 "$H40" SOURCE-DATED daniel-ospina/tortoise 2026-01-01T00:00:00Z
rc=$(run push --registry "$TMP/reg7" --union "$TMP/uni7")
check "dateless target vs dated source → exit 1" "[ $rc -eq 1 ]"
check "dateless target untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg7/daniel-ospina-tortoise-7002.json'))['verdict']=='TARGET-DATELESS'\""
# (iii) a NAIVE stamp would be ordered in the box's LOCAL zone, so it is not a clock either
mkrec "$TMP/reg7/daniel-ospina-tortoise-7003.json" 7003 "$H40" TARGET-AWARE daniel-ospina/tortoise 2026-10-22T03:00:00Z
python3 -c "import json;open('$TMP/uni7/daniel-ospina-tortoise-7003.json','w').write(json.dumps({'pr':7003,'head_sha':'$H40','verdict':'SOURCE-NAIVE','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22 01:00:00'}))"
rc=$(run push --registry "$TMP/reg7" --union "$TMP/uni7")
check "naive (no-offset) source → exit 1, no local-zone guess" "[ $rc -eq 1 ]"
check "aware target untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg7/daniel-ospina-tortoise-7003.json'))['verdict']=='TARGET-AWARE'\""
# (iv) EQUAL reviewed_at with a CARRY marker must NOT deadlock: the carried re-mint supersedes
mkrec "$TMP/reg7/daniel-ospina-tortoise-7004.json" 7004 "$H40" PRE-CARRY daniel-ospina/tortoise 2026-10-22T03:35:39Z
python3 -c "import json;open('$TMP/uni7/daniel-ospina-tortoise-7004.json','w').write(json.dumps({'pr':7004,'head_sha':'2'*40,'verdict':'CARRIED','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22T03:35:39Z','mint':'carried','carried_at':'2026-10-22T04:00:00Z','carried_from':'$H40'}))"
rc=$(run push --registry "$TMP/reg7" --union "$TMP/uni7")
check "carried re-mint at an equal reviewed_at is adopted" \
  "python3 -c \"import json;d=json.load(open('$TMP/reg7/daniel-ospina-tortoise-7004.json'));assert d['verdict']=='CARRIED',d\""
check "and the run converged on that key (not a permanent conflict)" "! grep -q 'daniel-ospina-tortoise-7004.json.*CONFLICT' '$TMP/out'"

echo "== §8 same key, different repo → COLLISION (never an overwrite), source preserved"
mkdir -p "$TMP/reg8" "$TMP/uni8"
mkrec "$TMP/reg8/1784.json" 1784 "$H40" clean daniel-ospina/tortoise 2026-08-27T07:44:20Z
mkrec "$TMP/uni8/1784.json"  1784 "$H40" clean daniel-ospina/DMeer    2027-06-01T00:00:00Z
rc=$(run push --registry "$TMP/reg8" --union "$TMP/uni8")
check "exit 1" "[ $rc -eq 1 ]"
check "registry still says tortoise" \
  "python3 -c \"import json;assert json.load(open('$TMP/reg8/1784.json'))['repo']=='daniel-ospina/tortoise'\""
check "collision preserved" "[ -n \"\$(ls '$TMP/uni8/conflicts/'*1784* 2>/dev/null)\" ]"

echo "== §9 key shapes never collapse (one PR number, several repos)"
mkdir -p "$TMP/reg9" "$TMP/uni9"
mkrec "$TMP/reg9/900201.json" 900201 "$H40" clean daniel-ospina/tortoise ""
mkrec "$TMP/uni9/daniel-ospina-DMeer-900201.json" 900201 "$H40" clean daniel-ospina/DMeer ""
mkrec "$TMP/uni9/premise-labs-foo-900201.json"    900201 "$H40" clean premise-labs/foo ""
rc=$(run sync --registry "$TMP/reg9" --union "$TMP/uni9")
check "all three keys coexist" "[ \$(ls \"$TMP/reg9\"/*900201*.json | wc -l) -eq 3 ]"
check "value-keyed record still tortoise" \
  "python3 -c \"import json;assert json.load(open('$TMP/reg9/900201.json'))['repo']=='daniel-ospina/tortoise'\""

echo "== §10 an unparseable record is never adopted, never deleted"
mkdir -p "$TMP/reg10" "$TMP/uni10"
printf '{"pr":9999,"head_sha":"abc' > "$TMP/uni10/9999.json"
rc=$(run push --registry "$TMP/reg10" --union "$TMP/uni10")
check "exit 1" "[ $rc -eq 1 ]"
check "not adopted" "[ ! -f '$TMP/reg10/9999.json' ]"
check "source not deleted" "[ -f '$TMP/uni10/9999.json' ]"

echo "== §11 nothing is ever deleted"
mkdir -p "$TMP/reg11" "$TMP/uni11"
mkrec "$TMP/reg11/1.json" 1 "$H40" clean "" 2026-01-01T00:00:00Z
mkrec "$TMP/reg11/2.json" 2 "$H40" clean "" 2026-01-01T00:00:00Z
mkrec "$TMP/uni11/3.json" 3 "$H40" clean "" 2026-01-01T00:00:00Z
rc=$(run sync --registry "$TMP/reg11" --union "$TMP/uni11")
check "registry keeps 1,2 and gains 3" "for k in 1 2 3; do [ -f \"$TMP/reg11/\$k.json\" ] || exit 1; done"
check "union keeps 3 and gains 1,2" "for k in 1 2 3; do [ -f \"$TMP/uni11/\$k.json\" ] || exit 1; done"

echo "== §12 status reports an unpublished union record"
mkdir -p "$TMP/reg12" "$TMP/uni12"
mkrec "$TMP/reg12/1.json" 1 "$H40" clean "" 2026-01-01T00:00:00Z
mkrec "$TMP/uni12/2.json" 2 "$H40" clean "" 2026-01-01T00:00:00Z
rc=$(run status --registry "$TMP/reg12" --union "$TMP/uni12")
check "exit 1 (registry is behind the union)" "[ $rc -eq 1 ]"
check "names the union-only record" "grep -q '2.json' '$TMP/out'"

echo "== §13 --dry-run changes nothing"
before="$(ls "$TMP/reg12" | wc -l)"
rc=$(run push --registry "$TMP/reg12" --union "$TMP/uni12" --dry-run)
check "exit 0" "[ $rc -eq 0 ]"
check "registry unchanged" "[ \$(ls '$TMP/reg12' | wc -l) -eq $before ]"
check "still reports the would-be add" "grep -q 'ADD *2.json' '$TMP/out'"

echo "== §14 a held lock makes a second writer exit 3 (UNKNOWN)"
mkdir -p "$TMP/uni14"
python3 - "$TMP/uni14/.sync.lock" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "w"); fcntl.flock(fh, fcntl.LOCK_EX); time.sleep(3); fh.close()
PY
HOLDER=$!
sleep 0.6
rc=$(run pull --registry "$REG" --union "$TMP/uni14")
wait "$HOLDER" 2>/dev/null
check "exit 3" "[ $rc -eq 3 ]"
check "says it is not a pass" "grep -q 'not a pass' '$TMP/err'"

echo "== §15 a non-ISO reviewed_at is VALID evidence with no clock claim (never 'invalid')"
mkdir -p "$TMP/reg15" "$TMP/uni15"
python3 -c "import json;open('$TMP/reg15/1823.json','w').write(json.dumps({'head_sha':'$H40','verdict':'clean','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22 03:35:39 UTC'}))"
python3 -c "import json;open('$TMP/uni15/1823.json','w').write(json.dumps({'head_sha':'$H40','verdict':'clean','repo':'daniel-ospina/tortoise','reviewed_at':'2026-01-01T00:00:00Z'}))"
before_15="$(sha256sum "$TMP/reg15/1823.json" | cut -d' ' -f1)"
rc=$(run push --registry "$TMP/reg15" --union "$TMP/uni15")
check "exit 1 (cannot order → CONFLICT, not a silent loss)" "[ $rc -eq 1 ]"
check "target bytes untouched" "[ \"\$(sha256sum '$TMP/reg15/1823.json' | cut -d' ' -f1)\" = '$before_15' ]"
check "source preserved" "[ -n \"\$(ls '$TMP/uni15/conflicts/'*1823* 2>/dev/null)\" ]"
check "not reported as INVALID" "! grep -q INVALID '$TMP/out'"
rc=$(run pull --registry "$TMP/reg15" --union "$TMP/uni16")
check "a non-ISO-dated record still CROSSES to the union (not parked as invalid)" \
  "python3 -c \"import json;assert json.load(open('$TMP/uni16/1823.json'))['reviewed_at']=='2026-10-22 03:35:39 UTC'\""

echo "== §16 legacy key: repo-named vs repo-less side is a COLLISION, never an overwrite (P0)"
mkdir -p "$TMP/reg16" "$TMP/uni16b"
mkrec "$TMP/reg16/1823.json" 1823 "$H40" clean daniel-ospina/tortoise 2026-08-01T00:00:00Z
mkrec "$TMP/uni16b/1823.json" 1823 "$H40" clean "" 2026-10-01T00:00:00Z
rc=$(run push --registry "$TMP/reg16" --union "$TMP/uni16b")
check "exit 1" "[ $rc -eq 1 ]"
check "the repo-attributed record survives" \
  "python3 -c \"import json;assert json.load(open('$TMP/reg16/1823.json'))['repo']=='daniel-ospina/tortoise'\""
check "the repo-less source is preserved" "[ -n \"\$(ls '$TMP/uni16b/conflicts/'*1823* 2>/dev/null)\" ]"


echo "== §17 status: a registry AHEAD of the union is not converged (either direction exits 1)"
mkdir -p "$TMP/reg17" "$TMP/uni17"
mkrec "$TMP/reg17/1.json" 1 "$H40" clean "" 2026-01-01T00:00:00Z
mkrec "$TMP/reg17/2.json" 2 "$H40" clean "" 2026-01-01T00:00:00Z
rc=$(run status --registry "$TMP/reg17" --union "$TMP/uni17")
check "exit 1 with an EMPTY union" "[ $rc -eq 1 ]"


echo "== §18 an unreadable / uncreatable store is exit 3, never a traceback or a pass"
mkdir -p "$TMP/reg18"
mkrec "$TMP/reg18/1.json" 1 "$H40" clean "" 2026-01-01T00:00:00Z
rc=$(run pull --registry "$TMP/reg18" --union "$TMP/reg18/1.json")
check "--union naming a FILE exits 3" "[ $rc -eq 3 ]"
check "no traceback" "! grep -q Traceback '$TMP/err'"
rc=$(run status --registry "$TMP/does-not-exist" --union "$TMP/reg18")
check "status on a missing registry exits 3" "[ $rc -eq 3 ]"


echo "== §19 a target the gate would read as absent is REPAIRED, not merely overwritten"
mkdir -p "$TMP/reg19" "$TMP/uni19"
printf 'not json at all' > "$TMP/reg19/5.json"
mkrec "$TMP/uni19/5.json" 5 "$H40" clean "" 2026-01-01T00:00:00Z
rc=$(run push --registry "$TMP/reg19" --union "$TMP/uni19")
check "exit 0" "[ $rc -eq 0 ]"
check "the unreadable target is repaired to the valid record" \
  "python3 -c \"import json;assert json.load(open('$TMP/reg19/5.json'))['verdict']=='clean'\""


echo "== §20 --json is machine-readable on stdout (nothing human before it)"
rc=$(run status --registry "$TMP/reg17" --union "$TMP/uni17" --json)
check "exit 1" "[ $rc -eq 1 ]"
check "stdout parses as JSON" "python3 -c \"import json;d=json.load(open('$TMP/out'));assert set(d)>= {'registry','union','only_registry'}\""
rc=$(run push --registry "$TMP/reg17" --union "$TMP/uni17" --json)
check "push --json stdout parses as JSON" "python3 -c \"import json;json.load(open('$TMP/out'))\""


echo "== §21 a record missing head_sha/verdict is never adopted (gate reads it as absent)"
mkdir -p "$TMP/reg21" "$TMP/uni21"
python3 -c "import json;open('$TMP/uni21/6.json','w').write(json.dumps({'pr':6,'verdict':'clean','reviewed_at':'2026-01-01T00:00:00Z'}))"
rc=$(run push --registry "$TMP/reg21" --union "$TMP/uni21")
check "exit 1" "[ $rc -eq 1 ]"
check "not adopted" "[ ! -f '$TMP/reg21/6.json' ]"

echo "== §22 the gate's OWN lexer: a record it would read as absent is never adopted (UTF-16, NaN)"
mkdir -p "$TMP/reg22" "$TMP/uni22"
python3 -c "import json;open('$TMP/reg22/7.json','w').write(json.dumps({'pr':7,'head_sha':'$H40','verdict':'GATE-VISIBLE','reviewed_at':'2026-01-01T00:00:00Z'}))"
python3 -c "import json;open('$TMP/uni22/7.json','wb').write(json.dumps({'pr':7,'head_sha':'$H40','verdict':'UTF16','reviewed_at':'2027-01-01T00:00:00Z'}).encode('utf-16'))"
rc=$(run push --registry "$TMP/reg22" --union "$TMP/uni22")
check "UTF-16 source → exit 1" "[ $rc -eq 1 ]"
check "gate-visible target untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg22/7.json'))['verdict']=='GATE-VISIBLE'\""
printf '{"pr":8,"head_sha":"%s","verdict":"NAN","reviewed_at":NaN}' "$H40" > "$TMP/uni22/8.json"
rc=$(run push --registry "$TMP/reg22" --union "$TMP/uni22")
check "NaN constant → not adopted" "[ ! -f '$TMP/reg22/8.json' ]"

echo "== §23 a LOST write is never counted as changed (CAS seam)"
mkdir -p "$TMP/reg23" "$TMP/uni23"
mkrec "$TMP/uni23/9.json" 9 "$H40" NEW daniel-ospina/tortoise 2027-01-01T00:00:00Z
mkrec "$TMP/reg23/9.json" 9 "$H40" OLD daniel-ospina/tortoise 2020-01-01T00:00:00Z
rc=$(run_cas 2 "" push --registry "$TMP/reg23" --union "$TMP/uni23")
check "both CAS attempts lost → exit 3 (UNKNOWN), never a false convergence" "[ $rc -eq 3 ]"
check "reports 'NOT written'" "grep -q 'NOT written' '$TMP/out'"
check "reports 0 changed" "grep -q '0 changed (0 added, 0 replaced)' '$TMP/out'"
check "target really is unchanged" "python3 -c \"import json;assert json.load(open('$TMP/reg23/9.json'))['verdict']=='OLD'\""
rc=$(run_cas 1 "" push --registry "$TMP/reg23" --union "$TMP/uni23")
check "one lost CAS then a landed retry → adopted" "python3 -c \"import json;assert json.load(open('$TMP/reg23/9.json'))['verdict']=='NEW'\""
check "and counted exactly once" "grep -q '1 changed (0 added, 1 replaced)' '$TMP/out'"

echo "== §24 a CONFLICT discovered at re-decision reaches the exit code and is preserved"
mkdir -p "$TMP/reg24" "$TMP/uni24"
mkrec "$TMP/uni24/10.json" 10 "$H40" SOURCE daniel-ospina/tortoise 2027-01-01T00:00:00Z
python3 -c "import json;open('$TMP/race24.json','w').write(json.dumps({'pr':10,'head_sha':'$H40','verdict':'CONCURRENT-EQUAL-CLOCK','repo':'daniel-ospina/tortoise','reviewed_at':'2027-01-01T00:00:00Z'}))"
rc=$(run_cas 1 "$TMP/race24.json" push --registry "$TMP/reg24" --union "$TMP/uni24")
check "exit 1 (a conflict cannot hide behind 'raced')" "[ $rc -eq 1 ]"
check "the concurrent record is kept" "python3 -c \"import json;assert json.load(open('$TMP/reg24/10.json'))['verdict']=='CONCURRENT-EQUAL-CLOCK'\""
check "the source is preserved" "[ -n \"\$(ls '$TMP/uni24/conflicts/'*10.json* 2>/dev/null)\" ]"

echo "== §25 an unresolvable --union path is a usage error (2), never the conflict code"
rc=$(run push --registry "$TMP/reg23" --union '~nosuchuser/union')
check "exit 2" "[ $rc -eq 2 ]"
check "no traceback" "! grep -q Traceback '$TMP/err'"

echo "== §26 a gate-invisible record is never adopted: repo:null and a bad charset"
mkdir -p "$TMP/reg26" "$TMP/uni26"
mkrec "$TMP/reg26/11.json" 11 "$H40" GATE-VISIBLE daniel-ospina/tortoise 2026-01-01T00:00:00Z
printf '{"pr":11,"head_sha":"%s","verdict":"NULL-REPO","repo":null,"reviewed_at":"2027-01-01T00:00:00Z"}' "$H40" > "$TMP/uni26/11.json"
rc=$(run push --registry "$TMP/reg26" --union "$TMP/uni26")
check "repo:null → exit 1" "[ $rc -eq 1 ]"
check "gate-visible target untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg26/11.json'))['verdict']=='GATE-VISIBLE'\""
printf '{"pr":12,"head_sha":"%s","verdict":"BAD-CHARSET","repo":"not a repo!","reviewed_at":"2027-01-01T00:00:00Z"}' "$H40" > "$TMP/uni26/12.json"
rc=$(run push --registry "$TMP/reg26" --union "$TMP/uni26")
check "bad repo charset → not adopted" "[ ! -f '$TMP/reg26/12.json' ]"

echo "== §27 a repo-qualified key does NOT prove its repo: one-sided attribution is a COLLISION"
# ⛔ `reviewRecordFile` maps `a-b/c-441.json` and `a/b-c-441.json` to the SAME filename, and the
# enforcer's ONLY defence is the embedded `repo` (`index.ts:1573-1577`, `1697-1704`). So a repo-less
# record on a qualified key can answer for a name-colliding peer, and ordering it by clock would
# delete that field (review cycle 4 P1). Attribution disagreement is a collision on EVERY key.
mkdir -p "$TMP/reg27" "$TMP/uni27"
mkrec "$TMP/reg27/daniel-ospina-tortoise-13.json" 13 "$H40" OLD daniel-ospina/tortoise 2026-01-01T00:00:00Z
mkrec "$TMP/uni27/daniel-ospina-tortoise-13.json" 13 "$H40" NEW "" 2027-01-01T00:00:00Z
rc=$(run push --registry "$TMP/reg27" --union "$TMP/uni27")
check "exit 1" "[ $rc -eq 1 ]"
check "the attributed record is untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg27/daniel-ospina-tortoise-13.json'))['verdict']=='OLD'\""
check "the unattributed source is preserved" "[ -n \"\$(ls '$TMP/uni27/conflicts/'*13.json* 2>/dev/null)\" ]"

echo "== §28 carried_at orders an equal clock, but a junk carried_at orders nothing"
mkdir -p "$TMP/reg28" "$TMP/uni28"
python3 -c "import json;open('$TMP/reg28/daniel-ospina-tortoise-14.json','w').write(json.dumps({'pr':14,'head_sha':'$H40','verdict':'PRE','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22T03:35:39Z','mint':'carried','carried_at':'2026-10-22T04:00:00Z'}))"
python3 -c "import json;open('$TMP/uni28/daniel-ospina-tortoise-14.json','w').write(json.dumps({'pr':14,'head_sha':'2'*40,'verdict':'JUNK-CARRIED-AT','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22T03:35:39Z','mint':'carried','carried_at':'zzz'}))"
rc=$(run push --registry "$TMP/reg28" --union "$TMP/uni28")
check "junk carried_at is no ordering evidence → exit 1" "[ $rc -eq 1 ]"
check "the real carried record is untouched" "python3 -c \"import json;assert json.load(open('$TMP/reg28/daniel-ospina-tortoise-14.json'))['verdict']=='PRE'\""

echo "== §29 --json with a NON-EMPTY transfer still emits only JSON"
mkdir -p "$TMP/reg29" "$TMP/uni29"
mkrec "$TMP/uni29/15.json" 15 "$H40" NEW daniel-ospina/tortoise 2027-01-01T00:00:00Z
rc=$(run push --registry "$TMP/reg29" --union "$TMP/uni29" --json)
check "exit 0" "[ $rc -eq 0 ]"
check "stdout is pure JSON (the transfer really added one)" "python3 -c \"import json;d=json.load(open('$TMP/out'));assert d['push']['add']==1,d\""

echo "== §30 status: a DIVERGED same-key pair is not converged"
mkdir -p "$TMP/reg30" "$TMP/uni30"
mkrec "$TMP/reg30/16.json" 16 "$H40" A daniel-ospina/tortoise 2026-01-01T00:00:00Z
mkrec "$TMP/uni30/16.json" 16 "$H40" B daniel-ospina/tortoise 2027-01-01T00:00:00Z
rc=$(run status --registry "$TMP/reg30" --union "$TMP/uni30")
check "exit 1" "[ $rc -eq 1 ]"
check "names the divergence" "grep -q diverged '$TMP/out'"

echo "== §31 a truncated pipe must not rewrite the verdict"
mkdir -p "$TMP/reg31" "$TMP/uni31"
mkrec "$TMP/reg31/17.json" 17 "$H40" A daniel-ospina/tortoise 2026-01-01T00:00:00Z
mkrec "$TMP/uni31/17.json" 17 "$H40" B daniel-ospina/tortoise 2026-01-01T00:00:00Z
set +o pipefail 2>/dev/null || true
python3 "$TOOL" push --registry "$TMP/reg31" --union "$TMP/uni31" 2>/dev/null | head -1 > /dev/null
rc=${PIPESTATUS[0]}
check "piped through head still exits 1" "[ $rc -eq 1 ]"

echo "== §32 a leading UTF-8 BOM is refused (JSON.parse refuses it too)"
mkdir -p "$TMP/reg32" "$TMP/uni32"
{ printf '\xef\xbb\xbf'; printf '{"pr":20,"head_sha":"%s","verdict":"BOM","reviewed_at":"2027-01-01T00:00:00Z"}' "$H40"; } > "$TMP/uni32/20.json"
rc=$(run push --registry "$TMP/reg32" --union "$TMP/uni32")
check "BOM source → exit 1, not adopted" "[ $rc -eq 1 ] && [ ! -f '$TMP/reg32/20.json' ]"

echo "== §33 a stray invalid byte is ACCEPTED (the gate decodes with replacement) — not stricter than it"
mkdir -p "$TMP/reg33" "$TMP/uni33"
python3 -c "b=b'{\"pr\":21,\"head_sha\":\"' + b'1'*40 + b'\",\"verdict\":\"has-a-' + bytes([0xff]) + b'-byte\",\"reviewed_at\":\"2027-01-01T00:00:00Z\"}'; open('$TMP/uni33/21.json','wb').write(b)"
rc=$(run push --registry "$TMP/reg33" --union "$TMP/uni33")
check "gate-valid (lossy-decoded) record is adopted, exit 0" "[ $rc -eq 0 ] && [ -f '$TMP/reg33/21.json' ]"

echo "== §34 carried_at is compared as a PARSED instant, not as a string"
mkdir -p "$TMP/reg34" "$TMP/uni34"
# target carried at 09:00Z; source carried at 10:00+02:00 == 08:00Z → target is LATER, keep it
python3 -c "import json;open('$TMP/reg34/daniel-ospina-tortoise-22.json','w').write(json.dumps({'pr':22,'head_sha':'$H40','verdict':'CARRIED-0900Z','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22T03:35:39Z','mint':'carried','carried_at':'2026-10-22T09:00:00Z'}))"
python3 -c "import json;open('$TMP/uni34/daniel-ospina-tortoise-22.json','w').write(json.dumps({'pr':22,'head_sha':'2'*40,'verdict':'CARRIED-0800Z','repo':'daniel-ospina/tortoise','reviewed_at':'2026-10-22T03:35:39Z','mint':'carried','carried_at':'2026-10-22T10:00:00+02:00'}))"
rc=$(run push --registry "$TMP/reg34" --union "$TMP/uni34")
check "exit 0" "[ $rc -eq 0 ]"
check "the genuinely later carried record is kept (a string compare would have replaced it)" \
  "python3 -c \"import json;assert json.load(open('$TMP/reg34/daniel-ospina-tortoise-22.json'))['verdict']=='CARRIED-0900Z'\""

echo "== §35 a trailing-newline repo / filename is NOT gate-valid (Python $ must not be used)"
mkdir -p "$TMP/reg35" "$TMP/uni35"
python3 -c "import json;open('$TMP/uni35/441.json','w').write(json.dumps({'pr':441,'head_sha':'$H40','verdict':'NL','repo':'a/b\n','reviewed_at':'2027-01-01T00:00:00Z'}))"
python3 -c "import json;open('$TMP/uni35/1823.json\n','w').write(json.dumps({'pr':1823,'head_sha':'$H40','verdict':'NL-KEY'}))"
rc=$(run push --registry "$TMP/reg35" --union "$TMP/uni35")
check "exit 1 (the newline repo is refused)" "[ $rc -eq 1 ]"
check "newline repo not adopted" "[ ! -f '$TMP/reg35/441.json' ]"
check "the '1823.json<newline>' file is not even a record key" "[ ! -f '$TMP/reg35/1823.json' ]"

echo "== §36 a NON-UTF-8 stdout (LC_ALL=C, PYTHONIOENCODING=ascii) still SHOWS the conflict"
mkdir -p "$TMP/reg36" "$TMP/uni36"
mkrec "$TMP/reg36/1.json" 1 "$H40" A daniel-ospina/tortoise 2026-01-01T00:00:00Z
mkrec "$TMP/uni36/1.json" 1 "$H40" B daniel-ospina/tortoise 2026-01-01T00:00:00Z
LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONIOENCODING=ascii python3 "$TOOL" push --registry "$TMP/reg36" --union "$TMP/uni36" > "$TMP/out36" 2>"$TMP/err36"
rc=$?
check "exit 1" "[ $rc -eq 1 ]"
check "the report is NOT empty (the conflict is readable)" "[ -s '$TMP/out36' ]"
check "it names the conflict" "grep -q CONFLICT '$TMP/out36'"
check "no traceback" "! grep -q Traceback '$TMP/err36'"

echo "== §37 a failing stdout target (/dev/full) cannot change the verdict"
if [ -w /dev/full ]; then
  python3 "$TOOL" push --registry "$TMP/reg36" --union "$TMP/uni36" > /dev/full 2>/dev/null
  rc=$?
  check "conflict still exits 1 (not the interpreter's 120)" "[ $rc -eq 1 ]"
else
  check "/dev/full unavailable — skipped" "true"
fi

echo "== §38 a CLOSED stdout is not a crash"
python3 "$TOOL" status --registry "$TMP/reg36" --union "$TMP/uni36" >&- 2>"$TMP/err38"
rc=$?
check "exit 1 (the verdict), no traceback" "[ $rc -eq 1 ] && ! grep -q Traceback '$TMP/err38'"

echo "== §39 a failing STDERR cannot rewrite the verdict either (both streams on /dev/full)"
if [ -w /dev/full ]; then
  mkdir -p "$TMP/reg39" "$TMP/uni39"; mkrec "$TMP/reg39/1.json" 1 "$H40" A "" 2026-01-01T00:00:00Z
  python3 "$TOOL" pull --registry "$TMP/reg39" --union "$TMP/uni39" >>/dev/full 2>&1
  check "converged run exits 0" "[ $? -eq 0 ]"
  python3 "$TOOL" pull --registry "$TMP/nope39" --union "$TMP/uni39" 2>/dev/full >/dev/null
  check "unreadable registry exits 3 (not the interpreter's 120)" "[ $? -eq 3 ]"
  python3 "$TOOL" bogus 2>/dev/full >/dev/null
  check "usage exits 2 (not 120)" "[ $? -eq 2 ]"
else
  check "/dev/full unavailable — skipped" "true"
fi

echo "== §40 a FAILED write is UNKNOWN (exit 3), never a false convergence"
mkdir -p "$TMP/reg40" "$TMP/uni40"
mkrec "$TMP/uni40/1.json" 1 "$H40" NEW "" 2027-01-01T00:00:00Z
chmod 500 "$TMP/reg40"
rc=$(run push --registry "$TMP/reg40" --union "$TMP/uni40")
chmod 700 "$TMP/reg40"
check "exit 3" "[ $rc -eq 3 ]"
check "says the write failed" "grep -q FAILED '$TMP/out'"
check "nothing adopted" "[ ! -f '$TMP/reg40/1.json' ]"

echo "== §41 a CLOSED stderr cannot leak a diagnostic onto stdout (--json stays pure JSON)"
mkdir -p "$TMP/reg41" "$TMP/uni41"; mkrec "$TMP/reg41/1.json" 1 "$H40" A "" 2026-01-01T00:00:00Z
python3 "$TOOL" status --registry "$TMP/reg41" --union "$TMP/uni41" --json 2>&- > "$TMP/out41"
check "exit 1" "[ $? -eq 1 ]"
check "stdout is pure JSON" "python3 -c \"import json;json.load(open('$TMP/out41'))\""

echo "== §42 a NON-STRING repo is refused as unattributable (never propagated, never mislabelled)"
mkdir -p "$TMP/reg42" "$TMP/uni42"
python3 -c "import json;open('$TMP/uni42/1.json','w').write(json.dumps({'pr':1,'head_sha':'$H40','verdict':'ARRAY-REPO','repo':['a/b'],'reviewed_at':'2027-01-01T00:00:00Z'}))"
rc=$(run push --registry "$TMP/reg42" --union "$TMP/uni42")
check "exit 1, not adopted" "[ $rc -eq 1 ] && [ ! -f '$TMP/reg42/1.json' ]"
check "the message names the real cause (not 'charset')" "grep -q 'is not a string' '$TMP/out'"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
