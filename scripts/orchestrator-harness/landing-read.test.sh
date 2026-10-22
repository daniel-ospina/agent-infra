#!/usr/bin/env bash
# landing-read.test.sh — agent-infra#2320: a box whose gh chain cannot reach a REAL binary must be a
# NAMED failure on the health/status surface, not a silent one.
#
# WHAT WAS BROKEN (measured 2026-10-22, the owner's Mac). The wrapper chain
# `gh-limit -> gh-rest -> .pi/agent/shims/gh` resolved to itself; gh-limit refused at depth 2
# ("refusing a third gh-shim hop … no real gh is reachable") and EVERY gh call returned EMPTY. The
# merge contract therefore read UNREADABLE, `merge-one.sh` refused every merge with exit 5, and
# nothing anywhere said why — the box looked like a permissions problem. `AGENT_GH_REAL` to the
# box's real gh fixed it instantly.
#
# WHAT THIS SUITE ASSERTS (all BEHAVIOURAL — the shipped files are DRIVEN, never grepped for prose):
#   §1  a PATH whose only `gh` is the agent shim  → `gh=CANNOT-REACH-REAL-GH`, and NO load claim and
#       NO readable contract. The cycle record in this fixture says `nothing=no_candidate`, so a
#       load/capacity bound cannot be what the verdict is about.
#   §2  a PATH whose only `gh` re-enters ITSELF   → the same verdict CARRYING the chain's own
#       depth-guard words (the measured message), so an operator sees the mechanism.
#   §3  load and landing are DISTINGUISHED: a record with `bound=load_per_cpu` on a box whose gh is
#       fine still reports `landing gh=OK`, and a landing blocker is reported on a HEALTHY cycle.
#   §4  a resolvable real gh + a non-empty protection read → `gh=OK path=…` with the resolved path
#       and `contract=OK required=[…]`; `landing.ok` is true.
#   §5  an EMPTY protection read is UNREADABLE — never "requires nothing".
#   §6  the pin: a script is never exported as `AGENT_GH_REAL` (a value naming a wrapper re-enters the
#       chain, #2266); a provably-broken inherited value is replaced by the resolved binary.
#   §7  MUTATION CONTROLS — the assertions above are non-vacuous: delete the resolution read from a
#       COPY of the shipped file and §1 goes RED; make the empty contract a pass and §5 goes RED.
#
# HERMETIC: no network, no real repo, no real gh. Every fixture is a temp dir; the stub gh answers
# `--version` and the protection endpoint from a case statement; the slug comes from `OR`, so no git
# is needed at all.
#
# ⛔ rc IS CAPTURED IMMEDIATELY AFTER EVERY DRIVEN COMMAND, never inline in a `ck` argument where a
# `$(…)` would supply the status of the last command in the pipeline.
# ⛔ NO `printf … | grep -q …` ANYWHERE (#841/#864): a quiet grep takes SIGPIPE on the writer and the
# pipeline reads FAILED on a match. A here-string feeds the same bytes with no pipe.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS_BIN="$ROOT/bin/harness"
RA="$HERE/repo-authority.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
q()  { grep -q  -- "$1" <<<"${2:-}"; }
qF() { grep -qF -- "$1" <<<"${2:-}"; }
nq() { ! grep -q -- "$1" <<<"${2:-}"; }

for f in "$HARNESS_BIN" "$RA"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite drives the shipped files, so it cannot run"; exit 2; }
done
echo "==> landing-read self-test ($HERE)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/landing-read.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
NOW="$(date +%s)"

# ── the tool PATH every fixture gets ────────────────────────────────────────────────────────────────
# A PATH with NO `gh` on it, but with the tools the harness needs. Building it explicitly (rather than
# reusing $PATH) is what makes "there is no real gh on this box" a FACT about the fixture instead of a
# hope about the host — the whole point of §1.
MIN="$TMP/minbin"; mkdir -p "$MIN"
# ⛔ `tail` IS LOAD-BEARING, and its absence is the honest degrade: without it `cycle_verdict` cannot
# read the newest record and the verb answers UNREADABLE (rc 2) — measured here before this line
# existed, which is why the fixture names the tool rather than hoping $PATH has it.
for t in bash sh env head tail sed tr cat date dirname awk wc uname iconv grep mktemp rm mkdir ln cp id sort; do
  for d in /usr/bin /bin /usr/local/bin /usr/sbin; do
    if [ -x "$d/$t" ]; then ln -sf "$d/$t" "$MIN/$t" 2>/dev/null; break; fi
  done
done
[ -x "$MIN/bash" ] || { echo "❌ no bash in the fixture PATH — cannot drive anything"; exit 2; }

# ── a cycle record, so the status verb has something to grade ───────────────────────────────────────
# mko <dir> <nothing-token>
mko() {
  mkdir -p "$1/state"
  printf 'start=%s end=%s cycle=9 interval=240 selected=issue:#1 selected_n=1 dispatched=0 ids=- nothing=%s placement=ok placed_on=- bound=none lpc_self=? shapes=1\n' \
    "$NOW" "$NOW" "$2" > "$1/state/cycles"
}
# status <dir> <PATH> [extra env…] -> stdout+stderr of the shipped verb
# ⛔ `OR` IS PINNED FOR EVERY FIXTURE. The box's ambient `OR` (a cell exports one) would otherwise
# decide which repo's contract this suite asks about, so the assertions would grade the operator's
# config instead of the fixture. `--dir` is not used: it is not a shipped flag on this verb.
status() {
  local o="$1" p="$2"; shift 2
  env PATH="$p" OR="${FIX_OR-acme/widget}" "$@" O="$o" bash "$HARNESS_BIN" status 2>&1
}

# ── §1 a PATH whose only gh is the agent shim ───────────────────────────────────────────────────────
echo
echo "── §1 the shim-only PATH: CANNOT-REACH-REAL-GH, and it is NOT excused as load ──"
SHIMD="$TMP/shimd"; mkdir -p "$SHIMD"
ln -sf "$ROOT/scripts/gh-shim/gh" "$SHIMD/gh"
O1="$TMP/o1"; mko "$O1" no_candidate
OUT1="$(status "$O1" "$SHIMD:$MIN")"; RC1=$?
ck "the status verb still runs (rc=$RC1, HEALTHY cycle: the landing read must not crash it)" \
   "$([ "$RC1" -eq 0 ] && echo 0 || echo 1)"
ck "…and NAMES the failure: gh=CANNOT-REACH-REAL-GH" \
   "$(q 'gh=CANNOT-REACH-REAL-GH' "$OUT1" && echo 0 || echo 1)"
ck "…naming the mechanism (the agent shim is a wrapper, not a binary)" \
   "$(q 'argv-level gh shim' "$OUT1" && echo 0 || echo 1)"
ck "…and states the CONSEQUENCE (a box that cannot land wastes its lane budget)" \
   "$(q 'wasted work' "$OUT1" && echo 0 || echo 1)"
ck "…and separates itself from load/capacity IN WORDS (not a bound= explanation)" \
   "$(q 'NOT a load/capacity one' "$OUT1" && echo 0 || echo 1)"
ck "…and does NOT report high load (the fixture's record says nothing=no_candidate; no bound=load)" \
   "$(nq 'load_per_cpu' "$OUT1" && nq 'HIGH LOAD' "$OUT1" && echo 0 || echo 1)"
ck "…and does NOT read the empty contract as a pass (contract=UNREADABLE)" \
   "$(q 'contract=UNREADABLE' "$OUT1" && nq 'contract=OK' "$OUT1" && echo 0 || echo 1)"
ck "…and flags the box LANDING BLOCKED in the last line a reader sees" \
   "$(q 'LANDING BLOCKED' "$OUT1" && echo 0 || echo 1)"
OUT1J="$(env PATH="$SHIMD:$MIN" OR=acme/widget O="$O1" bash "$HARNESS_BIN" status --json 2>&1)"
_j1="$(printf '%s' "$OUT1J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["landing"]["ok"], d["landing"]["gh"], d["verdict"])' 2>&1)"
ck "…and the machine surface says landing.ok=false beside a HEALTHY cycle verdict (got: $_j1)" \
   "$([ "$_j1" = "False CANNOT-REACH-REAL-GH HEALTHY" ] && echo 0 || echo 1)"

# ── §2 a wrapper that re-enters ITSELF: the chain's own depth-guard words must survive ──────────────
echo
echo "── §2 a self-resolving wrapper: the depth-guard message is QUOTED, not summarised away ──"
HOPD="$TMP/hopd"; mkdir -p "$HOPD"
cat > "$HOPD/gh" <<'HOP'
#!/usr/bin/env bash
# fixture: a wrapper that resolves to ITSELF, exactly the shape measured on 2026-10-22.
if [ "${HARNESS_GH_SHIM_DEPTH:-0}" -ge 2 ]; then
  printf 'gh-limit: refusing a third gh-shim hop (HARNESS_GH_SHIM_DEPTH=%s) — the shims are resolving to each other and no real gh is reachable\n' \
    "$HARNESS_GH_SHIM_DEPTH" >&2
  exit 127
fi
export HARNESS_GH_SHIM_DEPTH=$(( ${HARNESS_GH_SHIM_DEPTH:-0} + 1 ))
exec "$0" "$@"
HOP
chmod +x "$HOPD/gh"
O2="$TMP/o2"; mko "$O2" no_candidate
OUT2="$(status "$O2" "$HOPD:$MIN")"; RC2=$?
ck "the verdict is still CANNOT-REACH-REAL-GH (rc=$RC2 status, not a crash)" \
   "$(q 'gh=CANNOT-REACH-REAL-GH' "$OUT2" && echo 0 || echo 1)"
ck "…carrying the chain's OWN depth-guard sentence" \
   "$(q 'third gh-shim hop' "$OUT2" && q 'no real gh is reachable' "$OUT2" && echo 0 || echo 1)"

# ── §3 DISTINGUISHED FROM LOAD — both directions ────────────────────────────────────────────────────
echo
echo "── §3 load and landing are two dimensions, in both directions ──"
GOODD="$TMP/goodd"; mkdir -p "$GOODD"
cat > "$GOODD/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--version*) printf 'gh version 9.9.9 (test-stub)\nhttps://example.invalid/gh\n' ;;
  *protection/required_status_checks*) printf 'pipeline-compliance\n' ;;
  *) printf 'stub: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$GOODD/gh"
O3="$TMP/o3"; mko "$O3" 'gate:capacity-placement(bound=load_per_cpu)'
OUT3="$(status "$O3" "$GOODD:$MIN")"
ck "a load-bound cycle record still prints its own bound (load is reported where it lives)" \
   "$(q 'load_per_cpu' "$OUT3" && echo 0 || echo 1)"
ck "…while the landing dimension reads OK, so load is NOT blamed for landing" \
   "$(q 'landing       gh=OK' "$OUT3" && echo 0 || echo 1)"
ck "…and the box is NOT reported LANDING BLOCKED" "$(nq 'LANDING BLOCKED' "$OUT3" && echo 0 || echo 1)"
O4="$TMP/o4"; mko "$O4" no_candidate
OUT4="$(status "$O4" "$SHIMD:$MIN")"
ck "and conversely: a HEALTHY cycle does not excuse a landing blocker" \
   "$(q 'harness status — HEALTHY' "$OUT4" && q 'LANDING BLOCKED' "$OUT4" && echo 0 || echo 1)"

# ── §4 a resolvable real gh + readable protection ───────────────────────────────────────────────────
echo
echo "── §4 a real gh that answers: OK, WITH the resolved path printed ──"
mkdir -p "$TMP/o5"; mko "$TMP/o5" no_candidate
OUT5="$(status "$TMP/o5" "$GOODD:$MIN")"
ck "gh=OK with the RESOLVED PATH (an operator can point AGENT_GH_REAL at it)" \
   "$(q "path=$GOODD/gh" "$OUT5" && echo 0 || echo 1)"
ck "…naming where it came from (source=path)" "$(q 'source=path' "$OUT5" && echo 0 || echo 1)"
ck "…and the contract OK with its contexts" \
   "$(q 'contract=OK' "$OUT5" && q 'required=\[pipeline-compliance\]' "$OUT5" && echo 0 || echo 1)"
OUT5J="$(env PATH="$GOODD:$MIN" OR=acme/widget O="$TMP/o5" bash "$HARNESS_BIN" status --json 2>&1)"
_j5="$(printf '%s' "$OUT5J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["landing"]["ok"], d["landing"]["ghPath"], d["landing"]["required"], d["landing"]["contractRepo"])' 2>&1)"
ck "…and the JSON carries ok/path/required/repo (got: $_j5)" \
   "$([ "$_j5" = "True $GOODD/gh pipeline-compliance acme/widget" ] && echo 0 || echo 1)"

# ⛔ A PATH WITH A SPACE MUST SURVIVE THE ROUND TRIP (fresh review P2). `path=` is the LAST field of
# the one-line protocol for exactly this; with the old order the printed remedy path and the JSON's
# `ghPath` both stopped at the space — naming a file that does not exist.
SPACED="$TMP/with space/bin"; mkdir -p "$SPACED"
cp "$GOODD/gh" "$SPACED/gh"; chmod +x "$SPACED/gh"
mkdir -p "$TMP/o5b"; mko "$TMP/o5b" no_candidate
OUT5B="$(status "$TMP/o5b" "$SPACED:$MIN")"
_printed="$(printf '%s\n' "$OUT5B" | sed -n 's/.* path=//p' | head -1)"
ck "a resolved path containing a SPACE is printed WHOLE (got: ${_printed:-<none>})" \
   "$(q "path=$SPACED/gh" "$OUT5B" && echo 0 || echo 1)"
OUT5BJ="$(env PATH="$SPACED:$MIN" OR=acme/widget O="$TMP/o5b" bash "$HARNESS_BIN" status --json 2>&1)"
_j5b="$(printf '%s' "$OUT5BJ" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["landing"]["ghPath"])' 2>&1)"
ck "…and the JSON's ghPath is the same whole path (got: ${_j5b:-<none>})" \
   "$([ "$_j5b" = "$SPACED/gh" ] && echo 0 || echo 1)"

# ⛔ AND `status` MUST NOT PIN A SCRIPT (fresh review P1). It asks the chain it has just proved
# answers, so it exports nothing; this stub records the env it was handed on the protection call and
# the pin must be EMPTY. `ensure_agent_gh_real` is the ONLY exporter, and it exports only a compiled
# binary — an unconditional export here handed a script-valued resolution to the chain, which is the
# #2266 re-entry this change exists to prevent.
RECD="$TMP/recd"; mkdir -p "$RECD"; PINLOG="$TMP/pinlog"
cat > "$RECD/gh" <<STUBPIN
#!/usr/bin/env bash
case "\$*" in
  *--version*) printf 'gh version 9.9.9 (test-stub)\n' ;;
  *protection/required_status_checks*) printf '%s' "\${AGENT_GH_REAL-<unset>}" > "$PINLOG"; printf 'pipeline-compliance\n' ;;
  *) exit 1 ;;
esac
STUBPIN
chmod +x "$RECD/gh"
mkdir -p "$TMP/o5c"; mko "$TMP/o5c" no_candidate
env -u AGENT_GH_REAL PATH="$RECD:$MIN" OR=acme/widget O="$TMP/o5c" bash "$HARNESS_BIN" status >/dev/null 2>&1
_pl="$(cat "$PINLOG" 2>/dev/null)"
ck "status exports NO pin to the chain it just proved answers (got: '${_pl:-<no call>}', want '<unset>')" \
   "$([ "$_pl" = "<unset>" ] && echo 0 || echo 1)"

# ── §5 an EMPTY protection read is UNREADABLE ───────────────────────────────────────────────────────
echo
echo "── §5 an EMPTY required-checks read is UNREADABLE, never \"requires nothing\" ──"
EMPTYD="$TMP/emptyd"; mkdir -p "$EMPTYD"
cat > "$EMPTYD/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--version*) printf 'gh version 9.9.9 (test-stub)\n' ;;
  # the shape a stale/under-scoped/absent-protection read leaves behind: rc 0, NO contexts
  *protection/required_status_checks*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$EMPTYD/gh"
mkdir -p "$TMP/o6"; mko "$TMP/o6" no_candidate OUT6=""
OUT6="$(status "$TMP/o6" "$EMPTYD:$MIN")"
ck "the gh read is OK (the binary answers) — the failure is the CONTRACT, not the chain" \
   "$(q 'landing       gh=OK' "$OUT6" && echo 0 || echo 1)"
ck "…and the contract is UNREADABLE, not OK" \
   "$(q 'contract=UNREADABLE' "$OUT6" && nq 'contract=OK' "$OUT6" && echo 0 || echo 1)"
ck "…and the box is flagged LANDING BLOCKED (the refusal this read exists to pre-empt)" \
   "$(q 'LANDING BLOCKED' "$OUT6" && echo 0 || echo 1)"

# ── §6 the pin: discovered, never a script ──────────────────────────────────────────────────────────
echo
echo "── §6 AGENT_GH_REAL is discovered per box, and a wrapper is NEVER exported ──"
_pin_script="$(env -u AGENT_GH_REAL PATH="$SHIMD:$MIN" bash -c '. "$1"; ensure_agent_gh_real; printf "%s" "${AGENT_GH_REAL:-<none>}"' _ "$RA" 2>&1)"
ck "a shim-only box exports NOTHING (got: ${_pin_script:-<empty>})" \
   "$([ "$_pin_script" = "<none>" ] && echo 0 || echo 1)"
_pin_stub="$(env -u AGENT_GH_REAL PATH="$GOODD:$MIN" bash -c '. "$1"; ensure_agent_gh_real; printf "%s" "${AGENT_GH_REAL:-<none>}"' _ "$RA" 2>&1)"
ck "a gh-shaped SCRIPT is refused as a pin too (a wrapper re-enters the chain, #2266) (got: ${_pin_stub:-<empty>})" \
   "$([ "$_pin_stub" = "<none>" ] && echo 0 || echo 1)"
# ⛔ A SHEBANG-LESS WRAPPER IS THE CASE THE FIRST FIX MISSED (fresh review P1): the gate was
# `head -c 2 … != '#!'`, and a script whose shebang is not on byte 1 still EXECUTES (the shell falls
# back to running it as sh), so it was pinned. The pin now requires a COMPILED BINARY (_gh_is_binary).
NOSHEBANG="$TMP/noshebang"; mkdir -p "$NOSHEBANG"
printf '\n#!/usr/bin/env bash\ncase "$*" in *--version*) printf "gh version 9.9.9 (test-stub)\\n" ;; *) exit 1 ;; esac\n' > "$NOSHEBANG/gh"
chmod +x "$NOSHEBANG/gh"
_pin_nosheb="$(env -u AGENT_GH_REAL PATH="$NOSHEBANG:$MIN" bash -c '. "$1"; ensure_agent_gh_real; printf "%s" "${AGENT_GH_REAL:-<none>}"' _ "$RA" 2>&1)"
ck "a SHEBANG-LESS wrapper is refused as a pin too (got: ${_pin_nosheb:-<empty>})" \
   "$([ "$_pin_nosheb" = "<none>" ] && echo 0 || echo 1)"
_broken_pin="$(env AGENT_GH_REAL="$SHIMD/gh" PATH="$GOODD:$MIN" bash -c '. "$1"; ensure_agent_gh_real; printf "%s" "${AGENT_GH_REAL:-<none>}"' _ "$RA" 2>&1)"
ck "a PROVABLY-BROKEN inherited pin (a shim) is dropped, not honoured (got: ${_broken_pin:-<empty>})" \
   "$([ "$_broken_pin" = "<none>" ] && echo 0 || echo 1)"
# A REAL binary is the only thing that can be pinned — and only a host that has one can prove it.
# (The magic-byte test is `_gh_is_binary`, so the probe here uses the same property the code does.)
REALGH=""
for d in /usr/bin /bin /usr/local/bin /opt/homebrew/bin; do
  if [ -x "$d/gh" ] && [ -n "$(od -A n -t x1 -N 4 "$d/gh" 2>/dev/null | tr -d ' \n' | grep -E '^(7f454c46|4d5a|cffaedfe|feedface|cefaedfe|feedfacf|cafebabe|bebafeca)')" ]; then
    REALGH="$d/gh"; break
  fi
done
if [ -n "$REALGH" ]; then
  _real_pin="$(env -u AGENT_GH_REAL PATH="$(dirname "$REALGH"):$MIN" bash -c '. "$1"; ensure_agent_gh_real; printf "%s" "${AGENT_GH_REAL:-<none>}"' _ "$RA" 2>&1)"
  ck "a real binary IS pinned, discovered from PATH (got: ${_real_pin:-<empty>}, want: $REALGH)" \
     "$([ "$_real_pin" = "$REALGH" ] && echo 0 || echo 1)"
else
  echo "  ⏭  skip: this host has no binary gh to pin (the script-refusal arms above still ran)"
fi

# ── §6b the PIN DIAGNOSIS names the real cause, and never suppresses the walk's finding ─────────────
# Fresh review P2: one shared sentence called a MISSING file "a harness shim" (the issue's own measured
# path, `/opt/homebrew/bin/gh`, is a missing file), and a pin diagnosis SUPPRESSED the walk's accurate
# datum. Both are operator-facing claims, so both are asserted.
echo
echo "── §6b an unusable pin is diagnosed by WHAT IT IS, and the walk's datum survives ──"
_read_pin() { # _read_pin <AGENT_GH_REAL value> <PATH>
  env AGENT_GH_REAL="$1" PATH="$2" bash -c '. "$1"; gh_chain_read' _ "$RA" 2>&1
}
_m1="$(_read_pin /nonexistent/homebrew/bin/gh "$MIN")"
ck "a MISSING pin is 'not an executable regular file', not 'a harness shim'" \
   "$(q 'is not an executable regular file' "$_m1" && nq 'harness gh layer' "$_m1" && echo 0 || echo 1)"
_m2="$(_read_pin "$SHIMD/gh" "$MIN")"
ck "the AGENT shim as a pin is named AS the agent shim (it is not a 'harness layer')" \
   "$(q 'argv-level gh shim' "$_m2" && nq 'harness gh layer' "$_m2" && echo 0 || echo 1)"
_m3="$(_read_pin /nonexistent/homebrew/bin/gh "$SHIMD:$MIN")"
ck "the WALK's datum is not suppressed by the pin diagnosis (both appear)" \
   "$(q 'argv-level gh shim' "$_m3" && q 'not an executable regular file' "$_m3" && echo 0 || echo 1)"

# ── §7 MUTATION CONTROLS — prove the assertions are not vacuous ─────────────────────────────────────
echo
echo "── §7 mutation: remove the read, and §1/§5 must go RED ──"
MUT="$TMP/mut"
mkdir -p "$MUT/bin" "$MUT/scripts/orchestrator-harness"
cp "$HARNESS_BIN" "$MUT/bin/harness"
for f in cycle-record.sh repo-authority.sh repo-slug.sh; do cp "$HERE/$f" "$MUT/scripts/orchestrator-harness/$f"; done
# (a) delete the RESOLUTION read: the status verb then has no verdict to report.
python3 - "$MUT/bin/harness" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
before = s
s = s.replace('    _ghline="$(gh_chain_read 2>/dev/null)"; _ghrc=$?\n', '    _ghline=""; _ghrc=99\n')
assert s != before, "mutation target not found — the resolution read moved; update this control"
open(p, "w").write(s)
PY
mk_out="$(env PATH="$SHIMD:$MIN" O="$O1" bash "$MUT/bin/harness" status 2>&1)"
ck "MUTANT (read deleted): CANNOT-REACH-REAL-GH is GONE — so §1 is a real assertion, not a prose match" \
   "$(nq 'CANNOT-REACH-REAL-GH' "$mk_out" && echo 0 || echo 1)"
ck "…and the mutant does NOT crash (it degrades to UNVERIFIABLE, which is never a pass)" \
   "$(q 'gh=UNVERIFIABLE' "$mk_out" && echo 0 || echo 1)"
# (b) make the EMPTY contract a pass: §5 must go RED.
# ⛔ THE MUTANT'S `bin/harness` IS RESTORED FIRST. Leaving mutant (a) in place would make this
# control pass for the WRONG reason — the box would read UNVERIFIABLE from the still-deleted read,
# not from the contract mutation under test.
cp "$HARNESS_BIN" "$MUT/bin/harness"
for f in cycle-record.sh repo-authority.sh repo-slug.sh; do cp "$HERE/$f" "$MUT/scripts/orchestrator-harness/$f"; done
python3 - "$MUT/scripts/orchestrator-harness/repo-authority.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = s
# an empty read becomes OK with an empty context list — the exact falsification §5 refuses
s = s.replace('  if out="$(required_checks "$or" "$gh" 2>/dev/null)"; then\n'
              '    printf \'CONTRACT=OK required=%s repos=%s\\n\' "$out" "$or"; return 0\n'
              '  fi\n',
              '  out="$(required_checks "$or" "$gh" 2>/dev/null)"; out=""\n'
              '  printf \'CONTRACT=OK required=%s repos=%s\\n\' "$out" "$or"; return 0\n')
assert s != before, "mutation target not found — merge_contract_read changed; update this control"
open(p, "w").write(s)
PY
mk2_out="$(env PATH="$EMPTYD:$MIN" OR=acme/widget O="$TMP/o6" bash "$MUT/bin/harness" status 2>&1)"
ck "MUTANT (empty contract = pass): the UNREADABLE verdict is GONE — so §5 is real" \
   "$(nq 'contract=UNREADABLE' "$mk2_out" && q 'contract=OK' "$mk2_out" && echo 0 || echo 1)"

# (c) A PRE-#2320 `$O` COPY must be NAMED, not concatenated (fresh review P2). Every deployed box is in
# this state until it is re-seeded, so the one diagnostic it gets must name a file that exists.
STALE="$MUT/scripts/orchestrator-harness/repo-authority.sh"
python3 - "$STALE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = s
i = s.index("# THE LANDING READ")
s = s[:i]
assert s != before, "mutation target not found — the landing block moved; update this control"
open(p, "w").write(s)
PY
stale_out="$(env PATH="$SHIMD:$MIN" O="$O1" bash "$MUT/bin/harness" status 2>&1)"
ck "MUTANT (a PRE-#2320 module): the read is UNVERIFIABLE and the reason NAMES the file" \
   "$(q 'gh=UNVERIFIABLE' "$stale_out" && q "at $STALE" "$stale_out" && echo 0 || echo 1)"
ck "…and the message does not concatenate the two arms into a path that cannot exist" \
   "$(nq "$STALE$STALE" "$stale_out" && echo 0 || echo 1)"

echo
echo "──────── landing-read: $PASS passed, $FAIL failed ────────"
[ "$FAIL" -eq 0 ]
