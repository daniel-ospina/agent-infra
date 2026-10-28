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
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

echo "==> wip-rescue-exit contract ($HERE)"

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
    O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
    KIND=lane; TAG=2834
    load1() { printf 1; }
    run_agent "$4" "$5" "$6" "$7" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$gate" "$WT" "$O" "$cap" "$O/logs/lane.log" "$PROMPT" "$label"
}
wiprefs() { git -C "$BARE" for-each-ref --format='%(refname)' 'refs/wip/*' 2>/dev/null; }

# ── A) THE DEFECT ITSELF: a lane that ends BEFORE its cap, with work in the tree ──────────────────
pi_stub dirty
: > "$O/logs/lane.log"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$O/pi.log" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 drive "$GATE" 300 "early exit")"
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
ck "A5 …and the append-only ledger state/lane-end.tsv holds the row (epoch, label, rc, cap, tree, rescue, ref, unpushed)" $rc

# ── B) NON-VACUITY: remove the exit-path call and the ref MUST be absent ──────────────────────────
# A copy of the shipped helper, mutated in exactly one place: the call. Everything else — the source,
# the cap path, the dirty pre-check — is the real file, so a green here would mean the CALL is what
# delivers the guarantee.
MUT="$TMP/mut"; mkdir -p "$MUT"
grep -v '^  terminal_wip_rescue "\$label"' "$GATE" > "$MUT/spawn-gate.sh"
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
  run_agent 300 "$4" "$5" "mutant" >/dev/null 2>&1
  printf "rc=%s" "$?"
' _ "$MUT/spawn-gate.sh" "$WT" "$O" "$O/logs/mut.log" "$PROMPT")"
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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "clean exit" >/dev/null 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$WT" "$O" "$O/logs/clean.log" "$PROMPT")"
after="$(wiprefs | wc -l | tr -d ' ')"
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
  O="$3"; MAX_LOAD=999999999; DISK_MIN_FREE_MB=1; DISK_LANE_TREE_MB=0; DISK_LANE_RESERVE_MB=0
  KIND=lane; TAG=2834
  load1() { printf 1; }
  run_agent 300 "$4" "$5" "unpushed exit" >/dev/null 2>&1
' _ "$GATE" "$WT" "$O" "$O/logs/unpushed.log" "$PROMPT"
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
' _ "$ISO/harness/spawn-gate.sh" "$WT" "$ISO/harness/O/lane.log" 2>/dev/null; rc=$?
grep -q 'rescue=UNAVAILABLE' "$ISO/harness/O/lane.log"; rcu=$?
grep -q 'NOT FOUND' "$ISO/harness/O/lane.log"; rcf=$?
ck "E1 a missing bg-rescue-wip.sh is reported as rescue=UNAVAILABLE with the searched homes — never 'nothing to rescue'" $([ "$rcu" -eq 0 ] && [ "$rcf" -eq 0 ] && echo 0 || echo 1)
ck "E2 …and the rescue never changes the lane's exit status (the function returned $rc)" $([ "$rc" -eq 0 ] && echo 0 || echo 1)
rm -f "$WT/orphan.txt"

# ── F) A MIS-POINTED WIP_PATH IS NOT A CLEAN TREE ────────────────────────────────────────────────
# fix-one.sh `cd`s into the MAIN checkout and passes WIP_PATH=<the fixer's worktree>; a caller that
# forgets it would have the rescue read the wrong tree. Not-a-worktree must be its own verdict, and it
# must not be reachable as "clean".
mkdir -p "$TMP/notgit"
: > "$O/logs/notgit.log"
O="$O" WIP_PATH="$TMP/notgit" bash -c '
  . "$1"
  terminal_wip_rescue "mis-pointed" 0 0 "$2"
' _ "$GATE" "$O/logs/notgit.log" 2>/dev/null
grep -q 'tree=not-a-worktree rescue=UNAVAILABLE' "$O/logs/notgit.log"; rc=$?
ck "F1 a WIP_PATH that is not a git worktree is tree=not-a-worktree, never a clean verdict" $rc
grep -q 'the worktree was CLEAN\|nothing was lost' "$O/logs/notgit.log"; rcc=$?
ck "F2 …and it never claims the tree was clean" $([ "$rcc" -ne 0 ] && echo 0 || echo 1)

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
    run_agent 1 "$4" "$5" "$6" >/dev/null 2>&1
    printf "rc=%s" "$?"
  ' _ "$GATE" "$WT" "$O" "$2" "$PROMPT" "$1"
}
pi_stub sleepdirty
: > "$O/logs/cap.log"
rm -f "$WT/capdirty.txt"
res="$(drive_cap "cap exit" "$O/logs/cap.log")"
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
grep -q 'STILL ONLY ON THIS DISK' "$O/logs/capfail.log"; rcfail=$?
ck "G4 …and the failing rescue is LOUD: it names the worktree as the only copy" $rcfail
grep -q 'rescue=DISABLED' "$O/logs/capoff.log"; rcdis=$?
ck "G5 …and the operator hatch (WIP_RESCUE_DISABLE=1) says the tree was NOT examined instead of implying it was clean" $rcdis
git -C "$WT" config --unset-all url."$TMP/not-a-repo.git".insteadOf
git -C "$WT" config url."$BARE".insteadOf "$GHURL"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
