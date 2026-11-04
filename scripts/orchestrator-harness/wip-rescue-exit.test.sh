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
# ⛔ THE REMOTE MUST STATE A DEFAULT FROM THE START. `lane_end_push` now REFUSES when it cannot determine
# the landing branch (an unresolved default is UNKNOWN, not "nothing to protect" — review cycle 2,
# finding 1), so a fixture whose bare HEAD pointed at an unborn `main` would refuse every push arm and
# measure the refusal instead of the push.
git -C "$WT" push -q origin HEAD:refs/heads/main
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
    unpushed) printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nprintf "committed but never pushed\\n" > local.txt\ngit add local.txt >/dev/null 2>&1\ngit -c user.email=t@t -c user.name=t commit -q -m "local only $$"\nexit 0\n' ;;
    sleepdirty) printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nprintf "work in flight when the cap fired\\n" > capdirty.txt\nsleep 30\n' ;;
    unpushed_landing) printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nprintf "a landing branch with local commits\\n" > local.txt\ngit add local.txt >/dev/null 2>&1\ngit -c user.email=t@t -c user.name=t commit -q -m "local only on a landing branch $$"\nexit 0\n' ;;
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
    O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
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
# ⛔ `switch`, NOT `checkout`, AND THE BRANCH NAME IS LITERAL — and note what this does NOT buy. The
# write-guard's static scanner refuses a `git checkout <ref>` inside a script, first on `$BR` being an
# unresolvable pathspec and then on `git -C "$WT"` being an unresolvable repo, so ONE of the forms was
# removed (`switch` cannot discard uncommitted changes by design, which is why it is not a
# re-implementation of the verb the guard protects). ⛔ THE SUITE IS STILL NOT RUNNABLE FROM AN AGENT
# SHELL: review cycle 1 measured that, and the remaining forms are the pre-existing
# `git -C "$WT" checkout -q -b mutation-probe` and this change's own `reset --hard`/`clean -fd` fixture
# resets, none of which the scanner can resolve. The supported path is the sanctioned runner
# (`BASH_SHARD_SLICE=<i>/<n> bash ./scripts/run-bash-shards.sh`), which is also what CI uses — the
# switch edit only removes one needless refusal, and claiming more would be a capability the file does
# not have (the guard false-positive class is #3173). The branch is created as `work` 200 lines above,
# so the literal is the same value by construction.
git -C "$WT" switch -q "work"; git -C "$WT" branch -q -D mutation-probe
rm -f "$WT/early.txt"

# ── C) THE MAJORITY CASE: a clean exit costs no push and says so ─────────────────────────────────
before="$(wiprefs | wc -l | tr -d ' ')"
pi_stub clean
: > "$O/logs/clean.log"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi3.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
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

# ── D) UNPUSHED COMMITS: measured, NAMED — and, since the durable-exit change, PUSHED ──────────────
# ⛔ D2/D3 USED TO ASSERT THE OPPOSITE, AND THE CHANGE IS DELIBERATE (#2834 ask 1, second half). The
# #2834 fix measured `unpushed` and printed "they were not pushed"; its own note said that half was
# owed, not refused ("teaching it to archive HEAD's tree … a change … deliberately not made in this
# PR — so ask 1 stays half-met here"). The reasoning it gave — a local commit survives the WORKTREE
# being removed — is true on a persistent box and false on a cloud cell, whose volume is discarded:
# an unpushed branch dies with the disk. So the exit path now pushes it, bounded and without force.
seed_sha="$(git -C "$BARE" rev-parse refs/heads/work)"
# ⛔ THE PUSH ARMS RUN IN A *LINKED* WORKTREE, BECAUSE THAT IS WHAT A LANE IS. The fixture's `$WT` is
# a plain checkout (its `--git-dir` IS its `--git-common-dir`), and the exit path REFUSES to push from
# a main checkout on purpose (a hub's branch is not a dying lane's to publish — see `lane_end_push`).
# Driving the push arms in `$WT` measured that refusal and called it a missing push, which is the
# shape of a test that proves the guard instead of the behaviour. `lane.sh` always runs inside
# `git worktree add`-created trees, so the arms use one: same repo, same origin, same insteadOf.
WT2="$TMP/wt2"
git -C "$WT" worktree add -q "$WT2" -b durable 2>/dev/null
git -C "$WT2" config user.name t; git -C "$WT2" config user.email t@t
[ -d "$WT2" ] && [ "$(git -C "$WT2" rev-parse --git-dir)" != "$(git -C "$WT2" rev-parse --git-common-dir)" ]; rc=$?
ck "D0 the push arms run in a LINKED worktree (git-dir != common-dir), the shape every lane.sh lane has — so they measure the push and not the main-checkout refusal" $rc
seed2="$(git -C "$WT2" rev-parse HEAD)"
pi_stub unpushed
: > "$O/logs/unpushed.log"
rm -f "$O/state/lane-exit-unpushed_exit.state"
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi4.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "unpushed exit" >>"$4.agent" 2>&1
' _ "$GATE" "$WT2" "$O" "$O/logs/unpushed.log" "$PROMPT"
arm "$O/logs/unpushed.log"
local_head="$(git -C "$WT2" rev-parse HEAD)"
grep -q 'tree=unpushed-only rescue=nothing unpushed=1' "$O/logs/unpushed.log"; rc=$?
ck "D1 a CLEAN tree whose branch holds an unpushed commit is recorded as unpushed-only, with the count" $rc
[ "$(git -C "$BARE" rev-parse refs/heads/durable 2>/dev/null)" = "$local_head" ]; rc=$?
ck "D2 …and the branch IS ON ORIGIN at the lane's head ($(git -C "$WT2" rev-parse --short HEAD)) — the commits a cell's volume would have taken" $rc
[ "$local_head" != "$seed2" ] && git -C "$WT2" merge-base --is-ancestor "$seed2" "$local_head"; rc=$?
ck "D3 …moved FORWARD only: the branch point is still an ancestor, so the push was a fast-forward and never a force" $rc
grep -q 'pushed durable → origin refs/heads/durable' "$O/logs/unpushed.log"; rc=$?
ck "D4 …and the log NAMES the ref it moved, so 'on origin' is a statement with an address" $rc
# ⛔ THE LOG MAY NOT CONTRADICT ITSELF (review P1). The `at_risk=0` arm printed "bg-rescue-wip.sh … does
# not push a branch, so they were not pushed" AFTER the push line — the false statement last, which is
# the order an operator reads. The NOTE is now keyed on the push verdict; both directions are asserted.
grep -q 'existed ONLY locally and the exit path PUSHED' "$O/logs/unpushed.log" && \
  ! grep -q 'so they were not pushed' "$O/logs/unpushed.log"; rc=$?
ck "D4b …and one terminal log never carries both 'now off-box' and 'they were not pushed' — the NOTE follows the push verdict" $rc
mk="$O/state/lane-exit-unpushed_exit.state"
[ -s "$mk" ] && grep -qx 'LANE-EXIT' "$mk"; rc=$?
ck "D5 …and a PER-LANE resume marker exists at state/lane-exit-<label>.state (the artifact a reclaim pass reads)" $rc
grep -qx "branch=durable" "$mk" 2>/dev/null && grep -qx "head=$local_head" "$mk" 2>/dev/null \
  && grep -qx 'push=pushed' "$mk" 2>/dev/null && grep -qx "branch_on_origin=$local_head" "$mk" 2>/dev/null; rc=$?
ck "D6 …naming branch, head, the push verdict and the sha the REMOTE reported (a read, not the push's own exit status)" $rc
grep -qx 'state=unpushed-only' "$mk" 2>/dev/null && grep -qx 'dirty=0' "$mk" 2>/dev/null \
  && grep -qx 'porcelain:' "$mk" 2>/dev/null && grep -q '^next=' "$mk" 2>/dev/null; rc=$?
ck "D7 …carrying the tree verdict, the dirty count, the porcelain section and a mechanically derived next step" $rc
git -C "$WT2" reset -q --hard "$seed2"; git -C "$WT2" clean -qfd
# ⛔ D8-D10 NON-VACUITY FOR THE PUSH ITSELF: the same lane on its OWN branch (`durablepre`), driven
# through the SHIPPED PRE-FIX helper (`origin/main`'s spawn-gate.sh, extracted from git rather than
# hand-mutated), must leave the branch where it was and write no marker. This is the RED half, kept as
# an arm so it can never silently stop discriminating — and it is the red→green evidence this change
# was required to produce. A separate branch, because the D arm above already moved `durable` on
# origin and reusing it would have measured the previous arm's push.
PRE="$TMP/pre"; mkdir -p "$PRE"
WT3="$TMP/wt3"
git -C "$WT" worktree add -q "$WT3" -b durablepre 2>/dev/null
pi_stub unpushed
git -C "$HERE" show origin/main:scripts/orchestrator-harness/spawn-gate.sh > "$PRE/spawn-gate.sh" 2>/dev/null
cp "$HERE/brief-gate.sh" "$HERE/repo-slug.sh" "$PRE/" 2>/dev/null
[ -s "$PRE/spawn-gate.sh" ] && ! grep -q 'lane_end_push' "$PRE/spawn-gate.sh"; rc=$?
ck "D8 the pre-fix helper was extracted from origin/main and really lacks the push (so the next arm measures the change, not git)" $rc
seed3="$(git -C "$WT3" rev-parse HEAD)"
: > "$O/logs/pre.log"; rm -f "$O/state/lane-exit-pre_fix.state"
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi5.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "pre fix" >>"$4.agent" 2>&1
' _ "$PRE/spawn-gate.sh" "$WT3" "$O" "$O/logs/pre.log" "$PROMPT"
arm "$O/logs/pre.log"
ck "D9 …AND ORIGIN HAS NO durablepre BRANCH AT ALL after the pre-fix exit — the lane's commit stayed on this disk, which is the RED the change turned green" \
  $(! git -C "$BARE" rev-parse -q --verify refs/heads/durablepre >/dev/null 2>&1 && echo 0 || echo 1)
ck "D9b …while the lane REALLY HAD an unpushed commit (head $(git -C "$WT3" rev-parse --short HEAD) != branch point $(git -C "$WT3" rev-parse --short "$seed3")), so D9 is not vacuous" \
  $([ "$(git -C "$WT3" rev-parse HEAD)" != "$seed3" ] && echo 0 || echo 1)
ck "D10 …and NO resume marker is written, exactly as at origin/main — so D5/D6 are the change's, not git's" \
  $([ ! -e "$O/state/lane-exit-pre_fix.state" ] && echo 0 || echo 1)

# ── N) THE TWO GATE PROPERTIES REVIEW CYCLE 1 BROKE, EACH WITH ITS OWN FIXTURE ─────────────────
# ⛔ N1-N2 — R1 IS A SET, NOT A NAME (review finding 1, and both halves were REPRODUCED). With
# `origin/HEAD = origin/main`, a lane on **master** pushed: the old code resolved ONE default and
# compared `sym = def`. The union is now consulted, so a branch that is a landing branch under ANY
# spelling is refused. The remote here states `main`; the lane sits on `master`.
WT4="$TMP/wt4"
# (the remote's default, and the branch it names, were established in the fixture setup above)
git -C "$WT" worktree add -q "$WT4" -b master 2>/dev/null
hdr4="$(git ls-remote --symref "$BARE" HEAD 2>/dev/null | head -1)"
case "$hdr4" in *'refs/heads/main'*) okhdr=0 ;; *) okhdr=1 ;; esac
ck "N0 the fixture's remote really states main as its default ($hdr4), so the next arm is not vacuous" $okhdr
pi_stub unpushed_landing
: > "$O/logs/landing.log"
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi6.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "landing" >>"$4.agent" 2>&1
' _ "$GATE" "$WT4" "$O" "$O/logs/landing.log" "$PROMPT"
arm "$O/logs/landing.log"
ck "N1 a lane on master is REFUSED when the remote's default is main: no refs/heads/master is created on origin" \
  $(! git -C "$BARE" rev-parse -q --verify refs/heads/master >/dev/null 2>&1 && echo 0 || echo 1)
grep -q 'refused-protected' "$O/logs/landing.log"; rcn1=$?
ck "N2 …and the refusal is named (push=refused-protected), not a silent no-op" $rcn1
# ⛔ N3-N4 — “VERIFIED BY READING THE REMOTE” MUST MEAN THE SHA, NOT THE REF (review finding 2,
# REPRODUCED: a push shim that exits 0 left origin at an older sha while the marker said push=pushed).
mkdir -p "$TMP/bin-shim"
REAL_GIT="$(command -v git)"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 0 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-shim/git"
chmod +x "$TMP/bin-shim/git"
pi_stub unpushed
: > "$O/logs/shim.log"; rm -f "$O/state/lane-exit-shim.state"
PATH="$TMP/bin-shim:$TMP/bin:$PATH" PI_LOG="$O/pi7.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "shim" >>"$4.agent" 2>&1
' _ "$GATE" "$WT2" "$O" "$O/logs/shim.log" "$PROMPT"
arm "$O/logs/shim.log"
ck "N3 the push shim really lies (origin/durable did NOT move to the lane's head: $(git -C "$BARE" rev-parse --short refs/heads/durable 2>/dev/null) vs $(git -C "$WT2" rev-parse --short HEAD))" \
  $([ "$(git -C "$BARE" rev-parse refs/heads/durable 2>/dev/null)" != "$(git -C "$WT2" rev-parse HEAD)" ] && echo 0 || echo 1)
grep -q 'the push did NOT deliver this lane' "$O/logs/shim.log"; rcn3=$?
ck "N4 …and the exit path does NOT record push=pushed for it: a 0 exit from the push is not a delivery" $rcn3
grep -qx 'push=FAILED' "$O/state/lane-exit-shim.state" 2>/dev/null; rcn4=$?
ck "N5 …the marker says push=FAILED, so the artifact a reclaim pass trusts never became 'safe'" $rcn4
# ⛔ N6 — AN UNREADABLE REMOTE ANSWER IS UNKNOWN, NOT "NO PROTECTED NAMES" (review cycle 2, finding 1,
# REPRODUCED: `trunk` was pushed and moved when the bounded symref read returned nothing). The shim makes
# only that read fail.
mkdir -p "$TMP/bin-nosymref"
{ printf '#!/bin/sh\ncase " $* " in *" ls-remote --symref "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-nosymref/git"
chmod +x "$TMP/bin-nosymref/git"
git -C "$WT" worktree add -q "$TMP/wt5" -b trunk 2>/dev/null
pi_stub unpushed_landing
: > "$O/logs/unknown.log"
PATH="$TMP/bin-nosymref:$TMP/bin:$PATH" PI_LOG="$O/pi8.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "unknown default" >>"$4.agent" 2>&1
' _ "$GATE" "$TMP/wt5" "$O" "$O/logs/unknown.log" "$PROMPT"
arm "$O/logs/unknown.log"
ck "N6 an unreadable default is REFUSED (refused-unknown-default), never pushed on {main,master} alone" \
  $(grep -q 'refused-unknown-default' "$O/logs/unknown.log" && ! git -C "$BARE" rev-parse -q --verify refs/heads/trunk >/dev/null 2>&1 && echo 0 || echo 1)
# ⛔ N7 — next= must not name an archive ref that cannot exist (review cycle 2, finding 3, REPRODUCED:
# a clean, successfully-pushed tree was told to `git fetch origin refs/wip/…`, which fails).
grep -q '^next=nothing to recover' "$O/state/lane-exit-unpushed_exit.state" 2>/dev/null \
  && ! grep -q 'refs/wip/durable' "$O/state/lane-exit-unpushed_exit.state" 2>/dev/null; rcn7=$?
ck "N7 a clean tree whose branch is on origin gets next='nothing to recover … IS on origin', not a fetch of a ref that was never created" $rcn7
# ⛔ N8 — an unreadable HEAD is NOT a verification (review cycle 2, finding 2, REPRODUCED: a shim push plus
# an unreadable HEAD recorded push=pushed and claimed '= this worktree HEAD').
mkdir -p "$TMP/bin-nohead"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 0 ;; *" rev-parse HEAD "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-nohead/git"
chmod +x "$TMP/bin-nohead/git"
PATH="$TMP/bin-nohead:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_LOG=/dev/null
  lane_end_push "no head" /dev/null "$2" durable 1 1
  printf "push=%s" "$LANE_END_PUSH"
' _ "$GATE" "$WT2" 2>/dev/null > "$TMP/nohead.out"
grep -q 'push=FAILED' "$TMP/nohead.out"; rcn8=$?
ck "N8 …an unreadable HEAD records push=FAILED, never push=pushed (measured: $(head -c 60 "$TMP/nohead.out"))" $rcn8
# ⛔ N8b — and the FIXTURE, not the assertion, is what makes N8 discriminate (cycle 3: the fixture's tree
# was BEHIND origin/durable, so the pre-fix run died at the non-fast-forward rejection and never reached the
# unreadable-HEAD branch — the arm passed identically before the fix). This asserts the precondition that
# made it vacuous, so if the fixture ever drifts forward again the reason N8 is meaningful disappears
# LOUDLY rather than silently.
[ "$(git -C "$WT2" rev-list --count HEAD..origin/durable 2>/dev/null)" -gt 0 ]; rcn8b=$?
ck "N8b …and the fixture precondition holds: WT2 is BEHIND origin/durable, so without the push-succeeds shim the transfer would be rejected before verification (which is what made N8 vacuous)" $rcn8b
# ⛔ N10 — A TRUNCATED MARKER MUST NEVER REPLACE A COMPLETE ONE (review cycle 3, finding 4): the `:`
# terminator made the block exit 0 unconditionally, so a write that died part-way installed a partial
# artifact with no loud line. The sentinel is injected to fail, deterministically.
mkdir -p "$TMP/trO/state"
O="$TMP/trO" bash -c '
  . "$1"
  LANE_END_LOG="$2/tr.log"; LANE_END_ROOT=/x; LANE_END_BRANCH=b; LANE_END_DIRTY=0
  LANE_END_MARKER_FRESH=1; LANE_END_PUSH=running
  lane_end_marker "keeps whole" 0 0
  printf() { case "$1" in end=ok*) return 1 ;; esac; builtin printf "$@"; }
  LANE_END_PUSH=pushed
  lane_end_marker "keeps whole" 0 0
' _ "$GATE" "$TMP" 2>/dev/null
grep -qx 'push=running' "$TMP/trO/state/lane-exit-keeps_whole.state" 2>/dev/null \
  && grep -q 'TRUNCATED' "$TMP/tr.log" 2>/dev/null; rcn10=$?
ck "N10 …a TRUNCATED write is refused by the end sentinel (the whole file stays, and the log says TRUNCATED)" $rcn10
# ⛔ N11 — STALE CONTENT MUST NOT SURVIVE A LATER TERMINAL ON THE SAME LABEL (review cycle 3, finding 5:
# `fix-one.sh` runs `run_agent` more than once in one shell, so the marker is rewritten for a NEW terminal).
O="$TMP/trO" bash -c '
  . "$1"
  LANE_END_LOG=/dev/null; LANE_END_ROOT=/x; LANE_END_BRANCH=b; LANE_END_DIRTY=0
  LANE_END_MARKER_FRESH=1; LANE_END_PUSH=pushed; LANE_END_TREE=clean
  lane_end_marker "twice" 0 0
  LANE_END_MARKER_FRESH=1; LANE_END_PUSH=refused-protected; LANE_END_TREE=dirty
  lane_end_marker "twice" 1 0
' _ "$GATE" 2>/dev/null
grep -qx 'push=refused-protected' "$TMP/trO/state/lane-exit-twice.state" 2>/dev/null \
  && ! grep -qx 'push=pushed' "$TMP/trO/state/lane-exit-twice.state" 2>/dev/null; rcn11=$?
ck "N11 …and a SECOND terminal on the same label replaces it (push=pushed is gone, not merged with it)" $rcn11
# ⛔ N12 — THE LEDGER ROW IS A FIXED-ARITY TSV (R5): a tenth column would silently shift every consumer
# that reads $5/$6. Asserted on the real row the arms above produced.
awk -F'\t' 'NF!=9 {bad=1} END {exit bad?1:0}' "$O/state/lane-end.tsv" 2>/dev/null; rcn12=$?
ck "N12 …every lane-end.tsv row still has exactly 9 fields" $rcn12
# ⛔ N13 — THE ARCHIVE ARM MUST NAME THE REF IT ACTUALLY CARRIES (cycle-3 verification of a review finding:
# the guard was written as `archived`, a word this code never assigns, so the fetch instruction was printed
# for `nothing` and suppressed for the one value where origin holds the only off-box copy).
mkdir -p "$TMP/archO/state"
O="$TMP/archO" bash -c '
  . "$1"
  LANE_END_LOG=/dev/null; LANE_END_ROOT=/x; LANE_END_BRANCH=fix/x; LANE_END_TREE=dirty
  LANE_END_RESCUE=refs/wip/fix-x
  lane_end_next > "$2/arch.next"
  LANE_END_RESCUE=nothing
  lane_end_next > "$2/none.next"
' _ "$GATE" "$TMP" 2>/dev/null
grep -q 'git fetch origin refs/wip/fix-x' "$TMP/arch.next" 2>/dev/null \
  && ! grep -q 'git fetch' "$TMP/none.next" 2>/dev/null; rcn13=$?
ck "N13 …a dirty tree WITH an archive gets the fetch of the ref it names; rescue=nothing gets none" $rcn13
# ⛔ N14 — THE NETWORK BUDGET IS PINNED TO THE CODE, NOT TO PROSE (review cycle 4, gap 1: this claim
# regressed TWICE by hand — the function comment, then the README — with the suite green both times).
# A static scan is the right instrument here: no behavioural arm can see a bound that was widened.
n_bound=$(grep -c 'tb_timeout 15 git -C "$root" push' "$GATE" 2>/dev/null)
n_sym=$(grep -c 'tb_timeout 15 git -C "$root" ls-remote --symref' "$GATE" 2>/dev/null)
n_ver=$(grep -c 'tb_timeout 5 git -C "$root" ls-remote --heads' "$GATE" 2>/dev/null)
# ⛔ CONTINUATIONS ARE JOINED AND COMMENTS STRIPPED BEFORE THE SCAN (review cycle 6, gap B: a call split by
# a line continuation — natural for a long refspec — was seen by neither the bounded nor the unbounded
# count, so `git -C "$root" \` + `fetch origin` on the next line shipped green).
joined=$(awk '
  /^lane_end_push\(\)/,/^}/ {
    if ($0 ~ /^[[:space:]]*#/) next
    line = line $0
    if ($0 ~ /\\$/) { sub(/\\$/, "", line); next }
    print line; line = ""
  }' "$GATE" 2>/dev/null)
n_net=$(printf '%s\n' "$joined" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g' | grep -cE 'git -C "\$root".*\b(push|fetch|ls-remote)\b')
# ⛔ COUNTED PER COMMAND SEGMENT, NOT PER LINE (review cycle 7: joining continuations made a bounded and an
# unbounded call share one line, so `tb_timeout … ls-remote … \` + `&& git -C "$root" fetch origin` read as
# bounded — a fail-open the join CREATED). Every segment that contains a network verb must carry its own
# `tb_timeout`.
n_unbounded=$(printf '%s\n' "$joined" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g' | grep -E 'git -C "\$root".*\b(push|fetch|ls-remote)\b' | grep -cv 'tb_timeout')
[ "$n_bound" = 1 ] && [ "$n_sym" = 1 ] && [ "$n_ver" = 1 ] \
  && [ "$n_net" -ge 3 ] && [ "$n_unbounded" = 0 ]; rcn14=$?
ck "N14 …every network call on the exit path is BOUNDED (15/15/5) — no unbounded and no continuation-split one (found $n_net)" $rcn14
# ⛔ N15 — THE HUB REFUSAL IS READ, NOT INHERITED (review cycle 4, gap 3: F7 executes the shape but no arm
# ever greps `refused-main-checkout`, so deleting the block left the suite green — the merge-gate bypass
# the comment names, undetected).
chk_hub=$(awk '/^lane_end_push\(\)/,/^}/' "$GATE" 2>/dev/null | grep -c 'LANE_END_PUSH="refused-main-checkout"')
[ "$chk_hub" = 1 ] && grep -q 'rev-parse --git-dir' "$GATE" 2>/dev/null \
  && grep -q 'rev-parse --git-common-dir' "$GATE" 2>/dev/null; rcn15=$?
ck "N15 …a hub checkout (git-dir == git-common-dir) is refused BY NAME in lane_end_push, not merely skipped by luck" $rcn15
# ⛔ N16 — THE CLONE-REF LEG OF THE LANDING CHECK (review cycle 4, gap 2): with the remote's own answer
# unavailable, a clone whose refs/remotes/origin/HEAD still names the renamed default must refuse THAT name.
git -C "$WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk 2>/dev/null
pi_stub unpushed_landing
: > "$O/logs/cloneref.log"
PATH="$TMP/bin-nosymref:$TMP/bin:$PATH" PI_LOG="$O/pi9.log" bash -c '
  . "$1"; cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "clone ref leg" >>"$4.agent" 2>&1
' _ "$GATE" "$TMP/wt5" "$O" "$O/logs/cloneref.log" "$PROMPT"
arm "$O/logs/cloneref.log"
ck "N16 …with the remote silent, the clone's refs/remotes/origin/HEAD still refuses the renamed default (trunk not moved) [$(tail -1 "$O/logs/cloneref.log" 2>/dev/null | cut -c1-90)]" \
  $(grep -q 'refused-protected' "$O/logs/cloneref.log" && ! git -C "$BARE" rev-parse -q --verify refs/heads/trunk >/dev/null 2>&1 && echo 0 || echo 1)
# ⛔ N17 — NO FORBIDDEN VERB ON ANY EXIT BRANCH (review cycle 4, gap 4; STRENGTHENED after cycle 5 proven
# by mutation: `--force` was caught but `-f` and the `+HEAD:refs/heads/…` force-by-refspec spelling were
# NOT, and `git +stash` required the verb adjacent to `git` while every call in this file is
# `git -C "$root" …`). The scan matches the file's own idiom and all three force spellings.
exit_fn=$(awk '/^lane_end_push\(\)/,/^}/' "$GATE"; awk '/^terminal_wip_rescue\(\)/,/^}/' "$GATE")
# Comment lines are STRIPPED first: the code's own prohibitions name these verbs ("no `--force`, no
# `git stash`"), so scanning prose would make the arm red on a correct file — the mirror of the
# false-negative it exists to prevent.
exit_code_only=$(printf '%s\n' "$exit_fn" | grep -v '^[[:space:]]*#')
n_force=$(printf '%s\n' "$exit_code_only" | grep -cE 'push.*(--force|(^| )-f( |$)|\+HEAD|\+refs)')
n_destructive=$(printf '%s\n' "$exit_code_only" | grep -ciE 'stash|worktree +(remove|prune)|reset .*--hard|clean +-[a-z]*f|checkout +(-f|-- )')
[ "$n_force" = 0 ] && [ "$n_destructive" = 0 ]; rcn17=$?
ck "N17 …the exit path carries no force (--force, -f, or a +refspec) and no stash/worktree-removal/reset --hard/clean -f/checkout -f, on ANY branch" $rcn17
# ⛔ N19 — THE R6 PROPERTY BEHAVIOURALLY, NOT BY SPELLING (review cycle 5, gap 1). A scan proves a verb is
# absent; it cannot prove a DIVERGENT branch is refused rather than overwritten. The dangerous direction —
# a dying lane reverting a peer's merged head — is exactly the non-fast-forward case, and D3 only proves
# the happy path was a fast-forward.
git -C "$WT" worktree add -q "$TMP/wt6" -b diverged 2>/dev/null
git -C "$TMP/wt6" commit -q --allow-empty -m base 2>/dev/null
git -C "$TMP/wt6" push -q origin diverged 2>/dev/null
base_sha=$(git -C "$BARE" rev-parse refs/heads/diverged 2>/dev/null)
git -C "$TMP/wt6" update-ref refs/heads/diverged "$seed2" 2>/dev/null
git -C "$TMP/wt6" commit -q --allow-empty -m divergent 2>/dev/null
local_head=$(git -C "$TMP/wt6" rev-parse HEAD 2>/dev/null)
O="$O" bash -c '
  . "$1"
  lane_end_push "diverged" "$2" "$3" diverged 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$O/logs/diverged.log" "$TMP/wt6" 2>/dev/null > "$TMP/diverged.out"
grep -q 'push=FAILED' "$TMP/diverged.out" 2>/dev/null \
  && [ "$(git -C "$BARE" rev-parse refs/heads/diverged 2>/dev/null)" = "$base_sha" ] \
  && [ "$(git -C "$TMP/wt6" rev-parse HEAD 2>/dev/null)" = "$local_head" ]; rcn19=$?
ck "N19 …a DIVERGENT branch is refused, the remote sha is UNMOVED and the LOCAL head still holds the commit (any destructive verb on the failure branch goes red) — measured: $(head -1 "$TMP/diverged.out" | cut -c1-40)" $rcn19
# ⛔ N18 — THE SILENT-WRITE RULE IS LOUD ON THE mkdir/mktemp BRANCHES TOO (review cycle 4, gap 5): N9 sends
# the log to /dev/null, so those two lines could go silent and stay green.
mkdir -p "$TMP/ro"
: > "$TMP/ro.notadir"
mkdir -p "$TMP/ro2/state"
O="$TMP/ro.notadir" bash -c '
  . "$1"
  LANE_END_LOG="$2/ro.log"; LANE_END_ROOT=/x; LANE_END_BRANCH=b; LANE_END_MARKER_FRESH=0
  lane_end_marker "no state dir" 0 0
  LANE_END_LOG="$2/ro2.log"; O="$3"
  chmod 500 "$3/state"
  lane_end_marker "no mktemp" 0 0
  chmod 700 "$3/state"
' _ "$GATE" "$TMP" "$TMP/ro2" 2>/dev/null
chmod 700 "$TMP/ro2/state" 2>/dev/null
grep -q 'NO resume marker' "$TMP/ro.log" 2>/dev/null && grep -qi 'could not create' "$TMP/ro2.log" 2>/dev/null; rcn18=$?
ck "N18 …a failed state-dir create AND a failed mktemp both say so loudly (no silent absence of the artifact)" $rcn18
# ⛔ N9 — A FAILED LATER WRITE MUST NOT DELETE THIS TERMINAL'S OWN PRE-NETWORK MARKER (review cycle 2,
# finding 5, REPRODUCED: an ENOSPC-shaped mktemp failure at the final write left NO marker at all).
mkdir -p "$TMP/mkO/state"
O="$TMP/mkO" bash -c '
  . "$1"
  LANE_END_LOG=/dev/null; LANE_END_ROOT=/x; LANE_END_BRANCH=b; LANE_END_DIRTY=0
  LANE_END_MARKER_FRESH=1; LANE_END_PUSH=running
  lane_end_marker "marker keep" 0 0
  # ENOSPC'"'"'s shape, made deterministic: the directory refuses the NEXT create while the existing file
  # (and its unlink) still works. Verified by N9b below, so a root run cannot pass this vacuously.
  chmod 500 "$O/state"
  # ⛔ THE INJECTION IS PROVEN INSIDE THE WINDOW IT IS USED IN (review cycle 3): the earlier version probed
  # AFTER restoring 0700, so the create always succeeded and the arm passed whether or not the injection
  # was real - an inert assertion, the very class this suite exists to refuse.
  mktemp "$O/state/.probe.XXXXXX" >/dev/null 2>&1 && printf 'INJ=0\n' || printf 'INJ=1\n'
  LANE_END_PUSH=pushed
  lane_end_marker "marker keep" 0 0
  chmod 700 "$O/state"
' _ "$GATE" 2>/dev/null > "$TMP/n9.out"
chmod 700 "$TMP/mkO/state" 2>/dev/null
[ -s "$TMP/mkO/state/lane-exit-marker_keep.state" ] && grep -qx 'push=running' "$TMP/mkO/state/lane-exit-marker_keep.state"; rcn9=$?
ck "N9 …and a failed FINAL marker write leaves the earlier one intact (push=running still on disk, not an absence)" $rcn9
grep -q 'INJ=1' "$TMP/n9.out"; mkmk=$?
ck "N9b …and the injection is real on THIS host (the in-window probe: a create in the 0500 state dir FAILED, so N9 cannot pass vacuously) [probe=$(head -1 "$TMP/n9.out" 2>/dev/null)]" $mkmk
git -C "$WT2" reset -q --hard "$seed2"; git -C "$WT2" clean -qfd
git -C "$WT2" reset -q --hard "$seed2"; git -C "$WT2" clean -qfd

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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
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
    O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
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
# ⛔ AND IT MUST NOT WRITE A CLEAN BILL OF HEALTH INTO THE MARKER EITHER (review P1). The hatch — and
# every path that returns before the measurement — leaves `tree=not-measured` and never reaches the
# push, so a `next=` arm that fell through to "nothing at risk … may be removed" would publish an
# affirmative reclaim verdict over a tree NOBODY LOOKED AT, in the exact artifact a reclaim pass reads.
MK_OFF="$O/state/lane-exit-cap_disabled.state"
[ -s "$MK_OFF" ] && grep -qx 'state=not-measured' "$MK_OFF" && grep -qx 'push=' "$MK_OFF"; rcmk1=$?
ck "G9 …the marker says state=not-measured and carries NO push verdict (nothing was pushed, nothing measured)" $rcmk1
grep -q '^next=MANUAL — this terminal did NOT measure' "$MK_OFF" 2>/dev/null && ! grep -q '^next=nothing at risk' "$MK_OFF" 2>/dev/null; rcmk2=$?
ck "G10 …and next= says MANUAL / NOT MEASURED — never 'nothing at risk … may be removed' over an unmeasured tree" $rcmk2
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
# ⛔ N20/N21/N22 — THE PUSH VERDICT'S FAIL-CLOSED ARMS, AND THE RESET THAT ONLY A SECOND TERMINAL
# CAN SEE (review cycle 7, findings 2 and 3). All three were IMPLEMENTED AND UNPROVEN: every other arm
# in this file drives ONE terminal inside a FRESH `bash -c`, so a fresh shell is empty whatever the
# reset does, and no arm referenced `push=unmeasured` or `push=detached` at all (measured: deleting the
# `uok`/detached guards, and deleting the whole reset block, each left this suite green — an inert
# assertion is the exact class this PR exists to refuse).
#
# N20 is the dangerous direction in one line: without the `uok` guard a FAILED count read leaves
# `unpushed=0`, which falls through to `push=nothing` — an affirmative "there was nothing to push"
# over a number nobody read. Arm L proves the TREE verdict for an unreadable count; this proves the
# PUSH verdict, which is what a reclaim pass actually reads.
O="$O" bash -c '
  . "$1"
  lane_end_push "unmeasured push" "/dev/null" "$2" never-pushed 0 0
  printf "unmeasured=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$WT" > "$TMP/n20.out" 2>/dev/null
grep -qx 'unmeasured=unmeasured' "$TMP/n20.out"; rcn20=$?
ck "N20 an UNREADABLE unpushed count is recorded as push=unmeasured — never push=nothing (an UNREAD zero is not a measured zero)" $rcn20
# N21 — A DETACHED HEAD IS NOT A BRANCH TO INVENT. The refusal must be recorded AND nothing may reach
# origin, so the head sha is checked against the REMOTE's own refs rather than against a log line.
git -C "$WT" worktree add -q "$TMP/wt7" -b detachedsrc 2>/dev/null
git -C "$TMP/wt7" commit -q --allow-empty -m "local only on a detached head" 2>/dev/null
det_sha="$(git -C "$TMP/wt7" rev-parse HEAD 2>/dev/null)"
git -C "$TMP/wt7" switch -q --detach 2>/dev/null
O="$O" bash -c '
  . "$1"
  lane_end_push "detached push" "/dev/null" "$2" ignored 1 1
  printf "detached=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$TMP/wt7" > "$TMP/n21.out" 2>/dev/null
grep -qx 'detached=detached' "$TMP/n21.out"; rcn21a=$?
# NON-VACUITY: the arm is only meaningful if the head really had a commit origin did not — and
# nothing invented a ref for it. Both read the REMOTE, not the gate's own prose.
case "$det_sha" in ''|*[!0-9a-f]*) rcn21b=1 ;; *) rcn21b=0 ;; esac
git -C "$BARE" for-each-ref --format='%(objectname)' 2>/dev/null | grep -qx "$det_sha" && rcn21c=1 || rcn21c=0
ck "N21 a DETACHED head with local commits is recorded as push=detached and NOTHING is pushed or invented (head ${det_sha:0:12} absent from origin's refs)" \
  $([ "$rcn21a" -eq 0 ] && [ "$rcn21b" -eq 0 ] && [ "$rcn21c" -eq 0 ] && echo 0 || echo 1)
# N22 — TWO TERMINALS IN ONE SHELL. `fix-one.sh` calls `run_agent` more than once in ONE shell, and the
# durable globals are reset at the TOP of `terminal_wip_rescue`, BEFORE the `WIP_RESCUE_DISABLE=1`
# hatch can return. The ORDERING is the property: resetting after the hatch would let a second
# terminal's `not-measured` row carry the FIRST lane's `push=pushed` — the most dangerous value to
# mis-carry. The first terminal here genuinely pushes (so the value being overwritten is real, not
# primed by the arm), and the second is the hatch, which returns before measuring anything.
# ⛔ ITS OWN WORKTREE AND BRANCH, on purpose: `$WT2` is BEHIND `origin/durable` by N8b's own
# precondition, so driving this arm there made the first push a NON-FAST-FORWARD — a refusal, not the
# `pushed` this arm needs to overwrite (measured: `first-push=FAILED`). A fresh branch has no remote
# history, so its push is a create, and the arm measures the reset rather than a rebase policy.
git -C "$WT" worktree add -q "$TMP/wt8" -b twoterm 2>/dev/null
git -C "$TMP/wt8" commit -q --allow-empty -m "unpushed for the two-terminal arm" 2>/dev/null
rm -f "$O/state/lane-exit-term_two.state" 2>/dev/null
O="$O" bash -c '
  . "$1"
  cd "$2" || exit 2
  lane_end_push "term one" "/dev/null" "$2" twoterm 1 1
  printf "first-push=%s\n" "$LANE_END_PUSH"
  WIP_RESCUE_DISABLE=1 terminal_wip_rescue "term two" 0 0 "/dev/null"
  printf "second-push=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$TMP/wt8" > "$TMP/n22.out" 2>&1
grep -qx 'first-push=pushed' "$TMP/n22.out"; rcn22a=$?
grep -qx 'second-push=' "$TMP/n22.out"; rcn22b=$?
grep -qx 'state=not-measured' "$O/state/lane-exit-term_two.state" 2>/dev/null; rcn22c=$?
grep -qx 'push=' "$O/state/lane-exit-term_two.state" 2>/dev/null; rcn22d=$?
# NON-VACUITY ON THE REMOTE: the first terminal's push must really have created the branch, otherwise
# `first-push=pushed` could be a log line with nothing behind it and the reset would be untested.
git -C "$BARE" rev-parse -q --verify refs/heads/twoterm >/dev/null 2>&1; rcn22e=$?
ck "N22 a SECOND terminal in the SAME shell carries NO stale push verdict from the first (first genuinely pushed -> origin/twoterm $(git -C "$BARE" rev-parse --short refs/heads/twoterm 2>/dev/null); second: $(sed -n '2p' "$TMP/n22.out" 2>/dev/null | cut -c1-30))" \
  $([ "$rcn22a" -eq 0 ] && [ "$rcn22b" -eq 0 ] && [ "$rcn22c" -eq 0 ] && [ "$rcn22d" -eq 0 ] && [ "$rcn22e" -eq 0 ] && echo 0 || echo 1)
echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
