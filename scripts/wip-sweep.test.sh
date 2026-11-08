#!/usr/bin/env bash
# wip-sweep.test.sh — the regression contract for agent-infra#3485.
#
# ⛔ WHY THIS EXISTS. `bg-rescue-wip.sh` is wired into `spawn-gate.sh`'s `run_agent` AT ITS END, so it
# rescues a lane that stops THROUGH that function — and nothing else. A lane killed by the OOM reaper,
# a crash, or a cell quiesce leaves its work in the working tree and nowhere else, and a quiesce then
# destroys the disk. `wip-sweep.sh` is the sweep that closes that gap, and because of what it is for,
# the suite builds REAL `git init --bare` remotes for the runs it makes (one arm then repoints origin at
# a missing path, deliberately, to assert the unreadable-origin case) and the properties that matter are
# pinned separately:
#
#   1. the work REACHES ORIGIN — and its CONTENT is the content that was dirty (a ref that exists but
#      does not carry the work is vacuous, so the case reads the blob back);
#   2. the sweep does not change the state it is sweeping — the branch does not move and the working
#      tree is not touched, because the lane it is archiving may still be running;
#   3. DRY RUN IS THE DEFAULT and pushes NOTHING — the arming decision is the caller's command line;
#   4. the per-pass cap DEFERS, and says so: a capped pass is INCOMPLETE, never clean;
#   5. `UNMEASURED` is its own verdict and is NEVER "nothing to rescue" — an unreadable worktree, an
#      unresolvable repo, a missing delegate and a failed archive all fail the pass loudly;
#   6. a ref the sweep creates is either tied to an issue or REPORTED as not tied — F1/F3/F5 pin the
#      report, and the doc says the archive still reaches origin without a link.
#
# WHAT THIS FILE DOES NOT DO, stated so a green run is not over-read: not every arm touches a remote.
# The suite builds real `git init --bare` remotes for the runs it makes and reads the records those runs
# write; some arms drive no remote at all (a refusal against an unreadable path, a `--print-status` read
# of a hand-written record), and a refusal arm may still build a fixture, because a refusal is a claim
# about that fixture's effect rather than about its absence. No assertion is recorded without an
# observation from that run, and NO INVENTORY OF WHICH ARM TOUCHES A REMOTE IS WRITTEN HERE: four
# attempts at one were wrong within a round of being written, so this header states the shape and lets
# the arms speak for themselves.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$HERE/wip-sweep.sh"
RR="$HERE/bg-rescue-wip.sh"
[ -f "$SW" ] || { echo "❌ missing $SW"; exit 1; }
[ -f "$RR" ] || { echo "❌ missing $RR"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭  SKIP: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wip-sweep.XXXXXX")"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
echo "==> wip-sweep contract ($HERE)"
echo "    scratch: $T"

# ⛔ SIGPIPE SAFE. `printf … | grep -q` is the shape scripts/check-no-sigpipe-grep.sh exists to keep
# out of this tree: under `pipefail` the producer takes 141 after grep's first match, the pipeline
# returns non-zero, and a MATCHING payload reports as missing. Capture, then match a here-string.
has() { grep -q -- "$2" <<<"$1"; }

# ref_of <repo> <ref> — the sha, or "" — never the echoed argument (`rev-parse <missing>` prints the
# argument and exits 128, which reads as a successful lookup).
ref_of() { git -C "$1" rev-parse -q --verify "$2" 2>/dev/null; }

# n_refs <bare> — the count, but only after proving the remote is there: an absent repo also yields 0,
# which would make "pushed nothing" a vacuous assertion.
n_refs() {
  [ -d "$1" ] || { echo "NO_REPO"; return 1; }
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || { echo "NO_REPO"; return 1; }
  # `grep -c` PRINTS 0 and EXITS 1 on empty input, so `|| true` keeps the single printed count.
  git -C "$1" for-each-ref refs/wip --format=x 2>/dev/null | grep -c '' 2>/dev/null || true
}

# blob_of <bare> <rev> <path> — the file's content, or "".
blob_of() { git -C "$1" show "$2:$3" 2>/dev/null; }

# mk_fixture <name> <branch> — a bare "origin" plus a clone checked out on <branch>, one commit,
# pushed. Returns NON-ZERO if any step failed: without `-e` a silent fixture failure would degrade an
# arm into a green assertion about nothing.
mk_fixture() {
  local n="$1" b="$2" d="$T/$1"
  mkdir -p "$d" || return 1
  git init -q --bare "$d/origin.git" || return 1
  git init -q -b "$b" "$d/wt" || return 1
  git -C "$d/wt" config user.email t@t || return 1
  git -C "$d/wt" config user.name t || return 1
  printf 'base\n' > "$d/wt/base.txt" || return 1
  git -C "$d/wt" add base.txt || return 1
  git -C "$d/wt" commit -qm "base" || return 1
  git -C "$d/wt" remote add origin "$d/origin.git" || return 1
  git -C "$d/wt" push -q -u origin "$b" 2>/dev/null || return 1
}

# sweep <state-dir> <args...> — run the sweep with its own state dir, output captured.
sweep() {
  local st="$1"; shift
  WIP_SWEEP_STATE_DIR="$st" bash "$SW" "$@" 2>&1
}

# ── K) THE CLASSIFIER THE SWEEP READS (`bg-rescue-wip.sh --verdict`) ─────────────────────────────────
# These arms run FIRST because every other assertion in this file is meaningless if the classifier can
# report `clean` for work it did not read.
echo; echo "── K. the ONE classifier: --verdict ──"
mk_fixture vclean fix/3485-vclean || { echo "❌ fixture failed (vclean)"; exit 1; }
O_V="$(bash "$RR" --verdict "$T/vclean/wt" 2>&1)"; RC_V=$?
[ "$RC_V" -eq 0 ] && has "$O_V" 'verdict=clean' && has "$O_V" 'paths=0' \
  && ok "K1 a CLEAN worktree is verdict=clean paths=0, exit 0" \
  || bad "K1 clean verdict wrong (rc=$RC_V): $O_V"
# ⛔ THE SLUG IS #3484's, NOT OURS. `fix/3485-vclean` follows the fleet's declared `<type>/<N>-<slug>`
# convention, so the classifier answers with the ISSUE-carrying ref component
# (`issue-3485-vclean`) — and the sweep must consume it rather than re-deriving a branch-shaped name.
# This arm is therefore also the integration point between #3484 and #3485: it pins that the sweep's
# caller reads WHAT THE CLASSIFIER WROTE, so a ref the rescue pushed is always the ref the index records.
has "$O_V" 'slug=issue-3485-vclean' \
  && ok "K1b the verdict names the classifier's OWN slug (#3484's issue-carrying form) — the caller never re-derives it" \
  || bad "K1b verdict did not carry slug=issue-3485-vclean: $O_V"

printf 'uncommitted edit\n' >> "$T/vclean/wt/base.txt"
printf 'untracked\n' > "$T/vclean/wt/new.txt"
O_V="$(bash "$RR" --verdict "$T/vclean/wt" 2>&1)"; RC_V=$?
[ "$RC_V" -eq 1 ] && has "$O_V" 'verdict=dirty' \
  && ok "K2 a DIRTY worktree is verdict=dirty, exit 1" \
  || bad "K2 dirty verdict wrong (rc=$RC_V): $O_V"
has "$O_V" 'paths=2' \
  && ok "K2b the dirty verdict carries the exact path count (2), so 'dirty' and 'how dirty' are one read" \
  || bad "K2b dirty verdict's path count is wrong or absent: $O_V"

mkdir -p "$T/vclean/wt/blocked" && printf 'hidden\n' > "$T/vclean/wt/blocked/inside.txt"
chmod 000 "$T/vclean/wt/blocked"
O_V="$(bash "$RR" --verdict "$T/vclean/wt" 2>&1)"; RC_V=$?
chmod 755 "$T/vclean/wt/blocked"
if [ "$(id -u)" = "0" ]; then
  skip "K3 an UNREADABLE directory cannot be simulated as root (chmod 000 still reads for uid 0) — the cannot-verify arm is UNPROVEN on this host"
else
  [ "$RC_V" -eq 2 ] && has "$O_V" 'verdict=cannot-verify' \
    && ok "K3 a worktree whose listing is INCOMPLETE is verdict=cannot-verify, exit 2 — never clean" \
    || bad "K3 an unreadable directory was not reported as cannot-verify (rc=$RC_V): $O_V"
  # ⛔ THE ASSERTION THAT MATTERS MOST IN THIS FILE. A path count on an unmeasured tree is the
  # "empty = clean" confusion this mode exists to remove.
  if has "$O_V" 'paths='; then
    bad "K3b cannot-verify carried a paths= field — an unenumerated tree has NO path count"
  else
    ok "K3b cannot-verify carries NO paths= field (an unknown count is not zero)"
  fi
fi

O_V="$(bash "$RR" --verdict "$T/vclean/origin.git" 2>&1)"; RC_V=$?
[ "$RC_V" -eq 2 ] && has "$O_V" 'verdict=cannot-verify' \
  && ok "K4 a path that is not a worktree is cannot-verify/2, not 'dirty'" \
  || bad "K4 a non-worktree path answered wrong (rc=$RC_V): $O_V"
# The ORDINARY mode's documented exit 1 for that same path must not move: the mode is additive.
bash "$RR" "$T/vclean/origin.git" >/dev/null 2>&1; RC_V=$?
[ "$RC_V" -eq 1 ] \
  && ok "K5 the SHIPPED contract is unchanged: plain bg-rescue-wip.sh still exits 1 for a non-worktree" \
  || bad "K5 plain-mode exit code moved for a non-worktree (rc=$RC_V, want 1)"

# ── A) ACCEPTANCE: a dirty worktree is archived WITHOUT any lane ending ─────────────────────────────
echo; echo "── A. acceptance: archived without a lane ending (the #3485 gap) ──"
mk_fixture acc fix/3485-acc || { echo "❌ fixture failed (acc)"; exit 1; }
A="$T/acc"
printf 'the fix that would have been lost to an OOM kill\n' >> "$A/wt/base.txt"
printf 'brand new untracked file\n' > "$A/wt/untracked.txt"
BEFORE_BR="$(ref_of "$A/wt" fix/3485-acc)"
BEFORE_WT="$(git -C "$A/wt" status --porcelain | sort | tr '\n' '|')"
O="$(sweep "$T/state-acc" --apply --repo "$A/wt")"; RC=$?
[ "$RC" -eq 0 ] && ok "A1 --apply exits 0 with the work archived" || bad "A1 --apply exit $RC (want 0): $O"
# The ref NAME is #3484's: a branch that carries an issue is archived under `refs/wip/issue-<N>-…`.
SHA="$(ref_of "$A/origin.git" refs/wip/issue-3485-acc)"
[ -n "$SHA" ] && ok "A2 refs/wip/issue-3485-acc exists on ORIGIN (read back from the bare remote)" \
               || bad "A2 no refs/wip/issue-3485-acc on origin — the sweep archived nothing"
has "$(blob_of "$A/origin.git" "$SHA" untracked.txt)" 'brand new untracked file' \
  && ok "A3 the UNTRACKED file's CONTENT is in the archived tree" \
  || bad "A3 the archived tree is missing the untracked file's content"
has "$(blob_of "$A/origin.git" "$SHA" base.txt)" 'lost to an OOM kill' \
  && ok "A4 the UNSTAGED tracked edit's CONTENT is in the archived tree" \
  || bad "A4 the archived tree is missing the tracked edit"
[ "$(ref_of "$A/wt" fix/3485-acc)" = "$BEFORE_BR" ] \
  && ok "A5 the BRANCH did not move (a sweep must not commit to the lane's branch)" \
  || bad "A5 the branch moved — the sweep changed the state it was sweeping"
[ "$(git -C "$A/wt" status --porcelain | sort | tr '\n' '|')" = "$BEFORE_WT" ] \
  && ok "A6 the WORKING TREE is unchanged (safe to run under a live lane)" \
  || bad "A6 the working tree changed — the sweep touched what it was archiving"
ROW="$(grep 'issue-3485-acc' "$T/state-acc/wip-sweep.tsv" 2>/dev/null | head -1)"
has "$ROW" 'archived' && has "$ROW" 'refs/wip/issue-3485-acc' \
  && ok "A7 the INDEX row names the verdict and the ISSUE-CARRYING ref (#3484's naming, in the record)" \
  || bad "A7 the index row is missing verdict/ref: $ROW"
# ⛔ THE ISSUE COLUMN ITSELF, POSITIVELY (review finding P1). A7 is satisfied by the REF column
# (`refs/wip/issue-3485-acc`, whose `3485` arrives from the ref name) and by the BRANCH column
# (`fix/3485-acc`), both of which are present whatever the `issue` column holds — so deleting issue
# derivation entirely left the suite at PASS. Measured: with `issue="$(issue_of "$br")"` replaced by
# `issue=""` the whole suite stayed green while A7 passed. This arm reads column 9 directly.
ACCIssue="$(awk -F'\t' '$4 == "fix/3485-acc" {print $9; exit}' "$T/state-acc/wip-sweep.tsv" 2>/dev/null)"
[ "$ACCIssue" = "3485" ] \
  && ok "A7b the index row's issue COLUMN is 3485 (derived from the branch, not inferred from another column)" \
  || bad "A7b the issue column is '$ACCIssue' (want 3485) — the link agent-infra#3484 needs is absent"

# ⛔ THE ARCHIVE IS READ BACK FROM ORIGIN, NOT INFERRED FROM AN EXIT CODE (review round 1, finding F3).
# `bg-rescue-wip.sh` exits 0 BOTH for "archived and pushed" AND for "clean — nothing at risk", so a tree
# that went clean between the verdict and the rescue would otherwise be recorded as archived with a ref
# that does not exist. Arm A8 pins the read-back; arm E6 pins what happens when it does not find one.
has "$ROW" 'archived-ref-present-on-origin' \
  && ok "A8 the row records that the ref was READ BACK from origin, not inferred from exit 0" \
  || bad "A8 the row does not record the origin read-back: $ROW"

# ── B) DRY RUN IS THE DEFAULT ───────────────────────────────────────────────────────────────────────
echo; echo "── B. dry run is the DEFAULT and pushes NOTHING ──"
mk_fixture dry fix/3485-dry || { echo "❌ fixture failed (dry)"; exit 1; }
printf 'work\n' >> "$T/dry/wt/base.txt"
O="$(sweep "$T/state-dry" --repo "$T/dry/wt")"; RC=$?
[ "$RC" -eq 1 ] && ok "B1 a dry run that finds WIP exits 1 — not 0 (it is not a clean box)" \
                || bad "B1 dry-run exit $RC (want 1): $O"
[ "$(n_refs "$T/dry/origin.git")" = "0" ] \
  && ok "B2 the DEFAULT pushed NOTHING (the arming decision is the caller's command line)" \
  || bad "B2 the default pass pushed a ref — dry-run is not the default"
grep -q 'dry-run-would-archive' "$T/state-dry/wip-sweep.tsv" 2>/dev/null \
  && ok "B3 the index records what it WOULD have archived" \
  || bad "B3 the index has no dry-run row"
grep -qx 'mode=dry-run' "$T/state-dry/wip-sweep.status" 2>/dev/null \
  && ok "B4 the pass record says mode=dry-run (the record never implies work was done)" \
  || bad "B4 the pass record does not say mode=dry-run"

# ── C) THE PER-PASS CAP DEFERS, AND SAYS SO ────────────────────────────────────────────────────────
echo; echo "── C. the per-pass cap is BOUNDED, and a capped pass is INCOMPLETE ──"
mk_fixture cap fix/3485-cap-a || { echo "❌ fixture failed (cap)"; exit 1; }
git -C "$T/cap/wt" worktree add -q "$T/cap/wt2" -b fix/3485-cap-b 2>/dev/null
git -C "$T/cap/wt" worktree add -q "$T/cap/wt3" -b fix/3485-cap-c 2>/dev/null
printf 'a\n' >> "$T/cap/wt/base.txt"
printf 'b\n' > "$T/cap/wt2/b.txt"
printf 'c\n' > "$T/cap/wt3/c.txt"
O="$(sweep "$T/state-cap" --apply --max 1 --repo "$T/cap/wt")"; RC=$?
[ "$RC" -eq 1 ] && ok "C1 --max 1 with three dirty worktrees exits 1 (INCOMPLETE, not clean)" \
                || bad "C1 capped pass exit $RC (want 1): $O"
[ "$(n_refs "$T/cap/origin.git")" = "1" ] \
  && ok "C2 the cap held: exactly ONE ref reached origin" \
  || bad "C2 the cap did not hold — $(n_refs "$T/cap/origin.git") refs reached origin"
grep -q '^deferred=2$' "$T/state-cap/wip-sweep.status" 2>/dev/null \
  && ok "C3 the record names deferred=2 — work left behind is a STATED fact" \
  || bad "C3 the record does not name deferred=2"
grep -q '^archived=1$' "$T/state-cap/wip-sweep.status" 2>/dev/null \
  && ok "C4 the record distinguishes archived=1 from deferred=2" \
  || bad "C4 the record cannot distinguish archived from deferred"
# ⛔ THE PASS BUDGET BOUNDS THE PASS, NOT ONLY THE ARCHIVES (review finding). It used to be tested
# inside the dirty/apply branch only, so a pass over many CLEAN worktrees cost
# `count × status-timeout` whatever the budget said — 2.3 h on the checkout this file cites, on the path
# a cell quiesce runs before the box goes. A stub whose `--verdict` sleeps longer than the budget is the
# cheap deterministic reproduction: three worktrees, budget 1s, and the pass must STOP and SAY so.
mk_fixture bud fix/3485-bud || { echo "❌ fixture failed (bud)"; exit 1; }
git -C "$T/bud/wt" worktree add -q "$T/bud/w2" -b fix/3485-bud-b 2>/dev/null
git -C "$T/bud/wt" worktree add -q "$T/bud/w3" -b fix/3485-bud-c 2>/dev/null
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  '  *" --verdict "*) sleep 2; echo "verdict=clean paths=0 branch=x slug=x issue=-"; exit 0 ;;' \
  'esac' \
  'exit 0' > "$T/stub-slow.sh"
chmod +x "$T/stub-slow.sh"
O="$(WIP_SWEEP_RESCUE="$T/stub-slow.sh" WIP_SWEEP_BUDGET=1 sweep "$T/state-bud" --apply --repo "$T/bud/wt" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "C5 a spent pass budget ends the pass with exit 1 (INCOMPLETE), not a green 0" \
                || bad "C5 a spent budget exited $RC (want 1): $O"
grep -q 'budget_stopped=yes' "$T/state-bud/wip-sweep.status" 2>/dev/null \
  && ok "C5b the record says the BUDGET ended the pass (not the cap, not a clean finish)" \
  || bad "C5b the record does not name the budget stop"
# A ROW FOR EVERY WORKTREE THE PASS DID NOT REACH (review finding 2, round 2). The first cut wrote the
# row inside a microsecond window and left NOTHING behind, so a stopped pass's index could not be
# reconciled against `git worktree list` — an under-report in the OPTIMISTIC direction.
# ⛔ COUNT THE COLUMN, NOT THE WORD (review finding, round 3). `grep -c 'unreached'` matches the word in
# ANY field — a path, a note, a ref — so it could be inflated to pass while a row was missing. Column 6
# is the verdict.
# EXACTLY one per un-reached worktree: `-ge 2` would also pass a regression that wrote the same row
# twice (a flush at the record boundary AND at EOF), which is the duplicate this whole parser shape can
# produce.
# The fixture has THREE worktrees and the stub's `--verdict` alone outlasts `WIP_SWEEP_BUDGET=1`, so the
# very first classification is the one the budget cuts off: every record is `unreached`, hence exactly 3.
NUR="$(awk -F'\t' '$6 == "unreached" {c++} END {print c+0}' "$T/state-bud/wip-sweep.tsv" 2>/dev/null)"
[ "${NUR:-0}" -eq 3 ] \
  && ok "C5c exactly one unreached row per worktree the budget cut off (${NUR:-0} of 3, counted in column 6)" \
  || bad "C5c ${NUR:-0} unreached row(s) for 3 worktrees (want exactly 3)"
# and the columns are not transposed: 4 is `branch`, 5 is `head`
URBAD="$(awk -F'\t' '$6 == "unreached" && ($4 !~ /^fix\// || $5 !~ /^[0-9a-f]+$/) {print; exit}' "$T/state-bud/wip-sweep.tsv" 2>/dev/null)"
[ -z "$URBAD" ] \
  && ok "C5d the unreached rows carry branch in column 4 and head in column 5 (not swapped)" \
  || bad "C5d an unreached row has its columns transposed: $URBAD"
# ⛔ AND THE BRANCH IS NORMALISED, like every examined row's: a bare swap still leaves
# `refs/heads/<b>` in the branch column, so reconciliation by branch fails one step later.
URREF="$(awk -F'\t' '$6 == "unreached" && $4 ~ /^refs\// {print $4; exit}' "$T/state-bud/wip-sweep.tsv" 2>/dev/null)"
[ -z "$URREF" ] \
  && ok "C5e the unreached rows\' branch is normalised (no raw refs/heads/<b>) — the same shape as examined rows" \
  || bad "C5e an unreached row carries a raw ref in the branch column: $URREF"

# ── D) UNMEASURED IS NEVER CLEAN (the sweep's own copy of the three-verdict rule) ──────────────────
echo; echo "── D. an UNMEASURED worktree fails the pass; it is never 'nothing to rescue' ──"
mk_fixture unk fix/3485-unk || { echo "❌ fixture failed (unk)"; exit 1; }
mkdir -p "$T/unk/wt/blocked" && printf 'hidden\n' > "$T/unk/wt/blocked/inside.txt"
chmod 000 "$T/unk/wt/blocked"
O="$(sweep "$T/state-unk" --apply --repo "$T/unk/wt")"; RC=$?
chmod 755 "$T/unk/wt/blocked"
if [ "$(id -u)" = "0" ]; then
  skip "D1-D3 cannot be measured as root (chmod 000 still reads for uid 0) — the UNMEASURED arms are UNPROVEN on this host"
else
  [ "$RC" -eq 3 ] && ok "D1 an unreadable worktree makes the pass exit 3 (fail-closed)" \
                  || bad "D1 an unreadable worktree exited $RC (want 3): $O"
  has "$O" 'UNMEASURED' && ok "D2 the pass SAYS UNMEASURED out loud" \
                        || bad "D2 the pass did not say UNMEASURED: $O"
  grep -q 'cannot-verify' "$T/state-unk/wip-sweep.tsv" 2>/dev/null \
    && ok "D3 the index records the cannot-verify row (the unmeasured tree is a fact in the record)" \
    || bad "D3 the index has no cannot-verify row"
  grep -q '^unmeasured=1$' "$T/state-unk/wip-sweep.status" 2>/dev/null \
    && ok "D4 the pass record counts it as unmeasured, not as clean" \
    || bad "D4 the pass record does not count unmeasured"
fi

# ── E) A FAILED ARCHIVE IS NOT A CLEAN PASS ───────────────────────────────────────────────────────
echo; echo "── E. a rescue that FAILED leaves the work on disk — and the pass says so ──"
mk_fixture rej fix/3485-rej || { echo "❌ fixture failed (rej)"; exit 1; }
printf '#!/bin/sh\nexit 1\n' > "$T/rej/origin.git/hooks/pre-receive"
chmod +x "$T/rej/origin.git/hooks/pre-receive"
printf 'work that must not be recorded as archived\n' >> "$T/rej/wt/base.txt"
O="$(sweep "$T/state-rej" --apply --repo "$T/rej/wt")"; RC=$?
[ "$RC" -eq 3 ] && ok "E1 a REJECTED push fails the pass (exit 3)" || bad "E1 rejected push exit $RC (want 3): $O"
has "$O" 'STILL ONLY ON THIS DISK' \
  && ok "E2 the pass says the work is STILL ONLY ON THIS DISK (the rescue's own wording, re-printed)" \
  || bad "E2 the pass did not say the work is still only on disk: $O"
grep -q '^failed=1$' "$T/state-rej/wip-sweep.status" 2>/dev/null \
  && ok "E3 the pass record counts failed=1" \
  || bad "E3 the pass record does not count failed=1"
grep -q 'rescue-exit-2' "$T/state-rej/wip-sweep.tsv" 2>/dev/null \
  && ok "E4 the index row names the rescue's exit code and records NO ref" \
  || bad "E4 the index row does not name the rescue's exit code"
[ "$(n_refs "$T/rej/origin.git")" = "0" ] \
  && ok "E5 nothing reached origin (and the remote was proven present, so 0 means 0)" \
  || bad "E5 a ref reached origin despite a rejected push"

# ── E6) EXIT 0 IS NOT EVIDENCE: the archive ref is read back, and its ABSENCE fails the pass ──────
echo; echo "── E6. a rescue that says 0 but left no ref is NOT recorded as archived ──"
# The TOCTOU arm (review round 1, finding F3). `WIP_SWEEP_RESCUE` is the documented seam, so a stub that
# answers `--verdict` honestly and then exits 0 having archived NOTHING is exactly the shape a tree that
# went clean between the two calls produces — and it must not be recorded, counted, or reported as an
# archive.
mk_fixture toc fix/3485-toc || { echo "❌ fixture failed (toc)"; exit 1; }
STUB="$T/stub-rescue.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  '  *" --verdict "*) echo "verdict=dirty paths=1 branch=fix/3485-toc slug=issue-3485-toc issue=3485"; exit 1 ;;' \
  'esac' \
  'exit 0' > "$STUB"
chmod +x "$STUB"
printf 'work the stub will not archive\n' >> "$T/toc/wt/base.txt"
O="$(WIP_SWEEP_RESCUE="$STUB" sweep "$T/state-toc" --apply --repo "$T/toc/wt")"; RC=$?
[ "$RC" -eq 3 ] && ok "E6a a rescue that exits 0 without leaving a ref fails the pass (exit 3)" \
                || bad "E6a exit 0 with no ref was accepted (rc=$RC, want 3): $O"
grep -q 'rescue-exited-0-but-ref-absent-on-origin' "$T/state-toc/wip-sweep.tsv" 2>/dev/null \
  && ok "E6b the index records the absence by name" \
  || bad "E6b the index does not record the absent ref"
grep -q '^archived=0$' "$T/state-toc/wip-sweep.status" 2>/dev/null \
  && ok "E6c archived=0 — no counter was incremented on an unverified archive" \
  || bad "E6c an unverified archive was counted as archived"
# ⛔ THE THIRD ARM OF THE SAME READ-BACK: origin cannot be read at all. That is NOT "not archived" and
# NOT "archived" — it is UNVERIFIED, and the pass must say so rather than pick either answer.
mk_fixture tcu fix/3485-tcu || { echo "❌ fixture failed (tcu)"; exit 1; }
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  '  *" --verdict "*) echo "verdict=dirty paths=1 branch=fix/3485-tcu slug=issue-3485-tcu issue=3485"; exit 1 ;;' \
  'esac' \
  'exit 0' > "$T/stub-rescue2.sh"
chmod +x "$T/stub-rescue2.sh"
git -C "$T/tcu/wt" remote set-url origin "$T/tcu/not-a-remote.git" 2>/dev/null
O="$(WIP_SWEEP_RESCUE="$T/stub-rescue2.sh" sweep "$T/state-tcu" --apply --repo "$T/tcu/wt")"; RC=$?
[ "$RC" -eq 3 ] && ok "E7a an UNREADABLE origin fails the pass (exit 3) instead of picking a verdict" \
                || bad "E7a an unreadable origin exited $RC (want 3): $O"
grep -q 'archive-ref-unverifiable' "$T/state-tcu/wip-sweep.tsv" 2>/dev/null \
  && ok "E7b the index says UNVERIFIABLE — neither archived nor absent" \
  || bad "E7b the index does not record the unverifiable read-back"

# ── F) AN ARCHIVE WITH NO ISSUE LINK IS REPORTED ───────────────────────────────────────────────────
echo; echo "── F. an archive that cannot be tied to an issue is REPORTED, not silently keyed ──"
mk_fixture noi topic-no-digits || { echo "❌ fixture failed (noi)"; exit 1; }
printf 'work\n' >> "$T/noi/wt/base.txt"
O="$(sweep "$T/state-noi" --apply --repo "$T/noi/wt")"; RC=$?
has "$O" 'NO ISSUE LINK' \
  && ok "F1 a dirty branch with no issue number is reported loudly" \
  || bad "F1 no report for an unlinkable branch: $O"
grep -q '^no_issue=1$' "$T/state-noi/wip-sweep.status" 2>/dev/null \
  && ok "F2 the pass record counts no_issue=1" \
  || bad "F2 the pass record does not count the unlinkable branch"
grep -q "$(printf 'topic-no-digits')" "$T/state-noi/wip-sweep.tsv" 2>/dev/null \
  && grep -q 'archived' "$T/state-noi/wip-sweep.tsv" 2>/dev/null \
  && ok "F3 the work IS still archived (an unlinked archive beats no archive) and recorded" \
  || bad "F3 the unlinked work was not archived/recorded"
[ "$RC" -eq 0 ] && ok "F4 a MISSING issue link is a report, not a pass failure (the archive landed)" \
                || bad "F4 an unlinkable branch failed the pass (rc=$RC)"
# ⛔ A DETACHED HEAD IS NOT AN ISSUE LINK (review finding). `--verdict` synthesises
# `detached-<short-sha>`, and the 2-8 digit extraction matched HEX out of it (`detached-a1234bc` →
# `issue=1234`), so the index asserted a false attribution AND the NO ISSUE LINK report never fired on a
# shape that really occurs (a bisect or a review checkout).
mk_fixture det fix/3485-det || { echo "❌ fixture failed (det)"; exit 1; }
git -C "$T/det/wt" worktree add -q --detach "$T/det/dw" HEAD 2>/dev/null
printf 'work on a detached checkout\n' > "$T/det/dw/det.txt"
O="$(sweep "$T/state-det" --apply --repo "$T/det/wt" 2>&1)"; RC=$?
has "$O" 'NO ISSUE LINK' \
  && ok "F5 a DETACHED worktree reports NO ISSUE LINK (a hex run in detached-<sha> is not an issue)" \
  || bad "F5 a detached worktree was silently given an issue link: $O"
grep -q '^no_issue=1$' "$T/state-det/wip-sweep.status" 2>/dev/null \
  && ok "F5b the pass record counts it in no_issue" \
  || bad "F5b a detached worktree was not counted in no_issue"
# column 9 of the TSV is `issue`, column 4 is `branch`
ISSUECOL="$(awk -F'\t' '$4 ~ /^detached-/ {print $9; exit}' "$T/state-det/wip-sweep.tsv" 2>/dev/null)"
[ "$ISSUECOL" = "-" ] \
  && ok "F5c the detached row records issue=- (no number fabricated out of the short sha)" \
  || bad "F5c the detached row carries an issue it cannot have: '$ISSUECOL'"

# ⛔ THE ISSUE HAS ONE HOME: the CLASSIFIER'S answer, not a regex of our own (review finding P2).
# The index used to scan the branch for "the first 2-8 digit run" while `wip_ref_parts` trusts only a
# `<type>/<N>` prefix — so the two rules disagreed, in BOTH directions, on the surface #3484 exists to
# make trustworthy. Each direction is pinned against the REAL classifier, because a stub would only
# prove that our stub and our parser agree.
#
# DIRECTION 1 — OVER-CLAIM: digits that are NOT in the `<type>/<N>` position. The ref carries no issue,
# so the index must not assert one, and #3484's report MUST fire.
mk_fixture ovc fix/lane-3485 || { echo "❌ fixture failed (ovc)"; exit 1; }
printf 'work\n' >> "$T/ovc/wt/base.txt"
O="$(sweep "$T/state-ovc" --apply --repo "$T/ovc/wt" 2>&1)"; RC=$?
has "$O" 'NO ISSUE LINK' \
  && ok "F6 a branch whose digits are not in <type>/<N> position is REPORTED as unlinked (no invented link)" \
  || bad "F6 an unlinkable branch was silently given an issue: $O"
OVCCOL="$(awk -F'\t' '$4 == "fix/lane-3485" {print $9; exit}' "$T/state-ovc/wip-sweep.tsv" 2>/dev/null)"
[ "$OVCCOL" = "-" ] \
  && ok "F6b …and the index records issue=- — it does not assert a link the ref does not carry" \
  || bad "F6b the index asserted issue='$OVCCOL' for a ref that carries none"
grep -q '^no_issue=1$' "$T/state-ovc/wip-sweep.status" 2>/dev/null \
  && ok "F6c …and no_issue counts it, so the pass record does not hide the gap" \
  || bad "F6c no_issue did not count an unlinkable branch"
# DIRECTION 2 — UNDER-CLAIM: a SINGLE-digit issue is still a typed link. The old 2-8 digit floor said
# "no link" about a ref that plainly carries one.
mk_fixture unc fix/1-x || { echo "❌ fixture failed (unc)"; exit 1; }
printf 'work\n' >> "$T/unc/wt/base.txt"
O="$(sweep "$T/state-unc" --apply --repo "$T/unc/wt" 2>&1)"; RC=$?
has "$O" 'NO ISSUE LINK' \
  && bad "F7 a branch that DOES carry an issue was reported as unlinked: $O" \
  || ok "F7 a single-digit issue is a link — no false NO ISSUE LINK report"
UNCCOL="$(awk -F'\t' '$4 == "fix/1-x" {print $9; exit}' "$T/state-unc/wip-sweep.tsv" 2>/dev/null)"
[ "$UNCCOL" = "1" ] \
  && ok "F7b the index records the classifier's issue=1 for fix/1-x" \
  || bad "F7b the index recorded issue='$UNCCOL' for fix/1-x (want 1)"
# DIRECTION 3 — FAIL-CLOSED on a classifier that prints no `issue=` at all. The field is the only thing
# that may create a link, so its ABSENCE must under-claim (report) rather than fall back to a scan.
STUB_NOISS="$T/stub-noissue.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  '  *" --verdict "*) echo "verdict=dirty paths=1 branch=fix/3485-3435 slug=issue-3485-3435"; exit 1 ;;' \
  'esac' 'exit 0' > "$STUB_NOISS"
chmod +x "$STUB_NOISS"
O="$(WIP_SWEEP_RESCUE="$STUB_NOISS" sweep "$T/state-noiss" --apply --repo "$T/acc/wt" 2>&1)"; RC=$?
NOISCOL="$(awk -F'\t' '$4 == "fix/3485-3435" {print $9; exit}' "$T/state-noiss/wip-sweep.tsv" 2>/dev/null)"
[ "$NOISCOL" = "-" ] \
  && ok "F8 a classifier that prints NO issue= field yields issue=- (under-claim, never a fallback scan)" \
  || bad "F8 a missing issue= field produced issue='$NOISCOL' — a second rule crept back in"


# ── G) NO REPO / NO DELEGATE: REFUSE, NEVER "NOTHING TO RESCUE" ───────────────────────────────────
echo; echo "── G. nothing to sweep is NOT 'nothing to rescue' ──"
O="$(sweep "$T/state-norepo" --apply --repo "$T/definitely-not-a-repo")"; RC=$?
[ "$RC" -eq 3 ] && ok "G1 a repo this pass cannot read exits 3 (fail-closed)" \
                || bad "G1 an unreadable repo exited $RC (want 3): $O"
has "$O" 'UNMEASURED' \
  && ok "G2 it says UNMEASURED rather than reporting a clean empty sweep" \
  || bad "G2 it did not say UNMEASURED: $O"
# ⛔ THE AMBIENT-`$REPO` ARM (added reviewing this file). `REPO` is a name the cell supervisor and
# the Mac bring-up both export, and an earlier draft of the sweep adopted it as a default repo — so a
# run from `$T` (not a repo at all) swept a REAL checkout because the shell happened to have `REPO`
# set: measured, 139 worktrees examined and 7 archives pushed to a real origin by an arm that was
# meant to prove "no repo resolvable". That is why the default is gone, and this arm pins its absence:
# `REPO` naming a genuinely dirty fixture must still produce a REFUSAL and must push NOTHING.
mk_fixture amb fix/3485-amb || { echo "❌ fixture failed (amb)"; exit 1; }
printf 'work that must not be archived by an ambient default\n' >> "$T/amb/wt/base.txt"
O="$(cd "$T" && export REPO="$T/amb/wt" && unset WIP_SWEEP_REPOS && sweep "$T/state-empty" --apply)"; RC=$?
[ "$RC" -eq 3 ] && ok "G3 an ambient \$REPO is NOT adopted as a default repo (exit 3, no repo resolvable)" \
                || bad "G3 ambient \$REPO was adopted — exit $RC (want 3): $O"
has "$O" 'no repo to scan' \
  && ok "G4 it names the reason ('no repo to scan') instead of answering 0" \
  || bad "G4 the no-repo refusal did not name its reason: $O"
[ "$(n_refs "$T/amb/origin.git")" = "0" ] \
  && ok "G4b the ambient \$REPO's work was NOT archived (the refusal is an EFFECT, not just an exit code)" \
  || bad "G4b an ambient \$REPO caused a push to an unasked-for repo"
O="$(WIP_SWEEP_RESCUE="$T/missing-rescue.sh" sweep "$T/state-nodeleg" --apply --repo "$T/acc/wt")"; RC=$?
[ "$RC" -eq 3 ] && ok "G5 a MISSING rescue is a refusal (the spawn-gate rescue=UNAVAILABLE rule)" \
                || bad "G5 missing rescue exit $RC (want 3): $O"
O="$(WIP_SWEEP_BOUNDED_LIB="$T/missing-lib.sh" sweep "$T/state-nolib" --apply --repo "$T/acc/wt")"; RC=$?
[ "$RC" -eq 3 ] && ok "G6 a MISSING bounded-execution lib is a refusal, never an unbounded pass" \
                || bad "G6 missing lib exit $RC (want 3): $O"
O="$(sweep "$T/state-badmax" --apply --max seven --repo "$T/acc/wt")"; RC=$?
[ "$RC" -eq 2 ] && ok "G7 an UNPARSEABLE --max is refused (a typo'd bound must never mean 'no bound')" \
                || bad "G7 unparseable --max exit $RC (want 2): $O"

# ── H) A CLEAN REPO IS A CLEAN PASS ───────────────────────────────────────────────────────────────
echo; echo "── H. a clean box is the only thing that exits 0 ──"
mk_fixture cln fix/3485-cln || { echo "❌ fixture failed (cln)"; exit 1; }
O="$(sweep "$T/state-cln" --apply --repo "$T/cln/wt")"; RC=$?
[ "$RC" -eq 0 ] && ok "H1 a clean worktree exits 0" || bad "H1 clean exit $RC (want 0): $O"
[ "$(n_refs "$T/cln/origin.git")" = "0" ] && ok "H2 no ref is manufactured for a clean tree" \
                                          || bad "H2 a ref was pushed for a clean tree"
# ⛔ COMMITS ONLY ON THIS DISK ARE REPORTED (review finding P1). The rescue archives UNCOMMITTED work and
# says so; a clean tree with unpushed commits therefore read as `clean`, and the pass reported exit 0 =
# "nothing left at risk" over a worktree whose only copy of those commits was that disk. The pass still
# cannot save them — but it must SAY so, count them, and put them on the monitoring surface.
mk_fixture unp fix/3485-unp || { echo "❌ fixture failed (unp)"; exit 1; }
printf 'a commit no remote has\n' > "$T/unp/wt/local-only.txt"
git -C "$T/unp/wt" add local-only.txt 2>/dev/null
git -C "$T/unp/wt" commit -qm "local only" 2>/dev/null
O="$(sweep "$T/state-unp" --apply --repo "$T/unp/wt" 2>&1)"; RC=$?
has "$O" 'COMMITS ONLY ON THIS DISK' \
  && ok "U1 a clean tree with unpushed commits is REPORTED, not silently 'nothing at risk'" \
  || bad "U1 unpushed commits were not reported: $O"
grep -q '^unpushed_worktrees=1$' "$T/state-unp/wip-sweep.status" 2>/dev/null \
  && ok "U1b the pass record counts it (a green summary cannot hide a worktree that dies with the box)" \
  || bad "U1b the pass record does not count unpushed worktrees"
UPCNT="$(awk -F'\t' '$4 == "fix/3485-unp" {print $12; exit}' "$T/state-unp/wip-sweep.tsv" 2>/dev/null)"
[ "$UPCNT" = "1" ] \
  && ok "U1c the index row carries the unpushed count (column 12 = 1)" \
  || bad "U1c the index row does not carry the unpushed count (got '$UPCNT')"
[ "$RC" -eq 0 ] && ok "U1d it is a REPORT, not a failure (this tool cannot archive branch commits)" \
                || bad "U1d unpusheable work failed the pass (rc=$RC)"
# AND THE COUNT SURVIVES ON THE DEFERRED ROWS (review finding 4, round 2): those are exactly the rows
# where work was NOT archived, so a '-' there hid the highest-risk case.
mk_fixture upc fix/3485-upc || { echo "x fixture failed (upc)"; exit 1; }
git -C "$T/upc/wt" worktree add -q "$T/upc/w2" -b fix/3485-upc-b 2>/dev/null
printf 'x\n' > "$T/upc/w2/x.txt"
printf 'y\n' >> "$T/upc/wt/base.txt"
sweep "$T/state-upc" --apply --max 1 --repo "$T/upc/wt" >/dev/null 2>&1
DEFCNT="$(awk -F'\t' '$11 ~ /deferred/ && $12 != "-" && $12 != "" {c++} END {print c+0}' "$T/state-upc/wip-sweep.tsv" 2>/dev/null)"
[ "${DEFCNT:-0}" -ge 1 ] \
  && ok "U1e a DEFERRED row still carries its unpushed count (not '-')" \
  || bad "U1e a deferred row dropped the unpushed column"
# ⛔ U2 — AN UNMEASURED COUNT IS NOT ZERO (#3588 review, cycle 9). The unreadable arm set `unpushed="?"`,
# incremented NO counter and set NO failure, so a `rev-list` that timed out or errored wrote
# `unpushed_worktrees=0` into a record that still said `status=ok rc=0`. The quiesce's whole refuse-DONE
# check reads that count, so it printed DONE over commits it had never counted — the false PASS this PR
# exists to close, one state over. The only trace was a `?` in a TSV column no caller reads.
mk_fixture unpu fix/3485-unpu || { echo "❌ fixture failed (unpu)"; exit 1; }
printf 'local only\n' > "$T/unpu/wt/local.txt"
git -C "$T/unpu/wt" add local.txt 2>/dev/null
git -C "$T/unpu/wt" commit -qm "local only" 2>/dev/null
mkdir -p "$T/unpubin"
UNP_REAL="$(command -v git)"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" rev-list --count "*) exit 128 ;;\nesac\nexec %s "$@"\n' \
  "$UNP_REAL" > "$T/unpubin/git"
chmod +x "$T/unpubin/git"
O_U2="$(PATH="$T/unpubin:$PATH" WIP_SWEEP_STATE_DIR="$T/state-unpu" bash "$SW" --apply --repo "$T/unpu/wt" 2>&1)"; RC_U2=$?
[ "$RC_U2" -eq 3 ] \
  && ok "U2 an UNREADABLE unpushed count FAILS the pass (exit 3), never reads as zero" \
  || bad "U2 an unreadable unpushed count answered rc=$RC_U2 (want 3) — a green record over a count nobody took: $O_U2"
grep -qx 'status=failed' "$T/state-unpu/wip-sweep.status" 2>/dev/null \
  && ok "U2b the record says status=failed, so no reader can take it for a clean pass" \
  || bad "U2b the record says status=$(sed -n 's/^status=//p' "$T/state-unpu/wip-sweep.status" 2>/dev/null)"
grep -q '^unpushed_unmeasured=1$' "$T/state-unpu/wip-sweep.status" 2>/dev/null \
  && ok "U2c the record counts it (unpushed_unmeasured=1), so the failure is attributable" \
  || bad "U2c the record does not count the unmeasured probe: $(grep -c . "$T/state-unpu/wip-sweep.status" 2>/dev/null) line(s)"
has "$O_U2" 'UNMEASURED' \
  && ok "U2d …and it SAYS so, naming the worktree whose state is unknown" \
  || bad "U2d the failure is silent: $O_U2"
grep -q 'nothing-at-risk' "$T/state-cln/wip-sweep.tsv" 2>/dev/null \
  && ok "H3 the index records the clean verdict" || bad "H3 the index has no clean row"
# ⛔ H4 IS ITS OWN COMMAND, AND THE LINE BREAK ABOVE IS LOAD-BEARING (measured 2026-11-07).
# `ok()` and `bad()` BOTH end in `echo`, so both return 0 (`:40-41`). Joined onto H3's `bad` call as
# `… row"grep -q '^seen=1$' …`, the whole thing is ONE `bad` invocation whose last argument happens to
# be a filename: its `echo` still returns 0, so the `&&` below fired on EVERY run and **H4 could not
# fail** — and in the H3-failing direction the `grep` never ran at all. Nothing else asserts `seen=1` in
# the positive direction (`Q4`/`Q7` want 0, and `J6`'s identity is satisfied by `0 == 0+0+0+0`), so a
# regression that stopped counting examinations read as a fully green suite: a false PASS on the rescue
# path, which is the class this whole file exists to close.
# ⛔ NOT VACUOUS — measured on a `seen=0` mutant of `wip-sweep.sh`, same fixtures:
#     joined (as shipped): PASS=198 FAIL=1, H4 ✅  (only J6 red)
#     split  (this text) : PASS=197 FAIL=2, H4 ❌  (`the record does not show the worktree was examined`)
# and on the HEALTHY sweep this text is PASS=199 FAIL=0 — so the break buys the arm its teeth without
# trading a false-green for a false-red. Do not re-join it.
grep -q '^seen=1$' "$T/state-cln/wip-sweep.status" 2>/dev/null \
  && ok "H4 seen=1 — the pass EXAMINED the main worktree (a zero-examined pass is a failure)" \
  || bad "H4 the record does not show the worktree was examined"

# ── I) --print-status ─────────────────────────────────────────────────────────────────────────────
echo; echo "── I. --print-status answers from the record alone ──"
WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "I1 a fresh ok record answers 0" || bad "I1 fresh record answered $RC (want 0)"
WIP_SWEEP_STATE_DIR="$T/state-absent" bash "$SW" --print-status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "I2 NO record answers 3 (never-run is not success)" || bad "I2 absent record answered $RC (want 3)"
mkdir -p "$T/state-stale" && printf 'status=ok\nrc=0\nts=1\ndetail=x\n' > "$T/state-stale/wip-sweep.status"
WIP_SWEEP_STATE_DIR="$T/state-stale" bash "$SW" --print-status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "I3 a STALE record answers 3 — a sweeper that stopped running is not a green box" \
                || bad "I3 stale record answered $RC (want 3)"
# ⛔ AND IT MUST NOT PRINT `ok` WHILE EXITING 3 (review finding). The verb `cat`-ed the record — which
# says `status=ok` — and then exited 3, so a consumer parsing the key=value surface the doc nominates
# read a green status off a box that is not being swept.
OST="$(WIP_SWEEP_STATE_DIR="$T/state-stale" bash "$SW" --print-status 2>/dev/null)"
has "$OST" 'status=stale' \
  && ok "I7 a STALE record PRINTS status=stale — the printed surface agrees with the exit code" \
  || bad "I7 a stale record printed a status that disagrees with its exit code: $OST"
# NOT A LINE-ANCHORED MATCH: the first cut printed the raw value as `recorded_status=ok`, which
# CONTAINS `status=ok` — so a `grep 'status=ok'` consumer still read green off a stale record. This arm
# is a SUBSTRING test on the whole print, deliberately.
if grep -q 'status=ok' <<<"$OST"; then
  bad "I7b the stale print still contains the substring status=ok — a grep consumer reads green"
else
  ok "I7b no emitted key CONTAINS status=ok (recorded= / recorded_rc= cannot collide)"
fi
# ⛔ AND THE PASSTHROUGH IS PART OF THE SAME GUARANTEE (review finding, round 8). I7b's fixture writes
# `detail=x`, and the three filters upstream of the print are ANCHORED (`^status=`), so a record whose
# OTHER keys carry the literal `status=ok` — here a `detail=` — reached the print verbatim while the
# script exited 3. That is the same consumer-side false green I7b exists to close, one key over.
mkdir -p "$T/state-xdetail"
printf 'status=failed\nrc=3\nts=%s\ndetail=note: status=ok was seen earlier\n' "$(date -u '+%s')" \
  > "$T/state-xdetail/wip-sweep.status"
OST2="$(WIP_SWEEP_STATE_DIR="$T/state-xdetail" bash "$SW" --print-status 2>/dev/null)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7d a record whose OTHER key carries status=ok still answers 3" \
                || bad "I7d answered $RC (want 3)"
if grep -q 'status=ok' <<<"$OST2"; then
  bad "I7e a passthrough line still CONTAINS status=ok — a grep consumer reads green off an rc=3 box"
else
  ok "I7e no passthrough line CONTAINS status=ok either (the pass-through is part of the guarantee)"
fi
# ⛔ AND THE ECHOED VALUES ARE THE SAME GUARANTEE ONE KEY OVER (review finding, round 9). The filter
# behind I7e drops record LINES; `recorded=`, `recorded_rc=` and the `detail=` derived from an
# unreadable `ts=` print record VALUES, which never pass through it. Measured on the pre-fix reader: a
# stale record reading `status=note status=ok` printed `recorded=note status=ok` while exiting 3, and
# `ts=status=ok` reached the surface inside the reader's OWN detail line. Values are REDACTED now, so
# the audit trail survives instead of the line vanishing.
mkdir -p "$T/state-xval1" "$T/state-xval2" "$T/state-xval3"
printf 'status=note status=ok\nrc=3\nts=1\ndetail=x\n' > "$T/state-xval1/wip-sweep.status"
OST3="$(WIP_SWEEP_STATE_DIR="$T/state-xval1" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7f a record whose STATUS VALUE carries status=ok still answers 3" \
                || bad "I7f answered $RC (want 3)"
if grep -q 'status=ok' <<<"$OST3"; then
  bad "I7f2 a raw record VALUE still CONTAINS status=ok — a grep consumer reads green"
else
  ok "I7f2 a raw record VALUE cannot CONTAIN status=ok on ANY channel (recorded= redacted, fd2 too)"
fi
# ⛔ THE STDERR CHANNEL, AND THE FALLBACK REASON IN PARTICULAR (review finding, round 11). The first
# version of this arm read the STALE fixture above (`ts=1`), whose reason is "the record is Ns old" —
# it embeds NO record value, so fd 2 never carried `status=ok` for that record: the arm was GREEN over
# the very defect it names, and a verifier proved it by reverting the redaction and watching the arm
# stay green. The fixture that ACTUALLY leaks on fd 2 is the CATCH-ALL one — a judgeable record whose
# `DERIVED_WHY` is empty, so the refusal quotes the record's own `recorded status='…' rc='…'` — and it
# is the `recorded status='…'` fallback branch that needs its own arm. Fresh `ts=` on purpose.
mkdir -p "$T/state-xval4"
printf 'status=note status=ok\nrc=3\nts=%s\ndetail=x\n' "$(date -u '+%s')" \
  > "$T/state-xval4/wip-sweep.status"
OSTC="$(WIP_SWEEP_STATE_DIR="$T/state-xval4" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7i a judgeable record with a poisoned status VALUE answers 3" \
                || bad "I7i answered $RC (want 3)"
if grep -q 'status=ok' <<<"$OSTC"; then
  bad "I7i2 the catch-all refusal still quotes a RAW record value — the combined surface reads green"
else
  ok "I7i2 the catch-all refusal quotes a REDACTED value (this branch was unarmed before)"
fi
SERR="$(WIP_SWEEP_STATE_DIR="$T/state-xval4" bash "$SW" --print-status 2>&1 >/dev/null)"
if grep -q 'status=ok' <<<"$SERR"; then
  bad "I7f3 the STDERR channel still carries status=ok off a corrupt record"
else
  ok "I7f3 the STDERR channel is redacted too — fd 2 cannot read green either"
fi
# ⛔ THE THIRD DOOR: A CALLER-SUPPLIED SEAM VALUE (review finding, round 12). The redaction first lived
# beside the RECORD reads, so a value the caller put in a seam — `--max 'status=ok'`,
# `WIP_SWEEP_MAX=status=ok`, a rescuer path containing it — was echoed verbatim by `refuse_startup`'s
# `detail=`, on a surface that exits 3. Those values now go through the same sink, because the sink
# moved to `refuse_startup` itself. Each arm reads the COMBINED surface (the refusal also reaches fd 2
# in pass mode, and a consumer reads `2>&1`).
O="$(WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status --max 'status=ok' 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7j(argv) a caller-supplied BOUND reading status=ok still answers 3" \
                || bad "I7j(argv) answered $RC (want 3)"
if grep -q 'status=ok' <<<"$O"; then
  bad "I7j2(argv) the refusal echoed the caller's raw --max value (detail= is the leak)"
else
  ok "I7j2(argv) the refusal detail= is redacted (a caller's --max cannot read green)"
fi
O="$(WIP_SWEEP_MAX='status=ok' WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7j(env) a caller-supplied ENV bound reading status=ok still answers 3" \
                || bad "I7j(env) answered $RC (want 3)"
if grep -q 'status=ok' <<<"$O"; then
  bad "I7j2(env) the refusal echoed the caller's raw WIP_SWEEP_MAX (detail= is the leak)"
else
  ok "I7j2(env) the refusal detail= is redacted (a caller's env bound cannot read green)"
fi
O="$(WIP_SWEEP_RESCUE="$T/status=ok-no-rescuer.sh" WIP_SWEEP_STATE_DIR="$T/state-cln" \
      bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7k an unreadable RESCUER path containing status=ok still answers 3" \
                || bad "I7k answered $RC (want 3)"
if grep -q 'status=ok' <<<"$O"; then
  bad "I7k2 the rescuer refusal echoed the caller's raw path"
else
  ok "I7k2 the rescuer refusal is redacted"
fi
# ⛔ AND THE RECORD PATH, which is a caller-supplied value too (`WIP_SWEEP_STATE_DIR`), so it is NOT a
# declared limit — the redaction reaches it like every other value the reader prints.
mkdir -p "$T/state=status=ok"
O="$(WIP_SWEEP_STATE_DIR="$T/state=status=ok" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7l a state dir NAMED with status=ok and no record still answers 3" \
                || bad "I7l answered $RC (want 3)"
if grep -q 'status=ok' <<<"$O"; then
  bad "I7l2 the no-record line printed the record PATH raw — the last undeclared door"
else
  ok "I7l2 the record path is redacted too, so no caller-supplied value reads green"
fi
# ⛔ THE PATH ON THE OTHER MESSAGE (review finding, round 13). I7l used a state dir with NO record, so it
# exercised ONLY the no-record line. The catch-all refusal prints the SAME variables — and it was left
# raw: measured, a `state=status=ok` dir holding a `status=bogus` record put the substring on BOTH
# channels at exit 3 while this suite was fully green. That fixture is what every earlier arm missed.
mkdir -p "$T/state=status=ok-bogus"
printf 'status=bogus\nrc=3\nts=%s\n' "$(date -u '+%s')" > "$T/state=status=ok-bogus/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state=status=ok-bogus" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7m a poisoned record PATH reaching the CATCH-ALL refusal still answers 3" \
                || bad "I7m answered $RC (want 3)"
if grep -q 'status=ok' <<<"$O"; then
  bad "I7m2 the catch-all refusal printed a caller-supplied PATH raw — fd 1 or fd 2 reads green"
else
  ok "I7m2 both refusal messages redact the path (the same variable in two messages)"
fi
# ⛔ AND THE CONTRACT IS KEY-SCOPED (round 13). Whatever else the surface carries, the LAST `^status=`
# line must agree with the exit — that is the shape `docs/ops/wip-sweep.md` tells consumers to rely on, so
# it gets an arm instead of being implied. The extra `frobnicate=status=ok` line is the noise that a
# substring consumer trips over and a key consumer ignores.
printf 'status=bogus\nrc=3\nts=%s\nfrobnicate=status=ok\n' "$(date -u '+%s')" \
  > "$T/state=status=ok-bogus/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state=status=ok-bogus" bash "$SW" --print-status 2>/dev/null)"; RC=$?
LAST_STATUS="$(sed -n 's/^status=//p' <<<"$O" | tail -1)"
{ [ "$LAST_STATUS" = failed ] && [ "$RC" -eq 3 ]; } \
  && ok "I7n the LAST ^status= key is the DERIVED failed while the exit is 3 — the key contract holds" \
  || bad "I7n last status='$LAST_STATUS' with rc=$RC (want failed/3)"
# ⛔ A VALUE MUST NOT BE ABLE TO START A LINE (review finding, round 14). The key contract is "the LAST
# `^status=` agrees with the exit", so a value that prints a SECOND `^status=` line BELOW the derived one
# defeats it — and redaction alone cannot fix that, because the injected line need not contain
# `status=ok` at all. Two vectors, both measured on the pre-fix code: a record with TWO `status=` lines
# (`sed` returns BOTH, so `recorded=` emitted the second as its own line) and a caller-supplied PATH
# containing a newline. Values are flattened at the sink now, so neither can add a line.
mkdir -p "$T/state-multi"
printf 'status=bogus\nrc=3\nts=%s\nstatus=status=ok\n' "$(date -u '+%s')" \
  > "$T/state-multi/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state-multi" bash "$SW" --print-status 2>/dev/null)"; RC=$?
NST="$(grep -c '^status=' <<<"$O")"
LAST_STATUS="$(sed -n 's/^status=//p' <<<"$O" | tail -1)"
{ [ "$RC" -eq 3 ] && [ "$NST" -eq 1 ] && [ "$LAST_STATUS" = failed ]; } \
  && ok "I7o a MULTI-LINE record value cannot add a second ^status= line (n=$NST, last=$LAST_STATUS)" \
  || bad "I7o n_status=$NST last='$LAST_STATUS' rc=$RC (want 1/failed/3)"
NL_DIR="$T/nl"$'\n'"status=incomplete"
mkdir -p "$NL_DIR"
printf 'status=bogus\nrc=3\nts=%s\n' "$(date -u '+%s')" > "$NL_DIR/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$NL_DIR" bash "$SW" --print-status 2>&1)"; RC=$?
NST="$(grep -c '^status=' <<<"$O")"
LAST_STATUS="$(sed -n 's/^status=//p' <<<"$O" | tail -1)"
{ [ "$RC" -eq 3 ] && [ "$NST" -eq 1 ] && [ "$LAST_STATUS" = failed ]; } \
  && ok "I7p a seam PATH containing a NEWLINE cannot add a second ^status= line (n=$NST)" \
  || bad "I7p n_status=$NST last='$LAST_STATUS' rc=$RC (want 1/failed/3)"
# ⛔ THE OTHER TWO PASSTHROUGH FILTERS WERE UNPINNED (review finding, round 23 — P1). Every arm counted
# `^status=`, and NO arm counted `^rc=` or `^recorded=`. Deleting `| grep -v '^rc='` left this suite
# fully GREEN while the reader echoed the RECORD's own `rc=0` line ABOVE the derived `rc=3` — so a
# first-match consumer (`grep '^rc=' | head -1`) read GREEN off a box the script reported as failed,
# and the file's "exactly ONE `^rc=` line, both LAST and both DERIVED" was false. The `^recorded` filter
# was equally ungraded (cosmetic rather than a false green, but unpinned is unpinned).
# The fixture carries its own `rc=` AND `recorded=` lines, so each filter is individually load-bearing.
mkdir -p "$T/state-keys"
printf 'status=bogus\nrc=0\nts=%s\nrecorded=ok\nrecorded_rc=0\n' "$(date -u '+%s')" \
  > "$T/state-keys/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state-keys" bash "$SW" --print-status 2>/dev/null)"; RC=$?
NST="$(grep -c '^status=' <<<"$O")"
NRC="$(grep -c '^rc=' <<<"$O")"
NREC="$(grep -c '^recorded=' <<<"$O")"
NRRC="$(grep -c '^recorded_rc=' <<<"$O")"
LAST_RC="$(sed -n 's/^rc=//p' <<<"$O" | tail -1)"
FIRST_RC="$(sed -n 's/^rc=//p' <<<"$O" | head -1)"
{ [ "$RC" -eq 3 ] && [ "$NST" -eq 1 ] && [ "$NRC" -eq 1 ] && [ "$LAST_RC" = 3 ] && [ "$FIRST_RC" = 3 ]; } \
  && ok "I7u exactly ONE ^rc= line and it is the DERIVED 3 — the record's own rc= does not leak" \
  || bad "I7u rc=$RC n_status=$NST n_rc=$NRC first_rc=$FIRST_RC last_rc=$LAST_RC (want 3/1/1/3/3)"
{ [ "$NREC" -eq 1 ] && [ "$NRRC" -eq 1 ]; } \
  && ok "I7v exactly ONE recorded= and ONE recorded_rc= — a foreign record's own lines are dropped" \
  || bad "I7v n_recorded=$NREC n_recorded_rc=$NRRC (want 1/1)"
# ⛔ AND THE CARRIAGE RETURN, SEPARATELY (review finding, round 15). A bare CR is not a line break to
# `grep`, so an arm that counts `^status=` on RAW output cannot see it — the defect only appears once a
# reader normalises CR to LF (a log shipper, `tr`, a Windows-side consumer). This arm therefore
# normalises BEFORE counting; without it, removing the `\r` flattening from `redact()` left the whole
# suite GREEN over a real injection.
CR_DIR="$T/cr"$'\r'"status=incomplete"
mkdir -p "$CR_DIR"
printf 'status=bogus\nrc=3\nts=%s\n' "$(date -u '+%s')" > "$CR_DIR/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$CR_DIR" bash "$SW" --print-status 2>&1)"; RC=$?
NST="$(printf '%s\n' "$O" | tr '\r' '\n' | grep -c '^status=')"
LAST_STATUS="$(printf '%s\n' "$O" | tr '\r' '\n' | sed -n 's/^status=//p' | tail -1)"
{ [ "$RC" -eq 3 ] && [ "$NST" -eq 1 ] && [ "$LAST_STATUS" = failed ]; } \
  && ok "I7q a seam PATH containing a CARRIAGE RETURN cannot add a ^status= line once CR is normalised" \
  || bad "I7q n_status=$NST (CR-normalised) last='$LAST_STATUS' rc=$RC (want 1/failed/3)"
# ⛔ AND THE CONTROLS A GREP-SHAPED ARM CANNOT SEE (review finding, round 16). `\v` and `\f` are not
# line breaks to `grep`, so counting `^status=` on the raw output cannot detect them — but
# `str.splitlines()` (Python, and the JSON/log readers built on it) splits on both, so a record reading
# `ts=17\vstatus=incomplete` forged a `status=` line BELOW the derived one for those consumers while
# `grep` saw one line and stayed GREEN. The sink is an allow-list now (printable ASCII only). This arm
# normalises the two bytes IT carries (`\v`, `\f`) and no more — it is NOT a splitlines-complete normaliser, and
# arm I7q above is CR-only. The splitlines-complete coverage is the UNION of I7o/I7p (LF), I7q (CR),
# I7r (VT) and I7s.1-7 (FF, 0x1c/0x1d/0x1e, U+0085, U+2028, U+2029) — each of those reddens when that
# class alone loses the allow-list. ⛔ NOT I7s ALONE: the loop carries only the seven listed above, so
# attributing LF/CR/VT to it would license deleting exactly the arms that catch them. FF is in that loop precisely because it was NOT covered
# when this comment claimed it was, and a FF-only mutant scored a full green suite.
mkdir -p "$T/state-vt"
printf 'status=bogus\nrc=3\nts=17\vstatus=incomplete\ndetail=x\n' > "$T/state-vt/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state-vt" bash "$SW" --print-status 2>&1)"; RC=$?
NST="$(printf '%s\n' "$O" | LC_ALL=C tr '\v\f' '\n\n' | grep -c '^status=')"
LAST_STATUS="$(printf '%s\n' "$O" | LC_ALL=C tr '\v\f' '\n\n' | sed -n 's/^status=//p' | tail -1)"
{ [ "$RC" -eq 3 ] && [ "$NST" -eq 1 ] && [ "$LAST_STATUS" = failed ]; } \
  && ok "I7r a VERTICAL-TAB value cannot forge a ^status= line for a splitlines() reader" \
  || bad "I7r splitlines-normalised n_status=$NST last='$LAST_STATUS' rc=$RC (want 1/failed/3)"
# ⛔ AND THE BREAKS THAT ARE NOT ORDINARY C0 CONTROLS (review finding, round 17). `str.splitlines()`
# breaks on 0x1c/0x1d/0x1e, on U+0085, and on U+2028/U+2029 — and `[:cntrl:]` matches only the first
# three in any locale, so a control-byte BLACKLIST could never close this. That is why the sink is an
# allow-list. Each arm normalises GREEDILY (every non-printable byte treated as a break) and requires the
# LAST `^status=` to still be the DERIVED one. ⛔ 0x1c-0x1e were MISSING from the first version of this
# loop, and a mutant keeping them uncovered scored 229/0 GREEN while forging the last `status=` line —
# so they are in the list precisely because their absence was measured, not because they looked likely.
_nbrk=0
for _brk in $'\x0c' $'\x1c' $'\x1d' $'\x1e' $'\xc2\x85' $'\xe2\x80\xa8' $'\xe2\x80\xa9'; do
  _nbrk=$((_nbrk+1))
  mkdir -p "$T/state-brk$_nbrk"
  printf 'status=bogus\nrc=3\nts=17%sstatus=incomplete\ndetail=x\n' "$_brk" \
    > "$T/state-brk$_nbrk/wip-sweep.status"
  O="$(WIP_SWEEP_STATE_DIR="$T/state-brk$_nbrk" bash "$SW" --print-status 2>&1)"; RC=$?
  NST="$(printf '%s\n' "$O" | LC_ALL=C tr -c '[:print:]\n' '\n' | grep -c '^status=')"
  LAST_STATUS="$(printf '%s\n' "$O" | LC_ALL=C tr -c '[:print:]\n' '\n' | sed -n 's/^status=//p' | tail -1)"
  { [ "$RC" -eq 3 ] && [ "$NST" -eq 1 ] && [ "$LAST_STATUS" = failed ]; } \
    && ok "I7s.$_nbrk a non-C0 line separator (splitlines-normalised n=$NST) cannot forge a ^status= line" \
    || bad "I7s.$_nbrk n_status=$NST last='$LAST_STATUS' rc=$RC (want 1/failed/3)"
done
# ⛔ AND THE SIBLING RESCUER FALLBACK, WHICH NOTHING GRADED (review finding, round 19). R8/R9 create a
# scratch dir with NO sibling, so they grade the `$HOME` FARM arm only. Deleting the `$SELF_DIR` sibling
# usability probe therefore left this suite fully GREEN while the reader answered `status=ok`/exit 0 over
# a box whose sibling rescuer is INERT — a false PASS, the exact class this PR exists to close. This arm
# puts an unusable sibling beside a copy of the sweep, with `$HOME` pointed at an empty dir so the farm
# cannot rescue it, and requires the refusal BY NAME.
mkdir -p "$T/sib/scripts" "$T/fakehome"
cp "$SW" "$T/sib/scripts/wip-sweep.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/sib/scripts/bg-rescue-wip.sh"
chmod +x "$T/sib/scripts/bg-rescue-wip.sh"
O="$(HOME="$T/fakehome" WIP_SWEEP_BOUNDED_LIB="$HERE/lib/bounded.sh" \
      WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$T/sib/scripts/wip-sweep.sh" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
  && ok "I7t an INERT sibling rescuer REFUSES — it never answers from the record" \
  || bad "I7t answered $RC (want 3) — a live false PASS on the sibling fallback"
has "$O" 'PRESENT-but-broken' \
  && ok "I7t2 and it names the sibling as present-but-broken, not as absent" \
  || bad "I7t2 the refusal does not name the sibling as present-but-broken: $O"
printf 'status=failed\nrc=3\nts=status=ok\ndetail=x\n' > "$T/state-xval2/wip-sweep.status"
OST4="$(WIP_SWEEP_STATE_DIR="$T/state-xval2" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7g a record whose ts= carries status=ok still answers 3" \
                || bad "I7g answered $RC (want 3)"
if grep -q 'status=ok' <<<"$OST4"; then
  bad "I7g2 the reader's OWN detail= echoed status=ok from an unreadable ts="
else
  ok "I7g2 the reader's own detail= is redacted too (a raw ts= never reaches the surface, fd1 or fd2)"
fi
# ⛔ AND THE REDACTION MUST NOT EAT A TRUE GREEN. A genuine `status=ok` is the reader's VERDICT and has
# to survive; only values that merely QUOTE the substring are redacted.
printf 'status=ok\nrc=status=ok\nts=%s\ndetail=none\n' "$(date -u '+%s')" \
  > "$T/state-xval3/wip-sweep.status"
OST5="$(WIP_SWEEP_STATE_DIR="$T/state-xval3" bash "$SW" --print-status 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "I7h a true-ok record with a poisoned rc= still answers 0" \
                || bad "I7h answered $RC (want 0)"
if grep -q 'recorded_rc=status=ok' <<<"$OST5"; then
  bad "I7h2 recorded_rc= echoed status=ok raw"
else
  ok "I7h2 recorded_rc= is redacted while the record is otherwise still ok"
fi
if grep -q '^status=ok$' <<<"$OST5"; then
  ok "I7h3 and the DERIVED status=ok IS still printed — redaction never eats a true green"
else
  bad "I7h3 a TRUE green lost its status=ok: $OST5"
fi
# ⛔ TWO ROUTES THE RECORD-VALUE ARMS ABOVE CANNOT SEE (review finding, round 10 follow-up). Every arm
# so far poisons a RECORD. The same guarantee is violated by content the record never touches, because
# the reader also splices a CALLER value and a PATH into its own printed lines — and both were measured
# at b03c916 answering `rc=3` with the literal on the surface:
#   WIP_SWEEP_MAX=status=ok          → `detail=WIP_SWEEP_MAX is not a non-negative integer: 'status=ok'`
#   WIP_SWEEP_STATE_DIR=…/status=ok…  → `detail=no pass record at …/status=ok/wip-sweep.status`
# The first arrives through `refuse_startup` (a surface no other arm exercises at all); the second
# through the never-run detail and, on a real record, through the catch-all refusal that names the
# record path. Redacting a path rewrites it only when it CARRIES the literal, so a normal path must
# stay byte-identical — I7k4 asserts both halves.
# ⛔ WHICH ARMS DISCRIMINATE: I7j2, I7k2, I7k3 (the `2`/`3` halves). The rc halves assert the EXIT, which
# the pre-fix code also returned 3 — co-assertions, not the catches. MEASURED on a /tmp copy with all
# four of the additions above reverted and nothing else changed: control PASS=217 FAIL=0, mutant
# PASS=214 FAIL=3, the three reds being exactly I7j2/I7k2/I7k3 — no other arm moved, I7k4 stayed green,
# and the last arm still reported.
OXENV="$(WIP_SWEEP_MAX='status=ok' WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7j an unparseable BOUND spelled status=ok still answers 3" \
                || bad "I7j answered $RC (want 3)"
if grep -q 'status=ok' <<<"$OXENV"; then
  bad "I7j2 the caller's own value reached the refusal detail — a grep consumer reads green off rc=3"
elif grep -q '^detail=WIP_SWEEP_MAX' <<<"$OXENV"; then
  ok "I7j2 the caller value is REDACTED in the refusal and the cause is still stated"
else
  bad "I7j2 the refusal detail was DROPPED — the cause is gone"
fi
mkdir -p "$T/state-ok-in-path/status=ok-dir"
OXPATH="$(WIP_SWEEP_STATE_DIR="$T/state-ok-in-path/status=ok-dir" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I7k a NEVER-RUN state dir whose PATH carries status=ok still answers 3" \
                || bad "I7k answered $RC (want 3)"
if grep -q 'status=ok' <<<"$OXPATH"; then
  bad "I7k2 the state PATH reached the never-run detail — a grep consumer reads green off an rc=3 box"
else
  ok "I7k2 the interpolated PATH is REDACTED in the never-run detail"
fi

printf 'status=failed\nrc=3\nts=%s\n' "$(date -u '+%s')" > "$T/state-ok-in-path/status=ok-dir/wip-sweep.status"
OXPATH3="$(WIP_SWEEP_STATE_DIR="$T/state-ok-in-path/status=ok-dir" bash "$SW" --print-status 2>&1)"; RC=$?
if grep -q 'status=ok' <<<"$OXPATH3"; then
  bad "I7k3 the record PATH reached the catch-all refusal unredacted — fd 2 reads green off rc=3"
else
  ok "I7k3 the catch-all refusal redacts the record PATH too (the residual this block used to declare)"
fi
# …AND A NORMAL PATH IS UNTOUCHED, so the fix cannot red a healthy box's diagnostics.
OXNORM="$(WIP_SWEEP_STATE_DIR="$T/state-absent" bash "$SW" --print-status 2>&1)"
if grep -q '^detail=no pass record at .*state-absent/wip-sweep.status$' <<<"$OXNORM" && ! grep -q '<redacted>' <<<"$OXNORM"; then
  ok "I7k4 an ordinary state path is printed UNCHANGED — redaction only rewrites a value carrying the literal"
else
  bad "I7k4 the ordinary path was rewritten or lost: $OXNORM"
fi
OST_RC="$(sed -n 's/^rc=//p' <<<"$OST" | tail -1)"
[ "$OST_RC" = "3" ] \
  && ok "I7c the printed rc= is the DERIVED one (3), not the recorded rc of a stale pass" \
  || bad "I7c the printed rc= is '$OST_RC' while the exit code is 3"
# A clock step BACKWARDS is not freshness either: `-gt` alone let a future-dated record answer 0 for
# the whole skew, on the one gate this pass hardened twice.
mkdir -p "$T/state-future"
printf 'status=ok\nrc=0\nts=%s\ndetail=x\n' "$(( $(date -u '+%s') + 31536000 ))" > "$T/state-future/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state-future" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I8 a record dated in the FUTURE answers 3 (a clock step backwards is not freshness)" \
                || bad "I8 a future-dated record answered $RC (want 3): $O"
has "$O" 'status=stale' \
  && ok "I8b it says stale, not ok" || bad "I8b a future-dated record's printed status is not stale: $O"
WIP_SWEEP_STATE_DIR="$T/state-cap" bash "$SW" --print-status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "I4 an INCOMPLETE record answers 1 (work was deferred — not clean, not failed)" \
                || bad "I4 incomplete record answered $RC (want 1)"
# ⛔ TWO WAYS A RECORD CLOCK WENT UNREAD AND ANSWERED 0 (review round 1, finding F4). The staleness test
# used to be `[ "$STALE_SECONDS" -gt 0 ] 2>/dev/null` and `[ -n "$S_TS" ]`, so an unparseable bound or a
# record with no `ts=` line SKIPPED the age check entirely and reported `status=ok` — a pass record of
# any age read as current.
O="$(cd "$T" && WIP_SWEEP_STALE_SECONDS=abc WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
# ⛔ THE READER ANSWERS A CONFIG REFUSAL INSTEAD OF EXITING SILENTLY (#3588 review, cycle 5). It is a
# consumer surface: exit 2 with no `status=`/`rc=` left a keyed consumer with nothing on exactly the box
# whose sweep refuses every pass. The INTENT this arm was written for is unchanged and is now stronger —
# a typo'd bound can never read as "no bound", and the answer is never green.
[ "$RC" -eq 3 ] && has "$O" 'status=failed' && has "$O" 'rc=3' \
  && ok "I5 an UNPARSEABLE WIP_SWEEP_STALE_SECONDS is refused AND answered (failed/3, a typo'd bound never means 'no bound')" \
  || bad "I5 unparseable stale bound answered $RC (want 3 with status=failed): $O"
# ⛔ AND A PLAUSIBLE-LOOKING VALUE MUST NOT DISABLE IT EITHER (review round 2, residual R1). `tb_timeout
# 0 …` is "unbounded" and `WIP_SWEEP_STALE_SECONDS=0` read as "do not check" — so a record from 1970
# answered `ok`. Only --max and WIP_SWEEP_BUDGET document 0 as a disable; the watchdogs and the
# staleness window do not.
O="$(cd "$T" && WIP_SWEEP_STALE_SECONDS=0 WIP_SWEEP_STATE_DIR="$T/state-stale" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && has "$O" 'status=failed' \
  && ok "I5b WIP_SWEEP_STALE_SECONDS=0 is REFUSED, not read as 'skip the staleness check'" \
  || bad "I5b a zero staleness window answered $RC (want 3 with status=failed): $O"
O="$(cd "$T" && WIP_SWEEP_STATUS_TIMEOUT=0 WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && has "$O" 'status=failed' \
  && ok "I5c WIP_SWEEP_STATUS_TIMEOUT=0 is REFUSED (a zero watchdog bound is 'unbounded' in bounded.sh)" \
  || bad "I5c a zero watchdog bound answered $RC (want 3 with status=failed): $O"
O="$(cd "$T" && WIP_SWEEP_RESCUE_TIMEOUT=0 WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && has "$O" 'status=failed' \
  && ok "I5d WIP_SWEEP_RESCUE_TIMEOUT=0 is REFUSED too (the rescue is the longest call on the quiesce path)" \
  || bad "I5d a zero rescue bound answered $RC (want 3 with status=failed): $O"
# ⛔ AND THE OTHER DIRECTION: the two seams that DO document 0 as a disable must still accept it. A gate
# that refuses everything is as useless as one that accepts everything, and `--max 0` / a zero budget
# are the documented "no cap" / "no pass budget" values.
O="$(cd "$T" && WIP_SWEEP_BUDGET=0 WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "I5e WIP_SWEEP_BUDGET=0 is still ACCEPTED (0 is a documented disable for the pass budget)" \
                || bad "I5e a zero pass budget was refused (rc=$RC, want 0): $O"
O="$(sweep "$T/state-max0" --apply --max 0 --repo "$T/cln/wt")"; RC=$?
[ "$RC" -eq 0 ] && ok "I5f --max 0 is still ACCEPTED (0 is a documented disable for the per-pass cap)" \
                || bad "I5f --max 0 was refused (rc=$RC, want 0): $O"
# ⛔ ACCEPTED IS NOT THE CLAIM — the SEAM MUST REACH ITS EFFECT (review finding P2). I5f ran against a
# CLEAN fixture, so "no cap" was indistinguishable from "a cap of zero"; and I5e ran `--print-status`,
# which never consults the budget at all. Measured: flipping `[ "$MAX" -gt 0 ]` to `-ge 0` (so `--max 0`
# archives NOTHING) and `[ "$BUDGET" -gt 0 ]` to `return 0` (so a zero budget is always exhausted) both
# left the suite green. These two arms run against a DIRTY fixture and require the work to move.
mk_fixture mx0 fix/3485-mx0 || { echo "x fixture failed (mx0)"; exit 1; }
printf 'work that --max 0 must still archive\n' >> "$T/mx0/wt/base.txt"
O="$(sweep "$T/state-mx0" --apply --max 0 --repo "$T/mx0/wt")"; RC=$?
[ "$RC" -eq 0 ] && [ "$(n_refs "$T/mx0/origin.git")" = "1" ] \
  && ok "I5g --max 0 means NO CAP: a dirty worktree is still archived (it is not a cap of zero)" \
  || bad "I5g --max 0 did not archive (rc=$RC, refs=$(n_refs "$T/mx0/origin.git")): $O"
mk_fixture bd0 fix/3485-bd0 || { echo "x fixture failed (bd0)"; exit 1; }
printf 'work that WIP_SWEEP_BUDGET=0 must still archive\n' >> "$T/bd0/wt/base.txt"
O="$(cd "$T" && WIP_SWEEP_BUDGET=0 WIP_SWEEP_STATE_DIR="$T/state-bd0" bash "$SW" --apply --repo "$T/bd0/wt" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(n_refs "$T/bd0/origin.git")" = "1" ] \
  && ok "I5h WIP_SWEEP_BUDGET=0 means NO BUDGET: the pass still archives (it is not 'always exhausted')" \
  || bad "I5h a zero budget did not archive (rc=$RC, refs=$(n_refs "$T/bd0/origin.git")): $O"
# ⛔ AN INTERRUPTED PASS MUST NOT READ AS OK (review finding P1). The record is now overwritten with
# `status=running` before any worktree is touched, so a pass that crashed / was OOM-killed / was cut off
# by a quiesce / could not write its verdict leaves `running` — never the previous pass's fresh `ok`.
# Measured before the fix: an unwritable state dir with one prior good pass exited 3 and `--print-status`
# still answered `rc=0 status=ok`.
# ⛔ AND THE WRITER, NOT ONLY THE READER (review finding P2). I9 hand-writes the marker, so DELETING the
# whole start-marker block left the suite at PASS — the fix this file's last commit is named after could be
# reverted silently. This arm runs a REAL pass whose delegate is slow, reads the record WHILE it is in
# flight, and requires `running`; then requires that the finished pass replaced it. A `kill -9` of the pass
# at that moment leaves a record that reads `failed`, never the previous `ok`.
mk_fixture mk fix/3485-mk || { echo "x fixture failed (mk)"; exit 1; }
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  '  *" --verdict "*) sleep 3; echo "verdict=clean paths=0 branch=x slug=x issue=-"; exit 0 ;;' \
  'esac' \
  'exit 0' > "$T/stub-slow2.sh"
chmod +x "$T/stub-slow2.sh"
( WIP_SWEEP_RESCUE="$T/stub-slow2.sh" WIP_SWEEP_STATE_DIR="$T/state-mk" \
    bash "$SW" --apply --repo "$T/mk/wt" >/dev/null 2>&1 ) &
MKD_PID=$!
MID=""
for _ in 1 2 3 4 5 6; do
  sleep 1
  MID="$(sed -n 's/^status=//p' "$T/state-mk/wip-sweep.status" 2>/dev/null)"
  [ "$MID" = "running" ] && break
done
wait "$MKD_PID" 2>/dev/null
[ "$MID" = "running" ] \
  && ok "I10 a pass IN FLIGHT records status=running (the marker is written by the run, before the work)" \
  || bad "I10 the in-flight record was '${MID:-<none>}' — nothing marks a pass as started"
FINAL="$(sed -n 's/^status=//p' "$T/state-mk/wip-sweep.status" 2>/dev/null)"
[ "$FINAL" = "ok" ] \
  && ok "I10b the finished pass REPLACED the marker with its verdict (status=ok)" \
  || bad "I10b the finished pass left status='$FINAL' (want ok)"

mkdir -p "$T/state-run" && printf 'status=running\nrc=?\nts=%s\ndetail=pass started\n' "$(date -u '+%s')" > "$T/state-run/wip-sweep.status"
O="$(WIP_SWEEP_STATE_DIR="$T/state-run" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "I9 a pass that never reached its verdict (status=running) answers 3, not ok" \
                || bad "I9 an interrupted pass answered $RC (want 3): $O"
has "$O" 'status=failed' \
  && ok "I9b it prints status=failed — the same word the pass would have written" \
  || bad "I9b an interrupted pass printed a status that reads green: $O"
mkdir -p "$T/state-nots" && printf 'status=ok\nrc=0\ndetail=x\n' > "$T/state-nots/wip-sweep.status"
WIP_SWEEP_STATE_DIR="$T/state-nots" bash "$SW" --print-status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "I6 a record with NO ts= answers 3 — an unreadable clock is not freshness" \
                || bad "I6 a record without ts= answered $RC (want 3)"

# ── J) A RECORD WHOSE CHECKOUT IS GONE IS NOT UNMEASURED ───────────────────────────────────────────
echo; echo "── J. a PRUNABLE worktree record is a skip, not a failed pass ──"
mk_fixture pru fix/3485-pru || { echo "❌ fixture failed (pru)"; exit 1; }
git -C "$T/pru/wt" worktree add -q "$T/pru/gone" -b fix/3485-pru-gone 2>/dev/null
printf 'archived before the checkout vanished\n' > "$T/pru/gone/kept.txt"
rm -rf "$T/pru/gone"
O="$(sweep "$T/state-pru" --apply --repo "$T/pru/wt")"; RC=$?
# ⛔ A LIVE PASS MEASURED THE OTHER BEHAVIOUR: two records whose directories had been reaped after they
# were listed made the pass exit 3 and report `unmeasured=2`, failing a box for work that could not
# exist. Git says `prunable`; a directory that is not there holds nothing.
[ "$RC" -eq 0 ] && ok "J1 a prunable record does NOT fail the pass (exit 0)" \
                || bad "J1 a prunable record failed the pass (rc=$RC): $O"
grep -q 'prunable-checkout-dir-absent' "$T/state-pru/wip-sweep.tsv" 2>/dev/null \
  && ok "J2 the index records WHY it was skipped (git's own prunable verdict, not a guess)" \
  || bad "J2 the index does not record the prunable skip"
grep -q '^unmeasured=0$' "$T/state-pru/wip-sweep.status" 2>/dev/null \
  && ok "J3 unmeasured=0 — a gone checkout is not an unreadable status" \
  || bad "J3 a prunable record was counted as UNMEASURED"
# ⛔ `skip` IS NOT `clean` (review round 5, finding F-b). These rows were NOT examined, and folding them
# into `clean=` made the summary unable to tell 5 measured-clean trees from 3 clean + 2 never-looked-at —
# a lossy count in the OPTIMISTIC direction, on the surface an instrument reads. They have their own
# counter, and the accounting identity must hold.
grep -q '^skipped=1$' "$T/state-pru/wip-sweep.status" 2>/dev/null \
  && ok "J4 the prunable record is counted as skipped=1, NOT clean" \
  || bad "J4 a skipped record is missing from the skipped= counter"
grep -qx 'clean=1' "$T/state-pru/wip-sweep.status" 2>/dev/null \
  && ok "J5 clean=1 — only the EXAMINED main worktree is counted clean; the prunable record added nothing to it" \
  || bad "J5 the clean counter does not match the ONE worktree that was actually examined: $(sed -n 's/^clean=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_SEEN="$(sed -n 's/^seen=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_CL="$(sed -n 's/^clean=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_SK="$(sed -n 's/^skipped=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_DI="$(sed -n 's/^dirty=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_UN="$(sed -n 's/^unmeasured=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
[ "${S_SEEN:-x}" = "$(( ${S_CL:-0} + ${S_SK:-0} + ${S_DI:-0} + ${S_UN:-0} ))" ] \
  && ok "J6 the accounting identity holds: seen = clean + skipped + dirty + unmeasured ($S_SEEN)" \
  || bad "J6 seen=$S_SEEN does not equal clean+skipped+dirty+unmeasured = $S_CL+$S_SK+$S_DI+$S_UN"

# ── L) A REFUSAL AT STARTUP MUST NOT LEAVE THE PREVIOUS PASS'S `ok` STANDING ───────────────────────
echo; echo "── L. a pass that refuses at startup overwrites the previous record ──"
mk_fixture lref fix/3485-lref || { echo "❌ fixture failed (lref)"; exit 1; }
O_L0="$(sweep "$T/state-lref" --apply --repo "$T/lref/wt")"; RC_L0=$?
[ "$RC_L0" -eq 0 ] && grep -qx 'status=ok' "$T/state-lref/wip-sweep.status" 2>/dev/null \
  && ok "L1 a GOOD pass records status=ok (the baseline this arm needs)" \
  || bad "L1 the prior pass did not record ok (rc=$RC_L0): $O_L0"
# ⛔ A MISSING RESCUER IS THE "BOX BEING SWEPT NOWHERE" CASE, AND IT REFUSES AFTER THE MARKER MUST BE
# WRITTEN. This is the half of the b063e6c fix that I10 cannot see: I10 runs a pass that SUCCEEDS, so a
# marker written below the delegate resolution still reads `running` while it is in flight. Measured with
# the marker moved back below that resolution: the whole suite stayed PASS=96 FAIL=0 and the sequence
# below answered `rc=0 status=ok` over a pass that archived nothing.
O_L1="$(WIP_SWEEP_RESCUE="$T/no-such-rescuer" WIP_SWEEP_STATE_DIR="$T/state-lref" \
  bash "$SW" --apply --repo "$T/lref/wt" 2>&1)"; RC_L1=$?
[ "$RC_L1" -eq 3 ] && ok "L2 a pass whose rescuer is missing exits 3" \
  || bad "L2 a missing rescuer answered $RC_L1 (want 3): $O_L1"
grep -qx 'status=ok' "$T/state-lref/wip-sweep.status" 2>/dev/null \
  && bad "L3 the REFUSED pass left the previous status=ok standing — the record still claims a swept box" \
  || ok "L3 the refused pass REPLACED the previous ok (nothing on this box was archived)"
O_L2="$(sweep "$T/state-lref" --print-status)"; RC_L2=$?
[ "$RC_L2" -ne 0 ] && ok "L4 --print-status is NOT green after a refused pass (rc=$RC_L2)" \
  || bad "L4 --print-status answered 0 over a pass that archived nothing: $O_L2"
has "$O_L2" 'status=ok' \
  && bad "L5 the reader still prints status=ok — the record was not overwritten" \
  || ok "L5 the reader prints no status=ok"

# ── M) A BARE REPO IS A SKIP, NEVER A CLEAN ───────────────────────────────────────────────────────────
# The `bare` branch of `examine()` had no arm at all: mutating ONLY its counter (`N_SKIPPED`→`N_CLEAN`)
# reddened nothing, while the accounting identity the doc asks an instrument to reconcile against
# (`seen = clean + skipped + dirty + unmeasured`) broke silently. The `prunable` flavour is pinned by
# J4/J5; this pins the second one.
echo; echo "── M. a BARE repo is a skip, never a clean ──"
git init -q --bare "$T/bare-m.git" || { echo "❌ fixture failed (bare)"; exit 1; }
O_M="$(sweep "$T/state-bare" --apply --repo "$T/bare-m.git")"; RC_M=$?
[ "$RC_M" -eq 0 ] && ok "M1 a bare repo does not fail the pass (exit 0) — there is no working tree to lose" \
  || bad "M1 a bare repo failed the pass (rc=$RC_M): $O_M"
grep -q 'bare-repo-no-working-tree' "$T/state-bare/wip-sweep.tsv" 2>/dev/null \
  && ok "M2 the index records WHY it was skipped (a fact about the repository, not a failed read)" \
  || bad "M2 the index does not record the bare-repo skip"
grep -qx 'skipped=1' "$T/state-bare/wip-sweep.status" 2>/dev/null \
  && ok "M3 the bare record is counted as skipped=1" \
  || bad "M3 the bare record is missing from the skipped= counter: $(sed -n 's/^skipped=//p' "$T/state-bare/wip-sweep.status" 2>/dev/null)"
grep -qx 'clean=0' "$T/state-bare/wip-sweep.status" 2>/dev/null \
  && ok "M4 clean=0 — a repository nothing examined is not a clean one" \
  || bad "M4 a bare repo was counted CLEAN: $(sed -n 's/^clean=//p' "$T/state-bare/wip-sweep.status" 2>/dev/null)"

# ── N) A RESCUE CUT OFF BY ITS OWN BOUND IS A FAILURE, NOT A BUDGET DEFERRAL ────────────────────────
# 124/137 on the rescue call is TWO facts, and the deferral branch used to claim both: the pass ran out
# of wall clock (a deferral, exit 1), or the rescue was cut off by its own WIP_SWEEP_RESCUE_TIMEOUT — a
# hung push, the case the doc spends a paragraph on (a FAILURE, exit 3, "the work is still only on this
# disk"). Without the `budget_exhausted` guard the second read as the first, `rescue-exit-124`/`-137`
# became unreachable, and `failed=0` claimed the archive had merely not been attempted.
echo; echo "── N. a rescue cut off by ITS OWN bound is a failure, not a deferral ──"
mk_fixture rto fix/3485-rto || { echo "❌ fixture failed (rto)"; exit 1; }
printf 'uncommitted edit\n' >> "$T/rto/wt/base.txt"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  '  *" --verdict "*) echo "verdict=dirty paths=1 branch=fix/3485-rto slug=issue-3485-rto issue=3485"; exit 1 ;;' \
  'esac' \
  'sleep 10' \
  'exit 0' > "$T/stub-hang.sh"
chmod +x "$T/stub-hang.sh"
O_N="$(WIP_SWEEP_RESCUE="$T/stub-hang.sh" WIP_SWEEP_RESCUE_TIMEOUT=1 \
  WIP_SWEEP_STATE_DIR="$T/state-rto" bash "$SW" --apply --repo "$T/rto/wt" 2>&1)"; RC_N=$?
[ "$RC_N" -eq 3 ] && ok "N1 a rescue killed by its OWN bound FAILS the pass (exit 3), not incomplete/1" \
  || bad "N1 a rescue timeout answered $RC_N (want 3 — the work is still only on this disk): $O_N"
grep -qx 'failed=1' "$T/state-rto/wip-sweep.status" 2>/dev/null \
  && ok "N2 failed=1 — the archive broke, and the record says so" \
  || bad "N2 failed=0 over a rescue that never completed"
grep -qx 'deferred=0' "$T/state-rto/wip-sweep.status" 2>/dev/null \
  && ok "N3 deferred=0 — the pass budget was never spent, so nothing is deferred" \
  || bad "N3 the rescue's own timeout was counted as a budget deferral"
IDX_N="$(cat "$T/state-rto/wip-sweep.tsv" 2>/dev/null)"
if has "$IDX_N" 'rescue-exit-124' || has "$IDX_N" 'rescue-exit-137'; then
  ok "N4 the row names the RESCUE's exit (rescue-exit-124/137), not deferred-pass-budget"
else
  bad "N4 the row does not attribute the failure to the rescue: $(sed -n '$p' "$T/state-rto/wip-sweep.tsv" 2>/dev/null)"
fi

# ⛔ N5 — THE `budget_exhausted` GATE ON THE CLASSIFY CALL (review finding, cycle 6). A 124/137 on the
# CLASSIFY call is a deferral ONLY when the budget is actually spent; otherwise the classifier timed out on
# its own bound and the worktree was NEVER MEASURED. The gate had no arm: deleting `&& budget_exhausted`
# left this suite at PASS=151 FAIL=0 (measured). Under the mutant a worktree nobody classified is reported
# as "never got its turn" with the whole budget still available, exit 1 (`incomplete`, retryable) replaces
# exit 3 (`failed`, a human must look) — and this runs on the quiesce path, where nobody retries.
mk_fixture n5 fix/3485-n5 || { echo "❌ fixture failed (n5)"; exit 1; }
printf 'uncommitted edit\n' >> "$T/n5/wt/base.txt"
# Answers the USABILITY probe (so the rescuer is accepted), then hangs on a REAL path — the shape that
# produces a 124 from the classify call while the pass budget is untouched.
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  'esac' \
  'sleep 30' \
  'echo "verdict=clean paths=0 branch=x slug=x issue=-"' \
  'exit 0' > "$T/stub-classify-hang.sh"
chmod +x "$T/stub-classify-hang.sh"
O_N5="$(WIP_SWEEP_RESCUE="$T/stub-classify-hang.sh" WIP_SWEEP_STATUS_TIMEOUT=2 \
  WIP_SWEEP_STATE_DIR="$T/state-n5" bash "$SW" --apply --repo "$T/n5/wt" 2>&1)"; RC_N5=$?
[ "$RC_N5" -eq 3 ] \
  && ok "N5 a classify timeout with the budget UNSPENT is a FAILURE (exit 3), not a deferral" \
  || bad "N5 a classify timeout answered $RC_N5 (want 3): $O_N5"
grep -qx 'unmeasured=1' "$T/state-n5/wip-sweep.status" 2>/dev/null \
  && ok "N5b unmeasured=1 — the worktree is counted as NOT MEASURED" \
  || bad "N5b the classify timeout was not counted as unmeasured: $(cat "$T/state-n5/wip-sweep.status" 2>/dev/null | tr '\n' ' ')"
grep -qx 'deferred=0' "$T/state-n5/wip-sweep.status" 2>/dev/null \
  && ok "N5c deferred=0 — nothing was deferred, because the budget was never spent" \
  || bad "N5c the classify timeout was mis-filed as a budget deferral"
if grep -q 'deferred-pass-budget' "$T/state-n5/wip-sweep.tsv" 2>/dev/null; then
  bad "N5d the index carries a deferred-pass-budget row over an unspent budget"
else
  ok "N5d no deferred-pass-budget row — the misdiagnosis the gate exists to prevent"
fi

# ⛔ N6/N6b — THE VERDICT ALLOW-LIST FALLBACK (review finding, cycle 6). `case "$verdict:$vrc"` accepts
# exactly three pairs; EVERYTHING else must land in `cannot-verify`. That fallback is the last thing
# standing between "the classifier could not classify" and "clean", and it had no arm: replacing it with
# `*) verdict="clean"` left this suite at PASS=151 FAIL=0 (measured). A rescuer that passes the usability
# probe and then answers a REAL path with no verdict line (or with a word this script has never seen) is
# exactly the 127 / word-exit-mismatch shape the comment names.
for _n6case in noverdict banana; do
  mk_fixture "n6$_n6case" "fix/3485-n6$_n6case" || { echo "❌ fixture failed (n6$_n6case)"; exit 1; }
  printf 'uncommitted edit\n' >> "$T/n6$_n6case/wt/base.txt"
  if [ "$_n6case" = banana ]; then _n6out='echo "verdict=banana paths=1 branch=x slug=x issue=-"; exit 0';
  else _n6out='echo "wip-sweep-ish: delegate exploded" >&2; exit 3'; fi
  printf '%s\n' '#!/usr/bin/env bash' \
    'case " $* " in' \
    '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
    'esac' \
    "$_n6out" > "$T/stub-v-$_n6case.sh"
  chmod +x "$T/stub-v-$_n6case.sh"
  O_N6="$(WIP_SWEEP_RESCUE="$T/stub-v-$_n6case.sh" WIP_SWEEP_STATE_DIR="$T/state-n6$_n6case" \
    bash "$SW" --apply --repo "$T/n6$_n6case/wt" 2>&1)"; RC_N6=$?
  [ "$RC_N6" -eq 3 ] \
    && ok "N6 a '$_n6case' answer is NOT a verdict — the pass FAILS (exit 3)" \
    || bad "N6 a '$_n6case' answer from the classifier exited $RC_N6 (want 3): $O_N6"
  # The classifier's own `branch=` wins the branch column (the stub says `x`), so the row is selected by
  # the WORKTREE PATH ($2) — which is what identifies this fixture — rather than by the branch.
  _n6col="$(awk -F'\t' -v m="n6$_n6case" '$2 ~ m {print $6; exit}' "$T/state-n6$_n6case/wip-sweep.tsv" 2>/dev/null)"
  [ "$_n6col" = "cannot-verify" ] \
    && ok "N6b ('$_n6case') the index row's verdict column is cannot-verify, NOT clean" \
    || bad "N6b ('$_n6case') the row recorded verdict='$_n6col' — the allow-list let it through to clean"
done

# ── O) AN ENV-BOUND REFUSAL MARKS THE PASS; AN ARGUMENT ERROR DOES NOT ─────────────────────────────
echo; echo "── O. an env-bound refusal (exit 2) marks the pass, an argument error does not ──"
# ⛔ THE DOC USED TO SAY "a usage error (exit 2) comes earlier and deliberately does not touch the
# record", and only the ARGUMENT parser is earlier — the FIVE environment-bound validations run AFTER the
# marker, on purpose. This arm pins the decision so a later tidy-up cannot move them above the marker and
# silently restore the stale-`ok` class this PR exists to close (a box whose sweep refuses EVERY pass
# reading as a swept box). The two cases are different and the doc now says both.
mk_fixture envb fix/3485-envb || { echo "❌ fixture failed (envb)"; exit 1; }
O_O0="$(sweep "$T/state-envb" --apply --repo "$T/envb/wt")"; RC_O0=$?
[ "$RC_O0" -eq 0 ] && grep -qx 'status=ok' "$T/state-envb/wip-sweep.status" 2>/dev/null \
  && ok "O1 a GOOD pass records status=ok (the baseline this arm needs)" \
  || bad "O1 the prior pass did not record ok (rc=$RC_O0): $O_O0"
O_O1="$(WIP_SWEEP_STALE_SECONDS=abc WIP_SWEEP_STATE_DIR="$T/state-envb" \
  bash "$SW" --apply --repo "$T/envb/wt" 2>&1)"; RC_O1=$?
[ "$RC_O1" -eq 2 ] && ok "O2 an unparseable bound is a usage refusal (exit 2)" \
  || bad "O2 an unparseable bound answered $RC_O1 (want 2): $O_O1"
grep -qx 'status=ok' "$T/state-envb/wip-sweep.status" 2>/dev/null \
  && bad "O3 an ENV-bound refusal left the previous status=ok standing — the stale-green class" \
  || ok "O3 the env-bound refusal marked the pass as started (a box that refuses every pass is not 'swept ok')"
O_O2="$(sweep "$T/state-envb" --print-status)"; RC_O2=$?
if [ "$RC_O2" -ne 0 ] && ! has "$O_O2" 'status=ok'; then
  ok "O4 --print-status is not green (rc=$RC_O2) and prints no status=ok"
else
  bad "O4/O5 --print-status is green over a pass that refused on its bounds (rc=$RC_O2): $O_O2"
fi
# ⛔ AND THE ARGUMENT CASE REALLY IS UNTOUCHED: the parser runs before the record is resolved.
REC_BEFORE="$(cat "$T/state-envb/wip-sweep.status" 2>/dev/null)"
O_O3="$(sweep "$T/state-envb" --no-such-flag 2>&1)"; RC_O3=$?
[ "$RC_O3" -eq 2 ] && ok "O6 an unknown argument exits 2" \
  || bad "O6 an unknown argument answered $RC_O3 (want 2): $O_O3"
[ "$(cat "$T/state-envb/wip-sweep.status" 2>/dev/null)" = "$REC_BEFORE" ] \
  && ok "O7 it did NOT touch the record — a mistyped argument is not a pass" \
  || bad "O7 an argument error rewrote the pass record"

# ── P) THE EXIT TRAP HONOURS BOTH OF THE LIBRARY'S DOCUMENTED OBLIGATIONS ───────────────────────
echo; echo "── P. the EXIT trap honours both obligations of the bounded-execution contract ──"
# ⛔ THIS IS AN EXECUTION, NOT A GREP (review finding, and the grep version was measurably a false
# GREEN). `scripts/lib/bounded.sh`'s CONTRACT names TWO EXIT-trap obligations — `tb_watchdogs_reap`
# (TERM every live watchdog timer) and `tb_bound_cleanup` (remove the per-run probe scratch dir) — and
# the leak the first one prevents only manifests on a host with no GNU `timeout` under SIGTERM/SIGINT.
# That leak cannot be reproduced here, but the FUNCTION can be run: extract `cleanup_all` into a temp
# file, source it in a subshell where both library calls are stubs that announce themselves, call it,
# and require BOTH announcements. A text grep passed with the call sitting after an unconditional
# `return 0` — the present-but-unreachable shape — and this does not.
EXTRACT="$T/cleanup_all.sh"
awk '/^cleanup_all\(\) \{/,/^\}/' "$SW" > "$EXTRACT" 2>/dev/null
OUT_P="$(bash -c '
  tb_watchdogs_reap() { echo REAPED; }
  tb_bound_cleanup()  { echo CLEANED; }
  LISTF=""; ERRF=""; REC_TMP=""
  . "$1" || exit 1
  cleanup_all
' _ "$EXTRACT" 2>&1)"
has "$OUT_P" 'REAPED' \
  && ok "P1 running cleanup_all TERMs live watchdog timers (a leaked timer SIGKILLs a recycled pid later)" \
  || bad "P1 cleanup_all never calls tb_watchdogs_reap when it runs — the library's first obligation"
has "$OUT_P" 'CLEANED' \
  && ok "P2 running cleanup_all also removes the probe scratch dir (the second obligation)" \
  || bad "P2 cleanup_all never calls tb_bound_cleanup when it runs"

# ── Q) A BUDGET SPENT BEFORE THE FIRST EXAMINATION IS `incomplete`, NOT A BROKEN ENUMERATE ──────────
echo; echo "── Q. a budget spent before the first examination is incomplete, not a failed pass ──"
# ⛔ THIS PATH WAS A SUB-SECOND RACE (measured: 1 run in 5 of the plain C5 fixture spent the budget before
# the first record, flushed three `unreached` rows, and then answered `status=failed`/exit 3 with
# `deferred=0` — the summary contradicting the index it exists to reconcile against). A `git` wrapper
# that sleeps only on the repo-level probe makes the corner DETERMINISTIC.
mk_fixture budq fix/3485-budq || { echo "❌ fixture failed (budq)"; exit 1; }
git -C "$T/budq/wt" worktree add -q "$T/budq/w2" -b fix/3485-budq-b 2>/dev/null
git -C "$T/budq/wt" worktree add -q "$T/budq/w3" -b fix/3485-budq-c 2>/dev/null
mkdir -p "$T/slowbin"
REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" rev-parse --is-inside-work-tree "*) sleep 2 ;;\nesac\nexec %s "$@"\n' "$REAL_GIT" > "$T/slowbin/git"
chmod +x "$T/slowbin/git"
O_Q="$(PATH="$T/slowbin:$PATH" WIP_SWEEP_BUDGET=1 WIP_SWEEP_STATE_DIR="$T/state-budq" \
  bash "$SW" --apply --repo "$T/budq/wt" 2>&1)"; RC_Q=$?
[ "$RC_Q" -eq 1 ] && ok "Q1 the pass is INCOMPLETE (exit 1), not failed — the budget ended it, the enumeration did not break" \
  || bad "Q1 answered $RC_Q (want 1): $O_Q"
grep -qx 'status=incomplete' "$T/state-budq/wip-sweep.status" 2>/dev/null \
  && ok "Q2 the record says status=incomplete" \
  || bad "Q2 the record says $(sed -n 's/^status=//p' "$T/state-budq/wip-sweep.status" 2>/dev/null)"
grep -qx 'deferred=3' "$T/state-budq/wip-sweep.status" 2>/dev/null \
  && ok "Q3 deferred=3 — every row the pass flushed is COUNTED, so the summary agrees with the index" \
  || bad "Q3 deferred=$(sed -n 's/^deferred=//p' "$T/state-budq/wip-sweep.status" 2>/dev/null) over three flushed rows"
grep -qx 'seen=0' "$T/state-budq/wip-sweep.status" 2>/dev/null \
  && ok "Q4 seen=0 — nothing was EXAMINED (the identity is over examined worktrees)" \
  || bad "Q4 seen=$(sed -n 's/^seen=//p' "$T/state-budq/wip-sweep.status" 2>/dev/null) (want 0)"
[ "$(grep -c 'deferred-pass-budget' "$T/state-budq/wip-sweep.tsv" 2>/dev/null)" = "3" ] \
  && ok "Q5 the index carries three unreached rows — it still reconciles against git worktree list" \
  || bad "Q5 the index carries $(grep -c 'deferred-pass-budget' "$T/state-budq/wip-sweep.tsv" 2>/dev/null) unreached row(s) (want 3)"

# ⛔ AND A WORKTREE WHOSE OWN CLASSIFY CALL WAS CUT OFF IS NOT `seen` EITHER (#3588 review, cycle 4).
# `seen` was incremented at the top of `examine`, and the classify-deferral branch returns before
# clean/skipped/dirty/unmeasured — so `seen=1` appeared with every term 0, breaking the documented
# identity. A `git` shim that sleeps only on `status` (the call the VERDICT makes) puts the stop inside
# the first examination instead of before it, which is the variant that produced the bad count.
mkdir -p "$T/statusbin"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" status --porcelain "*) sleep 2 ;;\nesac\nexec %s "$@"\n' "$REAL_GIT" > "$T/statusbin/git"
chmod +x "$T/statusbin/git"
O_Q6="$(PATH="$T/statusbin:$PATH" WIP_SWEEP_BUDGET=1 WIP_SWEEP_STATE_DIR="$T/state-budq2" \
  bash "$SW" --apply --repo "$T/budq/wt" 2>&1)"; RC_Q6=$?
[ "$RC_Q6" -eq 1 ] && ok "Q6 a stop inside the first verdict call is still INCOMPLETE (exit 1)" \
  || bad "Q6 answered $RC_Q6 (want 1): $O_Q6"
grep -qx 'seen=0' "$T/state-budq2/wip-sweep.status" 2>/dev/null \
  && ok "Q7 seen=0 — a worktree whose classification never completed was NOT examined" \
  || bad "Q7 seen=$(sed -n 's/^seen=//p' "$T/state-budq2/wip-sweep.status" 2>/dev/null) with clean/skipped/dirty/unmeasured all 0 — the identity is false"

# ⛔ Q8/Q9/Q10 — THE BUDGET BOUNDS THE REPO LOOP TOO (#3588 review, cycle 10). The budget was tested before
# every EXAMINATION, but the loop over REPOS was unguarded and its two pre-examination calls were the only
# ones not clamped with `cap_timeout`. So "bounds the WHOLE pass" (docs/ops/wip-sweep.md) was false by up
# to one STATUS_TIMEOUT per REMAINING repo: measured 24 s against a 2 s bound on 4 hanging repos. On a
# quiesce whose reclaim timeout the operator sizes against that number, the reclaim can then kill the pass
# MID-ARCHIVE with `status=running` and no `NOT DONE` — the failure the bound exists to prevent.
# Q9 is the DISCRIMINATOR and it is not timing-based: with the fix, an unreached repo gets a REPO-level row
# (path `-`), so the index still accounts for it. Reverted, those calls run and the row never appears.
mk_fixture q8a fix/3485-q8a || { echo "❌ fixture failed (q8a)"; exit 1; }
mk_fixture q8b fix/3485-q8b || { echo "❌ fixture failed (q8b)"; exit 1; }
mkdir -p "$T/listbin"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" worktree list "*) sleep 4 ;;\nesac\nexec %s "$@"\n' "$REAL_GIT" > "$T/listbin/git"
chmod +x "$T/listbin/git"
SECONDS=0
O_Q8="$(PATH="$T/listbin:$PATH" WIP_SWEEP_BUDGET=1 WIP_SWEEP_STATUS_TIMEOUT=8 WIP_SWEEP_STATE_DIR="$T/state-q8" \
  bash "$SW" --apply --repo "$T/q8a/wt" --repo "$T/q8b/wt" --repo "$T/budq/wt" 2>&1)"; RC_Q8=$?
Q8_EL=$SECONDS
[ "$RC_Q8" -eq 1 ] \
  && ok "Q8 three repos past an exhausted budget still exit INCOMPLETE (1), not failed" \
  || bad "Q8 answered $RC_Q8 (want 1): $O_Q8"
Q8_UNREACHED="$(awk -F'\t' '$3 == "-" && $6 == "unreached" && $11 == "deferred-pass-budget" {c++} END {print c+0}' "$T/state-q8/wip-sweep.tsv" 2>/dev/null)"
[ "${Q8_UNREACHED:-0}" -ge 2 ] \
  && ok "Q9 the repos the budget never reached are RECORDED as unreached (${Q8_UNREACHED} repo-level row(s)), not silently skipped" \
  || bad "Q9 only ${Q8_UNREACHED:-0} repo-level unreached row(s) — the repo loop ran unguarded and the index lost the repos it skipped"
[ "$Q8_EL" -lt 9 ] \
  && ok "Q10 the whole pass stayed near the 1 s budget (${Q8_EL}s for 3 repos whose listing takes 4 s each) — the bound covers the REPO loop" \
  || bad "Q10 the pass took ${Q8_EL}s against a 1 s budget over 3 repos — the repo-level calls are outside the bound (reverted: ~12 s)"
grep -qx 'status=incomplete' "$T/state-q8/wip-sweep.status" 2>/dev/null \
  && ok "Q10b …and the record says status=incomplete, so the overrun is legible rather than a green pass" \
  || bad "Q10b the record says status=$(sed -n 's/^status=//p' "$T/state-q8/wip-sweep.status" 2>/dev/null)"
[ "$(sed -n 's/^deferred=//p' "$T/state-budq2/wip-sweep.status" 2>/dev/null)" -ge 1 ] 2>/dev/null \
  && ok "Q8 the deferred counter still names the work that never got its turn" \
  || bad "Q8 deferred is not counted: $(sed -n 's/^deferred=//p' "$T/state-budq2/wip-sweep.status" 2>/dev/null)"

# ── R) THE READER ANSWERS ON THE BOXES WHOSE SWEEP REFUSES ───────────────────────────────────────
echo; echo "── R. --print-status answers on the boxes whose sweep refuses ──"
# ⛔ THE READER USED TO RUN AFTER THE BOUNDED-LIB RESOLUTION AND THE BOUND VALIDATIONS, so on exactly the
# box an instrument is asking about (the one whose sweep refuses every pass) it exited 3 with NO
# `status=`/`rc=` line at all — while the doc promises a derived `rc=` on every path.
# ⛔ THE RECORD UNDER IT MUST BE A FRESH `ok`, or the arm is satisfied by an unrelated state: measured on
# a record left `running` by an earlier arm, R1 stayed GREEN with the library check deleted.
mk_fixture rlib fix/3485-rlib || { echo "❌ fixture failed (rlib)"; exit 1; }
sweep "$T/state-rlib" --apply --repo "$T/rlib/wt" >/dev/null 2>&1
grep -qx 'status=ok' "$T/state-rlib/wip-sweep.status" 2>/dev/null \
  && ok "R0 a good pass leaves status=ok (the baseline this arm needs)" \
  || bad "R0 the baseline pass did not record ok"
O_R1="$(WIP_SWEEP_BOUNDED_LIB=/nonexistent/bounded.sh WIP_SWEEP_STATE_DIR="$T/state-rlib" \
  bash "$SW" --print-status 2>&1)"; RC_R1=$?
[ "$RC_R1" -eq 3 ] && has "$O_R1" 'rc=3' && ! has "$O_R1" 'status=ok' \
  && ok "R1 a box with no bounded library CANNOT SWEEP, so the reader answers failed/3 rather than the last ok" \
  || bad "R1 the reader answered over a box that cannot sweep (rc=$RC_R1): $O_R1"
O_R2="$(WIP_SWEEP_STALE_SECONDS=abc WIP_SWEEP_STATE_DIR="$T/state-envb" \
  bash "$SW" --print-status 2>&1)"; RC_R2=$?
[ "$RC_R2" -eq 3 ] && has "$O_R2" 'status=failed' && has "$O_R2" 'WIP_SWEEP_STALE_SECONDS' \
  && ok "R2 the reader still validates the seams IT depends on, and NAMES the broken one" \
  || bad "R2 an unparseable staleness window answered $RC_R2: $O_R2"

# ⛔ R3 — THE P0 ARM (#3588 review, cycle 5). The reader answered `status=ok rc=0` over a box whose sweep
# refuses EVERY pass for four of its eight startup conditions: an unparseable `WIP_SWEEP_BUDGET` /
# `WIP_SWEEP_MAX`, a rescuer that does not exist, and a bounded-library pin that EXISTS but is not the
# library. Its baseline is a fresh `ok` record — with a `running` record every seam looks refused for the
# wrong reason (R1's first version made exactly that mistake).
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/notalib.sh"; chmod +x "$T/notalib.sh"
# ⛔ THE THREE RESCUER SHAPES `[ -f ]` BLESSED (#3588 review), all GENERATED here so the arm cannot depend
# on the host: a 0-byte farmed copy (the realistic truncation), a file that does not parse, and — the one
# that defeats `-s` + `bash -n` — a file that is non-empty and PARSES but has no `--verdict` mode. That last
# one is the most plausible broken farm of the three, and only a BEHAVIOURAL probe catches it. (The first
# cut used `/etc/hostname` as the "not a script" fixture; on this host it contains one word that is valid
# bash, so `bash -n` accepted it and the arm reddened on the fixture instead of the code.)
: > "$T/empty-rescuer.sh"
printf '%s\n' 'this is ( not bash' > "$T/not-a-script.sh"
printf '%s\n' 'echo "this parses but has no --verdict mode"' > "$T/parses-not-rescuer.sh"
for _seam in "WIP_SWEEP_BUDGET=abc" "WIP_SWEEP_MAX=abc" "WIP_SWEEP_RESCUE=$T/no-such-rescuer" \
             "WIP_SWEEP_BOUNDED_LIB=$T/notalib.sh" "WIP_SWEEP_STALE_SECONDS=0" \
             "WIP_SWEEP_RESCUE=$T/empty-rescuer.sh" "WIP_SWEEP_RESCUE=$T/not-a-script.sh" \
             "WIP_SWEEP_RESCUE=$T/parses-not-rescuer.sh"; do
  O_R3="$(env "$_seam" WIP_SWEEP_STATE_DIR="$T/state-rlib" bash "$SW" --print-status 2>&1)"; RC_R3=$?
  if [ "$RC_R3" -eq 0 ] || has "$O_R3" 'status=ok'; then
    bad "R3 '${_seam%%=*}' answers GREEN over a box whose sweep refuses every pass (rc=$RC_R3): $O_R3"
  else
    ok "R3 '${_seam%%=*}' is never green on the reader surface (rc=$RC_R3)"
  fi
done

# ⛔ R4 — THE USABILITY PROBE ITSELF MUST BE BOUNDED (#3588 review, cycle 5). `rescue_usable` EXECUTES the
# rescuer to see whether it can answer, and it ran with NO watchdog — while every other subprocess in the
# file is clamped. Measured before the fix: a rescuer that sleeps on `--verdict` was still blocked after
# 8 s with `WIP_SWEEP_STATUS_TIMEOUT=1` (the outer `timeout` fired, rc=124), i.e. the hang was unbounded.
# This is the call that runs AFTER the kill sweep and BEFORE the restart on the quiesce path, so a hang
# there leaves the cell with zero controllers. A probe that cannot answer in time is NOT usable — the
# refusal direction, never a green one.
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *" --verdict "*) sleep 30; echo "verdict=clean paths=0 branch=x slug=x issue=-"; exit 0 ;;' \
  'esac' 'exit 0' > "$T/hang-rescuer.sh"
chmod +x "$T/hang-rescuer.sh"
_T0="$(date +%s)"
O_R4="$(env WIP_SWEEP_RESCUE="$T/hang-rescuer.sh" WIP_SWEEP_STATUS_TIMEOUT=1 WIP_SWEEP_BUDGET=1 \
        WIP_SWEEP_STATE_DIR="$T/state-r4" bash "$SW" --dry-run --repo "$T/vclean/wt" 2>&1)"; RC_R4=$?
_ELAPSED=$(( $(date +%s) - _T0 ))
has "$O_R4" 'not a USABLE' \
  && ok "R4 a rescuer that HANGS on --verdict is REFUSED (the probe is watchdog-bounded)" \
  || bad "R4 a hanging rescuer was not refused (rc=$RC_R4): $O_R4"
[ "$_ELAPSED" -lt 15 ] \
  && ok "R4b …within the bound (${_ELAPSED}s against a 30 s hang — previously unbounded)" \
  || bad "R4b the usability probe was UNBOUNDED: ${_ELAPSED}s elapsed with STATUS_TIMEOUT=1"

# ⛔ R5/R6/R7 — ANSWERING IS NOT CLASSIFYING (#3588 review). The probe used to accept ANY output containing
# `verdict=`, so a three-line stub that ECHOED `verdict=cannot-verify` and exited 0 was a valid rescuer:
# the reader then answered from a record on a box whose every pass fails. The probe now requires the
# DOCUMENTED PAIR — the word AND the exit code the rescuer's own contract assigns it (`bg-rescue-wip.sh:210`
# /`:288` answer the unmeasurable verdict as `cannot-verify` on **2**). R5 is the exact stub shape that used
# to pass; R6 is the OTHER half (the right word, the wrong code) so neither half can be dropped alone; R7 is
# the POSITIVE CONTROL, because without it a probe that refused everything would satisfy R5 and R6.
# Each is judged on the READER surface with a record that a good pass left `ok` — that is where a wrong
# answer is a false GREEN rather than a loud refusal (R0 above seeds `status=ok`).
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "verdict=cannot-verify"; exit 0' > "$T/answers-not-classifies.sh"
chmod +x "$T/answers-not-classifies.sh"
O_R5="$(env WIP_SWEEP_RESCUE="$T/answers-not-classifies.sh" WIP_SWEEP_STATE_DIR="$T/state-rlib" \
        bash "$SW" --print-status 2>&1)"; RC_R5=$?
if [ "$RC_R5" -eq 0 ] || has "$O_R5" 'status=ok'; then
  bad "R5 a rescuer that ECHOES a verdict and exits 0 answers GREEN on the reader surface (rc=$RC_R5): $O_R5"
elif ! has "$O_R5" 'not a USABLE'; then
  bad "R5 the wrong-code rescuer was not refused BY NAME (rc=$RC_R5): $O_R5"
else
  ok "R5 'verdict=cannot-verify' on exit 0 is REFUSED — the word without the rescuer's own code is not an answer"
fi
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "verdict=clean paths=0 branch=x slug=x issue=-"; exit 2' > "$T/right-code-wrong-word.sh"
chmod +x "$T/right-code-wrong-word.sh"
O_R6="$(env WIP_SWEEP_RESCUE="$T/right-code-wrong-word.sh" WIP_SWEEP_STATE_DIR="$T/state-rlib" \
        bash "$SW" --print-status 2>&1)"; RC_R6=$?
if [ "$RC_R6" -eq 0 ] || has "$O_R6" 'status=ok'; then
  bad "R6 a rescuer answering 'verdict=clean' on exit 2 answers GREEN on the reader surface (rc=$RC_R6): $O_R6"
elif ! has "$O_R6" 'not a USABLE'; then
  bad "R6 the wrong-word rescuer was not refused BY NAME (rc=$RC_R6): $O_R6"
else
  ok "R6 'verdict=clean' on exit 2 is REFUSED — the code without the word it belongs to is not an answer"
fi
# R7: the POSITIVE CONTROL. A rescuer that answers the documented pair for a path that cannot exist IS
# usable, so the reader must reach its own answer (`never` on a fresh state dir) instead of refusing the
# rescuer. Without this arm R5/R6 are satisfied by a probe that refuses EVERYTHING.
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  'esac' 'exit 0' > "$T/faithful-rescuer.sh"
chmod +x "$T/faithful-rescuer.sh"
O_R7="$(env WIP_SWEEP_RESCUE="$T/faithful-rescuer.sh" WIP_SWEEP_STATE_DIR="$T/state-r7" \
        bash "$SW" --print-status 2>&1)"; RC_R7=$?
if has "$O_R7" 'not a USABLE'; then
  bad "R7 the POSITIVE CONTROL failed: a rescuer answering the documented pair was REFUSED, so R5/R6 prove nothing: $O_R7"
elif [ "$RC_R7" -eq 3 ] && has "$O_R7" 'status=never'; then
  ok "R7 positive control: the documented pair IS usable — the reader reaches its own 'never' answer past it"
else
  bad "R7 the faithful rescuer was accepted but the reader did not answer never/3 (rc=$RC_R7): $O_R7"
fi

# ⛔ R8/R9 — THE FARM FALLBACK IS A BRANCH, NOT A FOOTNOTE (#3588 review, item 3). Every R3 seam sets
# `WIP_SWEEP_RESCUE`, so every one of them grades the PIN branch. The finding the usability probe exists for
# named the FARMED copy — `$HOME/.pi/agent/scripts/bg-rescue-wip.sh`, which `pi-bootstrap/setup.sh` writes
# with `cp -f` — and the code comment in `wip-sweep.sh`'s FALLBACKS block CLAIMS "a 0-byte copy at SELF_DIR or in the
# $HOME farm was still ACCEPTED there", with no arm behind the claim. So the fallback could lose the probe
# silently and the suites would stay green. Here the sweep is copied ALONE into a scratch dir ($SELF_DIR then
# holds no rescuer), the library is pinned, and HOME is redirected: the $HOME production is the ONLY one left
# that can answer, so what these arms measure is that branch and nothing else.
FARMDIR="$T/farm"; FARMHOME="$T/farmhome"
rm -rf "$FARMDIR" "$FARMHOME" "$T/farm-rescue.log" "$T/state-r8" "$T/state-r9"
mkdir -p "$FARMDIR" "$FARMHOME/.pi/agent/scripts"
cp "$SW" "$FARMDIR/wip-sweep.sh"
[ -f "$FARMDIR/bg-rescue-wip.sh" ] \
  && bad "R8 precondition failed: the scratch sweep dir already holds a rescuer, so the fallback is unreachable" \
  || ok "R8 precondition: the copied sweep has NO sibling rescuer, so only a fallback can answer"
# The USABLE farmed rescuer: logs every call (so the probe itself is observable) and answers the pair.
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "rescue:$*" >> "'"$T"'/farm-rescue.log"' \
  'case " $* " in' \
  '  *"/nonexistent-wip-sweep-usability-probe"*) echo "verdict=cannot-verify"; exit 2 ;;' \
  'esac' \
  'exit 1' > "$FARMHOME/.pi/agent/scripts/bg-rescue-wip.sh"
chmod +x "$FARMHOME/.pi/agent/scripts/bg-rescue-wip.sh"
O_R8="$(env -u WIP_SWEEP_RESCUE HOME="$FARMHOME" WIP_SWEEP_BOUNDED_LIB="$HERE/lib/bounded.sh" \
        WIP_SWEEP_STATE_DIR="$T/state-r8" bash "$FARMDIR/wip-sweep.sh" --print-status 2>&1)"; RC_R8=$?
[ -s "$T/farm-rescue.log" ] \
  && ok "R8 the $HOME FALLBACK is reached and PROBED when no sibling rescuer exists (the branch the finding named)" \
  || bad "R8 the farmed rescuer was never probed, so the fallback branch is unexercised: $O_R8"
if has "$O_R8" 'not a USABLE'; then
  bad "R8b the USABLE farmed rescuer was REFUSED, so the fallback would refuse a correct box: $O_R8"
elif [ "$RC_R8" -eq 3 ] && has "$O_R8" 'status=never'; then
  ok "R8b …and a usable farmed rescuer is ACCEPTED — the reader reaches its own 'never' answer past it"
else
  bad "R8b the farmed rescuer was accepted but the reader did not answer never/3 (rc=$RC_R8): $O_R8"
fi
# R9 — THE CLAIM ITSELF: an INERT farmed copy must be REFUSED, not accepted because it sits at the farm.
# `echo verdict=…; exit 0` is the shape that used to pass; at the farm it is exactly the truncated `cp -f`
# install the probe exists for.
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "verdict=cannot-verify"; exit 0' > "$FARMHOME/.pi/agent/scripts/bg-rescue-wip.sh"
chmod +x "$FARMHOME/.pi/agent/scripts/bg-rescue-wip.sh"
O_R9="$(env -u WIP_SWEEP_RESCUE HOME="$FARMHOME" WIP_SWEEP_BOUNDED_LIB="$HERE/lib/bounded.sh" \
        WIP_SWEEP_STATE_DIR="$T/state-r9" bash "$FARMDIR/wip-sweep.sh" --print-status 2>&1)"; RC_R9=$?
if has "$O_R9" 'not a USABLE'; then
  ok "R9 an INERT farmed rescuer is REFUSED by name — the fallback applies the same usability test as the pin"
else
  bad "R9 an inert farmed rescuer was ACCEPTED (rc=$RC_R9): the fallback branch skipped the probe: $O_R9"
fi
[ "$RC_R9" -eq 3 ] && has "$O_R9" 'status=failed' \
  && ok "R9b …and the reader answers failed/3 rather than a stale green over a box whose every pass fails" \
  || bad "R9b the inert-farm path did not answer failed/3 (rc=$RC_R9): $O_R9"

# ⛔ THE UNMEASURED MESSAGE'S BACKTICKS, PINNED (#3588 review). Its label is S4m, NOT S4: the "one empty
# listing out of two repos" arm is already S4, and two rows sharing a label make a red S4 unattributable in
# a log (measured by the mutation pass: a group-D mutant reddened THIS arm while the other S4 stayed green,
# and nothing in the log told them apart — which defeats the point of pinning either). `err "UNMEASURED — `git worktree list`
# answered …"` was a LIVE COMMAND SUBSTITUTION inside double quotes: bash ran it and spliced its output into
# the warning. Restoring the backticks left the suite fully green, so the fix was unpinned.
mk_fixture elist fix/3485-elist || { echo "x fixture failed (elist)"; exit 1; }
mkdir -p "$T/emptybin"
REAL_GIT_E="$(command -v git)"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *" worktree list "*) exit 0 ;;' \
  'esac' \
  "exec $REAL_GIT_E \"\$@\"" > "$T/emptybin/git"
chmod +x "$T/emptybin/git"
ELIST_ERR="$(cd "$T" && PATH="$T/emptybin:$PATH" WIP_SWEEP_STATE_DIR="$T/state-elist" \
  bash "$SW" --apply --repo "$T/elist/wt" 2>&1 >/dev/null)"
has "$ELIST_ERR" "'git worktree list' answered" \
  && ok "S4m the UNMEASURED message quotes the command LITERALLY (its backticks were a live substitution)" \
  || bad "S4m the empty-listing message no longer contains the literal 'git worktree list' — a backtick in a double-quoted err string RUNS it: $ELIST_ERR"

# ── S) A REPO THAT LISTED NOTHING IS ESCALATED ON ITS OWN ────────────────────────────────────────────
echo; echo "── S. a repo that listed NOTHING is escalated even when a sibling repo deferred rows ──"
# ⛔ THE ZERO-EXAMINATION ESCALATION IS GLOBAL, and flushed rows can come from another repo — so a repo
# answering exit 0 with an EMPTY list could be excused as `incomplete` by a sibling's deferrals. Not a
# false PASS (a deferral never yields `status=ok`), but a mis-attributed diagnosis: "no time" for what is
# "the enumerate is broken". `sweep_repo` now counts its own listing.
mkdir -p "$T/emptybin"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" worktree list --porcelain "*) exit 0 ;;\nesac\nexec %s "$@"\n' "$REAL_GIT" > "$T/emptybin/git"
chmod +x "$T/emptybin/git"
O_S="$(PATH="$T/emptybin:$PATH" WIP_SWEEP_STATE_DIR="$T/state-empty" \
  bash "$SW" --apply --repo "$T/envb/wt" 2>&1)"; RC_S=$?
[ "$RC_S" -eq 3 ] && ok "S1 a repo whose listing names zero worktrees FAILS the pass (exit 3)" \
  || bad "S1 an empty listing answered $RC_S (want 3): $O_S"
grep -qx 'status=failed' "$T/state-empty/wip-sweep.status" 2>/dev/null \
  && ok "S2 the record says failed, not incomplete — nothing was swept and nobody ran out of clock" \
  || bad "S2 the record says $(sed -n 's/^status=//p' "$T/state-empty/wip-sweep.status" 2>/dev/null)"
grep -q 'worktree-list-empty' "$T/state-empty/wip-sweep.tsv" 2>/dev/null \
  && ok "S3 the index names WHY (worktree-list-empty), so the next actor is not left guessing" \
  || bad "S3 the index does not record the empty listing"
# ⛔ S4 — THE SHAPE THE PER-REPO FIX EXISTS FOR (#3588 review, cycle 5). With ONE repo the global
# zero-examination rule already fails the pass, so only the note string was pinned: deleting the per-repo
# escalation reddened S3 and left S1/S2 green. Two repos is different — repo B is examined normally, so
# the global rule cannot fire, and without the per-repo check the pass answered `status=ok rc=0` over a
# repo that was NEVER ENUMERATED (measured on the mutant). That is a false PASS, not a mis-diagnosis.
mkdir -p "$T/selbin"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" worktree list --porcelain "*)\n     case " $* " in *"%s"*) exit 0 ;; esac ;;\nesac\nexec %s "$@"\n' \
  "$T/budq/wt" "$REAL_GIT" > "$T/selbin/git"
chmod +x "$T/selbin/git"
O_S4="$(PATH="$T/selbin:$PATH" WIP_SWEEP_STATE_DIR="$T/state-sel" \
  bash "$SW" --apply --repo "$T/budq/wt" --repo "$T/rlib/wt" 2>&1)"; RC_S4=$?
[ "$RC_S4" -eq 3 ] && ok "S4 one empty listing out of two repos still FAILS the pass (exit 3)" \
  || bad "S4 an empty listing was excused by a sibling repo (rc=$RC_S4, want 3): $O_S4"
grep -q "worktree-list-empty" "$T/state-sel/wip-sweep.tsv" 2>/dev/null \
  && ok "S5 the empty repo is named in the index" \
  || bad "S5 the index does not name the empty listing"
grep -q "$T/rlib/wt" "$T/state-sel/wip-sweep.tsv" 2>/dev/null \
  && ok "S6 the other repo was still EXAMINED — the pass did not abort at the first empty listing" \
  || bad "S6 the healthy repo was not examined: $(sed -n '1,4p' "$T/state-sel/wip-sweep.tsv" 2>/dev/null)"

# ── S7) A PARTIAL LISTING IS NOT A CLEAN REPO ────────────────────────────────────────────────────────
echo; echo "── S7. a listing that OMITS a worktree is unmeasured, not clean ──"
# ⛔ S7 IS THE NEGATIVE CONTROL THIS CLASS NEVER HAD (#3588 review, cycle 6). `git worktree list --porcelain`
# can answer a SUBSET with rc=0 and COMPLETELY EMPTY stderr, so neither the rc guard nor the zero-record
# guard fires and the omission is invisible. Shape: damage ONE worktree's admin record (`.git/worktrees/
# <name>/gitdir` removed), which an interrupted `git worktree add`, a racing `prune`, or a partial restore
# all produce. MEASURED before the fix: the pass answered `status=ok rc=0` while w2's uncommitted work was
# never enumerated and never archived — the same false PASS this file exists to remove, one layer in.
# A HEALTHY twin runs first, so the new guard cannot pass this arm by refusing every repo unconditionally.
mk_fixture partial fix/3485-partial || { echo "x fixture failed (partial)"; exit 1; }
P_REPO="$T/partial/wt"
git -C "$P_REPO" worktree add -q "$T/partial/w2" -b wip-partial-ok 2>/dev/null \
  || { echo "x could not add a linked worktree (partial)"; exit 1; }
printf 'precious\n' > "$T/partial/w2/precious.txt"
[ -n "$(git -C "$T/partial/w2" status --porcelain 2>/dev/null)" ] \
  && ok "S7a baseline: the linked worktree holds uncommitted work, so a missed enumeration loses real work" \
  || bad "S7a the linked worktree was NOT dirty, so this arm grades nothing"
O_H="$(WIP_SWEEP_STATE_DIR="$T/state-partial-ok" bash "$SW" --apply --repo "$P_REPO" 2>&1)"; RC_H=$?
[ "$RC_H" -eq 0 ] \
  && ok "S7b a HEALTHY listing still passes (the partial guard is not a blanket refusal)" \
  || bad "S7b an undamaged repo escalated rc=$RC_H — the guard refuses everything: $O_H"
# the damaged twin: same shape, one admin record broken
mk_fixture partial2 fix/3485-partial2 || { echo "x fixture failed (partial2)"; exit 1; }
P2_REPO="$T/partial2/wt"
git -C "$P2_REPO" worktree add -q "$T/partial2/w2" -b wip-partial2-b 2>/dev/null \
  || { echo "x could not add a linked worktree (partial2)"; exit 1; }
printf 'precious\n' > "$T/partial2/w2/precious.txt"
rm -f "$P2_REPO/.git/worktrees/w2/gitdir"
P_LISTED="$(git -C "$P2_REPO" worktree list --porcelain 2>"$T/partial2.err")"; P_LRC=$?
P_NREC="$(printf '%s\n' "$P_LISTED" | grep -c '^worktree ')"
[ "$P_LRC" -eq 0 ] && [ ! -s "$T/partial2.err" ] && [ "$P_NREC" -eq 1 ] \
  && ok "S7c the damaged listing answers rc=0 with EMPTY stderr and 1 of 2 records — no rc or stderr check can see it" \
  || bad "S7c this host did not reproduce the invisible shape (rc=$P_LRC records=$P_NREC stderr=$(cat "$T/partial2.err" 2>/dev/null))"
O_P="$(WIP_SWEEP_STATE_DIR="$T/state-partial" bash "$SW" --apply --repo "$P2_REPO" 2>&1)"; RC_P=$?
[ "$RC_P" -eq 3 ] \
  && ok "S7d a PARTIAL listing FAILS the pass (exit 3) instead of reporting the repo clean" \
  || bad "S7d a partial listing answered rc=$RC_P (want 3) — the omitted worktree was never swept and the pass read clean: $O_P"
grep -qx 'status=failed' "$T/state-partial/wip-sweep.status" 2>/dev/null \
  && ok "S7e the record says failed, so no fleet instrument can answer green on it" \
  || bad "S7e the record says $(sed -n 's/^status=//p' "$T/state-partial/wip-sweep.status" 2>/dev/null)"
grep -q 'worktree-list-partial' "$T/state-partial/wip-sweep.tsv" 2>/dev/null \
  && ok "S7f the index names WHY (worktree-list-partial), so the next actor is not left guessing" \
  || bad "S7f the index does not record the partial listing"
has "$O_P" 'NEVER enumerated and NEVER swept' \
  && ok "S7g the refusal says the omitted worktrees were never swept, so the reader is not told 'unknown' without a reason" \
  || bad "S7g the refusal does not name what was missed: $O_P"

# ⛔ S8 — THE INVERSE FALSE POSITIVE: DEBRIS IS NOT AN OMITTED WORKTREE (#3588 review, cycle 3).
# A `git worktree add` killed between `mkdir(.git/worktrees/<name>)` and the `gitdir` write leaves a
# directory that is not a registration at all. Counting every directory made the
# guard report a COMPLETE listing as PARTIAL — persistent for the `locked`-only shape, which neither
# `git gc` nor `git worktree prune` removes (an EMPTY dir both of them do clear) — and on the quiesce path
# that became a false "the work is LOST" FATAL over work that WAS archived. A guard that cries loss over nothing trains
# operators to disbelieve the one line that must always be believed, so the debris shape needs its own
# arm: without it, a future "count everything" edit reds nothing.
mk_fixture debris fix/3485-debris || { echo "x fixture failed (debris)"; exit 1; }
DB_REPO="$T/debris/wt"
mkdir -p "$DB_REPO/.git/worktrees/leftover-empty"                 # the empty dir a killed add leaves
mkdir -p "$DB_REPO/.git/worktrees/leftover-locked"                # …and the `locked`-only shape
: > "$DB_REPO/.git/worktrees/leftover-locked/locked"
O_D="$(WIP_SWEEP_STATE_DIR="$T/state-debris" bash "$SW" --apply --repo "$DB_REPO" 2>&1)"; RC_D=$?
[ "$RC_D" -eq 0 ] \
  && ok "S8a debris admin dirs do NOT make a COMPLETE listing read as partial (rc=0)" \
  || bad "S8a two debris dirs made a healthy, fully-listed repo escalate rc=$RC_D — a permanent false block that calls archived work LOST: $O_D"
grep -qx 'status=ok' "$T/state-debris/wip-sweep.status" 2>/dev/null \
  && ok "S8b …and the pass record says ok, so no reader is told a human must look" \
  || bad "S8b the record says $(sed -n 's/^status=//p' "$T/state-debris/wip-sweep.status" 2>/dev/null)"
# ⛔ S8c — the TRUE positive must survive the debris arm: debris present AND a real omission must still
# escalate. Without this, S8a could be satisfied by deleting the guard entirely.
mk_fixture debris2 fix/3485-debris2 || { echo "x fixture failed (debris2)"; exit 1; }
DB2_REPO="$T/debris2/wt"
git -C "$DB2_REPO" worktree add -q "$T/debris2/w2" -b wip-debris2-b 2>/dev/null \
  || { echo "x could not add a linked worktree (debris2)"; exit 1; }
printf 'precious\n' > "$T/debris2/w2/precious.txt"
mkdir -p "$DB2_REPO/.git/worktrees/leftover-empty"
rm -f "$DB2_REPO/.git/worktrees/w2/gitdir"          # the real omission, alongside the debris
O_D2="$(WIP_SWEEP_STATE_DIR="$T/state-debris2" bash "$SW" --apply --repo "$DB2_REPO" 2>&1)"; RC_D2=$?
[ "$RC_D2" -eq 3 ] \
  && ok "S8c debris does NOT mask a real omission — the damaged registration still FAILS the pass (exit 3)" \
  || bad "S8c a real omission was excused because debris was also present (rc=$RC_D2, want 3): $O_D2"

# ⛔ S9 — A REGISTRATION THAT LOST *TWO* FILES IS STILL A REGISTRATION (#3588 review, cycle 4). S8a's
# fix first required `gitdir` AND both of `HEAD`+`commondir`, which counted 0 for a registration that lost
# `gitdir` plus ONE of the others — so a genuine omission read `status=ok rc=0`. That is a regression in the
# PROTECTIVE direction, i.e. exactly the false PASS this file exists to close, and S8c cannot see it
# because S8c removes only `gitdir`. Both orderings are asserted so the ANY-of test cannot be narrowed
# back to ALL-of, and the dirty file stays in place: the arm asserts on the work that would be lost.
for pair in "gitdir HEAD" "gitdir commondir"; do
  set -- $pair
  mkdir -p "$T/f4" && rm -rf "$T/f4"/* 2>/dev/null
  mk_fixture f4 fix/3485-f4 || { echo "x fixture failed (f4)"; exit 1; }
  F4_REPO="$T/f4/wt"
  git -C "$F4_REPO" worktree add -q "$T/f4/w2" -b "wip-f4-$2" 2>/dev/null \
    || { echo "x could not add a linked worktree (f4)"; exit 1; }
  printf 'precious\n' > "$T/f4/w2/precious.txt"
  rm -f "$F4_REPO/.git/worktrees/w2/$1" "$F4_REPO/.git/worktrees/w2/$2"
  O_F4="$(WIP_SWEEP_STATE_DIR="$T/state-f4-$2" bash "$SW" --apply --repo "$F4_REPO" 2>&1)"; RC_F4=$?
  [ "$RC_F4" -eq 3 ] \
    && ok "S9 registration missing '$1'+'$2' still counts, so the omitted dirty worktree FAILS the pass (exit 3)" \
    || bad "S9 a registration missing '$1'+'$2' counted 0, so an OMITTED worktree holding uncommitted work read clean (rc=$RC_F4): $O_F4"
  grep -q 'worktree-list-partial' "$T/state-f4-$2/wip-sweep.tsv" 2>/dev/null \
    && ok "S9b …and the note is worktree-list-partial, not a bare 'unknown'" \
    || bad "S9b the index does not record the partial listing for '$1'+'$2'"
done

# ⛔ S10 — A REGISTRATION DAMAGED DOWN TO NON-MARKER CONTENT IS STILL COUNTED (#3588 review, cycle 5).
# A marker WHITELIST (`gitdir`/`HEAD`/`commondir`) excluded exactly this shape: with only
# `ORIG_HEAD`/`index`/`logs` left, git OMITS the worktree and the pass answered `status=ok rc=0` over work
# that was never swept — the same false PASS this file exists to close, hiding behind a comment that claimed
# the exclusion was fail-closed. The exclusion is now debris-by-EXCLUSION (empty, or nothing but `locked`),
# so this arm is what keeps the whitelist from coming back.
mk_fixture f5 fix/3485-f5 || { echo "x fixture failed (f5)"; exit 1; }
F5_REPO="$T/f5/wt"
git -C "$F5_REPO" worktree add -q "$T/f5/w2" -b wip-f5-b 2>/dev/null \
  || { echo "x could not add a linked worktree (f5)"; exit 1; }
printf 'precious\n' > "$T/f5/w2/precious.txt"
rm -f "$F5_REPO/.git/worktrees/w2/gitdir" "$F5_REPO/.git/worktrees/w2/HEAD" \
      "$F5_REPO/.git/worktrees/w2/commondir"
[ -e "$F5_REPO/.git/worktrees/w2/index" ] && [ -e "$F5_REPO/.git/worktrees/w2/logs" ] \
  && ok "S10a baseline: the damaged registration keeps only non-marker content (index/logs), so a marker whitelist would skip it" \
  || bad "S10a this host's admin dir has no index/logs to leave behind — the arm would grade nothing"
O_F5="$(WIP_SWEEP_STATE_DIR="$T/state-f5" bash "$SW" --apply --repo "$F5_REPO" 2>&1)"; RC_F5=$?
[ "$RC_F5" -eq 3 ] \
  && ok "S10b a registration stripped to non-marker content FAILS the pass (exit 3) — git omits that worktree, so skipping it reads green over unswept work" \
  || bad "S10b a registration holding only index/logs counted as debris, so an OMITTED dirty worktree read clean (rc=$RC_F5): $O_F5"
grep -q 'worktree-list-partial' "$T/state-f5/wip-sweep.tsv" 2>/dev/null \
  && ok "S10c …and the note is worktree-list-partial" \
  || bad "S10c the index does not record the partial listing for the stripped registration"

# ⛔ S11 — THE TWO REPO-LEVEL NOTES ON THE COMMON-DIR PATH ARE PINNED (#3588 review, cycle 8). The
# mutation pass MEASURED that `worktree-list-failed` and `worktree-list-unverifiable` appear ZERO times in
# this suite, and that deleting the `tb_timeout` bound on `git rev-parse --git-common-dir` left the whole
# suite at 176/0. So the comment's "BOUNDED, LIKE EVERY OTHER SUBPROCESS HERE" was a claim no arm could
# falsify — on the one path where a hung git means the quiesce never finishes and the cell is handed on to
# be reclaimed UNARCHIVED, which is the loss this PR exists to prevent.
echo; echo "── S11. the common-dir probe is bounded, and each of its failures is attributable ──"
mk_fixture s11 fix/3485-s11 || { echo "x fixture failed (s11)"; exit 1; }
S11_REPO="$T/s11/wt"
S11_REAL="$(command -v git)"

# (a) a REFUSED listing -> worktree-list-failed
mkdir -p "$T/failbin"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" worktree list --porcelain "*) exit 1 ;;\nesac\nexec %s "$@"\n' \
  "$S11_REAL" > "$T/failbin/git"
chmod +x "$T/failbin/git"
O_S11F="$(PATH="$T/failbin:$PATH" WIP_SWEEP_STATE_DIR="$T/state-s11f" bash "$SW" --apply --repo "$S11_REPO" 2>&1)"; RC_S11F=$?
[ "$RC_S11F" -eq 3 ] \
  && ok "S11a a REFUSED 'git worktree list' FAILS the pass (exit 3)" \
  || bad "S11a a refused listing answered $RC_S11F (want 3): $O_S11F"
grep -q 'worktree-list-failed' "$T/state-s11f/wip-sweep.tsv" 2>/dev/null \
  && ok "S11b …and the index names worktree-list-failed, so the cause is not a bare 'unknown'" \
  || bad "S11b the index does not record the refused listing"

# (b) an UNRESOLVABLE common dir -> worktree-list-unverifiable
mkdir -p "$T/unverb"
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" --git-common-dir "*) exit 1 ;;\nesac\nexec %s "$@"\n' \
  "$S11_REAL" > "$T/unverb/git"
chmod +x "$T/unverb/git"
O_S11U="$(PATH="$T/unverb:$PATH" WIP_SWEEP_STATE_DIR="$T/state-s11u" bash "$SW" --apply --repo "$S11_REPO" 2>&1)"; RC_S11U=$?
[ "$RC_S11U" -eq 3 ] \
  && ok "S11c an UNRESOLVABLE common dir FAILS the pass (exit 3) — completeness is never assumed" \
  || bad "S11c an unresolvable common dir answered $RC_S11U (want 3): $O_S11U"
grep -q 'worktree-list-unverifiable' "$T/state-s11u/wip-sweep.tsv" 2>/dev/null \
  && ok "S11d …and the index names worktree-list-unverifiable" \
  || bad "S11d the index does not record the unresolvable common dir"

# (c) a HANGING probe must be WATCHDOG-BOUNDED rather than waited out
mkdir -p "$T/slowbin"
# `exec sleep` so the TERM lands on the sleep itself and cannot fall through to the real git afterwards.
printf '#!/usr/bin/env bash\ncase " $* " in\n  *" --git-common-dir "*) exec sleep 30 ;;\nesac\nexec %s "$@"\n' \
  "$S11_REAL" > "$T/slowbin/git"
chmod +x "$T/slowbin/git"
SECONDS=0
O_S11S="$(PATH="$T/slowbin:$PATH" WIP_SWEEP_STATUS_TIMEOUT=1 WIP_SWEEP_STATE_DIR="$T/state-s11s" bash "$SW" --apply --repo "$S11_REPO" 2>&1)"; RC_S11S=$?
S11_EL=$SECONDS
[ "$S11_EL" -lt 15 ] \
  && ok "S11e a HANGING common-dir probe is BOUNDED — the pass returned in ${S11_EL}s against a 30 s hang" \
  || bad "S11e the pass took ${S11_EL}s against a 30 s hang — the common-dir call is NOT watchdog-bounded (deleting the tb_timeout is what this arm exists for)"
[ "$RC_S11S" -eq 3 ] \
  && ok "S11f …and it FAILS the pass (exit 3), never reading the repo complete" \
  || bad "S11f a hung probe answered $RC_S11S (want 3): $O_S11S"
grep -q 'worktree-list-unverifiable' "$T/state-s11s/wip-sweep.tsv" 2>/dev/null \
  && ok "S11g …and the index names worktree-list-unverifiable, so a timeout is attributable" \
  || bad "S11g the index does not record the timed-out probe"

echo
echo "── summary ──"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
