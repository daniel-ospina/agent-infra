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

# ⛔ THE AMBIENT `WIP_PATH` IS CLEARED FOR THE SAME REASON `LANE_PREFLIGHT` IS — AND IT IS THE SAME
# DECLARED-SEAM SHAPE, NOT A HIDDEN `unset` (measured 2026-11-07, running this suite FROM A FIXER LANE,
# which is where lanes run it). A lane's envelope exports `WIP_PATH=<its own worktree>`, and the shipped
# exit path honours it: `root="${WIP_PATH:-$PWD}"` (spawn-gate.sh). Left in place it OUTRANKS the
# fixture's `cd "$WT"`, so every rescue arm rescued the CALLER's worktree — 250 passed / 37 failed on a
# tree whose own `refs/wip/*` is not the one under test — and the same inheritance made the arm push a
# rescue ref to the CALLER's real origin. Cleared for the same reason the capability gate is: the arms
# below are about the RESCUE CONTRACT, and the envelope of whoever runs the suite is not their subject.
# ⛔ NOT VACUOUS: §W0 asserts the declaration is in force, so deleting this line is red on any box whose
# caller exports `WIP_PATH` (measured: 250/37 with the ambient value, 287/0 with this line).
export WIP_PATH=

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
    O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
      O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
# ⛔ W0 IS S0's MIRROR FOR THE OTHER INHERITED VALUE, AND IT EARNS ITS ROW THE SAME WAY. The arms below
# drive the shipped `run_agent`, whose exit path roots the rescue at `"${WIP_PATH:-$PWD}"` — so a
# caller's `WIP_PATH` OUTRANKS the fixture's `cd "$WT"` and every rescue arm measures the CALLER's tree
# instead (measured 2026-11-07 from a fixer lane: 250 passed / 37 failed, and a rescue ref written to the
# caller's real origin). With the declaration above in place it must read empty HERE, in this shell.
# Like S0 it can only redden on a box whose caller exports the value — which is the only box where the
# declaration does anything, so the honest statement is that it makes the line load-bearing there, not
# that it reddens everywhere.
ck "W0 this suite CLEARS an inherited WIP_PATH, so the arms below rescue the FIXTURE worktree and not the caller's" \
  $([ -z "${WIP_PATH:-}" ] && echo 0 || echo 1)
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
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi.log" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 drive "$GATE" 300 "early exit")"
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
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
grep -q 'and the exit path PUSHED' "$O/logs/unpushed.log" && \
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
# through a PRE-FIX CONTROL — this head's helper with the exit-path device calls REMOVED — must leave
# the branch where it was and write no marker. This is the RED half, kept as an arm so it can never
# silently stop discriminating — and it is the red→green evidence this change was required to produce.
# A separate branch, because the D arm above already moved `durable` on origin and reusing it would
# have measured the previous arm's push.
#
# ⛔ THE CONTROL IS DERIVED FROM THE SHIPPED FILE, NOT FROM AN `origin/main` REF (this PR's own red CI,
# 2026-11-04). It used to be `git -C "$HERE" show origin/main:…spawn-gate.sh`. That ref does not exist
# here and was never guaranteed: `actions/checkout` fetches **one commit, for the ref that triggered the
# workflow** (its own README; `ci.yml`'s `bash-suites` job sets no `fetch-depth`), so the extraction
# produced an EMPTY file, `. "$PRE/spawn-gate.sh"` defined nothing, and the arm's lane died with
# `run_agent: command not found` — while D9 PASSED, because "no branch on origin" is vacuously true
# over a lane that never ran. D9b is what caught it. Same defect class as DEFECT A above (a verdict
# that is a function of the CHECKOUT rather than of the code), so it gets the same treatment: no base
# ref, no network, a fixture built from the shipped file — the mechanism arm B already uses.
#
# WHAT THE MUTATION REMOVES, AND WHY IT IS FOUR LINES: the change's whole exit-path device is the local
# marker reset, the marker write (two call sites, one per terminal path) and the push. The FUNCTIONS
# stay, so the arm measures the WIRING. The count assertion makes a renamed call line fail loudly
# instead of silently turning the control into a copy of the shipped helper (which D9 would then red —
# fail-closed, but unnamed).
PRE="$TMP/pre"; mkdir -p "$PRE"
WT3="$TMP/wt3"
git -C "$WT" worktree add -q "$WT3" -b durablepre 2>/dev/null
pi_stub unpushed
n_calls="$(grep -cE '^  (LANE_END_PUSH="running"|lane_end_marker "|lane_end_push ")' "$GATE")"
ck "D8a the shipped helper really carries the exit-path device the control removes (4 call lines: 1 reset, 2 marker writes, 1 push) — so the mutation cannot be a no-op (measured: $n_calls)" \
  $([ "$n_calls" = 4 ] && echo 0 || echo 1)
grep -vE '^  (LANE_END_PUSH="running"|lane_end_marker "\$label" "\$rc" "\$cap"|lane_end_push "\$label" "\$log" "\$root" "\$br" "\$unpushed" "\$unpushed_ok")$' \
  "$GATE" > "$PRE/spawn-gate.sh"
# The control must be able to START, for the reason B1's sibling documents: `run_agent` refuses BEFORE
# the spawn when `brief-gate.sh` / `repo-slug.sh` are unresolvable beside the helper, and a control that
# never ran would make D9 pass for the wrong reason — the exact vacuity this arm was rewritten for.
cp "$HERE/brief-gate.sh" "$HERE/repo-slug.sh" "$PRE/" 2>/dev/null
bash -n "$PRE/spawn-gate.sh" \
  && grep -q '^lane_end_push()' "$PRE/spawn-gate.sh" && grep -q '^lane_end_marker()' "$PRE/spawn-gate.sh" \
  && ! grep -qE '^  (LANE_END_PUSH="running"|lane_end_marker "|lane_end_push ")' "$PRE/spawn-gate.sh"; rc=$?
ck "D8b the control removed the CALLS and kept the FUNCTIONS, and the result still parses (so the next arm tests the wiring, not a broken file)" $rc
seed3="$(git -C "$WT3" rev-parse HEAD)"
: > "$O/logs/pre.log"; rm -f "$O/state/lane-exit-pre_fix.state"
res3="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi5.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "pre fix" >>"$4.agent" 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$PRE/spawn-gate.sh" "$WT3" "$O" "$O/logs/pre.log" "$PROMPT")"
arm "$O/logs/pre.log"
ck "D8c the CONTROL lane itself ran (so D9 tests the removed push, not a refusal that never dispatched) ($res3)" \
  $([ "$res3" = "rc=0 started=1" ] && echo 0 || echo 1)
grep -q 'PI_RAN' "$O/pi5.log" 2>/dev/null; rcpi3=$?
ck "D8d …and its stub agent really executed in the fixture worktree" $rcpi3
ck "D9 …AND ORIGIN HAS NO durablepre BRANCH AT ALL after the control exit — the lane's commit stayed on this disk, which is the RED the change turned green" \
  $(! git -C "$BARE" rev-parse -q --verify refs/heads/durablepre >/dev/null 2>&1 && echo 0 || echo 1)
ck "D9b …while the lane REALLY HAD an unpushed commit (head $(git -C "$WT3" rev-parse --short HEAD) != branch point $(git -C "$WT3" rev-parse --short "$seed3")), so D9 is not vacuous" \
  $([ "$(git -C "$WT3" rev-parse HEAD)" != "$seed3" ] && echo 0 || echo 1)
ck "D10 …and NO resume marker is written, exactly as before the change — so D5/D6 are the change's, not git's" \
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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "shim" >>"$4.agent" 2>&1
' _ "$GATE" "$WT2" "$O" "$O/logs/shim.log" "$PROMPT"
arm "$O/logs/shim.log"
ck "N3 the push shim really lies (origin/durable did NOT move to the lane's head: $(git -C "$BARE" rev-parse --short refs/heads/durable 2>/dev/null) vs $(git -C "$WT2" rev-parse --short HEAD))" \
  $([ "$(git -C "$BARE" rev-parse refs/heads/durable 2>/dev/null)" != "$(git -C "$WT2" rev-parse HEAD)" ] && echo 0 || echo 1)
grep -q "this lane's commits are not on that ref" "$O/logs/shim.log" && grep -q 'push=FAILED' "$O/state/lane-exit-shim.state"; rcn3=$?
ck "N4 …and the exit path does NOT record push=pushed for it: a 0 exit from the push is not a delivery" $rcn3
# ⛔ N4a-N4c — A DIFFERENT SHA IS TWO FACTS, AND ONLY ONE IS A NON-DELIVERY (review of PR #3399, P2 —
# REPRODUCED). The `!=` arm used to record `FAILED` and say "this lane's commits are NOT on that ref" on
# INEQUALITY ALONE — while listing "a concurrent move" as one of its causes, which is the opposite of what
# a concurrent move means. The verify read lands ~1 RTT after the push, on an account 22 concurrent landers
# share and a rail that fast-forwards: if a peer advanced the ref inside that window, origin's sha is our
# commit's DESCENDANT and every one of this lane's commits IS on it. Ancestry is local and decidable, so
# this fixture makes the remote's ref a descendant and asserts the delivery is recognised — AND asserts the
# absence claim is gone, so a fix that merely softened the wording without measuring would fail here.
N4D="$TMP/n4d"
rm -rf "$N4D"* "$N4D-origin.git"
git init -q --bare -b main "$N4D-origin.git"
git init -q -b main "$N4D-hub"
git -C "$N4D-hub" config user.name t; git -C "$N4D-hub" config user.email t@t
git -C "$N4D-hub" remote add origin "$GHURL"
git -C "$N4D-hub" config url."$N4D-origin.git".insteadOf "$GHURL"
printf 'n4d seed\n' > "$N4D-hub/seed.txt"
git -C "$N4D-hub" add seed.txt && git -C "$N4D-hub" commit -q -m 'n4d seed'
git -C "$N4D-hub" push -q origin HEAD:refs/heads/main
git -C "$N4D-hub" fetch -q origin
git -C "$N4D-hub" worktree add -q "$N4D-lane" -b desclane
git -C "$N4D-lane" config user.name t; git -C "$N4D-lane" config user.email t@t
printf 'n4d lane work\n' > "$N4D-lane/local.txt"
git -C "$N4D-lane" add local.txt && git -C "$N4D-lane" commit -q -m 'the lane commit'
n4d_mine="$(git -C "$N4D-lane" rev-parse HEAD)"
# the PEER ADVANCE: one commit ON TOP of the lane's head, pushed outside the lane, inside the verify window
git -C "$N4D-hub" worktree add -q "$N4D-peer" -b peerdesclane "$n4d_mine"
git -C "$N4D-peer" config user.name t; git -C "$N4D-peer" config user.email t@t
printf 'peer advance\n' > "$N4D-peer/peer.txt"
git -C "$N4D-peer" add peer.txt && git -C "$N4D-peer" commit -q -m 'a peer advanced the ref'
git -C "$N4D-peer" push -q origin HEAD:refs/heads/desclane
n4d_origin="$(git -C "$N4D-origin.git" rev-parse refs/heads/desclane)"
: > "$O/logs/n4d.log"
PATH="$TMP/bin-shim:$TMP/bin:$PATH" bash -c '
  . "$1"
  lane_end_push n4d "$2" "$3" desclane 1 1
  printf "push=%s origin=%s\n" "$LANE_END_PUSH" "$LANE_END_ORIGIN"
' _ "$GATE" "$O/logs/n4d.log" "$N4D-lane" 2>/dev/null > "$TMP/n4d.out"
# non-vacuity: the fixture really did put origin AHEAD of the lane's HEAD (not equal, not behind)
git -C "$N4D-origin.git" merge-base --is-ancestor "$n4d_mine" "$n4d_origin" 2>/dev/null \
  && [ "$n4d_mine" != "$n4d_origin" ]; rcn4a=$?
ck "N4a the fixture really made origin's ref a DESCENDANT of the lane's HEAD ($(printf '%s' "$n4d_mine" | cut -c1-8) → $(printf '%s' "$n4d_origin" | cut -c1-8)) — so the verdict below is about ancestry, not equality" $rcn4a
grep -q 'push=pushed' "$TMP/n4d.out" && ! grep -q 'push=FAILED' "$TMP/n4d.out" \
  && grep -q 'DESCENDANT' "$O/logs/n4d.log"; rcn4b=$?
ck "N4b …a fast-forward by a peer inside the verify window records DELIVERY (push=pushed), not FAILED — the lane's commits ARE on that ref [$(grep -m1 'push=' "$TMP/n4d.out" 2>/dev/null)]" $rcn4b
! grep -q "this lane's commits are not on that ref" "$O/logs/n4d.log"; rcn4c=$?
ck "N4c …and it does NOT keep the pre-fix absence claim beside a passing ancestry read — the sentence the old arm printed unconditionally" $rcn4c
# ⛔ N4e-N4i — AN ANCESTRY THAT COULD NOT BE MEASURED IS NOT A NON-DELIVERY (review round 2, P1 —
# REPRODUCED). `merge-base --is-ancestor` has THREE outcomes: 0 (ancestor), 1 (measured, NOT an ancestor)
# — and **128** when the object is not in THIS repository, which is the NORMAL shape for exactly the case
# this block exists for: a peer advanced the ref and this lane never fetched, so the peer's commit is
# unknown locally. Measured here: `--is-ancestor M D` → `fatal: Not a valid commit name` rc=128 before the
# fetch, rc=0 after. Treating every non-zero as "not an ancestor" printed a false durable absence for a
# genuine descendant. ⛔ N4d could NOT see it: the peer there was a WORKTREE OF THE SAME HUB, so `D` was
# always already in the lane's object store and `rc` could only ever be 0 — hence the SEPARATE CLONE here.
N4E="$TMP/n4e"
rm -rf "$N4E-lane" "$N4E-hub" "$N4E-peer" "$N4E-origin.git"
git init -q --bare -b main "$N4E-origin.git"
git init -q -b main "$N4E-hub"
git -C "$N4E-hub" config user.name t; git -C "$N4E-hub" config user.email t@t
git -C "$N4E-hub" remote add origin "$GHURL"
git -C "$N4E-hub" config url."$N4E-origin.git".insteadOf "$GHURL"
printf 'n4e seed\n' > "$N4E-hub/seed.txt"
git -C "$N4E-hub" add seed.txt && git -C "$N4E-hub" commit -q -m 'n4e seed'
git -C "$N4E-hub" push -q origin HEAD:refs/heads/main
git -C "$N4E-hub" fetch -q origin
git -C "$N4E-hub" worktree add -q "$N4E-lane" -b advlane
git -C "$N4E-lane" config user.name t; git -C "$N4E-lane" config user.email t@t
printf 'the lane commit\n' > "$N4E-lane/lane.txt"
git -C "$N4E-lane" add lane.txt && git -C "$N4E-lane" commit -q -m 'the lane commit'
n4e_mine="$(git -C "$N4E-lane" rev-parse HEAD)"
# ⛔ DELIBERATELY NO `-u` ON THE FIXTURE'S OWN PUSH: a `-u` here would pre-set the upstream and make N4i
# vacuous (it asserts the TERMINAL writes none).
git -C "$N4E-lane" push -q origin advlane:refs/heads/advlane
# a SEPARATE CLONE — not a worktree of the same hub — so the descendant object is absent from the lane
git clone -q "$N4E-origin.git" "$N4E-peer" 2>/dev/null
git -C "$N4E-peer" config user.name t; git -C "$N4E-peer" config user.email t@t
git -C "$N4E-peer" checkout -q -B advlane "$n4e_mine"
printf 'peer advance\n' > "$N4E-peer/peer.txt"
git -C "$N4E-peer" add peer.txt && git -C "$N4E-peer" commit -q -m 'a peer advanced the ref'
git -C "$N4E-peer" push -q origin HEAD:refs/heads/advlane
n4e_origin="$(git -C "$N4E-origin.git" rev-parse refs/heads/advlane)"
# non-vacuity: in the LANE's own object store the remote sha is UNKNOWN (rc=128), and it IS a descendant
git -C "$N4E-lane" merge-base --is-ancestor "$n4e_mine" "$n4e_origin" 2>/dev/null; rcn4e_pre=$?
git -C "$N4E-origin.git" merge-base --is-ancestor "$n4e_mine" "$n4e_origin" 2>/dev/null; rcn4e_org=$?
[ "$rcn4e_pre" = 128 ] && [ "$rcn4e_org" = 0 ]; rcn4e=$?
ck "N4e the fixture makes the remote's sha UNKNOWN to the lane (rc=$rcn4e_pre, not 1) while it really IS a descendant (origin's own rc=$rcn4e_org) — so this arm measures the 128 branch, which N4d structurally could not" $rcn4e
: > "$O/logs/n4e.log"
bash -c '
  . "$1"
  lane_end_push n4e "$2" "$3" advlane 1 1
  printf "push=%s origin=%s\n" "$LANE_END_PUSH" "$LANE_END_ORIGIN"
' _ "$GATE" "$O/logs/n4e.log" "$N4E-lane" 2>/dev/null > "$TMP/n4e.out"
grep -q 'push=verify-ancestry-unmeasured' "$TMP/n4e.out" && ! grep -q 'push=FAILED' "$TMP/n4e.out" \
  && grep -q 'ANCESTRY COULD NOT BE MEASURED' "$O/logs/n4e.log"; rcn4f=$?
ck "N4f …an ancestry the worktree cannot evaluate records verify-ancestry-unmeasured — NOT FAILED [$(grep -m1 'push=' "$TMP/n4e.out" 2>/dev/null)]" $rcn4f
! grep -q "commits are not on that ref" "$O/logs/n4e.log" && grep -q 'asserts NEITHER delivery NOR loss' "$O/logs/n4e.log"; rcn4g=$?
ck "N4g …and it makes no absence claim: neither 'not on that ref' nor 'NOT an ancestor', only that the relation was not measured" $rcn4g
n4e_next="$( bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_PUSH=verify-ancestry-unmeasured; LANE_END_ORIGIN=deadbeefcafe
  LANE_END_HEAD=feedface; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=advlane
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n4e_next" in MANUAL*'NEITHER delivery NOR loss'*) rcn4h=0 ;; *) rcn4h=1 ;; esac
ck "N4h …and next= is MANUAL and says the artifact asserts NEITHER delivery NOR loss, so a reclaim pass cannot read it as safe OR as lost [${n4e_next:0:60}]" $rcn4h
# ⛔ N4i — NO `-u` (review round 2, P2 — REPRODUCED). The terminal used to push with `-u`, writing
# `branch.<br>.remote`/`.merge` into the repository's SHARED config — which in a linked worktree is what
# every PEER worktree reads, so one dying lane silently gave another a `git pull`/`git push` default it
# never configured. The function's own contract already said "no `-u` on a guess".
[ -z "$(git -C "$N4E-lane" config --get branch.advlane.merge 2>/dev/null)" ] \
  && [ -z "$(git -C "$N4E-lane" config --get branch.advlane.remote 2>/dev/null)" ]; rcn4i=$?
ck "N4i …and the exit path writes NO upstream for the lane's branch — a dying terminal may not hand a peer worktree a pull/push default it never configured" $rcn4i
# ⛔ N4j — THE BOUNDED SCRATCH DIR IS RELEASED, AND THE PRIME MUST COME BEFORE THE FIRST BOUNDED CALL
# (review round 3, P2 — REPRODUCED). Every bounded call in `lane_end_push` is CAPTURED, so `tb_bound_tmp`'s
# `mktemp -d` runs in the command-substitution SUBSHELL unless the parent already holds the handle. With the
# prime sitting after the proof and symref reads, those two still minted their own directory and the parent
# cleaned up nothing — measured: two orphaned `bounded.*` dirs per lane exit, which is the accumulation this
# feature exists to stop. `TB_TIMEOUT_FORCE_INTERNAL=1` is part of the arm: without it this host's GNU
# `timeout` runs and the arm would measure a path that never touches the scratch dir at all.
# ⛔ AND THE REFUSAL PATHS ARE THE ONES THAT NEED IT MOST (review round 4, P2 — REPRODUCED). The first cut
# drove ONE successful push, so the `tb_bound_cleanup` calls on `refused-pushurl-unresolved`,
# `refused-pushurl-divergent` and `refused-protected` could all be deleted with the suite still green —
# measured, deleting 12 of the 13 cleanups left `217 passed`. Each of those returns is on the exit path of a
# lane that DID create the scratch dir (the prime runs before the push-target resolution), so a dropped
# cleanup leaks one dir per terminal on exactly the hosts this feature exists for. The loop below drives the
# three refusals that are constructible from this fixture, each with a FRESH `TMPDIR`, and requires zero
# leftover dirs in all of them. (`refused-unknown-default` and `push-killed` need a git shim to force the
# symref/exit-code shape and are covered by the same single statement — the failure they would catch is
# identical, so they are noted rather than duplicated.)
n4j_case() { # n4j_case <tag> <root> <branch> -> "push=<v> dirs=<n>"
  local tag="$1" rt="$2" br="$3" d out v
  d="$N4E-tmp-$tag"; rm -rf "$d"; mkdir -p "$d"
  out="$(TMPDIR="$d" TB_TIMEOUT_FORCE_INTERNAL=1 bash -c '
    . "$1"
    lane_end_push "$4" /dev/null "$2" "$3" 1 1
    printf "push=%s\n" "$LANE_END_PUSH"
  ' _ "$GATE" "$rt" "$br" "$tag" 2>/dev/null | tail -1)"
  v="$(printf '%s' "$out" | sed -n 's/^push=//p')"
  printf 'push=%s dirs=%s' "${v:-<none>}" "$(ls -d "$d"/bounded.* 2>/dev/null | wc -l | tr -d ' ')"
}
n4j_ok="$(n4j_case ok "$N4E-lane" advlane)"# the lane must have FETCHED for the ancestry to be measurable — otherwise this path is
# `verify-ancestry-unmeasured`, not `pushed`, and the arm would measure the wrong branch.
git -C "$N4E-lane" fetch -q origin 2>/dev/null
n4j_ok="$(n4j_case ok "$N4E-lane" advlane)"
# a REFUSAL constructible from this fixture: no `origin` at all -> the push target cannot be resolved.
git -C "$N4E-lane" remote remove origin 2>/dev/null
n4j_unres="$(n4j_case unres "$N4E-lane" advlane)"
git -C "$N4E-lane" remote add origin "$GHURL" 2>/dev/null
# and TWO push urls -> the exit path may not guess which repository receives its ref. TWO, because a
# single `--add --push` only REPLACES the default pushurl and leaves the count at 1 (measured: that
# variant recorded refused-unknown-default instead, so the arm would have measured the wrong refusal).
git -C "$N4E-lane" config --add remote.origin.pushurl "$N4E-origin.git"
git -C "$N4E-lane" config --add remote.origin.pushurl /tmp/n4j-a.git
n4j_div="$(n4j_case div "$N4E-lane" advlane)"
git -C "$N4E-lane" config --unset-all remote.origin.pushurl 2>/dev/null
# and a LANDING branch -> the push is refused before any network write.
git -C "$N4E-hub" checkout -q -b n4j-hubside 2>/dev/null
git -C "$N4E-hub" worktree add -q "$N4E-main" main 2>/dev/null
n4j_prot="$(n4j_case prot "$N4E-main" main)"
rm -f /tmp/n4j-a.git
case "$n4j_ok"  in 'push=pushed dirs=0')                        rcn4j=0 ;; *) rcn4j=1 ;; esac
case "$n4j_unres" in 'push=refused-pushurl-unresolved dirs=0')  : ;; *) rcn4j=1 ;; esac
case "$n4j_div"  in 'push=refused-pushurl-divergent dirs=0')     : ;; *) rcn4j=1 ;; esac
case "$n4j_prot" in 'push=refused-protected dirs=0')             : ;; *) rcn4j=1 ;; esac
ck "N4j …and the bounded scratch dir is RELEASED on the success path AND on every refusal that runs after the prime (ok=[$n4j_ok] unres=[$n4j_unres] div=[$n4j_div] prot=[$n4j_prot]) — a dropped cleanup leaks one dir per lane exit" $rcn4j
# ⛔ N4k — EVERY CONSUMER OF THE `push=` DOMAIN, NOT JUST THE TWO THAT WERE REMEMBERED (review round 3,
# P1 — REPRODUCED). `verify-ancestry-unmeasured` was added to `lane_end_next` and to
# `lane_end_push_caveat`, but NOT to the `[wip] NOTE` case in `terminal_wip_rescue` — the THIRD consumer —
# so it fell to that case's `*)` arm and printed "N commit(s) … exist ONLY locally and were NOT pushed" in
# the same terminal whose marker `next=` says "asserts NEITHER delivery NOR loss". A false measured
# absence, which is the one class this whole feature exists to remove. STATIC on purpose: driving the NOTE
# needs a full cap/clean-tree fixture, and what went stale is not the sentence but the DOMAIN LIST — the
# list is what this pins.
n4k_body="$(awk '/^terminal_wip_rescue\(\)/,/^}/' "$GATE" 2>/dev/null)"
n4k_miss=""
for n4k_v in verify-unanswered push-unreported push-killed verify-ancestry-unmeasured verify-head-unreadable; do
  grep -q "$n4k_v" <<< "$n4k_body" || n4k_miss="$n4k_miss $n4k_v"
done
[ -z "$n4k_miss" ] && grep -q 'MIGHT exist only locally' <<< "$n4k_body"; rcn4k=$?
ck "N4k the [wip] NOTE abstains for EVERY abstaining push verdict, not just the three it was written for (${n4k_miss:-none missing}) — a verdict added to the domain must be found in all THREE consumers, not the two that were remembered" $rcn4k
# ⛔ N4m — `FAILED` MAY NOT SIT IN THE NOTE'S ABSENCE ARM (review round 5, P2 — REPRODUCED). It is the
# THIRD consumer of a verdict that carries TWO measurements and it was the last one that did not split
# them: the remote ANSWERED and the ref is ABSENT (establishes "not on origin") vs the remote answered
# holding a DIFFERENT sha (this lane's commits may well BE on origin — a peer push, or a rail merge of
# them). Reproduced with a peer force-moving `refs/heads/reused` to an unrelated sha while the lane's
# commit really was pushed under `refs/heads/other`: this NOTE — the LAST line of the lane log, the order
# an operator reads — said the commits "exist ONLY locally and were NOT pushed" over a commit
# `git ls-remote origin other` answered with, while the `[lane-exit]` line above it declined to claim it.
# Static for the same reason N4k is: driving this NOTE needs a non-fast-forward fixture AND a peer move
# inside the verify window, and what went stale is the SHAPE of the arm, not the sentence.
n4m_ok=""
# ⛔ AND THE POLARITY, NOT JUST THE SENTENCES (review round 6, P2 — REPRODUCED). Asserting that four
# STRINGS exist in the function body cannot see the condition they hang off: inverting the guard to
# `[ -z "${LANE_END_ORIGIN:-}" ]` makes the NOTE print "exist ONLY locally and were NOT pushed" for the
# different-sha case and "holds that ref at a DIFFERENT sha (branch_on_origin=)" for the empty one —
# i.e. EXACTLY the defect this arm claims to prevent — and the suite stayed at 222 passed, 0 failed.
# So the arm is extracted and its test is pinned as a TEST.
n4m_arm="$(printf '%s\n' "$n4k_body" | awk '/^[[:space:]]*FAILED\)$/{f=1} f{print} f&&/^[[:space:]]*\*\)$/{exit}')"
[ -n "$n4m_arm" ] && n4m_ok="$n4m_ok FAILED-arm"
grep -qF 'if [ -n "${LANE_END_ORIGIN:-}" ]; then' <<< "$n4m_arm" && n4m_ok="$n4m_ok polarity"
grep -q 'branch_on_origin=\$LANE_END_ORIGIN' <<< "$n4m_arm" && n4m_ok="$n4m_ok splits-on-origin"
grep -q 'some OTHER ref was NOT measured' <<< "$n4m_arm" && n4m_ok="$n4m_ok abstains"
# control: the honest sentence must still exist for the ref-ABSENT half — deleting the split by deleting
# the sentence would pass the three greps above.
grep -q 'branch_on_origin empty' <<< "$n4m_arm" && n4m_ok="$n4m_ok keeps-the-absence-half"
case "$n4m_ok" in *FAILED-arm*polarity*splits-on-origin*abstains*keeps-the-absence-half*) rcn4m=0 ;; *) rcn4m=1 ;; esac
ck "N4m …and the NOTE splits FAILED on what the remote actually holds, rather than re-asserting the absence the [lane-exit] line above declines [$n4m_ok]" $rcn4m
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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "unknown default" >>"$4.agent" 2>&1
' _ "$GATE" "$TMP/wt5" "$O" "$O/logs/unknown.log" "$PROMPT"
arm "$O/logs/unknown.log"
ck "N6 an unreadable default is REFUSED (refused-unknown-default), never pushed on {main,master} alone" \
  $(grep -q 'refused-unknown-default' "$O/logs/unknown.log" && ! git -C "$BARE" rev-parse -q --verify refs/heads/trunk >/dev/null 2>&1 && echo 0 || echo 1)
# ⛔ N6b — THE VERDICT MUST ALSO REACH `next=` (review, PR #3399 P2). N6 above asserted the push verdict
# only, so `refused-unknown-default` was assigned by `lane_end_push`, matched NO arm in `lane_end_next`,
# and fell through to the generic `unpushed-only` sentence — which says "the commits are in the local
# object store, not on origin" and never says they die with the VOLUME. Measured before the fix: the
# marker read `next=the tree was clean but commit(s) on trunk were not pushed (push=refused-unknown-default)`
# with no MANUAL and no do-not-reap. The reclaim pass reads `next=`, so this arm is the one that matters.
mk6="$O/state/lane-exit-unknown_default.state"
[ -s "$mk6" ] && grep -qx 'push=refused-unknown-default' "$mk6" \
  && grep -q '^next=MANUAL' "$mk6" && grep -qi 'do NOT reap' "$mk6" && grep -qi 'volume' "$mk6"; rcn6b=$?
ck "N6b …and next= is MANUAL with an explicit do-not-reap and the volume consequence, not the generic 'in the local object store' sentence [$(grep '^next=' "$mk6" 2>/dev/null | cut -c1-70)]" $rcn6b
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
grep -q 'push=verify-head-unreadable' "$TMP/nohead.out" && ! grep -q 'push=pushed' "$TMP/nohead.out"; rcn8=$?
ck "N8 …an unreadable HEAD records verify-head-unreadable, never push=pushed and never FAILED (measured: $(head -c 60 "$TMP/nohead.out")) — FAILED asserted a comparison that was never made" $rcn8
# ⛔ N8c — AND THAT ARM MAY NOT ASSERT AN EXIT STATUS IT NEVER MEASURED (review round 5, P2 —
# REPRODUCED). `verify-head-unreadable` is reachable with a NON-ZERO push — the rc≠0/rc=0 split above
# covers only the arm where the verify read ALSO got no answer — so a push that failed but whose ref DOES
# exist on the remote (a server that applied the ref and then failed to report, or a rejected re-push of
# an already-delivered one) lands here. The sentence hardcoded "the push exited 0", in the arm added to
# stop exactly this class of false claim; measured with a shim whose `push` exits 1 and whose
# `rev-parse HEAD` exits 1 against an origin that really holds the ref. `lane_end_next`'s arm for this
# verdict never made the claim, so only the log was wrong — which is the line an operator reads first.
mkdir -p "$TMP/bin-nohead1"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 1 ;; *" rev-parse HEAD "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-nohead1/git"
chmod +x "$TMP/bin-nohead1/git"
: > "$TMP/rcnohead.log"
PATH="$TMP/bin-nohead1:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_LOG=/dev/null
  lane_end_push "no head rc" "$3" "$2" durable 1 1
  printf "push=%s" "$LANE_END_PUSH"
' _ "$GATE" "$WT2" "$TMP/rcnohead.log" 2>/dev/null > "$TMP/rcnohead.out"
grep -q 'push=verify-head-unreadable' "$TMP/rcnohead.out" \
  && grep -q 'the push exited 1' "$TMP/rcnohead.log" \
  && ! grep -q 'the push exited 0' "$TMP/rcnohead.log"; rcn8c=$?
ck "N8c …and its log names the exit status it MEASURED (push rc=1 → 'the push exited 1'), never a hardcoded 0 [$(grep -o 'the push exited [0-9?]*' "$TMP/rcnohead.log" 2>/dev/null | head -1)]" $rcn8c
# ⛔ N8b — AND THE ARTIFACT MAY NOT TURN THAT MISSING COMPARISON INTO A MEASURED ABSENCE (review round 4,
# P1 — REPRODUCED). `FAILED` used to carry this arm, and both consumers split only on `branch_on_origin`,
# so a HEAD that could not be read was published as "which is not the HEAD this terminal measured
# (<unknown>): the commit(s) from this lane were NOT delivered to that ref" — a fabricated absence.
n8b="$( bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_PUSH=verify-head-unreadable; LANE_END_ORIGIN=deadbeefcafe
  LANE_END_HEAD=; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=durable
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n8b" in MANUAL*'NO COMPARISON WAS MADE'*'NEITHER delivery NOR loss'*) rcn8b=0 ;; *) rcn8b=1 ;; esac
case "$n8b" in *'were NOT delivered'*|*'NOT on that ref'*) rcn8b=1 ;; esac
ck "N8b …and next= says NO COMPARISON WAS MADE / asserts neither, and never claims non-delivery [${n8b:0:70}]" $rcn8b
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
  LANE_END_LOG="$2/tr.log"; LANE_END_ROOT=/x; LANE_END_BRANCH=b
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
  LANE_END_LOG=/dev/null; LANE_END_ROOT=/x; LANE_END_BRANCH=b; LANE_END_MARKER_FRESH=1; LANE_END_PUSH=pushed; LANE_END_TREE=clean
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
# ⛔ ONE DEFINITION OF THE SCAN, RUN TWICE — against the gate AND against a mutant of it (review round 5,
# P1 — MEASURED). N14 and its own control (N14scan) had SEPARATE copies of this pipeline, so reverting
# N14's exemption to the old substring form left the control GREEN: measured, that mutant printed
# `222 passed, 0 failed`. A control that does not share the expression cannot see a regression in it —
# the control was asserting its own copy of the rule, which is the "one fact, two expressions" defect in
# the instrument rather than in the code. One function, two files passed to it.
n14_scan() { # n14_scan <gate-file> -> "<network> <local-config> <at-bound-position> <unbounded>"
  local j cmds n l b
  j=$(awk '
    # ⛔ STRIP PROSE ONLY: a quoted literal containing a SPACE reads as prose and is removed; a quoted
    # single token ("fetch", "git") is a WORD in a real command and its quotes are KEPT, so quoting a verb
    # or the command word is not a way to escape this scan. Both quote kinds are handled, and a backslash
    # escapes the next character (an `\"` inside a message must not invert the quote state).
    function strip_prose(s,   out, i, c, q, sq, buf, esc) {
      out = ""; buf = ""; q = 0; sq = 0; esc = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (esc) { if (q || sq) buf = buf c; else out = out c; esc = 0; continue }
        if (c == "\\") { esc = 1; if (q || sq) buf = buf c; else out = out c; continue }
        if (c == "\"" && sq == 0) {
          if (q == 0) { q = 1; buf = "" } else { q = 0; if (buf ~ / /) out = out " "; else out = out "\"" buf "\"" }
          continue
        }
        if (c == "\047" && q == 0) {
          if (sq == 0) { sq = 1; buf = "" } else { sq = 0; if (buf ~ / /) out = out " "; else out = out "\047" buf "\047" }
          continue
        }
        if (q || sq) buf = buf c; else out = out c
      }
      if (q || sq) out = out buf
      return out
    }
    function pushseg(s, sp, prose,   t) {
      if (s !~ /[^[:space:]]/) return
      if (prose == 1) return
      # Only the opening segment can still hold a literal; later ones begin outside quotes. `bash -c`
      # style wrappers are NOT stripped, so a call hidden in their argument stays visible (it then reads
      # UNBOUNDED, the fail-closed direction).
      if (sp == "" && s !~ /^[[:space:]]*(bash|sh|eval|command|env)([[:space:]]|$)/) {
        t = strip_prose(s); print t; return
      }
      print s
    }
    /^lane_end_push\(\)/,/^}/ {
      if ($0 ~ /^[[:space:]]*#/) next
      line = line $0
      if ($0 ~ /\\$/) { sub(/\\$/, "", line); next }
      cur = ""; sp = ""; q = 0; sq = 0; esc = 0; depth = 0; incase = 0; cprose = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1); two = substr(line, i, 2)
        if (esc) { cur = cur c; esc = 0; continue }
        if (c == "\\") { cur = cur c; esc = 1; continue }
        if (two == "$(" && sq == 0) {
          pushseg(cur, sp, cprose); cur = ""; sp = "$("
          qs[depth] = q; ss[depth] = sq; depth++; q = 0; sq = 0; cprose = 0; i++; continue
        }
        # `case … in 124)` closes nothing: a `)` while a `case` is open inside the substitution is a
        # PATTERN terminator, and popping there would hand the rest of a MESSAGE to the scan as code.
        if (depth > 0 && substr(line, i, 5) == "case ") incase = 1
        if (depth > 0 && substr(line, i, 4) == "esac") incase = 0
        if (c == ")" && depth > 0 && q == 0 && sq == 0 && incase == 0) {
          pushseg(cur, sp, cprose); cur = ""; sp = ")"
          depth--; q = qs[depth]; sq = ss[depth]; cprose = ((q == 1 || sq == 1) && depth == 0); continue
        }
        # ⛔ A SEPARATOR SPLITS AT ANY DEPTH (review round 10, P1 — REPRODUCED). Gating this on
        # `depth == 0` made a `$( … )` body ONE segment, so an unbounded call sharing a substitution with a
        # bounded sibling was certified by that sibling s bound: measured
        #   out9="$(tb_timeout 5 git -C "$root" rev-parse HEAD; git -C "$root" ls-remote …)"
        # -> `5 1 5 0`, unbounded 0, suite 222/0. `;` is a command separator inside a substitution exactly
        # as it is outside one; only quotes suppress it.
        if (q == 0 && sq == 0 && (two == "&&" || two == "||")) {
          pushseg(cur, sp, cprose); cur = ""; sp = two; cprose = 0; i++; continue
        }
        if (q == 0 && sq == 0 && (c == ";" || c == "|" || c == "&")) {
          pushseg(cur, sp, cprose); cur = ""; sp = c; cprose = 0; continue
        }
        # ⛔ BOTH QUOTE KINDS, AND A BACKSLASH ESCAPES THE NEXT CHARACTER (review round 10, P1 —
        # REPRODUCED). Without single-quote tracking a `local msg='"'"'do NOT git push'"'"'` line was scanned as
        # code (a fail-CLOSED false red); without escape handling an `\"` inside a message INVERTED the
        # quote state, so the message swallowed the `;` that followed it and `strip_prose` then deleted the
        # `git` token of a real joined call — `4 1 4 0`, suite 222/0, fail-OPEN.
        if (c == "\"" && sq == 0) { q = 1 - q; cur = cur c; continue }
        if (c == "\047" && q == 0) { sq = 1 - sq; cur = cur c; continue }
        cur = cur c
      }
      pushseg(cur, sp, cprose)
      line = ""
    }' "$1" 2>/dev/null)
  # ⛔ `$(`, `&&`, `||`, `;`, `|` AND `&` ALL SPLIT (review round 7, P1 — REPRODUCED). `$(` was missing, so
  # `out="$(git -C "$root" ls-remote …)"` — the shape every call in `lane_end_push` has — kept an
  # assignment prefix on the segment; and a single `&` did not split, so a backgrounded unbounded call
  # shared a line with the bounded push and was certified by the bound beside it. Measured:
  # `… & git -C "$root" fetch origin` injected above the push returned `5 1 5 0` — unbounded, count 0.
  cmds="$j"
  # ⛔ THE MATCHER IS THE COMMAND SHAPE, NOT ONE SPELLING OF IT (review round 7, P1 — REPRODUCED). It
  # required the literal `git -C "$root"`, so every other spelling of the same call was invisible to BOTH
  # counts and N14 stayed green: measured with this function on a copy of the gate, `git -C "${root}"
  # ls-remote …`, `( cd "$root" && git ls-remote … )` and the verbs `pull` / `remote update` / `clone` all
  # returned `4 1 4 0` — and the `$root` respelling passed the FULL suite at 222/0. Same class as rounds 5
  # and 6 twice above: the instrument's coverage was narrower than the claim it pins. With messages
  # excluded structurally, the remaining discriminator is simply "a `git` token in a COMMAND segment"; the
  # verb list is the network verbs git HAS, not the three this function happened to use, so an added
  # `pull`/`clone`/`remote update` is counted rather than assumed absent.
  # ⛔ RESIDUAL, NAMED, AND IT FAILS SAFE: a call bounded in another spelling's shape (`tb_timeout 15 bash
  # -c 'cd … && git ls-remote'`) counts as NETWORK but not as AT-BOUND, so it reads UNBOUNDED — over-block,
  # the direction R3 fails closed in. The prose side is the mirror image: a `git` verb inside a MESSAGE's
  # literal text is not counted, which is deliberate — but the cost is that prose carrying an imperative
  # AND a `$(…)` on one segment would be scanned, so an edit to those sentences can red this arm. That
  # direction over-blocks; it cannot hide a call, because a REAL call always has a `$(` or starts its own
  # command segment.
  # ⛔ A QUOTED COMMAND WORD IS STILL THE COMMAND (review round 10, P1 — REPRODUCED): `"git" -C "$root"
  # ls-remote …` scanned `4 1 4 0` because the character after `git` was a quote. The word may be quoted.
  seg_re='(^|[^-[:alnum:]_])"?git"?([[:space:]]|$)'
  seg_net='([^-[:alnum:]_]|^)(push|fetch|ls-remote|pull|clone)([[:space:]]|$)|([^-[:alnum:]_]|^)remote[[:space:]]+(update|show|prune|set-head)'
  # ⛔ THE VERB IS MATCHED AT COMMAND POSITION, NOT AS ANY SUBSTRING (review round 6, P1 — REPRODUCED).
  # The old test was `…\b(push|fetch|ls-remote)\b` MINUS `grep -v 'remote get-url'`, and that exclusion was
  # a whole-SEGMENT substring drop: any segment merely MENTIONING `remote get-url` vanished from both the
  # network count and the unbounded count. Measured by injecting
  #   out7="$(git -C "$root" ls-remote --heads "$pushurl" 2>/dev/null)"  # this IS a network read, and
  #                                                                       # no remote get-url happened here
  # above the bounded push: `n14_scan` returned `4 1 4 0` for the real gate AND for the mutant — the
  # unbounded read was not counted at all, and N14 stayed green at 222/0. Exactly the class round 5 closed
  # one line up; the comment on this arm claimed the direction was "never fail-open" while it stood.
  # ⇒ THE EXCLUSION WAS NEVER NEEDED. It existed because the generic verb regex matched the `--push` FLAG in
  # `git -C "$root" remote get-url --push --all origin`. Requiring the verb to be a COMMAND WORD — the
  # character before it is not `-`/alnum/underscore — separates the flag from the call without dropping the
  # segment: the flag match disappears, the real call stays, and a trailing comment can no longer exempt
  # anything because nothing is excluded by prose any more. `n_local` is still counted and still asserted
  # (=1), so the push-url read has to keep existing.
  n=$(printf '%s\n' "$cmds" | grep -E "$seg_re" | grep -E "$seg_net" | wc -l | tr -d ' ')
  l=$(printf '%s\n' "$cmds" | grep -c 'git -C "[^"]*" remote get-url' | tr -d ' ')
  # ⛔ AND `tb_timeout 0` IS NOT A BOUND (review round 6, P2 — REPRODUCED). `bounded.sh:30` defines
  # `<secs>` 0 as "no bound", and `tb_timeout 0 sleep 3` measures 3 s with rc=0 — so `[0-9]+` certified an
  # explicitly UNBOUNDED exit-path call as bounded. Measured: a mutant with
  # `out8="$(tb_timeout 0 git -C "$root" ls-remote --heads "$pushurl")"` injected above the push gave
  # `5 1 5 0` and 222/0. A leading non-zero digit is the whole fix.
  b=$(printf '%s\n' "$cmds" | grep -E "$seg_re" | grep -E "$seg_net" | grep -cE 'tb_timeout[[:space:]]+[1-9][0-9]*[[:space:]]+git([[:space:]]|$)' | tr -d ' ')
  printf '%s %s %s %s\n' "$n" "$l" "$b" "$((n - b))"
}
# ⛔ COUNTED PER COMMAND SEGMENT, NOT PER LINE (review cycle 7: joining continuations made a bounded and an
# unbounded call share one line, so `tb_timeout … ls-remote … \` + `&& git -C "$root" fetch origin` read as
# bounded — a fail-open the join CREATED). Every segment that contains a network verb must carry its own
# `tb_timeout`.
# ⛔ AND `remote get-url` USED TO BE EXCLUDED HERE AS A FALSE RED (review cycle 17, P2) — AND THAT
# EXCLUSION WAS ITSELF A FAIL-OPEN (review round 6, P1). The flag `--push` in `remote get-url --push --all
# origin` tripped the generic verb regex, so the segment was dropped; but `grep -v 'remote get-url'` drops a
# segment for MENTIONING the string, so a real unbounded read sharing a segment with that prose was dropped
# with it. `n14_scan` now matches the verb as a COMMAND WORD instead, which separates the flag from the call
# without excluding any segment — the false red and the fail-open were the same defect from two sides.
n14_res="$(n14_scan "$GATE")"
n_net=$(printf '%s\n' "$n14_res" | awk '{print $1}')
n_local=$(printf '%s\n' "$n14_res" | awk '{print $2}')
n_bounded_pos=$(printf '%s\n' "$n14_res" | awk '{print $3}')
n_unbounded=$(printf '%s\n' "$n14_res" | awk '{print $4}')
# ⛔ THE EXEMPTION IS THE BOUND'S COMMAND POSITION, NOT THE WORD SOMEWHERE IN THE SEGMENT (review round 5,
# P1 — REPRODUCED). The test was `grep -cv 'tb_timeout'`: a SUBSTRING match over the whole segment, so the
# word appearing anywhere exempted the call — including in a trailing COMMENT, which the awk above does not
# strip (it skips full-line `#` only). Measured by injecting
#   out2="$(git -C "$root" fetch origin 2>/dev/null)"  # tb_timeout
# immediately above the bounded push: `n_net=5 n_unbounded=0` → N14 GREEN over an UNBOUNDED fetch on the
# exit path. That is the one thing R3 exists to forbid, and it turns a dying lane into a worktree nobody
# can reap. The positive form is the shape every real call in `lane_end_push` actually has —
# `tb_timeout <secs> git -C "$root" <verb>` — so a comment can no longer pay for a call, while a bound on a
# DIFFERENT command still counts as unbounded (`,` `;` `&&` already split segments in `n14_scan`). The
# direction of the false verdict is now over-block, never fail-open. The expression lives in `n14_scan`
# ONLY, so the control below runs the same one.
[ "$n_bound" = 1 ] && [ "$n_sym" = 1 ] && [ "$n_ver" = 1 ] \
  && [ "$n_net" -ge 3 ] && [ "$n_unbounded" = 0 ] && [ "$n_local" = 1 ]; rcn14=$?
ck "N14 …every NETWORK call on the exit path is BOUNDED (15/15/5) — no unbounded and no continuation-split one (found $n_net network, $n_local local config read, $n_bounded_pos at bound position)" $rcn14
# ⛔ N14c — THE ARM ABOVE MUST BE ABLE TO SEE THE CLASS IT EXISTS FOR (review round 5, P1 — REPRODUCED).
# The substring form passed this suite for twenty-odd cycles while an unbounded `fetch` with a trailing
# `# tb_timeout` comment was invisible to it, so the assertion is now pinned against a MUTANT of the very
# function it scans: inject that exact call into a copy of the gate and require the same scan to count an
# unbounded network call. Without this, a future narrowing of the regex would go green on silence.
n14_mut="$TMP/n14mut"; mkdir -p "$n14_mut"
# ⛔ FIVE MUTANTS, ONE PER CLASS THIS EXPRESSION NOW COVERS (rounds 5, 7, 8, 9 and 10 — each REPRODUCED). 1: the
# round-5 class (an unbounded `fetch` whose trailing comment SAYS `tb_timeout`). 2: the round-7 class — a
# spelling the old literal matcher could not see at all (`"${root}"`, verb `pull`). 3: the `&` class — an
# unbounded call BACKGROUNDED onto a line whose bounded sibling would otherwise certify it. A control that
# shares only the first goes green when the matcher narrows back to one spelling, and one that omits the
# third goes green when the `&` splitter is reverted; both were measured green at 222/0 before they were
# pinned here. 4: the round-9 class — a REAL command `;`-joined to a message — which every per-statement
# rule (rounds 7 and 8) dropped: measured, reverting the quote-state rule leaves this mutant at 3 of 5.
# 5: the round-10 class — an unbounded call sharing a `$( … )` with a bounded sibling — which the depth gate
# dropped: measured, restoring the gate leaves this mutant at 4 of 5.
awk '{ print }
  !done && /tb_timeout 15 git -C "\$root" push/ {
    print "  out2=\"$(git -C \"$root\" fetch origin 2>/dev/null)\"  # tb_timeout"
    print "  out3=\"$(git -C \"${root}\" pull origin 2>/dev/null)\""
    print "  out4=\"$(tb_timeout 15 git -C \"$root\" rev-parse HEAD 2>/dev/null)\" & git -C \"$root\" fetch origin 2>/dev/null"
    print "  echo \"noop\" >> \"$log\" 2>/dev/null || true; git -C \"$root\" fetch origin 2>/dev/null"
    print "  out5=\"$(tb_timeout 5 git -C \"$root\" rev-parse HEAD 2>/dev/null; git -C \"${root}\" ls-remote /tmp/nope 2>/dev/null)\""
    done=1
  }' "$GATE" > "$n14_mut/gate.sh" 2>/dev/null
grep -q 'fetch origin 2>/dev/null)"  # tb_timeout' "$n14_mut/gate.sh" 2>/dev/null \
  && grep -q 'git -C "${root}" pull origin' "$n14_mut/gate.sh" 2>/dev/null \
  && grep -q 'rev-parse HEAD 2>/dev/null)" & git -C "$root" fetch origin' "$n14_mut/gate.sh" 2>/dev/null \
  && grep -q 'noop" >> "$log" 2>/dev/null || true; git -C "$root" fetch origin' "$n14_mut/gate.sh" 2>/dev/null \
  && grep -q 'rev-parse HEAD 2>/dev/null; git -C "${root}" ls-remote' "$n14_mut/gate.sh" 2>/dev/null; n14_inj=$?
# ⛔ THE SAME `n14_scan`, ON THE MUTANT — this is what makes the control real. If the exemption ever goes
# back to a substring test, field 4 here reads 0 over an unbounded `fetch` and N14scan reds.
n14_mut_unb=$(n14_scan "$n14_mut/gate.sh" | awk '{print $4}')
[ "$n14_inj" -eq 0 ] && [ "$n14_mut_unb" -ge 5 ]; rcn14scan=$?
ck "N14scan …and the arm can SEE five classes it has had to learn: a trailing comment that pretends to bound, a spelling it used not to match, a call BACKGROUNDED beside a bounded sibling, and a real command joined to a message by a semicolon, and an unbounded call sharing a substitution with a bounded sibling (injected: 5, counted unbounded: $n14_mut_unb of 5) — an exemption, a narrow matcher, a dropped ampersand split, a per-statement prose rule, or a substitution-boundary blind spot cannot pass this" $rcn14scan
# ⛔ N14b — THE BOUND MUST BOUND **WALL CLOCK**, NOT ONLY SPELLING (review cycle 10, P2 — REPRODUCED).
# N14 is a TEXT SCAN by construction, so it cannot see this class at all, and on a Linux host GNU
# `timeout` hides it: `tb_watchdog` used to `kill -9 "$pid"` — the DIRECT child only — so a command that
# FORKED a transport helper left the grandchild alive, and because every caller here captures
# (`out="$(tb_timeout … 2>&1)"`) the orphan held the CAPTURE PIPE and the substitution blocked for as
# long as the orphan lived. Measured on the pre-fix library: `tb_timeout 3` over a command that
# backgrounds a `sleep 8` → 8 s captured, 3 s redirected; against a real black-holed `git push` → 131 s
# for a declared 15 s. macOS is the host this library exists FOR (no GNU timeout), so the defect was
# invisible on every CI runner and live on the operator's own orchestrator. The fix signals the process
# GROUP (`set -m` + `kill -9 -pgid`), which is what GNU timeout does.
# ⛔ `TB_TIMEOUT_FORCE_INTERNAL=1` IS PART OF THE ARM: without it this host's GNU `timeout` would run and
# the arm would measure the WORKAROUND, passing on the broken library (the seam the library documents).
n14b_s=$(date +%s)
TB_TIMEOUT_FORCE_INTERNAL=1 bash -c '
  . "$1"
  out="$(tb_timeout 2 bash -c "( sleep 9 ) & sleep 9" 2>&1)"
  printf "rc=%s\n" "$?"' _ "$HERE/../lib/bounded.sh" >/dev/null 2>&1
n14b_e=$(( $(date +%s) - n14b_s ))
# 2 s bound + 4 s slack; the pre-fix library needs 9 s, so the arm discriminates with room to spare.
[ "$n14b_e" -le 6 ]; rcn14b=$?
ck "N14b …and the bound bounds WALL CLOCK: a CAPTURED command whose grandchild outlives the kill still returns at the bound (${n14b_e}s for a 2 s bound — 9 s before the process-group fix)" $rcn14b
# ⛔ N14c-N14e — THE BOUND MUST NOT BECOME A FLOOR (review round 2, P1 — REPRODUCED). N14b's fix gives the
# bounded command its OWN process group so the TIMER can reach a transport helper. The first cut forked the
# WATCHDOG under `set -m` too, so BOTH left the caller's group — and the fleet reaps a lane with
# `kill -TERM -- -<pgid>` then `-KILL` precisely so nothing is left resident. Measured, pre-fix, under a
# caller group-TERM: the bounded `sleep` SURVIVED at ppid 1 until its own bound expired. On a
# `tb_timeout 1800 python3` that is half an hour of resident work the census has to account for.
# ⛔ NO `setsid` HERE — macOS has none, and the fleet's orchestrator boxes are Macs. `set -m` in the
# probe's PARENT makes the probe its own group leader on any bash, which is the same shape a reaper
# creates; the arm asserts that shape (non-vacuity) before it signals anything.
# ⛔ AND THE ARM SCORES THE PID IT STARTED, NEVER AN ARGV MATCH (review round 3, P1 — REPRODUCED). Matching
# the process table for `sleep 4242` and then `pkill -9 -f` on it made two lanes running this suite on one
# box interfere: a leftover from an interrupted run read as "the bounded command SURVIVED" (a false red),
# and the cleanup then SIGKILLed a process this run did not own. The bounded command now publishes its own
# pid, which is the only handle that is true of THIS run — the measurement-artifact rule, applied to the
# instrument rather than to the product.
cat > "$TMP/n14c-probe.sh" <<'N14CPROBE'
set -u
export TB_TIMEOUT_FORCE_INTERNAL=1
. "$1"
tb_timeout 60 bash -c 'echo $$ > "$1"; exec sleep 4242' _ "$2" &
wait
N14CPROBE
n14c_pid="$(bash -c '
  set -m 2>/dev/null
  bash "$1" "$2" "$3" >/dev/null 2>&1 &
  printf "%s" "$!"' _ "$TMP/n14c-probe.sh" "$HERE/../lib/bounded.sh" "$TMP/n14c-child.pid")"
sleep 2
n14c_pgid="$(ps -o pgid= -p "${n14c_pid:-0}" 2>/dev/null | tr -d ' ')"
n14c_child="$(cat "$TMP/n14c-child.pid" 2>/dev/null)"
[ -n "$n14c_pid" ] && [ "$n14c_pgid" = "$n14c_pid" ] && [ -n "$n14c_child" ] && kill -0 "$n14c_child" 2>/dev/null; rcn14c=$?
ck "N14c the probe is a real caller-group shape (pgid ${n14c_pgid:-?} = pid ${n14c_pid:-?}) and ITS OWN bounded command is running (pid ${n14c_child:-?}) — so the signal below is the fleet's own shape" $rcn14c
kill -TERM -"${n14c_pid:-0}" 2>/dev/null
sleep 2
kill -0 "$n14c_child" 2>/dev/null; rcn14d=$?
[ "$rcn14d" -ne 0 ] && [ -n "${n14c_child:-}" ]; rcn14d=$?
ck "N14d …and a caller group-TERM reaches the bounded command: the pid THIS arm started is GONE (pre-fix it survived at ppid 1 for its whole bound — the watchdog was ungrouped with it and its trap forwarded nothing)" $rcn14d
[ -n "${n14c_child:-}" ] && kill -9 "$n14c_child" 2>/dev/null
# ⛔ AND THE ESCALATION: a command that IGNORES the forwarded TERM must not outlive the reap either, or
# ungrouping it would have hidden it from the reaper's second (KILL) stage.
cat > "$TMP/n14e-probe.sh" <<'N14EPROBE'
set -u
export TB_TIMEOUT_FORCE_INTERNAL=1
. "$1"
trap '' TERM
tb_timeout 60 bash -c 'echo $$ > "$1"; exec sleep 4343' _ "$2" &
wait
N14EPROBE
n14e_pid="$(bash -c '
  set -m 2>/dev/null
  bash "$1" "$2" "$3" >/dev/null 2>&1 &
  printf "%s" "$!"' _ "$TMP/n14e-probe.sh" "$HERE/../lib/bounded.sh" "$TMP/n14e-child.pid")"
sleep 2
n14e_child="$(cat "$TMP/n14e-child.pid" 2>/dev/null)"
kill -TERM -"${n14e_pid:-0}" 2>/dev/null
sleep 3
kill -0 "$n14e_child" 2>/dev/null; rcn14e=$?
[ "$rcn14e" -ne 0 ] && [ -n "${n14e_child:-}" ]; rcn14e=$?
ck "N14e …and a TERM-IGNORING command is ESCALATED to SIGKILL by the watchdog, so ungrouping it did not hide it from the reaper's second stage (pid ${n14e_child:-?})" $rcn14e
# ⛔ NEVER DEFAULT A PID TO `0` (review round 4, P1 — REPRODUCED). `kill -9 "${pid:-0}"` with no pid sends the
# signal to PROCESS GROUP 0 = the caller's own group: measured, it KILLED THE SUITE mid-run (rc=137, no RESULT
# line). And `kill -0 0` SUCCEEDS against that group, so the "is it gone?" arms reported GONE while the bounded
# command was still alive — a false PASS built on the missing datum, on the very boxes (a full disk) where the
# pid file may not be written. Guard the emptiness; never substitute a pid.
for n14_p in ${n14e_child:-} ${n14c_child:-}; do [ -n "$n14_p" ] && kill -9 "$n14_p" 2>/dev/null; done
:
# ⛔ N15 — THE HUB REFUSAL IS READ, NOT INHERITED (review cycle 4, gap 3: F7 executes the shape but no arm
# ever greps `refused-main-checkout`, so deleting the block left the suite green — the merge-gate bypass
# the comment names, undetected).
chk_hub=$(awk '/^lane_end_push\(\)/,/^}/' "$GATE" 2>/dev/null | grep -c 'LANE_END_PUSH="refused-main-checkout"')
[ "$chk_hub" = 1 ] && grep -q 'rev-parse --git-dir' "$GATE" 2>/dev/null \
  && grep -q 'rev-parse --git-common-dir' "$GATE" 2>/dev/null; rcn15=$?
ck "N15 …a hub checkout (git-dir == git-common-dir) is refused BY NAME in lane_end_push, not merely skipped by luck" $rcn15
# ⛔ N15b — AN UNREADABLE DISCRIMINATOR IS A REFUSAL, NOT "NOT A HUB" (review, PR #3399 P2). The guard
# used to be `[ -n "$gd" ] && [ -n "$cd" ] && [ "$gd" = "$cd" ]`, so a read that answered NOTHING skipped the
# hub refusal entirely and fell through to the push. N15 above only greps the block's existence, which
# cannot see that: this arm makes ONE read fail and requires the lane to refuse. Reachability is depth
# (`--git-common-dir` exists since git 2.5), and the point is not the odds — it is that inside one
# function the same doctrine must not be applied to one measurement and skipped for the next.
mkdir -p "$TMP/bin-nocommondir"
{ printf '#!/bin/sh\ncase " $* " in *" --git-common-dir "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-nocommondir/git"
chmod +x "$TMP/bin-nocommondir/git"
git -C "$WT" worktree add -q "$TMP/wtshape" -b shapeunknown 2>/dev/null
pi_stub unpushed
: > "$O/logs/shape.log"
PATH="$TMP/bin-nocommondir:$TMP/bin:$PATH" PI_LOG="$O/pi9.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "shape unknown" >>"$4.agent" 2>&1
' _ "$GATE" "$TMP/wtshape" "$O" "$O/logs/shape.log" "$PROMPT"
arm "$O/logs/shape.log"
grep -q 'could NOT establish whether' "$O/logs/shape.log" && ! git -C "$BARE" rev-parse -q --verify refs/heads/shapeunknown >/dev/null 2>&1; rcn15b=$?
ck "N15b …and an UNREADABLE git-common-dir is REFUSED before any push (nothing reached origin), naming the failed read — not treated as 'therefore not a hub'" $rcn15b
mk15b="$O/state/lane-exit-shape_unknown.state"
[ -s "$mk15b" ] && grep -qx 'push=UNAVAILABLE' "$mk15b" && grep -q '^next=MANUAL' "$mk15b"; rcn15c=$?
ck "N15c …and the artifact says push=UNAVAILABLE with next=MANUAL, so a reclaim pass cannot read an unknown shape as safe" $rcn15c
# ⛔ N15d — THE HUB REFUSAL IS DRIVEN, NOT MERELY READ (review cycle 8, P1 — REPRODUCED). N15 greps the
# block's existence and N15b/N15c break a READ; NEITHER drives a hub checkout that HAS a working origin,
# so the equality could be neutered (`[ "$gd" = "$cd" ]` -> `[ "$gd" = "NEVER-EQUAL" ]`) and this suite
# stayed green while the lane PUSHED its branch to origin — the merge-gate bypass the block exists to
# close, undetected by every arm in this file. N19 already states the rule for R6: "a scan proves a verb
# is absent; it cannot prove a DIVERGENT branch is refused". Same rule, same missing arm.
HUB="$TMP/hub"
git init -q -b hubfeature "$HUB"
git -C "$HUB" config user.name t; git -C "$HUB" config user.email t@t
git -C "$HUB" remote add origin "$GHURL"
git -C "$HUB" config url."$BARE".insteadOf "$GHURL"
printf 'hub seed\n' > "$HUB/seed.txt"
git -C "$HUB" add seed.txt && git -C "$HUB" commit -q -m 'hub seed'
# ⛔ AN UNPUSHED COMMIT IS PART OF THE FIXTURE, NOT SET DRESSING: `lane_end_push` short-circuits on
# `unpushed <= 0`, so a hub whose branch is already on origin would measure `push=nothing` and this arm
# would pass on the ungated tree too.
printf 'hub local\n' > "$HUB/local.txt"
git -C "$HUB" add local.txt && git -C "$HUB" commit -q -m 'hub local only'
# ⛔ AND THE DISCRIMINATOR IS ASSERTED, NOT ASSUMED: `git-dir` must EQUAL `git-common-dir` in the hub (that
# is what makes it a MAIN checkout) — else the arm has no subject. ⛔ NOT `$WT`: `$WT` is itself a MAIN
# checkout (`git init`), so asserting it DIFFERS was a false assertion about the fixture, not a defect in
# the gate (measured: this arm went red on its own wrong premise while N15d below it passed).
[ "$(git -C "$HUB" rev-parse --git-dir)" = "$(git -C "$HUB" rev-parse --git-common-dir)" ] \
  && [ "$(git -C "$HUB" rev-list --count HEAD --not --remotes)" -gt 0 ]; rcn15d0=$?
ck "N15d0 FIXTURE: the hub's git-dir EQUALS its git-common-dir (a main checkout) and its branch holds an unpushed commit — else this arm has no subject" $rcn15d0
pi_stub clean
: > "$O/logs/hub.log"; rm -f "$O/state/lane-exit-hub.state"
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi9.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "hub" >>"$4.agent" 2>&1
' _ "$GATE" "$HUB" "$O" "$O/logs/hub.log" "$PROMPT"
arm "$O/logs/hub.log"
grep -q 'is the repo.s MAIN CHECKOUT' "$O/logs/hub.log" \
  && ! git -C "$BARE" rev-parse -q --verify refs/heads/hubfeature >/dev/null 2>&1; rcn15d=$?
ck "N15d …a MAIN CHECKOUT holding an unpushed branch is REFUSED by name and NOTHING reaches origin (refs/heads/hubfeature absent) — driven, not grepped" $rcn15d
mk15d="$O/state/lane-exit-hub.state"
[ -s "$mk15d" ] && grep -qx 'push=refused-main-checkout' "$mk15d" && grep -q '^next=' "$mk15d"; rcn15e=$?
ck "N15e …and the artifact records push=refused-main-checkout with a next=, so the refusal is visible to a reclaim pass [$(grep -m1 '^push=' "$mk15d" 2>/dev/null)]" $rcn15e
# ⛔ N15f — R3's SECOND CLAUSE HAD NO ARM (review of PR #3399 round 11, P2). R3 reads "no unbounded network
# call on the exit path; a missing bound is a REFUSAL, not a hang". The first clause is pinned hard
# (N14/N14b, with N14c-e as the mutant controls); the second was pinned only by GREPPING that the refusal
# block EXISTS in the source — and a grep cannot tell "refuses" from "pushes anyway", which is exactly why
# N15d exists one block up. So the library is made genuinely UNFINDABLE rather than read about: an isolated
# copy of the gate whose sibling `../lib/` has no `bounded.sh`, an `$O` with no `lib/`, and HOME +
# AGENT_INFRA_PATH emptied so neither farmed home can answer either. The lane must refuse by name and
# reach no origin.
NB="$TMP/nobound"; rm -rf "$NB"; mkdir -p "$NB/harness" "$NB/lib"
# ⛔ THE WITHHELD THING IS `lib/bounded.sh` AND NOTHING ELSE, AND AN ISOLATE THAT WITHHELD MORE WOULD
# MEASURE THE WRONG REFUSAL — twice measured while building this arm. `brief_gate_lib` resolves
# `brief-gate.sh` as a SIBLING of this gate (exit 78, "brief-gate.sh not found"), and the landing-ratio
# gate needs `repo-slug.sh` beside it ("UNREADABLE repo … Creation is HELD") — each of those refuses
# BEFORE the push, so a bare copy of the gate reports a refusal that has nothing to do with the bound.
# The isolate is therefore a SYMLINK FARM of the real harness dir and its `lib/`, with exactly one entry
# deleted: `bounded.sh`. Every other resolver still answers; the bound cannot.
for f in "$HERE"/*; do ln -s "$f" "$NB/harness/$(basename "$f")"; done
for f in "$HERE/../lib"/*; do ln -s "$f" "$NB/lib/$(basename "$f")"; done
rm -f "$NB/lib/bounded.sh"
# The fixture must be a LINKED worktree (D0's rule) holding a REAL unpushed commit: `lane_end_push`
# short-circuits on `unpushed <= 0`, so without one this arm would go green over a lane that never tried to
# push at all — the vacuous-control shape the D8/D9 arms exist to prevent.
git -C "$WT" worktree add -q "$TMP/wtnb" -b nobound 2>/dev/null
# `nobound` is ONE WORD because `lane_end_marker` SLUGIFIES the label into the filename: the first cut of
# this fixture used `no bound` and wrote `lane-exit-no_bound.state`, while N15g read
# `lane-exit-nobound.state` — a red arm that had nothing to do with the behaviour it asserts. The label
# and the filename must agree by construction, not by luck.
pi_stub unpushed
: > "$O/logs/nobound.log"; rm -f "$O/state/lane-exit-nobound.state"
HOME="$TMP/emptyhome" AGENT_INFRA_PATH= PATH="$TMP/bin:$PATH" PI_LOG="$O/pi10.log" bash -c '
  . "$1"
  cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "nobound" >>"$4.agent" 2>&1
' _ "$NB/harness/spawn-gate.sh" "$TMP/wtnb" "$O" "$O/logs/nobound.log" "$PROMPT"
arm "$O/logs/nobound.log"
# ⛔ AND THE FIXTURE IS ASSERTED, NOT ASSUMED (N15d0's discipline): the lane must really hold an unpushed
# commit, and the isolated tree must really have NO bounded.sh — else this arm measures nothing.
[ "$(git -C "$TMP/wtnb" rev-list --count HEAD --not --remotes)" -gt 0 ] && [ ! -e "$NB/lib/bounded.sh" ]; rcn15f0=$?
ck "N15f0 FIXTURE: the isolated tree has NO lib/bounded.sh and the lane really holds an unpushed commit — else this arm has no subject" $rcn15f0
grep -q 'scripts/lib/bounded.sh was not found' "$O/logs/nobound.log" \
  && ! git -C "$BARE" rev-parse -q --verify refs/heads/nobound >/dev/null 2>&1; rcn15f=$?
ck "N15f …a MISSING scripts/lib/bounded.sh REFUSES the push by name and reaches no origin (refs/heads/nobound absent) — R3's 'a missing bound is a refusal, not a hang', driven rather than grepped" $rcn15f
mk15f="$O/state/lane-exit-nobound.state"
[ -s "$mk15f" ] && grep -qx 'push=UNAVAILABLE' "$mk15f" && grep -q '^next=MANUAL' "$mk15f"; rcn15g=$?
ck "N15g …and the artifact records push=UNAVAILABLE with next=MANUAL, so a reclaim pass cannot read an unbound exit as safe [$(grep -m1 '^push=' "$mk15f" 2>/dev/null)]" $rcn15g
# ⛔ N15h — THE LAST LINE OF THE LANE LOG MAY NOT ASSERT AN OFF-BOX ABSENCE (review of PR #3399 round 14,
# P2 — REPRODUCED). `[wip] NOTE`'s fallback arm still said "exist ONLY locally and were NOT pushed" from
# `unpushed>0`, i.e. from the LOCAL `refs/remotes/*` cache — the third consumer of that enumeration, after
# `next=` and the shared caveat. It is the line an operator reads LAST. This arm is driven through the
# real `run_agent`: the isolated-harness lane above ends `push=UNAVAILABLE` and writes exactly that NOTE.
! grep -q 'exist ONLY locally' "$O/logs/nobound.log" \
  && grep -q "LOCAL refs/remotes/\* cache" "$O/logs/nobound.log" \
  && grep -q 'NOT a claim about any remote' "$O/logs/nobound.log"; rcn15h=$?
ck "N15h …and the [wip] NOTE that ends the lane log scopes the same claim to the LOCAL cache instead of asserting the commits exist only on this disk" $rcn15h
# …and the note still carries the survival facts, so it is scoped and not deleted.
grep -q 'They survive this WORKTREE being removed' "$O/logs/nobound.log"; rcn15i=$?
ck "N15i …while still naming what does and does not survive (scoped, not silenced)" $rcn15i
# ⛔ N23 — ANY DOMAIN THAT SAYS MANUAL OUTRANKS A DOMAIN THAT ONLY REPORTS (review cycle 8, P1).
# `lane_end_next`'s arms are `return 0`, so arm ORDER decided the verdict: the push case ran first, and its
# `refused-protected|refused-main-checkout` arm is a NON-MANUAL sentence, so a DIRTY tree whose archive
# FAILED was told only about its branch — losing "uncommitted work is NOT archived; do NOT reap it" from
# the one artifact a reclaim pass reads. Measured on the pre-fix helper: `dirty + refused-protected +
# rescue=FAILED` -> "commit(s) on develop were NOT pushed … re-dispatch", while the same tree with
# `push=pushed` -> MANUAL. A DIRECT call is honest here and not a stub of the subject: `lane_end_next` is
# a PURE function of the LANE_END_* globals `terminal_wip_rescue` assigns, so setting them is exactly what
# a drive would do — and it is the only way to reach this matrix (a real `refused-protected` push needs a
# lane branch named after the remote's default, which a fixture cannot do without also testing git).
nx="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=FAILED; LANE_END_PUSH=refused-protected
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx" in MANUAL*"do NOT reap"*) rcn23=0 ;; *) rcn23=1 ;; esac
ck "N23 a DIRTY tree whose archive FAILED still gets next=MANUAL / do-not-reap when the push was refused-protected — the rescue fact is not silenced by the push arm [${nx:0:72}]" $rcn23
nx2="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=FAILED; LANE_END_PUSH=pushed
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
# ⛔ "NOT archived" IS NOT A MEASURABLE CLAIM ON THIS ARM (P1 — REPRODUCED). `FAILED` is `rc2 != 0` AND no
# ref THIS RUN wrote, and `bg-rescue-wip.sh` exits 2 for a PARTIAL archive whose push SUCCEEDED and for a
# chain failure — so the flat "uncommitted work … is NOT archived" it used to print denied an archive that
# can be sitting on origin, and contradicted the log line for the SAME terminal. The scoped rescue fact is
# asserted FOR, the flat claim AGAINST, and the union (push=pushed must not silence it) is unchanged.
case "$nx2" in MANUAL*"do NOT reap"*) rcn23b=0 ;; *) rcn23b=1 ;; esac
case "$nx2" in *"is NOT archived"*) rcn23b=1 ;; *) : ;; esac
case "$nx2" in *"no ref this run wrote pins the uncommitted work"*) : ;; *) rcn23b=1 ;; esac
ck "N23b …and the SAME tree with push=pushed still reaches a MANUAL / do-not-reap sentence that SCOPES the rescue fact to this run (exit 2 also covers a PARTIAL archive that pushed, so a flat NOT-archived is unprovable) [${nx2:0:64}]" $rcn23b
nx3="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=FAILED; LANE_END_PUSH=refused-main-checkout
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx3" in MANUAL*"do NOT reap"*) rcn23c=0 ;; *) rcn23c=1 ;; esac
ck "N23c …the same union holds for refused-main-checkout (both non-MANUAL push verdicts merge the rescue domain in)" $rcn23c
nx4="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=refused-protected
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx4" in MANUAL*"uncommitted work"*) rcn23d=0 ;; *) rcn23d=1 ;; esac
ck "N23d …and a DIRTY tree with a refused push names the uncommitted work even when no rescue value is set (the weak branch-only sentence is no longer reachable over an un-archived tree)" $rcn23d
# ⛔ N23e — A CLEAN TREE IS THE SAME RISK, SO IT GETS THE SAME KEYWORD (review cycle 11, P2 — the arm used
# to pin the OPPOSITE). `refused-protected` on an `unpushed-only` tree returned a reporter sentence with no
# `MANUAL`, while `refused-unknown-default` on the IDENTICAL state (commits on this disk only) is hoisted
# into the MANUAL case — so a consumer filtering on this file's own MANUAL convention reclaimed the one
# worktree and refused the other over the same fact. N23 was right that the rescue fact must not be
# silenced; it was wrong that the branch fact may be spoken without the keyword.
nx5="$( bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing; LANE_END_PUSH=refused-protected
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx5" in MANUAL*"NOT pushed"*"do NOT reap"*) rcn23e=0 ;; *) rcn23e=1 ;; esac
ck "N23e …and a CLEAN (unpushed-only) tree with a refused push NOW gets MANUAL / do-not-reap too — the keyword follows the RISK (commits on this disk only), not the tree verdict [${nx5:0:72}]" $rcn23e
# ⛔ N24 — A "ZERO" NOBODY READ IS NOT A MEASURED ZERO, IN THE MARKER TOO (review cycle 8, P2).
# `LANE_END_UNPUSHED` is reset to `0` before the hatch can return, so a not-measured terminal wrote
# `unpushed=0` — a count published as measured, one line above `state=not-measured`, in the artifact a
# reclaim pass reads FIELD BY FIELD. The file already refuses this shape on the TSV column (`?`).
nl="$( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=not-measured; LANE_END_RESCUE=DISABLED; LANE_END_UNPUSHED=0
  LANE_END_LOG=/dev/null; LANE_END_MARKER_FRESH=1
  lane_end_marker n24 0 10' _ "$GATE" "$TMP/n24O" 2>/dev/null )"
mk24="$TMP/n24O/state/lane-exit-n24.state"
[ -s "$mk24" ] && grep -qx 'state=not-measured' "$mk24" && grep -qx 'unpushed=?' "$mk24" \
  && ! grep -qx 'unpushed=0' "$mk24"; rcn24=$?
ck "N24 a NOT-MEASURED terminal records unpushed=? — never a 0 nobody read, in the marker as on the TSV column" $rcn24
# ⛔ N25 — THE MARKER IS LINE-ORIENTED, SO ITS VALUES ARE FLATTENED (review cycle 8, P2). The ledger's own
# writer already does this for its path column (`tr '\t\n' '  '`); `root` is a caller-supplied `WIP_PATH`,
# so an embedded newline injected a bogus `key=value` line and every `while read k=v` consumer mis-parsed
# the rest of the file. Only the label and root are flattened (the `porcelain:` section is raw BY DESIGN).
rm -rf "$TMP/n25O"
( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=clean; LANE_END_RESCUE=nothing; LANE_END_UNPUSHED=0
  LANE_END_ROOT="$(printf "/tmp/ro\nINJECTED")"; LANE_END_LOG=/dev/null; LANE_END_MARKER_FRESH=1
  lane_end_marker "$(printf "la\nbel")" 0 10' _ "$GATE" "$TMP/n25O" 2>/dev/null )
mk25="$TMP/n25O/state/lane-exit-label.state"
[ -s "$mk25" ] && [ "$(grep -c '^label=' "$mk25")" = 1 ] \
  && ! grep -qx 'INJECTED' "$mk25" && ! grep -qx 'bel' "$mk25"; rcn25=$?
ck "N25 a NEWLINE in the label or in WIP_PATH is flattened — it cannot inject a line into the marker's key=value stream [$(grep -m1 '^label=' "$mk25" 2>/dev/null)]" $rcn25
# ⛔ N26 — A STALE CACHE IS NOT AN ANSWER (review cycle 9, P0 — REPRODUCED END-TO-END before the fix).
# The landing-branch guard used to let the clone's cached `refs/remotes/origin/HEAD` SUBSTITUTE for the
# remote's own answer (`[ -z "$def" ] && [ -z "$c" ]`), so a cache that merely EXISTED satisfied "we know
# the default". Measured on the pre-fix helper: a bare whose REAL default was `trunk`, a clone whose cache
# still said `origin/main`, `ls-remote --symref` silent, and a lane on `trunk` -> the exit path PUSHED
# `refs/heads/trunk` (the remote's own landing branch) and recorded `push=pushed`. That is a dying lane's
# exit hook moving a landing branch, skipping the rail AND the attestation, reported as a clean delivery.
# This arm is the fixture from that reproduction: the cache names a DIFFERENT branch from the real default.
N26="$TMP/n26"
git init -q --bare -b trunk "$N26-origin.git"
git init -q -b n26base "$N26-hub"
git -C "$N26-hub" config user.name t; git -C "$N26-hub" config user.email t@t
git -C "$N26-hub" remote add origin "$GHURL"
git -C "$N26-hub" config url."$N26-origin.git".insteadOf "$GHURL"
printf 'n26 seed\n' > "$N26-hub/seed.txt"
git -C "$N26-hub" add seed.txt && git -C "$N26-hub" commit -q -m 'n26 seed'
git -C "$N26-hub" push -q origin n26base:trunk
git -C "$N26-hub" fetch -q origin
git -C "$N26-hub" worktree add -q "$N26-lane" -b trunk origin/trunk
git -C "$N26-lane" config user.name t; git -C "$N26-lane" config user.email t@t
printf 'n26 local\n' > "$N26-lane/local.txt"
git -C "$N26-lane" add local.txt && git -C "$N26-lane" commit -q -m 'n26 local only'
# the STALE cache: the clone still believes the default is `main`
git -C "$N26-hub" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
n26_before="$(git -C "$N26-origin.git" rev-parse refs/heads/trunk)"
: > "$O/logs/n26.log"
# `ls-remote --symref` silent = the bound timing out; the cache is present, the remote's answer is not.
PATH="$TMP/bin-nosymref:$TMP/bin:$PATH" bash -c '
  . "$1"
  lane_end_push n26 "$2" "$3" trunk 1 1
  printf "push=%s origin=%s\n" "$LANE_END_PUSH" "$LANE_END_ORIGIN"
' _ "$GATE" "$O/logs/n26.log" "$N26-lane" 2>/dev/null > "$TMP/n26.out"
n26_after="$(git -C "$N26-origin.git" rev-parse refs/heads/trunk)"
[ "$n26_before" = "$n26_after" ] && grep -q 'push=refused-unknown-default' "$TMP/n26.out" \
  && grep -q 'could NOT DETERMINE' "$O/logs/n26.log" \
  && ! grep -q 'pushed trunk' "$O/logs/n26.log"; rcn26=$?
ck "N26 a SILENT remote + a STALE clone cache does NOT license a push of the remote's real default (trunk did not move; the cache is a name to refuse on, never an answer) [$(grep -m1 'push=' "$TMP/n26.out" 2>/dev/null)]" $rcn26
n26m="$( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing; LANE_END_PUSH=refused-unknown-default
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=trunk
  lane_end_next' _ "$GATE" "$TMP/n26O" 2>/dev/null )"
case "$n26m" in MANUAL*"do NOT reap"*) rcn26b=0 ;; *) rcn26b=1 ;; esac
ck "N26b …and next= is MANUAL / do-not-reap, so the artifact does not read this refusal as a clean delivery" $rcn26b
# ⛔ N27 — A REPORTER MAY NOT SILENCE A MANUAL ARM (review cycle 9, P1 — REPRODUCED, the cycle-8 fix's own
# REGRESSION). Hoisting only the rescue `FAILED`/`archived-local` block put `archived-local` — a REPORTER —
# above the MANUAL push set, so `dirty + archived-local + push=FAILED` printed "retrieve the archive …
# (local pin only — the OFF-BOX push is unconfirmed)" and returned: the branch fact was dropped, and a
# known-FAILED push was described as merely "unconfirmed". Measured on f842544e.
for n27p in FAILED UNAVAILABLE detachdrunning; do
  case "$n27p" in detachdrunning) n27p=detached ;; esac
  n27="$( bash -c '
    . "$1"
    LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH="$2"
    LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop; LANE_END_REF=refs/wip-local/develop
    lane_end_next' _ "$GATE" "$n27p" 2>/dev/null )"
  case "$n27" in MANUAL*"do NOT reap"*) rcn27=0 ;; *) rcn27=1 ;; esac
  ck "N27 a known-$n27p push is NOT described as 'unconfirmed' and still says do-not-reap when the archive is local-only [${n27:0:64}]" $rcn27
done
n27b="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=pushed
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop; LANE_END_REF=refs/wip-local/develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n27b" in *refs/wip-local/develop*) rcn27b=0 ;; *) rcn27b=1 ;; esac
ck "N27b …while with a known-GOOD branch push the archive sentence still names the local pin (the reporter is not silenced by a MANUAL arm that never fired)" $rcn27b
# ⛔ N28 — cannot-verify MAY NOT BE TOLD TO 'read the log before removing it' (review cycle 9, P1). The
# lane LOG for this state says "Do not reap this worktree on the strength of this row"; the artifact, which
# is what a reclaim pass keys on, said only "read the [wip] line before removing it". One run then refuses
# in its log and licenses a reclaim in its marker. Reachable with push=nothing|pushed, so no MANUAL push
# arm above has fired.
for n28p in nothing pushed; do
  n28="$( bash -c '
    . "$1"
    LANE_END_TREE=cannot-verify; LANE_END_RESCUE=nothing; LANE_END_PUSH="$2"
    LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
    lane_end_next' _ "$GATE" "$n28p" 2>/dev/null )"
  # ⛔ CASE-INSENSITIVE ON PURPOSE: the sentence reads "Do NOT reap", and a `case` pattern is
  # case-sensitive — the first cut of this arm matched "do NOT reap" and went red on its own wording
  # while the behaviour was correct.
  { case "$n28" in MANUAL*) : ;; *) false ;; esac; } && grep -qi 'NOT reap' <<<"$n28"; rcn28=$?
  ck "N28 cannot-verify with push=$n28p gets next=MANUAL / do-not-reap — the artifact and the lane log agree [${n28:0:60}]" $rcn28
done
# ⛔ N29 — THE OTHER UNMEASURED EARLY RETURN LEARNS THE SAME LESSON (review cycle 9, P2). N24/G10b cover
# the WIP_RESCUE_DISABLE hatch; `not-a-worktree` reaches the writer through the other early return and was
# still publishing `unpushed=0` AND `dirty=0` — a derived zero over a tree whose porcelain was never read.
rm -rf "$TMP/n29O"
( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=not-a-worktree; LANE_END_RESCUE=UNAVAILABLE
  LANE_END_UNPUSHED=0; LANE_END_PORCELAIN=""
  LANE_END_ROOT=/tmp/not-a-wt; LANE_END_LOG=/dev/null; LANE_END_MARKER_FRESH=1
  lane_end_marker n29 0 10' _ "$GATE" "$TMP/n29O" 2>/dev/null )
mk29="$TMP/n29O/state/lane-exit-n29.state"
[ -s "$mk29" ] && grep -qx 'state=not-a-worktree' "$mk29" && grep -qx 'unpushed=?' "$mk29" \
  && grep -qx 'dirty=?' "$mk29" && ! grep -qx 'dirty=0' "$mk29"; rcn29=$?
ck "N29 a NOT-A-WORKTREE terminal records unpushed=? AND dirty=? — both zeros were derived over an enumeration that never ran [$(grep -m1 '^dirty=' "$mk29" 2>/dev/null)]" $rcn29
# ⛔ N16 — THE CLONE-REF LEG OF THE LANDING CHECK (review cycle 4, gap 2), RE-BASED ON A STRONGER VERDICT
# (review cycle 9, P0). This arm used to require `refused-protected` — i.e. it required the clone's cached
# `origin/HEAD` to be TRUSTED as knowledge of the remote's default. That trust was the P0: a bare whose
# REAL default is `trunk` + a cache still saying `origin/main` + a silent `ls-remote --symref` made the exit
# path push `refs/heads/trunk` and record `push=pushed` (reproduced end-to-end). The cache is now honoured
# only as one MORE name to refuse on, so a silent remote refuses the WHOLE push as
# `refused-unknown-default` — strictly stronger than refusing one name, and this arm asserts the property
# that matters (the renamed default did NOT move) under the new verdict. N26 below drives the bypass case.
git -C "$WT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk 2>/dev/null
pi_stub unpushed_landing
: > "$O/logs/cloneref.log"
PATH="$TMP/bin-nosymref:$TMP/bin:$PATH" PI_LOG="$O/pi9.log" bash -c '
  . "$1"; cd "$2" || exit 2
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "clone ref leg" >>"$4.agent" 2>&1
' _ "$GATE" "$TMP/wt5" "$O" "$O/logs/cloneref.log" "$PROMPT"
arm "$O/logs/cloneref.log"
ck "N16 …with the remote silent, NOTHING is pushed and the renamed default does not move — the clone's stale cache is no longer trusted as an answer [$(tail -1 "$O/logs/cloneref.log" 2>/dev/null | cut -c1-90)]" \
  $(grep -q 'refused-unknown-default\|refused-protected' "$O/logs/cloneref.log" && ! git -C "$BARE" rev-parse -q --verify refs/heads/trunk >/dev/null 2>&1 && echo 0 || echo 1)
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
  LANE_END_LOG=/dev/null; LANE_END_ROOT=/x; LANE_END_BRANCH=b
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
# here, measured, and then refused one layer down by `bg-rescue-wip.sh:117-123` — the record said the
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
  O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
    O="$3"; MAX_LOAD=999999999; MEM_MIN_AVAIL_MB=1; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_SELF_MB=0; DISK_LANE_RESERVE_MB=0
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
# ⛔ AND THE COUNT IS NOT INVENTED EITHER (review cycle 8, P2): `LANE_END_UNPUSHED` is reset to `0` before
# the hatch can return, so this real-drive marker used to publish `unpushed=0` one line under
# `state=not-measured`. N24 proves the rule at the writer; this asserts it on the LIVE path a drive takes.
grep -qx 'unpushed=?' "$MK_OFF" 2>/dev/null && ! grep -qx 'unpushed=0' "$MK_OFF" 2>/dev/null; rcmk3=$?
ck "G10b …and it records unpushed=? rather than the reset-to-0 value nobody read [$(grep -m1 '^unpushed=' "$MK_OFF" 2>/dev/null)]" $rcmk3
git -C "$WT" config --unset-all url."$TMP/not-a-repo.git".insteadOf
git -C "$WT" config url."$BARE".insteadOf "$GHURL"

# ── I) A STALE refs/wip-local IS NOT THIS RUN'S ARCHIVE (review F1, round 3) ──────────────────────
# `refs/wip-local/<slug>` lives in the repo's COMMON git dir and is keyed by branch slug alone, so an
# EARLIER rescue of this branch leaves one behind. A run that archives NOTHING — an unwritable TMPDIR
# is the cheap reproduction of `bg-rescue-wip.sh:81`, the full-disk shape — must not be recorded as
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
# ⛔ `bg-rescue-wip.sh` writes `refs/wip-local/<slug>` under a GUARD (`:262-271` warns and carries on), and
# then exits 0 once the PUSH succeeds (`:468-480`). So `rc2=0` + no new local ref has TWO causes, and the
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
# ── N30–N32 — REVIEW CYCLE 11: THREE PLACES THAT CLAIMED MORE THAN THEY MEASURED ────────────────
# ⛔ N30 — AN UNANSWERED VERIFY IS NOT AN ABSENT REF (review cycle 11, P1 — REPRODUCED). The verifying
# `ls-remote --heads` is the TIGHTEST bound on the exit path (5 s) and it decides the same question the
# push just decided, so on a congested link a DELIVERED push was recorded `push=FAILED` together with
# "$unpushed commit(s) are STILL only on this disk". The arm makes the remote ANSWER for the push and
# says NOTHING for the verify — the exact split between "the ref is absent" and "nobody answered" — and
# asserts both halves: the branch really IS on origin (so `FAILED` would be a fabricated absence), and
# the artifact says UNVERIFIED rather than absent.
git -C "$WT" worktree add -q "$TMP/wt9" -b verifyun 2>/dev/null
git -C "$TMP/wt9" commit -q --allow-empty -m "unpushed for the verify-unanswered arm" 2>/dev/null
mkdir -p "$TMP/bin-nohdr"
{ printf '#!/bin/sh\ncase " $* " in *" ls-remote --heads "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-nohdr/git"
chmod +x "$TMP/bin-nohdr/git"
: > "$O/logs/unanswered.log"; rm -f "$O/state/lane-exit-unanswered.state"
PATH="$TMP/bin-nohdr:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=verifyun
  lane_end_push "unanswered" "$3" "$2" verifyun 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
  lane_end_next > "$4"
  LANE_END_LOG="$3"; LANE_END_MARKER_FRESH=1
  lane_end_marker "unanswered" 0 300
' _ "$GATE" "$TMP/wt9" "$O/logs/unanswered.log" "$TMP/n30.next" > "$TMP/n30.out" 2>&1
vhead="$(git -C "$TMP/wt9" rev-parse HEAD)"
# NON-VACUITY: the push DID reach origin, so "still only on this disk" is exactly the false sentence here.
git -C "$BARE" rev-parse -q --verify refs/heads/verifyun >/dev/null 2>&1 \
  && [ "$(git -C "$BARE" rev-parse refs/heads/verifyun 2>/dev/null)" = "$vhead" ]; rcn30a=$?
ck "N30a the fixture's push really DID land (origin/verifyun = $(git -C "$BARE" rev-parse --short refs/heads/verifyun 2>/dev/null), the lane's head) — so the verdict below is about the READ, not the push" $rcn30a
grep -qx 'push=verify-unanswered' "$TMP/n30.out"; rcn30b=$?
ck "N30b …and an UNANSWERED verifying read records push=verify-unanswered — never push=FAILED and never push=pushed (it measured NEITHER delivery nor loss)" $rcn30b
! grep -q 'push=FAILED' "$TMP/n30.out" && grep -q 'did not answer' "$O/logs/unanswered.log"; rcn30c=$?
ck "N30c …the log says the read did not answer, and nowhere claims the commits are 'STILL only on this disk'" $rcn30c
case "$(cat "$TMP/n30.next" 2>/dev/null)" in MANUAL*"did NOT establish"*) rcn30d=0 ;; *) rcn30d=1 ;; esac
ck "N30d …and next= is MANUAL / 'did NOT establish' — the worktree is still not reaped, but the artifact does not assert the absence it could not measure [$(cut -c1-60 "$TMP/n30.next" 2>/dev/null)]" $rcn30d
grep -qx 'push=verify-unanswered' "$O/state/lane-exit-unanswered.state" 2>/dev/null; rcn30e=$?
ck "N30e …and the MARKER carries the same verdict, so the artifact a reclaim pass reads agrees with the log" $rcn30e
# ⛔ N31 — THE `archived-local` REPORTER MAY NOT ASSERT AN ABSENCE THE PUSH DID NOT MEASURE (review cycle
# 11, P2 — REPRODUCED). It ended "…so the commits on <br> are not on origin either" WHATEVER the push did,
# so with `push=pushed` the artifact contradicted its own `push=pushed` / `branch_on_origin=<sha>`. Same
# class D4b closed in the lane LOG, left open in the artifact. Both fixed directions AND the untouched one
# are asserted, so this cannot regress into either silence or over-claim.
al_pushed="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=pushed
  LANE_END_REF=refs/wip-local/develop; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  LANE_END_ORIGIN=deadbeefcafe
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$al_pushed" in *"not on origin either"*) rcn31a=1 ;; *deadbeefcafe*) rcn31a=0 ;; *) rcn31a=1 ;; esac
ck "N31a archived-local + push=pushed does NOT say the branch is missing from origin — it names the sha the remote reported [${al_pushed:0:70}]" $rcn31a
al_nothing="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=nothing
  LANE_END_REF=refs/wip-local/develop; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$al_nothing" in *"not on origin either"*) rcn31b=1 ;; *'unpushed=0'*) rcn31b=0 ;; *) rcn31b=1 ;; esac
ck "N31b …nor with push=nothing, where every commit on the head is already on a remote ref (unpushed=0) [${al_nothing:0:70}]" $rcn31b
# ⛔ N31c — PIN THE LANDING PLACE OF A FUTURE VERDICT (review cycle 14, P2). `archived-local` is assigned only
# AFTER `lane_end_push` has run, so `LANE_END_PUSH` is always one of the declared values here and the old
# fallback was DEAD — yet it said "the commits on <br> are not on origin either", i.e. the exact absence
# cycle 11 removed, waiting for the first value nobody classified. This arm therefore drives a value that is
# deliberately OUTSIDE the declared domain and asserts the ABSTENTION, not an absence claim: that is the
# behaviour a future verdict inherits.
al_other="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=not-attempted
  LANE_END_REF=refs/wip-local/develop; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$al_other" in *"not on origin either"*) rcn31c=1 ;; *"asserts neither delivery nor absence"*) rcn31c=0 ;; *) rcn31c=1 ;; esac
ck "N31c …while an UNCLASSIFIED push value makes the reporter ABSTAIN rather than assert an absence — the branch a future verdict lands on [${al_other:0:60}]" $rcn31c
# ⛔ N32 — THE CLEAN VERDICT CARRIES ITS OWN SCOPE (review cycle 11, P2). `clean` is measured over the paths
# git does NOT ignore, and that caveat lived only in the lane LOG — which this file itself calls secondary.
# A lane whose only copy of its work is an ignored file read `state=clean` and was handed an affirmative
# "may be removed" with no scope attached.
sc="$( bash -c '
  . "$1"
  LANE_END_TREE=clean; LANE_END_RESCUE=nothing; LANE_END_PUSH=pushed
  LANE_END_UNPUSHED=0; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$sc" in *'does NOT ignore'*) rcn32a=0 ;; *) rcn32a=1 ;; esac
ck "N32a the clean \"may be removed\" verdict names what it measured (the paths git does NOT ignore), so the artifact cannot state more safety than the enumeration covered" $rcn32a
case "$sc" in *"may be removed once its PR is terminal"*) rcn32b=0 ;; *) rcn32b=1 ;; esac
ck "N32b …and it is still an affirmative verdict where that is warranted — the scope was added, not the removal replaced by an abstention" $rcn32b
# ⛔ N32c — THE LAST ARM MAY NOT BE A FALL-THROUGH EITHER (review of PR #3399, P2 — REPRODUCED). `lane_end_next`
# ENDS on this arm, so it is where every value nobody classified lands — and it handed them "nothing at risk …
# may be removed" without consulting `LANE_END_PUSH` at all, the exact shape both arms above it abstain for.
# Driving the shipped function with an EMPTY push value printed the affirmative sentence. Every reachable
# value has an arm today, so this is latent — but a latent arm is precisely the one a FUTURE verdict lands
# on, and what it would land on here is a removal licence.
sc_u="$( bash -c '
  . "$1"
  LANE_END_TREE=clean; LANE_END_RESCUE=nothing; LANE_END_PUSH=
  LANE_END_UNPUSHED=0; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$sc_u" in MANUAL*'does NOT classify'*) rcn32c=0 ;; *) rcn32c=1 ;; esac
ck "N32c …but an UNCLASSIFIED push value (here: the pre-push EMPTY one) makes the SAME clean tree ABSTAIN — a removal licence is never a fall-through [${sc_u:0:60}]" $rcn32c
# ⛔ N32e — THE SAME ARGUMENT IN THE **OTHER** DIMENSION (review of PR #3399 round 11, P2 — REPRODUCED).
# N32c stopped the tail consulting a default for `push`, but it kept interpolating `${LANE_END_TREE:-clean}`,
# so a FUTURE tree verdict reaching the tail with a safe push value was PUBLISHED as `tree=clean` together
# with "may be removed". Measured on the pre-fix function: `LANE_END_TREE=submodule-dirty push=pushed`
# printed "nothing at risk (tree=submodule-dirty …): … may be removed", while the same tree value with an
# EMPTY push abstained — i.e. the fence existed for one dimension and not the one beside it. The value used
# here (`submodule-dirty`) is deliberately OUTSIDE the six declared tree values, the same way N31c uses
# `not-attempted`: it is the only reachable expression of the branch a FUTURE verdict lands on, so do not
# "fix" it to a declared value, which would make the arm vacuous.
sc_t="$( bash -c '
  . "$1"
  LANE_END_TREE=submodule-dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=pushed
  LANE_END_UNPUSHED=0; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$sc_t" in MANUAL*'does NOT classify the tree value'*) rcn32e=0 ;; *) rcn32e=1 ;; esac
ck "N32e …and an UNCLASSIFIED **tree** value abstains too, even with a safe push — the removal licence is not a fall-through in either dimension [${sc_t:0:70}]" $rcn32e
case "$sc_t" in *'may be removed'*) rcn32e2=1 ;; *) rcn32e2=0 ;; esac
ck "N32e2 …and it does NOT carry the affirmative 'may be removed' sentence over a tree nobody classified" $rcn32e2
# …and the two declared-safe values are unchanged, so the fence above cannot be passing by refusing EVERYTHING.
sc_ok="$( bash -c '
  . "$1"
  LANE_END_TREE=clean; LANE_END_RESCUE=nothing; LANE_END_PUSH=pushed
  LANE_END_UNPUSHED=0; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$sc_ok" in 'nothing at risk'*'tree=clean'*'may be removed'*) rcn32e3=0 ;; *) rcn32e3=1 ;; esac
ck "N32e3 …while tree=clean with push=pushed still gets the affirmative reclaim sentence (the fence is a fence, not a blanket refusal) [${sc_ok:0:50}]" $rcn32e3
# ⛔ N32d — `unpushed=0` IS A MEASUREMENT ABOUT THE LOCAL TRACKING REFS, NOT ABOUT THE REMOTE (review of
# PR #3399, P1 — REPRODUCED). The sentence claimed "every commit on <b> is already on a remote ref", an
# OFF-BOX fact this path never measured: the count is `git rev-list --count HEAD --not --remotes`, i.e.
# `refs/remotes/*` — a CACHE that `git fetch --prune` revokes and that a deleted remote branch leaves stale
# forever. `scripts/pi-reap-worktrees.sh` (#3041) already refuses exactly this inference (`remote-only-ref`
# exists for it; only a bounded `ls-remote --heads` upgrades a row to `remote-holds:`). Pinned from both
# sides: the claim must be scoped to the cache, and the unscoped wording must not come back.
n32d="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=nothing
  LANE_END_REF=refs/wip-local/develop; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n32d" in *'a CACHE'*) rcn32d=0 ;; *) rcn32d=1 ;; esac
ck "N32d push=nothing names the LOCAL tracking refs it read and calls them a CACHE — it does not claim the remote holds the commits [${n32d:0:90}]" $rcn32d
case "$n32d" in *'already on a remote ref'*) rcn32d2=1 ;; *) rcn32d2=0 ;; esac
ck "N32d2 …and the unscoped off-box claim ('already on a remote ref') is gone, so the sentence cannot state more safety than the enumeration covered" $rcn32d2
# ⛔ N27c — A REPORTER MAY NOT SIT ABOVE A MANUAL ARM, AND THE ARCHIVE IS NO EXCEPTION (review cycle 12,
# P1 — REPRODUCED). `refused-protected|refused-main-checkout` used to live BELOW the `archived-local`
# reporter, so a DIRTY tree with a refused push and a LOCAL-ONLY archive — the fleet's worst reachable state
# (the documented `fix-one.sh` no-`WIP_PATH` case on the hub's landing branch, plus a full disk where only
# the local pin could be written: nothing off-box at all) — got the reporter's generic sentence, with no
# `MANUAL` and no `do NOT reap`. Measured before the fix:
#   next=retrieve the archive refs/wip-local/develop … the branch push is push=refused-main-checkout, so the
#         commits on develop are not on origin either
# i.e. the reclaim pass this artifact exists for took the worktree and lost both halves.
nx27c="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=refused-main-checkout
  LANE_END_REF=refs/wip-local/develop; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx27c" in MANUAL*) rcn27c=0 ;; *) rcn27c=1 ;; esac
case "$nx27c" in *"do NOT reap"*) : ;; *) rcn27c=1 ;; esac
case "$nx27c" in *"refs/wip-local/develop"*) : ;; *) rcn27c=1 ;; esac
# ⛔ AND IT MUST SAY THE PIN IS NOT ESTABLISHED TO BE THE ONLY COPY (review cycle 16, P2 — REPRODUCED).
# This arm is the one written FOR the fleet's worst state, and it named the raw `rescue=` value while
# omitting the fact that makes the state worst — so a reclaimer on a cell was told to "recover … from the
# rescue ref", a pin that dies with the volume. N27c/N27d asserted only `MANUAL*` and could not see it.
# ⛔ THE OMISSION IS NOW STATED AS AN ABSENCE OF EVIDENCE, NOT AS AN ABSENCE OF A COPY (P1 — REPRODUCED).
# `archived-local` is `rc2 != 0` AND a ref this run wrote; `bg-rescue-wip.sh` exits 2 for a PARTIAL archive
# whose push SUCCEEDED as well as for a failed push, so the pin CAN coexist with an off-box archive at
# `refs/wip/<slug>`. Measured: a worktree holding an unborn nested repo (SKIPPED ⇒ PARTIAL) plus a real
# push left `refs/wip/wtlane` ON ORIGIN while the terminal printed "archived to the LOCAL pin … only (no
# off-box copy)". So the unprovable claim is asserted AGAINST here, and the honest sentence FOR.
case "$nx27c" in *"no off-box copy"*) rcn27c=1 ;; *) : ;; esac
case "$nx27c" in *"does NOT establish that the pin is the only copy"*) : ;; *) rcn27c=1 ;; esac
case "$nx27c" in *"check it there"*) : ;; *) rcn27c=1 ;; esac
ck "N27c a REFUSED push over a LOCAL-ONLY archive is MANUAL / do-not-reap, still names the pin, and says the pin is NOT established to be the only copy (a PARTIAL archive that PUSHED reaches this arm too) [${nx27c:0:72}]" $rcn27c
nx27d="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_PUSH=refused-protected
  LANE_END_REF=refs/wip-local/develop; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx27d" in MANUAL*"do NOT reap"*"does NOT establish that the pin is the only copy"*) rcn27d=0 ;; *) rcn27d=1 ;; esac
ck "N27d …the same holds for refused-protected, including the not-established-as-only-copy fact (the pair is one arm, so it is asserted as one)" $rcn27d
# ⛔ N33 — A TIMED-OUT PUSH IS NOT A MEASURED ABSENCE EITHER (review cycle 12, P2). `rc=124` means the
# TIMER KILLED THE CLIENT — the ref may already have been applied server-side — yet the log said "STILL only
# on this disk", contradicting itself in one breath ("the remote never answered") and breaking this file's
# own definition of `FAILED` (the remote ANSWERED and the ref is absent), while next= printed "exist only on
# this disk" as measured fact. A shim that exits 124 is a faithful driver: the code branches on the NUMBER,
# and the number is the contract the timer has with every caller.
mkdir -p "$TMP/bin-124"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 124 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-124/git"
chmod +x "$TMP/bin-124/git"
git -C "$WT" worktree add -q "$TMP/wt10" -b timedout 2>/dev/null
git -C "$TMP/wt10" commit -q --allow-empty -m "unpushed for the push-timeout arm" 2>/dev/null
: > "$O/logs/timedout.log"; rm -f "$O/state/lane-exit-timedout.state"
PATH="$TMP/bin-124:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=timedout
  lane_end_push "timedout" "$3" "$2" timedout 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
  lane_end_next > "$4"
  LANE_END_LOG="$3"; LANE_END_MARKER_FRESH=1
  lane_end_marker "timedout" 0 300
' _ "$GATE" "$TMP/wt10" "$O/logs/timedout.log" "$TMP/n33.next" > "$TMP/n33.out" 2>&1
grep -qx 'push=push-killed' "$TMP/n33.out"; rcn33a=$?
ck "N33a a push whose TIMER fired (rc=124) records push=push-killed — a distinct verdict from push=FAILED (the remote ANSWERED and the ref is absent), and a name that asserts only what was MEASURED" $rcn33a
! grep -q 'STILL only on this disk' "$O/logs/timedout.log" && grep -q 'timer fired at its bound' "$O/logs/timedout.log" \
  && grep -q 'did NOT establish' "$O/logs/timedout.log"; rcn33b=$?
ck "N33b …and the log says the delivery was NOT established, never the self-contradicting 'never answered … STILL only on this disk'" $rcn33b
# ⛔ N33g — THE LOG MAY NOT NAME A CAUSE THE CODE CANNOT ESTABLISH (review cycle 14, P2 — REPRODUCED). `137`
# is not the timer's signature: `timeout 1 sh -c 'kill -9 $$'` returns it THROUGH GNU timeout with the timer
# never firing, and an OOM killer on a full disk produces it with no timer at all. So the 137 sentence must
# not claim the 15s bound fired, while the 124 sentence must say the timer did — same verdict, different
# prose, because that is the only part the exit path can actually know.
! grep -q 'TIMED OUT after 15s' "$O/logs/timedout.log" && grep -q 'timer fired at its bound' "$O/logs/timedout.log"; rcn33g=$?
ck "N33g the rc=124 sentence no longer speaks in a fixed 'TIMED OUT after 15s' voice — it names the timer as what fired [$(grep -o 'timer fired at its bound' "$O/logs/timedout.log" | head -1)]" $rcn33g
case "$(cat "$TMP/n33.next" 2>/dev/null)" in MANUAL*"did NOT establish"*) rcn33c=0 ;; *) rcn33c=1 ;; esac
ck "N33c …and next= is MANUAL / 'did NOT establish' — not reaped, and not told to stop reaping for a loss nobody measured [$(cut -c1-58 "$TMP/n33.next" 2>/dev/null)]" $rcn33c
grep -qx 'push=push-killed' "$O/state/lane-exit-timedout.state" 2>/dev/null; rcn33d=$?
ck "N33d …and the MARKER carries the same verdict, so artifact and log agree" $rcn33d
# ⛔ N34 — THE LEDGER COLUMN AND THE MARKER ARE ONE DERIVATION (review cycle 12, P2 — REPRODUCED). The TSV
# wrote the raw `${LANE_END_UNPUSHED:-0}`, and `terminal_wip_rescue` resets that global to 0 BEFORE both
# early returns, so `WIP_RESCUE_DISABLE=1` and `not-a-worktree` published a MEASURED ZERO in the aggregate
# row while the marker beside them said `unpushed=?` — the exact lie the marker's own comment claims to
# prevent, still live in the ledger the README describes as the table consumers read.
rm -rf "$TMP/n34O"
( bash -c '
  . "$1"
  O="$2"; WIP_RESCUE_DISABLE=1; LANE_END_LOG=/dev/null
  terminal_wip_rescue n34 0 10 /dev/null' _ "$GATE" "$TMP/n34O" 2>/dev/null )
tsv34="$TMP/n34O/state/lane-end.tsv"
mk34="$TMP/n34O/state/lane-exit-n34.state"
[ -s "$tsv34" ] && [ "$(awk -F'\t' 'NR==1{print $5}' "$tsv34")" = "not-measured" ] \
  && [ "$(awk -F'\t' 'NR==1{print $8}' "$tsv34")" = "?" ]; rcn34a=$?
ck "N34a the HATCH row's ledger column 8 is '?' — the same '?' the marker publishes, not the reset's 0 [$(awk -F'\t' 'NR==1{print "state="$5" unpushed="$8}' "$tsv34" 2>/dev/null)]" $rcn34a
[ -s "$mk34" ] && grep -qx 'unpushed=?' "$mk34"; rcn34b=$?
ck "N34b …and the marker on the SAME terminal says the same thing — one derivation, two writers" $rcn34b
rm -rf "$TMP/n34bO"
mkdir -p "$TMP/definitely-not-a-repo"
( bash -c '
  . "$1"
  O="$2"; WIP_PATH="$3"; LANE_END_LOG=/dev/null
  terminal_wip_rescue n34b 0 10 /dev/null' _ "$GATE" "$TMP/n34bO" "$TMP/definitely-not-a-repo" 2>/dev/null )
tsv34b="$TMP/n34bO/state/lane-end.tsv"
[ -s "$tsv34b" ] && [ "$(awk -F'\t' 'NR==1{print $5}' "$tsv34b")" = "not-a-worktree" ] \
  && [ "$(awk -F'\t' 'NR==1{print $8}' "$tsv34b")" = "?" ]; rcn34c=$?
ck "N34c …and the same holds on the OTHER unmeasured early return (not-a-worktree), so the fix is the derivation and not one arm [$(awk -F'\t' 'NR==1{print "state="$5" unpushed="$8}' "$tsv34b" 2>/dev/null)]" $rcn34c
rm -rf "$TMP/definitely-not-a-repo"
# ⛔ N34d NON-VACUITY: a MEASURED zero still publishes `0` — the derivation must not turn every row into `?`.
rm -rf "$TMP/n34cO"
( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=clean; LANE_END_RESCUE=nothing; LANE_END_UNPUSHED=0
  LANE_END_LOG=/dev/null; LANE_END_MARKER_FRESH=1
  lane_end_record n34c 0 10' _ "$GATE" "$TMP/n34cO" 2>/dev/null )
tsv34c="$TMP/n34cO/state/lane-end.tsv"
[ -s "$tsv34c" ] && [ "$(awk -F'\t' 'NR==1{print $8}' "$tsv34c")" = "0" ]; rcn34d=$?
ck "N34d …while a MEASURED zero still publishes 0 — the column gained a distinction, not a blanket '?'" $rcn34d
# ⛔ N33e — THE RC CLASS, NOT ONE INTEGER (review cycle 13, P2 — REPRODUCED). Keying the timed-out push on
# `124` alone missed the fleet's INTERNAL watchdog: `tb_bound_tmp` degrades to "no sentinel" when its scratch
# dir cannot be made (the full-disk state this PR exists for) and `tb_timeout` then returns the SIGKILLed
# child's status. Measured on the shipped lib: `TMPDIR=/nonexistent TB_TIMEOUT_FORCE_INTERNAL=1 tb_timeout 1
# sleep 5` → **137**, not 124. A SIGKILLed client is a fortiori "did NOT establish", so the verdict must be
# the same class. The shim branches on the NUMBER because the number is the timer's contract with the caller.
mkdir -p "$TMP/bin-137"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 137 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-137/git"
chmod +x "$TMP/bin-137/git"
git -C "$WT" worktree add -q "$TMP/wt11" -b killed 2>/dev/null
git -C "$TMP/wt11" commit -q --allow-empty -m "unpushed for the push-SIGKILL arm" 2>/dev/null
: > "$O/logs/killed.log"; rm -f "$O/state/lane-exit-killed.state"
PATH="$TMP/bin-137:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=killed
  lane_end_push "killed" "$3" "$2" killed 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$TMP/wt11" "$O/logs/killed.log" > "$TMP/n33e.out" 2>&1
grep -qx 'push=push-killed' "$TMP/n33e.out"; rcn33e=$?
ck "N33e a push the INTERNAL watchdog SIGKILLed (rc=137, no sentinel — the full-disk shape) also records push=push-killed, not FAILED" $rcn33e
! grep -q 'STILL only on this disk' "$O/logs/killed.log" && grep -q 'did NOT establish' "$O/logs/killed.log" \
  && grep -q 'SIGKILLed' "$O/logs/killed.log" && ! grep -q 'fired at its bound' "$O/logs/killed.log"; rcn33f=$?
ck "N33f …and its log asserts neither delivery nor loss, and does NOT claim the 15s bound fired — which signal sent it is not measurable from here" $rcn33f
# ⛔ N27e — THE ONE MANUAL ARM THAT DID NOT UNION THE OTHER DOMAIN (review cycle 13, P2 — REPRODUCED).
# `rescue=FAILED` printed "uncommitted work is NOT archived … re-run bg-rescue-wip.sh" and returned BEFORE the
# refused-push arms, so `push=refused-main-checkout` — the documented `fix-one.sh` no-`WIP_PATH` hub case —
# was silently dropped, and the offered remedy cannot push a branch. The same rescue fact beside `push=FAILED`
# does name both, so the arm order alone violated the file's own rule.
nx27e="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=FAILED; LANE_END_PUSH=refused-main-checkout
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx27e" in MANUAL*"do NOT reap"*) rcn27e=0 ;; *) rcn27e=1 ;; esac
# the flat claim is gone; the scoped one is what this arm may say (see N23b for why).
case "$nx27e" in *"is NOT archived"*) rcn27e=1 ;; *) : ;; esac
case "$nx27e" in *"no ref this run wrote pins the uncommitted work"*) : ;; *) rcn27e=1 ;; esac
# ⛔ THE SECOND CLAUSE USED TO PIN `*"NOT on origin"*` — the very claim round 13 correctly REMOVED (review
# of PR #3399 round 13, P2). Leaving it here would have made this arm a tombstone that forces the off-box
# absence back in. N27e's actual subject is the UNION (both domains named), so it asserts the push verdict
# is present by name and that the branch cannot be fixed by re-running the rescue — never the wording of
# a claim nobody measured.
case "$nx27e" in *"refused-main-checkout"*) : ;; *) rcn27e=1 ;; esac
case "$nx27e" in *"re-running the rescue does NOT fix"*) : ;; *) rcn27e=1 ;; esac
ck "N27e a FAILED archive beside a REFUSED push names BOTH facts and says the rescue cannot fix the branch [${nx27e:0:64}]" $rcn27e
# ⛔ N28c/N28d — A MANUAL VERDICT MAY NOT SIT BELOW A REPORTER, AND `cannot-verify` IS ONE (review cycle 13,
# P1 — REPRODUCED). `cannot-verify` lived inside the `dirty|cannot-verify` block, so `rescue=archived-local`
# and `rescue=refs/wip/*` both returned first: the lane LOG said the listing was INCOMPLETE and "do not reap
# this worktree on the strength of this row" while the ARTIFACT said "retrieve the archive … before removing
# it" — the same run refusing and licensing a reclaim. N28 could not see it: N28 drives `rescue=nothing`,
# the one value where that arm was reachable.
nx28c="$( bash -c '
  . "$1"
  LANE_END_TREE=cannot-verify; LANE_END_RESCUE=archived-local
  LANE_END_REF=refs/wip-local/cvdemo; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx28c" in MANUAL*) rcn28c=0 ;; *) rcn28c=1 ;; esac
case "$nx28c" in *"NOT reap"*) : ;; *) rcn28c=1 ;; esac
case "$nx28c" in *"refs/wip-local/cvdemo"*) : ;; *) rcn28c=1 ;; esac
ck "N28c cannot-verify over a LOCAL-ONLY archive is MANUAL / do-not-reap and still names the pin — the reporter no longer runs above it [${nx28c:0:60}]" $rcn28c
nx28d="$( bash -c '
  . "$1"
  LANE_END_TREE=cannot-verify; LANE_END_RESCUE=refs/wip/cvdemo; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$nx28d" in MANUAL*"NOT reap"*"refs/wip/cvdemo"*) rcn28d=0 ;; *) rcn28d=1 ;; esac
ck "N28d …nor is the OFF-BOX archive exempt — the incomplete listing means even that cannot certify the tree, and the ref is still named [${nx28d:0:60}]" $rcn28d
# ⛔ N35 — `unpushed` HAS ITS OWN ENUMERATION AND MUST SURVIVE `cannot-verify` (review cycle 13, P2 —
# REPRODUCED). `dirty` rides on the porcelain listing (untrusted here), but `unpushed` comes from `rev-list`
# and is only `?` when THAT failed (:1893). Publishing `?` over a measured count is the inverse of the defect
# cycle 12 fixed — "never measured" claimed about a number that was measured — and it left the ledger less
# informative than the same terminal's own lane log.
rm -rf "$TMP/n35O"
( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=cannot-verify; LANE_END_RESCUE=nothing; LANE_END_UNPUSHED=1
  LANE_END_PORCELAIN=""; LANE_END_LOG=/dev/null; LANE_END_MARKER_FRESH=1
  lane_end_record n35 0 10' _ "$GATE" "$TMP/n35O" 2>/dev/null )
tsv35="$TMP/n35O/state/lane-end.tsv"; mk35="$TMP/n35O/state/lane-exit-n35.state"
[ -s "$tsv35" ] && [ "$(awk -F'\t' 'NR==1{print $8}' "$tsv35")" = "1" ] \
  && grep -qx 'unpushed=1' "$mk35"; rcn35a=$?
ck "N35a a cannot-verify row keeps the unpushed count it DID measure — and the marker agrees, one derivation [$(awk -F'\t' 'NR==1{print "col8="$8}' "$tsv35" 2>/dev/null)]" $rcn35a
grep -qx 'dirty=?' "$mk35"; rcn35b=$?
ck "N35b …while dirty on that same row IS '?', because that field does ride the untrusted listing" $rcn35b
rm -rf "$TMP/n35bO"
( bash -c '
  . "$1"
  O="$2"; LANE_END_TREE=cannot-verify; LANE_END_RESCUE=nothing; LANE_END_UNPUSHED="?"
  LANE_END_PORCELAIN=""; LANE_END_LOG=/dev/null; LANE_END_MARKER_FRESH=1
  lane_end_record n35b 0 10' _ "$GATE" "$TMP/n35bO" 2>/dev/null )
awk -F'\t' 'NR==1{exit !($8=="?")}' "$TMP/n35bO/state/lane-end.tsv"; rcn35c=$?
ck "N35c …and a genuinely UNMEASURED count on a cannot-verify row still publishes '?' — the fix keys on the count, not the tree" $rcn35c
# ⛔ N28e — THE HOISTED cannot-verify SENTENCE MAY NOT CONTRADICT ITSELF EITHER (review cycle 14, P2 —
# REPRODUCED). It carried a HARD-CODED "`rescue=nothing` means the rescue did not certify it" beside an
# INTERPOLATED `rescue=%s`, so with `rescue=refs/wip/develop` one line said both "rescue=refs/wip/develop"
# and "rescue=nothing" — telling the reader NO archive exists while naming one. N28c/N28d assert MANUAL,
# do-not-reap and that the ref appears; neither asserts the rescue value the sentence claims, so the
# contradiction was invisible to them. This arm pins the absence of the literal.
al_cv="$( bash -c '
  . "$1"
  LANE_END_TREE=cannot-verify; LANE_END_RESCUE=archived-local
  LANE_END_REF=refs/wip-local/cvdemo; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$al_cv" in *'`rescue=nothing`'*) rcn28e=1 ;; *'rescue=archived-local'*) rcn28e=0 ;; *) rcn28e=1 ;; esac
ck "N28e …and the sentence names the rescue value it actually holds — the hard-coded 'rescue=nothing' clause is gone [${al_cv:0:64}]" $rcn28e
# ⛔ N36 — `push=running` IS NOT A MEASURED LOSS (review cycle 14, P2 — REPRODUCED). The pre-network marker
# sets it BEFORE the push step, so it is what survives a kill in that window — and it was folded into the
# MANUAL push case whose sentence says the commits "exist only on this disk", printed beside `unpushed=0`:
# a loss claim contradicted by the same artifact's own count.
n36="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=""; LANE_END_PUSH=running; LANE_END_UNPUSHED=0
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n36" in MANUAL*"unpushed=0"*"did NOT establish"*) rcn36a=0 ;; *) rcn36a=1 ;; esac
ck "N36a a pre-network marker (push=running, unpushed=0) is MANUAL and asserts NEITHER delivery NOR loss — it does not claim the commits exist only on this disk [$n36]" $rcn36a
case "$n36" in *'exist only on this disk'*) rcn36b=1 ;; *) rcn36b=0 ;; esac
ck "N36b …and specifically never carries the unmeasured-loss sentence, which the same row's own unpushed=0 contradicts" $rcn36b
# ⛔ N37 — `not-a-worktree` HAD NO ARM AND INHERITED THE RESCUE ARM (review cycle 14, P2 — REPRODUCED). The
# rescue sentence asserts uncommitted work EXISTS at the root and prescribes re-running a rescuer that never
# ran. The cause is the CALLER's pointer, and the remedy it now names is the one that works.
n37="$( bash -c '
  . "$1"
  LANE_END_TREE=not-a-worktree; LANE_END_RESCUE=UNAVAILABLE
  LANE_END_UNPUSHED="?"; LANE_END_ROOT=/tmp/not-a-wt
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n37" in MANUAL*) rcn37a=0 ;; *) rcn37a=1 ;; esac
case "$n37" in *"WIP_PATH"*) : ;; *) rcn37a=1 ;; esac
case "$n37" in *"NOT archived"*) rcn37a=1 ;; *) : ;; esac
ck "N37a not-a-worktree is MANUAL, names the CALLER's remedy (WIP_PATH) and does not assert work that was never examined [${n37:0:64}]" $rcn37a
# ⛔ N37b — UNAVAILABLE IS NOT FAILED (review cycle 14, P2). A rescuer that was NOT FOUND cannot be "re-run",
# and the log for that same terminal already names the homes that were searched. README requires the two be
# told apart; the artifact said "re-run bg-rescue-wip.sh" for both.
n37b="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=UNAVAILABLE; LANE_END_PUSH=pushed; LANE_END_UNPUSHED=0
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n37b" in *"rescue TOOL itself was not found"*) rcn37b=0 ;; *) rcn37b=1 ;; esac
case "$n37b" in *"re-run bg-rescue-wip.sh"*) rcn37b=1 ;; *) : ;; esac
ck "N37b …and rescue=UNAVAILABLE says the TOOL was not found, never 're-run bg-rescue-wip.sh' (which cannot be run) [${n37b:0:64}]" $rcn37b
# ⛔ POSITIVE, NOT A STALE-PHRASE HUNT (review cycle 16, P2 — REPRODUCED). The first cut asserted only that
# "homes that were tried" was ABSENT, so it passed on a line that named NO reason at all — a mutation that
# deleted the whole reason list stayed green. A negative assertion about one phrase is not the property the
# label claims; this one fails if the reason list is removed.
case "$n37" in *"not inside a repository at all"*|*"not its root"*|*"unreadable"*) rcn37c=0 ;; *) rcn37c=1 ;; esac
ck "N37c …and it names the REASON it could not be examined (positively — deleting the reason list turns THIS red, where a stale-phrase hunt stayed green)" $rcn37c
# ⛔ N38 — `push=unmeasured` IS NOT A MEASURED ABSENCE (review cycle 15, P2 — REPRODUCED). It means the
# `rev-list --count` FAILED, and it sat in the "exist only on this disk" arm — asserting existence from the
# enumeration that failed, beside its own `unpushed=?`, while the LOG for the same terminal abstains. A
# promisor/partial clone fails `rev-list --count` while `status` still reads the worktree, so this is
# reachable, not theoretical.
n38="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=unmeasured; LANE_END_UNPUSHED="?"
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n38" in MANUAL*"could NOT be read"*"does NOT know"*) rcn38a=0 ;; *) rcn38a=1 ;; esac
case "$n38" in *'exist only on this disk'*) rcn38a=1 ;; *) : ;; esac
ck "N38a push=unmeasured is MANUAL and says the count could NOT be read — it does not assert the commits exist only on this disk from the enumeration that failed [${n38:0:60}]" $rcn38a
# ⛔ N39 — THE DURABLE `push-killed` SENTENCE MAY NOT NAME A CAUSE EITHER (review cycle 15, P2 —
# REPRODUCED). Cycle 14 made the LOG rc-specific and left `next=` saying "the push at the exit path TIMED
# OUT", which `137` does not establish — `timeout 1 sh -c 'kill -9 $$'` returns 137 with the timer never
# firing, and an OOM kill looks identical. The README declares this fixed; the artifact is what a consumer
# reads, and N33c's pattern (MANUAL*"did NOT establish"*) was satisfied by the old sentence too.
n39="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=push-killed
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n39" in MANUAL*"CLIENT WAS KILLED"*"did NOT establish"*) rcn39=0 ;; *) rcn39=1 ;; esac
case "$n39" in *"TIMED OUT"*) rcn39=1 ;; *) : ;; esac
ck "N39a …and the push-killed next= is CAUSE-NEUTRAL — it says the client was killed and names no cause, because 137 does not establish one [${n39:0:60}]" $rcn39
# ⛔ N40 — `cannot-verify` IS A MANUAL FACT OF ITS OWN (review cycle 15, P2 — REPRODUCED). It says the
# listing was not PROVEN complete, so unseen paths are in neither the porcelain section nor any archive —
# a fact no other field of next= carries — and every MANUAL push arm and both MANUAL rescue arms dropped it
# because the tree arm sits BELOW them. Four cycles in a row found a new arm breaking the file's own
# "a MANUAL arm may not silence another domain's MANUAL fact" rule; the caveat is now expressed ONCE.
for n40v in "dirty nothing FAILED" "dirty FAILED pushed" "dirty UNAVAILABLE pushed" "dirty archived-local running"; do
  set -- $n40v
  n40="$( bash -c '
    . "$1"
    LANE_END_TREE=cannot-verify; LANE_END_RESCUE="$2"; LANE_END_PUSH="$3"
    LANE_END_REF=refs/wip-local/x; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
    lane_end_next' _ "$GATE" "$2" "$3" 2>/dev/null )"
  case "$n40" in *"NOT PROVEN complete"*) rcn40=0 ;; *) rcn40=1 ;; esac
  ck "N40 cannot-verify's MANUAL fact survives a MANUAL push/rescue verdict (rescue=$2 push=$3) — no arm may silence another domain's MANUAL fact [${n40:0:58}]" $rcn40
done
# ⛔ N41 — THE DEAD `unpushed-only` ELSE MUST ABSTAIN (review cycle 15, P2 — REPRODUCED). `unpushed-only`
# requires a READABLE count and every non-`pushed` value is consumed by an arm above, so this branch fires
# only for a push value no path produces — and it still said "not on origin" with an invented
# `${LANE_END_PUSH:-not-attempted}`. Same dead-branch shape R5 was raised for one arm up.
n41="$( bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing; LANE_END_PUSH=""
  LANE_END_UNPUSHED=2; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n41" in *"not on origin"*) rcn41=1 ;; *"asserts neither delivery nor absence"*) rcn41=0 ;; *) rcn41=1 ;; esac
ck "N41 the dead unpushed-only else ABSTAINS instead of inventing a verdict and an absence [${n41:0:58}]" $rcn41
# ⛔ N42 — `FAILED` MAY NOT ASSERT THE STRONGEST ABSENCE (review cycle 16, P2 — REPRODUCED). It is assigned
# from a measurement where the remote ANSWERED holding a DIFFERENT sha — and the same artifact prints
# `branch_on_origin=<sha>`, so "exist only on this disk" contradicted the line above it; when that sha was a
# DESCENDANT (a peer push or a rail merge of our commits) the absence was simply false.
n42="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=FAILED
  LANE_END_ORIGIN=deadbeefcafe; LANE_END_HEAD=1234567abcd
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n42" in *"exist only on this disk"*) rcn42a=1 ;; *"deadbeefcafe"*) rcn42a=0 ;; *) rcn42a=1 ;; esac
ck "N42a a FAILED whose origin reported a DIFFERENT sha names that sha and does not claim the commits exist only on this disk [${n42:0:62}]" $rcn42a
n42b="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=FAILED
  LANE_END_ORIGIN=""; LANE_END_HEAD=1234567abcd
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n42b" in *"does NOT hold refs/heads/develop"*"do NOT reap"*) rcn42b=0 ;; *) rcn42b=1 ;; esac
ck "N42b …while the arm that DID establish an absent ref says exactly that, and still refuses a reclaim" $rcn42b
# ⛔ N43 — A NON-ZERO PUSH IS VERIFIED, NOT TRUSTED (review cycle 16, P2 — REPRODUCED, and an R2 violation).
# The rc≠0 path assigned FAILED and said "STILL only on this disk" without reading the remote — the one
# thing R2 forbids. A non-zero exit covers a rejected ref, a transport failure, a hook, and a server that
# APPLIED the ref and then failed to report; only the first establishes absence.
mkdir -p "$TMP/bin-rej"
# push exits 1 (a rejection) and the VERIFY read is the REAL git, so the remote can answer.
# \u26d4 THE SHIM MUST NOT BREAK THE SYMREF READ: `lane_end_push` reads `ls-remote --symref origin HEAD`
# BEFORE the push to decide the protected set, and a shim that fails every `ls-remote` makes the whole arm
# `refused-unknown-default` — which is why the first cut of this arm never reached the code it tests.
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-rej/git"
chmod +x "$TMP/bin-rej/git"
git -C "$WT" worktree add -q "$TMP/wt12" -b rejbase 2>/dev/null
git -C "$TMP/wt12" commit -q --allow-empty -m "base of rejbase"
git -C "$TMP/wt12" push -q origin HEAD:refs/heads/rejbase 2>/dev/null    # origin really holds an OLDER sha
git -C "$TMP/wt12" commit -q --allow-empty -m "an unpushed commit on top"
rej_old="$(git -C "$TMP/wt12" rev-parse HEAD~1)"
: > "$O/logs/rejected.log"; rm -f "$O/state/lane-exit-rejected.state"
PATH="$TMP/bin-rej:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=rejbase
  lane_end_push "rejected" "$3" "$2" rejbase 1 1
  printf "push=%s origin=%s\n" "$LANE_END_PUSH" "$LANE_END_ORIGIN"
' _ "$GATE" "$TMP/wt12" "$O/logs/rejected.log" > "$TMP/n43.out" 2>&1
grep -qx "push=FAILED origin=$rej_old" "$TMP/n43.out"; rcn43a=$?
ck "N43a a NON-ZERO push is VERIFIED against the remote, so FAILED carries the sha the remote reported rather than an unread absence [$(cat "$TMP/n43.out" 2>/dev/null | tr -d '\n')]" $rcn43a
grep -q "holds refs/heads/rejbase at $rej_old" "$O/logs/rejected.log"; rcn43b=$?
ck "N43b …and the log replays what the REMOTE answered (the repository AND the sha it holds), which is the only thing that establishes a non-delivery" $rcn43b
# and when the VERIFY read cannot answer on a non-zero push, the verdict is neither delivery nor absence.
# Match ONLY `ls-remote --heads` so the pre-push symref read still answers (see N43a's note).
mkdir -p "$TMP/bin-rej2"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 1 ;; *" ls-remote --heads "*) exit 7 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-rej2/git"
chmod +x "$TMP/bin-rej2/git"
: > "$O/logs/unreported.log"
PATH="$TMP/bin-rej2:$PATH" O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=rejbase
  lane_end_push "unreported" "$3" "$2" rejbase 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
  lane_end_next > "$4"
' _ "$GATE" "$TMP/wt12" "$O/logs/unreported.log" "$TMP/n43.next" > "$TMP/n43b.out" 2>&1
grep -qx 'push=push-unreported' "$TMP/n43b.out"; rcn43c=$?
ck "N43c …and a non-zero push whose read ALSO cannot answer records push=push-unreported — never FAILED, which would assert an absence nobody read" $rcn43c
case "$(cat "$TMP/n43.next" 2>/dev/null)" in MANUAL*"does NOT know"*"do NOT reap"*) rcn43d=0 ;; *) rcn43d=1 ;; esac
ck "N43d …and next= refuses a reclaim while asserting it does NOT know what origin holds [$(cut -c1-56 "$TMP/n43.next" 2>/dev/null)]" $rcn43d
# ⛔ N46 — A REJECTED PUSH IS NOT AN ADVANCE "INSIDE THE VERIFY WINDOW" (review of PR #3399 round 12, P2 —
# REPRODUCED). The rc≠0 path FALLS THROUGH to the ancestry arm on purpose, so `anc_rc=0` is reachable over a
# push that REPORTED FAILURE. That arm then wrote "a peer push or the rail advanced the ref inside the
# verify window" unconditionally — while for a REJECTED ref the advance is precisely the cause that PRECEDES
# the push, and the replayed `[rejected]` line sits in the same log. The verdict `pushed` is right either
# way (the commits ARE off-box); the CAUSE was fabricated. This fixture makes the remote a DESCENDANT and
# fails only the push, so the arm is driven with both facts at once.
N46="$TMP/n46"
rm -rf "$N46-origin.git" "$N46-hub" "$N46-lane" "$N46-peer"
git init -q --bare -b main "$N46-origin.git"
git init -q -b main "$N46-hub"
git -C "$N46-hub" config user.name t; git -C "$N46-hub" config user.email t@t
git -C "$N46-hub" remote add origin "$GHURL"
git -C "$N46-hub" config url."$N46-origin.git".insteadOf "$GHURL"
printf 'n46 seed\n' > "$N46-hub/seed.txt"
git -C "$N46-hub" add seed.txt && git -C "$N46-hub" commit -q -m 'n46 seed' \
  && git -C "$N46-hub" push -q origin HEAD:refs/heads/main \
  && git -C "$N46-hub" fetch -q origin \
  && git -C "$N46-hub" worktree add -q "$N46-lane" -b rejlane
git -C "$N46-lane" config user.name t; git -C "$N46-lane" config user.email t@t
printf 'the lane commit\n' > "$N46-lane/local.txt"
git -C "$N46-lane" add local.txt && git -C "$N46-lane" commit -q -m 'the lane commit'
n46_mine="$(git -C "$N46-lane" rev-parse HEAD 2>/dev/null)"
# THE ADVANCE COMES FIRST, which is what makes the lane's push a rejection rather than a delivery.
git -C "$N46-hub" worktree add -q "$N46-peer" -b peerrejlane "$n46_mine"
git -C "$N46-peer" config user.name t; git -C "$N46-peer" config user.email t@t
printf 'peer advance\n' > "$N46-peer/peer.txt"
git -C "$N46-peer" add peer.txt && git -C "$N46-peer" commit -q -m 'a peer advanced the ref FIRST'
git -C "$N46-peer" push -q origin HEAD:refs/heads/rejlane
n46_origin="$(git -C "$N46-origin.git" rev-parse refs/heads/rejlane 2>/dev/null)"
: > "$O/logs/n46.log"
PATH="$TMP/bin-rej:$PATH" bash -c '
  . "$1"
  lane_end_push n46 "$2" "$3" rejlane 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$O/logs/n46.log" "$N46-lane" 2>/dev/null > "$TMP/n46.out"
# ⛔ THE FIXTURE IS ASSERTED, NOT ASSUMED: the remote must really be AHEAD and is_oid must really hold.
[ -n "$n46_mine" ] && [ "$n46_mine" != "$n46_origin" ] \
  && git -C "$N46-origin.git" merge-base --is-ancestor "$n46_mine" "$n46_origin" 2>/dev/null; rcn46a=$?
ck "N46a FIXTURE: origin holds a DESCENDANT of the lane's HEAD ($(printf '%s' "$n46_mine" | cut -c1-8) → $(printf '%s' "$n46_origin" | cut -c1-8)) and bin-rej fails ONLY the push — so both facts are present" $rcn46a
grep -qx 'push=pushed' "$TMP/n46.out" && ! grep -qx 'push=FAILED' "$TMP/n46.out"; rcn46b=$?
ck "N46b …a REJECTED push whose remote already holds a descendant still records DELIVERY (every commit of this lane IS on that ref) [$(cat "$TMP/n46.out" 2>/dev/null | tr -d '\n')]" $rcn46b
! grep -q 'inside the verify window' "$O/logs/n46.log"; rcn46c=$?
ck "N46c …but it does NOT claim the advance happened INSIDE THE VERIFY WINDOW — over a rejection that advance is the cause, and it predates the push" $rcn46c
grep -q 'did not report success (rc=1)' "$O/logs/n46.log" && grep -q 'branch is NOT at risk' "$O/logs/n46.log" \
  && grep -q 'NOT established here' "$O/logs/n46.log"; rcn46d=$?
ck "N46d …and the line names only what was measured: the client did not report success, the commits are on that ref anyway, and the CAUSE is explicitly not established" $rcn46d
# ⛔ AND IT NAMES NO CAUSE AT ALL — round 12 replaced one exit-status-derived cause with another
# (review of PR #3399 round 13, P2 — REPRODUCED), so both shapes are refused by name here.
! grep -q 'BEFORE the push' "$O/logs/n46.log" && ! grep -q 'client refused' "$O/logs/n46.log" \
  && ! grep -q 'inside the verify window' "$O/logs/n46.log"; rcn46d2=$?
ck "N46d2 …and it does NOT replace that with a second exit-status cause: neither 'BEFORE the push' nor 'the client refused' nor 'inside the verify window' is asserted over an rc that cannot distinguish them" $rcn46d2
# …and the CONVERGED case is unchanged, so N46c cannot be passing by suppressing the sentence everywhere.
# ⛔ `unpushed` MUST BE 1 HERE: `lane_end_push` short-circuits on `unpushed <= 0` and answers `nothing`
# before any push — the first cut of this control passed 0 and asserted a `push=pushed` that the function
# never reaches (measured: `push=nothing`). The push itself is shimmed to exit 0 (the real one would be
# REJECTED by the remote that is already ahead), which is exactly the state this control is about: rc=0
# with the advance still present, where "inside the verify window" IS the measured reading.
mkdir -p "$TMP/bin-pushok"
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 0 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-pushok/git"
chmod +x "$TMP/bin-pushok/git"
: > "$O/logs/n46ok.log"
PATH="$TMP/bin-pushok:$PATH" bash -c '
  . "$1"
  lane_end_push n46ok "$2" "$3" rejlane 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$O/logs/n46ok.log" "$N46-lane" 2>/dev/null > "$TMP/n46ok.out"
grep -qx 'push=pushed' "$TMP/n46ok.out" && grep -q 'inside the verify window' "$O/logs/n46ok.log"; rcn46e=$?
ck "N46e …while a push that really exited 0 keeps the 'inside the verify window' reading (the branch is a branch, not a deletion) [$(cat "$TMP/n46ok.out" 2>/dev/null | tr -d '\n')]" $rcn46e
# ⛔ N47 — A `pushed` REMEDY NAMES THE REPOSITORY THE VERDICT IS ABOUT (review of PR #3399 round 12, P2 —
# REPRODUCED). Round 3 wrote that invariant for `verify-ancestry-unmeasured` and fixed ONE arm; two arms
# kept a hardcoded `origin`, while `pushed` is granted against the PROVEN push url. With
# `remote.origin.pushurl` diverging from `remote.origin.url`, the artifact's own prescribed command then
# names a repository nobody read. Both arms are driven here, plus the no-divergence control.
for _n47 in unpushed-only archived; do
  case "$_n47" in
    unpushed-only) _n47args='LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing' ;;
    archived)      _n47args='LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_REF=refs/wip-local/x' ;;
  esac
  for _n47u in /srv/push-repo.git ''; do
    n47="$( bash -c "
      . \"\$1\"
      $_n47args; LANE_END_PUSH=pushed; LANE_END_PUSH_URL='$_n47u'
      LANE_END_ORIGIN=abc1234; LANE_END_UNPUSHED=0; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
      lane_end_next" _ "$GATE" 2>/dev/null )"
    if [ -n "$_n47u" ]; then
      case "$n47" in *"$_n47u"*'abc1234'*) rcn47=0 ;; *) rcn47=1 ;; esac
      case "$n47" in *'origin'*) rcn47b=1 ;; *) rcn47b=0 ;; esac
      ck "N47 [$_n47] the remedy names the PROVEN push url ($_n47u), never a hardcoded origin [${n47:0:64}]" $([ "$rcn47" -eq 0 ] && [ "$rcn47b" -eq 0 ] && echo 0 || echo 1)
    else
      case "$n47" in *'origin'*'abc1234'*) rcn47c=0 ;; *) rcn47c=1 ;; esac
      ck "N47 [$_n47] …and with NO divergence it still names origin (the arm is a fence, not a blanket rewrite) [${n47:0:64}]" $rcn47c
    fi
  done
done
# ⛔ N48 — AN OFF-BOX ABSENCE IS NOT MEASURABLE FROM A LOCAL CACHE IN THE `unpushed>0` DIRECTION EITHER
# (review of PR #3399 round 12, P2 — REPRODUCED). `unpushed>0` is `rev-list --count HEAD --not --remotes`
# over `refs/remotes/*` — a CACHE. The `nothing` arm was scoped to it; this group still asserted "exist
# only on this disk", an off-box claim, reachable-and-false when a peer on a reused branch name pushed and
# this worktree never fetched.
for _n48p in UNAVAILABLE refused-unknown-default refused-pushurl-divergent refused-pushurl-unresolved; do
  n48="$( bash -c '
    . "$1"
    LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing; LANE_END_PUSH="$2"
    LANE_END_UNPUSHED=2; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
    lane_end_next' _ "$GATE" "$_n48p" 2>/dev/null )"
  case "$n48" in
    *'exist only on this disk'*) rcn48=1 ;;
    MANUAL*'LOCAL refs/remotes/*'*'CACHE'*'NOT a claim about what any remote holds'*) rcn48=0 ;;
    *) rcn48=1 ;;
  esac
  ck "N48 [$_n48p] the abstention is scoped to the LOCAL refs/remotes/* cache and explicitly NOT a claim about any remote — never 'exist only on this disk' [${n48:0:60}]" $rcn48
done
n48b="$( bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing; LANE_END_PUSH=UNAVAILABLE
  LANE_END_UNPUSHED=2; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n48b" in MANUAL*'do NOT reap'*'discarded'*) rcn48b=0 ;; *) rcn48b=1 ;; esac
ck "N48b …and it still REFUSES the reclaim and still names the volume hazard (fail-closed, and not a blanket abstention)" $rcn48b
case "$n48b" in *'unpushed=2'*) rcn48c=0 ;; *) rcn48c=1 ;; esac
ck "N48c …and carries the count it read, so the reader can see what the scoped sentence is about" $rcn48c
# ⛔ N49 — THE SAME OFF-BOX CLAIM IN THE SHARED CAVEAT HELPER (review of PR #3399 round 13, P2 —
# REPRODUCED). Round 12 scoped `lane_end_next`'s abstention; `lane_end_push_caveat`, which is APPENDED to
# the same MANUAL arms, kept "the commit(s) on <br> are NOT on origin either". This drives the EXACT state
# the reviewer reproduced — the documented fix-one.sh-without-WIP_PATH hub case — because
# `refused-main-checkout` is NOT consumed by the abstention group above, so the helper really is reached.
# The old "latent" note claimed every MANUAL push verdict returns above the helper's call sites; that is
# false for `refused-protected`/`refused-main-checkout`, which is why this arm exists.
n49="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=FAILED; LANE_END_PUSH=refused-main-checkout
  LANE_END_UNPUSHED=3; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n49" in
  *'are NOT on origin either'*) rcn49=1 ;;
  *'refused-main-checkout'*'LOCAL refs/remotes/*'*'CACHE'*'not a statement about any remote'*) rcn49=0 ;;
  *) rcn49=1 ;;
esac
ck "N49 the SHARED push caveat scopes its absence claim to the LOCAL cache too, on the state the reviewer reproduced (dirty + rescue=FAILED + refused-main-checkout) [${n49:0:70}]" $rcn49
# …and the caveat is still APPENDED there, so N49 cannot be passing by dropping the domain's fact.
case "$n49" in MANUAL*'no ref this run wrote pins the uncommitted work'*'refused-main-checkout'*) rcn49b=0 ;; *) rcn49b=1 ;; esac
case "$n49" in *'is NOT archived'*) rcn49b=1 ;; *) : ;; esac
ck "N49b …while the tree domain's MANUAL fact survives in the same sentence, scoped to this run (the caveat is not deleted, and the flat NOT-archived claim this class forbids is gone)" $rcn49b
# …and it is not vacuous for the OTHER member of that group either.
n49c="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=FAILED; LANE_END_PUSH=refused-protected
  LANE_END_UNPUSHED=1; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=main
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n49c" in *'are NOT on origin either'*) rcn49c=1 ;; *'LOCAL refs/remotes/*'*) rcn49c=0 ;; *) rcn49c=1 ;; esac
ck "N49c …and for refused-protected, the other member that reaches the helper" $rcn49c
# ⛔ N50 — THE ARCHIVE RECOVERY NAMES THE PROVEN PUSH URL (review of PR #3399 round 13, P2 — REPRODUCED).
# `bg-rescue-wip.sh` WRITES the archive with `git push origin "$C:refs/wip/$SLUG"` (328/333/354, all three push functions), so it lands
# in the PUSH repository; this instruction was a FETCH through `origin`, which reads remote.origin.url.
# With the two diverging, the artifact's own command answers "couldn't find remote ref" over an archive
# that exists in the other repository — the round-3 failure verbatim, in a third arm of that invariant.
for _n50u in /srv/push-repo.git ''; do
  n50="$( bash -c '
    . "$1"
    LANE_END_TREE=dirty; LANE_END_RESCUE=refs/wip/fix-x; LANE_END_PUSH=pushed
    LANE_END_PUSH_URL="$2"; LANE_END_ORIGIN=abc1234
    LANE_END_UNPUSHED=0; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
    lane_end_next' _ "$GATE" "$_n50u" 2>/dev/null )"
  if [ -n "$_n50u" ]; then
    case "$n50" in *"git fetch $_n50u refs/wip/fix-x"*) rcn50=0 ;; *) rcn50=1 ;; esac
    ck "N50 the archive recovery fetches from the PROVEN push url ($_n50u), not a hardcoded origin [${n50:0:64}]" $rcn50
  else
    case "$n50" in *'git fetch origin refs/wip/fix-x'*) rcn50b=0 ;; *) rcn50b=1 ;; esac
    ck "N50 …and with NO divergence it still says origin (a fence, not a blanket rewrite) [${n50:0:64}]" $rcn50b
  fi
done
# ⛔ N51 — THE REMEDY NAMES THE PUSH REPOSITORY EVEN WHEN THE PUSH STEP NEVER RAN (review of PR #3399
# round 14, P2 — REPRODUCED). `lane_end_push` resolves and PROVES `LANE_END_PUSH_URL` only after the
# `unpushed > 0` gate — `nothing`, `unmeasured` and `detached` all return before it — so round 13's fix
# fell back to `origin` exactly on those paths. Measured end-to-end by the reviewer on the previous head:
# a `pushurl`-divergent repo, a clean tree with one stray file and `unpushed=0` gave
# `next=… git fetch origin refs/wip/<slug>`, whose own command answered `couldn't find remote ref` while
# `bg-rescue-wip.sh` had put the archive in the push repository. `lane_end_push_repo` reads the push url
# from CONFIG (no network, no proof needed for a remedy).
N51="$TMP/n51"
rm -rf "$N51"
git init -q -b main "$N51"
git -C "$N51" config user.name t; git -C "$N51" config user.email t@t
git -C "$N51" commit -q --allow-empty -m seed
git -C "$N51" remote add origin https://example.invalid/fetch.git
git -C "$N51" config remote.origin.pushurl https://example.invalid/push.git
[ "$(git -C "$N51" remote get-url origin)" != "$(git -C "$N51" remote get-url --push origin)" ]; rcn51b=$?
ck "N51b FIXTURE: the repo's fetch and push urls really DIVERGE — else this arm cannot see the class" $rcn51b
n51="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=refs/wip/fix-x; LANE_END_PUSH=nothing
  LANE_END_UNPUSHED=0; LANE_END_ROOT="$2"; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" "$N51" 2>/dev/null )"
case "$n51" in *'git fetch https://example.invalid/push.git refs/wip/fix-x'*) rcn51=0 ;; *) rcn51=1 ;; esac
ck "N51 …even when the push step never ran (push=nothing leaves LANE_END_PUSH_URL unset), the archive recovery fetches from the PUSH url [${n51:0:70}]" $rcn51
n51c="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=running
  LANE_END_UNPUSHED=2; LANE_END_ROOT="$2"; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" "$N51" 2>/dev/null )"
case "$n51c" in *'git ls-remote --heads https://example.invalid/push.git refs/heads/develop'*) rcn51c=0 ;; *) rcn51c=1 ;; esac
ck "N51c …and so does the push=running 're-read the remote' remedy, which is written before the push step" $rcn51c
# ⛔ AND `push=unmeasured` HAS NO REPOSITORY TO NAME — its remedy is the endpoint-free
# `rev-list --count HEAD --not --remotes`, deliberately (a narrower question about one remote is what the
# round-15 finding was about). Asserted so a later "make it name a repo" change cannot narrow it silently.
n51d="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=nothing; LANE_END_PUSH=unmeasured
  LANE_END_UNPUSHED=
  LANE_END_ROOT="$2"; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" "$N51" 2>/dev/null )"
case "$n51d" in *'rev-list --count HEAD --not --remotes'*) rcn51d=0 ;; *) rcn51d=1 ;; esac
ck "N51d …while push=unmeasured still prescribes the ENDPOINT-FREE count (naming a remote would answer a narrower question)" $rcn51d
# …and TWO push urls are not this code's to guess: it answers `origin` rather than picking one.
N51E="$TMP/n51e"
rm -rf "$N51E"
git init -q -b main "$N51E"
git -C "$N51E" config user.name t; git -C "$N51E" config user.email t@t
git -C "$N51E" commit -q --allow-empty -m seed
git -C "$N51E" remote add origin https://example.invalid/fetch.git
git -C "$N51E" config --add remote.origin.pushurl https://example.invalid/p1.git
git -C "$N51E" config --add remote.origin.pushurl https://example.invalid/p2.git
n51e="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=refs/wip/fix-x; LANE_END_PUSH=nothing
  LANE_END_UNPUSHED=0; LANE_END_ROOT="$2"; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" "$N51E" 2>/dev/null )"
case "$n51e" in *'git fetch origin refs/wip/fix-x'*) rcn51e=0 ;; *) rcn51e=1 ;; esac
ck "N51e …while TWO push urls answer origin — an ambiguous target is not this code's to pick, the same way the push half refuses it by name [${n51e:0:60}]" $rcn51e

# ⛔ N52 — A DETACHED HEAD'S COMMITS ARE HELD BY NO BRANCH (review of PR #3399 round 15, P2 — REPRODUCED).
# `push=detached` shared the `UNAVAILABLE|refused-*` group in BOTH consumers, whose sentences end "The
# commits survive the worktree being removed". That is true for a commit on a BRANCH — the branch ref lives
# in the shared object database — and FALSE here: nothing but this worktree's own HEAD and reflog references
# a detached commit, and `git worktree remove` deletes `.git/worktrees/<id>/HEAD` with its reflog, after
# which the object is unreachable and `git gc` prunes it. Measured on a linked worktree: HEAD detached, one
# commit, `for-each-ref --contains HEAD` EMPTY, object PRUNED by `gc --prune=now` after removal. The claim
# stood in the direction that LOSES WORK, so both consumers are driven here.
DETW="$TMP/wtdet"; rm -rf "$DETW"
git -C "$WT" worktree add -q --detach "$DETW" 2>/dev/null
git -C "$DETW" config user.name t; git -C "$DETW" config user.email t@t
git -C "$DETW" commit -q --allow-empty -m "a commit on a detached head"
# FIXTURE: the HEAD really is detached and the commit really is held by no branch.
[ -z "$(git -C "$DETW" symbolic-ref -q --short HEAD)" ] && [ -z "$(git -C "$DETW" for-each-ref --contains HEAD --format='%(refname)' 2>/dev/null)" ]; rcn52a=$?
ck "N52a FIXTURE: the fixture worktree is DETACHED and no ref contains its HEAD — else this arm cannot see the class" $rcn52a
: > "$O/logs/det.log"; rm -f "$O/state/lane-exit-det.state"
WIP_PATH="$DETW" O="$O" bash -c '
  . "$1"
  terminal_wip_rescue "det" 0 0 "$2"
' _ "$GATE" "$O/logs/det.log" 2>>"$O/logs/det.log.agent"
grep -qx 'push=detached' "$O/state/lane-exit-det.state" 2>/dev/null; rcn52b=$?
ck "N52b …and the terminal really reaches push=detached (the verdict this arm is about) [$(grep -m1 '^push=' "$O/state/lane-exit-det.state" 2>/dev/null)]" $rcn52b
! grep -qi 'survive this WORKTREE being removed' "$O/logs/det.log" && grep -q 'DETACHED HEAD' "$O/logs/det.log"; rcn52c=$?
ck "N52c …and the LANE LOG does NOT promise that a detached commit survives the worktree being removed" $rcn52c
det_next="$(grep -m1 '^next=' "$O/state/lane-exit-det.state" 2>/dev/null | sed 's/^next=//')"
case "$det_next" in *'survive the worktree being removed'*) rcn52d=1 ;; *'DETACHED HEAD'*'unreachable'*) rcn52d=0 ;; *) rcn52d=1 ;; esac
ck "N52d …and next= likewise says the commits become unreachable, instead of the branch-survival sentence [${det_next:0:70}]" $rcn52d
# …and the group it LEFT still carries its own survival sentence, so N52c is not passing by deletion.
# …and the group `detached` LEFT still carries its own survival sentence, so N52c is not passing because
# the file lost the sentence everywhere. (A detached commit is on no branch, so the sentence is right for
# `UNAVAILABLE` and wrong only here — the two facts must not be collapsed into one arm.)
det_unav="$( bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing; LANE_END_PUSH=UNAVAILABLE
  LANE_END_UNPUSHED=1; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$det_unav" in *'survive the worktree being removed'*) rcn52e=0 ;; *) rcn52e=1 ;; esac
ck "N52e …while the group it LEFT still carries the branch-survival sentence (the fact is split per verdict, not deleted)" $rcn52e
# ⛔ N53 — NO UNESCAPED BACKTICK IN A DOUBLE-QUOTED LOG STRING (review of PR #3399 round 15, P1 — MY OWN
# REGRESSION). Round 14's NOTE rewrite put `git fetch --prune` in RAW BACKTICKS inside a DOUBLE-QUOTED
# `echo`, so the exit path EXECUTED it: measured, a terminating lane ran `git fetch --prune` against the
# checked-out repo and PRUNED `refs/remotes/origin/gone` — mutating the very cache this artifact family
# reasons about — unbounded, on the one path R3 forbids unbounded network calls on. N15h could not see it:
# it greps words that survived the substitution, while the substitution ate the words around them. The
# existing N14 scanner strips prose before counting `git`, so a substitution inside a message is invisible
# to it by construction — hence a scanner for the CLASS, not for one sentence.
n53_scan() { # n53_scan <file> -> number of `echo "` lines carrying an UNESCAPED backtick
  awk '
    { line = $0; gsub(/\\`/, "", line)
      if (line ~ /echo "/ && index(line, "`") > 0) { n++; if (n <= 3) print "  line " NR ": " substr(line, 1, 100) > "/dev/stderr" } }
    END { printf "%d", n + 0 }' "$1"
}
n53="$(n53_scan "$GATE" 2>/dev/null)"
[ "$n53" = "0" ]; rcn53=$?
ck "N53 …no DOUBLE-QUOTED log line carries an UNESCAPED backtick — a command substitution in a message is a live command on the exit path (found $n53)" $rcn53
# ⛔ AND THE SCANNER IS SHOWN TO SEE THE CLASS: a COPY with the defect restored must be counted.
N53M="$TMP/n53mut"; rm -rf "$N53M"; mkdir -p "$N53M"
sed 's/'"'"'git fetch --prune'"'"'/`git fetch --prune`/' "$GATE" > "$N53M/spawn-gate.sh" 2>/dev/null
n53m="$(n53_scan "$N53M/spawn-gate.sh" 2>/dev/null)"
[ "$n53m" != "0" ]; rcn53b=$?
ck "N53b …and the scanner is LOAD-BEARING: the defect restored in a copy is counted ($n53m line(s)), so a green N53 is not a scan that sees nothing" $rcn53b
# ⛔ N54 — "NOT ON THAT REF" IS NOT "ONLY ON THIS DISK" IN THE LANE LOG EITHER (review of PR #3399
# round 15, P2 — REPRODUCED). The `FAILED`/`branch_on_origin`-empty NOTE is the third consumer to make the
# claim, and splitting `FAILED` in round 5 changed the ARM without narrowing the READ: the measurement is
# `ls-remote --heads <pushurl> refs/heads/<br>` answering NOTHING, which is an absence about ONE REF NAME.
# Its sibling arm already declines the inference in as many words; this one did not. Reachable: a peer
# pushed these commits under another name and this worktree never fetched, and the exit path's own push of
# `refs/heads/<br>` was refused by a hook — the log then says the work exists only on this disk while the
# push repository holds it under another ref. Driven through the real `terminal_wip_rescue`.
mkdir -p "$TMP/bin-empty"
# push fails; the HEADS read ANSWERS with nothing (rc=0, empty) — that is `FAILED` with `branch_on_origin`
# empty. `ls-remote --symref` must still answer, or the arm is refused earlier for an unknown default.
{ printf '#!/bin/sh\ncase " $* " in *" push "*) exit 1 ;; *" ls-remote --heads "*) exit 0 ;; esac\nexec %s "$@"\n' "$REAL_GIT"; } > "$TMP/bin-empty/git"
chmod +x "$TMP/bin-empty/git"
git -C "$WT" worktree add -q "$TMP/wtempty" -b emptyheads 2>/dev/null
git -C "$TMP/wtempty" config user.name t; git -C "$TMP/wtempty" config user.email t@t
git -C "$TMP/wtempty" commit -q --allow-empty -m "an unpushed commit"
: > "$O/logs/emptynote.log"; rm -f "$O/state/lane-exit-emptynote.state"
# ⛔ THE ROOT IS THE `WIP_PATH` ENV, NOT ARG 4: `terminal_wip_rescue <label> <rc> <cap> <log>` takes the
# LOG as its fourth argument and reads the tree from `WIP_PATH` (default `$PWD`). The first cut of this arm
# passed the worktree as arg 4 and therefore measured the REPOSITORY THIS SUITE RUNS IN — the marker came
# back `root=<the agent-infra checkout>, state=dirty, unpushed=0, push=nothing`, i.e. an arm about a
# FAILED push that never ran one, over a tree that is not the fixture's. The `N54a` fixture assertion is
# what caught it.
PATH="$TMP/bin-empty:$PATH" WIP_PATH="$TMP/wtempty" O="$O" bash -c '
  . "$1"
  terminal_wip_rescue "emptynote" 0 0 "$2"
' _ "$GATE" "$O/logs/emptynote.log" 2>>"$O/logs/emptynote.log.agent"
grep -qx 'push=FAILED' "$O/state/lane-exit-emptynote.state" 2>/dev/null \
  && grep -qx 'branch_on_origin=' "$O/state/lane-exit-emptynote.state" 2>/dev/null; rcn54a=$?
ck "N54a FIXTURE: the terminal reaches push=FAILED with branch_on_origin EMPTY — the arm this is about [$(grep -m1 '^push=' "$O/state/lane-exit-emptynote.state" 2>/dev/null)]" $rcn54a
grep -qx "root=$TMP/wtempty" "$O/state/lane-exit-emptynote.state" 2>/dev/null; rcn54a2=$?
ck "N54a2 …and the ROOT is the fixture worktree, not the checkout this suite runs in (WIP_PATH, not arg 4)" $rcn54a2
! grep -q 'exist ONLY locally' "$O/logs/emptynote.log" \
  && grep -q 'not on THAT ref' "$O/logs/emptynote.log" \
  && grep -q 'Whether they are on some OTHER ref was NOT measured here' "$O/logs/emptynote.log"; rcn54b=$?
ck "N54b …and the [wip] NOTE does NOT turn a one-ref absence into 'only on this disk'" $rcn54b
# …and the survival facts survive the scoping, so this is a narrowed claim and not a deleted one.
grep -q 'They survive this WORKTREE being removed' "$O/logs/emptynote.log"; rcn54c=$?
ck "N54c …while still naming what does and does not survive" $rcn54c
# ⛔ N55 — NO OPERATOR-FACING LINE STATES AN OFF-BOX ABSENCE WITHOUT THE SCOPE OF THE READ THAT PRODUCED
# IT (fresh review of PR #3399 at af13bcf4f, P2 — REPRODUCED). Round 16 scoped ten `[lane-exit]` lines with
# a `loscope` definition and MISSED three in the `pushed` arm ("existed only on this disk", "existed ONLY
# locally"), so the half-applied fix shipped green: N45/N45b/N45c pin sentence SHAPE and domain
# completeness, and N48/N54 pin `next=`/NOTE wording — NOTHING grepped the `[lane-exit]` lines for scope,
# which is why the miss was invisible. The scanner below is for the CLASS, not for the three sentences.
# A COMMENT is not an operator-facing line: this file's own review history quotes the phrases it removed,
# and stripping comments is what keeps that history from reading as a live claim.
n55_scan() { # n55_scan <file> -> number of operator-facing lines carrying an UNSC0PED absence phrase
  awk '
    { line = $0
      sub(/^[ \t]+/, "", line)
      if (substr(line, 1, 1) == "#") next            # a comment records history; it is not a claim to an operator
      if (line !~ /(echo|printf)/) next
      if (line !~ /ONLY on this disk|only on this disk|ONLY locally|only locally|existed only on|exist only on|are local-only|NOT on origin either|are on NO branch/) next
      if (line ~ /loscope|LANE_END_LOCAL_SCOPE|LOCAL refs\/remotes|NOT measured|not measured|MIGHT/) next
      n++; if (n <= 3) print "  line " NR ": " substr(line, 1, 110) > "/dev/stderr"
    }
    END { printf "%d", n + 0 }' "$1"
}
n55="$(n55_scan "$GATE" 2>/dev/null)"
[ "$n55" = "0" ]; rcn55=$?
ck "N55 …no operator-facing line claims an off-box absence ('only on this disk' / 'only locally' / 'on NO branch') without the scope of the read that produced it (found $n55)" $rcn55
# ⛔ AND THE SCANNER IS SHOWN TO SEE THE CLASS: a COPY with one unscoped line planted must be counted.
N55M="$TMP/n55mut"; rm -rf "$N55M"; mkdir -p "$N55M"
awk 'NR==1{print; print "  echo \"claimed: N commit(s) exist ONLY on this disk\""; next} {print}' "$GATE" > "$N55M/spawn-gate.sh" 2>/dev/null
n55m="$(n55_scan "$N55M/spawn-gate.sh" 2>/dev/null)"
[ "$n55m" = "1" ]; rcn55b=$?
ck "N55b …and the scanner is LOAD-BEARING: ONE planted unscoped line is counted ($n55m), so a green N55 is not a scan that sees nothing" $rcn55b
# ⛔ AND IT IS A SCAN FOR SCOPE, NOT A BAN ON VOCABULARY: the SAME phrase carrying the scope is NOT counted,
# so quoting the words in an honest sentence must stay possible (the whole family is worded that way).
N55S="$TMP/n55scope"; rm -rf "$N55S"; mkdir -p "$N55S"
awk 'NR==1{print; print "  echo \"were $LANE_END_LOCAL_SCOPE — only on this disk until pushed\""; next} {print}' "$GATE" > "$N55S/spawn-gate.sh" 2>/dev/null
n55s="$(n55_scan "$N55S/spawn-gate.sh" 2>/dev/null)"
[ "$n55s" = "0" ]; rcn55c=$?
ck "N55c …while the SAME phrase carrying the scope is NOT counted, so the scan tests scope and not vocabulary ($n55s)" $rcn55c
# ⛔ N56 — A PARTIAL ARCHIVE MAY NOT BE REPORTED AS THE WHOLE TREE (fresh review of PR #3399 at
# 11c3f7cd9, P1 — REPRODUCED). `rescue=archived-local` is assigned on `rc2 != 0` + "a ref this run
# wrote", and `bg-rescue-wip.sh` exits 2 for BOTH a PARTIAL archive and a failed push. The skipped paths
# of a partial archive are in NEITHER `refs/wip-local/<slug>` NOR `refs/wip/<slug>`, so a remedy that
# said "retrieve the archive … before removing" without naming that possibility told an operator to
# remove a worktree whose unarchivable paths no archive held. All four `archived-local` remedies are
# driven here, because the sentence is composed in four places and was wrong in all four.
for _n56 in pushed nothing FAILED UNAVAILABLE; do
  n56="$( bash -c '
    . "$1"
    LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_REF=refs/wip-local/x@abc1234
    LANE_END_PUSH="$2"; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop; LANE_END_ORIGIN=deadbee
    lane_end_next' _ "$GATE" "$_n56" 2>/dev/null )"
  case "$n56" in *'may be PARTIAL'*) rcn56=0 ;; *) rcn56=1 ;; esac
  ck "N56 …an archived-local remedy (push=$_n56) names that the archive may be PARTIAL — exit 2 is also a partial archive, and its skipped paths are in NO archive named here" $rcn56
done
# …and the caveat is NOT emitted where it would be a different false claim: a `clean` tree has nothing
# at risk, so its remedy must not carry an archive-partiality warning (non-vacuity for N56).
n56b="$( bash -c '
  . "$1"
  LANE_END_TREE=clean; LANE_END_RESCUE=nothing; LANE_END_PUSH=nothing; LANE_END_UNPUSHED=0
  LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n56b" in *'may be PARTIAL'*) rcn56b=1 ;; *) rcn56b=0 ;; esac
ck "N56b …while a clean-tree remedy does NOT carry it, so N56 is a scoped caveat and not a constant banner [${n56b:0:60}]" $rcn56b
# ⛔ N57 — A LISTING THAT NAMED DIRTY PATHS **AND WARNED** IS STILL AN INCOMPLETE WALK (fresh review at
# 11c3f7cd9, P1 — REPRODUCED). The classifier read `st_out` non-empty as `dirty` and never consulted
# `st_noise`, and `lane_end_tree_caveat`'s only arm was `cannot-verify` — so `dirty` was the one verdict
# that could NEVER carry the caveat, and the porcelain section was published as the worktree's state.
n57="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_REF=refs/wip-local/x@abc1234
  LANE_END_PUSH=nothing; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  LANE_END_LISTING_INCOMPLETE=1
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n57" in *'NOT PROVEN complete'*) rcn57=0 ;; *) rcn57=1 ;; esac
ck "N57 …a dirty tree whose listing WARNED carries the incompleteness caveat — the paths the walk never saw are in neither the porcelain section nor any archive" $rcn57
# …and the SAME dirty tree WITHOUT the flag does not, so N57 is driven by the measurement and not by `dirty`.
n57b="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=archived-local; LANE_END_REF=refs/wip-local/x@abc1234
  LANE_END_PUSH=nothing; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  LANE_END_LISTING_INCOMPLETE=0
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n57b" in *'NOT PROVEN complete'*) rcn57b=1 ;; *) rcn57b=0 ;; esac
ck "N57b …while the same dirty tree with a COMPLETE listing does not, so the caveat tracks the flag and not the verdict" $rcn57b
# …and the FIXTURE half: the classifier must SET that flag for a listing that both names paths and warns.
# Driven on a real worktree, because the flag is what the two arms above consume — asserting it there
# would otherwise only ever test the test.
N57W="$TMP/wtn57"; rm -rf "$N57W"
git -C "$WT" worktree add -q "$N57W" -b incomplete57 2>/dev/null
mkdir -p "$N57W/sub"; printf 'a\n' > "$N57W/sub/f.txt"; printf 'b\n' > "$N57W/top.txt"
git -C "$N57W" add -A >/dev/null 2>&1; git -C "$N57W" -c user.name=t -c user.email=t@t commit -qm seed >/dev/null 2>&1
printf 'MOD\n' >> "$N57W/top.txt"; printf 'MOD2\n' >> "$N57W/sub/f.txt"; chmod 000 "$N57W/sub"
: > "$O/logs/n57.log"; rm -f "$O/state/lane-exit-n57.state"
WIP_PATH="$N57W" O="$O" bash -c '
  . "$1"
  terminal_wip_rescue "n57" 0 0 "$2"
' _ "$GATE" "$O/logs/n57.log" 2>>"$O/logs/n57.log.agent"
chmod 755 "$N57W/sub" 2>/dev/null
n57next="$(grep -m1 '^next=' "$O/state/lane-exit-n57.state" 2>/dev/null | sed 's/^next=//')"
case "$n57next" in *'NOT PROVEN complete'*) rcn57c=0 ;; *) rcn57c=1 ;; esac
ck "N57c FIXTURE: a REAL listing that names 'M top.txt' AND warns (chmod 000 sub/) sets the flag, so the caveat reaches an operator [$(grep -m1 '^state=' "$O/state/lane-exit-n57.state" 2>/dev/null)]" $rcn57c
# …and the `dirty` field must not read as a WHOLE-LISTING measurement over that same warning walk (review
# cycle 21, P3 — VERIFIED against this file's own rule and README's "`dirty` … is `?` whenever that listing
# is untrusted"). The count came from a listing the terminal had just declined to certify, so it is `?`;
# publishing `dirty=2` there invited a reclaim pass to read a trusted count beside a porcelain section the
# caveat says is incomplete.
n57dirty="$(grep -m1 '^dirty=' "$O/state/lane-exit-n57.state" 2>/dev/null)"
case "$n57dirty" in 'dirty=?') rcn57d=0 ;; *) rcn57d=1 ;; esac
ck "N57d FIXTURE: …and the marker's dirty field is '?' over that warned listing, so no field presents a trusted count over an untrusted walk [$n57dirty]" $rcn57d
# ⛔ N58 — EXIT 0 DOES NOT PROVE THE ARCHIVE'S TREE IS THE WORKTREE (fresh review at 4f50e6718, P1 —
# REPRODUCED, and it FALSIFIED the premise round 18 used to leave this arm alone: "the callee skips no
# paths on exit 0"). `scripts/bg-rescue-wip.sh` runs `git add -A` (`:201`), falls back to `git add -u` with
# stderr DISCARDED (`:209`), then adds only `git ls-files -o` entries — UNTRACKED paths — collecting
# `SKIPPED` from those alone. A TRACKED file git cannot read fails both adds, is never in the untracked
# sweep, and is in NEITHER the archive NOR the skipped list — `write-tree` and the push still succeed and
# the callee exits 0. The remedy said "the archive commit's TREE is the worktree as it was left" over
# exactly that shape, so an operator who fetched it, found the edit absent, and removed the worktree
# destroyed the only copy.
for _n58p in pushed nothing; do
  n58="$( bash -c '
    . "$1"
    LANE_END_TREE=dirty; LANE_END_RESCUE=refs/wip/develop; LANE_END_REF=refs/wip-local/develop@abc1234
    LANE_END_PUSH="$2"; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop; LANE_END_ORIGIN=deadbee
    lane_end_next' _ "$GATE" "$_n58p" 2>/dev/null )"
  case "$n58" in *'TREE is NOT PROVEN'*'before removing anything'*) rcn58=0 ;; *) rcn58=1 ;; esac
  ck "N58 …the refs/wip/* remedy (push=$_n58p) does NOT claim the archive's tree IS the worktree — a tracked file git cannot read is in NEITHER the archive NOR the skipped list, on an exit 0" $rcn58
done
# …and the cannot-verify arm makes the same claim and must carry the same scoping.
n58b="$( bash -c '
  . "$1"
  LANE_END_TREE=cannot-verify; LANE_END_RESCUE=refs/wip/develop; LANE_END_REF=refs/wip-local/develop@abc
  LANE_END_PUSH=nothing; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n58b" in *'NOT PROVEN to be the worktree as it was left'*) rcn58b=0 ;; *) rcn58b=1 ;; esac
ck "N58b …and so does the cannot-verify arm, which is the one state whose subject IS that the measurement was incomplete" $rcn58b
# ⛔ N58c — A REFUSED PUSH ON A DIRTY TREE MAY NOT DROP THE INCOMPLETENESS FACT (fresh review, P2). The arm
# appended only `lane_end_rescue_caveat`, which emits NOTHING for `rescue=refs/wip/*`, so the flag was
# measured and never reported — on the arm the file calls "the fleet's worst reachable state".
n58c="$( bash -c '
  . "$1"
  LANE_END_TREE=dirty; LANE_END_RESCUE=refs/wip/develop; LANE_END_REF=refs/wip-local/develop@abc
  LANE_END_PUSH=refused-main-checkout; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
  LANE_END_LISTING_INCOMPLETE=1
  lane_end_next' _ "$GATE" 2>/dev/null )"
case "$n58c" in *'NOT PROVEN complete'*) rcn58c=0 ;; *) rcn58c=1 ;; esac
ck "N58c …and a REFUSED push on a dirty tree still reports an INCOMPLETE listing instead of silencing it" $rcn58c
echo

# ⛔ N44 — THE READ AND THE WRITE MUST ADDRESS THE SAME REPOSITORY (review cycle 17, P0 — REPRODUCED).
# `git push origin` honours remote.origin.pushurl and `url.<base>.pushInsteadOf`; `ls-remote origin` honours
# remote.origin.url. When they diverge the landing-branch set came from repository A while the ref was
# written to repository B — and B's LANDING BRANCH moved. Reproduced on this commit before the fix:
# canon.git's refs/heads/trunk moved 613382f..b4e6ab9 (fast forward) while the same terminal recorded
# `push=FAILED` "does NOT hold refs/heads/trunk". THIS ARM FAILS IF THE FIX IS REMOVED: with the reads
# back on `origin` the protected set is mirror's `main`, `trunk` is not in it, and canon's trunk moves.
#
# ⛔ A FIXTURE MAY NOT DEPEND ON THE BOX'S GLOBAL GIT IDENTITY (review round 5, P0 — REPRODUCED).
# Every `git commit` in N44/N44g/N44h needs `user.name`/`user.email`. THIS box carries them in
# `~/.gitconfig`, so the arms passed here for twenty-odd cycles — and the CI runner carries NEITHER, so
# `git commit` there dies with `fatal: empty ident name (for <runner@…>) not allowed`, the `&&` chain
# short-circuits, the bare repos stay empty, `git worktree add -q … trunk` fails, `lane_end_push` is
# handed a directory that does not exist, and the terminal records `push=detached` — a verdict about a
# DYING LANE, produced by a FIXTURE that never got built. Measured on run 42084291355 job 127445961182
# (`wip-rescue-exit.test.sh: 212 passed, 6 failed` → N44a N44c N44d N44g0 N44g N44g2) and reproduced on
# this box, byte-identical, with `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null HOME=<empty>`.
# ⛔ N44h did NOT red there, which is worse than a red: its fixture also failed to build and the arm
# still reported ✅, because a clone with no commit and no `origin` lands on `refused-pushurl-unresolved`
# by a different route. A green arm over a broken fixture is the class this suite exists to refuse.
# Set in the REPO (not per-command) for the reason recorded at the top of this file: `bg-rescue-wip.sh`
# builds its archive with `git commit-tree`, which needs an identity of its OWN, so `-c user.email=…` on
# the command that commits does not cover an arm that later archives. And the two arms below assert the
# fixture is REAL, so a fixture that fails to build reds a `…prep` arm instead of six arms blaming the code.
fixture_ident() { git -C "$1" config user.name t && git -C "$1" config user.email t@t; }
is_oid() { grep -qE '^[0-9a-f]{40}$' <<< "$1"; }
n44="$TMP/n44"; mkdir -p "$n44"
git init -q --bare "$n44/mirror.git" && git init -q --bare "$n44/canon.git"
git -C "$n44/mirror.git" symbolic-ref HEAD refs/heads/main
git -C "$n44/canon.git" symbolic-ref HEAD refs/heads/trunk
git init -q "$n44/seed" && fixture_ident "$n44/seed" && git -C "$n44/seed" commit -q --allow-empty -m base \
  && git -C "$n44/seed" branch -M main && git -C "$n44/seed" commit -q --allow-empty -m m2 \
  && git -C "$n44/seed" push -q "$n44/mirror.git" main:main \
  && git -C "$n44/seed" checkout -q -b trunk && git -C "$n44/seed" commit -q --allow-empty -m t2 \
  && git -C "$n44/seed" push -q "$n44/canon.git" trunk:trunk && rm -rf "$n44/seed"
git clone -q "$n44/mirror.git" "$n44/wk" 2>/dev/null
# The lane worktree's commits below read the COMMON config, i.e. this clone's — set once, here.
fixture_ident "$n44/wk"
git -C "$n44/wk" remote set-url --push origin "$n44/canon.git"
git -C "$n44/wk" fetch -q "$n44/canon.git" trunk:trunk
git -C "$n44/wk" worktree add -q "$n44/wt" trunk
git -C "$n44/wt" commit -q --allow-empty -m "a lane's unpushed work"
# ⛔ THE FIXTURE IS ASSERTED BEFORE ANY VERDICT IS READ FROM IT (review round 5, P0 — REPRODUCED).
# `git rev-parse <ref>` writes the LITERAL ARGUMENT to stdout when the ref does not resolve, and exits
# 128 — so on the broken-fixture path (the CI runner, no git identity) `n44_before` was the STRING
# `refs/heads/trunk` and `n44_after` was the same string, i.e. N44b compared two error echoes and
# reported ✅ "the landing branch did NOT move (refs/hea before, refs/hea after)" — a green assertion
# over a ref that never existed, holding up the one arm that proves the P0 bypass cannot recur.
# The last two N44 arms do not have this hole and this one does not inherit it: the sha must be 40-hex
# and the worktree must exist, or the arms that follow are measuring nothing.
n44_before="$(git -C "$n44/canon.git" rev-parse refs/heads/trunk 2>/dev/null)"
{ is_oid "$n44_before" && [ -d "$n44/wt" ]; }; rcn44prep=$?
ck "N44prep the fixture is REAL — canon.git holds a 40-hex trunk ($n44_before) and the lane worktree exists" $rcn44prep
: > "$O/logs/pushurl.log"
O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=trunk
  lane_end_push "pushurl" "$3" "$2" trunk 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
' _ "$GATE" "$n44/wt" "$O/logs/pushurl.log" > "$TMP/n44.out" 2>&1
n44_after="$(git -C "$n44/canon.git" rev-parse refs/heads/trunk)"
grep -qx 'push=refused-protected' "$TMP/n44.out"; rcn44a=$?
ck "N44a a fetch/push url DIVERGENCE cannot hide the push repository's landing branch — canon's trunk (its default) is refused (recorded: $(cat "$TMP/n44.out" 2>/dev/null | tr -d '\n'))" $rcn44a
[ "$n44_before" = "$n44_after" ]; rcn44b=$?
ck "N44b …and the landing branch did NOT move (${n44_before:0:8} before, ${n44_after:0:8} after) — this is the assertion that goes RED if the reads go back to remote.origin.url" $rcn44b
grep -q 'push target =' "$O/logs/pushurl.log"; rcn44c=$?
ck "N44c …and the log NAMES the repository every verdict below is about (the divergence was invisible before, which is why the damage could not be read after the fact)" $rcn44c
# ⛔ N44d — A push url set that is not EXACTLY one cannot be resolved to a single repository (review cycle
# 17, P2). Picking one would be the same guess, one level up, so it REFUSES and the refusal is MANUAL.
git -C "$n44/wk" remote set-url --push --add origin "$n44/mirror.git"
: > "$O/logs/pushurl2.log"
O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=trunk
  lane_end_push "pushurl2" "$3" "$2" trunk 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
  lane_end_next > "$4"
' _ "$GATE" "$n44/wt" "$O/logs/pushurl2.log" "$TMP/n44.next" > "$TMP/n44d.out" 2>&1
grep -qx 'push=refused-pushurl-divergent' "$TMP/n44d.out"; rcn44d=$?
ck "N44d …and TWO push urls refuse rather than picking one ($(cat "$TMP/n44d.out" 2>/dev/null | tr -d '\n'))" $rcn44d
[ "$n44_before" = "$(git -C "$n44/canon.git" rev-parse refs/heads/trunk)" ]; rcn44e=$?
ck "N44e …nothing was pushed anywhere by that refusal (canon's trunk still ${n44_before:0:8})" $rcn44e
case "$(cat "$TMP/n44.next" 2>/dev/null)" in MANUAL*"do NOT reap"*) rcn44f=0 ;; *) rcn44f=1 ;; esac
ck "N44f …and next= is MANUAL / do-not-reap, so a reclaimer is told to refuse that worktree [$(cut -c1-60 "$TMP/n44.next" 2>/dev/null)]" $rcn44f
git -C "$n44/wk" worktree remove --force "$n44/wt" 2>/dev/null
# ⛔ N44g — RESOLVING THE PUSH URL IS NOT ENOUGH, BECAUSE THE READ IS A FETCH (review cycle 18, P0 —
# REPRODUCED). `git ls-remote <url>` re-applies `url.<base>.insteadOf` ON TOP of the resolved push url; the
# push does not. So with `url.B.pushInsteadOf = A` and `url.C.insteadOf = B`, get-url answers B, the push
# writes B, and the READ answers C — the fix above went green on N44a/N44b and was still one rewrite hop
# short. THIS ARM FAILS IF THE PROOF GUARD IS REMOVED: without it B's landing branch moves.
n44g="$TMP/n44g"; mkdir -p "$n44g"
git init -q --bare "$n44g/A.git" && git init -q --bare "$n44g/B.git" && git init -q --bare "$n44g/C.git"
git -C "$n44g/A.git" symbolic-ref HEAD refs/heads/main
git -C "$n44g/B.git" symbolic-ref HEAD refs/heads/trunk
git -C "$n44g/C.git" symbolic-ref HEAD refs/heads/main
git init -q "$n44g/seed" && fixture_ident "$n44g/seed" && git -C "$n44g/seed" commit -q --allow-empty -m base && git -C "$n44g/seed" branch -M main
for r in A B C; do git -C "$n44g/seed" push -q "$n44g/$r.git" main:main; done
git -C "$n44g/seed" checkout -q -b trunk && git -C "$n44g/seed" commit -q --allow-empty -m t2
# trunk must be reachable through A too, so the WORKTREE can be created the ordinary way; A is not a
# rewrite target, so this fetch reaches the repository it names.
git -C "$n44g/seed" push -q "$n44g/A.git" trunk:trunk
git -C "$n44g/seed" push -q "$n44g/B.git" trunk:trunk && git -C "$n44g/seed" push -q "$n44g/C.git" trunk:trunk
rm -rf "$n44g/seed"
git clone -q "$n44g/A.git" "$n44g/wk" 2>/dev/null
fixture_ident "$n44g/wk"
git -C "$n44g/wk" config "url.$n44g/B.git.pushInsteadOf" "$n44g/A.git"
git -C "$n44g/wk" config "url.$n44g/C.git.insteadOf" "$n44g/B.git"
git -C "$n44g/wk" fetch -q origin trunk:trunk
git -C "$n44g/wk" worktree add -q "$n44g/wt" trunk
git -C "$n44g/wt" commit -q --allow-empty -m "a lane's unpushed work"
n44g_target="$(git -C "$n44g/wt" remote get-url --push origin)"
n44g_proof="$(git -C "$n44g/wt" ls-remote --get-url "$n44g_target")"
n44g_before="$(git -C "$n44g/B.git" rev-parse refs/heads/trunk 2>/dev/null)"
ck "N44g0 …the fixture really is chained AND real (push target ${n44g_target##*/}, fetch expansion ${n44g_proof##*/}, trunk $n44g_before — they must DIFFER, and trunk must be a 40-hex sha, or this arm cannot see the class)" "$([ "$n44g_target" != "$n44g_proof" ] && is_oid "$n44g_before" && echo 0 || echo 1)"
: > "$O/logs/chain.log"
O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=trunk
  lane_end_push "chain" "$3" "$2" trunk 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
  lane_end_next > "$4"
' _ "$GATE" "$n44g/wt" "$O/logs/chain.log" "$TMP/n44g.next" > "$TMP/n44g.out" 2>&1
grep -qx 'push=refused-pushurl-divergent' "$TMP/n44g.out"; rcn44g=$?
ck "N44g an insteadOf rewrite that separates the READ from the WRITE is refused, not read anyway ($(cat "$TMP/n44g.out" 2>/dev/null | tr -d '\n'))" $rcn44g
grep -q 'fetch-side expansion' "$O/logs/chain.log"; rcn44g2=$?
ck "N44g2 …and the log names BOTH endpoints, so the operator can see what separates them" $rcn44g2
[ "$n44g_before" = "$(git -C "$n44g/B.git" rev-parse refs/heads/trunk 2>/dev/null)" ]; rcn44g3=$?
ck "N44g3 …and the push target's LANDING BRANCH did not move (${n44g_before:0:8}) — the assertion that goes RED when the proof guard is removed" $rcn44g3
case "$(cat "$TMP/n44g.next" 2>/dev/null)" in MANUAL*"do NOT reap"*) rcn44g4=0 ;; *) rcn44g4=1 ;; esac
ck "N44g4 …and next= refuses the reclaim" $rcn44g4
git -C "$n44g/wk" worktree remove --force "$n44g/wt" 2>/dev/null
# ⛔ N44h — A MISSING `origin` IS NOT A DIVERGENCE (review cycle 18, P2 — REPRODUCED). It recorded
# `refused-pushurl-divergent (0 found: )` — an empty list in a durable artifact — and blamed a pushurl/
# pushInsteadOf divergence the repo does not have. A resolution that FAILED is its own cause with its own
# remedy.
n44h="$TMP/n44h"; mkdir -p "$n44h"
git init -q --bare "$n44h/only.git" && git -C "$n44h/only.git" symbolic-ref HEAD refs/heads/main
git init -q "$n44h/seed" && fixture_ident "$n44h/seed" && git -C "$n44h/seed" commit -q --allow-empty -m base && git -C "$n44h/seed" push -q "$n44h/only.git" HEAD:main && rm -rf "$n44h/seed"
git clone -q "$n44h/only.git" "$n44h/wk" 2>/dev/null
fixture_ident "$n44h/wk"
git -C "$n44h/wk" worktree add -q "$n44h/wt" -b lone 2>/dev/null
git -C "$n44h/wt" commit -q --allow-empty -m "a lane's unpushed work"
git -C "$n44h/wt" remote remove origin 2>/dev/null
: > "$O/logs/noorigin.log"
O="$O" bash -c '
  . "$1"
  LANE_END_TREE=unpushed-only; LANE_END_RESCUE=nothing
  LANE_END_ROOT="$2"; LANE_END_BRANCH=lone
  lane_end_push "noorigin" "$3" "$2" lone 1 1
  printf "push=%s\n" "$LANE_END_PUSH"
  lane_end_next > "$4"
' _ "$GATE" "$n44h/wt" "$O/logs/noorigin.log" "$TMP/n44h.next" > "$TMP/n44h.out" 2>&1
grep -qx 'push=refused-pushurl-unresolved' "$TMP/n44h.out"; rcn44h=$?
ck "N44h a checkout with NO origin records refused-pushurl-unresolved, not 'divergent' over an empty list ($(cat "$TMP/n44h.out" 2>/dev/null | tr -d '\n'))" $rcn44h
grep -q 'could NOT BE RESOLVED' "$O/logs/noorigin.log"; rcn44h2=$?
ck "N44h2 …and the log names the read that failed as the cause, so the remedy is not a config change that does not apply" $rcn44h2
case "$(cat "$TMP/n44h.next" 2>/dev/null)" in MANUAL*"do NOT reap"*) rcn44h3=0 ;; *) rcn44h3=1 ;; esac
ck "N44h3 …and next= still refuses the reclaim (fail-closed either way)" $rcn44h3
git -C "$n44h/wk" worktree remove --force "$n44h/wt" 2>/dev/null
# ⛔ N45 — NO `next=` SENTENCE MAY BE PRINTED TWICE, MANGLED, OR LEFT HALF-FILLED (review cycle 19, P1 —
# REPRODUCED). Inserting one more `%s` into a format without its argument (or the reverse) makes bash
# RE-RUN the whole format on the left-over arguments: the durable `next=` then carried the entire MANUAL
# sentence twice, with the push URL dropped into the `refs/heads/%s` slot (`refs/heads//srv/repo.git`) and
# the branch appended after "lane log". Two arms were in that state and NO arm asserted the shape of the
# output — the suite printed the corrupt line and stayed green.
# ⛔ AND IT DRIVES THE TREE DIMENSION TOO (review cycle 21, P2 — MEASURED). Review cycle 20's matrix pinned
# `LANE_END_TREE=dirty`, so the five TREE-driven arms (`not-a-worktree`, `not-measured`, `cannot-verify`,
# `unpushed-only`, the final `nothing at risk`) were never exercised, and in the `archived-local` reporter
# arms the ref/root checks were structurally inert — those sentences contain no `refs/heads/` and never say
# `reap `. Measured on a copy with the ref argument deleted from the `pushed` reporter: `BAD:[none]` over
# `retrieve the archive /tmp/wt (local pin only — no off-box copy) before removing deadbeef; the BRANCH is
# the good half (push=pushed, origin holds ), so only the uncommitted work is local-only` — every slot
# holding its neighbour's value and the sha slot empty, in the one sentence that is read before a reclaim.
# So the matrix is tree x push x rescue, and the reporter arms get their own positive substitutions.
# ⛔ AND ONE SENTENCE IS NOT ENOUGH TO ASSERT THE SHAPE OF A SENTENCE (review cycle 22, P2 — REPRODUCED).
# Asserting PRESENCE catches a shifted or empty slot; it cannot see a TRANSPOSITION, because both values
# are still somewhere in the string. Measured by swapping the root and origin arguments at the `pushed`
# reporter: `… before removing deadbeef; … origin holds /tmp/wt`, and pin-slot + sha-slot BOTH passed.
# Each sha-reporting shape therefore needs an adjacency anchor, because a presence test cannot tell
# which slot a value landed in. TWO of the three have one (`sha-transposed` for `origin holds <sha>`,
# `origin-at-transposed` for `origin at <sha> (<b>)`); the third, `holds refs/heads/<b> at <sha>`, does
# NOT need a new one, because a transposition there puts `deadbeef` into the ref slot and the existing
# `ref-slot` presence test reds it (measured: 20 cells). ⛔ `before removing ` is NOT an anchor either:
# 8 of the 450 cells contain it and 6 of those already name the root there, but the `tree measured dirty
# with rescue=nothing` arm names the root EARLIER in the sentence and then pronominalises it ("before
# removing it") — so pinning root-adjacency to that phrase would red 2 cells of that one correct arm
# while constraining 3 sentences. What catches a root in the sha slot is that the SHA is then missing
# from the slot's own introducer, which is what the adjacency anchors below test.
n45_sha=deadbeef
n45_bad=""; n45_all=""
for n45_tree in dirty cannot-verify unpushed-only not-a-worktree not-measured clean; do
# ⛔ ONE DEFINITION OF THE MATRIX'S PUSH DOMAIN, SO THE COMPLETENESS ARM BELOW CAN COMPARE AGAINST IT
# (review round 3, P1). It used to be inline in the `for`, which is why a 16th verdict could be added to
# `lane_end_push` and silently never exercised.
n45_push_domain="pushed nothing running unmeasured detached verify-unanswered push-unreported push-killed verify-ancestry-unmeasured verify-head-unreadable FAILED UNAVAILABLE refused-unknown-default refused-protected refused-main-checkout refused-pushurl-divergent refused-pushurl-unresolved"
  for n45_push in $n45_push_domain; do
    for n45_rescue in nothing FAILED UNAVAILABLE archived-local refs/wip/develop; do
      n45_out="$( bash -c '
        . "$1"
        LANE_END_TREE="$4"; LANE_END_RESCUE="$3"; LANE_END_PUSH="$2"
        LANE_END_UNPUSHED=1; LANE_END_ROOT=/tmp/wt; LANE_END_BRANCH=develop
        LANE_END_PUSH_URL=/srv/repo.git; LANE_END_REF=refs/wip/develop; LANE_END_ORIGIN="$5"
        LANE_END_HEAD="$5"
        lane_end_next' _ "$GATE" "$n45_push" "$n45_rescue" "$n45_tree" "$n45_sha" 2>/dev/null )"
      n45_cell="$n45_tree/$n45_push/$n45_rescue"
      n45_all="$n45_all$n45_out"$'\n'
      # 1. one sentence, not the same sentence twice (a SURPLUS argument re-runs the whole format).
      # ⛔ COUNTING THE WORD `MANUAL` IS NOT COUNTING THE SENTENCES (review cycle 22, P2 — REPRODUCED).
      # Seven of the ninety distinct sentences carry no `MANUAL` at all — the `retrieve the archive`
      # reporter arms, `recover the uncommitted state`, `nothing at risk`, `nothing to recover`, the
      # `tree measured dirty with rescue=nothing` arm and the clean-branch-push abstention — so for those
      # cells this check could not fire at all. ⛔ THREE OF THOSE SEVEN ARE TREE-ONLY, NOT ALL SEVEN:
      # `nothing at risk`, `nothing to recover` and the clean-branch-push abstention are reachable ONLY
      # through the tree dimension; the rest already ran at round 1's `LANE_END_TREE=dirty`. Which round
      # added an arm is not the point — a word-based count cannot see ANY sentence that lacks the word,
      # whichever matrix reached it. Measured: with one surplus argument added to the
      # `archived-local`/`pushed` reporter, and
      # separately to the final `nothing at risk` arm, the format re-ran and printed the sentence TWICE
      # while the `MANUAL` count, the `%s` search and both slot assertions stayed green. Every arm ends
      # its format in a single `\n`, so a re-run is always a SECOND LINE — the line count covers all of
      # them. The `MANUAL` count is kept because it names the specific defect when it fires.
      n45_lines="$(printf '%s' "$n45_out" | grep -c . )"
      [ "${n45_lines:-0}" -gt 1 ] && n45_bad="$n45_bad $n45_cell(x${n45_lines}-lines)"
      n45_n="$(printf '%s' "$n45_out" | grep -o 'MANUAL' | grep -c . )"
      [ "${n45_n:-0}" -gt 1 ] && n45_bad="$n45_bad $n45_cell(MANUALx$n45_n)"
      # 2. POSITIVE SUBSTITUTION, NOT A HUNT FOR ONE MANGLED PHRASE. bash fills a MISSING argument with
      # the empty string and warns about nothing (`printf 'a %s b %s\n' one` -> `a one b `), so an
      # unfilled specifier never leaves a literal `%s` and never yields `refs/heads//`. If the sentence
      # names a ref it must name the branch, if it names a remote read it must name the url the cell set,
      # if it names the reporter's archive it must name the pin, and if it reports what origin holds it
      # must report the sha. An empty slot, a URL in the ref slot, and a doubled value all fail these.
      case "$n45_out" in *'refs/heads/'*) case "$n45_out" in *'refs/heads/develop'*) : ;; *) n45_bad="$n45_bad $n45_cell(ref-slot)" ;; esac ;; esac
      case "$n45_out" in *'--heads '*) case "$n45_out" in *'--heads /srv/repo.git'*) : ;; *) n45_bad="$n45_bad $n45_cell(url-slot)" ;; esac ;; esac
      case "$n45_out" in *'retrieve the archive '*) case "$n45_out" in *'retrieve the archive refs/wip/develop'*) : ;; *) n45_bad="$n45_bad $n45_cell(pin-slot)" ;; esac ;; esac
      # ⛔ THE SHA SLOT'S ANCHORS ARE THE PHRASINGS THAT ACTUALLY REPORT ONE (review cycle 22, P2 —
      # MEASURED). This assertion was first written anchored on `origin holds refs/heads/`, which appears
      # ONLY in the `[lane-exit]` LOG echoes (spawn-gate.sh:1529,1545,1548) and NEVER in the `next=`
      # product: driven over all 450 cells (6 trees x 15 pushes x 5 rescues), 0 sentences contain it, so
      # the arm could not fire — a blind assertion, i.e. exactly the defect this matrix exists to remove.
      # It was corrected here, before it was ever committed, so no earlier commit on this branch carries
      # the inert form. The product reports an origin sha in THREE shapes, each with its own anchor:
      # `holds refs/heads/<b> at <sha>` (the answered-remote MANUAL arm), `origin at <sha> (<b>`
      # (unpushed-only), and `origin holds <sha>` (the archived-local reporter). MEASURED over the 90
      # distinct sentences: 8 carry the sha behind `holds refs/heads/`, 1 behind `origin at `, 1 behind
      # `origin holds `. And `origin holds ` ALSO prefixes TWO ABSTAINING arms that report no sha BY
      # DESIGN — `origin holds the commit(s)` (verify-unanswered) and `origin holds for <b>`
      # (push-unreported), 8 sentences each — so those are excluded FIRST: a test that reds the truth is
      # as broken as one that passes a lie.
      case "$n45_out" in
        *'origin holds the '*|*'origin holds for '*) : ;;
        *'holds refs/heads/'*|*'origin at '*|*'origin holds '*)
          case "$n45_out" in *"$n45_sha"*) : ;; *) n45_bad="$n45_bad $n45_cell(sha-slot)" ;; esac ;;
      esac
      # ADJACENCY — the only thing that separates a correct slot from a TRANSPOSED one (see the header).
      # TWO of the three sha-reporting shapes are anchored here; the third (`holds refs/heads/…`) is
      # caught by the `ref-slot` presence test above, because a transposition puts the sha in the ref slot.
      # ⛔ `origin at ` IS THE SECOND AND NEEDED ITS OWN (review cycle 23, P3 — REPRODUCED). `sha-slot`
      # passes a transposition here because the sha is still PRESENT: swapping the two arguments at the
      # unpushed-only sentence renders `origin at develop (deadbeef)` and measured `bad:[none]` over all
      # 450 cells. `origin at ` occurs only in that one arm, so the anchor cannot red another.
      case "$n45_out" in
        *'origin holds '*)
          case "$n45_out" in
            *'origin holds the '*|*'origin holds for '*) : ;;
            *'origin holds '"$n45_sha"*) : ;;
            *) n45_bad="$n45_bad $n45_cell(sha-transposed)" ;;
          esac ;;
      esac
      case "$n45_out" in
        *'origin at '*) case "$n45_out" in *'origin at '"$n45_sha"' '*) : ;; *) n45_bad="$n45_bad $n45_cell(origin-at-transposed)" ;; esac ;;
      esac
      # ⛔ THE `git -C` SLOT THIS BRANCH NAMES IS A SLOT TOO (review cycle 23, P3 — REPRODUCED). The
      # `unmeasured` remedy names the root and then the enumeration's tail, and NEITHER was asserted:
      # dropping the root argument renders `git -C  rev-list …` and transposing the two renders
      # `git -C develop … origin//tmp/wt..HEAD`, both measured `bad:[none]` with the rescue and tree
      # caveats swallowed.
      # ⛔ AND "AT MOST ONCE PER SENTENCE" IS FALSE FOR THE ARM ADDED IN ROUND 3 (review round 4, P1 —
      # REPRODUCED): `verify-ancestry-unmeasured` names `git -C` TWICE (the `fetch` and the `merge-base`),
      # so asserting only that EVERY `git -C ` is followed by the root let the SECOND one be emptied
      # undetected — deleting one argument left the suite at 217 passed while the sentence rendered
      # `… then git -C  — AND the uncommitted work … merge-base --is-ancestor  FETCH_HEAD`, i.e. an empty
      # root slot, the caveat spliced into the middle of the command, and an empty ancestry sha. So the
      # assertion is now on the COUNT of root-bearing occurrences matching the count of `git -C ` in the
      # sentence, which covers both arms without hard-coding either number.
      n45_gitc="$(printf '%s' "$n45_out" | grep -o 'git -C ' | wc -l | tr -d ' ')"
      n45_gitroot="$(printf '%s' "$n45_out" | grep -o 'git -C /tmp/wt ' | wc -l | tr -d ' ')"
      [ "${n45_gitc:-0}" = "${n45_gitroot:-0}" ] || n45_bad="$n45_bad $n45_cell(gitroot-slot)"
      # …and the ancestry REMEDY's own two slots, which the count check alone cannot see (an emptied
      # ancestry sha still leaves every `git -C ` root-bearing).
      case "$n45_out" in
        *'merge-base --is-ancestor '*) case "$n45_out" in *'merge-base --is-ancestor '"$n45_sha"' FETCH_HEAD'*) : ;; *) n45_bad="$n45_bad $n45_cell(ancestry-slot)" ;; esac ;;
      esac
      case "$n45_out" in *'git -C '*) case "$n45_out" in *'git -C /tmp/wt '*) : ;; *) n45_bad="$n45_bad $n45_cell(gitroot-slot)" ;; esac ;; esac
      case "$n45_out" in *'read it yourself'*) case "$n45_out" in *'rev-list --count HEAD --not --remotes'*) : ;; *) n45_bad="$n45_bad $n45_cell(enum-trap)" ;; esac ;; esac
      # ⛔ THE CAVEAT UNION ARGUMENT IS A SLOT TOO, AND NOTHING ASSERTED IT (review cycle 24, P3 —
      # REPRODUCED). `push=unmeasured` + `rescue=FAILED` renders the rescue caveat, but DELETING that one
      # union argument leaves the sentence intact — 5 specifiers, 4 arguments, so bash does NOT re-run the
      # format — and the matrix reported `bad:[none]` while the suite stayed at 200 passed. The other
      # domain's MANUAL fact vanished silently, which is the rule this file states four separate times.
      # ⛔ THE INVERSE IS FALSE AND IS DELIBERATELY NOT ASSERTED: "every MANUAL arm must carry both
      # caveats" was measured WRONG — 138 distinct cells legitimately omit them (142 requirement
      # failures: 4 cells miss BOTH the rescue and the tree caveat), because their arms return above
      # the caveat mechanism (and `not-a-worktree` / `not-measured` return above this arm entirely, so
      # they never emit the phrase below at all). The anchor is therefore this arm's OWN phrase, and only
      # the caveat for the value THAT CELL set is required.
      case "$n45_out" in *'could NOT be read (push=unmeasured)'*)
        case "$n45_rescue" in
          # ⛔ FAILED AND UNAVAILABLE ARE DIFFERENT FACTS (P1 — REPRODUCED). They shared one
          # sentence, and for UNAVAILABLE it claimed "an archive may exist at refs/wip/<slug>" when
          # the callee NEVER RAN (tool not found / not a worktree root) — impossible, not merely
          # unmeasured, and contradicted by the same terminal's own [wip] line. Each now has its own.
          FAILED) case "$n45_out" in *"no ref this run wrote pins the uncommitted work at "*'compare that sha before deciding'*) : ;; *) n45_bad="$n45_bad $n45_cell(rescue-caveat)" ;; esac ;;
          UNAVAILABLE) case "$n45_out" in *'the rescue NEVER RAN'*) : ;; *) n45_bad="$n45_bad $n45_cell(rescue-caveat)" ;; esac
            # ⛔ AND IT MUST SCOPE THAT TO THE ARCHIVE (P1 — REPRODUCED): the rescue runs AFTER the
            # branch push, so `push=verify-*|push-killed` + `rescue=UNAVAILABLE` is reachable and those
            # arms have MEASURED a push — an unscoped "pushed nothing" puts two contradicting
            # measurements in one terminal (the D4b shape). The branch must be named as a SEPARATE
            # measurement, and the unmeasured provenance claim ("PREDATES this run") must be gone.
            case "$n45_out" in *'pushed nothing to refs/wip/<slug>'*) : ;; *) n45_bad="$n45_bad $n45_cell(rescue-caveat-scope)" ;; esac
            case "$n45_out" in *'was NOT written by this run'*) : ;; *) n45_bad="$n45_bad $n45_cell(rescue-caveat-predate)" ;; esac
            case "$n45_out" in *'PREDATES this run'*) n45_bad="$n45_bad $n45_cell(rescue-caveat-provenance)" ;; *) : ;; esac ;;
          archived-local) case "$n45_out" in *'archived to the LOCAL pin'*) : ;; *) n45_bad="$n45_bad $n45_cell(rescue-caveat)" ;; esac ;;
        esac
        case "$n45_tree" in
          cannot-verify) case "$n45_out" in *'NOT PROVEN complete'*) : ;; *) n45_bad="$n45_bad $n45_cell(tree-caveat)" ;; esac ;;
        esac ;;
      esac
      # ⛔ THE TWO NEGATIVE SHAPES ARE KEPT, NOT DROPPED (review cycle 22, P3). Neither fires on today's
      # product (0 of the 90 sentences match), so nothing measurable was lost when they fell out of the
      # rewrite — but an EMPTY root in a `reap`/`before removing` arm and an EMPTY push verdict are
      # defects a future arm can reintroduce, and dropping a guard without saying so is how a suite
      # quietly narrows. They are cheap, they are arm-agnostic, and they stay. ⛔ AND THE `before
      # removing` HALF WAS NOT ACTUALLY COVERED (review cycle 24, P3 — REPRODUCED): the pattern named only
      # `reap`, so emptying the root at the `pushed` reporter's `before removing %s` rendered `… before
      # removing ; the BRANCH is the good half …` with the matrix at `bad:[none]`. The empty forms of
      # both phrases are now matched, which is what this comment always claimed.
      case "$n45_out" in *'reap  '*|*'reap `'*|*'before removing ;'*|*'before removing `'*) n45_bad="$n45_bad $n45_cell(root-slot)" ;; esac
      case "$n45_out" in *'push=)'*|*'push=,'*|*'push= '*) n45_bad="$n45_bad $n45_cell(empty-verdict)" ;; esac
      case "$n45_out" in *'%s'*) n45_bad="$n45_bad $n45_cell(unfilled-specifier)" ;; esac
      # ⛔ "no off-box copy" IS NOT A CLAIM THIS CODE CAN MAKE, IN ANY CELL (P1 — REPRODUCED). The phrase
      # stood in `lane_end_rescue_caveat`'s `archived-local` arm AND in the `cannot-verify` arm's nested copy
      # of it, and it is FALSE whenever the rescue was a PARTIAL archive whose push SUCCEEDED — the exact
      # `rc2 != 0` + new-pin shape that IS `archived-local`. Fixing one site and leaving the other is the
      # standard way this class returns, so the ban is arm-agnostic and sweeps the whole matrix instead of
      # the two sites that held it: a `refs/wip/<slug>` copy this row cannot NAME is still a copy, and a
      # terminal that denies it sends the operator to the wrong place to look.
      case "$n45_out" in *'no off-box copy'*) n45_bad="$n45_bad $n45_cell(offbox-absence-claim)" ;; esac
    done
  done
done
ck "N45 every tree x push x rescue cell produces ONE well-formed next= sentence — no duplicated sentence, no empty or misfilled slot, no unfilled specifier [bad:${n45_bad:-none}]" "$([ -z "$n45_bad" ] && echo 0 || echo 1)"
# ⛔ N45b — AND THE MATRIX MUST NOT BE VACUOUS (review cycle 20, P2). An arm that drives hundreds of cells
# which all fall into ONE sentence proves nothing about the others. The distinct-sentence count is the
# non-vacuity floor: below it, verdicts have stopped reaching their own arms (a reorder, or a missing case).
n45_bad2=0
n45_distinct="$(printf '%s\n' "$n45_all" 2>/dev/null | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
[ "${n45_distinct:-0}" -ge 20 ] || n45_bad2=1
ck "N45b …and the matrix really reaches distinct arms (${n45_distinct:-0} distinct next= sentences, floor 20) — a floor below 1 would make N45 vacuous" $n45_bad2
# ⛔ N45c — THE MATRIX'S OWN DOMAIN LIST MUST TRACK THE CODE (review round 3, P1 — REPRODUCED). The push
# list above is a HARDCODED 15-value enumeration, and `verify-ancestry-unmeasured` was added to
# `lane_end_push` without being added to it — so the new arm's `%s` slots, format re-runs and specifier
# counts were asserted by NOTHING: deleting an argument from the new arm's printf left the matrix green
# while the sentence rendered the root into the sha slot and an empty sha into the `git -C` slot. That is
# precisely the class this matrix exists to catch, defeated by a list nobody re-derived. So the domain is
# now DERIVED from the source and every assigned value must appear in the list.
n45_derived="$(grep -o 'LANE_END_PUSH="[^"$][^"]*"' "$GATE" 2>/dev/null | sed 's/.*="//; s/"$//' | sort -u)"
n45_missing=""
for n45_v in $n45_derived; do
  grep -q "\\b${n45_v}\\b" <<< "$n45_push_domain" 2>/dev/null || n45_missing="$n45_missing $n45_v"
done
[ -z "$n45_missing" ] && [ -n "$n45_derived" ] && [ "$(printf '%s\n' $n45_derived | wc -l | tr -d ' ')" -ge 16 ]; n45_bad3=$?
ck "N45c …and every push verdict the CODE can assign is in the matrix's list, derived from source (${n45_derived_count:-$(printf '%s\n' $n45_derived | wc -l | tr -d ' ')} values${n45_missing:+, MISSING:$n45_missing}) — so a new verdict cannot be forgotten the way this one was" $n45_bad3
echo

# ── PW1 THE WRITE AND THE READ-BACK DERIVE THE SAME REF (#3484) ───────────────────────────────────
# ⛔ THE DEFECT THIS WOULD HAVE CAUGHT. `bg-rescue-wip.sh` now names a ref after the ISSUE
# (`fix/4242-first-attempt` → `refs/wip/issue-4242-first-attempt`), but the exit path in `spawn-gate.sh`
# computed its own slug from the branch (`fix-4242-first-attempt`). The read-back would then name a ref
# nobody wrote: the lane-end ledger's `rescue=`/`ref=` columns would point at nothing while the real
# archive sat on origin — the exact "released and unrecorded" shape #3484 removes, one layer down. The
# slug now has ONE home (`bg-rescue-wip.sh --slug`), and this arm drives the real path on an
# ISSUE-NAMED branch to prove the two sides agree.
git -C "$WT" checkout -q -b fix/4242-first-attempt 2>/dev/null
git -C "$WT" push -q -u origin fix/4242-first-attempt 2>/dev/null
pi_stub dirty
: > "$O/logs/lane.log"
# ⛔ ALL FOUR DISK TERMS, NOT THREE (disk-admission.test.sh §I). With `DISK_LANE_SELF_MB` unstated the
# lane-headroom term defaults to this host's own cost (6144 MB), so on a host with free space between
# the 1 MB floor and that default the arm's subject becomes a DISK-NOHEADROOM refusal instead — the
# arm then measures the box, not the WIP rescue it exists for.
PATH="$TMP/bin:$PATH" PI_LOG="$O/pi.log" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_SELF_MB=0 DISK_LANE_RESERVE_MB=0 \
  drive "$GATE" 300 "issue-shaped" >/dev/null 2>&1
arm "$O/logs/lane.log"
PW_REF="$(git -C "$BARE" for-each-ref --format='%(refname)' 'refs/wip/*' 2>/dev/null | grep -c 'refs/wip/issue-4242-first-attempt$' || true)"
ck "PW1 an ISSUE-NAMED branch rescues to a ref that carries the issue (refs/wip/issue-4242-first-attempt)" \
   $([ "${PW_REF:-0}" = "1" ] && echo 0 || echo 1)
grep -q 'rescue=refs/wip/issue-4242-first-attempt' "$O/logs/lane.log"; rc=$?
ck "PW2 …and the exit path's OWN record names THAT ref — its read-back is not derived from a divergent copy" $rc
grep -q 'ref=refs/wip-local/issue-4242-first-attempt@' "$O/logs/lane.log"; rc=$?
ck "PW3 …including the local pin, so the ledger names a ref this run really wrote" $rc
grep -q 'ref=refs/wip-local/fix-4242-first-attempt@' "$O/logs/lane.log"; rc=$?
ck "PW4 NON-VACUITY: the exit path does NOT name the branch-mangled ref the old divergent copy produced" \
   $([ "$rc" -ne 0 ] && echo 0 || echo 1)

echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
