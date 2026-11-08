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
#     output is UNMEASURABLE — an unreadable verification is never a pass.
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
command -v python3 >/dev/null 2>&1 || { echo "SKIP lane-report-gate.test.sh — no python3 (the consumer is python)"; exit 0; }

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
# ⛔ THE STATE MUST GO BEFORE THE NEXT ARM, or `rec_head` (which is checked first) answers for it and the
# worktree-direction row below silently grades the wrong rule — measured: it reported
# `reason=report-bound-to-another-head` while claiming to test the worktree.
rm -f "$WT/.worktree-report/state.json"
# The direction `head_moved_since_write` CANNOT see: the worktree is behind the branch because something
# else pushed. The consumer reports its own worktree head, so `live_head != $head` is the only witness.
out="$(env STUB_OK=1 STUB_RC=0 STUB_STALE=0 STUB_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bash "$GATE" --check "$REPO" "feat/2977-tm" "$WT_HEAD" 2>&1)"; rc=$?
if [ "$rc" = 4 ]; then ok "STALE: the WORKTREE is not at the head being merged (the shift no writer can see) (rc=$rc)"; else bad "worktree-behind: expected rc=4, got rc=$rc :: $out"; fi
case "$out" in *reason=worktree-is-not-at-the-merging-head*) ok "…and it names that reason, not the writer's flag" ;; *) bad "worktree-behind reason: $out" ;; esac

# ── 3. RED and INVALID, and polarity by CONTENT ──────────────────────────────────────────────────
drive 3 "RED: valid evidence that records a failing suite (consumer exit 3)" STUB_OK=0 STUB_RC=3 STUB_FAILING=1
drive 2 "INVALID: the consumer's rules fail and it exits 1" STUB_OK=0 STUB_RC=1 STUB_RULES=suite-log-hash-mismatch:unit
case "$LAST_OUT" in *suite-log-hash-mismatch*) ok "INVALID names the failing rule the consumer reported" ;; *) bad "INVALID does not name the rule: $LAST_OUT" ;; esac
drive 2 "POLARITY: exit 0 with ok:false is INVALID, not PASS" STUB_OK=0 STUB_RC=0
drive 7 "UNMEASURABLE: the consumer's output is not JSON" STUB_RAW=not-json STUB_RC=0

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
# The refusal must not park: a park is HEAD-keyed and the remedy is a re-run at the SAME head.
if grep -qE '^[[:space:]]*exit 9 ;;\|^[[:space:]]*exit 9$' "$MERGE_ONE" && ! sed -n "$((co_call))p" "$MERGE_ONE" >/dev/null; then bad "merge-one.sh: the report refusal is not reachable"; fi
if sed -n "$((co_call)),$((co_call+8))p" "$MERGE_ONE" | grep -q 'park '; then
  bad "merge-one.sh PARKS on a report refusal — a HEAD-keyed park deadlocks the re-run that is the remedy"
else
  ok "merge-one.sh does not park on a report refusal (the remedy is a re-run at the same head)"
fi
# The deployed set: a $O without the file makes every caller's `lane_report_gate` an unbound command.
if grep -q 'lane-report-gate.sh' "$INSTALL"; then
  ok "install.sh's maintained shipped-set list carries lane-report-gate.sh"
else
  bad "install.sh does not list lane-report-gate.sh — a \$O deployed without it breaks both carriers"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
