#!/usr/bin/env bash
# ci_runner_starvation.test.sh — hermetic suite for scripts/ci_runner_starvation.sh (agent-infra#2875).
#
# Run: bash scripts/ci_runner_starvation.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. NO network, NO `gh`, NO systemctl, NO real
# runner pool: `gh`, `systemctl` and `ci_runner_pool.sh` are shims on PATH, and every fixture lives
# under a temp dir. It runs in BOTH bash lanes (discovered as `scripts/*.test.sh`).
#
# WHY A FAKE gh THAT IS *STATEFUL* AND *SCRIPTABLE*. The healer's whole job is a read→act→re-read
# loop, so a fake that replays canned text without mutating state could not prove either half:
#   (a) "label restored, invariant clears" needs the POST to MUTATE the runner list so the re-read
#       sees the restored label and the job that then gets assigned;
#   (c) "never restart a busy runner" needs a TOCTOU — the probe sees busy==0, step 2's re-read sees
#       one runner busy — which a scripted per-read override models without touching the state.
# Both are here: POST/PUT/DELETE mutate `state.tsv`; `override.runners.<N>` / `override.queued.<N>`
# files override the N-th read (holding the last), which is how a live job landing between two reads
# is made deterministic.
#
# WHY THESE CASES — each is a measured failure shape or a guard a naive healer would miss:
#   * the STARVED shape (queued>0 AND busy==0 AND online>0) must heal by ADDITIVELY restoring
#     `ubuntu-latest`, and the invariant must clear;
#   * the detector must SAY the three states starvation is not — DEMAND, IDLE, OFFLINE — and not act;
#   * persistence: N=3 consecutive samples, ~2 min apart (the timer provides the spacing; the streak
#     counts samples);
#   * MUTATION (c): make the busy-guard unconditional and show a test reddens (the healer would
#     restart a live job);
#   * MUTATION (d): allow a label REPLACE instead of an additive add, and show a test reddens;
#   * escalation bound: a permanently broken pool reaches step 4 (FILE AND SHOUT) within the bound
#     and does not spin.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALER="$SCRIPT_DIR/ci_runner_starvation.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_ne() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3 (both: $1)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()  { if grep -qF -- "$2" <<<"$1"; then bad "$3 (present: $2)"; else ok "$3"; fi; }
assert_file() { if [ -f "$1" ]; then ok "$2"; else bad "$2 (absent: $1)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ci-starvation-test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

BIN="$T/bin"; mkdir -p "$BIN"
GH_DIR="$T/gh"; mkdir -p "$GH_DIR"
STATE="$T/state"; mkdir -p "$STATE"
ROOT="$T/runner-root"; mkdir -p "$ROOT"

# ── fake gh: stateful + scriptable ────────────────────────────────────────────────────────────
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# GH_DIR holds: state.tsv (id<TAB>name<TAB>online|offline<TAB>true|false<TAB>labels-comma),
#               queued (one integer), gh.log (every invocation), gh.actions (POST/PUT/DELETE),
#               override.runners.<N> / override.queued.<N> (per-read overrides).
GH_DIR="${GH_DIR:?}"
mkdir -p "$GH_DIR"
printf '%s\n' "$*" >>"$GH_DIR/gh.log"
# ⛔ READ STDIN ONLY FOR --input - (POST/PUT), NEVER FOR GET. A GET run inside the healer's
# `while read <<<"$rows"` loop inherits that here-string as stdin; a bare `cat` here would CONSUME
# the rest of the loop's rows and the healer would silently process only the first runner — the
# exact "a command substitution eats the while-read" defect this repo keeps filing.
case "$*" in *"--input -"*) stdin_body="$(cat)" ;; *) stdin_body="" ;; esac

case "$*" in *"issue create"*)
  printf 'https://github.com/%s/issues/999\n' "${GH_REPO:-repo}"
  printf 'filed\n' >>"$GH_DIR/gh.filed"
  exit 0 ;;
esac

method=GET
case "$*" in *"-X POST"*) method=POST ;; *"-X PUT"*) method=PUT ;; *"-X DELETE"*) method=DELETE ;; esac

if [ "$method" = POST ] || [ "$method" = PUT ]; then
  id="$(printf '%s\n' "$*" | sed 's/.*\/runners\///; s/\/labels.*//')"
  labels="$(printf '%s' "$stdin_body" | sed 's/^{"labels":\[//; s/\]}$//; s/","/,/g; s/"//g')"
  printf '%s id=%s labels=%s\n' "$method" "$id" "$labels" >>"$GH_DIR/gh.actions"
  # mutate state: POST adds (additive), PUT replaces
  : >"$GH_DIR/state.new"
  found=0
  while IFS=$'\t' read -r rid rname rstatus rbusy rlabels; do
    [ -n "$rid" ] || continue
    if [ "$rid" = "$id" ]; then
      found=1
      if [ "$method" = PUT ]; then
        rlabels="$labels"
      else
        for l in $(printf '%s' "$labels" | tr ',' ' '); do
          case ",$rlabels," in *",$l,"*) ;; *) rlabels="${rlabels:+$rlabels,}$l" ;; esac
        done
      fi
      # label fix → a job gets assigned (test a): busy becomes true, queued drops
      if [ "${GH_FLOW_ON_LABEL:-1}" = 1 ] && [ "$method" = POST ]; then
        case ",$labels," in *",ubuntu-latest,"*)
          rbusy=true
          q="$(cat "$GH_DIR/queued" 2>/dev/null || printf 0)"
          case "$q" in ''|*[!0-9]*) q=0 ;; esac
          [ "$q" -gt 0 ] && q=$((q - 1))
          printf '%s' "$q" >"$GH_DIR/queued"
        ;; esac
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$rid" "$rname" "$rstatus" "$rbusy" "$rlabels" >>"$GH_DIR/state.new"
  done <"$GH_DIR/state.tsv"
  [ "$found" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\n' "$id" "runner-$id" online false "$labels" >>"$GH_DIR/state.new"
  mv "$GH_DIR/state.new" "$GH_DIR/state.tsv"
  exit 0
fi

if [ "$method" = DELETE ]; then
  id="$(printf '%s\n' "$*" | sed 's/.*\/runners\///')"
  printf 'DELETE id=%s\n' "$id" >>"$GH_DIR/gh.actions"
  : >"$GH_DIR/state.new"
  while IFS=$'\t' read -r rid rname rstatus rbusy rlabels; do
    [ -n "$rid" ] || continue
    [ "$rid" = "$id" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$rid" "$rname" "$rstatus" "$rbusy" "$rlabels" >>"$GH_DIR/state.new"
  done <"$GH_DIR/state.tsv"
  mv "$GH_DIR/state.new" "$GH_DIR/state.tsv"
  exit 0
fi

case "$*" in
  *"actions/runners"*)
    n="$(cat "$GH_DIR/.n-runners" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s' "$n" >"$GH_DIR/.n-runners"
    if [ -f "$GH_DIR/override.runners.$n" ]; then cat "$GH_DIR/override.runners.$n"; else cat "$GH_DIR/state.tsv" 2>/dev/null; fi
    exit 0 ;;
  *"actions/runs"*)
    n="$(cat "$GH_DIR/.n-queued" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s' "$n" >"$GH_DIR/.n-queued"
    if [ -f "$GH_DIR/override.queued.$n" ]; then cat "$GH_DIR/override.queued.$n"; else cat "$GH_DIR/queued" 2>/dev/null; fi
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$BIN/gh"

# ── fake systemctl: record restarts; `cat <unit>` answers present/absent ─────────────────────
cat >"$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
GH_DIR="${GH_DIR:?}"
printf '%s\n' "$*" >>"$GH_DIR/systemctl.log"
case "$1" in
  restart) [ "${SYSCTL_RESTART_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  cat) if grep -qxF -- "$2" "$GH_DIR/units-present" 2>/dev/null; then exit 0; else exit 1; fi ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/systemctl"

# ── fake ci_runner_pool.sh (step 3 delegate) ────────────────────────────────────────────────
cat >"$BIN/pool" <<'STUB'
#!/usr/bin/env bash
GH_DIR="${GH_DIR:?}"
printf '%s\n' "$*" >>"$GH_DIR/pool.log"
exit "${POOL_RC:-0}"
STUB
chmod +x "$BIN/pool"

export GH_DIR STATE ROOT
export STARVE_REPO="acme/tortoise"

# seed helpers
seed_queued()  { printf '%s\n' "$1" >"$GH_DIR/queued"; }
# ⛔ `row` prints NO trailing newline, and `seed_runners` joins its args with `\n` — a row built with
# a trailing `\n` inside a `$(…)` has that newline STRIPPED, so two `$(row …)`s concatenated into ONE
# malformed line (the second runner's id glued to the first's labels) and the POST branch matched no
# runner. `while read` also skips a final line with no newline, so the joined form must end with one.
seed_runners() { printf '%s\n' "$@" >"$GH_DIR/state.tsv"; rm -f "$GH_DIR/.n-runners" "$GH_DIR/.n-queued"; }
row() { printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5"; }

# run <verb> — invoke the healer with every seam pinned to the shims.
run() {
  STARVE_GH="$BIN/gh" STARVE_SYSTEMCTL="$BIN/systemctl" STARVE_POOL="$BIN/pool" \
    STARVE_STATE_DIR="$STATE" STARVE_PLATFORM=Linux STARVE_RUNNER_ROOT="$ROOT" \
    STARVE_SAMPLES="${STARVE_SAMPLES:-1}" \
    STARVE_WAIT_BUSY_S="${STARVE_WAIT_BUSY_S:-1}" STARVE_WAIT_BUSY_POLL_S="${STARVE_WAIT_BUSY_POLL_S:-1}" \
    bash "$HEALER" "$@" 2>&1
}

reset_gh() {
  rm -f "$GH_DIR"/gh.log "$GH_DIR"/gh.actions "$GH_DIR"/systemctl.log "$GH_DIR"/pool.log \
        "$GH_DIR"/gh.filed "$GH_DIR"/.n-runners "$GH_DIR"/.n-queued \
        "$GH_DIR"/override.runners.* "$GH_DIR"/override.queued.*
  : >"$GH_DIR/state.tsv"; : >"$GH_DIR/queued"; : >"$GH_DIR/units-present"
  rm -f "$STATE/ci-runner-starvation.state" "$STATE/ci-runner-starvation.filed"
}

# ══ 1. the detector classifies, and SAYS, the four states ═══════════════════════════════════
echo "── detector classification ──"
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64)"
out="$(run probe)"
assert_eq "$?" "0" "probe exits 0 on a measured STARVED sample"
assert_contains "$out" "state=STARVED" "a queued>0 AND busy==0 AND online>0 pool is STARVED"
assert_contains "$out" "queued=5 busy=0 online=1" "and the counts are printed"

reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online true self-hosted-x64,ubuntu-latest)"
out="$(run probe)"
assert_contains "$out" "state=DEMAND" "queued>0 AND busy>0 is DEMAND, not starvation"

reset_gh; seed_queued 0
seed_runners "$(row 1 r1 online false self-hosted-x64)"
out="$(run probe)"
assert_contains "$out" "state=IDLE" "queued==0 is IDLE"

reset_gh; seed_queued 9
seed_runners "$(row 1 r1 offline false self-hosted-x64)"
out="$(run probe)"
assert_contains "$out" "state=OFFLINE" "online==0 is OFFLINE (its own signal, its own owner)"

# ══ 2. the pass does NOT act on demand / idle / offline ═════════════════════════════════════
echo "── does NOT fire on the three non-starvation states ──"
for st in DEMAND IDLE OFFLINE; do
  reset_gh
  case "$st" in
    DEMAND)  seed_queued 5; seed_runners "$(row 1 r1 online true self-hosted-x64,ubuntu-latest)" ;;
    IDLE)    seed_queued 0; seed_runners "$(row 1 r1 online false self-hosted-x64)" ;;
    OFFLINE) seed_queued 9; seed_runners "$(row 1 r1 offline false self-hosted-x64)" ;;
  esac
  out="$(run check)"
  assert_eq "$?" "0" "$st: the pass exits 0 (a measured non-starvation state is not a failure)"
  assert_absent "$out" "heal:" "$st: the ladder does NOT run"
  assert_absent "$(cat "$GH_DIR/gh.actions" 2>/dev/null)" "POST" "$st: no label write"
  assert_absent "$(cat "$GH_DIR/systemctl.log" 2>/dev/null)" "restart" "$st: no runner restarted"
done

# ══ 3. the STARVED shape heals: label restored, invariant clears ════════════════════════════
echo "── starved shape heals ──"
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64)"
out="$(run check)"
assert_eq "$?" "0" "a starved pool heals at step 1 and exits 0"
assert_contains "$(cat "$GH_DIR/gh.actions")" "POST id=1 labels=ubuntu-latest" \
  "the missing ubuntu-latest is ADDITIVELY POSTed"
assert_contains "$out" "step 1 CLEARED the invariant" "the ladder names the step that healed it"
assert_contains "$out" "state=DEMAND" "after the label fix the pool reads DEMAND (busy>0)"
assert_eq "$(cat "$GH_DIR/queued")" "4" "a job was assigned (queued dropped 5 -> 4)"

# ── and a runner that ALREADY has the canonical set is not touched ──────────────────────────
reset_gh; seed_queued 3
seed_runners "$(row 1 r1 online false self-hosted-x64,ubuntu-latest)"
out="$(run check)"
assert_eq "$?" "4" "a healthy-label starved pool still escalates (the counts, not the labels, are the invariant)"
assert_absent "$(cat "$GH_DIR/gh.actions" 2>/dev/null)" "POST" "no label write when the set is already canonical"

# ══ 4. persistence: N=3 consecutive samples ═════════════════════════════════════════════════
echo "── persistence (N=3) ──"
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64)"
STARVE_SAMPLES=3
out="$(run check)"; assert_eq "$?" "0" "sample 1 is STARVED but below threshold"
assert_contains "$out" "streak=1/3" "and it names the streak"
assert_absent "$(cat "$GH_DIR/gh.actions" 2>/dev/null)" "POST" "sample 1 does NOT heal yet"
out="$(run check)"; assert_contains "$out" "streak=2/3" "sample 2 counts the streak"
assert_absent "$(cat "$GH_DIR/gh.actions" 2>/dev/null)" "POST" "sample 2 still does NOT heal"
out="$(run check)"; assert_contains "$out" "streak=3/3" "sample 3 reaches the threshold"
assert_contains "$(cat "$GH_DIR/gh.actions")" "POST" "sample 3 runs the ladder"
STARVE_SAMPLES=1

# a non-starved sample resets the streak
reset_gh; seed_queued 5; seed_runners "$(row 1 r1 online false self-hosted-x64)"
STARVE_SAMPLES=3
run check >/dev/null 2>&1
run check >/dev/null 2>&1
seed_queued 0
out="$(run check)"
assert_contains "$out" "state=IDLE" "an IDLE sample after two starved ones"
assert_eq "$(cat "$STATE/ci-runner-starvation.state")" "starved_streak=0" "and it RESET the streak"
STARVE_SAMPLES=1

# ══ 5. MUTATION: the busy-guard is load-bearing ═════════════════════════════════════════════
# Shipped: step 2 skips a runner that is busy at the moment of restart (a TOCTOU the probe could
# not have seen). Mutant (guard removed): it restarts the busy runner — a live job dies.
echo "── mutation: never restart a busy runner ──"
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64)" "$(row 2 r2 online false self-hosted-x64)"
# step 1 must NOT heal (so the ladder reaches step 2), and step 2's read (the 6th) sees r2 busy.
# Read order: probe(1), step1 enumerate(2), verify r1(3), verify r2(4), after_step probe(5),
# step2 enumerate(6).
printf '%s\n' "$(row 1 r1 online false self-hosted-x64)" "$(row 2 r2 online true self-hosted-x64)" >"$GH_DIR/override.runners.6"
# ⛔ exported, not a command-prefix: a `VAR=x out="$(run …)"` prefix does NOT reach the subshell's
# child, so the fake gh would read GH_FLOW_ON_LABEL as unset and heal at step 1 (never reaching step 2).
export GH_FLOW_ON_LABEL=0
out="$(run check)"
unset GH_FLOW_ON_LABEL
assert_contains "$out" "step2: runner=2 name=r2 busy — skipped" "shipped step 2 SKIPS the busy runner"
assert_contains "$(cat "$GH_DIR/systemctl.log")" "restart actions.runner.acme-tortoise.r1.service" \
  "the non-busy runner r1 WAS restarted"
assert_absent "$(cat "$GH_DIR/systemctl.log")" "actions.runner.acme-tortoise.r2.service" \
  "the busy runner r2 was NOT restarted (never kill a live job)"

# mutate: make the busy-guard unconditional (restart regardless of busy)
MUT="$T/mutant-busy.sh"
python3 - "$HEALER" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = 'if [ "$busy" = true ]; then'
assert text.count(needle) == 1, "the busy-guard moved: update the mutation target"
open(dst, "w", encoding="utf-8").write(text.replace(needle, 'if false; then'))
PY
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64)" "$(row 2 r2 online false self-hosted-x64)"
printf '%s\n' "$(row 1 r1 online false self-hosted-x64)" "$(row 2 r2 online true self-hosted-x64)" >"$GH_DIR/override.runners.6"
mut_out="$(GH_FLOW_ON_LABEL=0 CI_RUNNER_LABELS_LIB="$SCRIPT_DIR/lib/ci-runner-labels.sh" \
  STARVE_GH="$BIN/gh" STARVE_SYSTEMCTL="$BIN/systemctl" STARVE_POOL="$BIN/pool" \
  STARVE_STATE_DIR="$STATE" STARVE_PLATFORM=Linux STARVE_RUNNER_ROOT="$ROOT" STARVE_SAMPLES=1 \
  STARVE_WAIT_BUSY_S=1 STARVE_WAIT_BUSY_POLL_S=1 \
  bash "$MUT" check 2>&1)"
assert_contains "$(cat "$GH_DIR/systemctl.log")" "actions.runner.acme-tortoise.r2.service" \
  "the MUTANT restarted the busy runner — so case 5 pins the busy-guard (the suite reddens on the mutant)"

# ══ 6. MUTATION: additive add, never a replace ══════════════════════════════════════════════
# Shipped: POST (additive) — a runner carrying an extra custom label keeps it. Mutant: PUT (replace)
# would drop the label the gate did not add.
echo "── mutation: additive, never a replace ──"
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64,extra-label)"
out="$(run check)"
assert_contains "$(cat "$GH_DIR/gh.actions")" "POST id=1 labels=ubuntu-latest" \
  "the shipped healer POSTs only the missing label (additive)"
assert_contains "$out" "step 1 CLEARED the invariant" "and heals"
# after the additive POST the runner STILL carries extra-label (the fake gh merged, not replaced)
assert_contains "$(cat "$GH_DIR/state.tsv")" "extra-label" "the extra custom label SURVIVES an additive add"

MUT2="$T/mutant-replace.sh"
python3 - "$HEALER" "$MUT2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = 'api -X POST "repos/$STARVE_REPO/actions/runners/$id/labels"'
assert text.count(needle) == 1, "the label-write moved: update the mutation target"
open(dst, "w", encoding="utf-8").write(text.replace(needle, 'api -X PUT "repos/$STARVE_REPO/actions/runners/$id/labels"'))
PY
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64,extra-label)"
mut_out="$(CI_RUNNER_LABELS_LIB="$SCRIPT_DIR/lib/ci-runner-labels.sh" \
  STARVE_GH="$BIN/gh" STARVE_SYSTEMCTL="$BIN/systemctl" STARVE_POOL="$BIN/pool" \
  STARVE_STATE_DIR="$STATE" STARVE_PLATFORM=Linux STARVE_RUNNER_ROOT="$ROOT" STARVE_SAMPLES=1 \
  bash "$MUT2" check 2>&1)"
assert_contains "$(cat "$GH_DIR/gh.actions")" "PUT id=1" \
  "the MUTANT REPLACED the label set — so case 6 pins the additive rule (the suite reddens on the mutant)"

# ══ 7. escalation bound: step 4 fires within the bound and does not spin ═════════════════════
echo "── escalation bound ──"
reset_gh; seed_queued 5
seed_runners "$(row 1 r1 online false self-hosted-x64)"
export GH_FLOW_ON_LABEL=0 SYSCTL_RESTART_FAIL=1 POOL_RC=2
out="$(run check)"
esc_rc=$?
unset GH_FLOW_ON_LABEL SYSCTL_RESTART_FAIL POOL_RC
assert_eq "$esc_rc" "4" "a permanently broken pool exits 4 (filed + visible)"
assert_contains "$out" "STARVED-UNHEALED" "and SAYS so"
assert_contains "$out" "step4: tracker issue filed" "the tracker issue was filed"
assert_eq "$(grep -c 'issue create' "$GH_DIR/gh.log" 2>/dev/null || printf 0)" "1" \
  "exactly ONE tracker issue (no spin)"
assert_eq "$(grep -c 'restart ' "$GH_DIR/systemctl.log" 2>/dev/null || printf 0)" "1" \
  "exactly ONE runner restart attempt (the ladder is a fixed sequence, not a retry loop)"
assert_contains "$(cat "$GH_DIR/pool.log")" "reconcile" "step 3 delegated to the pool once"

echo "───────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo "❌ $FAIL assertion(s) failed, $PASS passed"
  exit 1
fi
echo "✅ all $PASS assertions passed"
