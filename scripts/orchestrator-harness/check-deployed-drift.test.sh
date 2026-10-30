#!/usr/bin/env bash
# check-deployed-drift.test.sh — the DELTA that `selftest.sh` does not grade: when the deployed copy
# differs, does the report NAME THE FILE, and does the check recover when the bytes come back?
#
# ── WHY THIS FILE EXISTS, AND WHY IT IS SMALL (agent-infra#2700) ────────────────────────────────
# `scripts/orchestrator-harness/selftest.sh` already drives the shipped `check-deployed-drift.sh` end
# to end — 24 assertions in that block, 15 of them carrying the `check-deployed-drift:` prefix (the
# other 9 grade `install.sh`'s stamp writer, its provenance fields, and a git-absent fallback). The
# prefixed 15 read: match→0, DIRTY source→1, re-record→0, post-install
# edit→1, MISSING record→2, `commit: UNKNOWN`→2, unresolvable ref→2, unknown commit object→2,
# BEHIND→1, fresh install→0, MISSING shipped file→1, an extra hand-placed script→1, a failed
# `mktemp`→2, an unreadable deployed `*.sh`→2, and an empty `$O` with a real record→1.
# **That is the capability's effect test and it is already in CI in both lanes.** ⛔ So this file does NOT re-implement it: a second implementation of a
# live shard is a duplicate, not coverage, and it would rot independently of the first.
#
# The two things `selftest.sh` does not assert, and which an operator needs:
#
#   1. **WHICH file differs.** Its post-install arm asserts the exit code (1) and nothing else; the
#      report's whole job at 3 a.m. is to name the file, and a count or a bare `DRIFT:` does not.
#   2. **That a one-byte difference is enough, and that restoring it clears the verdict.** Paired in
#      THIS file, with the SAME fixture one byte apart, the two arms are the suite's own non-vacuity
#      control: a check that cannot see a one-byte change would pass §1 and fail §2, and a check that
#      is permanently red would pass §2 and fail §1.
#
# Plus the self-registration arm every sibling carries (capacity-placement.test.sh §10): the epic's
# own failure class is "wired once, silently unwired later", and a suite that does not assert its own
# presence in the ONE shard list cannot notice.
#
# ⛔ NO `printf … | grep -q …` (SIGPIPE false negative, agent-infra #841/#864 — enforced by
# scripts/check-no-sigpipe-grep.sh). Here-strings throughout.
# Hermetic: a real local fixture repo, `--no-fetch`, no network, its own git identity (including
# `commit.gpgsign=false`, so an ambient global config cannot red the fixture — the hazard #2581 fixed
# elsewhere), and no `$HOME` dependence.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DRIFT="$HERE/check-deployed-drift.sh"
SHARDS="$ROOT/scripts/run-bash-shards.sh"
for f in "$DRIFT" "$SHARDS"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite grades the shipped file, so it cannot run"; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "❌ git not found — cannot build the fixture repo"; exit 2; }
# ⛔ THE FIXTURE MUST HASH THE WAY THE GRADED SCRIPT DOES. Measured on the pre-change fixture with
# `sha256sum` absent from PATH: the payload came out EMPTY (both the inner and the outer hash use the same
# missing binary, so nothing is emitted and `awk` still exits 0), and the grade after it was **UNKNOWN,
# rc 2 — "carries no payload hash"**, i.e. a failing §1. So the real failure mode is a confusing tool
# error, not a stampable false record (an earlier draft of this comment claimed the empty-input digest
# reached the stamp and surfaced as a hand edit — wrong, and corrected in review round 12). Resolving the
# command here, as `check-deployed-drift.sh` does, turns that confusion into one named line.
SHA_CMD="sha256sum"
command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"
command -v ${SHA_CMD%% *} >/dev/null 2>&1 || { echo "❌ neither sha256sum nor shasum is available — the fixture cannot write a truthful stamp"; exit 2; }

PASS=0; FAIL=0
ck() { if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
q()  { grep -q  -- "$1" <<<"${2:-}"; }
qF() { grep -qF -- "$1" <<<"${2:-}"; }   # ⛔ FIXED STRINGS for filenames: 'b.sh' as a REGEX
                                          # matches 'bash', which made a negative arm fail for the
                                          # wrong reason (measured in review round 1).
echo "==> check-deployed-drift delta self-test ($HERE)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deployed-drift.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; O="$TMP/O"
G="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false"
git init -q -b main "$REPO" >/dev/null 2>&1 || { echo "❌ git init failed"; exit 2; }
mkdir -p "$REPO/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho one\n' > "$REPO/scripts/orchestrator-harness/a.sh"
printf '#!/usr/bin/env bash\necho two\n' > "$REPO/scripts/orchestrator-harness/b.sh"
( cd "$REPO" && $G add -A && $G commit -q -m fixture ) >/dev/null 2>&1
HEAD1="$(git -C "$REPO" rev-parse HEAD)"
ck "fixture repo has a commit" "$([ -n "$HEAD1" ] && echo 0 || echo 1)"

# deploy — the deployed copy at $O is byte-identical to the ref's harness dir, with a truthful stamp.
deploy() {
  rm -rf "$O"; mkdir -p "$O"
  cp "$REPO/scripts/orchestrator-harness/a.sh" "$REPO/scripts/orchestrator-harness/b.sh" "$O/" || return 1
  local payload
  payload="$( ( cd "$O" && for f in *.sh; do $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
  printf '{\n "commit": "%s",\n "payloadSha256": "%s",\n "agentInfraDirty": false\n}\n' \
    "$HEAD1" "$payload" > "$O/.agent-infra-stamp.json"
}
run() { OUT="$(bash "$DRIFT" --o "$O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch 2>&1)"; RC=$?; }

deploy || { echo "❌ could not deploy the fixture copy"; exit 2; }

echo
echo "── §1 the deployed copy IS the ref: OK, rc 0 (the control half of the pair) ──"
run
ck "rc is 0" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "the verdict says OK and names the deployed dir" "$(q "OK: deployed $O" "$OUT" && echo 0 || echo 1)"

echo
echo "── §2 EXACTLY ONE BYTE differs: DRIFT (1), and the report NAMES that file ──"
# 'one' -> 'onf': the ONLY delta in the whole fixture is one byte of a.sh.
printf '#!/usr/bin/env bash\necho onf\n' > "$O/a.sh"
run
ck "rc is 1 (we compared, and it differs)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "the report NAMES a.sh — the file that differs, not a count" "$(qF 'a.sh — the deployed copy DIFFERS' "$OUT" && echo 0 || echo 1)"
ck "…and does not name the file that did NOT change (b.sh)" "$(qF 'b.sh — ' "$OUT" && echo 1 || echo 0)"
ck "…and is not reported as OK (a drift must never read as a match)" "$(q 'OK: deployed' "$OUT" && echo 1 || echo 0)"

echo
echo "── §3 restoring that ONE byte returns the verdict to OK (the check is not stuck red) ──"
deploy
run
ck "rc is 0 again" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
# ⛔ §1/§2/§3 are one fixture, one byte apart, with opposite verdicts — the non-vacuity control.

echo
echo "── §4 this suite is REGISTERED as a shard (the ONE list both CI lanes run) ──"
# ⛔ MEMBERSHIP IS READ FROM WHAT THE RUNNER EXECUTES, NOT FROM ITS TEXT (#2838). This check used to
# grep the runner's SOURCE for its own `run_shard` row — the text of a list that no longer exists:
# #2838 deleted the enumerated block, because every suite ran twice beside the derived loop and the
# runner's own `executed + skipped == listed` self-check could never hold. A text grep now fails on a
# suite that IS wired (a false red) and passes on a COMMENTED-OUT row that executes nothing, so it
# reads `--list` — the runner's own oracle, the same one `spawn-gate.test.sh` and both lanes use.
LIST="$(bash "$SHARDS" --list 2>/dev/null)"; rc=$?
ck "run-bash-shards.sh --list is READABLE (an unreadable list must not pass the membership check vacuously)" \
   "$([ "$rc" -eq 0 ] && [ -n "$LIST" ] && echo 0 || echo 1)"
grep -qxF 'scripts/orchestrator-harness/check-deployed-drift.test.sh' <<<"$LIST"
ck "run-bash-shards.sh EXECUTES this suite (--list), not merely names it in its text" $?

echo
printf 'check-deployed-drift delta self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
