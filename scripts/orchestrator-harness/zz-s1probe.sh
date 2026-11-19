#!/usr/bin/env bash
# capacity-transfer.test.sh — R8: a capacity refusal must stay ELIGIBLE on another machine
# (agent-infra#1909).
#
# WHAT WAS BROKEN, and how each section is RED on the pre-change tree.
#
#   The harness already recorded refusals (`spawn-gate.sh`'s 75/77, the controller's `[cap]` line),
#   and nothing downstream could tell a REFUSED lane from a WORKING one. Two consequences, both
#   measured-shaped:
#
#   • `chain-merge.sh` waited its full 90 minutes for a PR that no agent could ever open, and the
#     whole time it held this box's cross-box claim `refs/claims/issue-<N>`. Every peer's
#     `claim_issue_preflight` reads a live claim as COLLISION, so ONE box's load spike made the
#     issue ineligible on ALL FIVE boxes. That is the reported 2026-10-17 stall: 47 P0/P1 issues
#     untouched while ~20 vCPU and ~35 GB sat idle on the same account.
#       → §2 is RED pre-change because `lane.sh` writes no refusal record at all, so `chain-merge.sh`
#         has nothing to read and waits (the bounded watchdog in this suite kills it and the check
#         reports "did not exit early").
#
#   • nothing stopped the refusing box from re-winning the claim on the next cycle and being
#     refused again, so the peers it had just yielded to never got the issue.
#       → §3 is RED pre-change because `capacity_yield_live()` does not exist in `orch-loop.sh`
#         (the extraction fails loudly, the way test-gates.sh's does).
#
#   §1 (the writer) is RED pre-change for the plainest reason: on the pre-change tree the gate
#   refuses and NOTHING is written to `$O/state`.
#
#   §2b3 (the epoch bound's BOUNDARY, round-2 review P2) is RED on the round-1 shape: with the slack
#   knob at or above the record's own yield window, `min()` returned the window itself and the bound
#   admitted the PREVIOUS dispatch's record at the one second this box may first re-dispatch. The
#   check reds on that shape — measured `50 passed / 2 failed` with this suite against the ROUND-1
#   scripts (i.e. the reviewed head, HEAD before the clamp), both reds being this section's boundary
#   check and its mutation control — and the section carries its own mutation control, so it cannot
#   rot into a green check that the clamp is not what makes it green.
#
# HOW THESE ARE WRITTEN. Every check drives the SHIPPED script it names — `lane.sh`,
# `chain-merge.sh`, `cap_refusal_gate()` extracted from the live `chain-merge.sh`, and
# `capacity_yield_live()` / `dispatch_funnel()` extracted from the live
# `orch-loop.sh` (never re-implemented: a copy would pass on the broken tree too). `pi`, `df` and `gh`
# are stubbed, so the suite is hermetic: no network, no model, and a LOCAL bare repo stands in for the
# shared origin, so §2's claim release is a real fenced push and not a mock.
#
# ⛔ THE STUBS ARE EXPORTED FUNCTIONS, NOT FILES ON PATH (round-1 review, P2). `lane.sh` and
# `chain-merge.sh` both begin with `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts
# two ABSOLUTE dirs AHEAD of any PATH this suite supplies — so a PATH-ordered stub loses to the
# machine's real binary. Measured while writing §1c: the `pi` stub was dead on this very runner
# (`/usr/local/bin/pi` exists) and a live agent ran for 98 s. The same hole was open for `gh` on any
# macOS deployment box (`/opt/homebrew/bin/gh` is the standard install, and the prepend exists
# BECAUSE that is where the deployed `gh` lives) — a real, authenticated `gh pr list` from a suite
# whose header promises "no network". An exported bash function is resolved before any PATH lookup,
# and the markers below prove it answered (a stub that silently did not is the false green).
#
# ⛔ `rc=$?` IS CAPTURED IMMEDIATELY AFTER EVERY TESTED COMMAND — never inline inside a `ck`
# argument, where a `$(…)` substituion would silently supply the status of `cat` instead.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⛔ THE CAPABILITY GATE IS DISABLED FOR THE ARMS IN THIS FILE, BY NAME AND ON PURPOSE (agent-infra#2935).
# `run_agent` measures the box — one bounded `pi` call — immediately before every launch, and these
# arms drive `run_agent` with a STUB `pi` that never emits the probe's answer token. With the gate live
# here, each arm would spend up to 2 x LANE_PREFLIGHT_BOUND on a stub and then be REFUSED by a gate
# this file is not testing, so an arm about the LOAD or DISK gate would report a capability refusal.
# The capability gate has its own arms (`cell-lane-preflight.test.sh`, and the capability block in
# `spawn-gate.test.sh`, which re-enables it with LANE_PREFLIGHT=1). This is the documented operator
# escape, declared where it applies — not a silent bypass: unsetting it here turns the gate back on and
# these arms go red, which is the assertion that the line is load-bearing rather than decorative.
export LANE_PREFLIGHT=0
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
O="$TMP/O"; mkdir -p "$O/state" "$O/logs" "$TMP/bin"
# ⛔ THE MEMORY GATE'S NEUTRALISER (agent-infra#2387), for exactly the reason every arm below pins
# `DISK_MIN_FREE_MB=1`: since #2387 `run_agent` refuses a spawn when available memory is below its
# floor, so without this a memory-tight box answers 84 to a LOAD arm and the suite reports a
# capacity-transfer regression that is not one. It is a FLOOR, not a switch — there is still a probe,
# still a comparison, still a refusal path (driven in spawn-gate.test.sh §12, which owns the floor's
# arithmetic and asserts the shipped default under `env -u`).
export MEM_MIN_AVAIL_MB=1
LANE="$HERE/lane.sh"; CHAIN="$HERE/chain-merge.sh"; ORCH="$HERE/orch-loop.sh"; CLAIMS="$HERE/claims.sh"
for f in "$LANE" "$CHAIN" "$ORCH" "$CLAIMS"; do
  [ -s "$f" ] || { echo "❌ missing $f"; exit 2; }
done

# ⛔ A COMPLIANT BRIEF FIXTURE (#2258): `run_agent` now runs the research-first gate BEFORE the load,
# disk, land-backlog and fork gates, so a fixture whose whole body is `prompt` is refused with 80 and
# every arm below that asserts a CAPACITY outcome reads that refusal instead of its subject (measured
# on this suite: 8 arms — `bgrc=80` and `frc=80` where 74 and 0 were wanted, and the land-backlog lines
# they grep for never appear). RENDERED from the shipped validator, never hand-typed, so the fixture
# cannot drift from the gate’s own advice — the same rule `spawn-gate.test.sh` follows.
BRIEF_OK="$TMP/brief-ok.txt"; export BRIEF_OK   # every driver below is a `bash -c` child
{ printf 'RESEARCH FIRST\n'; "$HERE/brief-gate.sh" --section lane; } > "$BRIEF_OK"
[ -s "$BRIEF_OK" ] || { echo "❌ could not render the compliant brief fixture"; exit 2; }

echo "==> capacity-transfer self-test ($HERE)"

# ⛔ THE MODEL-CREDENTIAL GATE IS DECLARED OFF FOR THIS SUITE, BY NAME AND ON PURPOSE (agent-infra#3331).
# `lane.sh` asserts, immediately before it spawns `pi`, that the lane's own environment holds the
# credential its provider resolves from `models.json`. These arms STUB `pi` — the credential is not what
# they measure — and a fixture that inherited whatever key the runner happens to have would be a false
# GREEN on one box and a false RED on another (the same defect provider-credential.test.sh records for
# `PI_LANE_*`).
# ⛔ THE ESCAPE IS ARGV, NOT AN ENVIRONMENT VARIABLE (review, P1). It used to be `export LANE_KEY_GATE=0`
# here — which worked in this suite and was, in the same breath, a fleet-wide off switch: on a cell the
# controller sources `keys.env` under `set -a`, so any descendant lane inherited the value and the gate
# never ran, while the suite stayed green. `--key-gate-off` on the invocation cannot be inherited, so a
# box cannot turn the assertion off for every lane it dispatches; `lane-outcome.test.sh` pins both
# directions (the flag skips, the variable is IGNORED and reported). The escape is still loud: every run
# here logs `[key-gate] … check=skipped reason=--key-gate-off`.

# ── stubs on PATH ────────────────────────────────────────────────────────────────────────────────
# `pi` must NEVER be reached by a refusing gate; when §1c lets an agent run it records that it did.
PI_LOG="$TMP/pi.log"; : > "$PI_LOG"; export PI_LOG
cat > "$TMP/bin/pi" <<STUB
#!/usr/bin/env bash
echo "RAN \$*" >> "$PI_LOG"
exit 0
STUB
# `df` reports ~0 MiB free in the 4th column (1 KiB blocks) when STUB_DISK_FULL=1, so the disk gate
# is refused deterministically on ANY filesystem — the suite must not depend on how full the runner's
# /tmp is — and delegates to the REAL `df` otherwise (the load cases need a real reading). It is
# switched per CASE by the variable, not by PATH, because the scripts under test re-prepend absolute
# dirs (see the header): a PATH-ordered `df` only wins by luck of the runner's prefix layout.
mkdir -p "$TMP/dbin"
cat > "$TMP/dbin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1000 999 1 100%% /\n'
STUB
# `gh pr list` finds no PR, ever: that is the whole point (no agent ran, so no PR can exist).
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
shift 0
exit 0
STUB
chmod +x "$TMP/bin/pi" "$TMP/dbin/df" "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"; export PATH

# ── the CREATION back-pressure readings (agent-infra#2409) ────────────────────────────────────
# `run_agent` now measures the repo's landing ratio before it starts a CREATION worker (#2409), via
# spawn-gate.sh's `land_backlog_*`. That is a gh read of the repo the worktree's origin names, so
# every arm that lets a lane actually start must SUPPLY the reading — the same rule #2333 applied to
# its CI-queue gate: an env var that switches a gate off would not be a gate, so the reading is given.
# ⛔ IT IS GIVEN THE WAY A BOX GIVES IT: by installing `$O/gh-rest/gh`, the REST adapter that
# `lane.sh`/`fix-one.sh` prepend to PATH (install.sh ships it; it is in the drift list). There is
# deliberately NO `LB_GH`-style env seam — review cycle 1 reproduced one opening the gate on a repo
# with 82 open PRs, and §LB pins that setting it now changes nothing.
#
# Shapes, all against `daniel-ospina/agent-infra` (the slug the fixture worktree's origin names):
#   lbgh-ok     3 open  / 40 landings in the last 24h -> ceiling 40 -> OK
#   lbgh-deep  81 open  / 15 landings in the last 24h -> ceiling 15 -> LAND-BACKLOG
#   lbgh-broken  every read fails                    -> UNREADABLE (must HOLD, never OK)
#   lbgh-p0     lbgh-deep + issue labelled P0-blocker    -> EXEMPT
#   lbgh-basered lbgh-deep + issue title 'main is red…'  -> EXEMPT
#   lbgh-paged 250 open in 3 pages / 10 landings last 24h, 40 the 24h before -> OK (both rules)
#   lbgh-nopr   lbgh-deep with NO PR at this worktree    -> a `prfix` claim is UNPROVABLE, so the
#               RATIO decides (deep backlog here -> HOLD); the same claim UNDER the ceiling RUNS
lbgh_shape() { # <file> <open1> <open2(page 2+)> <lands-last-24h> <lands-prior-24h> [labels] [title] [branch-rule PR#] [PR-head-sha] [commit-rule PR#]
  local f="$1" o1="$2" o2="$3" l24="$4" p24="$5" lab="${6:-}" ti="${7:-a normal issue}"
  local prn="${8:-1}" prhead="${9:-HEAD}" pstate="${10:-open}"
  # @PSTATE@ is the FIRST open-listing object's state: `closed` is the shape that proves the gate's
  # `select(.state=="open")` is load-bearing (without it, a commit on `main` "proves" itself via the
  # MERGED PR that introduced it — measured, and it left the suite green before this arm existed).
  # A QUOTED heredoc, so nothing here is expanded by the test shell; the @TOKENS@ are the only
  # substitutions. `\001` is the field separator the reader cuts on, and bash's printf interprets it
  # in the FORMAT string (the stub's shebang is bash), so the label/title pair arrives verbatim.
  sed -e "s|@O1@|$o1|g" -e "s|@O2@|$o2|g" -e "s|@L24@|$l24|g" -e "s|@P24@|$p24|g" \
      -e "s|@LAB@|$lab|g" -e "s|@TITLE@|$ti|g" -e "s|@PRN@|$prn|g" -e "s|@PRHEAD@|$prhead|g" \
      -e "s|@PSTATE@|$pstate|g" > "$f.raw" <<'STUB'
#!/usr/bin/env bash
# ⛔ THE EVIDENCE ARMS MUST APPLY THE GATE'S OWN `--jq`, OR THEY TEST PLUMBING INSTEAD OF LOGIC.
# A stub that prints a fixed answer regardless of the filter makes the gate's selection UNEXERCISED:
# measured in review cycle 5, breaking the commit rule's `select(.state=="open")` (and the branch
# rule's whole body) left the suite GREEN, because the stub never looked at the filter. These two arms
# therefore emit JSON and run the filter the gate passed, like `$O/gh-rest/gh` does.
jqf() { local a prev=""; for a in "$@"; do if [ "$prev" = "--jq" ]; then printf '%s' "$a"; return 0; fi; prev="$a"; done; return 1; }
cjq() { local f; if f="$(jqf "$@")"; then printf '%s\n' "$1" | jq -r "$f"; else printf '%s\n' "$1"; fi; }
case "$*" in
  *broken*) exit 1 ;;
  # ⛔ THE `prfix` EXEMPTION'S EVIDENCE, AND THE STUB MUST TELL THE TWO RULES APART (review cycle 5,
  # P2-4: with one answer for every `pr list`, BOTH rules could be broken and the suite stayed green).
  #   rule 1 (branch): `gh pr list --head <br> --json number,headRefOid` -> "<pr#> <headRefOid>"
  #                                       → @PRN@ @PRHEAD@   (the gate compares the sha to this HEAD)
  *pr\ list*headRefOid*) cjq "[{\"number\":@PRN@,\"headRefOid\":\"@PRHEAD@\"}]" "$@"; exit 0 ;;
  #   rule 2 (commit): the BASE repo's open-PR listing, ONE PAGE, filtered by the gate's own jq. The
  #   FIRST object is the controllable one: number @PRN@, state @PSTATE@, head.sha @PRHEAD@. The rest
  #   are decoys with an unrelated sha, so "found a PR" can never stand in for "found THIS head".
  #   ⛔ THE COUNT READER HITS THE SAME URL with `--jq length`, so the array IS the count — which is
  #   what makes the state/head selects testable at all (dropping `select(.state=="open")` was
  #   measured GREEN before this shape existed: a commit on `main` "proved" itself via the MERGED PR
  #   that introduced it).
  *pr\ list*) printf '%s\n' "@PRN@"; exit 0 ;;
  *"/issues/"*) printf '%s\001%s\n' "@LAB@" "@TITLE@"; exit 0 ;;
  # ⛔ `&page=1 ` — WITH THE TRAILING SPACE: the URL also carries `per_page=100`, which CONTAINS the
  # substring `page=1`, so a loose glob served page 1 for every page (measured: 5 x 100 = "500 open"
  # for a 150-PR fixture, and the reader could not tell it from a real 500).
  *state=open*'&page=1 '*)
    js=""; i=0
    if [ "@O1@" -gt 0 ]; then
      js="{\"number\":$(( @PRN@ > 0 ? @PRN@ : 9000 )),\"state\":\"@PSTATE@\",\"head\":{\"sha\":\"@PRHEAD@\"}}"
      i=1
      while [ "$i" -lt "@O1@" ]; do js="$js,{\"number\":$(( 9100 + i )),\"state\":\"open\",\"head\":{\"sha\":\"dddddddddddddddddddddddddddddddddddddddd\"}}"; i=$(( i + 1 )); done
    fi
    cjq "[$js]" "$@"; exit 0 ;;
  *state=open*)
    js=""; i=0
    while [ "$i" -lt "@O2@" ]; do js="$js${js:+,}{\"number\":$(( 9200 + i )),\"state\":\"open\",\"head\":{\"sha\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}}"; i=$(( i + 1 )); done
    cjq "[$js]" "$@"; exit 0 ;;
  # PAGE 2 HAS NOTHING: the real listing is paged, and a stub that re-served page 1 doubled every
  # count, which the reader cannot tell from a genuinely longer list (measured: it did).
  *state=closed*page=2*) exit 0 ;;
  *state=closed*)
    for i in $(seq 1 @L24@); do printf '%s\n' "$(( $(date +%s) - (i % 20) * 3600 ))"; done
    for i in $(seq 1 @P24@); do printf '%s\n' "$(( $(date +%s) - 86400 - (i % 20) * 3600 ))"; done
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  mv "$f.raw" "$f"
  chmod +x "$f"
}
# Install/uninstall the adapter the tested scripts actually resolve (see above).
lbgh_install() { mkdir -p "$O/gh-rest"; cp "$1" "$O/gh-rest/gh"; chmod +x "$O/gh-rest/gh"; }
lbgh_clear()   { rm -f "$O/gh-rest/gh"; rmdir "$O/gh-rest" 2>/dev/null || true; }
lbgh_shape "$TMP/lbgh-ok"      3  0   40 0
lbgh_shape "$TMP/lbgh-deep"   81  0   15 0
lbgh_shape "$TMP/lbgh-paged" 100 50  120 0
lbgh_shape "$TMP/lbgh-prior"  30  0   10 40
# A gh chain that cannot answer AT ALL (agent-infra#2320's shape): every read fails, so the ratio is
# UNREADABLE. It is its own file rather than a `lbgh_shape` marker because the shape stub dispatches
# on the ARGUMENTS, which never contain the word "broken".
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/lbgh-broken"; chmod +x "$TMP/lbgh-broken"
lbgh_shape "$TMP/lbgh-p0"     81  0   15 0 "P0-blocker,harness" "crash on boot"
lbgh_shape "$TMP/lbgh-basered" 81 0   15 0 "bug" "main is red: lander.test.sh pipes"
lbgh_shape "$TMP/lbgh-nopr"    81  0   15 0 "bug" "a normal issue" 0
# A worktree whose origin names a real GitHub slug — the gate DERIVES the repo (there is no `LB_REPO`
# env over-ride on purpose: pointing it at an empty repo would be a bypass). No commits needed; the
# gate only reads `remote.origin.url`.
LBWT="$TMP/lbwt"; mkdir -p "$LBWT"
( cd "$LBWT" && git init -q . && git remote add origin https://github.com/daniel-ospina/agent-infra.git \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git checkout -q --detach ) >/dev/null 2>&1
# ⛔ THE LANE'S CWD MUST BE THE TARGET REPO (agent-infra#2724/#2694). lane.sh now asserts the
# worktree's origin against the repo it was dispatched for and REFUSES (72) when they disagree — the
# measured wrong-repo lane. These fixtures drive the GATE, not the repo check, so their cwd is a real
# checkout of the repo they name. A `cd "$TMP"` (a plain temp dir) would be the very defect the
# assertion exists to catch, and the suite would report gate regressions that are not regressions.
LANECWD="$TMP/lanecwd"; mkdir -p "$LANECWD"
( cd "$LANECWD" && git init -q . && git remote add origin https://github.com/daniel-ospina/agent-infra.git \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git checkout -q --detach ) >/dev/null 2>&1
# A SECOND fixture WITH A COMMIT (and therefore a branch name). `git rev-parse --abbrev-ref HEAD` is
# what the `prfix` evidence reads, and it fails on a repo with no commits — so the positive arm needs a
# tree a branch can be named in, while the negative arm must be a real "branch exists, no PR" case.
LBWT2="$TMP/lbwt2"; mkdir -p "$LBWT2"
( cd "$LBWT2" && git init -q . && git remote add origin https://github.com/daniel-ospina/agent-infra.git \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git checkout -q --detach ) >/dev/null 2>&1

# The AUTHORITATIVE stubs: exported functions (see the header). Each records that it answered, so a
# stub the tested script never resolved cannot pass as "stubbed".
GH_FUNC_MARK="$TMP/gh-func.mark"; DF_FUNC_MARK="$TMP/df-func.mark"; GH_LOG="$TMP/gh-calls.log"
: > "$GH_LOG"
# BOTH paths are exported: the tested scripts run under `set -u`, so a function referencing a
# non-exported variable ACROSS an exec boundary aborts with `unbound variable` — which reads as "the
# chain failed" and is the wrong reason for a red check.
export GH_FUNC_MARK DF_FUNC_MARK GH_LOG STUB_DISK_FULL
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"; printf 'used\n' > "$GH_FUNC_MARK"
  # ⛔ A `gh` BASHLESS-FUNCTION OUTRANKS EVERY PATH LOOKUP, so it would SHADOW the box's own REST
  # adapter (`$O/gh-rest/gh`, which lane.sh/fix-one.sh prepend to PATH). The creation gate reads its
  # measurement through exactly that adapter (there is no env seam, by design — see §LB), so this
  # stub defers to one when it is installed, which is what a real box's PATH does too.
  if [ -x "${O:-}/gh-rest/gh" ]; then command "$O/gh-rest/gh" "$@"; return $?; fi
  return 0
}
df() {
  printf 'used\n' > "$DF_FUNC_MARK"
  if [ "${STUB_DISK_FULL:-0}" = "1" ]; then
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1000 999 1 100%% /\n'
    return 0
  fi
  command df "$@"   # `command` bypasses this function: the real reading, by absolute resolution
}
export -f gh df 2>/dev/null || true

# run_bounded <seconds> <command…> — runs a command under a watchdog and exposes BOUNDED_RC /
# BOUNDED_OUT. Needed because the PRE-CHANGE `chain-merge.sh` waits 90 x 60 s; without a bound this
# suite would hang instead of reporting the regression. 124 = it outlived the bound.
run_bounded() {
  local lim="$1"; shift
  local outp="$TMP/bounded.$$.out" pid i
  "$@" > "$outp" 2>&1 &
  pid=$!
  wait_bounded "$pid" "$lim"
  BOUNDED_OUT="$(cat "$outp" 2>/dev/null)"; rm -f "$outp"
}
# wait_bounded <pid> <seconds> — the watchdog on its own, for a background command that must be
# STARTED before the test does something else (the production race in §2a2).
wait_bounded() {
  local pid="$1" lim="$2" i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$lim" ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; BOUNDED_RC=124
  else
    wait "$pid" 2>/dev/null; BOUNDED_RC=$?
  fi
}

# ═══ §1 THE WRITER — `lane.sh` records the refusal, with the yield and the gate that fired ═══════
echo
echo "=== §1 the refusal becomes a durable record (state/capacity-refused-<N>) ==="
# The yield length is pinned to a non-default value so the check is not satisfied by the default.
LANE_YIELD=120
BEFORE="$(date +%s)"
( cd "$LANECWD" && O="$O" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" \
    CAPACITY_YIELD_SECS=$LANE_YIELD bash -x "$LANE" --key-gate-off 7 feat/7-tm daniel-ospina/agent-infra ) > "$TMP/lane7.out" 2>&1
lrc=$?
AFTER="$(date +%s)"
REC="$O/state/capacity-refused-7"
{ [ "$lrc" -eq 75 ] && [ -f "$REC" ]; }; rc=$?
ck "a LOAD refusal (exit 75) writes state/capacity-refused-7" $rc

ep=""; until=""; gate=""
[ -f "$REC" ] && read -r ep until gate < "$REC"
{ [ -n "${ep:-}" ] && [ "$ep" -ge "$BEFORE" ] && [ "$ep" -le "$AFTER" ]; }; rc=$?
ck "field 1 is THIS refusal's epoch (${ep:-<none>} within [$BEFORE,$AFTER]) — the per-dispatch bound" $rc
[ "$(( ${until:-0} - ${ep:-0} ))" -eq "$LANE_YIELD" ]; rc=$?
ck "field 2 is field1 + CAPACITY_YIELD_SECS ($LANE_YIELD), not the 900 default" $rc
[ "${gate:-}" = "load" ]; rc=$?
ck "field 3 names the gate that actually fired ('load', got '${gate:-<none>}')" $rc
{ [ ! -s "$PI_LOG" ]; }; rc=$?
ck "no agent was started by the refused lane (the gate, not the record, did the refusing)" $rc
grep -q 'capacity transfer' <<<"$(cat "$O/logs/lane-7.log" 2>/dev/null)"; rc=$?
ck "the lane log states the transfer (an operator can see the release is coming)" $rc

# The DISK gate reports itself as 'disk': the two refusals have opposite remedies, so a record that
# said 'load' on a full filesystem would send the operator to wait for an event that cannot arrive.
rm -f "$DF_FUNC_MARK"
( cd "$LANECWD" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=500 DISK_GATE_PATH="$TMP" STUB_DISK_FULL=1 \
    CAPACITY_YIELD_SECS=$LANE_YIELD bash "$LANE" --key-gate-off 8 feat/8-tm daniel-ospina/agent-infra ) > "$TMP/lane8.out" 2>&1
l8rc=$?
dgate=""
[ -f "$O/state/capacity-refused-8" ] && { read -r _d1 _d2 dgate < "$O/state/capacity-refused-8"; }
{ [ "$l8rc" -eq 77 ] && [ "${dgate:-}" = "disk" ]; }; rc=$?
ck "a DISK refusal (exit 77) records gate='disk' (rc=$l8rc, gate='${dgate:-<none>}')" $rc
# The disk reading must be the STUB's, not whatever `df` the box happens to have (the failure mode
# this override exists for: a PATH stub silently losing to /opt/homebrew or /usr/local).
{ [ -s "$DF_FUNC_MARK" ]; }; rc=$?
ck "  …and the exported df stub answered (not a real filesystem reading — a PATH stub loses to the scripts' PATH prepend)" $rc

# ── THE FORK REFUSAL IS CONSUMED AS `fork`, NOT BUCKETED AS `load` (review P1, agent-infra#2293) ──
# `spawn-gate.sh` gained a THIRD refusal code (73, fork) before the disk (77) and load (75) gates, and
# ⛔ 73, NOT 74: 74 is AGENT_LAND_BACKLOG (§LB below shares this file), and the two remedies are
# opposite — a shared code let `fork` and `land` refusals be labelled as each other, which is the
# instrument false positive both issues exist to delete. The batch's integration review caught it.
# `spawn-gate.sh`'s own comment states the contract this arm pins: "a caller that reads a fork refusal as a load
# refusal retries forever on a box that cannot start a process to retry with." Before this arm the
# writer folded every code except disk into `load`, so a fork refusal published the LOAD remedy and
# its remedy line said "load gate" — the two failures the issue names.
# Driven through the SHIPPED lane.sh: only the headroom SOURCE is faked (10 spare pids against the
# shipped 200 margin), by exporting the two capacity functions the gate consumes, so the gate, the
# refusal code, the record and the log line are all the real ones.
rm -f "$O/state/capacity-refused-17"
# ⛔ THE CREATION-BACK-PRESSURE GATE SITS ON THIS SAME PATH, AND A FAILED READ IS NOT AN OK (#2409,
# measured 2026-11-10). This arm sets `MAX_LOAD=999999`, so the only things ahead of the fork gate are
# the disk one (cleared) and the fork one — but BELOW them sits the land-backlog gate, which reads this
# repo's LIVE open-PR count and landing rate through the `$O/gh-rest/gh` adapter. With no adapter
# installed that read FAILS, the gate answers 74 (`UNREADABLE open-PR count` — correctly, a measurement
# that cannot be taken is never an OK), and the lane refused with `gate='land'` instead of `fork`:
# the arm measured a gate it does not name. The reading is therefore SUPPLIED as a box supplies it, the
# same `lbgh_install`/`lbgh_clear` pairing the stale-record arm and §LB already use. The gate still runs
# for real; only its measurement is a fixture. ⛔ It is supplied HERE and not to §1's load/disk arms
# above, deliberately: those sit ABOVE the creation gate and must be decided by the capacity gate —
# and on a box whose `keys.env` raises `MAX_LOAD` (the documented, credentials-file-authoritative
# reading) they fall through to the creation gate and red locally. Supplying it there too would let
# that box REACH A LIVE AGENT on an arm that is supposed to refuse, which is strictly worse than a
# local-only false red.
lbgh_install "$TMP/lbgh-ok"
( cd "$LANECWD"
  # shellcheck shell=bash
  cap_procs_pair_vars() { printf -v "$1" '%s' 15631; printf -v "$2" '%s' 15641; printf -v "$3" '%s' uid; }
  # ⛔ ALL THREE OF `SPAWN_GATE_CAP_NEEDS` MUST BE FAKED, OR NONE OF THEM ARE USED (#3231 follow-up,
  # measured 2026-11-10). `spawn-gate.sh` accepts a PRELOADED capacity module only when it provides
  # EVERY function in `SPAWN_GATE_CAP_NEEDS` (`cap_procs_pair_vars cap_h_for_vars cap_fork_probe`);
  # with one missing it falls through to the candidate walk and SOURCES a real `capacity.sh` over all
  # of them. `cap_fork_probe` was added to that set by #3231 (the fork floor reading its own
  # instrument), and this fixture was not updated — so the headroom override below was silently
  # DISCARDED, the gate read the box's real headroom, the fork gate passed, and the run fell through
  # to the LAND-BACKLOG gate on the live repo's PR count (rc=74 gate='land').
  # The probe is stubbed as `ok` and never decides anything here: the arithmetic arm refuses FIRST
  # (`headroom=10 < CAP_MIN_FORK_HEADROOM=200`), so the refusal below is still the arithmetic's — the
  # property this arm exists to pin — and a real two-fork probe would make the arm depend on the box.
  cap_fork_probe() { return 0; }
  cap_h_for_vars() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
    printf -v "$3" '%s' "$(( $2 - $1 ))"
  }
  export -f cap_procs_pair_vars cap_h_for_vars cap_fork_probe
  O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" CAPACITY_YIELD_SECS=$LANE_YIELD \
    bash "$LANE" --key-gate-off 17 feat/17-tm daniel-ospina/agent-infra
) > "$TMP/lane17.out" 2>&1
l17rc=$?
fgate=""
[ -f "$O/state/capacity-refused-17" ] && { read -r _fg1 _fg2 fgate < "$O/state/capacity-refused-17"; }
{ [ "$l17rc" -eq 73 ] && [ "${fgate:-}" = "fork" ]; }; rc=$?
ck "a FORK refusal (exit 73) records gate='fork', and is NOT bucketed as 'load' (rc=$l17rc, gate='${fgate:-<none>}')" $rc
L17LOG="$(cat "$O/logs/lane-17.log" 2>/dev/null)"
grep -q 'FORK gate refused' <<<"$L17LOG"; rc=$?
ck "  …and the lane log names the FORK remedy (restart or drain the box from outside), not a load wait" $rc
grep -q 'load gate refused' <<<"$L17LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "  …and it is NOT reported as a load refusal — the remedies are opposite, and one of them cannot work" $rc
grep -q 'disk-gate' <<<"$L17LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "  …and the disk gate never ran (fork is evaluated first, so the un-clearable cause is the one named)" $rc
lbgh_clear   # the creation-gate reading supplied for the fork arm is withdrawn here

# A lane that DOES run supersedes an old refusal: otherwise a later chain for the same issue could
# read the stale record. (The epoch bound already protects it; this keeps the state dir clean.)
#
# ⛔ THE `pi` OVERRIDE IS A BASH FUNCTION, PROVEN BEFORE IT IS RELIED ON. `lane.sh` prepends
# `/opt/homebrew/bin:/usr/local/bin` to PATH at its own start, so a PATH-ordered stub CANNOT win:
# measured while writing this file, §1c resolved the machine's REAL `pi` and ran a live agent for
# 98 s. An exported function is resolved before any PATH lookup, and the probe below proves the
# override reaches a bash child *before* lane.sh is launched — if it does not, the check is SKIPPED
# (loudly) rather than silently invoking whatever `pi` this box happens to have.
PI_FUNC_MARK="$TMP/pi-func.mark"
# ⛔ BOTH PATHS ARE EXPORTED: lane.sh runs with `set -u`, and the injected function references these
# two variables ACROSS an exec boundary, so a non-exported one aborts the agent with `unbound
# variable` — which reads as "the lane failed" and is the wrong reason for a red check.
export PI_FUNC_MARK PI_LOG
pi() { echo "RAN $*" >> "$PI_LOG"; printf 'used\n' > "$PI_FUNC_MARK"; return 0; }
export -f pi 2>/dev/null || true
rm -f "$PI_FUNC_MARK"
( pi probe ) >/dev/null 2>&1
if [ -e "$PI_FUNC_MARK" ]; then
  printf '1\t2\tload\n' > "$O/state/capacity-refused-9"
  # The creation gate's reading, supplied as a box supplies it (see the adapter fixtures above).
  lbgh_install "$TMP/lbgh-ok"
  ( cd "$LBWT" && O="$O" MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
      bash "$LANE" --key-gate-off 9 feat/9-tm daniel-ospina/agent-infra ) > "$TMP/lane9.out" 2>&1
  l9rc=$?
  lbgh_clear
  { [ "$l9rc" -eq 0 ] && [ ! -f "$O/state/capacity-refused-9" ]; }; rc=$?
  ck "a lane that RAN clears a stale refusal record (rc=$l9rc, pi invoked=$([ -e "$PI_FUNC_MARK" ] && echo yes || echo no))" $rc
else
  echo "  ⚠️ SKIPPED: the export -f pi override did not reach a bash child, so lane.sh would resolve
              the machine's own pi. Not running a live agent from a regression suite."
fi

# A non-numeric issue id must not be turned into a path — lane.sh is also invoked by hand.
( cd "$LANECWD" && O="$O" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" \
    bash "$LANE" --key-gate-off '../../escape' 'x' daniel-ospina/agent-infra ) > "$TMP/laneesc.out" 2>&1
esc_rc=$?
{ [ ! -e "$TMP/escape" ] && [ ! -e "$O/state/capacity-refused-../../escape" ]; }; rc=$?
ck "a non-numeric issue id writes no record and no path outside \$O/state (rc=$esc_rc)" $rc
echo "=== LANE7 LOG ==="; cat "$O/logs/lane-7.log" 2>/dev/null | grep -E "land-backlog|load-gate|mem-gate|disk-gate|capability|key-gate|NOT started|stand-down" | head -20; echo "=== record ==="; cat "$O/state/capacity-refused-7" 2>/dev/null; echo "=== SUMMARY: PASS=$PASS FAIL=$FAIL ==="
