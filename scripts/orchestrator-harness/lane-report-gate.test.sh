#!/usr/bin/env bash
# lane-report-gate.test.sh — the CONSUMER of the mandatory lane report (#2977).
#
# WHAT IS ASSERTED, and why each arm exists (every one of them is a way this gate could be inert or
# wrong without anybody noticing):
#
#  1. EVERY ROW OF THE DECISION TABLE, driven through the SHIPPED script against real git worktrees and
#     a fixture consumer. A gate whose rows are never driven is a gate nobody knows the polarity of.
#  2. THE ARM THE WRITER DELIBERATELY LEAVES TO ITS CONSUMER: `check` exits 0 on a moved head, so a
#     consumer keying on `$?` merges a report that describes a DIFFERENT tree (measured twice in one
#     lane on 2026-11-07). The fixture reproduces exactly that: rc 0 + `head_moved_since_write: true`
#     MUST be STALE, never PASS.
#  3. THE HEAD IS LOAD-BEARING IN BOTH DIRECTIONS (fresh review of this change, P1). The writer compares
#     the report against ITS OWN worktree; when the BRANCH advances from somewhere else (a `fix-<PR>`
#     push, another box) the worktree stays behind, `head_moved_since_write` stays FALSE, and a gate
#     that never compares `$head` returns PASS for a report describing a tree one commit behind the
#     head being merged. So: the head the report was written at AND the head the worktree is at must
#     both BE the head being merged, and an EMPTY head cannot pass any arm. ⛔ These rows exist because
#     the reviewer's mutant — `head=` documented everywhere and compared nowhere — passed this suite.
#  4. POLARITY BY CONTENT, NOT BY EXIT CODE ALONE: rc 0 with `ok: false` is INVALID, and unparseable
#     output is UNMEASURABLE — an unreadable verification is never a pass. Also UNMEASURABLE, not an
#     abstention: an empty branch, an empty repo, and no interpreter (a missing input or an unrunnable
#     verifier must never reach the most tolerant outcome the gate has).
#  5. THE TWO ABSTENTIONS ARE NOT GREEN and are distinguishable: a repo that ships no writer is
#     NO-CONSUMER (the gate cannot bind there), and a branch with no worktree on this box is
#     NO-WORKTREE. Collapsing either into 0 is how a gate reports coverage it does not have.
#  6. EXACT BRANCH MATCH, with decoy worktrees that are a TRUE prefix (`feat/2977`) and a TRUE
#     EXTENSION (`feat/2977-tm-extra`) of the branch, both created BEFORE the real worktree so a
#     first-match walk reaches them first. ⛔ The first version used `feat/297-tm`, which is not a
#     prefix of `feat/2977-tm` at all — the reviewer showed a branch-prefix mutant passing the whole
#     suite. Three arms now pin the two mutant directions and the documented NO-WORKTREE case.
#  7. `head_at_write` IS READ FROM THE WRITER STATE, not from the consumer's `head` (which is the
#     worktree's CURRENT head): the STALE line must name two DIFFERENT shas, or it reads as a
#     contradiction and names nothing.
#  8. WIRING — a gate nothing calls is the defect this issue is about. ⛔ ANCHORED ON CODE LINES, NOT
#     ON PROSE: `lane-merge.sh` mentions `lane_report_gate` in a COMMENT above its own call, so a
#     `grep` for the identifier matched the comment and the reviewer's "delete the call" mutant left
#     every row green. Each anchor below is a regex over the line that actually sources or calls.
#     ⛔ AND THE DISPOSITION IS PINNED, NOT JUST THE CALL (fresh review, P1): deleting the refusal from
#     both carriers left this suite 29/29 green, so a gate that runs, prints its verdict and is ignored
#     passed. The code line that refuses (`emit_fix FIX_REQUIRED` / `exit 9`) and the rail ordering are
#     asserted BETWEEN the call and the thing they protect.
#  9. THE LAUNDERING ARM (fresh review, P0): `write_report` re-stamps `head_at_write` on every
#     `write`/`note`/idempotent `init`, so a report whose suites ran at an older commit presents a
#     matching recorded head. The newest suite `finished_at` is written only by `run`, so it is the one
#     witness a re-render cannot move — and the control row proves the arm refuses the laundering, not
#     every report.
# 10. THE VERIFIER IS THE TRUSTED CHECKOUT'S, not the merged worktree's (fresh review, P2): a lane can
#     edit `tools/worktree_report.py` on its own branch, so preferring `$wt` would let it grade itself.
#     Cycle 2 closed the two remaining doors: NO ambient env var may select the verifier (an `export`
#     inherited through the chain defeated even the $O-pinned carrier), and the `$wt` FALLBACK is gone
#     (a lane could ADD the writer to its PR and lift a non-participant repo's refusal).
# 11. A MIS-GRADED OR UNREACHABLE REFUSAL IS A DEFECT TOO (cycle 2): an unusable repo path is 7, not a
#     mergeable 6 abstention; a gate block NESTED in a never-true guard is inert while every anchor
#     stays green, so the block must not be nested; and a future-dated merging head (a cross-box push)
#     gets its own reason, because the re-run remedy cannot converge on it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/lane-report-gate.sh"
LANE_MERGE="$HERE/lane-merge.sh"
MERGE_ONE="$HERE/merge-one.sh"
INSTALL="$HERE/install.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$1"; }

[ -f "$GATE" ] || { echo "❌ lane-report-gate.sh missing"; exit 1; }
# ⛔ THE GUARD MUST USE THE GATE'S OWN FLOOR, NOT "python3 exists" (round-9 review, P2). The gate now
# requires ≥ 3.12 (the shipped consumer refuses an older interpreter and prints nothing). On exactly the
# hosts that motivated that floor — macOS `/usr/bin/python3` = 3.9, Debian 11 / Ubuntu 20.04 — this guard
# passed while every row the gate could not run returned 7, i.e. ~38 FAILURES instead of its own
# diagnosis, and the first wrong remedy a hurried reader reaches for is "lower the floor".
_PY_OK=""
for _c in python3 python /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  command -v "$_c" >/dev/null 2>&1 || continue
  "$_c" -I -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null \
    && { _PY_OK="$_c"; break; }
done
[ -n "$_PY_OK" ] || { echo "SKIP lane-report-gate.test.sh — no interpreter >= 3.12 (the consumer refuses an older one and prints nothing; run it as 'uv run python ...')"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lane-report-gate-test-XXXXXX")" || { echo "❌ mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Hermetic git: no ambient identity/locale leaks into the fixture commits.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/home"
unset GH_REPO OR
mkdir -p "$HOME"

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
# A real repo with real LINKED worktrees, because the gate reads `git worktree list --porcelain`:
# a directory that merely looks like a worktree would make §6 pass for the wrong reason.
REPO="$TMP/repo"
mkdir -p "$REPO"; git -C "$REPO" init -q -b main
printf 'x\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
# ⛔ THE DECOYS MUST SORT BEFORE THE REAL WORKTREE, ON PURPOSE, AND CREATION ORDER IS IRRELEVANT:
# `git worktree list` emits paths in SORTED order, so `.worktrees/tm-extension` and `.worktrees/tm-prefix`
# were both printed AFTER `.worktrees/tm-2977` — a first-match walk reached the real worktree first and every
# prefix mutant looked correct. (The first version of this file claimed the opposite about creation order;
# the fresh reviewer's mutant proved the claim false.) These names sort first, so the walk really does reach
# a decoy first and the row can see the difference.
DECOY_P="$REPO/.worktrees/a-decoy-prefix"     # branch "feat/2977"        — a TRUE PREFIX of the real branch
DECOY_E="$REPO/.worktrees/b-decoy-extension"  # branch "feat/2977-tm-extra" — a TRUE EXTENSION of it
git -C "$REPO" worktree add -q -b "feat/2977" "$DECOY_P" main 2>/dev/null || bad "fixture: could not create the prefix decoy worktree"
git -C "$REPO" worktree add -q -b "feat/2977-tm-extra" "$DECOY_E" main 2>/dev/null || bad "fixture: could not create the extension decoy worktree"
WT="$REPO/.worktrees/tm-2977"
git -C "$REPO" worktree add -q -b "feat/2977-tm" "$WT" main 2>/dev/null || bad "fixture: could not create the real worktree"

mkdir -p "$REPO/tools"
# The fixture consumer: emits the shape `worktree_report.py check --json` really emits, with the rc and
# the fields the gate acts on taken from the environment. ⛔ `head` DEFAULTS TO THE WORKTREE'S REAL HEAD
# (that is what the real consumer prints) — a hardcoded sentinel here reddened the PASS row the moment
# the gate started comparing `$head`, which is exactly the coupling this fixture must model.
cat > "$REPO/tools/worktree_report.py" <<'STUB'
import json, os, subprocess, sys
if os.environ.get("STUB_RAW"):
    sys.stdout.write(os.environ["STUB_RAW"]); sys.exit(int(os.environ.get("STUB_RC", "0")))
wt = sys.argv[sys.argv.index("--worktree") + 1] if "--worktree" in sys.argv else "."
head = os.environ.get("STUB_HEAD")
if head is None:
    head = subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
rules = [r for r in os.environ.get("STUB_RULES", "").split(",") if r]
print(json.dumps({
    "ok": os.environ.get("STUB_OK", "1") == "1",
    "rules": rules,
    "suites": int(os.environ.get("STUB_SUITES", "2")),
    "failing_suites": int(os.environ.get("STUB_FAILING", "0")),
    "head": head,
    "head_moved_since_write": os.environ.get("STUB_STALE", "0") == "1",
}))
sys.exit(int(os.environ.get("STUB_RC", "0")))
STUB
printf '## Files changed\nx\n## Suites run\ny\n## Could not do\nz\n' > "$WT/WORKTREE-REPORT.md"
# The prefix decoy CARRIES a report, so the reverse-prefix mutant returns a real verdict instead of ABSENT
# (a distinct code, which is what §6's third arm asserts against).
printf '## Files changed\n## Suites run\n## Could not do\n' > "$DECOY_P/WORKTREE-REPORT.md"
# The extension decoy deliberately has NO report: the extension mutant then returns ABSENT (1), not PASS.

WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
# ⛔ THE HONEST BASELINE STATE IS PART OF THE FIXTURE (round-6 review, P1). An ABSENT writer state is
# now 7 UNMEASURABLE (absence kills the same two head witnesses corruption does, and `rm` is the cheaper
# way to do it), so every arm that expects a verdict about the EVIDENCE must start from a readable state,
# exactly as a real run does. `finished_at` is far ahead of the fixture commit so the `predates` witness
# reads "ran after the commit". Arms that need a different state overwrite this one.
_restore_state() { # the honest baseline: state bound to the head being merged, evidence after it
  mkdir -p "$WT/.worktree-report"
  printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"2099-01-01T00:00:00Z"}]}\n' \
    "$WT_HEAD" > "$WT/.worktree-report/state.json"
}
_restore_state

# drive <expected-rc> <name> [env…] — run the SHIPPED gate AT THE WORKTREE'S HEAD and assert the code.
drive() {
  local want="$1" name="$2"; shift 2
  local out rc
  out="$(env "$@" bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"; else bad "$name — expected rc=$want, got rc=$rc :: $out"; fi
  LAST_OUT="$out"
}

# ── 1. PASS ─────────────────────────────────────────────────────────────────────────────────────
drive 0 "PASS: valid evidence at the head being merged" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *VERDICT=PASS*) ok "PASS is spelled VERDICT=PASS on the printed line" ;; *) bad "PASS line: $LAST_OUT" ;; esac
case "$LAST_OUT" in *worktree="$WT "*) ok "PASS resolves the EXACT branch worktree, not a decoy" ;; *) bad "PASS resolved the wrong worktree: $LAST_OUT" ;; esac
# ⛔ THE PASS LINE MUST NAME THE VERIFIER (fresh review, P2): provenance that nothing reads is a comment,
# not a control, and it is the only thing that makes a wrong grader visible AFTER it changed a verdict.
case "$LAST_OUT" in *"tool=$REPO/tools/worktree_report.py"*) ok "PASS names the verifier it used (tool=…)" ;; *) bad "PASS does not name the verifier: $LAST_OUT" ;; esac

# ── 1b. AN ABSENT WRITER STATE IS UNMEASURABLE, NOT A PASS (round-6 review, P1) ───────────
# The PASS arm above runs against the fixture's readable baseline state. With the state REMOVED, the two
# head witnesses are unreadable — and because `rm` is cheaper than damaging the file, an absent state that
# PASSED made deleting the witness the cheapest available action for the graded party (measured: the
# laundering state refused rc=4, then PASSED rc=0 one `rm` later).
rm -f "$WT/.worktree-report/state.json"
drive 7 "UNMEASURABLE: an ABSENT writer state kills both head witnesses, exactly as a corrupt one does" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=writer-state-absent*) ok "…and it names the ABSENT state rather than returning a verdict about the report" ;; *) bad "absent-state reason: $LAST_OUT" ;; esac
case "$LAST_OUT" in *VERDICT=PASS*) bad "an absent writer state was read as a PASS — deleting the witness was the cheapest bypass" ;; *) ok "…and it is not reported as PASS" ;; esac
case "$LAST_OUT" in
  *"report_head=$WT_HEAD"*) bad "the refusal substituted the MERGING head for a report head it never read" ;;
  *) ok "…and no line substitutes the merging head for a head it did not read" ;;
esac
_restore_state
# ── 1c. A CORRUPT WRITER STATE IS UNMEASURABLE, NOT A PASS (fresh review, P2) ──────────────────
# ⛔ BOTH head witnesses are read out of this file, and both arms that consume them are `[ -n … ]`-guarded
# — so on a parse failure they go DARK and `ok:true` alone reads as green. The lane owns this worktree,
# so truncating the file was a one-command way to delete the two witnesses the PR calls P0. A file that
# EXISTS and will not parse is tampering with a witness that was there: 7, never a verdict.
mkdir -p "$WT/.worktree-report"
printf 'not json at all{{{\n' > "$WT/.worktree-report/state.json"
drive 7 "UNMEASURABLE: a writer state that exists but will not parse (both head witnesses are dark)" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=writer-state-corrupt*) ok "…and it names the corrupt state instead of returning a verdict about it" ;; *) bad "corrupt-state reason: $LAST_OUT" ;; esac
case "$LAST_OUT" in *VERDICT=PASS*) bad "a corrupt writer state was read as a PASS" ;; *) ok "…and it is not reported as PASS" ;; esac
_restore_state
# ── 1d. A STATE THAT PARSES IS NOT A WITNESS (round-7 review, P0) ──────────────────
# ⛔ `{}` IS VALID JSON AND A DICT, so it used to be `state_ok = "ok"` — with `head_at_write` and every
# `finished_at` simply DELETED, both head witnesses went dark and the gate PASSED. That is the round-6
# hole one spelling over: `rm` and truncation were refused, a one-line JSON edit was accepted. Each of
# the three deletions below must be refused, because the `run` writer always stamps both.
printf '{}\n' > "$WT/.worktree-report/state.json"
drive 7 "UNMEASURABLE: a state that parses but carries NO witness keys ({}) is not evidence" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=writer-state-missing-witness*) ok "…named writer-state-missing-witness, not a verdict about the report" ;; *) bad "empty-object state reason: $LAST_OUT" ;; esac
case "$LAST_OUT" in *VERDICT=PASS*) bad "an EMPTY state object was read as a PASS" ;; *) ok "…and it is not reported as PASS" ;; esac
printf '{"version":1,"branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"2099-01-01T00:00:00Z"}]}\n' > "$WT/.worktree-report/state.json"
drive 7 "UNMEASURABLE: `head_at_write` deleted (the recorded-head witness is gone)" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=writer-state-missing-witness*) ok "…named missing-witness for the deleted head binding" ;; *) bad "deleted head_at_write reason: $LAST_OUT" ;; esac
printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0}]}\n' "$WT_HEAD" > "$WT/.worktree-report/state.json"
drive 7 "UNMEASURABLE: every suite `finished_at` deleted (the laundering witness is gone)" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=writer-state-missing-witness*) ok "…named missing-witness for the deleted timestamps" ;; *) bad "deleted finished_at reason: $LAST_OUT" ;; esac
# CONTROL: the honest shape (both witnesses present) still PASSES, so the three rows above are not just
# asserting that every state is refused.
_restore_state
drive 0 "CONTROL: a state carrying both witnesses still PASSES (the missing-witness rows are not a blanket refusal)" STUB_OK=1 STUB_RC=0 STUB_STALE=0

# ── 2. THE MEASURED DEFECT: rc 0 + a moved head is NOT a pass ────────────────────────────────────
mkdir -p "$WT/.worktree-report"
printf '{"version":1,"head_at_write":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","branch":"feat/2977-tm","suites":[]}\n' \
  > "$WT/.worktree-report/state.json"
drive 4 "STALE: the consumer exits 0 but the report was written at another head" STUB_OK=1 STUB_RC=0 STUB_STALE=1
# §7: both shas are named, and they DIFFER.
case "$LAST_OUT" in
  *report_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*merging_head=*) ok "STALE names the recorded head and the merging head" ;;
  *) bad "STALE message does not name both heads: $LAST_OUT" ;;
esac
case "$LAST_OUT" in
  *"report_head=$WT_HEAD"*) bad "STALE used the live head as 'report_head' (the consumer's \`head\`, not the writer state's \`head_at_write\`): $LAST_OUT" ;;
  *) ok "STALE does not mistake the live head for the report head" ;;
esac

# ── 2b. THE HEAD IS BOUND IN BOTH DIRECTIONS (§3) ─────────────────────────────────────────────────
# The reviewer's mutant — `head` documented in every message, compared in none — passes every row above.
# These three rows are what make it fail.
out="$(env STUB_OK=1 STUB_RC=0 STUB_STALE=0 bash "$GATE" --check "$REPO" "feat/2977-tm" "" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "EMPTY head is UNMEASURABLE (a report cannot be bound to no commit) (rc=$rc)"; else bad "empty head: expected rc=7, got rc=$rc :: $out"; fi
drive 4 "report written at ANOTHER head (the state disagrees with the head being merged)" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *VERDICT=STALE*) ok "…and it is STALE, not PASS, even though the consumer exited 0" ;; *) bad "report-bound-to-another-head did not refuse: $LAST_OUT" ;; esac
# ⛔ THE rec_head WITNESS MUST AGREE HERE, or it (checked first) answers for this row and the
# worktree-direction row silently grades the wrong rule — measured: it reported
# `reason=report-bound-to-another-head` while claiming to test the worktree.
_restore_state
# The direction `head_moved_since_write` CANNOT see: the worktree is behind the branch because something
# else pushed. The consumer reports its own worktree head, so `live_head != $head` is the only witness.
out="$(env STUB_OK=1 STUB_RC=0 STUB_STALE=0 STUB_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 4 ]; then ok "STALE: the WORKTREE is not at the head being merged (the shift no writer can see) (rc=$rc)"; else bad "worktree-behind: expected rc=4, got rc=$rc :: $out"; fi
case "$out" in *reason=worktree-is-not-at-the-merging-head*) ok "…and it names that reason, not the writer's flag" ;; *) bad "worktree-behind reason: $out" ;; esac

# ── 2c. AN UNUSABLE INPUT IS UNMEASURABLE, NEVER AN ABSTENTION (fresh review, P1) ────────────────
# An empty branch made `_lrg_worktree` return 1, so the gate answered **6 NO-WORKTREE** — the code the
# carriers log as "an abstention, not a green" and then MERGE ON. An ingress that cannot name the
# branch must not get the gate's most tolerant outcome. Same rule the empty-`head` row above states.
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "EMPTY branch is UNMEASURABLE, not a 6 abstention (rc=$rc)"; else bad "empty branch: expected rc=7, got rc=$rc :: $out"; fi
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "EMPTY repo is UNMEASURABLE, not a 6 abstention (rc=$rc)"; else bad "empty repo: expected rc=7, got rc=$rc :: $out"; fi

# ── 2d. THE LAUNDERING ARM (fresh review, P0) ────────────────────────────────────────────────────
# `write_report` re-stamps `head_at_write` on every `write`/`note`/idempotent `init`, so a lane that
# runs its suites at commit A, commits B, then runs any of those three commands presents a recorded
# head of B with evidence from A. The suite's own `finished_at` is written ONLY by `run` and is not
# touched by a render, so it is the witness that survives — and it must be load-bearing.
printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"2020-01-01T00:00:00Z"}]}\n' "$WT_HEAD" > "$WT/.worktree-report/state.json"
drive 4 "STALE: a re-rendered report whose suites finished BEFORE the merging commit existed" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=evidence-not-produced-after-the-merging-commit*) ok "…and it names the laundering reason, not the writer's flag" ;; *) bad "predates reason: $LAST_OUT" ;; esac
# The control that makes the row discriminating: evidence produced AFTER the commit (the honest
# re-run at the merging head) must still PASS, so the arm refuses the laundering and not every report.
printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"2099-01-01T00:00:00Z"}]}\n' "$WT_HEAD" > "$WT/.worktree-report/state.json"
drive 0 "PASS: evidence finished AFTER the merging commit was created (the honest re-run at the head)"
# ⛔ THE SAME-SECOND ROW (measured end-to-end before it was written): both clocks are SECOND
# resolution, so a suite finished in the commit's own second is indistinguishable between the honest
# and the laundering case. An ambiguous witness must not read as green, so equality refuses. Without
# this row a `<` mutant passes the two rows above and lets a fast commit launder in the same second.
HEAD_ISO="$(git -C "$WT" log -1 --format=%cI "$WT_HEAD")"
printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"%s"}]}\n' "$WT_HEAD" "$HEAD_ISO" > "$WT/.worktree-report/state.json"
drive 4 "STALE: evidence finished in the merging commit's OWN second (ambiguous, so it cannot pass)" STUB_OK=1 STUB_RC=0 STUB_STALE=0
_restore_state

# ── 3. RED and INVALID, and polarity by CONTENT ──────────────────────────────────────────────────
drive 3 "RED: valid evidence that records a failing suite (consumer exit 3)" STUB_OK=0 STUB_RC=3 STUB_FAILING=1
drive 2 "INVALID: the consumer's rules fail and it exits 1" STUB_OK=0 STUB_RC=1 STUB_RULES=suite-log-hash-mismatch:unit
case "$LAST_OUT" in *suite-log-hash-mismatch*) ok "INVALID names the failing rule the consumer reported" ;; *) bad "INVALID does not name the rule: $LAST_OUT" ;; esac
drive 2 "POLARITY: exit 0 with ok:false is INVALID, not PASS" STUB_OK=0 STUB_RC=0
drive 7 "UNMEASURABLE: the consumer's output is not JSON" STUB_RAW=not-json STUB_RC=0
# ── 2c. THE INHERITED `PATH` CANNOT CHOOSE THE INTERPRETER (fresh review, P1) ─────────────────────
# ⛔ THIS REPLACES AN ARM THAT COULD NO LONGER FAIL. The old row emptied `PATH` and asserted rc=7
# ("no interpreter") — which only worked while `_lrg_py` resolved python with `command -v`. That is
# exactly the bypass: `command -v` walks the INHERITED `PATH`, and a lane runs `lane-merge.sh` itself,
# forking the chain and the `$O`-pinned `merge-one.sh` under plain environment inheritance, so
# `PATH=/tmp/shim:$PATH` with a two-branch `python3` made every RED report PASS through both python
# passes. The interpreter is now pinned to ABSOLUTE candidates and `PATH` is never consulted, so the
# property to assert is not "absence is rc=7" (unsimulable on a box that HAS python) but the two
# halves below: PATH cannot redirect it, and the function does not read PATH at all.
SHIMDIR="$TMP/shim"; mkdir -p "$SHIMDIR"
# The liar: prints the laundering-witness fields a PASS needs, whatever the consumer actually said.
printf '#!/bin/sh\nprintf "1|0||%s|%s|0|0|ok\\n" "%s" "%s"\n' "$WT_HEAD" "$WT_HEAD" "$WT_HEAD" "$WT_HEAD" > "$SHIMDIR/python3"
printf '#!/bin/sh\nprintf "1|0||%s|%s|0|0|ok\\n" "%s" "%s"\n' "$WT_HEAD" "$WT_HEAD" "$WT_HEAD" "$WT_HEAD" > "$SHIMDIR/python"
chmod +x "$SHIMDIR/python3" "$SHIMDIR/python"
# Negative control FIRST: prove the shim WOULD have flipped the verdict, so the arm can fail.
_shim_wins="$(PATH="$SHIMDIR" /bin/sh -c 'command -v python3' 2>/dev/null)"
if [ "$_shim_wins" = "$SHIMDIR/python3" ]; then ok "CONTROL the planted python3 IS what a PATH lookup returns ($_shim_wins) — so the arm below can fail"; else bad "CONTROL the planted shim is not reachable by a PATH lookup, so the arm below cannot fail"; fi
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 PATH="$SHIMDIR:$PATH" bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "a PATH-shimmed python3 does NOT flip genuinely RED evidence (rc=$rc) — the interpreter is pinned, not inherited"; else bad "PATH chose the interpreter: expected rc=3, got rc=$rc :: $out"; fi
# ── 2d. NO AMBIENT IMPORT OR GIT VARIABLE MAY DECIDE THE VERDICT EITHER (round-6 review, P0) ──
# ⛔ PINNING THE INTERPRETER PATH CLOSES "WHICH PROGRAM", NOT "WHICH MODULES". `python3 -c` puts `''`
# (the process CWD) at `sys.path[0]` and honours `PYTHONPATH`, and BOTH are lane-controlled: a lane runs
# lane-merge.sh itself with cwd = its own worktree, so an UNTRACKED `json.py` (or one `export`) made the
# single pass that decides ok/stale/rec_head/predates return whatever the graded party wanted —
# measured RED (rc 3) → PASS (rc 0) with a shim that only defines `loads()`. Both invocations now run
# under `-I`, which implies `-E -s` and drops the cwd/script-dir entry.
SEAM="$TMP/seam"; mkdir -p "$SEAM/shim" "$SEAM/cwd"
cat > "$SEAM/shim/json.py" <<'LIARJSON'
def loads(s, *a, **k):
    return {"ok": True, "rules": [], "suites": 1, "failing_suites": 0,
            "head": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", "head_moved_since_write": False}
def load(f, *a, **k):
    return {}
LIARJSON
cp "$SEAM/shim/json.py" "$SEAM/cwd/json.py"
# Negative control: prove the shim WOULD have decided, so the arm can fail.
_ctl="$(PYTHONPATH="$SEAM/shim" "$(command -v python3)" -c 'import json; print(json.loads("{}").get("ok"))' 2>/dev/null)"
if [ "$_ctl" = "True" ]; then ok "CONTROL the PYTHONPATH shim DOES decide a bare python3 import — so the arms below can fail"; else bad "CONTROL the PYTHONPATH shim is inert, so the arms below cannot fail"; fi
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 PYTHONPATH="$SEAM/shim" bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "a PYTHONPATH-supplied json cannot flip genuinely RED evidence (rc=$rc) — the verdict pass is isolated"; else bad "PYTHONPATH supplied the module that computes the verdict: expected rc=3, got rc=$rc :: $out"; fi
# The untracked-cwd variant needs no env at all — the lane simply runs the gate from its own worktree.
out="$(cd "$SEAM/cwd" && env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "…and an UNTRACKED json.py in the calling directory cannot either (rc=$rc)"; else bad "a cwd json.py decided the verdict: expected rc=3, got rc=$rc :: $out"; fi
# ⛔ `git -C <dir>` DOES NOT OVERRIDE AN AMBIENT `GIT_DIR`, so the enumerations that choose WHICH REPO is
# graded could be answered by another repository entirely (measured: a foreign GIT_DIR made the gate grade
# another repo's worktree and PASS for a branch/head belonging to the named repo).
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 GIT_DIR=/nonexistent/git/dir bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "…and an ambient GIT_DIR cannot retarget which repo is graded (rc=$rc)"; else bad "GIT_DIR retargeted the enumeration: expected rc=3, got rc=$rc :: $out"; fi

# ── 2e. THE GIT SEAM: THE FUNCTION VECTOR IS CLOSED, THE PATH VECTOR IS DISCLOSED (round-7 review, P0)
# ⛔ THE PROGRAM THAT ANSWERS worktree/HEAD/commit-date DECIDES WHICH REPO IS GRADED, so it is as
# load-bearing as the interpreter. Two vectors, and they are handled DIFFERENTLY on purpose:
#   (1) an exported bash function (`git() {…}; export -f git` → `BASH_FUNC_git%%` in the child hops a
#       lane's carrier forks) shadows the binary with NO PATH change. Closed by `unset -f git` at source
#       time — asserted behaviourally below.
#   (2) a `git` earlier on the inherited PATH. NOT closed: pinning to absolute paths was implemented and
#       REVERTED because the merge-one fixtures drive this gate with a stubbed `git` over a synthetic
#       repo/head, so the pin bypassed the stub and took 66 rows red. That residual is FILED and
#       DISCLOSED in the gate — asserted below — because a silent omission is the failure mode here.
GSHIM="$TMP/gitshim"; mkdir -p "$GSHIM"
printf '#!/bin/sh\nexit 1\n' > "$GSHIM/git"; chmod +x "$GSHIM/git"
out="$(bash -c 'git() { return 1; }; export -f git; STUB_OK=0 STUB_RC=3 STUB_FAILING=1 exec bash "$1" --check "$2" feat/2977-tm "$3"' _ "$GATE" "$REPO" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "an EXPORTED bash function named git cannot replace the binary (rc=$rc) — the function namespace is cleared at source time"; else bad "an exported git function replaced the binary: expected rc=3, got rc=$rc :: $out"; fi
# NEGATIVE CONTROL: the same exported function DOES shadow an unreserved git, so the row above can fail.
_cf="$(bash -c 'git() { echo HIJACKED; }; export -f git; exec bash -c "git --version"' 2>&1 | head -1)"
if [ "$_cf" = "HIJACKED" ]; then ok "CONTROL an exported git function DOES shadow a bare git — so the row above can fail"; else bad "CONTROL the exported-function shadow is inert ($_cf), so the row above cannot fail"; fi
if grep -q 'unset -f git' "$GATE"; then ok "…and the gate clears the git function namespace explicitly (unset -f git)"; else bad "the gate no longer clears exported git functions"; fi
# ⛔ THE DISCLOSURE PIN. The PATH residual must stay written down, with the reason its fix was reverted, or
# the next reader will assume the seam class is fully closed (the file claims it for python).
if grep -q 'A `git` EARLIER ON THE INHERITED `PATH`' "$GATE" && grep -q 'REVERTED' "$GATE" \
   && grep -q '66 of that suite' "$GATE" && grep -q '#3789' "$GATE"; then
  ok "…and the PATH-shim residual is DISCLOSED with its over-block AND a tracker reference (#3789) — so filed is checkable"
else
  bad "the git PATH-shim residual is no longer disclosed in the gate — an open P0 would read as closed"
fi

# ── 2f. A GATE-ENABLE KNOB IS THE INERT GATE, AND NEITHER SUITE CAUGHT IT (round-7 review, P2) ─
# ⛔ THE NESTING ROW ABOVE READS THE LINE *BEFORE* THE ANCHOR, so a guard opened immediately AFTER the
# anchor is invisible to it — and that is byte-for-byte the instance its own comment names. Measured:
# wrapping the block in `if [ -n "${LANE_REPORT_ENFORCE:-}" ]; then … fi` left THIS suite at 82/82 AND
# lane-merge.test.sh at 115/115, while lane-merge.sh logged "lane-report: verified at head …" — a claim
# of a verification that never ran. The assertions below pin what such a wrapper breaks.
# The block ends at the `launch_chain` INVOCATION (`launch_chain()` is DEFINED far earlier, so an
# `^launch_chain` range end matched nothing and the span came back empty — a range that yields nothing
# is not a pass, it is a silent skip).
_lm_anchor="$(grep -nE '^_lrg_rc=0; _lrg_out=""' "$LANE_MERGE" | head -1 | cut -d: -f1)"
_lm_block="$([ -n "$_lm_anchor" ] && sed -n "${_lm_anchor},/^launch_chain /p" "$LANE_MERGE")"
if [ -z "$_lm_block" ]; then bad "the lane-merge.sh gate-block span could not be extracted (anchor=${_lm_anchor:-none}) — the rows below would be vacuous"; fi
_knob="$(printf '%s\n' "$_lm_block" | grep -nE '^[[:space:]]*(if|elif|while)[[:space:]].*:-' | head -1)"
if [ -n "$_knob" ]; then
  bad "lane-merge.sh's gate block is guarded by an opt-in default ($_knob) — unset means the gate never runs"
else
  ok "lane-merge.sh's gate block has no opt-in enable knob — an unset variable cannot switch it off"
fi
_n_reset="$(printf '%s\n' "$_lm_block" | grep -cE '_lrg_rc=0')"
if [ "$_n_reset" = 1 ]; then
  ok "…and _lrg_rc=0 appears exactly once (at the anchor) — a later reset cannot launder a refusal"
else
  bad "the gate block contains $_n_reset _lrg_rc=0 assignments — one of them can mask the verdict"
fi
if printf '%s\n' "$_lm_block" | grep -E 'verified at head' | grep -qE '^[[:space:]]*0\)'; then
  ok "…and 'verified at head' is emitted only from the 0) arm — the log cannot claim a verdict it did not get"
else
  bad "the 'verified at head' line is not confined to the 0) arm of the verdict case"
fi

# ── 2g. GIT_COMMON_DIR IS THE SAME SEAM AS GIT_DIR (round-8 review, P1) ────────────────────
# ⛔ It retargets BOTH `worktree list` enumerations — the branch's worktree AND the main worktree the
# consumer is read from — and it also retargets `resolve_trusted_checkout` in lane-merge.sh, i.e. the
# function the provenance disposition leans on. Measured: `GIT_COMMON_DIR=<clone>/.git` turned
# VERDICT=ABSENT rc=1 into VERDICT=PASS rc=0, with graded tree and verifier both from the other repo.
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 GIT_COMMON_DIR=/nonexistent/common bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "…and an ambient GIT_COMMON_DIR cannot retarget the enumeration either (rc=$rc)"; else bad "GIT_COMMON_DIR retargeted the enumeration: expected rc=3, got rc=$rc :: $out"; fi

# ── 2j. A REPLACE REF CANNOT FORGE THE COMMIT DATE (round-9 review, P1) ──────────────────
# ⛔ `refs/replace/*` does not RELOCATE the repo (so the entry-time unsets cannot see it): it makes
# `git log -1 --format=%cI <head>` return a SUBSTITUTED commit's date, forging the `predates` witness with
# `state.json` untouched (`cmp` identical in the measurement). The ref lives in the common gitdir, is not
# on the branch, and is invisible in the reviewed diff.
if git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
  _base="$(git -C "$WT" rev-parse HEAD)"
  _forged="$(GIT_COMMITTER_DATE=2010-01-01T00:00:00Z GIT_AUTHOR_DATE=2010-01-01T00:00:00Z \
             git -C "$WT" commit-tree "$_base^{tree}" -p "$_base" -m forged 2>/dev/null)"
  if [ -n "$_forged" ] && git -C "$WT" replace "$_base" "$_forged" 2>/dev/null; then
    _seen="$(git -C "$WT" log -1 --format=%cI "$_base" 2>/dev/null)"
    case "$_seen" in 2010-*) ok "CONTROL the replace ref DOES change what git reports for that commit — so the row below can fail" ;;
                   *) bad "CONTROL the replace ref did not take effect ($_seen), so the row below cannot fail" ;; esac
    # The state's witness would otherwise say STALE (finished long before the merging commit); with the
    # forged date it would say PASS. The gate must not honour the replacement.
    printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"2020-01-01T00:00:00Z"}]}\n' "$WT_HEAD" > "$WT/.worktree-report/state.json"
    out="$(env STUB_OK=1 STUB_RC=0 STUB_STALE=0 bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
    if [ "$rc" = 4 ]; then ok "a refs/replace ref cannot forge the commit date the laundering arm reads (rc=$rc, still STALE)"; else bad "a replace ref forged the commit date: expected rc=4, got rc=$rc :: $out"; fi
    git -C "$WT" replace -d "$_base" 2>/dev/null || true
  else
    ok "SKIPPED the replace-ref row (git replace unavailable in this fixture)"
  fi
  _restore_state
fi

# ── 2h. THE STATE MUST AGREE WITH THE SEALED REPORT (round-8 review, P1) ──────────────────
# ⛔ `state.json` CARRIES NO DIGEST — only WORKTREE-REPORT.md is sealed — so a two-field EDIT (head_at_write
# + the newest finished_at) laundered a STALE report into PASS while the sealed report still named the
# old head: a self-contradicting artifact, which this file's header says must not be mergeable.
_SEALED_A="aaaaaaaaaaaa"; _SEALED_B="bbbbbbbbbbbb"
printf '## Files changed\n- **Base:** `main` → **head at write:** `%s`\n## Suites run\n## Could not do\n' "$_SEALED_A" > "$WT/WORKTREE-REPORT.md"
printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"2099-01-01T00:00:00Z"}]}\n' "$_SEALED_B" > "$WT/.worktree-report/state.json"
drive 4 "STALE: the state claims a head the SEALED report does not name (a falsified state is self-contradicting)" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *reason=state-disagrees-with-the-sealed-report*) ok "…and it names the disagreement rather than reporting a head binding" ;; *) bad "sealed-vs-state reason: $LAST_OUT" ;; esac
case "$LAST_OUT" in *VERDICT=PASS*) bad "a state contradicting the sealed report was read as a PASS" ;; *) ok "…and it is not reported as PASS" ;; esac
# CONTROL: when the two halves AGREE, the honest flow still passes.
printf '## Files changed\n- **Base:** `main` → **head at write:** `%s`\n## Suites run\n## Could not do\n' "$(printf '%s' "$WT_HEAD" | cut -c1-12)" > "$WT/WORKTREE-REPORT.md"
_restore_state
drive 0 "CONTROL: a report whose sealed head AGREES with the state still PASSES" STUB_OK=1 STUB_RC=0 STUB_STALE=0
# Restore the stanza-free report the baseline fixtures use, so later arms that re-point the head are not
# judged against a stamp from this block.
printf '## Files changed\n## Suites run\n## Could not do\n' > "$WT/WORKTREE-REPORT.md"

# ── 2i. THE INTERPRETER IS VERSION-GATED, NOT FIRST-FOUND (round-8 review, P1) ─────────────
# ⛔ The consumer REFUSES an interpreter below 3.12 by design and prints NOTHING when it does, so the gate
# saw "no JSON" -> 7 -> a refusal the lane cannot remedy, on every box whose FIRST candidate is older
# (macOS `/usr/bin/python3` is 3.9; the 3.12+ build sits under /opt/homebrew, which was consulted THIRD).
_py_chosen="$(bash -c '. "$1" >/dev/null 2>&1; _lrg_py' _ "$GATE" 2>/dev/null)"
if [ -n "$_py_chosen" ] && "$_py_chosen" -I -c 'import sys; raise SystemExit(0 if sys.version_info>=(3,12) else 1)' 2>/dev/null; then
  ok "the resolved interpreter MEETS the consumer's 3.12 floor ($_py_chosen)"
else
  bad "the resolved interpreter does not meet the 3.12 floor (got '${_py_chosen:-none}') — every merge on an older-first box would be refused"
fi
# ⛔ THE FLOOR VALUE ITSELF IS PINNED, not just the fact that a probe exists. On a box where every
# candidate is 3.12 (this CI cell) lowering the floor changes no outcome, so a behavioural arm alone
# cannot see a `>= (0, 0)` mutant — measured: it stayed green. The floor must match the consumer's
# documented requirement, so the literal is asserted.
if grep -q 'sys.version_info' "$GATE" && grep -q '(3, 12)' "$GATE"; then
  ok "…and the floor is probed per candidate at the consumer's documented 3.12, not assumed from the path"
else
  bad "the interpreter floor is not pinned at 3.12 (first-found or a lower floor is worst-first on macOS)"
fi

# The structural half: the resolver must not consult PATH at all. Kept deliberately BLUNT (any
# `command -v` in the function body fails) — a precise pattern here is how the previous version of this
# row matched nothing and stayed green over a mutant.
_lrg_py_body="$(sed -n '/^_lrg_py()/,/^}/p' "$GATE")"
if grep -q 'command -v' <<< "$_lrg_py_body"; then bad "_lrg_py still resolves the interpreter with command -v (a PATH lookup)"; else ok "_lrg_py never consults PATH — its candidates are absolute"; fi

# ── 3b. NO AMBIENT ENV VAR MAY SELECT THE VERIFIER (fresh review, P1) ─────────────────────────────
# The "disable it by ambient env" bypass: a lane runs lane-merge.sh itself, which forks the chain and
# the $O-pinned merge-one.sh under plain inheritance, so one `export` reached the backstop carrier.
# The seam is deleted; this row proves a liar named in the env cannot override the repo's consumer.
LIAR="$TMP/liar_tool.py"
printf 'import json,sys\nprint(json.dumps({"ok":True,"rules":[],"suites":1,"failing_suites":0,"head":"%s","head_moved_since_write":False}))\n' "$WT_HEAD" > "$LIAR"
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 LANE_REPORT_GATE_TOOL="$LIAR" bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "LANE_REPORT_GATE_TOOL in the ambient env is IGNORED — the repo's consumer still decides (rc=$rc)"; else bad "ambient LANE_REPORT_GATE_TOOL overrode the verifier: expected rc=3, got rc=$rc :: $out"; fi
# ⛔ THE `_PY` HALF OF THE SAME SEAM (fresh review, P2): it chooses the program that computes ok/predates/
# skew — i.e. EVERY arm — and was reachable through the same inheritance chain. Over genuinely RED
# evidence it must change nothing.
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 LANE_REPORT_GATE_PY=/bin/true bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "LANE_REPORT_GATE_PY in the ambient env is IGNORED — RED evidence is still RED (rc=$rc)"; else bad "ambient LANE_REPORT_GATE_PY overrode the interpreter: expected rc=3, got rc=$rc :: $out"; fi

# ── 3c. AN UNUSABLE repo IS 7, NOT A 6 ABSTENTION (fresh review, P2) ─────────────────────────────
mkdir -p "$TMP/plaindir"
out="$(bash "$GATE" --check "$TMP/plaindir" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "a NON-GIT repo is UNMEASURABLE, not a 6 abstention (rc=$rc)"; else bad "non-git repo: expected rc=7, got rc=$rc :: $out"; fi
out="$(bash "$GATE" --check "$TMP/no-such-path-xyz" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "a NONEXISTENT repo path is UNMEASURABLE, not a 6 abstention (rc=$rc)"; else bad "nonexistent repo: expected rc=7, got rc=$rc :: $out"; fi

# ── 4. ABSENT / NO-CONSUMER / UNMEASURABLE-with-report ───────────────────────────────────────────
mv "$WT/WORKTREE-REPORT.md" "$TMP/report.bak"
drive 1 "ABSENT: a worktree for this branch with no report — silence"
mv "$TMP/report.bak" "$WT/WORKTREE-REPORT.md"
mv "$REPO/tools/worktree_report.py" "$TMP/stub.bak"
mv "$WT/WORKTREE-REPORT.md" "$TMP/report.bak"
drive 5 "NO-CONSUMER: the repo ships no writer, so no report of this format exists (not a refusal)"
mv "$TMP/report.bak" "$WT/WORKTREE-REPORT.md"
# (the arm above needs the report GONE and no consumer; the next one needs the report PRESENT, so the
# two arms are driven in that order rather than by a shared fixture state.)
out="$(env STUB_OK=1 bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "UNMEASURABLE: report present but no consumer to verify it (rc=$rc)"; else bad "report-present-no-consumer: expected rc=7, got rc=$rc :: $out"; fi
mv "$TMP/stub.bak" "$REPO/tools/worktree_report.py"

# ── 4b. THE VERIFIER COMES FROM THE TRUSTED CHECKOUT, NOT THE TREE BEING MERGED (fresh review, P2) ──
# `$wt` is the LANE worktree on the branch under review, so a gate that preferred its copy of
# `tools/worktree_report.py` would run a grader the graded tree supplies — the "rewrite the grader"
# bypass. Plant a LYING consumer in the worktree and assert the trusted checkout's honest one still
# decides (RED here); a first-preference-on-`$wt` mutant returns PASS and reds this row.
mkdir -p "$WT/tools"
cat > "$WT/tools/worktree_report.py" <<'LIAR'
import json, subprocess, sys
wt = sys.argv[sys.argv.index("--worktree") + 1] if "--worktree" in sys.argv else "."
head = subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
print(json.dumps({"ok": True, "rules": [], "suites": 1, "failing_suites": 0,
                  "head": head, "head_moved_since_write": False}))
LIAR
drive 3 "the worktree's OWN lying consumer does not grade it — the trusted checkout's consumer decides" STUB_OK=0 STUB_RC=3 STUB_FAILING=1
# ⛔ THE SAME ESCAPE THROUGH THE `$repo` HALF (fresh review, P2). `lane-merge.sh` resolves the trusted
# checkout itself and passes MAIN, so the row above held for that carrier by CONVENTION. `merge-one.sh`
# passes `$REPO` straight from argv — and a lane that runs the deployed merge-one.sh from its own
# worktree hands the gate the graded tree, so the liars above become the grader. The gate now resolves
# the consumer from the repo's MAIN worktree, which makes the property hold for every carrier. Fed the
# LANE worktree as `$repo`, the lying consumer there must STILL not decide.
out="$(env STUB_OK=0 STUB_RC=3 STUB_FAILING=1 bash "$GATE" --check "$WT" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 3 ]; then ok "a lane worktree passed as \$repo does not grade itself — the main worktree's consumer still decides (rc=$rc)"; else bad "the lane worktree graded itself when handed as \$repo: expected rc=3, got rc=$rc :: $out"; fi
case "$out" in
  *reason=recorded-suites-did-not-pass*) ok "…and the verdict is the MAIN worktree consumer's (its rule set), not the lane's liar" ;;
  *) bad "the verdict did not come from the main worktree's consumer: $out" ;;
esac
# ⛔ THE INDEPENDENT CLONE IS *NOT* CLOSED HERE — AND THAT IS DISCLOSED, NOT HIDDEN (round-7 review, P1).
# A clone's own main worktree IS the clone, so a caller that hands the gate a clone supplies the graded
# tree's own consumer. The gate cannot fix it (it has no trusted notion of which repo is the subject),
# so the disposition is: `lane-merge.sh` resolves a trusted checkout and passes MAIN; `merge-one.sh`
# takes `$REPO` from argv and is therefore the caller obligation. ⛔ A PATH-SHAPE FIX WAS TRIED AND
# REVERTED — refusing when the consumer sits under `$wt` over-blocked the ORDINARY case (a lane working
# in the repo root legitimately has its consumer inside `$wt`): measured, 66 merge-one rows went red.
# This row pins the DISCLOSURE, so the residual cannot be dropped by deleting the comment that records it.
if grep -q 'INDEPENDENT-CLONE' "$GATE" \
   && grep -q 'merge-one.sh. takes .\$REPO. from argv' "$GATE" \
   && grep -q 'OVERS-BLOCKS\|OVER-BLOCKS' "$GATE"; then
  ok "the consumer-provenance residual (an independent clone is NOT covered) is DISCLOSED in the gate, with the over-block that a path check causes"
else
  bad "the gate no longer discloses the independent-clone residual (or the over-block that rules out a path-shape fix) — the limitation would go unrecorded"
fi
if grep -q 'SCOPE — WHICH PATHS ARE COVERED' scripts/orchestrator-harness/README.md 2>/dev/null; then
  ok "…and the README states the SCOPE of the guarantee rather than claiming every merge path is covered"
else
  bad "the README does not scope the guarantee — auto-rail.sh merges without this gate and the text implies otherwise"
fi

# ── 5. EXACT BRANCH MATCH (§6) — both mutant directions — the decoys sort FIRST in the walk ──
# ── 5. EXACT BRANCH MATCH (§6) — both mutant directions, and the decoys sort BEFORE the real worktree ──
# (a) the EXTENSION decoy's branch starts with the real branch and its PATH sorts before the real
#     worktree, so an extension mutant selects it before it can reach the real one.
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
case "$out" in
  *worktree="$DECOY_E "*) bad "an EXTENSION decoy was selected for feat/2977-tm (prefix mutant): $out" ;;
  *worktree="$WT "*)      ok "a preceding EXTENSION worktree (feat/2977-tm-extra) is never selected for feat/2977-tm" ;;
  *)                      bad "extension-decoy arm resolved neither worktree: $out" ;;
esac
# (b) the PREFIX decoy is selectable for its OWN branch — the control that it exists and matches.
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/2977" "$(git -C "$DECOY_P" rev-parse HEAD)" 2>&1)"; rc=$?
case "$out" in *worktree="$DECOY_P "*) ok "the TRUE-PREFIX decoy (feat/2977) is selected for its own branch (control)" ;; *) bad "prefix control: $out" ;; esac
# (c) the documented arm the first version never executed: a branch that no worktree is on, but which a
# prefix-mutant WILL match (it starts with the decoy's branch) — must be NO-WORKTREE, never a verdict.
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/2977-ext" deadbeef 2>&1)"; rc=$?
if [ "$rc" = 6 ]; then ok "NO-WORKTREE for feat/2977-ext (a reverse-prefix mutant would have graded the feat/2977 decoy) (rc=$rc)"; else bad "reverse-prefix arm: expected rc=6, got rc=$rc :: $out"; fi

# ── 6. NO-WORKTREE ───────────────────────────────────────────────────────────────────────────────
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/nobody-tm" deadbeef 2>&1)"; rc=$?
if [ "$rc" = 6 ]; then ok "NO-WORKTREE: no worktree on this box for the branch (an abstention, not a pass) (rc=$rc)"; else bad "NO-WORKTREE: expected rc=6, got rc=$rc :: $out"; fi
case "$out" in *VERDICT=NO-WORKTREE*) ok "NO-WORKTREE is spelled on the line, so a census can count abstentions" ;; *) bad "NO-WORKTREE line: $out" ;; esac
# ⛔ A PRUNABLE REGISTRATION IS NOT EVIDENCE (fresh review, P2): `git worktree list --porcelain` keeps the
# stanza after the directory is deleted, so a resolver that trusts it refuses ABSENT on a file that
# cannot exist — with a remedy that is impossible in a worktree that is gone. It is 6, the code for
# "the evidence is not reachable from here".
git -C "$REPO" worktree add -q -b feat/gone "$TMP/gone" main 2>/dev/null || true
rm -rf "$TMP/gone"
out="$(bash "$GATE" --check "$REPO" "feat/gone" "$(git -C "$REPO" rev-parse HEAD)" 2>&1)"; rc=$?
if [ "$rc" = 6 ] && grep -q 'reason=worktree-directory-is-gone' <<<"$out"; then
  ok "a PRUNABLE worktree registration is NO-WORKTREE (6), not ABSENT with an impossible remedy (rc=$rc)"
else
  bad "prunable worktree: expected rc=6 + worktree-directory-is-gone, got rc=$rc :: $out"
fi
git -C "$REPO" worktree prune 2>/dev/null || true

# ── 7. USAGE ─────────────────────────────────────────────────────────────────────────────────────
out="$(bash "$GATE" 2>&1)"; rc=$?
[ "$rc" = 64 ] && case "$out" in *usage:*) ok "no arguments prints usage and exits 64" ;; *) bad "usage text missing" ;; esac || bad "usage exit code: expected 64, got rc=$rc"

# ── 8. WIRING (§8) — anchored on the CODE lines, never on prose ──────────────────────────────────
# ⛔ THE ANCHORS ARE THE DEFECT THIS SECTION EXISTS FOR. `lane-merge.sh` names `lane_report_gate` in a
# comment above its call, and the first version's `grep -n 'lane_report_gate'` matched THAT — so the
# reviewer deleted the call and the whole suite stayed green. Every regex below matches a line that
# sources the file or calls the function, and nothing else can satisfy it.
lm_src="$(grep -nE '^\[ -n "\$LANE_REPORT_GATE" \] && \. ' "$LANE_MERGE" | head -1 | cut -d: -f1)"
lm_call="$(grep -nE '^[[:space:]]*_lrg_out="\$\(lane_report_gate ' "$LANE_MERGE" | head -1 | cut -d: -f1)"
lm_chain="$(grep -nE '^[[:space:]]*launch_chain "\$HEAD"' "$LANE_MERGE" | tail -1 | cut -d: -f1)"
if [ -n "$lm_src" ] && [ -n "$lm_call" ] && [ -n "$lm_chain" ] && [ "$lm_src" -lt "$lm_call" ] && [ "$lm_call" -lt "$lm_chain" ]; then
  ok "lane-merge.sh SOURCES the gate (line $lm_src) and CALLS it (line $lm_call) before launch_chain (line $lm_chain)"
else
  bad "lane-merge.sh wiring: source=${lm_src:-none} call=${lm_call:-none} chain=${lm_chain:-none} — the gate must be sourced and its result used before the chain launches"
fi
co_src="$(grep -nE '^\. "\$LANE_REPORT_GATE" ' "$MERGE_ONE" | head -1 | cut -d: -f1)"
co_call="$(grep -nE '^_lrg_out="\$\(lane_report_gate ' "$MERGE_ONE" | head -1 | cut -d: -f1)"
# ⛔ THE ANCHOR IS THE RECORDER PROBE, not `run_agent`: `run_agent` also appears in its own DEFINITION
# (line ~502), so anchoring on it would pass whatever the call order actually is.
co_paid="$(grep -nE '^RECORDER="\$HOME' "$MERGE_ONE" | head -1 | cut -d: -f1)"
if [ -n "$co_src" ] && [ -n "$co_call" ] && [ -n "$co_paid" ] && [ "$co_call" -lt "$co_paid" ]; then
  ok "merge-one.sh SOURCES the gate (line $co_src) and CALLS it (line $co_call) before the paid/review path (line $co_paid)"
else
  bad "merge-one.sh wiring: source=${co_src:-none} call=${co_call:-none} paid=${co_paid:-none}"
fi
# ⛔ THE REFUSAL MUST BE PINNED, NOT JUST THE CALL (fresh review, P1). Deleting the disposition
# from BOTH carriers left this suite 29/29 green — a gate that runs, prints its verdict, and is
# ignored. Assert the code line BETWEEN the call and the thing it protects, so a decorative gate
# cannot pass, and pin the rail ordering (a check after the rail short-circuit skips every rail repo).
if sed -n "$((lm_call)),$((lm_chain))p" "$LANE_MERGE" | grep -qE '^[[:space:]]*emit_fix FIX_REQUIRED '; then
  ok "lane-merge.sh's refusal is a FIX_REQUIRED disposition between the call and launch_chain"
else
  bad "lane-merge.sh calls the gate but never refuses: no 'emit_fix FIX_REQUIRED' between line $lm_call and $lm_chain"
fi
co_rail="$(grep -nE '^if \[ "\$MERGE_AUTHORITY" = "rail" \]; then' "$MERGE_ONE" | head -1 | cut -d: -f1)"
if [ -n "$co_rail" ] && [ "$co_call" -lt "$co_rail" ]; then
  ok "merge-one.sh gates BEFORE the rail short-circuit (call line $co_call < rail line $co_rail)"
else
  bad "merge-one.sh: the gate call (${co_call:-none}) must precede the rail short-circuit (${co_rail:-none}) — a check after it skips every rail repo's merge"
fi
# ⛔ LINE ORDER ALONE IS NOT ENOUGH (fresh review, P1): wrapping the block in `if [ "$MERGE_AUTHORITY"
# != "rail" ]` keeps every line in order while skipping the gate on EXACTLY the repos the PR names as
# the ones where the lane report is the only evidence. The block must be UNGUARDED, so assert the
# lines immediately above it cannot be such a guard.
co_head="$(grep -nE '^_lrg_rc=0; _lrg_out=""' "$MERGE_ONE" | head -1 | cut -d: -f1)"
if [ -z "$co_head" ]; then
  bad "merge-one.sh: the gate block's first line is unrecognisable — the rail-guard assertion cannot read it"
elif sed -n "$((co_head-3)),$((co_head-1))p" "$MERGE_ONE" | grep -qE 'MERGE_AUTHORITY'; then
  bad "merge-one.sh's gate block is guarded by MERGE_AUTHORITY — a rail-repo skip defeats the gate on every repo that needs it"
else
  ok "merge-one.sh's gate block is UNGUARDED (it runs on rail repos too)"
fi
# ⛔ LINE ORDER AND "NO MERGE_AUTHORITY NEARBY" ARE STILL SYNTACTIC (fresh review, P2): wrapping the
# block in a never-true guard (`if false; then`), or in a config flag that defaults off, keeps every
# anchor and every ordering while making the gate INERT — the cycle-1 finding one wrapper away. The
# realistic instance is `if [ -n "${LANE_REPORT_ENFORCE:-}" ]; then`, so assert the block is not nested
# in ANY conditional: the nearest preceding non-blank, non-comment line must not open a block.
_guard_of() { # _guard_of <file> <head-line> — the nearest preceding code line
  awk -v t="$2" 'NR<t { if ($0 ~ /^[[:space:]]*$/) next; if ($0 ~ /^[[:space:]]*#/) next; last=$0 } END { print last }' "$1"
}
# ⛔ THE ANCHOR MUST BE ABLE TO MATCH, AND AN UNMATCHED ANCHOR MUST FAIL (fresh review, P2). The
# pattern here was `^_lrg_rc=0; _lrg_out=""$`, but lane-merge.sh's real first line is
# `_lrg_rc=0; _lrg_out=""; _lrg_skip=0` — the `$` made it match NOTHING, so `lm_head` was empty, the
# guard lookup returned nothing, and the `case` fell to `*` and reported PASS with an EMPTY
# `(preceding code line: )` in the message. Measured: wrapping lane-merge.sh's whole gate block in
# `if false; then … fi` left this suite at 56 passed / 0 failed. An anchored pattern is only a guard if
# its silence is a failure, so the empty case is now its own `bad` and the loop is skipped.
lm_head="$(grep -nE '^_lrg_rc=0; _lrg_out=""' "$LANE_MERGE" | head -1 | cut -d: -f1)"
if [ -z "$lm_head" ]; then
  bad "lane-merge.sh: the gate block's first line is unrecognisable — the nesting assertion cannot read it"
fi
for _pair in "lane-merge.sh:$lm_head" "merge-one.sh:$co_head"; do
  _f="${_pair%%:*}"; _ln="${_pair##*:}"
  _g="$(_guard_of "$HERE/$_f" "$_ln")"
  # ⛔ A `*'then'`-ONLY MATCH IS A HEURISTIC THAT ENUMERATES THE WRAPPERS THE AUTHOR THOUGHT OF (fresh
  # review, P2): `while false; do` and an extract-into-an-uncalled-function both left the suite green.
  # Match every block opener that can make a top-level block unreachable-by-default.
  case "$_g" in
    *'then'|*' do'|*'() {'|*' {')
      bad "$_f's gate block is NESTED or inside a definition (preceding code line: '$_g') — a wrapper that never runs makes the gate inert while every anchor stays green" ;;
    *)  ok "$_f's gate block is not nested in a conditional or a definition (preceding code line: $(printf '%s' "$_g" | cut -c1-40))" ;;
  esac
done
if [ -n "$co_rail" ] && sed -n "$((co_call)),$((co_rail))p" "$MERGE_ONE" | grep -qE '^[[:space:]]*exit 9 ;;'; then
  ok "merge-one.sh's refusal exits 9 between the call and the rail short-circuit"
else
  bad "merge-one.sh calls the gate but has no 'exit 9' refusal before the rail short-circuit"
fi
if sed -n "$((co_call)),$((co_call+8))p" "$MERGE_ONE" | grep -q 'park '; then
  bad "merge-one.sh PARKS on a report refusal — a HEAD-keyed park deadlocks the re-run that is the remedy"
else
  ok "merge-one.sh does not park on a report refusal (the remedy is a re-run at the same head)"
fi
# ⛔ THE ABSTENTION AUDIT STRING IS THE WHOLE JUSTIFICATION FOR NOT REFUSING (fresh review, P2). The
# scoping decision makes 5/6 acceptable ONLY because they are logged "so a fleet-wide census can see how
# much of the queue is actually covered" and are "never counted as a green". Nothing pinned that: both
# carriers' abstention arms could be made SILENT, or made to print "verified at head …", with every
# suite green. Pin the audit half here (the reachability half is the nesting row above).
# ⛔ ASSERT THE ARM LINE ITSELF, NOT A FILE-WIDE REGEX (fresh review, P2): `grep -E 'verified at head .*5\|6'`
# reads `\|` as a LITERAL pipe, so it matched nothing and the negative half was inert. Extracting the
# `5|6)` arm and testing THAT line is the only version that can fail.
# ⛔ READ THE LINE ONCE INTO A VARIABLE AND TEST IT WITH A HERE-STRING: `sed -n Np file | grep -q` is
# itself a SIGPIPE false-negative (the quiet grep exits on its first match and sed dies of SIGPIPE
# under pipefail), so the assertion meant to protect the audit string could silently invert.
_lm56="$(grep -nE '^[[:space:]]*5\|6\)' "$LANE_MERGE" | head -1 | cut -d: -f1)"
_lm56_line=""; [ -n "$_lm56" ] && _lm56_line="$(sed -n "${_lm56}p" "$LANE_MERGE")"
if [ -n "$_lm56" ] && grep -qE 'abstention, not a green' <<<"$_lm56_line" \
   && ! grep -qiE 'was verified|is verified|verified at head' <<<"$_lm56_line"; then
  ok "lane-merge.sh's 5/6 arm SAYS abstention and does not claim a verification"
else
  bad "lane-merge.sh's abstention arm no longer names itself, or claims a verification"
fi
_co56="$(grep -nE '^[[:space:]]*5\|6\)' "$MERGE_ONE" | head -1 | cut -d: -f1)"
_co56_line=""; [ -n "$_co56" ] && _co56_line="$(sed -n "${_co56}p" "$MERGE_ONE")"
if [ -n "$_co56" ] && grep -qE 'NOT ENFORCED' <<<"$_co56_line" \
   && grep -qE 'ABSTENTION, not a green' <<<"$_co56_line" \
   && ! grep -qiE 'was verified|is verified|verified at head' <<<"$_co56_line"; then
  ok "merge-one.sh's 5/6 arm still records NOT ENFORCED / ABSTENTION and claims no verification"
else
  bad "merge-one.sh's abstention arm no longer records the audit string (or claims a verification)"
fi
# ⛔ A HEAD THE GATE CANNOT BIND IS NOT A REPORT DEFECT (fresh review, P2). `HEAD` comes from a swallowed
# API read, so one gh blip would otherwise be RELABELLED as a lane-report fault: exit 9 → FIX_REQUIRED,
# telling the lane to re-run suites, with no park — while the file's own arm for that state (park +
# exit 3) sits DOWNSTREAM of the gate. The gate must run only on a 40-hex head.
if grep -qE '^case "\$\{HEAD:-\}" in$' "$MERGE_ONE" && grep -qE '^  \*\) \[ "\$\{#HEAD\}" -eq 40 \] && _lrg_head_bindable=1 ;;$' "$MERGE_ONE" \
   && grep -qE '^if \[ "\$\{?_lrg_head_bindable\}?" = 1 \]; then$' "$MERGE_ONE"; then
  ok "merge-one.sh gates only on a bindable 40-HEX head (gh's own shape test; a transient failure parks, it is not a report fault)"
else
  bad "merge-one.sh gates on an empty/malformed head — a gh blip (or a 40-char non-sha) becomes a FIX_REQUIRED report fault"
fi

# ⛔ THE FALLBACK MUST FAIL CLOSED, NOT SELF-GRADE (fresh review, P2). When no trusted (main) checkout
# resolves, the only reachable copy of `tools/worktree_report.py` is the tree under review — so passing
# the lane checkout makes the gate PASS on a grader the graded tree supplied. The gate is SKIPPED there
# and `launch_chain` refuses immediately below. (No merge follows today; the danger is a future edit
# that softens that refusal.)
if grep -qE '^    _lrg_skip=1$' "$LANE_MERGE" && grep -qE 'no trusted \(main\) checkout to source the verifier from' "$LANE_MERGE"; then
  ok "lane-merge.sh SKIPS the gate (and lets launch_chain refuse) when no trusted checkout resolves — it never self-grades"
else
  bad "lane-merge.sh falls back to the lane checkout when no trusted checkout resolves — the graded tree would supply its own verifier"
fi

# The deployed set: a $O without the file makes every caller's `lane_report_gate` an unbound command.
if grep -q 'lane-report-gate.sh' "$INSTALL"; then
  ok "install.sh's maintained shipped-set list carries lane-report-gate.sh"
else
  bad "install.sh does not list lane-report-gate.sh — a \$O deployed without it breaks both carriers"
fi

# ── 9. A FUTURE-DATED MERGING HEAD IS A DIFFERENT FAULT (fresh review, P2) ─────────────────────
# When the head was committed on a box whose clock is AHEAD, every honest run here is older than it,
# so the laundering arm would refuse forever while printing a remedy (re-run) that cannot converge.
# The gate must NAME it, so the remedy can say "re-push / wait", not "re-run".
_future="$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'z\n' >> "$WT/f2" 2>/dev/null || printf 'z\n' > "$WT/f2"
git -C "$WT" add f2 2>/dev/null || true
GIT_COMMITTER_DATE="$_future" GIT_AUTHOR_DATE="$_future" git -C "$WT" commit -qm skewed 2>/dev/null || true
NEWH="$(git -C "$WT" rev-parse HEAD)"
printf '{"version":1,"head_at_write":"%s","branch":"feat/2977-tm","suites":[{"n":1,"command":"x","exit":0,"finished_at":"%s"}]}\n' "$NEWH" "$_now" > "$WT/.worktree-report/state.json"
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/2977-tm" "$NEWH" 2>&1)"; rc=$?
if [ "$rc" = 4 ] && grep -q 'reason=merging-head-is-dated-ahead-of-this-box' <<<"$out"; then
  ok "a future-dated merging head is STALE with its OWN reason (the re-run remedy cannot converge, so it is named)"
else
  bad "future-dated head: expected rc=4 + merging-head-is-dated-ahead-of-this-box, got rc=$rc :: $out"
fi
case "$(bash "$GATE" --remedy 4 2>&1)" in
  *'RE-RUNNING WILL NOT HELP'*) ok "the code-4 remedy tells the lane that re-running cannot clear a clock-skewed head" ;;
  *) bad "the code-4 remedy does not distinguish the clock-skew case" ;;
esac
git -C "$WT" reset --hard -q HEAD~1 2>/dev/null || true
rm -f "$WT/f2" "$WT/.worktree-report/state.json"

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1