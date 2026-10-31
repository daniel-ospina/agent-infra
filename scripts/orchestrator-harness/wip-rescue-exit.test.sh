#!/usr/bin/env bash
# wip-rescue-exit.test.sh — the EXIT-PATH contract of agent-infra#2834.
#
# THE DEFECT THIS SUITE EXISTS FOR. The WIP rescue ran on ONE termination path: the wall-clock CAP
# (`cap_wip_snapshot`, #2045). That is not the common one. Measured on a single fleet session of 373
# dispatched lanes: `hit its … cap` appeared in ZERO lane logs, and 148 of those 373 worktrees were
# left holding uncommitted or unpushed work — while `origin` held no `refs/wip/*` attributable to the
# session. So a lane that finishes its turn, stops at a gate or restarts simply ENDED, and nothing
# looked at its tree. The shipped `scripts/bg-rescue-wip.sh` — the tool whose contract survives a
# reaped worktree, because it puts the work under `refs/wip/<slug>` ON ORIGIN — was wired to nothing
# in this repo at all.
#
# WHAT IS ASSERTED, AND WHY IT IS DRIVEN RATHER THAN GREPPED. Every arm below runs the SHIPPED
# `run_agent` (or, for the two resolution arms, the SHIPPED `terminal_wip_rescue`) and then reads the
# REMOTE: `git -C <bare-origin> cat-file` on the pushed tree, not a log line that says a push happened.
# A suite that greps for "rescue" passes on a tree where the call is there and the guard around it is
# wrong — which is exactly how the operator's own copy failed for a whole session (`cd "$WT"` ran
# before `_HERE` was resolved from a RELATIVE `BASH_SOURCE`, so every call named a path that did not
# exist and `[ -f … ] && bash …` degenerated to `false`).
#
# ⛔ NON-VACUITY IS AN ARM, NOT A CLAIM (#2834 ask 4). Arm B drives a copy of `spawn-gate.sh` with the
# exit-path CALL removed and requires the remote ref to be ABSENT. Without it, arm A would pass on a
# tree where any part of the flight — the call, the dirty pre-check, the push — was doing the work,
# and the suite could not tell the fix from an accident.
#
# ⛔ HERMETIC, AND THE ORIGIN IS LOCAL ON PURPOSE. The fixture's `remote.origin.url` is GitHub-SHAPED
# (`https://github.com/owner/repo.git`) because the creation back-pressure gate derives the repo slug
# from that config, and `url.<bare>.insteadOf` rewrites the TRANSPORT to a local bare repo. Both
# properties are needed at once and only this combination has both: `git remote get-url` WOULD follow
# the rewrite, while `repo-slug.sh` reads `git config --local --get remote.origin.url` and therefore
# still sees the GitHub slug. No network, no credentials, no state outside $TMP.
#
# Run:  bash scripts/orchestrator-harness/wip-rescue-exit.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/spawn-gate.sh"
PASS=0; FAIL=0

# ⛔ DEFECT A — THIS SUITE MUST NOT BE A FUNCTION OF THE BOX IT RUNS ON (agent-infra#2935 seam).
# Every arm below drives the SHIPPED `run_agent` with a STUB `pi`. `run_agent` also asks the box one
# bounded question first (`cell-lane-preflight.sh`, #2935) — "can you complete one model call and
# RETURN?" — and this suite has no business answering it: the stub never emits the probe's answer
# token, so with the gate live every arm here would be measured against a gate this file is not
# testing. On a DEV BOX that usually went unnoticed because the gate passed for its own reasons
# (an ambient provider key, a real `pi` on PATH); on a CI RUNNER it does not: there is no `pi`
# install, the probe reports `why=pi-missing`, `run_agent` returns 71 (`AGENT_CAPABILITY_REFUSED`)
# BEFORE any spawn, and all 14 rescue arms cascaded into a false red — a red that cost a lane a whole
# triage cycle because of DEFECT B below (the suite discarded the child's output, so the refusal
# arrived as `rc=71 started=0` with NO reason attached).
#
# THE SEAM IS THE HARNESS'S OWN, NOT AN AD-HOC `if` IN THIS FILE: `LANE_PREFLIGHT=0` is the escape
# `spawn-gate.sh` documents on the refusal line itself ("Override with LANE_PREFLIGHT=0 once an
# operator has measured it by hand"), and it is the same declaration its sibling suites make for the
# same reason (`spawn-gate.test.sh`, `brief-gate.test.sh`, `capacity-transfer.test.sh`,
# `lane-bound.test.sh`) — with the capability gate's OWN arms kept where they belong: the capability
# block in `spawn-gate.test.sh` and `cell-lane-preflight.test.sh`.
#
# ⛔ AND IT IS DECLARED, NOT SILENT: a skip would have been the WRONG instrument here. A skip is a
# MACHINE-DEPENDENT verdict — it can hide a genuine failure on a machine that DOES have the
# capability, which is worse than a red. The seam is machine-INDEPENDENT: §0 below asserts, with a
# FIXTURE probe verdict, that the gate refuses at 71 when the capability is absent AND that this
# suite's setting starts the lane anyway — and S0 asserts THIS FILE's declaration is in force, which
# is what makes deleting the line red on any box (a review caught the earlier version of this comment
# claiming §0 covered that when it did not: §0's own arms PASS `LANE_PREFLIGHT` explicitly, so on a
# pi-equipped box the suite stayed green with the line deleted — measured, 71/0 — while a runner
# would still cascade).
export LANE_PREFLIGHT=0

# ⛔ DEFECT B — A FAILING ARM MUST SHOW THE CHILD'S OWN WORDS, NOT A NUMBER.
# Every arm below used to run `run_agent … >/dev/null 2>&1`. That is how the CI failure above became
# an unreasoned `rc=71 started=0`: the refusal, its reason (`why=pi-missing`) and the gate that
# produced it were all written to fds that went nowhere. So the child's stdout/stderr now lands in
# `<lane-log>.agent` (greppable beside the lane's own log), `ck` prints it — plus the reason lines in
# the lane log — ON THE ARM THAT FAILED, and a red run KEEPS $TMP and prints its path instead of
# deleting the evidence. A green run stays quiet and cleans up.
ARM_LANE=""; ARM_LOG=""
arm() { # arm <lane-log> — point the failure dump at THIS arm's artefacts
  ARM_LANE="$1"; ARM_LOG="$1.agent"
}
_dump() { # _dump <file> <what>
  local f="${1:-}" what="${2:-log}"
  [ -n "$f" ] || return 0
  if [ ! -s "$f" ]; then printf '  ── %s: %s exists but is EMPTY ──\n' "$what" "$f"; return 0; fi
  printf '  ── %s: %s ──\n' "$what" "$f"
  # THE REASON FIRST: gate lines are exactly what vanished when the child was silenced.
  grep -E '^\[[a-z-]+(-gate|-bound)?\]|LANE_CAPABILITY=' "$f" 2>/dev/null | tail -25 | sed 's/^/  │ /'
  printf '  ── …and the last 40 lines of it ──\n'
  tail -40 "$f" | sed 's/^/  │ /'
}
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); return 0; fi
  printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1))
  _dump "${ARM_LANE:-}" "the lane log"
  _dump "${ARM_LOG:-}" "run_agent's own stdout/stderr"
  return 1
}
TMP="$(mktemp -d)"
cleanup() {
  if [ "${FAIL:-1}" -ne 0 ]; then
    printf '  ⚠️  %s failed — artefacts KEPT for grepping: %s\n' "$FAIL" "$TMP"
  else rm -rf "$TMP"; fi
}
trap cleanup EXIT
mkdir -p "$TMP/bin"

echo "==> wip-rescue-exit contract ($HERE)"
# The declaration, with the pre-flight's OWN inputs measured now — so a CI log says WHY this suite
# does not ask the box, instead of leaving it to be inferred from a code comment. The probe itself is
# NOT run here (one bounded model call, 5-25 s, and it is not what this suite tests); §0 drives the
# gate with a fixture verdict in both directions instead.
_pf_pi="$(command -v pi 2>/dev/null || true)"
_pf_keyvar="$(printf '%s' "${PI_LANE_PROVIDER:-deepseek}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')_API_KEY"
eval "_pf_key=\${${_pf_keyvar}:-}"
_pf_keys="none"
for _c in "${CELL_HOME:-}/keys.env" "${HOME:-}/keys.env"; do
  [ -n "${_c%/keys.env}" ] && [ -r "$_c" ] && { _pf_keys="$_c"; break; }
done
echo "==> capability pre-flight: DECLARED OFF (LANE_PREFLIGHT=0) — this suite stubs 'pi' and does not"
echo "    test the #2935 gate; on a runner with no pi install that gate refuses every arm at rc=71."
echo "    measured here: pi=${_pf_pi:-NONE} · $_pf_keyvar=$([ -n "$_pf_key" ] && echo set || echo unset) · keys.env=$_pf_keys"
echo "    NOT a silent bypass — S0 asserts THIS declaration, §0 asserts rc=71 without the seam and a"
echo "    started lane with it."

[ -s "$GATE" ] && bash -n "$GATE"; rc=$?
ck "spawn-gate.sh exists and parses" $rc

# ── the fixture ───────────────────────────────────────────────────────────────────────────────────
# A bare repo stands in for origin; a real git repo with a GitHub-shaped remote is the worktree.
# `user.name`/`user.email` are set in the REPO (not per-command) because `bg-rescue-wip.sh` builds its
# archive with `git commit-tree`, which needs an identity of its own — a per-commit `-c user.email=…`
# would leave the rescue unable to commit and this suite would be measuring that instead.
BARE="$TMP/origin.git"; WT="$TMP/wt"; O="$TMP/O"
GHURL="https://github.com/owner/repo.git"
git init -q --bare -b main "$BARE"
mkdir -p "$O/logs" "$O/state"
git init -q -b work "$WT"
git -C "$WT" config user.name t; git -C "$WT" config user.email t@t
git -C "$WT" remote add origin "$GHURL"
git -C "$WT" config url."$BARE".insteadOf "$GHURL"
printf 'seed\n' > "$WT/seed.txt"
git -C "$WT" add seed.txt && git -C "$WT" commit -q -m seed
git -C "$WT" push -q -u origin work
BR="$(git -C "$WT" branch --show-current)"; SLUG="$(printf '%s' "$BR" | tr '/' '-')"

# The creation back-pressure gate reads `gh` immediately before any spawn; supply the calm reading
# where it READS it (the seam spawn-gate.test.sh established — an env var that opens a gate is not a
# gate, and this suite is not testing that gate).
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# The brief gate refuses a brief with no research contract, so the fixture is rendered from the shipped
# validator — the same text a real dispatch carries.
PROMPT="$TMP/prompt"
{ printf 'a lane brief\n\n'; bash "$HERE/brief-gate.sh" --section lane; } > "$PROMPT"
bash "$HERE/brief-gate.sh" --check "$PROMPT" lane 2>/dev/null \
  || { echo "  ❌ the suite's fixture brief is REFUSED by the research-first gate" >&2; exit 1; }

# pi_stub <mode> — what the stub agent does to its cwd before it exits (i.e. BEFORE its cap):
#   dirty    writes an untracked file and exits 0                 (the #2834 modal case)
#   clean    touches nothing and exits 0                          (the majority case)
#   unpushed commits without pushing                              (the case the rescue cannot take)
#   sleep    never finishes inside the cap                        (the cap path)
#   sleepdirty writes a file and THEN never finishes              (the #2045 cap case: killed dirty)
pi_stub() {
  case "$1" in
    dirty)    printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nprintf "the work a lane leaves behind\\n" > early.txt\nexit 0\n' ;;
    clean)    printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nexit 0\n' ;;
    unpushed) printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nprintf "committed but never pushed\\n" > local.txt\ngit add local.txt >/dev/null 2>&1\ngit -c user.email=t@t -c user.name=t commit -q -m "local only"\nexit 0\n' ;;
    sleepdirty) printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nprintf "work in flight when the cap fired\\n" > capdirty.txt\nsleep 30\n' ;;
    *)        printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nsleep 30\n' ;;
  esac > "$TMP/bin/pi"
  chmod +x "$TMP/bin/pi"
}

# drive <gate> <cap-s> <label> [<wip-path>] — the SHIPPED run_agent, driven in the fixture worktree.
# `load1` is re-declared AFTER sourcing because run_agent's contract is "read load IMMEDIATELY before
# the spawn" and that reading has to be controllable; it is a seam, not a stub of the logic here.
drive() { # drive <gate> <cap> <label> [wip-path]
  local gate="$1" cap="$2" label="$3" wip="${4:-}"
  bash -c '
    . "$1"
    cd "$2" || exit 2
    O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
    KIND=lane; TAG=2834
    load1() { printf 1; }
    if [ -n "$8" ]; then WIP_PATH="$8"; fi
    # ⛔ NOT `>/dev/null 2>&1` (defect B): the child output goes beside its lane log, where the
    # failure dump in ck prints it. `$5` IS the lane log path, so `.agent` is one glob away.
    run_agent "$4" "$5" "$6" "$7" >>"$5.agent" 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$gate" "$WT" "$O" "$cap" "$O/logs/lane.log" "$PROMPT" "$label" "$wip"
}
wiprefs() { git -C "$BARE" for-each-ref --format='%(refname)' 'refs/wip/*' 2>/dev/null; }

# ── §0 THE SEAM IS LOAD-BEARING, AND THE CI FAILURE IS REPRODUCED IN BOTH DIRECTIONS ─────────────
# The declaration at the top of this file would be decoration if nothing asserted it, so the gate is
# DRIVEN here — not on the box's real capability (that is `cell-lane-preflight.test.sh`'s job, and a
# verdict about this box is exactly the box-dependent reading that made CI red) but on a FIXTURE
# verdict reached through the harness's own `CELL_PREFLIGHT_SH` seam. `why=pi-missing` is the shape a
# CI runner produces: no `pi` install, so the probe cannot measure and every spawn is refused.
#
# S1-S3 pin the failure this suite used to REPORT WITHOUT SAYING: rc=71, no agent, and the reason
# (`LANE_CAPABILITY=refused why=pi-missing` + the gate line) present in the lane log. S4-S5 pin the
# escape: the SAME box, the SAME fixture verdict, `LANE_PREFLIGHT=0` as this file sets it — the lane
# starts and the gate writes nothing. A single arm could be green by accident; the pair cannot.
# S0 (below) is the third leg: the file's OWN declaration, which the per-invocation arms cannot see.
mkfake_pf() { # mkfake_pf <why> <exit>
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "[cell-lane-preflight] LANE_CAPABILITY=refused why=%s host=ci-runner attempts=1 bound=45s"\n' "$1"
    printf 'exit %s\n' "$2"; } > "$TMP/fake-preflight.sh"
  chmod +x "$TMP/fake-preflight.sh"
}
drive_pf() { # drive_pf <LANE_PREFLIGHT> <lane-log> -> "rc=<n> started=<n>"
  # ⛔ ITS OWN `$O` (#2834's ledger contract). `run_agent` appends one `lane-end.tsv` row per terminal,
  # so driving it here in the FIXTURE's `$O` would put a §0 row ahead of arm A's and break A5's
  # `NR==1` ("the first row is this lane's") — an assertion this suite must not weaken to make room
  # for a pre-flight arm. A private ledger keeps the two surfaces independent.
  env PATH="$TMP/bin:$PATH" PI_LOG="$PFO/pi.log" O="$PFO" DISK_MIN_FREE_MB=1 \
      LANE_PREFLIGHT="$1" CELL_PREFLIGHT_SH="$TMP/fake-preflight.sh" \
    bash -c '
      . "$1"
      cd "$2" || exit 2
      O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
      KIND=lane; TAG=2834
      load1() { printf 1; }
      run_agent 300 "$4" "$5" "$6" >>"$4.agent" 2>&1
      printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
    ' _ "$GATE" "$WT" "$PFO" "$2" "$PROMPT" "preflight-$1"
}
PFO="$TMP/pf-O"; mkdir -p "$PFO/logs" "$PFO/state"
# ⛔ S0 asserts THIS FILE's own declaration, and it is not redundant with S1-S5: those arms PASS
# `LANE_PREFLIGHT` explicitly per invocation (S1=1, S4=0), so they prove the GATE's two directions
# while saying nothing about what the arms below inherit. Without S0, deleting the `export` above left
# the suite GREEN on a pi-equipped box (measured: 71 passed / 0 failed) with the arms merely running a
# live probe, and only a runner would have noticed. This is the one assertion that makes the
# declaration load-bearing on every box.
ck "S0 this suite's OWN pre-flight declaration is in force, so the arms below cannot silently inherit a LIVE capability gate" \
  $([ "${LANE_PREFLIGHT:-}" = "0" ] && echo 0 || echo 1)
pi_stub clean
mkfake_pf pi-missing 2
: > "$PFO/logs/preflight.log"; rm -f "$PFO/pi.log"
res="$(drive_pf 1 "$PFO/logs/preflight.log")"
arm "$PFO/logs/preflight.log"
ck "S1 a box with NO capability is REFUSED at 71 before any spawn, exactly as the CI runner was ($res)" \
  $([ "$res" = "rc=71 started=0" ] && echo 0 || echo 1)
ck "S2 …the refusal NAMES the gate and its reason in the lane log (why=pi-missing), instead of arriving as a bare number" \
  $(grep -q 'LANE_CAPABILITY=refused why=pi-missing' "$PFO/logs/preflight.log" && grep -q 'capability-gate. REFUSED' "$PFO/logs/preflight.log" && echo 0 || echo 1)
ck "S3 …and NO agent was started (no stub run was reached)" $([ ! -s "$PFO/pi.log" ] && echo 0 || echo 1)
: > "$PFO/logs/preflight0.log"; rm -f "$PFO/pi.log"
res0="$(drive_pf 0 "$PFO/logs/preflight0.log")"
arm "$PFO/logs/preflight0.log"
ck "S4 …and LANE_PREFLIGHT=0 — the seam this suite declares — starts the SAME lane on the SAME box ($res0)" \
  $([ "$res0" = "rc=0 started=1" ] && [ -s "$PFO/pi.log" ] && echo 0 || echo 1)
ck "S5 …with NO capability reading written at all, so the seam is a real escape and not a second gate" \
  $(! grep -q 'capability-gate' "$PFO/logs/preflight0.log" && echo 0 || echo 1)

# ── A) THE DEFECT ITSELF: a lane that ends BEFORE its cap, with work in the tree ──────────────────
pi_stub dirty
: > "$O/logs/lane.log"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi.log" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 drive "$GATE" 300 "early exit")"
arm "$O/logs/lane.log"
ck "A1 the stub lane really ran and exited before its cap ($res)" $([ "$res" = "rc=0 started=1" ] && echo 0 || echo 1)
[ -n "$(wiprefs)" ]; rc=$?
ck "A2 an early exit WITH uncommitted work leaves a refs/wip/* ref on ORIGIN (refs: $(wiprefs | tr '\n' ' '))" $rc
# ⛔ THE BYTES, NOT THE REF NAME. A ref that exists over an empty tree is not a rescue; the guarantee
# bg-rescue-wip.sh makes is that every uncommitted byte is reachable from that ref.
got="$(git -C "$BARE" show "refs/wip/$SLUG:early.txt" 2>/dev/null)"
ck "A3 …and the pushed archive CONTAINS the uncommitted file's bytes ('$got')" $([ "$got" = "the work a lane leaves behind" ] && echo 0 || echo 1)
grep -q "\[wip\] end label=early exit rc=0 cap=0 tree=dirty rescue=refs/wip/$SLUG" "$O/logs/lane.log"; rc=$?
ck "A4 the lane's log carries a TERMINAL RECORD naming rc, the trigger and the rescue ref (#2834 ask 2)" $rc
[ -s "$O/state/lane-end.tsv" ] && awk -F'\t' 'NR==1 && $2=="early exit" && $5=="dirty" && $6 ~ /^refs\/wip\// {found=1} END{exit !found}' "$O/state/lane-end.tsv"; rc=$?
ck "A5 …and the append-only ledger state/lane-end.tsv holds the row (epoch, label, rc, cap, tree, rescue, ref, unpushed, root)" $rc

# ── B) NON-VACUITY: remove the exit-path call and the ref MUST be absent ──────────────────────────
# A copy of the shipped helper, mutated in exactly one place: the call. Everything else — the source,
# the cap path, the dirty pre-check — is the real file, so a green here would mean the CALL is what
# delivers the guarantee.
MUT="$TMP/mut"; mkdir -p "$MUT"
grep -v '^  terminal_wip_rescue "\$label"' "$GATE" > "$MUT/spawn-gate.sh"
# ⛔ THE MUTANT MUST BE ABLE TO START (review F2, round 3). `run_agent` refuses BEFORE the spawn when
# `brief-gate.sh` is unresolvable (`spawn-gate.sh:1455-1468`), and `$MUT` has none of its homes — so on
# a runner with no `$AGENT_INFRA_PATH` and no `~/.pi/agent/scripts/brief-gate.sh` this arm went green
# because the LANE NEVER RAN, not because the call was removed: a control whose verdict is a function
# of the box is not a control. Ship the gate beside the mutant (its `$here` home) and ASSERT below
# that the mutant lane started.
cp "$HERE/brief-gate.sh" "$MUT/"
# …AND `repo-slug.sh`, which is resolved from the helper's OWN directory (`spawn-gate.sh:432`): without
# it the creation back-pressure gate cannot read the repo and refuses with 74 (`AGENT_LAND_BACKLOG`)
# before the spawn — the same vacuity through another door, which this arm's own assertion caught.
cp "$HERE/repo-slug.sh" "$MUT/"
grep -q '^terminal_wip_rescue()' "$MUT/spawn-gate.sh" && ! grep -q '^  terminal_wip_rescue "\$label"' "$MUT/spawn-gate.sh"; rc=$?
ck "B1 the mutation removed the CALL and kept the function (so the arm below tests the wiring, not a delete)" $rc
# A SECOND worktree with the same shape, so the two arms cannot see each other's refs.
git -C "$WT" checkout -q -b "mutation-probe"
git -C "$WT" push -q -u origin mutation-probe >/dev/null 2>&1
pi_stub dirty
: > "$O/logs/mut.log"
rm -f "$WT/early.txt"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi2.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "mutant" >>"$4.agent" 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$MUT/spawn-gate.sh" "$WT" "$O" "$O/logs/mut.log" "$PROMPT")"
arm "$O/logs/mut.log"
ck "B1b the MUTANT lane itself ran (so B2/B3 test the removed call, not a refusal that never dispatched) ($res)" \
  $([ "$res" = "rc=0 started=1" ] && echo 0 || echo 1)
grep -q 'PI_RAN' "$O/pi2.log" 2>/dev/null; rcpi=$?
ck "B1c …and its stub agent really executed against the fixture worktree" $rcpi
git -C "$BARE" rev-parse -q --verify "refs/wip/mutation-probe" >/dev/null 2>&1; rc=$?
ck "B2 with the exit-path call REMOVED the same lane leaves NO ref for its branch (so arm A is not vacuous)" $([ "$rc" -ne 0 ] && echo 0 || echo 1)
grep -q '\[wip\] end' "$O/logs/mut.log"; rcn=$?
ck "B3 …and the mutant writes no terminal record at all (the absence is the mutation, not a silent skip)" $([ "$rcn" -ne 0 ] && echo 0 || echo 1)
git -C "$WT" checkout -q "$BR"; git -C "$WT" branch -q -D mutation-probe
rm -f "$WT/early.txt"

# ── C) THE MAJORITY CASE: a clean exit costs no push and says so ─────────────────────────────────
before="$(wiprefs | wc -l | tr -d ' ')"
pi_stub clean
: > "$O/logs/clean.log"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi3.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "clean exit" >>"$4.agent" 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$WT" "$O" "$O/logs/clean.log" "$PROMPT")"
after="$(wiprefs | wc -l | tr -d ' ')"
arm "$O/logs/clean.log"
[ "$before" = "$after" ] && grep -q 'tree=clean rescue=nothing' "$O/logs/clean.log"; rc=$?
ck "C1 a clean exit creates NO ref and the record says tree=clean rescue=nothing ($before -> $after refs)" $rc
grep -q 'unpushed=0' "$O/logs/clean.log"; rc=$?
ck "C2 …and it records the unpushed count, so 'nothing at risk' is a measurement and not an assumption" $rc

# ── D) UNPUSHED COMMITS: measured and NAMED, never silently pushed ───────────────────────────────
seed_sha="$(git -C "$BARE" rev-parse refs/heads/work)"
pi_stub unpushed
: > "$O/logs/unpushed.log"
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi4.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "unpushed exit" >>"$4.agent" 2>&1
' _ "$GATE" "$WT" "$O" "$O/logs/unpushed.log" "$PROMPT"
arm "$O/logs/unpushed.log"
grep -q 'tree=unpushed-only rescue=nothing unpushed=1' "$O/logs/unpushed.log"; rc=$?
ck "D1 a CLEAN tree whose branch holds an unpushed commit is recorded as unpushed-only, with the count" $rc
grep -q 'exist ONLY locally' "$O/logs/unpushed.log"; rc=$?
ck "D2 …and the log NAMES that they were not pushed, instead of implying the lane's work is on origin" $rc
[ "$(git -C "$BARE" rev-parse refs/heads/work)" = "$seed_sha" ]; rc=$?
ck "D3 …and the rescue did NOT move the branch ($(git -C "$BARE" rev-parse --short refs/heads/work) is still the seed)" $rc
git -C "$WT" reset -q --hard "$seed_sha"; git -C "$WT" clean -qfd

# ── E) A MISSING RESCUER IS LOUD, NOT A SILENT SKIP ─────────────────────────────────────────────
# This is the operator's own measured failure one layer down: the call existed, the file did not, and
# `[ -f … ] && bash …` turned it into `false`. An isolated copy of the helper (no `scripts/` above it,
# no $O, no $AGENT_INFRA_PATH, empty $HOME) cannot resolve the script, and must SAY so.
ISO="$TMP/iso"; mkdir -p "$ISO/harness/O" "$ISO/home"
cp "$GATE" "$ISO/harness/spawn-gate.sh"
printf 'unrescuable\n' > "$WT/orphan.txt"
PATH="$TMP/bin:$PATH" O="$ISO/harness/O" AGENT_INFRA_PATH= HOME="$ISO/home" bash -c '
  . "$1"
  cd "$2" || exit 2
  WIP_PATH="$2"
  : > "$3"
  terminal_wip_rescue "no-rescuer" 0 0 "$3"
' _ "$ISO/harness/spawn-gate.sh" "$WT" "$ISO/harness/O/lane.log" 2>>"$ISO/harness/O/lane.log.agent"; rc=$?
arm "$ISO/harness/O/lane.log"
grep -q 'rescue=UNAVAILABLE' "$ISO/harness/O/lane.log"; rcu=$?
grep -q 'NOT FOUND' "$ISO/harness/O/lane.log"; rcf=$?
ck "E1 a missing bg-rescue-wip.sh is reported as rescue=UNAVAILABLE with the searched homes — never 'nothing to rescue'" $([ "$rcu" -eq 0 ] && [ "$rcf" -eq 0 ] && echo 0 || echo 1)
ck "E2 …and the rescue never changes the lane's exit status (the function returned $rc)" $([ "$rc" -eq 0 ] && echo 0 || echo 1)
rm -f "$WT/orphan.txt"

# ── F) A MIS-POINTED WIP_PATH IS NOT A CLEAN TREE ────────────────────────────────────────────────
# fix-one.sh `cd`s into the MAIN checkout and passes WIP_PATH=<the fixer's worktree>; a caller that
# forgets it would have the rescue read the wrong tree. `not-a-worktree` is its own verdict, and it
# must not be reachable as "clean". What this guard CAN refuse is a path that is not a worktree ROOT
# (arm F4); what it cannot is another checkout's root (arm F7, recorded not refused).
mkdir -p "$TMP/notgit"
: > "$O/logs/notgit.log"
O="$O" WIP_PATH="$TMP/notgit" bash -c '
  . "$1"
  terminal_wip_rescue "mis-pointed" 0 0 "$2"
' _ "$GATE" "$O/logs/notgit.log" 2>>"$O/logs/notgit.log.agent"
arm "$O/logs/notgit.log"
grep -q 'tree=not-a-worktree rescue=UNAVAILABLE' "$O/logs/notgit.log"; rc=$?
ck "F1 a WIP_PATH that is not a git worktree is tree=not-a-worktree, never a clean verdict" $rc
grep -q 'the worktree was CLEAN\|nothing was lost' "$O/logs/notgit.log"; rcc=$?
ck "F2 …and it never claims the tree was clean" $([ "$rcc" -ne 0 ] && echo 0 || echo 1)
# ⛔ F3 — THE ROW EXISTS ON THE PATH THAT RETURNS BEFORE THE MEASUREMENT (review F1, PR #2975).
# `not-a-worktree` is a root that is not a worktree ROOT, and it used to return with NO
# `lane-end.tsv` row while the file and the README both claim one row per terminal on every path —
# so a transition on which nothing was MEASURED was invisible in the fleet's aggregate surface. This
# reads the LEDGER, not the log line (the arm above already reads the line, and a line with no row is
# exactly the defect).
awk -F'\t' '$2=="mis-pointed" && $5=="not-a-worktree" && $6=="UNAVAILABLE" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcf3=$?
ck "F3 …and the append-only ledger still holds a row for it — 'one row per terminal, on every path' includes the paths that return before the measurement" $rcf3

# ⛔ F4 — A PATH *INSIDE* A WORKTREE IS NOT ITS ROOT (review P2, round 4, PR #2975). The guard used to be
# `rev-parse --git-dir`, which SUCCEEDS ANYWHERE INSIDE A REPOSITORY, so a subdirectory was ratified
# here, measured, and then refused one layer down by `bg-rescue-wip.sh:96-103` — the record said the
# RESCUE failed when the POINTER was wrong. The pre-check now carries the callee's own predicate, so
# the verdict is `not-a-worktree` and it names the enclosing worktree.
mkdir -p "$WT/nested/deep"
: > "$O/logs/nested.log"
O="$O" WIP_PATH="$WT/nested/deep" bash -c '
  . "$1"
  terminal_wip_rescue "nested-root" 0 0 "$2"
' _ "$GATE" "$O/logs/nested.log" 2>>"$O/logs/nested.log.agent"
arm "$O/logs/nested.log"
grep -q 'tree=not-a-worktree rescue=UNAVAILABLE' "$O/logs/nested.log"; rcn=$?
ck "F4 a WIP_PATH that is INSIDE a worktree but not its root is tree=not-a-worktree, not a measured subdirectory" $rcn
grep -q 'inside the worktree at' "$O/logs/nested.log"; rcn2=$?
ck "F5 …and the line NAMES the enclosing worktree, so the caller is told which root to pass" $rcn2
awk -F'\t' '$2=="nested-root" && $5=="not-a-worktree" && $9=="'"$WT"'/nested/deep" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcn3=$?
ck "F6 …and the row's root column holds the path that was refused, not the parent it named" $rcn3

# ⛔ F7/F8 — THE RESIDUAL, RECORDED RATHER THAN CLAIMED AWAY (review P2, round 4, PR #2975). A caller
# that sets NO `WIP_PATH` while its cwd sits at the ROOT of another checkout IS a worktree root, so no
# predicate in `terminal_wip_rescue` can tell it from the lane's own tree — the honest answer is that
# the row NAMES the tree it measured. The foreign checkout carries only an UNPUSHED commit (at_risk=0),
# so this arm costs no network call and touches no remote: it is asserting VISIBILITY, not a rescue.
FOREIGN="$TMP/foreign"
git init -q -b foreign "$FOREIGN"
git -C "$FOREIGN" config user.name t; git -C "$FOREIGN" config user.email t@t
printf 'seed\n' > "$FOREIGN/seed.txt"
git -C "$FOREIGN" add seed.txt && git -C "$FOREIGN" commit -q -m seed
printf 'committed but never pushed\n' > "$FOREIGN/local.txt"
git -C "$FOREIGN" add local.txt && git -C "$FOREIGN" commit -q -m 'local only'
: > "$O/logs/foreign.log"
O="$O" bash -c '
  . "$1"
  cd "$2" || exit 2
  terminal_wip_rescue "forgot-wip-path" 0 0 "$3"
' _ "$GATE" "$FOREIGN" "$O/logs/foreign.log" 2>>"$O/logs/foreign.log.agent"
arm "$O/logs/foreign.log"
awk -F'\t' '$2=="forgot-wip-path" && $5=="unpushed-only" && $9=="'"$FOREIGN"'" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcf7=$?
ck "F7 a cwd that IS another checkout's root is MEASURED (tree=unpushed-only) and recorded with THAT root in the row — the surface a wrong-tree archive is caught on" $rcf7
grep -qF "at $FOREIGN" "$O/logs/foreign.log" && grep -q 'tree=unpushed-only' "$O/logs/foreign.log"; rcf8=$?
ck "F8 …and the lane log names the MEASURED tree (not a refusal) too, so the wrong tree is never silent" $rcf8

# ── H) WIP_PATH BEATS $PWD — the shape the PRODUCTION caller actually has ─────────────────────
# `fix-one.sh` `cd`s into the MAIN checkout and only NAMES the fixer's worktree in the agent's prompt,
# so its `$PWD` is deliberately the WRONG tree. Arm E sets `WIP_PATH` where `$PWD` is ALREADY the
# worktree (it cannot tell the two apart) and arm F refuses a BAD `WIP_PATH`; neither proves the
# property the README states — that a VALID `WIP_PATH` WINS over a dirty cwd. Without this arm the
# `drive()`/`WIP_PATH` plumbing was dead code, and the claim rested on arms that could not see it
# (review F3, PR #2975). The lane ends inside a DIFFERENT dirty checkout that shares the GitHub-shaped
# slug, and the archive must be the WORKTREE's branch — never the checkout's.
MAINCO="$TMP/mainco"
git init -q -b main "$MAINCO"
git -C "$MAINCO" config user.name t; git -C "$MAINCO" config user.email t@t
git -C "$MAINCO" remote add origin "$GHURL"
git -C "$MAINCO" config url."$BARE".insteadOf "$GHURL"
printf 'seed\n' > "$MAINCO/seed.txt"
git -C "$MAINCO" add seed.txt && git -C "$MAINCO" commit -q -m seed
printf 'the worktree work a lane left behind\n' > "$WT/wtwork.txt"   # the tree the lane ACTUALLY used
pi_stub dirty                                                         # …whose cwd is MAINCO
: > "$O/logs/wipath.log"
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi5.log" bash -c '
  . "$1"
  cd "$5" || exit 2
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  WIP_PATH="$2"
  run_agent 300 "$4" "$6" "wip-path wins" >>"$4.agent" 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$WT" "$O" "$O/logs/wipath.log" "$MAINCO" "$PROMPT" >/dev/null

arm "$O/logs/wipath.log"
ck "H1 the lane really ended inside the OTHER dirty checkout (its own untracked file is there)" \
  $([ -f "$MAINCO/early.txt" ] && echo 0 || echo 1)
wk="$(git -C "$BARE" show "refs/wip/$SLUG:wtwork.txt" 2>/dev/null)"
ck "H2 a VALID WIP_PATH wins over a dirty \$PWD: the archive is the WORKTREE's branch ('$wk')" \
  $([ "$wk" = "the worktree work a lane left behind" ] && echo 0 || echo 1)
git -C "$BARE" rev-parse -q --verify "refs/wip/main" >/dev/null 2>&1; rcmain=$?
ck "H3 …and the CWD checkout was NOT archived: no refs/wip/main exists for it" $([ "$rcmain" -ne 0 ] && echo 0 || echo 1)
git -C "$BARE" cat-file -e "refs/wip/$SLUG:early.txt" 2>/dev/null; rcother=$?
ck "H4 …and the cwd's own file is not inside the worktree's archive (the two trees did not blur)" \
  $([ "$rcother" -ne 0 ] && echo 0 || echo 1)
rm -f "$WT/wtwork.txt"

# ── G) THE CAP PATH STILL RESCUES, AND A FAILED PUSH DOES NOT TOUCH rc ─────────────────────────
# "ANY terminal transition" includes the one #2045 already covered: the cap. This arm proves both
# triggers reach the same rescue — and, in the same breath, that the lane's exit status is a fact
# about the LANE, not about the network: the same cap kill is run twice, once with a rescue that
# cannot reach the remote and once with the rescue disabled, and the two statuses must be EQUAL.
drive_cap() { # drive_cap <label> <log>
  PATH="$TMP/bin:$PATH" PI_LOG="$O/pi.log" bash -c '
    . "$1"
    cd "$2" || exit 2
    O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
    KIND=lane; TAG=2834
    load1() { printf 1; }
    run_agent 1 "$4" "$5" "$6" >>"$4.agent" 2>&1
    printf "rc=%s" "$?"
  ' _ "$GATE" "$WT" "$O" "$2" "$PROMPT" "$1"
}
pi_stub sleepdirty
: > "$O/logs/cap.log"
rm -f "$WT/capdirty.txt"
res="$(drive_cap "cap exit" "$O/logs/cap.log")"
arm "$O/logs/cap.log"
grep -q '\[cap\] .*cap' "$O/logs/cap.log"; rccap=$?
grep -q '\[wip\] end label=cap exit rc=.* cap=1 tree=dirty rescue=refs/wip/' "$O/logs/cap.log"; rcend=$?
ck "G1 the CAP kill still snapshots (#2045 unchanged) AND the exit path rescues it off-box, recorded as cap=1" $([ "$rccap" -eq 0 ] && [ "$rcend" -eq 0 ] && echo 0 || echo 1)
gotcap="$(git -C "$BARE" show "refs/wip/$SLUG:capdirty.txt" 2>/dev/null)"
ck "G2 …and the pushed archive holds the work that was in flight when the cap fired ('$gotcap')" $([ "$gotcap" = "work in flight when the cap fired" ] && echo 0 || echo 1)
# The TRANSPORT is pointed at a path that is not a repository, while the SLUG stays GitHub-shaped: the
# creation gate derives that slug from the config, so a local `remote set-url` would be refused by THAT
# gate (74) before this arm ever reached the rescue. `url.<base>.insteadOf` is transport-only, so the
# failure is local and instant — no network, no credentials.
rm -f "$WT/capdirty.txt"
git -C "$WT" config --unset-all "url.$BARE.insteadOf"
git -C "$WT" config url."$TMP/not-a-repo.git".insteadOf "$GHURL"
: > "$O/logs/capfail.log"
res_fail="$(drive_cap "cap failing" "$O/logs/capfail.log")"
: > "$O/logs/capoff.log"
res_off="$(WIP_RESCUE_DISABLE=1 drive_cap "cap disabled" "$O/logs/capoff.log")"
ck "G3 an unreachable remote does NOT change the lane's exit status ($res_fail with a failing rescue, $res_off with the rescue disabled)" $([ "$res_fail" = "$res_off" ] && echo 0 || echo 1)
arm "$O/logs/capfail.log"
grep -q 'STILL ONLY ON THIS DISK' "$O/logs/capfail.log"; rcfail=$?
ck "G4 …and the failing rescue is LOUD: it names the worktree as the only copy" $rcfail
# ⛔ THE ARCHIVE THAT WAS PINNED IS RECORDED AS SUCH (review F2, PR #2975). bg-rescue-wip.sh exits 2
# both for "nothing was archived" and for "archived, push failed" (`refs/wip-local/<slug>` valid).
# Reading the ref only on rc=0 recorded a bare `FAILED` with an EMPTY ref in the second case — hiding
# the one pointer to the archived commit from the fleet record.
grep -qE 'rescue=archived-local .*ref=refs/wip-local/' "$O/logs/capfail.log"; rcarc=$?
ck "G6 …and the archive that DID get pinned locally is recorded as rescue=archived-local WITH its ref, not a bare FAILED with an empty one" $rcarc
grep -q 'rescue=FAILED' "$O/logs/capfail.log"; rcfailed=$?
ck "G7 …so FAILED is no longer printed over a worktree whose work is in fact pinned" $([ "$rcfailed" -ne 0 ] && echo 0 || echo 1)
grep -q 'rescue=DISABLED' "$O/logs/capoff.log"; rcdis=$?
arm "$O/logs/capoff.log"
ck "G5 …and the operator hatch (WIP_RESCUE_DISABLE=1) says the tree was NOT examined instead of implying it was clean" $rcdis
# ⛔ AND THE HATCH STILL WRITES A ROW (review F1, PR #2975). A hatch that blanks the ledger is
# indistinguishable from a lane that never ended — the exact ambiguity `lane-end.tsv` exists to close.
awk -F'\t' '$2=="cap disabled" && $5=="not-measured" && $6=="DISABLED" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcdisrow=$?
ck "G8 …and the disabled path still appends its own ledger row (tree=not-measured rescue=DISABLED)" $rcdisrow
git -C "$WT" config --unset-all url."$TMP/not-a-repo.git".insteadOf
git -C "$WT" config url."$BARE".insteadOf "$GHURL"

# ── I) A STALE refs/wip-local IS NOT THIS RUN'S ARCHIVE (review F1, round 3) ──────────────────────
# `refs/wip-local/<slug>` lives in the repo's COMMON git dir and is keyed by branch slug alone, so an
# EARLIER rescue of this branch leaves one behind. A run that archives NOTHING — an unwritable TMPDIR
# is the cheap reproduction of `bg-rescue-wip.sh:62`, the full-disk shape — must not be recorded as
# `archived-local`, because that is a durability verdict about work that is still SINGLE-COPY. This
# arm is the exact case: the ref exists (arms A/G wrote it), the rescue cannot archive, and the record
# must say FAILED with no ref, naming the stale one as stale.
printf 'work that will NOT be archived\n' > "$WT/stale.txt"
before_sha="$(git -C "$WT" rev-parse -q --verify refs/wip-local/work 2>/dev/null)"
: > "$O/logs/staleref.log"
TMPDIR="$TMP/no-such-tmpdir" O="$O" WIP_PATH="$WT" bash -c '
  . "$1"
  terminal_wip_rescue "stale ref" 0 0 "$2"
' _ "$GATE" "$O/logs/staleref.log" 2>>"$O/logs/staleref.log.agent"
rcstale=$?
after_sha="$(git -C "$WT" rev-parse -q --verify refs/wip-local/work 2>/dev/null)"
arm "$O/logs/staleref.log"
ck "I1 the fixture really left a STALE ref unchanged by this run (before=$before_sha after=$after_sha)" \
  $([ -n "$before_sha" ] && [ "$before_sha" = "$after_sha" ] && echo 0 || echo 1)
grep -q 'rescue=archived-local' "$O/logs/staleref.log"; rcac=$?
ck "I2 a rescue that archived NOTHING is NOT recorded as archived-local, even though a stale refs/wip-local/<slug> exists" \
  $([ "$rcac" -ne 0 ] && echo 0 || echo 1)
grep -q 'rescue=FAILED .*ref=<none>' "$O/logs/staleref.log"; rcfl=$?
ck "I3 …it is FAILED with NO ref, so the row cannot pin this lane to a snapshot the run did not write" $rcfl
grep -q 'written by an EARLIER rescue' "$O/logs/staleref.log"; rcnote=$?
ck "I4 …and the stale ref is NAMED as stale (it may predate the work now in the tree), not silently ignored" $rcnote
ck "I5 …and the rescue still never changes the lane's exit status (the function returned $rcstale)" \
  $([ "$rcstale" -eq 0 ] && echo 0 || echo 1)
rm -f "$WT/stale.txt"

# ── J) A STATUS THAT SUCCEEDS WHILE WARNING IS NOT "CLEAN" (review P1, round 2) ─────────────────
# `git status --porcelain -uall` EXITS 0 WITH EMPTY STDOUT when it cannot read a directory, and says
# why ONLY on stderr — reproduced on this file's own pre-check against a `chmod 000` directory holding
# a MODIFIED TRACKED file (`rc=0 out=[]` + `warning: could not open directory 'sub/': Permission
# denied`). With stderr discarded, "no output" became "nothing changed": the rescue was never called
# and the ledger asserted `tree=clean` over work that was never enumerated — a positive safety claim
# where an absence would at least be honest.
#
# ⛔ THE BLINDNESS IS INJECTED, NOT `chmod 000`'d, ON PURPOSE. `chmod 000` does nothing to a runner that
# happens to execute as root, which would make this arm silently VACUOUS exactly where CI runs it — the
# failure mode arm B1b/B1c exist to refuse for the mutation control. The wrapper reproduces the CALLER's
# view exactly (exit 0, empty stdout, one `INCOMPLETE_RE` warning) while leaving the filesystem
# READABLE, so the rescue's own `git add -A` really does stage the file and J4 can read its bytes back
# out of origin. Anything that is not a `status` call is exec'd unchanged.
mkdir -p "$TMP/bin-warn"
# ⛔ The fixture must be BLIND TO ONE PATH, not merely dirty: earlier arms deliberately left files
# (`early.txt`, the unpushed commit's `local.txt`) in this worktree, and a non-empty listing would let
# a `status`-seeing caller pass J2 by accident. Reset to the seed commit so `hidden/secret.txt` is the
# ONLY uncommitted path — which is exactly what the wrapper then hides.
git -C "$WT" reset -q --hard HEAD && git -C "$WT" clean -q -xdf
mkdir -p "$WT/hidden"
printf 'work inside a directory git could not open\n' > "$WT/hidden/secret.txt"
REAL_GIT="$(command -v git)"
{ printf '#!/usr/bin/env bash\nREAL=%s\n' "'$REAL_GIT'"
  cat <<'WRAP'
is_status=0
for a in "$@"; do [ "$a" = "status" ] && is_status=1; done
[ "$is_status" -eq 1 ] || exec "$REAL" "$@"
errf="$(mktemp)" || exec "$REAL" "$@"
out="$("$REAL" "$@" 2>"$errf")"; rc=$?
if [ -n "$out" ]; then printf '%s\n' "$out" | grep -v 'hidden/' || true; fi
cat "$errf" >&2; rm -f "$errf"
printf "warning: could not open directory 'hidden/': Permission denied\n" >&2
exit "$rc"
WRAP
} > "$TMP/bin-warn/git"
chmod +x "$TMP/bin-warn/git"
rawst="$(git -C "$WT" status --porcelain -uall 2>/dev/null)"
blindst="$(PATH="$TMP/bin-warn:$PATH" GIT_OPTIONAL_LOCKS=0 git -C "$WT" status --porcelain -uall 2>"$TMP/werr")"; blindrc=$?
if [ -n "$rawst" ] && [ "$blindrc" -eq 0 ] && [ -z "$blindst" ] && grep -q 'could not open directory' "$TMP/werr"; then j1=0; else j1=1; fi
arm ""   # J1 asserts the FIXTURE, not a lane: no product log applies to it
ck "J1 the fixture reproduces the blind spot: the work IS uncommitted (real status sees it) yet the wrapped status exits 0 with NO output and a warning on stderr" $j1
: > "$O/logs/blind.log"
PATH="$TMP/bin-warn:$PATH" O="$O" WIP_PATH="$WT" bash -c '
  . "$1"
  terminal_wip_rescue "blinded status" 0 0 "$2"
' _ "$GATE" "$O/logs/blind.log" 2>>"$O/logs/blind.log.agent"
rcblind=$?
arm "$O/logs/blind.log"
grep -q 'tree=cannot-verify' "$O/logs/blind.log"; rcblindtree=$?
ck "J2 an INCOMPLETE listing is recorded as cannot-verify, so an empty enumeration is never published as a clean tree" $rcblindtree
grep -q 'tree=clean' "$O/logs/blind.log"; rcblindclean=$?
ck "J3 …and NOTHING in that transition claims tree=clean (the fail-open the round-2 review measured)" \
  $([ "$rcblindclean" -ne 0 ] && echo 0 || echo 1)
grep -q '^\[wip\]   bg-rescue-wip:' "$O/logs/blind.log"; rcreached=$?
ck "J4 …and the rescue was REACHED (its output is replayed), instead of being skipped on an empty listing" $rcreached
gotblind="$(git -C "$BARE" show "refs/wip/$SLUG:hidden/secret.txt" 2>/dev/null)"
ck "J5 …and the archive on ORIGIN holds the bytes git status could not see ('$gotblind')" \
  $([ "$gotblind" = "work inside a directory git could not open" ] && echo 0 || echo 1)
grep -q 'listing at .* is INCOMPLETE' "$O/logs/blind.log"; rcnamed=$?
ck "J6 …and the line NAMES the incomplete listing (rc + stderr line count) rather than only changing a column" $rcnamed
ck "J7 …and the rescue still never changes the lane's exit status (the function returned $rcblind)" \
  $([ "$rcblind" -eq 0 ] && echo 0 || echo 1)
rm -rf "$WT/hidden"

echo
# ── K) A PUSHED ARCHIVE WITH NO LOCAL PIN IS NOT "nothing" (review P2, round 5, PR #2975) ─────────
# ⛔ `bg-rescue-wip.sh` writes `refs/wip-local/<slug>` under a GUARD (`:246-252` warns and carries on), and
# then exits 0 once the PUSH succeeds (`:362-368`). So `rc2=0` + no new local ref has TWO causes, and the
# caller used to record both as `rescue=nothing` — "nothing needed saving" — over work that IS on origin.
# A D/F conflict is how that state is reached in one command: a ref named `refs/wip-local/<slug>/x` makes
# `refs/wip-local/<slug>` unwritable, so the pin fails while the push does not.
seed_sha="$(git -C "$WT" rev-parse HEAD)"
# Arm I leaves `refs/wip-local/<slug>` itself behind, which would make the CHILD ref the D/F conflict. Clear
# it first so the conflict is the one this arm needs: the pin unwritable, the push unaffected.
git -C "$WT" update-ref -d "refs/wip-local/$SLUG" 2>/dev/null
git -C "$WT" update-ref "refs/wip-local/$SLUG/dfblock" "$seed_sha" 2>/dev/null; rcdf=$?
arm ""   # K0 asserts the FIXTURE's D/F conflict, not a lane
ck "K0 the fixture really made refs/wip-local/$SLUG unwritable (a D/F conflict: a child ref exists under it)" $rcdf
# ⛔ `pi_stub` only INSTALLS the stub; it RUNS inside `run_agent`. This arm drives `terminal_wip_rescue`
# directly, so it creates the dirty file itself — the same way arms E/F/G do.
printf 'the work a lane leaves behind\n' > "$WT/early.txt"
: > "$O/logs/df.log"
O="$O" WIP_PATH="$WT" bash -c '
  . "$1"
  terminal_wip_rescue "df-conflict" 0 0 "$2"
' _ "$GATE" "$O/logs/df.log" 2>>"$O/logs/df.log.agent"; rcdf2=$?
gotdf="$(git -C "$BARE" show "refs/wip/$SLUG:early.txt" 2>/dev/null)"
arm "$O/logs/df.log"
ck "K1 the push DID succeed, so origin really holds the work ('$gotdf')" \
  $([ "$gotdf" = "the work a lane leaves behind" ] && echo 0 || echo 1)
awk -F'\t' '$2=="df-conflict" && $5=="dirty" && $6=="refs/wip/'"$SLUG"'" && $7=="" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rck2=$?
ck "K2 an exit-0 rescue that pushed but could not write its local pin is recorded as rescue=refs/wip/<slug> with an EMPTY ref — NOT rescue=nothing" $rck2
grep -q 'rescue=nothing' "$O/logs/df.log"; rck3=$?
ck "K3 …and nothing in that transition says 'nothing' — the archive on origin is not reported as unsaved work" \
  $([ "$rck3" -ne 0 ] && echo 0 || echo 1)
grep -q 'could not write its LOCAL pin' "$O/logs/df.log"; rck4=$?
ck "K4 …and a loud line names the empty ref column over an archive that EXISTS, so it is not read as 'nothing archived'" $rck4
ck "K5 …and the rescue still never changes the lane's exit status (the function returned $rcdf2)" \
  $([ "$rcdf2" -eq 0 ] && echo 0 || echo 1)
git -C "$WT" update-ref -d "refs/wip-local/$SLUG/dfblock" 2>/dev/null
rm -f "$WT/early.txt"
echo
# ── L) AN UNREADABLE `rev-list` IS NOT A MEASURED ZERO (review P2, round 6, PR #2975) ──────────────
# ⛔ The unpushed count used to be read as `rev-list … || 0`, so a FAILED read — a partial/promisor
# clone that cannot see the objects, a corrupt odb, a permission problem — landed as `unpushed=0` and
# the verdict fell through to `tree=clean` over a lane that may hold commits only locally. `0` has to
# MEAN measured zero, so this arm injects the failure and requires the tree to stop being certified.
# The wrapper fails ONLY `rev-list` (a `status` failure is arm J's, and would test the wrong branch),
# and L0 proves the injection worked on THIS host rather than trusting the wrapper.
mkdir -p "$TMP/bin-norev"
{ printf '#!/usr/bin/env bash\nREAL=%s\n' "'$REAL_GIT'"
  cat <<'WRAP'
is_rev=0
for a in "$@"; do [ "$a" = "rev-list" ] && is_rev=1; done
[ "$is_rev" -eq 1 ] || exec "$REAL" "$@"
printf 'fatal: could not read object database\n' >&2
exit 128
WRAP
} > "$TMP/bin-norev/git"
chmod +x "$TMP/bin-norev/git"
# A COMPLETE, EMPTY listing, so the ONLY thing that can stop a `clean` verdict is the unpushed read.
git -C "$WT" reset -q --hard HEAD && git -C "$WT" clean -q -xdf
injected="$(PATH="$TMP/bin-norev:$PATH" git -C "$WT" rev-list --count HEAD --not --remotes 2>/dev/null)"; injrc=$?
arm ""   # L0/L1 assert the FIXTURE wrapper, not a lane
ck "L0 the fixture really makes the unpushed count UNREADABLE on this host (rc=$injrc, out='${injected}')" \
  $([ "$injrc" -ne 0 ] && [ -z "$injected" ] && echo 0 || echo 1)
realcount="$(git -C "$WT" rev-list --count HEAD --not --remotes 2>/dev/null)"
case "${realcount:-}" in ''|*[!0-9]*) rcl0=1 ;; *) rcl0=0 ;; esac
ck "L1 …and the REAL git still answers, so the arm is not vacuous on a host that cannot count at all ('${realcount}')" $rcl0
: > "$O/logs/norev.log"
PATH="$TMP/bin-norev:$PATH" O="$O" WIP_PATH="$WT" bash -c '
  . "$1"
  terminal_wip_rescue "unreadable unpushed" 0 0 "$2"
' _ "$GATE" "$O/logs/norev.log" 2>>"$O/logs/norev.log.agent"
rcnorev=$?
arm "$O/logs/norev.log"
awk -F'\t' '$2=="unreadable unpushed" && $5=="cannot-verify" && $8=="?" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcl1=$?
ck "L2 an unreadable unpushed count is recorded as tree=cannot-verify with the column '?', never as a measured 0" $rcl1
awk -F'\t' '$2=="unreadable unpushed" && $5=="clean" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcl2=$?
ck "L3 …and NOTHING in that transition says tree=clean (the fail-open this arm exists to catch)" \
  $([ "$rcl2" -ne 0 ] && echo 0 || echo 1)
grep -q 'unpushed-commit count could NOT be read' "$O/logs/norev.log"; rcl3=$?
ck "L4 …and a loud line NAMES the unreadable count as its own cause, not the status wording (which would send an operator to the wrong command)" $rcl3
ck "L5 …and the rescue still never changes the lane's exit status (the function returned $rcnorev)" \
  $([ "$rcnorev" -eq 0 ] && echo 0 || echo 1)
rm -rf "$TMP/bin-norev"
echo
# ── M) A READING THAT WAS NEVER TAKEN IS NOT REPORTED (review P2, round 6, PR #2975) ──────────────
# ⛔ When `mktemp` fails there is no place for `git status`'s stderr to land, so the pre-check forces
# `st_rc=1` — and the cannot-verify line then printed `git status rc=1, 0 stderr line(s)` for a command
# that NEVER RAN. Two problems in one sentence: a fabricated reading, and a pointer at git where the
# cause is `TMPDIR`. The line must say which of the two it is.
git -C "$WT" reset -q --hard HEAD && git -C "$WT" clean -q -xdf
: > "$O/logs/notmp.log"
TMPDIR="$TMP/does-not-exist" O="$O" WIP_PATH="$WT" bash -c '
  . "$1"
  terminal_wip_rescue "no temp dir" 0 0 "$2"
' _ "$GATE" "$O/logs/notmp.log" 2>>"$O/logs/notmp.log.agent"
rcnotmp=$?
arm "$O/logs/notmp.log"
grep -q 'NO status reading was taken' "$O/logs/notmp.log"; rcm1=$?
ck "M1 a failed mktemp is reported as 'NO status reading was taken', naming TMPDIR" $rcm1
grep -q 'git status rc=' "$O/logs/notmp.log"; rcm2=$?
ck "M2 …and the line carries NO 'git status rc=…' parenthetical, so it never reports a reading that was not taken" \
  $([ "$rcm2" -ne 0 ] && echo 0 || echo 1)
awk -F'\t' '$2=="no temp dir" && $5=="cannot-verify" {f=1} END{exit !f}' "$O/state/lane-end.tsv"; rcm3=$?
ck "M3 …and the verdict is still cannot-verify (fail-closed), so the wording fix did not weaken the gate" $rcm3
ck "M4 …and the rescue still never changes the lane's exit status (the function returned $rcnotmp)" \
  $([ "$rcnotmp" -eq 0 ] && echo 0 || echo 1)
echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
