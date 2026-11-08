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
#  3. POLARITY BY CONTENT, NOT BY EXIT CODE ALONE: rc 0 with `ok: false` is INVALID, and unparseable
#     output is UNMEASURABLE — an unreadable verification is never a pass.
#  4. THE TWO ABSTENTIONS ARE NOT GREEN and are distinguishable: a repo that ships no writer is
#     NO-CONSUMER (the gate cannot bind there), and a branch with no worktree on this box is
#     NO-WORKTREE. Collapsing either into 0 is how a gate reports coverage it does not have.
#  5. EXACT BRANCH MATCH: a worktree on `feat/297-tm` must never be verified for `feat/2977-tm` — a
#     prefix match would green-light a tree nobody is merging.
#  6. `head_at_write` IS READ FROM THE WRITER STATE, not from the consumer's `head` (which is the
#     worktree's CURRENT head): the STALE line must name two DIFFERENT shas, or it reads as a
#     contradiction and names nothing.
#  7. WIRING: both merge paths call the gate, and the shipped file is in install.sh's maintained list —
#     a gate that nothing calls, or a $O deployed without it, is the defect this issue is about.
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
mkdir -p "$HOME"

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
# A real repo with a real LINKED worktree, because the gate reads `git worktree list --porcelain`:
# a directory that merely looks like a worktree would make §5 pass for the wrong reason.
REPO="$TMP/repo"
mkdir -p "$REPO"; git -C "$REPO" init -q -b main
printf 'x\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
WT="$REPO/.worktrees/tm-2977"
git -C "$REPO" worktree add -q -b "feat/2977-tm" "$WT" main 2>/dev/null || bad "fixture: could not create the linked worktree"

# A DECOY worktree whose branch is a strict PREFIX of the real one (§5).
DECOY="$REPO/.worktrees/tm-297"
git -C "$REPO" worktree add -q -b "feat/297-tm" "$DECOY" main 2>/dev/null || bad "fixture: could not create the decoy worktree"

mkdir -p "$REPO/tools"
# The fixture consumer: emits the shape `worktree_report.py check --json` really emits, with the rc and
# the two fields the gate acts on taken from the environment.
cat > "$REPO/tools/worktree_report.py" <<'STUB'
import json, os, sys
if os.environ.get("STUB_RAW"):
    sys.stdout.write(os.environ["STUB_RAW"]); sys.exit(int(os.environ.get("STUB_RC", "0")))
rules = [r for r in os.environ.get("STUB_RULES", "").split(",") if r]
print(json.dumps({
    "ok": os.environ.get("STUB_OK", "1") == "1",
    "rules": rules,
    "suites": int(os.environ.get("STUB_SUITES", "2")),
    "failing_suites": int(os.environ.get("STUB_FAILING", "0")),
    "head": os.environ.get("STUB_HEAD", "livehead"),
    "head_moved_since_write": os.environ.get("STUB_STALE", "0") == "1",
}))
sys.exit(int(os.environ.get("STUB_RC", "0")))
STUB
printf '## Files changed\nx\n## Suites run\ny\n## Could not do\nz\n' > "$WT/WORKTREE-REPORT.md"

# drive <expected-rc> <name> [env…] — run the SHIPPED gate and assert only the exit code.
drive() {
  local want="$1" name="$2"; shift 2
  local out rc
  out="$(env "$@" bash "$GATE" --check "$REPO" "feat/2977-tm" "$(git -C "$WT" rev-parse HEAD)" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"; else bad "$name — expected rc=$want, got rc=$rc :: $out"; fi
  LAST_OUT="$out"
}

# ── 1. PASS ─────────────────────────────────────────────────────────────────────────────────────
drive 0 "PASS: valid evidence at the head being merged" STUB_OK=1 STUB_RC=0 STUB_STALE=0
case "$LAST_OUT" in *VERDICT=PASS*) ok "PASS is spelled VERDICT=PASS on the printed line" ;; *) bad "PASS line: $LAST_OUT" ;; esac

# ── 2. THE MEASURED DEFECT: rc 0 + a moved head is NOT a pass ────────────────────────────────────
mkdir -p "$WT/.worktree-report"
printf '{"version":1,"head_at_write":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","branch":"feat/2977-tm","suites":[]}\n' \
  > "$WT/.worktree-report/state.json"
drive 4 "STALE: the consumer exits 0 but the report was written at another head" STUB_OK=1 STUB_RC=0 STUB_STALE=1
# §6: both shas are named, and they DIFFER.
case "$LAST_OUT" in
  *report_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*merging_head=*) ok "STALE names the recorded head and the merging head" ;;
  *) bad "STALE message does not name both heads: $LAST_OUT" ;;
esac
case "$LAST_OUT" in
  *"report_head=$(git -C "$WT" rev-parse HEAD)"*) bad "STALE used the live head as 'report_head' (the consumer's \`head\`, not the writer state's \`head_at_write\`): $LAST_OUT" ;;
  *) ok "STALE does not mistake the live head for the report head" ;;
esac
rm -f "$WT/.worktree-report/state.json"

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
out="$(env STUB_OK=1 bash "$GATE" --check "$REPO" "feat/2977-tm" "$(git -C "$WT" rev-parse HEAD)" 2>&1)"; rc=$?
if [ "$rc" = 7 ]; then ok "UNMEASURABLE: report present but no consumer to verify it (rc=$rc)"; else bad "report-present-no-consumer: expected rc=7, got rc=$rc :: $out"; fi
mv "$TMP/stub.bak" "$REPO/tools/worktree_report.py"

# ── 5. EXACT BRANCH MATCH (the decoy must never be verified) ─────────────────────────────────────
# The DECOY has no report and its own branch; asking for a branch that only the decoy matches must be
# NO-WORKTREE, and the run must never touch the decoy. Then: give the DECOY a report and prove the
# gate still resolves the exact branch, not the prefix.
printf 'decoy\n' > "$DECOY/WORKTREE-REPORT.md"
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/297-tm" "$(git -C "$DECOY" rev-parse HEAD)" 2>&1)"; rc=$?
case "$out" in *"$DECOY"*) ok "the decoy worktree is selected for its OWN branch (control)" ;; *) bad "decoy control failed: $out" ;; esac
rm -f "$DECOY/WORKTREE-REPORT.md"
printf '## Files changed\n## Suites run\n## Could not do\n' > "$WT/WORKTREE-REPORT.md"
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/2977-tm" "$(git -C "$WT" rev-parse HEAD)" 2>&1)" || true
case "$out" in *worktree="$WT "*) ok "exact branch match resolves the 2977 worktree, never the 297 decoy prefix" ;; *) bad "exact-branch resolution: $out" ;; esac

# ── 6. NO-WORKTREE ─────────────────────────────────────────────────────────────────────────────——
# ⛔ NOT via `drive`: `drive` always asks for the branch that DOES have a worktree, which is the PASS
# arm. This one needs a branch no worktree is checked out on.
out="$(env STUB_OK=1 STUB_RC=0 bash "$GATE" --check "$REPO" "feat/nobody-tm" deadbeef 2>&1)"; rc=$?
if [ "$rc" = 6 ]; then ok "NO-WORKTREE: no worktree on this box for the branch (an abstention, not a pass) (rc=$rc)"; else bad "NO-WORKTREE: expected rc=6, got rc=$rc :: $out"; fi
case "$out" in *VERDICT=NO-WORKTREE*) ok "NO-WORKTREE is spelled on the line, so a census can count abstentions" ;; *) bad "NO-WORKTREE line: $out" ;; esac

# ── 7. USAGE ─────────────────────────────────────────────────────────────────────────────────────
out="$(bash "$GATE" 2>&1)"; rc=$?
[ "$rc" = 64 ] && case "$out" in *usage:*) ok "no arguments prints usage and exits 64" ;; *) bad "usage text missing" ;; esac || bad "usage exit code: expected 64, got rc=$rc"

# ── 8. WIRING — a gate nothing calls is the defect this issue is about ───────────────────────────
for f in "$LANE_MERGE" "$MERGE_ONE"; do
  n="$(basename "$f")"
  if grep -q 'lane-report-gate.sh' "$f" && grep -q 'lane_report_gate' "$f"; then
    ok "$n sources lane-report-gate.sh and calls lane_report_gate"
  else
    bad "$n does not consume the lane report (#2977): no source+call found"
  fi
done
# It must be called BEFORE the paid reviewer, or the refusal costs a review.
lm_first="$(grep -n 'lane_report_gate' "$LANE_MERGE" | head -1 | cut -d: -f1)"
lm_chain="$(grep -n 'launch_chain' "$LANE_MERGE" | tail -1 | cut -d: -f1)"
if [ -n "$lm_first" ] && [ -n "$lm_chain" ] && [ "$lm_first" -lt "$lm_chain" ]; then
  ok "lane-merge.sh gates the report BEFORE it launches the merge chain (no paid chain on a bad report)"
else
  bad "lane-merge.sh: lane_report_gate must run before launch_chain (call at ${lm_first:-none}, chain at ${lm_chain:-none})"
fi
co_first="$(grep -n 'lane_report_gate' "$MERGE_ONE" | head -1 | cut -d: -f1)"
# ⛔ THE ANCHOR IS THE RECORDER PROBE, not `run_agent`: `run_agent` also appears in its own DEFINITION
# (line ~502), so anchoring on it would pass whatever the call order actually is.
co_rev="$(grep -n 'RECORDER="\$HOME' "$MERGE_ONE" | head -1 | cut -d: -f1)"
if [ -n "$co_first" ] && [ -n "$co_rev" ] && [ "$co_first" -lt "$co_rev" ]; then
  ok "merge-one.sh gates the report BEFORE the paid review"
else
  bad "merge-one.sh: lane_report_gate must run before run_agent (call at ${co_first:-none}, review at ${co_rev:-none})"
fi
# The deployed set: a $O without the file makes every caller's `lane_report_gate` an unbound command.
if grep -q 'lane-report-gate.sh' "$INSTALL"; then
  ok "install.sh's maintained shipped-set list carries lane-report-gate.sh"
else
  bad "install.sh does not list lane-report-gate.sh — a \$O deployed without it breaks both carriers"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
