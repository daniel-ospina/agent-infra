#!/usr/bin/env bash
# wip-sweep.test.sh — the regression contract for agent-infra#3485.
#
# ⛔ WHY THIS EXISTS. `bg-rescue-wip.sh` is wired into `spawn-gate.sh`'s `run_agent` AT ITS END, so it
# rescues a lane that stops THROUGH that function — and nothing else. A lane killed by the OOM reaper,
# a crash, or a cell quiesce leaves its work in the working tree and nowhere else, and a quiesce then
# destroys the disk. `wip-sweep.sh` is the sweep that closes that gap, and because of what it is for,
# every case here is driven against a REAL bare remote and the properties that matter are pinned
# separately:
#
#   1. the work REACHES ORIGIN — and its CONTENT is the content that was dirty (a ref that exists but
#      does not carry the work is vacuous, so the case reads the blob back);
#   2. the sweep does not change the state it is sweeping — the branch does not move and the working
#      tree is not touched, because the lane it is archiving may still be running;
#   3. DRY RUN IS THE DEFAULT and pushes NOTHING — the arming decision is the caller's command line;
#   4. the per-pass cap DEFERS, and says so: a capped pass is INCOMPLETE, never clean;
#   5. `UNMEASURED` is its own verdict and is NEVER "nothing to rescue" — an unreadable worktree, an
#      unresolvable repo, a missing delegate and a failed archive all fail the pass loudly;
#   6. every ref the sweep creates can be tied to an issue, and one that cannot BE REPORTED.
#
# ⛔ EVERY ARM HERE WAS BUILT TO GO RED. The `--verdict` cases specifically pin the ONE classifier the
# sweeper reads (arms K1-K5): if `bg-rescue-wip.sh` ever answered `clean` for a tree it could not read,
# the sweep would report a clean fleet over a disk full of unfiled work and NOTHING else in this file
# would notice — that is the mutation the verdict arms exist to catch.
#
# Run:  bash scripts/wip-sweep.test.sh
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
has "$O_V" 'slug=fix-3485-vclean' \
  && ok "K1b the verdict names the classifier's OWN slug — the caller never re-derives the ref name" \
  || bad "K1b verdict did not carry slug=: $O_V"

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
SHA="$(ref_of "$A/origin.git" refs/wip/fix-3485-acc)"
[ -n "$SHA" ] && ok "A2 refs/wip/fix-3485-acc exists on ORIGIN (read back from the bare remote)" \
               || bad "A2 no refs/wip/fix-3485-acc on origin — the sweep archived nothing"
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
ROW="$(grep 'fix-3485-acc' "$T/state-acc/wip-sweep.tsv" 2>/dev/null | head -1)"
has "$ROW" 'archived' && has "$ROW" 'refs/wip/fix-3485-acc' && has "$ROW" '3485' \
  && ok "A7 the INDEX row names the verdict, the ref and the issue link (agent-infra#3484's ask, in the record)" \
  || bad "A7 the index row is missing verdict/ref/issue: $ROW"
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
  '  *" --verdict "*) echo "verdict=dirty paths=1 branch=fix/3485-toc slug=fix-3485-toc"; exit 1 ;;' \
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
  '  *" --verdict "*) echo "verdict=dirty paths=1 branch=fix/3485-tcu slug=fix-3485-tcu"; exit 1 ;;' \
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
grep -q 'nothing-at-risk' "$T/state-cln/wip-sweep.tsv" 2>/dev/null \
  && ok "H3 the index records the clean verdict" || bad "H3 the index has no clean row"
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
WIP_SWEEP_STATE_DIR="$T/state-cap" bash "$SW" --print-status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "I4 an INCOMPLETE record answers 1 (work was deferred — not clean, not failed)" \
                || bad "I4 incomplete record answered $RC (want 1)"
# ⛔ TWO WAYS A RECORD CLOCK WENT UNREAD AND ANSWERED 0 (review round 1, finding F4). The staleness test
# used to be `[ "$STALE_SECONDS" -gt 0 ] 2>/dev/null` and `[ -n "$S_TS" ]`, so an unparseable bound or a
# record with no `ts=` line SKIPPED the age check entirely and reported `status=ok` — a pass record of
# any age read as current.
O="$(cd "$T" && WIP_SWEEP_STALE_SECONDS=abc WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "I5 an UNPARSEABLE WIP_SWEEP_STALE_SECONDS is refused (a typo'd bound never means 'no bound')" \
                || bad "I5 unparseable stale bound exit $RC (want 2): $O"
# ⛔ AND A PLAUSIBLE-LOOKING VALUE MUST NOT DISABLE IT EITHER (review round 2, residual R1). `tb_timeout
# 0 …` is "unbounded" and `WIP_SWEEP_STALE_SECONDS=0` read as "do not check" — so a record from 1970
# answered `ok`. Only --max and WIP_SWEEP_BUDGET document 0 as a disable; the watchdogs and the
# staleness window do not.
O="$(cd "$T" && WIP_SWEEP_STALE_SECONDS=0 WIP_SWEEP_STATE_DIR="$T/state-stale" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "I5b WIP_SWEEP_STALE_SECONDS=0 is REFUSED, not read as 'skip the staleness check'" \
                || bad "I5b a zero staleness window exited $RC (want 2): $O"
O="$(cd "$T" && WIP_SWEEP_STATUS_TIMEOUT=0 WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "I5c WIP_SWEEP_STATUS_TIMEOUT=0 is REFUSED (a zero watchdog bound is 'unbounded' in bounded.sh)" \
                || bad "I5c a zero watchdog bound exited $RC (want 2): $O"
O="$(cd "$T" && WIP_SWEEP_RESCUE_TIMEOUT=0 WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "I5d WIP_SWEEP_RESCUE_TIMEOUT=0 is REFUSED too (the rescue is the longest call on the quiesce path)" \
                || bad "I5d a zero rescue bound exited $RC (want 2): $O"
# ⛔ AND THE OTHER DIRECTION: the two seams that DO document 0 as a disable must still accept it. A gate
# that refuses everything is as useless as one that accepts everything, and `--max 0` / a zero budget
# are the documented "no cap" / "no pass budget" values.
O="$(cd "$T" && WIP_SWEEP_BUDGET=0 WIP_SWEEP_STATE_DIR="$T/state-cln" bash "$SW" --print-status 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "I5e WIP_SWEEP_BUDGET=0 is still ACCEPTED (0 is a documented disable for the pass budget)" \
                || bad "I5e a zero pass budget was refused (rc=$RC, want 0): $O"
O="$(sweep "$T/state-max0" --apply --max 0 --repo "$T/cln/wt")"; RC=$?
[ "$RC" -eq 0 ] && ok "I5f --max 0 is still ACCEPTED (0 is a documented disable for the per-pass cap)" \
                || bad "I5f --max 0 was refused (rc=$RC, want 0): $O"
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
grep -qx 'clean=0' "$T/state-pru/wip-sweep.status" 2>/dev/null \
  && ok "J5 clean=0 — a record nobody examined never inflates the clean count" \
  || bad "J5 a skipped record was counted as clean"
S_SEEN="$(sed -n 's/^seen=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_CL="$(sed -n 's/^clean=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_SK="$(sed -n 's/^skipped=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_DI="$(sed -n 's/^dirty=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
S_UN="$(sed -n 's/^unmeasured=//p' "$T/state-pru/wip-sweep.status" 2>/dev/null)"
[ "${S_SEEN:-x}" = "$(( ${S_CL:-0} + ${S_SK:-0} + ${S_DI:-0} + ${S_UN:-0} ))" ] \
  && ok "J6 the accounting identity holds: seen = clean + skipped + dirty + unmeasured ($S_SEEN)" \
  || bad "J6 seen=$S_SEEN does not equal clean+skipped+dirty+unmeasured = $S_CL+$S_SK+$S_DI+$S_UN"

echo
echo "── summary ──"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
