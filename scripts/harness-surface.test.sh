#!/usr/bin/env bash
# harness-surface.test.sh — the four proofs the ONE launcher owes, each one RED on the tree that
# shipped before it. Every assertion drives the SHIPPED `scripts/harness-up` (and the SHIPPED shim
# block, extracted by its own `>>> shim` markers) — a re-implementation would pass on the broken copy.
#
#   (a) STATUS IS RED WHEN THE EXECUTED SHA IS NOT THE PIN, GREEN WHEN IT IS.
#       The `exec` row reads the RUNNING controller's argv, resolves the tree that path lives in and
#       compares its COMMIT with the pin. Green: a worktree at the pinned commit -> HEALTHY. Red: the
#       same box with the controller executing an OLDER tree (the restart-pending state a pin advance
#       legitimately creates) -> DEGRADED, both shas named. Nothing on the pre-change screen could see
#       the difference: every other row reads a record or the CONFIGURED dir.
#
#   (b) `up` TWICE LEAVES ONE CONTROLLER, AND THE SECOND RUN IS A NO-OP — NOT A RESTART.
#       The authority stub refuses a second start exactly as `orchestrator-bringup.sh` does, so the old
#       code's second `up` called it again and reported FAILED on a healthy box. The assertions are
#       BOTH halves: one controller, and the authority invoked ONCE with the second run saying
#       ALREADY UP. (A count alone would pass on the old tree — the refusal also left one controller.)
#
#   (c) THE CAPACITY DECISION IS A MEASUREMENT, AND IT REFUSES A FIXED-CAP ANSWER.
#       The lane ceiling comes from load and free disk read at the moment of the decision, printed with
#       the numbers. A configured fixed cap is REPORTED AND IGNORED as a ceiling; when the box cannot
#       be measured the decision REFUSES (and `up` refuses with it) rather than substituting the cap.
#
#   (d) THE macOS ARM IS EXERCISED, NOT TRUSTED. `HARNESS_UP_OS=Darwin` plus BSD-shaped stubs
#       (`mktemp` that REQUIRES a template, `sysctl vm.loadavg`, `launchctl print`, BSD `stat`) drive
#       the shim and a full `status` run. The pre-change tree dies here: `mktemp -d` with no template
#       is a usage error on macOS, so every Apple run failed at its last line while Linux stayed green.
#
# Hermetic: fixture repos, throwaway HOME/CELL_HOME, stubbed tools, no network, no real process read.
set -u
# ⛔ THE AMBIENT ENVIRONMENT IS NOT THIS SUITE'S INPUT — start from known-empty inputs. `harness-up`
# now PREFERS the caller's `REPO` (the WORK repo) over `--repo` (the HARNESS checkout), which is the
# whole point of #2356, so a fixture that passes only `--repo` inherits whatever the shell exports. A
# fleet shell exports `REPO=<its work repo>`, and a shell that sourced a cell's `keys.env` (a documented
# knob, harness-up's ENV_FILE) brings `REPO` in through the config seam instead. Without this the suite
# grades the ambient value: measured on this tree, `REPO=<a dir that is not a checkout>` -> **52 of 91
# assertions fail**, `ENV_FILE=<a file naming that dir>` -> **52 fail**, `HARNESS_PIN=<a bogus path>` ->
# **12**, `O=<a bogus dir>` -> **8** — every one of them for a reason that is not this code, against a
# header that claims hermeticity. That is a false RED the next reader attributes to the launcher, and
# it also lets an arm pass for the wrong reason. The capacity and selftest/OS knobs are ambient too —
# `HARNESS_UP_SELFTESTS=<bogus>` -> **12 fail**, `HARNESS_UP_OS=Darwin` -> **6**, `HU_LOAD_PER_CPU=1` or
# `HU_LOAD_PER_LANE=1` -> **3** each — and every fixture depends on their DEFAULTS, so they are cleared
# as well; arms that exercise them set them per-command (`HARNESS_UP_OS=Darwin` in (d)).
# ⛔ AND THE HARNESS-SIDE KNOBS ARE AMBIENT TOO — the sibling suite clears exactly these and says why
# (`harness-cohesion.test.sh`: `HARNESS_REF` in particular is a value a real cell shell carries).
# Clearing only the work-repo knobs was an over-claim: measured, `HARNESS_REF=origin/nope` -> **2
# failed** here, both of them this suite's own (e) assertions — the same false RED the block above
# exists to remove, one knob over.
# Fixtures that need a work repo set it explicitly (`REPO="$WORK"` in (e)); (a)-(d) pass `--repo` and
# want the launcher's own fallback answer.
unset REPO HARNESS_REPO ENV_FILE HARNESS_PIN O HARNESS_UP_SELFTESTS HARNESS_UP_OS HU_LOAD_PER_CPU HU_LOAD_PER_LANE \
      HARNESS HARNESS_REF HARNESS_PIN_DIR HARNESS_PIN_FILE
# ⛔ THE BOX'S DISK IS NOT THIS SUITE'S INPUT EITHER: `df` is stubbed below ($TMP/df, 20000MB) so the disk
# leg of the capacity decision is deterministic AND live — one arm makes it the binding leg on purpose.
# The helpers pass the two knobs explicitly (an ambient `export` cannot reach them) and default to the
# launcher's own values (500/1100), so the arms grade the RULE, not this box's free space.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/harness-up"
fails=0
assertions=0
ck() { # <name> <0|1>
  assertions=$((assertions + 1))
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
# ⛔ A BSD `mktemp` REQUIRES A TEMPLATE — the platform fact this suite exists to keep exercised. The
# suite passes one so that it runs on both platforms; the LAUNCHER's own call is what (d) tests.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-surface.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── the fixture repo: two commits, an old worktree, and a harness at each ──────────────────────
REPO_FIX="$TMP/repo"
mkdir -p "$REPO_FIX/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho loop\n' > "$REPO_FIX/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env bash\necho claims\n' > "$REPO_FIX/scripts/orchestrator-harness/claims.sh"
( cd "$REPO_FIX" && git init -q -b main . && git add scripts/orchestrator-harness \
  && git -c user.email=t@example.com -c user.name=t commit -qm A \
  && git update-ref refs/remotes/origin/main refs/heads/main \
  && git remote add origin "$REPO_FIX" ) >/dev/null 2>&1
SHA_A="$(cd "$REPO_FIX" && git rev-parse HEAD)"
# …the OLD tree: a linked worktree at A, which is what a controller left behind by a pin advance runs.
OLD="$TMP/old-tree"
( cd "$REPO_FIX" && git worktree add -q --detach "$OLD" "$SHA_A" ) >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho loop\n' > "$REPO_FIX/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env bash\necho fix\n' >> "$REPO_FIX/scripts/orchestrator-harness/claims.sh"
( cd "$REPO_FIX" && git add -A scripts/orchestrator-harness \
  && git -c user.email=t@example.com -c user.name=t commit -qm B \
  && git update-ref refs/remotes/origin/main refs/heads/main ) >/dev/null 2>&1
SHA_B="$(cd "$REPO_FIX" && git rev-parse HEAD)"
A12="${SHA_A:0:12}"; B12="${SHA_B:0:12}"

# The PIN: commit B, materialised under the pin root in the shape `hu_verify_pin` requires.
CELL="$TMP/cell"
PINROOT="$CELL/harness"
( cd "$REPO_FIX" && git worktree add -q --detach "$PINROOT/$B12" "$SHA_B" ) >/dev/null 2>&1
PIN_TREE="$PINROOT/$B12/scripts/orchestrator-harness"
mkdir -p "$PINROOT/$B12/scripts/orchestrator-harness" "$CELL/.pi/agent/state" "$CELL/orchestrator/state" "$CELL/orchestrator/logs"
[ -f "$PIN_TREE/orch-loop.sh" ] || cp "$REPO_FIX/scripts/orchestrator-harness"/*.sh "$PIN_TREE/" 2>/dev/null
printf '%s\n' "$SHA_B" > "$CELL/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$PIN_TREE" > "$CELL/.harness-path"
printf 'relation=current running=%s ref=%s pin=%s action=none fetch=ok rc=0 at=%s\n' \
  "$B12" "$B12" "$B12" "$(date +%s)" > "$CELL/orchestrator/state/harness-refresh"
printf 'claims=reachable at=%s\n' "$(date +%s)" > "$CELL/orchestrator/state/harness-claims"
: > "$CELL/orchestrator/heartbeat"
# A harness dir carrying what the launcher delegates to (stubs: this suite tests the LAUNCHER).
for d in "$PIN_TREE" "$OLD/scripts/orchestrator-harness"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/check-deployed-drift.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/selftest.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/check-single-source.sh"
  printf '#!/usr/bin/env bash\nprintf "harness relation=current running=x ref=y pin=z action=none fetch=ok\\n"\nexit 0\n' > "$d/harness-refresh.sh"
  chmod +x "$d"/*.sh 2>/dev/null
done

# The process table seam (`HU_PS`): `-eo` answers the whole table, `-p <pid> -o command=` one process.
cat > "$TMP/ps-probe" <<'SH'
#!/bin/sh
case "$*" in
  *-p\ *|*-p=*) pid=""
    while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
    [ -n "${PS_P_EMPTY:-}" ] && exit 0
    [ -n "$pid" ] && awk -v p="$pid" '$1==p { sub(/^[^ ]+ +/, ""); print; exit }' "$PS_TABLE" 2>/dev/null ;;
  *) cat "$PS_TABLE" 2>/dev/null ;;
esac
exit 0
SH
chmod +x "$TMP/ps-probe"
# ⛔ A TABLE WITH ONE UNRELATED PROCESS, NOT AN EMPTY FILE: an empty census is UNREADABLE to `hu_pids`
# (a real `ps` always lists itself), and an unreadable census is a different case from "no controller".
printf '1 launchd\n9 bash /usr/bin/unrelated.sh\n' > "$TMP/ps-none"
# tmux: the cell's supervisor row reads a SESSION, so it is stubbed to answer "present".
printf '#!/bin/sh\nexit 0\n' > "$TMP/tmux"
# ⛔ THE BOX'S DISK IS NOT THIS SUITE'S INPUT — a FIXTURE is. The capacity row reads the volume the STATE
# DIR lives on (`hp_disk_free_mb` → `df -Pk`), and a suite cannot change how much disk this machine has:
# measured at 94% full (`disk_free=8100MB`), the (c) ceiling arms asserted 7 lanes against a disk bound of
# `(8100-500)/1100 = 6` and went **2 red** for a reason that is not the code — the false-RED class the
# header exists to remove. A fixed `df` makes the disk leg BOTH hermetic and live: the default arms answer
# 20000MB (disk non-binding at 1100MB/lane → 17), and one arm below makes it the BINDING leg on purpose,
# so a regression that ignores free disk is caught rather than masked. (A top-level `export` of the two
# knobs cannot do this: both capacity helpers re-set them per-command.)
cat > "$TMP/df" <<'SH'
#!/bin/sh
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' '/dev/fixture 100000000 1 20480000 1% /'
SH
chmod +x "$TMP/df"; chmod +x "$TMP/tmux"
# A load fixture: `HU_LOADAVG_FILE` is the seam (a suite cannot change the box's load).
printf '4.00 1.00 0.50 1/100 4242\n' > "$TMP/load"

# ── THE WORK REPO FIXTURE: a checkout that does NOT contain the pin commit ───────────────────────
# #2356: the harness repo and the work repo are two different things, and on a cell they are two
# different PATHS. Every arm that proves the split needs a repo that is a real checkout, is NOT the
# harness, and cannot resolve the pin commit — so it is built here, before the arms that use it.
WORK="$TMP/work"
mkdir -p "$WORK"
( cd "$WORK" && git init -q -b main . \
  && printf 'x\n' > README && git add README \
  && git -c user.email=t@example.com -c user.name=t commit -qm work \
  && git update-ref refs/remotes/origin/main refs/heads/main \
  && git remote add origin "$WORK" ) >/dev/null 2>&1

run_status() { # <harness-dir>; knobs via the exported shell vars read below
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
          REPO="${REPV:-}" \
          HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="${PS_TABLE:-$TMP/ps-none}" \
          HU_LOADAVG_FILE="${LOADFILE-$TMP/load}" HU_NCPU="${NCPUV:-4}" \
          HARNESS_UP_MAX_LANES="${MAXL:-}" HARNESS_UP_OS="${OSV:-}" \
          HU_DISK_FLOOR_MB="${DISKFLOOR:-500}" HU_DISK_PER_LANE_MB="${DISKCOST:-1100}" \
          bash "$UP" status --repo "$REPO_FIX" --harness "$1" --no-fetch 2>&1 )"
  RC=$?
}

# ══ (a) THE EXEC ROW: RED when the executed sha is not the pin, GREEN when it is ════════════════
# GREEN: the controller executes the PIN's worktree (B), so the screen agrees with itself.
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/cloud-cell-doctor.sh\n' "$PIN_TREE" "$PIN_TREE" > "$TMP/ps-pinned"
PS_TABLE="$TMP/ps-pinned" run_status "$PIN_TREE"
ck "(a) GREEN control: controller on the PIN's tree is HEALTHY (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
case "$OUT" in
  *"exec"*"OK (executing $PIN_TREE/orch-loop.sh @ $B12"*) ck "(a) GREEN: the exec row names the resolved path AND the sha it executes" 0 ;;
  *) ck "(a) GREEN: the exec row names the resolved path AND the sha it executes [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-200)]" 1 ;;
esac
case "$OUT" in *"VERDICT: HEALTHY"*) ck "(a) GREEN: the verdict is HEALTHY" 0 ;; *) ck "(a) GREEN: the verdict is HEALTHY [$(printf '%s' "$OUT" | grep '^VERDICT')]" 1 ;; esac

# RED: the SAME box, one fact changed — the controller executes the OLD tree (A) while the pin is B.
# This is the real restart-pending state a pin advance creates (#2216/#2278), and the state the screen
# reported OK about before this row existed.
# ⛔ WITH A WORK REPO IN THE SHELL. `merge-base --is-ancestor` is a HARNESS-repo question: asked of the
# work repo (the conflation #2356 removes) the harness objects are simply absent, so every real BEHIND
# degrades to "NOT on the reference's line" and names the wrong remedy. Reverting that one `-C "$HREPO"`
# left this arm green while `REPV` was unset (measured), so the arm now carries a foreign work repo.
printf '4242 bash %s/scripts/orchestrator-harness/orch-loop.sh\n4243 bash %s/scripts/orchestrator-harness/cloud-cell-doctor.sh\n' "$OLD" "$OLD" > "$TMP/ps-old"
PS_TABLE="$TMP/ps-old" REPV="$WORK" run_status "$OLD/scripts/orchestrator-harness"
ck "(a) RED control: a controller executing a tree that is NOT the pin is DEGRADED (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in *"VERDICT: HEALTHY"*) ck "(a) RED: the verdict is NOT HEALTHY" 1 ;; *) ck "(a) RED: the verdict is NOT HEALTHY" 0 ;; esac
case "$OUT" in
  *"exec"*"DIFFERS"*"$A12"*"$B12"*) ck "(a) RED: the exec row says DIFFERS and names BOTH shas ($A12 vs $B12)" 0 ;;
  *) ck "(a) RED: the exec row says DIFFERS and names BOTH shas ($A12 vs $B12) [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
case "$OUT" in
  *"exec"*"BEHIND"*) ck "(a) RED: the row says WHICH disagreement it is (BEHIND — one restart away)" 0 ;;
  *) ck "(a) RED: the row says WHICH disagreement it is (BEHIND — one restart away) [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
# ⛔ THE RESTART-PENDING ANCESTRY TEST IS A HARNESS-REPO QUESTION TOO (review round 5, P2). Same box,
# same two commits: `merge-base --is-ancestor "$got_head" "$sha"` decides between "restart-pending —
# the pin is an ancestor of the tree being read, this start will materialise it" and "MISMATCH …
# refusing". Asked of the WORK repo — the conflation #2356 removes — the harness objects are absent,
# the ancestry answers NO, and a CORRECT pin is refused with the wrong remedy: #2356's own symptom on
# the restart-pending branch. Measured (review round 5): with `scripts/harness-up:709` reverted to
# `-C "$REPO"` the pin line flips to `pin: MISMATCH` and the suite stayed at 0 failed, so this pair is
# the only thing that makes that one site discriminating. The VERDICT line is matched, never the whole
# screen: `pin: commit <sha> (from …), pin root …` also starts with `pin: `.
pin_line="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]*pin: (restart-pending|MISMATCH)' | head -1)"
ck "(a) RED: the pin resolve calls an ANCESTOR tree restart-pending, decided in the HARNESS repo [$pin_line]" \
   "$(case "$pin_line" in *'pin: restart-pending'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(a) RED: …and it is NOT refused as a MISMATCH (what a wrong-repo ancestry test answers)" \
   "$(case "$pin_line" in *'pin: MISMATCH'*) echo 1 ;; *) echo 0 ;; esac)"

# ⛔ AND THE MAC'S REAL LAYOUT IS NOT A GIT WORKTREE. `install.sh` deploys a FLAT COPY into `$O` and
# the plist execs `__O__/orch-loop.sh` (launchd.plist.template:10, install.sh:26), so `git -C` on that
# dir answers NOTHING. Three wrong answers were tried and rejected in two review rounds: `DIFFERS`
# (asserts the code IS different — nobody established that), `BROKEN`(2) (honest but makes `up` exit 2
# AFTER a successful start on the owner's own machine), `SKIPPED` (hides the state #2271 fixes). The
# row must NAME the layout, return DEGRADED, and never a false OK.
printf '4242 bash %s/orchestrator/orch-loop.sh\n' "$CELL" > "$TMP/ps-flat"
PS_TABLE="$TMP/ps-flat" run_status "$PIN_TREE"
case "$OUT" in
  *"exec"*"UNIDENTIFIED (executing $CELL/orchestrator/orch-loop.sh"*"flat copy with NO git identity"*) ck "(a-mac) a FLAT-copy controller (no .git) is NAMED, not silently OK" 0 ;;
  *) ck "(a-mac) a FLAT-copy controller (no .git) is NAMED, not silently OK [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
# ⛔ THE EXEC ROW ONLY: "SKIPPED" legitimately appears in OTHER rows on this platform (launchd,
# supervisor), so the whole-output substring test reddened on a healthy screen.
exec_row="$(printf '%s\n' "$OUT" | grep -E '^exec ' | head -1)"
ck "(a-mac) …and it is not SKIPPED away (the state #2271 fixes must stay visible) [$exec_row]" "$(case "$exec_row" in *SKIPPED*) echo 1 ;; *) echo 0 ;; esac)"
ck "(a-mac) …and never a false OK about a copy nobody can identify" "$(case "$exec_row" in *"OK (executing"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(a-mac) …so the screen is DEGRADED (rc=$RC) — red enough to act on, not a broken box" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"

# ⛔ A PIN THAT DOES NOT RESOLVE IS NOT "NO PIN" (found by review): falling through to the harness dir
# printed `OK` about a DIFFERENT reference while the pin named a commit nothing could read — a false
# OK about the wrong tree. Its own verdict has to be UNRESOLVABLE/cannot-verify.
cp "$CELL/.pi/agent/state/HARNESS-PIN" "$TMP/pin.hold"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$CELL/.pi/agent/state/HARNESS-PIN"
PS_TABLE="$TMP/ps-pinned" run_status "$PIN_TREE"
case "$OUT" in *"exec"*"UNRESOLVABLE"*) ck "(a) a pin naming a commit this repo does not have is UNRESOLVABLE, not a fall-through" 0 ;;
  *) ck "(a) a pin naming a commit this repo does not have is UNRESOLVABLE, not a fall-through [$(printf '%s' "$OUT" | grep -E '^exec' | cut -c1-240)]" 1 ;;
esac
# ⛔ …AND IT NAMES THE REPO IT LOOKED IN (review: the exec-row message was unasserted, so naming the WORK
# repo — sending the reader to the wrong checkout — stayed green).
ck "(a) …and the exec-row refusal names the HARNESS repo it searched, not the work repo" \
   "$(case "$OUT" in *"not a commit in the harness repo $REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"
case "$OUT" in *"exec"*"OK (executing"*) ck "(a) …and it never reports OK against a reference the pin did not name" 1 ;; *) ck "(a) …and it never reports OK against a reference the pin did not name" 0 ;; esac
cp "$TMP/pin.hold" "$CELL/.pi/agent/state/HARNESS-PIN"

# ⛔ AND IT MUST SEE A CONTROLLER THAT IS NOT AT THIS BOX'S TWO PATHS (review round 3): the `loop` row's
# census is deliberately scoped to `$HARNESS`/`$O` ("is THIS deployment running"), but the `exec` row
# asks "WHAT is running" — so a controller executing a third tree (a hand-launched old worktree, the
# `~/.cache/orc` shape) must be RESOLVED AND COMPARED, not reported as `MISSING (no controller)`. That
# distinction is the whole reason this row exists, and the earlier arms all used an in-scope path.
printf '4242 bash %s/scripts/orchestrator-harness/orch-loop.sh\n' "$OLD" > "$TMP/ps-elsewhere"
PS_TABLE="$TMP/ps-elsewhere" run_status "$PIN_TREE"
exec_elsewhere="$(printf '%s\n' "$OUT" | grep -E '^exec ' | head -1)"
ck "(a) a controller from a THIRD tree is resolved and compared, not MISSING [$exec_elsewhere]" \
   "$(case "$exec_elsewhere" in *MISSING*) echo 1 ;; *"$A12"*) echo 0 ;; *) echo 1 ;; esac)"

# ══ (b) `up` TWICE: ONE CONTROLLER, ONE START, AND THE SECOND RUN SAYS ALREADY UP ═══════════════
# The fixture is a checkout-shaped copy of the shipped launcher with its SIBLINGS stubbed, because the
# launcher drives the platform authorities by path — and the authority stub REFUSES a second start the
# way the real one does (`registry_claim_or_refuse`).
# ⛔ THE FIXTURE'S HARNESS DIR IS A WORKTREE AT THE PINNED COMMIT INSIDE ITS OWN PIN ROOT, so the pin
# gate is satisfied by PATHS (all that gate compares on this tree) and the run actually reaches the
# components. Anything looser would test the pin gate instead of the start.
FIXCELL="$TMP/fixcell"
FIXPIN="$FIXCELL/harness"
( cd "$REPO_FIX" && git worktree add -q --detach "$FIXPIN/$B12" "$SHA_B" ) >/dev/null 2>&1
FIX="$FIXPIN/$B12/scripts"
mkdir -p "$FIX/orchestrator-harness" "$FIXCELL/.pi/agent/state" "$FIXCELL/orchestrator/state"
cp "$UP" "$FIX/harness-up"; chmod +x "$FIX/harness-up"
# ⛔ THE FLAT-COPY LAYOUT IS A FIXTURE OF ITS OWN (see below, after the authority stub exists):
# `install.sh` deploys a flat copy into `$O` and a plist execs it, so `SELF_PATH` is outside ANY checkout
# and the own-checkout fallback has nothing to read.
printf '%s\n' "$SHA_B" > "$FIXCELL/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$FIX/orchestrator-harness" > "$FIXCELL/.harness-path"
cat > "$FIX/orchestrator-bringup.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  start)
    printf 'start\n' >> "$FIX_LOG"
    # (e) records the two repos the CHILD receives. One variable used to mean both: the pin check
    # resolved the pin commit in the work repo (refusing a good pin), and `--repo <harness>` then
    # retargeted the controller at the harness repo's backlog. Distinct lines keep every other
    # assertion readable — the start/stop counts match `^start$`/`^stop$` exactly.
    printf 'env REPO=%s\n' "${REPO:-}" >> "$FIX_LOG"
    printf 'env HARNESS_REPO=%s\n' "${HARNESS_REPO:-}" >> "$FIX_LOG"
    # The REAL authority refuses a second controller for the same repo+state dir.
    if [ -s "$FIX_LIVE" ]; then
      echo "bringup: REFUSED: already running on this machine (pid 4242 at this state dir) — use: status | stop" >&2
      exit 1
    fi
    exit 0 ;;
  stop) printf 'stop\n' >> "$FIX_LOG"; printf 'stoprepo %s\n' "${REPO:-}" >> "$FIX_LOG"; exit 0 ;;
  *) printf '%s\n' "$*" >> "$FIX_LOG"; exit 0 ;;
esac
SH
cat > "$FIX/cloud-cell-supervisor.sh" <<'SH'
#!/usr/bin/env bash
printf 'supervisor %s\n' "${1:-}" >> "$FIX_LOG"; exit 0
SH
chmod +x "$FIX/orchestrator-bringup.sh" "$FIX/cloud-cell-supervisor.sh"
FH="$FIX/orchestrator-harness"
# Every delegate the launcher drives is a stub here: `selftest.sh`/`check-single-source.sh` exit 0,
# `check-deployed-drift.sh` exits 0, and the refresh records a current relation.
for t in selftest.sh check-single-source.sh check-deployed-drift.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FH/$t"
done
# ⛔ THE REFRESH STUB RECORDS ITS ARGV. `--repo <X>` must name the HARNESS checkout; without this line
# the argument is unobservable, and reverting the launcher to `--repo "$REPO"` (the conflation #2356
# removes) left the whole suite green (measured). Reverted, the refresh resolves `$REF` in the WORK repo,
# reads `relation=unknown` and REFUSES the start — #2356's own symptom, one component further along.
cat > "$FH/harness-refresh.sh" <<'SH'
#!/usr/bin/env bash
printf 'refreshargv %s\n' "$*" >> "$FIX_LOG"
printf 'harness relation=current running=x ref=y pin=z action=none fetch=ok\n'
exit 0
SH
printf '#!/usr/bin/env bash\n: # the controller the authority starts\n' > "$FH/orch-loop.sh"
chmod +x "$FH"/*.sh
# ⛔ THE FLAT-COPY FIXTURE, built HERE because it needs the authority stub too: arms in (e) use it for
# BOTH halves — "the config file can name the harness" (status) and "`down` must still answer when no
# harness resolves" (the stop must reach the authority from a copy that can name no candidate).
FLAT="$TMP/flat"; mkdir -p "$FLAT"
cp "$UP" "$FLAT/harness-up"; cp "$FIX/orchestrator-bringup.sh" "$FLAT/orchestrator-bringup.sh"
chmod +x "$FLAT"/*
run_up() { # <ps-table>
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
          HOME="$TMP/home" CELL_HOME="$FIXCELL" \
          HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="$1" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
          HU_CLAIMS_TIMEOUT=5 \
          bash "$FIX/harness-up" up --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"
  RC=$?
}
# First start: the census is readable and holds no controller, so the authority is asked ONCE.
run_up "$TMP/ps-none"
n1="$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)"
ck "(b) first 'up' asks the authority to start exactly once (n=$n1)" "$([ "$n1" -eq 1 ] && echo 0 || echo 1)"
# …then the box IS up: the control file and the census now both say so, exactly as after a real start.
: > "$FIXCELL/live"
printf '4242 bash %s/orch-loop.sh\n4243 bash %s/cloud-cell-doctor.sh\n' "$FH" "$FH" > "$TMP/ps-up"
: > "$FIXCELL/orchestrator/heartbeat"
run_up "$TMP/ps-up"
n2="$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)"
ck "(b) the second 'up' does NOT start a second controller (authority started $n2 time(s), want 1)" "$([ "$n2" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in
  *"loop: ALREADY UP"*) ck "(b) the second 'up' SAYS ALREADY UP (a no-op, not a silent restart)" 0 ;;
  *) ck "(b) the second 'up' SAYS ALREADY UP (a no-op, not a silent restart) [$(printf '%s' "$OUT" | grep -E 'loop:' | cut -c1-200)]" 1 ;;
esac
ck "(b) the second 'up' does not report a failed start (rc=$RC, not 1-from-a-refusal)" "$([ "$RC" -le 1 ] && echo 0 || echo 1)"
live_n="$(grep -c 'orch-loop.sh' "$TMP/ps-up" | tr -d ' ')"
ck "(b) exactly ONE controller exists after two 'ups' (n=$live_n)" "$([ "$live_n" -eq 1 ] && echo 0 || echo 1)"
# …and the no-op did not cycle ANYTHING: a restart would have logged a stop.
ck "(b) the second 'up' killed nothing (no stop in the authority log)" "$(grep -q '^stop$' "$FIXCELL/fix.log" 2>/dev/null && echo 1 || echo 0)"

# …and a STATUS runner over the same fixture. The FIX launcher has no `capacity.sh` beside it, so the
# capacity block drives the SHIM probe under scripted readings — the (c) arms below are about the
# RULE (a measured ceiling), while the reuse arm further down proves capacity.sh is consumed when it
# IS there.
run_status_fix() { # uses the caller's PS_TABLE (the fixture launcher)
  OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
          HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
          HU_PS="$TMP/ps-probe" PS_TABLE="${PS_TABLE:-$TMP/ps-none}" HU_LOADAVG_FILE="${LOADFILE-$TMP/load}" HU_NCPU="${NCPUV:-4}" \
          HARNESS_UP_MAX_LANES="${MAXL:-}" HARNESS_UP_OS="${OSV:-}" \
          HU_DISK_FLOOR_MB="${DISKFLOOR:-500}" HU_DISK_PER_LANE_MB="${DISKCOST:-1100}" \
          bash "$FIX/harness-up" status --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"
  RC=$?
}

# ⛔ THE MAC'S CONTROLLER RUNS FROM `$O`, NOT FROM `HARNESS` — and `up` deploys to `$O`
# (install.sh:26). An ALREADY-UP check that accepted only `$HARNESS` reported a healthy Mac's second
# `up` as a FAILED START, i.e. it re-created the defect this whole arm removes (found by review).
printf '4242 bash %s/orchestrator/orch-loop.sh\n' "$FIXCELL" > "$TMP/ps-up-o"
run_up "$TMP/ps-up-o"
n3="$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)"
ck "(b-mac) a controller executing the DEPLOYED \$O copy is ALREADY UP (authority starts still $n3)" "$([ "$n3" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in
  *"loop: ALREADY UP"*) ck "(b-mac) …and says so, instead of reporting a healthy Mac as a failed start" 0 ;;
  *) ck "(b-mac) …and says so, instead of reporting a healthy Mac as a failed start [$(printf '%s' "$OUT" | grep -E 'loop:|FAILED' | cut -c1-200)]" 1 ;;
esac
# ⛔ AND THE RUN'S EXIT CODE IS PART OF THE CONTRACT (review round 2): `up` ends with the status verb, so
# a row that returns BROKEN makes a SUCCESSFUL start exit 2. On this layout the exit must be DEGRADED at
# worst — the row is named, and nothing failed to run.
ck "(b-mac) …and 'up' on that layout exits DEGRADED at worst (rc=$RC), never 2-after-a-successful-start" "$([ "$RC" -le 1 ] && echo 0 || echo 1)"

# ⛔ AN UNREADABLE PATH IS NOT A FOREIGN ONE (review round 5): when the single-process read answers
# nothing (a pid that exited between the census and the read, a restricted /proc), `up` used to assert
# "NOT from this run's harness" — a fact nobody established — with a `down`/`up` remedy an operator
# should not follow on a healthy box. It must say only what is known and still fail closed.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix3.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-up" PS_P_EMPTY=1 HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FIX/harness-up" up --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(b) an UNREADABLE controller argv is reported as unknown, not as a foreign harness (rc=$RC, fail closed)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "(b) …and the message says it CANNOT TELL, rather than asserting 'NOT from this run'" \
   "$(case "$OUT" in *"CANNOT TELL"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(b) …and it never claims a foreign harness it did not observe" \
   "$(case "$OUT" in *"NOT from this run's harness"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(b) …and it still starts nothing and kills nothing (authority start count unchanged)" \
   "$([ "$(grep -c '^start$' "$FIXCELL/fix.log" 2>/dev/null || echo 0)" -eq 1 ] && echo 0 || echo 1)"

# ══ (c) CAPACITY: MEASURED, NEVER A FIXED CAP — AND THE PROBE IS capacity.sh's ═════════════════
# ncpu=4 -> ceiling 8.00 load/cpu = 32.00 load units; 4.00 load units per lane; load 4.00 ->
# (32.00-4.00)/4.00 = 7 lanes. ⛔ THE EXPECTED NUMBER IS DERIVED FROM THE PRINTED READING, so the
# assertion is about the RULE and not about this box: a fixed `max_lanes` (8, say) cannot satisfy it.
PS_TABLE="$TMP/ps-none" run_status_fix
cap_line="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) the capacity row prints the MEASURED load it used (load=4.00) [$cap_line]" "$(case "$cap_line" in *"load=4.00"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) the capacity row prints the lane ceiling it derived (lanes=7 from ncpu=4, load=4.00)" "$(case "$cap_line" in *"lanes=7 "*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and it names WHICH probe answered (via=shim, this fixture has no capacity.sh)" "$(case "$cap_line" in *"via=shim"*) echo 0 ;; *) echo 1 ;; esac)"
MAXL=8 PS_TABLE="$TMP/ps-none" run_status_fix
cap_fixed="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a configured fixed cap does NOT become the ceiling (still lanes=7, not 8) [$cap_fixed]" "$(case "$cap_fixed" in *"lanes=7 "*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and the fixed cap is REPORTED as IGNORED, not silently discarded" "$(case "$cap_fixed" in *"fixed cap '8'"*"IGNORED as a ceiling"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND THE DISK LEG IS THE BINDING LEG HERE (review: making it non-binding left it unasserted): the
# fixture `df` answers 20000MB, so 5000MB/lane gives disklen=4 < loadlanes=7 and the ROW must say so. A
# regression that ignores free disk (over-placing lanes on a full box) reds this arm and no other.
DISKCOST=5000 DISKFLOOR=0 PS_TABLE="$TMP/ps-none" run_status_fix
cap_disk="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) with the disk as the BINDING leg the row reports lanes=4 (not the load bound, 7) [$cap_disk]" \
   "$(case "$cap_disk" in *"lanes=4 "*"disk_free=20000MB"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ THE DEFAULT 500MB RESERVE IS PART OF THE RULE, and it must be exercised WITHOUT the helper (which
# always passes the knob explicitly, so the launcher's own default is otherwise unreachable): invoke the
# launcher directly with `HU_DISK_FLOOR_MB` unset. On the fixture's 20000MB, (20000-500)/5000 = 3 lanes;
# a dropped reserve answers 4.
OUT="$( cd "$REPO_FIX" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_DISK_PER_LANE_MB=5000 bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"
cap_floor="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) the DEFAULT 500MB reserve is applied when the knob is UNSET (lanes=3, not 4) [$cap_floor]" \
   "$(case "$cap_floor" in *"lanes=3 "*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND A KNOB THAT IS NOT A NUMBER FALLS BACK TO THE DEFAULT, rather than turning the box BROKEN: a
# typo'd measurement is a measurement this box does not have, and the documented default is the answer.
DISKCOST=abc PS_TABLE="$TMP/ps-none" run_status_fix
cap_bad="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a non-numeric disk knob falls back to the default and still answers (lanes=7) [$cap_bad]" \
   "$(case "$cap_bad" in *"lanes=7 "*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ A LEADING ZERO IS OCTAL TO `$(( ))` (review round 3): `HU_LOAD_PER_LANE=0400` divided by 256 and
# reported 10 lanes where the reading supports 7 (a 43% over-report, in the direction that over-places
# work), and `HU_LOAD_PER_CPU=0800` did not parse at all. The same reading must give the same answer
# whichever spelling an operator uses.
NCPUV=4 LOADFILE="$TMP/load" PS_TABLE="$TMP/ps-none" run_status_fix
cap_plain="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
HU_LOAD_PER_LANE=0400 HU_LOAD_PER_CPU=0800 PS_TABLE="$TMP/ps-none" run_status_fix
cap_zero="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
# ⛔ `[[:space:]]` would be wrong here: the ROW renders `OK (lanes=7 …`, so the field is not preceded by
# a space (only the machine record is). Measured — the anchored form silently read nothing.
plain_lanes="$(printf '%s' "$cap_plain" | sed -n 's/.*lanes=\([0-9]*\) .*/\1/p' | head -1)"
zero_lanes="$(printf '%s' "$cap_zero" | sed -n 's/.*lanes=\([0-9]*\) .*/\1/p' | head -1)"
ck "(c) a leading-zero knob does not become OCTAL (0400/0800 -> lanes=${zero_lanes:-none}, plain=${plain_lanes:-none}) [$cap_zero]" \
   "$([ -n "$plain_lanes" ] && [ "$plain_lanes" = "$zero_lanes" ] && echo 0 || echo 1)"

# A SATURATED box is a measured answer (0 lanes), not a refusal and not a blank.
printf '39.00 1.00 0.50 1/100 4242\n' > "$TMP/load-hot"
LOADFILE="$TMP/load-hot" PS_TABLE="$TMP/ps-none" run_status_fix
cap_hot="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) a saturated box answers lanes=0 WITH the load it read [$cap_hot]" "$(case "$cap_hot" in *"load=39.00"*) case "$cap_hot" in *"lanes=0 "*) echo 0 ;; *) echo 1 ;; esac ;; *) echo 1 ;; esac)"
# ⛔ THE PROBE IS REUSED, NOT RE-IMPLEMENTED. A `capacity.sh` beside the launcher answers with a load
# this box's own /proc does not carry, and the row must report THAT reading (via=capacity.sh): a second
# probe wearing the fleet instrument's name is exactly the duplication the house rule forbids.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$CAPSH_ARGV"\nprintf "host=fixture ncpu=2 load1=1234 lpc=617 lanes=0 disk_free_mb=9000 mem_free_mb=10 at=%s\\n" "$(date +%%s)"\n' > "$FH/capacity.sh"
chmod +x "$FH/capacity.sh"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" CAPSH_ARGV="$TMP/capsh.argv" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FIX/harness-up" status --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
cap_sh="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) the row CONSUMES capacity.sh's record, not its own probe (via=capacity.sh, load=12.34 ncpu=2) [$cap_sh]" \
   "$(case "$cap_sh" in *"via=capacity.sh"*) case "$cap_sh" in *"load=12.34"*"ncpu=2"*) echo 0 ;; *) echo 1 ;; esac ;; *) echo 1 ;; esac)"
# ⛔ AND IT IS HANDED THE PATH WHOSE VOLUME FILLS (review round 2): `capacity.sh probe` with no argument
# measures the CALLER's cwd, so a box whose cwd is on another volume than the state dir over-reports
# free disk — wrong in the direction this feature exists to prevent.
ck "(c) the probe is passed the state dir whose volume lanes fill (\$O), not the caller's cwd [$(cat "$TMP/capsh.argv" 2>/dev/null)]" \
   "$(case "$(cat "$TMP/capsh.argv" 2>/dev/null)" in *"$FIXCELL/orchestrator"*) echo 0 ;; *) echo 1 ;; esac)"
rm -f "$FH/capacity.sh"
# …and the default ceiling is PINNED EQUAL to that file's own, so the two instruments cannot drift.
cap_const="$(sed -n 's/^CAP_LPC_CEILING="${CAP_LPC_CEILING:-\([0-9]*\)}".*/\1/p' "$HERE/orchestrator-harness/capacity.sh" 2>/dev/null | head -1)"
up_const="$(sed -n 's/.*percpu="${HU_LOAD_PER_CPU:-\([0-9]*\)}".*/\1/p' "$UP" | head -1)"
ck "(c) the load ceiling default equals capacity.sh's CAP_LPC_CEILING (up=$up_const capacity=$cap_const)" "$([ -n "$cap_const" ] && [ "$cap_const" = "$up_const" ] && echo 0 || echo 1)"
# ⛔ THE REFUSAL: an unmeasurable box + a fixed cap must NOT answer with the cap. A Darwin-shaped arm
# with a `sysctl` that cannot read the load, and a launcher whose sibling harness dir has no
# capacity.sh (the fallback path), so the probe has nowhere left to go.
mkdir -p "$TMP/noload"
printf '#!/bin/sh\nexit 1\n' > "$TMP/noload/sysctl"; chmod +x "$TMP/noload/sysctl"
OUT="$( cd "$TMP" && PATH="$TMP/noload:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HARNESS_UP_OS=Darwin \
        HARNESS_UP_MAX_LANES=8 bash "$FIX/harness-up" status --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
cap_ref="$(printf '%s\n' "$OUT" | grep -E '^capacity' | head -1)"
ck "(c) an UNMEASURABLE box REFUSES the capacity answer [$cap_ref]" "$(case "$cap_ref" in *REFUSED*) echo 0 ;; *) echo 1 ;; esac)"
ck "(c) …and it never prints the fixed cap as a lane count" "$(case "$cap_ref" in *"lanes=8"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(c) …and the screen is BROKEN, not healthy (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
OUT="$( cd "$TMP" && PATH="$TMP/noload:$TMP:$PATH" FIX_LOG="$FIXCELL/fix2.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HARNESS_UP_OS=Darwin HARNESS_UP_MAX_LANES=8 \
        bash "$FIX/harness-up" up --repo "$REPO_FIX" --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(c) 'up' on an unmeasurable box REFUSES to launch (rc=$RC, documented 3)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *"not a measurement"*) ck "(c) the refusal says WHY (a fixed cap is not a measurement)" 0 ;; *) ck "(c) the refusal says WHY (a fixed cap is not a measurement) [$(printf '%s' "$OUT" | grep -iE 'refus' | cut -c1-200)]" 1 ;; esac

# ══ (d) THE macOS ARM: BSD userland, exercised rather than trusted ═════════════════════════════
# The shim is EXTRACTED from the shipped launcher by its own markers — one copy of it, driven here.
sed -n '/^# ══ >>> shim /,/^# ══ <<< shim /p' "$UP" > "$TMP/shim.sh"
ck "(d) the shim block is extractable from the shipped launcher by its own markers" "$([ -s "$TMP/shim.sh" ] && echo 0 || echo 1)"
mkdir -p "$TMP/darwinbin"
# ⛔ BSD mktemp: a TEMPLATE is required. This is the exact shape that killed every Apple run.
cat > "$TMP/darwinbin/mktemp" <<'SH'
#!/bin/sh
case "${1:-}" in -d) shift ;; esac
case "${1:-}" in ''|*X*) ;; esac
[ -n "${1:-}" ] || { echo "usage: mktemp [-d] template" >&2; exit 1; }
printf '%s\n' "$1" >> "$SHIM_LOG.mktemp"
d="$(printf '%s' "$1" | sed 's/X*$//')$$"
mkdir -p "$d" && printf '%s\n' "$d"
SH
# BSD stat: `-f %m` answers; `-c %Y` is a usage error (the reverse of GNU, which is why the shim
# tries GNU first and GUARDS the answer rather than trusting the order).
cat > "$TMP/darwinbin/stat" <<'SH'
#!/bin/sh
case "$1" in
  -f) [ "$2" = "%m" ] && { /usr/bin/stat -c %Y "$3" 2>/dev/null || echo 1700000000; exit 0; }
      echo "stat: illegal option" >&2; exit 1 ;;
  *)  echo "stat: illegal option" >&2; exit 1 ;;
esac
SH
cat > "$TMP/darwinbin/sysctl" <<'SH'
#!/bin/sh
case "$*" in
  *vm.loadavg*) printf '{ 2.50 1.00 0.50 }\n' ;;
  *hw.ncpu*)    printf '4\n' ;;
  *)            exit 1 ;;
esac
SH
# launchctl print: rc 0 + `state = running`; LOADED_NO_PID drops the pid line; ABSENT fails.
cat > "$TMP/darwinbin/launchctl" <<'SH'
#!/bin/sh
case "${LAUNCHD_MODE:-running}" in
  absent) printf 'Could not find service "com.test.job" in domain for user gui: 501\n' >&2; exit 113 ;;
  # ⛔ A DOMAIN-LEVEL REJECTION: non-zero, and it says NOTHING about the service (measured shape of
  # `launchctl print gui/0/x` under root, and of an SSH context with no gui domain).
  bad-domain) printf 'Bad request.\nCould not find domain for user gui: 0\n' >&2; exit 113 ;;
  loaded-no-pid) printf '\tstate = spawn scheduled\n\tlast exit code = 78\n'; exit 0 ;;
  # A recorded exit that keeps being followed by no process — with the cumulative launch count.
  crashloop) printf '\tstate = spawn scheduled\n\tlast exit code = 128\n\truns = 7\n'; exit 0 ;;
  # NO launch count at all: the row may print the code and must invent no count.
  died) printf '\tstate = spawn scheduled\n\tlast exit code = 128\n'; exit 0 ;;
  # A CLEAN exit with a climbing launch count: `orch-loop.sh`'s "already running" path does `exit 0`,
  # so KeepAlive relaunches it cleanly, for ever. This must NOT read as a crash.
  clean-exit) printf '\tstate = spawn scheduled\n\tlast exit code = 0\n\truns = 7\n'; exit 0 ;;
  # Loaded, no process, and launchd has NEVER launched it (runs = 0 settles "never kicked").
  never-started) printf '\tstate = spawn scheduled\n\truns = 0\n'; exit 0 ;;
  # ⛔ `last exit code = 0` IS launchd's CALLOC DEFAULT, so a job that never ran reports it too.
  # `runs = 0` is the decisive datum and must WIN over it (review round 3).
  default-clean) printf '\tstate = spawn scheduled\n\tlast exit code = 0\n\truns = 0\n'; exit 0 ;;
  # A SIGNED status (a signal death). A present datum must not be reported as absent.
  signed) printf '\tstate = spawn scheduled\n\tlast exit code = -15\n\truns = 3\n'; exit 0 ;;
  # NON-CANONICAL INTEGER: `00` must normalise to a clean 0, not read as a crash (round 5).
  zerozero) printf '\tstate = spawn scheduled\n\tlast exit code = 00\n\truns = 5\n'; exit 0 ;;
  # Loaded with no process AND no exit data at all: the row may not invent one.
  no-data) printf '\tstate = spawn scheduled\n'; exit 0 ;;
  *) printf '\tstate = running\n\tpid = 4242\n'; exit 0 ;;
esac
SH
chmod +x "$TMP/darwinbin"/*
SHIM_LOG="$TMP/shim" HARNESS_UP_OS=Darwin PATH="$TMP/darwinbin:$PATH" \
  bash -c '. "$1/shim.sh"; hu_bounded(){ local s="$1"; shift; "$@"; }; os="$(hp_os)"; m="$(hp_mktemp_d)"
    printf "os=%s\nmktmp=%s\nload=%s\nncpu=%s\ndisk=%s\n" "$os" "$m" "$(hp_load1_c)" "$(hp_ncpu)" "$(hp_disk_free_mb "$1")"
    hp_launchd_loaded com.test.job; printf "launchd_running=%s\n" "$?"
    LAUNCHD_MODE=loaded-no-pid hp_launchd_loaded com.test.job; printf "launchd_dead=%s\n" "$?"
    LAUNCHD_MODE=absent hp_launchd_loaded com.test.job; printf "launchd_absent=%s\n" "$?"
    LAUNCHD_MODE=bad-domain hp_launchd_loaded com.test.job; printf "launchd_baddomain=%s\n" "$?"' \
  _ "$TMP" > "$TMP/darwin-out" 2>&1
ck "(d) hp_os answers Darwin from the seam" "$(grep -qx 'os=Darwin' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_mktemp_d SUCCEEDS under a BSD mktemp (a template was passed)" "$(case "$(sed -n 's/^mktmp=//p' "$TMP/darwin-out")" in /*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) the BSD mktemp stub RECORDED the templated call (nothing ran untemplated)" "$([ -s "$TMP/shim.mktemp" ] && echo 0 || echo 1)"
ck "(d) hp_load1_c reads sysctl's curly-braced vm.loadavg (2.50 -> 250)" "$(grep -qx 'load=250' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_ncpu reads hw.ncpu (4)" "$(grep -qx 'ncpu=4' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_disk_free_mb answers a number through BSD/POSIX df" "$(sed -n 's/^disk=//p' "$TMP/darwin-out" | grep -qE '^[0-9]+$' && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: running -> 0" "$(grep -qx 'launchd_running=0' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: loaded with NO process -> 1 (the state 'ps' alone cannot name)" "$(grep -qx 'launchd_dead=1' "$TMP/darwin-out" && echo 0 || echo 1)"
ck "(d) hp_launchd_loaded: launchd's own SERVICE-level not-found -> 2 (absent)" "$(grep -qx 'launchd_absent=2' "$TMP/darwin-out" && echo 0 || echo 1)"
# ⛔ rc IS NOT THE VERDICT (review round 4): a DOMAIN-level rejection is non-zero too, and calling it
# NOT LOADED answers a question nobody answered — with a re-install remedy. Same rule as launchd-cycle.sh
# `lc_probe` and orchestrator-bringup.sh `launchd_job_state`.
ck "(d) hp_launchd_loaded: a DOMAIN rejection -> 5 cannot-verify, NOT 'not loaded'" "$(grep -qx 'launchd_baddomain=5' "$TMP/darwin-out" && echo 0 || echo 1)"

# ⛔ "NO USABLE BOUND" IS NOT "launchctl IS ABSENT" (review round 2): `hu_bounded` returns 125 when perl
# is missing, and folding that into 3 made the row send the operator after a binary that is already
# there. A PATH holding launchctl (and nothing else that matters) but NO perl is the exact regime — the
# REAL helpers block is sourced, so the 125 is the shipped bound's own answer, not a test fixture's.
BASH_BIN="$(command -v bash)"
mkdir -p "$TMP/noperl"
cp "$TMP/darwinbin/launchctl" "$TMP/noperl/launchctl"; chmod +x "$TMP/noperl/launchctl"
printf '#!/bin/sh\nprintf "501\\n"\n' > "$TMP/noperl/id"; chmod +x "$TMP/noperl/id"
sed -n '/^# >>> helpers$/,/^# <<< helpers$/p' "$UP" > "$TMP/helpers.sh"
NOPERL="$( HARNESS_UP_OS=Darwin PATH="$TMP/noperl" "$BASH_BIN" -c '. "$1/helpers.sh"; hp_launchd_loaded com.test.job; printf "%s" "$?"' _ "$TMP" 2>/dev/null )"
ck "(d) an unbindable probe (launchctl present, perl absent) answers 125 — NOT 'launchctl absent' (got '${NOPERL:-nothing}')" "$([ "$NOPERL" = 125 ] && echo 0 || echo 1)"

# …and the WHOLE launcher on the macOS arm: it must reach a verdict at all (the untemplated mktemp
# used to end the run at its last line), and the launchd row must be a REAL answer, not SKIPPED.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
n_v="$(printf '%s\n' "$OUT" | grep -c '^VERDICT:')"
ck "(d) a macOS-arm 'status' RUNS TO A VERDICT (a BSD mktemp/temp-dir death would end it earlier)" "$([ "$n_v" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in
  *"launchd"*"OK (com.eldato.orchestrator-loop is loaded and has a process"*) ck "(d) the launchd row answers LOADED+RUNNING on the macOS arm" 0 ;;
  *) ck "(d) the launchd row answers LOADED+RUNNING on the macOS arm [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac
LAUNCHD_MODE=loaded-no-pid OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=loaded-no-pid HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
case "$OUT" in
  *"launchd"*"DIED (last exit 78"*) ck "(d) a job loaded with NO process NAMES launchd's own exit code (78), not a shrug" 0 ;;
  *) ck "(d) a job loaded with NO process NAMES launchd's own exit code (78) [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac
# ⛔ THE STATE THIS WHOLE ROW EXISTS FOR (2026-10-22). The Mac's `com.eldato.orchestrator-loop` sat at
# LAST EXIT 128 — a fork/spawn failure — and the row could only say "it is crashing or was never
# kicked". The exit code and launchd's own launch count are in the block the row already reads, so
# the row must CARRY them instead of dropping them.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=crashloop HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a NON-ZERO exit is NAMED DIED with launchd's own code (128) [$launchd_row]" \
   "$(case "$launchd_row" in *"DIED (last exit 128"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and the launch count is carried as EVIDENCE (7 launch(es)) [$(printf '%s' "$launchd_row" | cut -c1-160)]" \
   "$(case "$launchd_row" in *"7 launch(es)"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `runs` IS CUMULATIVE AND MAY NOT BECOME A VERDICT (review, 2026-10-22 and again cycle 2). Two
# assertions, because a vocabulary-only negation is defeatable: a re-add worded `CRASH-LOOP` or
# `LOOPING` would pass a check that only looked for the literal `PERSISTENT`. So: negate the whole
# verdict vocabulary in use, AND positively require the CONDITIONAL sentence that makes the count
# evidence rather than a diagnosis.
# ⛔ THE `""` ARM IS THE POINT (review round 4): without it an EMPTY row makes every negative
# assertion pass — the row could stop being emitted entirely and these would stay green.
ck "(d) …but a cumulative count is NOT turned into any crash/persistence verdict [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in ""|*CRASH*|*PERSIST*|*LOOP*|*"will not help"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(d) …and persistence is stated CONDITIONALLY, so the count is evidence not a verdict [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in *"if it STAYS here"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ A CLEAN EXIT IS NOT A CRASH (review cycle 2). `orch-loop.sh`'s lock path prints "already running"
# and `exit 0`; with KeepAlive that is a job that exits IMMEDIATELY and cleanly, every time. Calling
# it DIED and pointing at `launchd.err` (that message goes to STDOUT) is a named WRONG CAUSE — worse
# than the old agnostic wording.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=clean-exit HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a CLEAN exit (0) is NAMED EXITED-CLEAN, not DIED [$launchd_row]" \
   "$(case "$launchd_row" in *EXITED-CLEAN*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and it does NOT claim every attempt is failing [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in ""|*"every attempt is failing"*) echo 1 ;; *) echo 0 ;; esac)"
ck "(d) …and it points at launchd.OUT, which is where 'already running' is written [$(printf '%s' "$launchd_row" | cut -c1-200)]" \
   "$(case "$launchd_row" in *launchd.out*launchd.err*|*launchd.err*) echo 1 ;; *launchd.out*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `runs = 0` SETTLES "NEVER KICKED" even with no exit code — the count is not discarded when the
# code is absent (review cycle 2).
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=never-started HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) 'no exit code + 0 launches' is NAMED NEVER-STARTED, not 'crashing or never kicked' [$launchd_row]" \
   "$(case "$launchd_row" in *NEVER-STARTED*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `runs = 0` MUST BEAT A DEFAULT `last exit code = 0` (review round 3). launchd callocs
# last_exit_status to 0, so a never-launched job reports "last exit code = 0" too; branching on the
# code first named a lock-contention cause and hid the `kickstart` remedy for a job that never ran.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=default-clean HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) '0 launches' WINS over launchd's default 'last exit code = 0' — NEVER-STARTED, not EXITED-CLEAN [$launchd_row]" \
   "$(case "$launchd_row" in *NEVER-STARTED*) echo 0 ;; *EXITED-CLEAN*) echo 1 ;; *) echo 1 ;; esac)"
# ⛔ A SIGNED STATUS IS A PRESENT DATUM. Dropping it would report a signal death as "no exit code".
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=signed HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a SIGNED exit status is carried, not dropped as 'no exit code' [$launchd_row]" \
   "$(case "$launchd_row" in *"DIED (last exit -15"*) echo 0 ;; *) echo 1 ;; esac)"

# ⛔ A NON-CANONICAL INTEGER IS NORMALISED, NOT ECHOED (review round 5): `00` is a clean exit, and
# a lax `[0-9]*` pattern would render `DIED (last exit 00)` — a clean exit named a crash.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=zerozero HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) a non-canonical '00' normalises to a CLEAN exit, not a crash [$launchd_row]" \
   "$(case "$launchd_row" in *EXITED-CLEAN*) echo 0 ;; *) echo 1 ;; esac)"
# An exit with NO launch count still prints the code, and invents no count.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=died HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) an exit with NO launch count still prints the code [$launchd_row]" \
   "$(case "$launchd_row" in *"DIED (last exit 128"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and invents no count when launchd published none [$(printf '%s' "$launchd_row" | cut -c1-160)]" \
   "$(case "$launchd_row" in ""|*"launch(es)"*|*"0 launches"*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AN ABSENT DATUM IS NEVER RENDERED AS A VALUE. With neither an exit code nor a run count the row
# must fall back to LOADED-NO-PROCESS rather than claim "last exit 0" or "0 launches".
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=no-data HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) with NO exit data the row falls back to LOADED-NO-PROCESS (it never invents a status) [$launchd_row]" \
   "$(case "$launchd_row" in *LOADED-NO-PROCESS*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and invents neither a code nor a count [$(printf '%s' "$launchd_row" | cut -c1-160)]" \
   "$(case "$launchd_row" in ""|*"last exit 0"*|*"0 launches"*) echo 1 ;; *) echo 0 ;; esac)"
# …and a DOMAIN-level rejection must not become a confident NOT LOADED + re-install remedy (review
# round 4): rc is not the verdict, the text is — the rule launchd-cycle.sh `lc_probe` and
# orchestrator-bringup.sh `launchd_job_state` both state.
OUT="$( cd "$TMP" && PATH="$TMP/darwinbin:$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" HARNESS_UP_OS=Darwin \
        LAUNCHD_MODE=bad-domain HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-pinned" HU_LOADAVG_FILE="$TMP/load" \
        bash "$UP" status --repo "$REPO_FIX" --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
launchd_row="$(printf '%s\n' "$OUT" | grep -E '^launchd ' | head -1)"
ck "(d) an unverifiable launchd read is UNKNOWN in the row [$launchd_row]" "$(case "$launchd_row" in *UNKNOWN*) echo 0 ;; *) echo 1 ;; esac)"
ck "(d) …and NOT 'NOT LOADED' with a re-install remedy" "$(case "$launchd_row" in *"NOT LOADED"*) echo 1 ;; *) echo 0 ;; esac)"
# …and the cell arm still says SKIPPED with its reason: not-applicable is a pass, never a fake OK.
PS_TABLE="$TMP/ps-pinned" OSV="" run_status "$PIN_TREE"
case "$OUT" in
  *"launchd"*"SKIPPED (no launchd on this platform"*) ck "(d) the Linux arm SKIPS launchd with its reason (never OK)" 0 ;;
  *) ck "(d) the Linux arm SKIPS launchd with its reason (never OK) [$(printf '%s' "$OUT" | grep -E '^launchd' | cut -c1-200)]" 1 ;;
esac

# ══ (e) THE HARNESS REPO AND THE WORK REPO ARE TWO DIFFERENT THINGS ═════════════════════════════
# A cell exports REPO=<the WORK repo> (tortoise) while the harness lives in agent-infra. The pin is a
# commit OF THE HARNESS REPO, and the controller derives `$OR` from REPO's origin — so resolving the
# pin in the work repo refuses a perfectly good pin, and the obvious repair (`--repo <agent-infra>`)
# writes REPO=<agent-infra> into the child and silently retargets the controller. Both halves are
# asserted here, and the RED control below is what keeps the refusal alive rather than muted.
# ⛔ THE WORK FIXTURE IS BUILT EARLY (see `WORK` above the run_status seam) because the (a) arms use it
# too: the harness-repo ancestry question is only discriminating with a foreign work repo in the shell.
ck "(e) the work-repo fixture does NOT contain the pin commit (a foreign object DB)" \
   "$([ -n "$WORK" ] && ! git -C "$WORK" rev-parse --verify --quiet "$SHA_B^{commit}" >/dev/null 2>&1 && echo 0 || echo 1)"
# CANDIDATE 2 (`HARNESS_REPO`, which the fleet may export): the pin is read in the HARNESS repo, never in
# the foreign work repo the caller exported as `REPO`. This arm supplies `HARNESS_REPO` ON PURPOSE —
# candidate 3 (the launcher's own checkout) is the NEXT arm's subject. Conflating the two is how a suite
# proves one candidate while its comment claims another.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" REPO="$WORK" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HARNESS_UP_OS= bash "$UP" status --harness "$PIN_TREE" --no-fetch 2>&1 )"
ck "(e) a foreign REPO does not poison the pin read: the pin resolves in HARNESS_REPO (pin: OK)" \
   "$(case "$OUT" in *'pin: OK'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and it does NOT claim the pin is unresolvable" \
   "$(case "$OUT" in *'pin: UNRESOLVABLE'*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ CANDIDATE 3 (`git worktree list`, the launcher's OWN checkout) IS THE OPERATIVE CELL PATH, and it is
# the one a `HARNESS_REPO`-carrying arm cannot cover: a cell's `keys.env` carries `OR` and `REPO` but NOT
# `HARNESS_REPO` (docs/ops/fleet-harness-baseline.md), so the fallback is what resolves the harness there.
# Run with NEITHER `--repo` NOR `HARNESS_REPO`, from a copy of the launcher living INSIDE the harness
# fixture's worktree — `git worktree list` names the MAIN worktree first, so its own checkout IS the
# harness repo — and the pin must resolve there. Without this arm, making the fallback revert to the work
# repo (the exact conflation #2356 removes) left the suite at 0 failed.
# ⛔ AND IT MUST CARRY THE FOREIGN WORK REPO (review P1): with `REPO` unset this arm is VACUOUS about the
# one regression it claims to guard — adding `REPO` back as an `HREPO` candidate (or as the fallback)
# left all 100 assertions green, because no arm supplied a work repo for the launcher to prefer. The
# cell shape IS "an ambient REPO that is not the harness", so `REPO="$WORK"` is what makes it that.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$WORK" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" status --harness "$FH" --no-fetch 2>&1 )"
ck "(e) with no --repo and no HARNESS_REPO the harness resolves from the launcher's OWN checkout (pin: OK)" \
   "$(case "$OUT" in *'pin: OK'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and that fallback reads the pin in the harness repo, not the foreign work repo" \
   "$(case "$OUT" in *'pin: UNRESOLVABLE'*) echo 1 ;; *) echo 0 ;; esac)"
# The child env: REPO stays the WORK repo, HARNESS_REPO is the harness checkout. This is the half that
# a `--repo <harness>` repair breaks, so it is asserted rather than assumed — WITH `--repo` PASSED.
# #2356 review P2: without `--repo` this arm is vacuous — `REPO="$WORK"` holds identically under the
# old buggy `REPO="${A_REPO:-${REPO:-}}"`, so a regression restoring `--repo`'s priority over REPO
# (the silent wrong-backlog retarget this PR exists to fix) would pass every assertion.
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$WORK" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" up --harness "$FH" --repo "$REPO_FIX" --no-fetch 2>&1 )"
ck "(e) the controller is told REPO=<work repo> (never the harness repo)" \
   "$(grep -qx "env REPO=$WORK" "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
ck "(e) …and HARNESS_REPO=<the harness checkout>" \
   "$(grep -qx "env HARNESS_REPO=$REPO_FIX" "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
# ⛔ THE OTHER HALF OF THE BANNER: a shell-exported REPO is named as such. Only the config-file branch was
# asserted, so deleting `REPO_SRC="the environment"` told the operator their ambient value was the
# FALLBACK — the one thing the line exists to distinguish — while staying 112/0.
ck "(e) …and the banner says an exported REPO came from the ENVIRONMENT" \
   "$(case "$OUT" in *"repo $WORK (the environment)"*) echo 0 ;; *) echo 1 ;; esac)"
# ── CANDIDATE 2 OF REPO's PRECEDENCE: THIS MACHINE'S CONFIG FILE ─────────────────────────────────
# `REPO` is "the caller's `REPO`, then the config file, then the harness checkout", and the config file
# is the CELL path, not a theoretical one: `docs/ops/fleet-harness-baseline.md` shows `keys.env` carrying
# `REPO=/tmp/cell-t3`, and `keys.env` is exactly `ENV_FILE`. Without this arm the MIDDLE candidate is
# untested — deleting `$(cfg_value REPO "$ENV_FILE")` from the launcher leaves every other assertion
# green (measured), and the regression exports `REPO=<the harness checkout>` to the controller on the
# boxes that configure their work repo here: the wrong-backlog retarget this split exists to remove.
# ⛔ NOT VACUOUS UNDER THE OLD CODE: `REPO="${A_REPO:-${REPO:-}}"` read `--repo` as REPO, so with no
# `REPO` in the shell the child was told `REPO=<the harness>` and this arm fails on that tree.
printf 'REPO=%s\n' "$WORK" > "$TMP/bringup.env"
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" ENV_FILE="$TMP/bringup.env" \
        HARNESS_REPO="$REPO_FIX" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" up --harness "$FH" --repo "$REPO_FIX" --no-fetch 2>&1 )"
ck "(e) with no REPO in the shell, the config file's REPO is the work repo the controller is told" \
   "$(grep -qx "env REPO=$WORK" "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
ck "(e) …and the harness repo still resolves from --repo/HARNESS_REPO, never from the config file" \
   "$(grep -qx "env HARNESS_REPO=$REPO_FIX" "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
# ⛔ THE SOURCE IS ON THE SCREEN. With `--repo` unable to set `REPO` any more, an inherited-but-unintended
# work repo is accepted silently, and a path alone does not say whether it came from the shell, the config
# file, or the fallback. The banner names it; reverting that interpolation reds this line.
ck "(e) …and the banner names WHERE the work repo came from (not just its path)" \
   "$(case "$OUT" in *"repo $WORK (the config file"*) echo 0 ;; *) echo 1 ;; esac)"
# ── THE PRECEDENCE CONFLICT: the caller's REPO BEATS the config file's ──────────────────────────────
# The documented order is "the caller's `REPO`, then the config file", and no other arm tests the case
# where BOTH are set and differ — the case a cell is actually in (a shell export plus `keys.env`). A
# regression that reads the config FIRST silently discards the caller's checkout and drains the other
# repo's backlog, which is the wrong-backlog class this split removes, one precedence step over.
printf 'REPO=%s\n' "$TMP/nowhere-repo" > "$TMP/conflict.env"
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$WORK" ENV_FILE="$TMP/conflict.env" \
        HARNESS_REPO="$REPO_FIX" HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" up --harness "$FH" --repo "$REPO_FIX" --no-fetch 2>&1 )"
ck "(e) with BOTH an env REPO and a DIFFERENT one in the config file, the caller's REPO wins" \
   "$(grep -qx "env REPO=$WORK" "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
ck "(e) …and the losing config value is never what the controller is told (and nothing was started on it)" \
   "$(grep -q 'nowhere-repo' "$FIXCELL/fix.log" 2>/dev/null && echo 1 || echo 0)"
# ── THE REFRESH IS A HARNESS QUESTION TOO (review: its argv was unobservable) ─────────────────────
# `up` starts `harness-refresh.sh --repo <X> --ref <REF>`, and X must be the HARNESS checkout. With the
# WORK repo there the refresh resolves `$REF` in the wrong object DB, reads relation=unknown and REFUSES
# the start — a correct cell refused, #2356's own symptom one component further along. The stub above
# records its argv, so reverting that one argument reds this arm instead of passing silently (measured).
ck "(e) the refresh is asked to read the HARNESS repo (harness-refresh --repo <harness>)" \
   "$(grep -q '^refreshargv ' "$FIXCELL/fix.log" 2>/dev/null \
      && grep -Fq -- "--repo $REPO_FIX " "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"

# ── THE THIRD RESOLUTION SITE: PIN-ABSENT, WHERE THE REF TIP IS READ ─────────────────────────────
# With no `HARNESS-PIN` record the launcher resolves `$REF`'s tip and says `pin: ABSENT … resolved
# <sha>`. That is a HARNESS question: asked of a foreign WORK repo it is UNRESOLVABLE (the work
# fixture's tip is a different sha), so this arm asserts the ABSENT path AND proves which repo answered.
NOPIN="$TMP/cell-nopin"
mkdir -p "$NOPIN/.pi/agent/state"
printf '%s\n' "$PIN_TREE" > "$NOPIN/.harness-path"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$NOPIN" REPO="$WORK" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$NOPIN/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --no-fetch 2>&1 )"
# ⛔ ASSERT ON THE PIN LINE ITSELF, NOT ON THE WHOLE SCREEN: `$B12` also appears in the harness PATH
# that `status` prints, so "the output contains $B12" is TRUE whatever the pin line says (measured — the
# vacuous form stayed green with the resolution reverted to `$REPO`).
pinline="$(printf '%s\n' "$OUT" | grep -m1 'pin: ABSENT')"
ck "(e) with no HARNESS-PIN the REF tip is resolved in the harness repo (pin: ABSENT … $B12)" \
   "$(case "$pinline" in *"resolved $B12 from"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and it is never UNRESOLVABLE for a ref the harness repo does hold" \
   "$(case "$OUT" in *'pin: UNRESOLVABLE'*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AND WHEN THE REF ITSELF DOES NOT RESOLVE, THE REFUSAL NAMES THE HARNESS REPO (review: reverting this
# message to `$REPO` left the suite green, so an operator was pointed at tortoise for a harness problem).
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$NOPIN" REPO="$WORK" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$NOPIN/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --ref origin/does-not-exist --no-fetch 2>&1 )"
ck "(e) an UNRESOLVABLE ref names the HARNESS repo it searched, not the work repo" \
   "$(case "$OUT" in *"does not resolve in $REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"
# ── the WORK repo's OWN validation (review cycles 2/3): a REPO the controller cannot use is refused ─
# Set-but-wrong is never "unset": a directory that is not a checkout makes `orch-loop.sh` fall back to a
# hardcoded owner/repo, so the controller grades a repo nobody named.
# ⛔ THE REFUSAL BELONGS TO `up`, NOT TO THE LAUNCHER — a refusal is not a universal verb policy. `up`
# STARTS a controller that would drain the repo, so it refuses and starts nothing. `down`/`status` must
# stay answerable: an operator reaches for them on a machine that is wrong, and the authority states the
# same rule for itself (`orchestrator-bringup.sh` `cmd_stop`: "REPORT, never die … `stop` is the verb an
# operator reaches for on a machine that is wrong, and it must stay answerable"). Since `--repo` no
# longer sets REPO, a launcher that refused EVERY verb on a stale ambient REPO would leave a live
# controller unstoppable until the operator edited their shell — which the pre-split launcher never did.
# ⛔ THESE `up` ARMS ARE REGRESSION GUARDS, NOT DETECTORS OF THIS BUG: `origin/main` already ran
# `die "$REPO is not a git checkout" 2` and the `-d` guard already exited 2. They exist because the
# split must not DROP the pre-split validation, which #2356 requires. The signal that the behaviour
# changed is the MESSAGE arms, which name `REPO=`, its SOURCE, and the remedy.
mkdir -p "$TMP/plaindir"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" REPO="$TMP/plaindir" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" up --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
ck "(e) 'up' REFUSES a REPO that is a directory but NOT a checkout (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "(e) …and the message names the value, its SOURCE, and the repo it is not a checkout of" \
   "$(case "$OUT" in *'is set (by the environment)'*'is not a git checkout'*) echo 0 ;; *) echo 1 ;; esac)"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" REPO="$TMP/no-such-dir" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" up --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
ck "(e) 'up' REFUSES a REPO that does not exist, not silently swapped for the harness (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "(e) …and the message says it is not a directory" \
   "$(case "$OUT" in *'REPO='*'is not a directory'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and it says NOTHING WAS STARTED (the operator's one cue that a refusal beat a partial start)" \
   "$(case "$OUT" in *'Nothing was started'*) echo 0 ;; *) echo 1 ;; esac)"
# …AND THE SAME BAD VALUE MUST NOT SILENCE THE ONE VERB THAT HAS TO ANSWER (review cycle 3).
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$TMP/no-such-dir" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" down --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(e) …while 'down' still REACHES the authority on that same bad REPO (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "(e) …and the stop was actually delegated" \
   "$(grep -qx 'stop' "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
ck "(e) …and the bad value is passed through and NAMED, never swapped for the harness" \
   "$(case "$OUT" in *'REPO='*'is not a directory'*) if grep -qx "stoprepo $TMP/no-such-dir" "$FIXCELL/fix.log" 2>/dev/null; then echo 0; else echo 1; fi ;; *) echo 1 ;; esac)"
ck "(e) …and the continuation is SAID, so a bare error cannot be mistaken for a failed stop" \
   "$(case "$OUT" in *"continuing, because 'down' starts nothing"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ THE OTHER `REPO_BAD` BRANCH (a directory that is not a CHECKOUT) needs the same proof: substituting
# the harness there hands the child `REPO=<agent-infra>` with no warning — the wrong-backlog retarget —
# and substituting it left the suite green (review cycle 4).
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$TMP/plaindir" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" down --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(e) 'down' reaches the authority on a REPO that is a directory but NOT a checkout (rc=$RC)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "(e) …and passes THAT value through, never the harness" \
   "$(if grep -qx "stoprepo $TMP/plaindir" "$FIXCELL/fix.log" 2>/dev/null; then echo 0; else echo 1; fi)"
# ── AND WITH NO HARNESS RESOLVABLE AT ALL, `down` MUST STILL ANSWER (review P1) ───────────────────────
# `down` reads no harness — it delegates to the authority's `stop`. `origin/main` reached cmd_down on a
# flat copy with no candidate; a verb-blind refusal here is the same inversion the `REPO_BAD` block fixes.
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$WORK" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FLAT/harness-up" down --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(e) 'down' from a copy that cannot name a harness still stops the box (rc=$RC)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "(e) …the stop was delegated, and the unresolvable harness was NAMED, not fatal" \
   "$(HU_NAMED=0; case "$OUT" in *'no agent-infra checkout resolved'*) HU_NAMED=1 ;; esac; if [ "$HU_NAMED" -eq 1 ] && grep -qx 'stop' "$FIXCELL/fix.log" 2>/dev/null; then echo 0; else echo 1; fi)"
ck "(e) …and the harness-side continuation is SAID too (not just the REPO-side clause)" \
   "$(case "$OUT" in *"continuing, because 'down' reads no harness"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and an EMPTY candidate is never reported as a misconfigured one" \
   "$(case "$OUT" in *"ignoring ''"*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AND `up` MUST REFUSE ON THE SAME BOX (review P1, fail-open): with no harness the pin cannot be
# resolved, so starting a controller is the #2356 refusal skipped entirely. Pin-less is the Mac shape; a
# flat copy with its own authority stub is the deployed shape. Nothing was started, and that is checked
# by the EMPTY authority log, not by the sentence alone.
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$WORK" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FLAT/harness-up" up --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(e) 'up' REFUSES when no harness resolves (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "(e) …says NOTHING WAS STARTED, and started nothing" \
   "$(HU_S=0; case "$OUT" in *'Nothing was started'*) HU_S=1 ;; esac; if [ "$HU_S" -eq 1 ] && [ ! -s "$FIXCELL/fix.log" ]; then echo 0; else echo 1; fi)"
ck "(e) …and the exit code is NOT spilled into the sentence (die formats its message, not its argv)" \
   "$(case "$OUT" in *'Nothing was started. 2'*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AND THE CLAIMS PROBE MUST NOT RUN ON AN UNNAMED WORK REPO (review P1): `git -C "" ls-remote origin`
# reads the CWD's repo, over the NETWORK, and PERSISTS `claims=reachable` for it — a record every later
# `status` reads as an answer. No work repo, no probe. ⛔ THE CWD HERE IS A REAL CHECKOUT ON PURPOSE: from
# a non-repo cwd the guarded and unguarded launchers behave identically (both fail), so the arm would be
# vacuous — the guard is only observable where `git -C ""` WOULD succeed.
FRESHCELL="$TMP/cell-flat2"
mkdir -p "$FRESHCELL/.pi/agent/state" "$FRESHCELL/orchestrator/state"
printf '%s\n' "$PIN_TREE" > "$FRESHCELL/.harness-path"
printf '%s\n' "$B12" > "$FRESHCELL/.pi/agent/state/HARNESS-PIN"
OUT="$( cd "$REPO_FIX" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FRESHCELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$FRESHCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FLAT/harness-up" status --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
claimsrow="$(printf '%s\n' "$OUT" | grep -E '^claims' | head -1)"
ck "(e) an unresolvable WORK repo does not probe claims (the row is UNKNOWN, not a latched OK) [$claimsrow]" \
   "$(case "$claimsrow" in *'UNKNOWN'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and no claims record was written for an unnamed repo" \
   "$([ ! -f "$FRESHCELL/orchestrator/state/harness-claims" ] && echo 0 || echo 1)"
# ── THE SOURCE IS NAMED FOR A CONFIG-FILE REPO TOO: `unset REPO` is INERT for this value ──────────
printf 'REPO=%s\n' "$TMP/plaindir" > "$TMP/badrepo.env"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" ENV_FILE="$TMP/badrepo.env" \
        HARNESS_REPO="$REPO_FIX" HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" up --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
ck "(e) a bad REPO from the CONFIG FILE names the config file, not the environment (rc=$RC)" \
   "$(case "$OUT" in *"(by the config file $TMP/badrepo.env)"*) echo 0 ;; *) echo 1 ;; esac)"
# ── THE HARNESS SIDE: an EXPLICIT bad `--repo` is refused, an INHERITED bad candidate is skipped ─────
# Two different answers, and both are load-bearing. `--repo` is the operator's assertion about this run:
# refusing it (naming the value) is what stops a mistyped flag from being silently answered by a
# different checkout. An inherited `HARNESS_REPO` is not — the supervisor PRUNES pin worktrees, so a
# candidate that moved is ordinary wear, and a launcher that refuses EVERY verb on it (rc=2) leaves a
# live controller with no sanctioned way to stop it. Both were measured as having NO assertion at all
# (review): removing either refusal, or leaving a stale candidate fatal, kept the suite at 0 failed.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --repo "$TMP/no-such-dir" --no-fetch 2>&1 )"; RC=$?
ck "(e) an unusable --repo is REFUSED (rc=$RC), never silently replaced by another checkout" \
   "$([ "$RC" -eq 2 ] && case "$OUT" in *"--repo $TMP/no-such-dir is not a directory"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and the refusal NAMES the flag and the value it refused" \
   "$(case "$OUT" in *"--repo $TMP/no-such-dir is not a directory"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ THE FLAG BEATS AN INHERITED CANDIDATE THAT DISAGREES (review P1): every other arm sets `--repo` and
# `HARNESS_REPO` to the SAME path, so "explicit wins" was never distinguished from "inherited wins" — a
# launcher preferring `HARNESS_REPO` over `--repo` stayed at 112/0. Both values here are VALID checkouts,
# so only the precedence can decide, and the child env records which one the launcher actually used.
: > "$FIXCELL/fix.log"; : > "$FIXCELL/live"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$FIXCELL" REPO="$WORK" HARNESS_REPO="$WORK" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" up --harness "$FH" --repo "$REPO_FIX" --no-fetch 2>&1 )"
ck "(e) an EXPLICIT --repo BEATS a valid but different inherited HARNESS_REPO" \
   "$(grep -qx "env HARNESS_REPO=$REPO_FIX" "$FIXCELL/fix.log" 2>/dev/null && echo 0 || echo 1)"
ck "(e) …and the banner names that same harness repo" \
   "$(case "$OUT" in *"harness repo $REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --repo "$TMP/plaindir" --no-fetch 2>&1 )"; RC=$?
ck "(e) a --repo that is a directory but NOT a checkout is REFUSED (rc=$RC)" \
   "$([ "$RC" -eq 2 ] && case "$OUT" in *"--repo $TMP/plaindir is not a git checkout"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and the message names it as not a git checkout" \
   "$(case "$OUT" in *"--repo $TMP/plaindir is not a git checkout"*) echo 0 ;; *) echo 1 ;; esac)"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_REPO="$TMP/pruned-pin-worktree" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" status --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(e) a STALE ambient HARNESS_REPO (a pruned pin worktree) is SKIPPED, not fatal (rc=$RC, not a refusal)" "$([ "$RC" -ne 2 ] && echo 0 || echo 1)"
ck "(e) …so the pin still resolves in the next candidate (the launcher's own checkout)" \
   "$(case "$OUT" in *'pin: OK'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and the skip is SAID, not silent" \
   "$(case "$OUT" in *"ignoring '$TMP/pruned-pin-worktree'"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ `rev-parse --git-dir` WALKS UP (review P2): a candidate that is a plain SUBDIR of some checkout used
# to be accepted as the harness, and the pin was then resolved in that foreign object DB — the #2356
# symptom one inherited candidate further in, with no warning. The acceptance test now requires the
# candidate to BE the toplevel, so this arm answers "is this the repo" rather than "is this inside one".
mkdir -p "$WORK/sub"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_REPO="$WORK/sub" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" status --harness "$FH" --no-fetch 2>&1 )"
ck "(e) a HARNESS_REPO that is a SUBDIR of a checkout is SKIPPED, not accepted as the harness" \
   "$(case "$OUT" in *"ignoring '$WORK/sub' (inside another checkout"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND A `--repo` THAT IS A SUBDIR IS REFUSED, not silently resolved in the ENCLOSING object DB — the
# root rule must cover the flag too, or the enumeration is one branch short of its own doctrine.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" REPO="$WORK" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --repo "$WORK/sub" --no-fetch 2>&1 )"; RC=$?
ck "(e) a --repo that is a SUBDIR of a checkout is REFUSED (rc=$RC)" \
   "$([ "$RC" -eq 2 ] && case "$OUT" in *"--repo $WORK/sub is inside another checkout"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND A `HARNESS_REPO` THAT IS A PLAIN DIRECTORY IS SKIPPED FOR THE STATED REASON: deleting that skip
# accepts the directory as the harness (no fallback) and the diagnostic reports the wrong reason — both
# unobservable before (review cycle 4).
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$FIXCELL" HARNESS_REPO="$TMP/plaindir" \
        HARNESS_PIN_DIR="$FIXPIN" HARNESS_PIN_FILE="$FIXCELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        HU_CLAIMS_TIMEOUT=5 bash "$FIX/harness-up" status --harness "$FH" --no-fetch 2>&1 )"
ck "(e) a HARNESS_REPO that is a plain directory is SKIPPED with the not-a-checkout reason" \
   "$(case "$OUT" in *"ignoring '$TMP/plaindir' (not a git checkout)"*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and the pin still resolves in the next candidate (the launcher's own checkout)" \
   "$(case "$OUT" in *'pin: OK'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …so the pin is read in the launcher's own checkout, never in the foreign repo" \
   "$(case "$OUT" in *'pin: OK'*) echo 0 ;; *) echo 1 ;; esac)"
# ── THE FLAT-COPY LAYOUT CAN STILL NAME ITS HARNESS — under the key that means ONE thing ───────────
# A deployed copy lives outside any checkout (`install.sh` writes a flat copy; a plist execs it), so the
# own-checkout fallback has nothing to read. The config file is that box's only statement of where its
# harness lives, and it must be `HARNESS_REPO=` — the pre-split `REPO=` key is the WORK repo now, and
# reading it here is exactly the conflation #2356 removes. No other arm covers this candidate, so a
# regression dropping it would ship green.
FLAT="$TMP/flat"
printf 'HARNESS_REPO=%s\n' "$REPO_FIX" > "$TMP/harness.env"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" ENV_FILE="$TMP/harness.env" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FLAT/harness-up" status --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
ck "(e) a flat copy outside any checkout resolves its harness from the config file's HARNESS_REPO (rc=$RC, not a refusal)" "$([ "$RC" -ne 2 ] && echo 0 || echo 1)"
ck "(e) …and the pin resolves there (pin: OK, never UNRESOLVABLE)" \
   "$(case "$OUT" in *'pin: OK'*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND IT RESOLVED IN THE HARNESS, NOT IN A FOREIGN REPO — a distinct detector, not a second copy of the
# line above: the pin line must name the HARNESS fixture's commit ($B12). A work-repo read answers a
# different sha (or nothing), so this line can fail where the one above passes.
ck "(e) …and the resolved object is the HARNESS fixture's commit ($B12), not the work repo's tip" \
   "$(pinline2="$(printf '%s\n' "$OUT" | grep -m1 'pin:')"; case "$pinline2" in *"$B12"*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AND WITH NO CANDIDATE AT ALL, `status` CONTINUES AND SAYS BROKEN — it does NOT refuse (review: the
# earlier arm claimed a refusal that the code never implemented, so it passed for either behaviour). What
# must be true is that the screen NAMES the unresolvable harness, reports cannot-verify, and never prints
# an OK row about a tree nobody named.
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$CELL" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$CELL/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FLAT/harness-up" status --harness "$PIN_TREE" --no-fetch 2>&1 )"; RC=$?
ck "(e) a flat copy with NO candidate reports BROKEN for status (rc=$RC), naming the unresolvable harness" \
   "$([ "$RC" -eq 2 ] && case "$OUT" in *'no agent-infra checkout resolved'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) …and the pin row is UNRESOLVED (cannot-verify), NOT a pass from the operator's own checkout" \
   "$(case "$OUT" in *'pin: UNRESOLVED'*) case "$OUT" in *'pin: OK'*) echo 1 ;; *) echo 0 ;; esac ;; *) echo 1 ;; esac)"
ck "(e) …and the verdict is BROKEN, never HEALTHY over a tree nobody named" \
   "$(case "$OUT" in *'VERDICT: BROKEN'*) echo 0 ;; *) echo 1 ;; esac)"
# ⛔ AN UNRESOLVABLE PIN NAMES THE REPO IT LOOKED IN — naming the WORK repo there is the refusal that
# sends the reader to the wrong place (the class this PR removes), and it was unasserted.
BADPIN2="$TMP/cell-badpin2"
mkdir -p "$BADPIN2/.pi/agent/state"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$BADPIN2/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$PIN_TREE" > "$BADPIN2/.harness-path"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$BADPIN2" REPO="$WORK" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$BADPIN2/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --no-fetch 2>&1 )"
ck "(e) an UNRESOLVABLE pin names the HARNESS repo it searched, not the work repo" \
   "$(case "$OUT" in *"is not an object in the harness repo $REPO_FIX"*) echo 0 ;; *) echo 1 ;; esac)"

# ── the RED control: the check still REFUSES a pin that names nothing this box can resolve ───────
BAD="$TMP/cell-badpin"
mkdir -p "$BAD/.pi/agent/state"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$BAD/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$PIN_TREE" > "$BAD/.harness-path"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" HOME="$TMP/home" CELL_HOME="$BAD" REPO="$WORK" HARNESS_REPO="$REPO_FIX" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$BAD/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$UP" status --harness "$PIN_TREE" --no-fetch 2>&1 )"
ck "(e) RED control: a pin naming no resolvable commit is still UNRESOLVABLE" \
   "$(case "$OUT" in *'pin: UNRESOLVABLE'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) RED control: …and it is never reported as OK" \
   "$(case "$OUT" in *'pin: OK'*) echo 1 ;; *) echo 0 ;; esac)"
# …and `up` REFUSES to start on it (the refusal is the point; a measurement is not consent).
# ⛔ THE ASSERTION MUST NAME THE PIN STEP: `cmd_up` refuses with rc 3 and the word REFUSED at TWO
# independent steps (the pin, and capacity), so `rc!=0 && REFUSED` also passes when the PIN refusal is
# broken. Name the pin's own sentence and prove NOTHING was started (an empty authority log).
: > "$FIXCELL/fix.log"
OUT="$( cd "$TMP" && PATH="$TMP:$PATH" FIX_LOG="$FIXCELL/fix.log" FIX_LIVE="$FIXCELL/live" \
        HOME="$TMP/home" CELL_HOME="$BAD" REPO="$WORK" \
        HARNESS_PIN_DIR="$PINROOT" HARNESS_PIN_FILE="$BAD/.harness-path" \
        HU_PS="$TMP/ps-probe" PS_TABLE="$TMP/ps-none" HU_LOADAVG_FILE="$TMP/load" HU_NCPU=4 \
        bash "$FIX/harness-up" up --harness "$FH" --no-fetch 2>&1 )"; RC=$?
ck "(e) RED control: 'up' REFUSES on an unresolvable pin (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
ck "(e) RED control: …and it says REFUSED (not a warning)" \
   "$(case "$OUT" in *REFUSED*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) RED control: …the refusal is the PIN step, not the capacity step" \
   "$(case "$OUT" in *'pin: UNRESOLVABLE'*) echo 0 ;; *) echo 1 ;; esac)"
ck "(e) RED control: …so the authority was never asked to start anything" \
   "$([ ! -s "$FIXCELL/fix.log" ] && echo 0 || echo 1)"

# ── the suite's own non-vacuity floor (the #1890 class) ────────────────────────────────────────
ck "non-vacuity: at least 20 assertions ran (ran: $assertions)" "$([ "$assertions" -ge 20 ] && echo 0 || echo 1)"
printf '\n%s\n' "harness-surface.test.sh: $assertions assertions, $fails failed"
if [ "$fails" -ne 0 ]; then printf 'FAILED: %s assertion(s)\n' "$fails"; exit 1; fi
printf 'ALL PASS\n'
exit 0
