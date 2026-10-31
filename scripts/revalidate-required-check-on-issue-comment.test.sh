#!/usr/bin/env bash
# revalidate-required-check-on-issue-comment.test.sh — the re-validation arm's own pins must run on
# EVERY PULL REQUEST, not only on an `issue_comment` event.
#
# ⛔ THE GAP THIS CLOSES (review of #3153, ISSUE 2 / P2). `scripts/revalidate-required-check-on-issue-
# comment.sh` carries its decisions as an embedded suite (`REVALIDATE_SELF_TEST=1 bash <script>`) whose
# only executor was the `revalidate-on-issue-comment` job in `.github/workflows/pipeline-compliance.yml`
# — a job gated on `github.event_name == 'issue_comment' && github.event.issue.pull_request == null`.
# The script is a `scripts/*.sh`, so it matched none of `scripts/run-bash-shards.sh`'s SUITE_GLOBS
# (`scripts/*.test.sh`, `scripts/*/*.test.sh`, …): no PR lane and no `main` matrix ever selected it.
# The decisions this file exists to own — the trust allow-list, the re-run polarity including the
# unknown-conclusion fail-closed rule, and the two-probe marker/retraction mapping — were therefore
# pinned by an assertion set that NO pull request could turn red, and a regression in the arm that
# re-reads this repo's only required check would merge green and be discovered only when a real
# comment landed after merge. That is the "a fixture nothing runs pins nothing" class (#1129) this
# very script's sibling comments cite.
#
# This suite IS discovered: its name matches `scripts/*.test.sh`, so it is in `--list` and in the
# `bash-suites` shard list on every run, with nothing edited in the runner to wire it. The
# `issue_comment` job keeps its own copy of the self-test as the live arm; this one is CI's.
#
# Hermetic: no network, no `gh`, no writes outside a mktemp dir. bash 3.2 (macOS) and bash 5 (cells).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SUBJECT="$HERE/revalidate-required-check-on-issue-comment.sh"
GATE="$HERE/check-pipeline-compliance.sh"

# ⛔ ASSERTION-COUNT PIN — the section-loss tripwire, the same shape `tests/review-pr/run.sh` uses. The
# self-test's arms are asserted wholesale below; without a floor, DELETING a whole arm leaves the
# remaining ones green and this suite still reports a pass. Raise it when the self-test grows.
N_FLOOR=31

[ -f "$SUBJECT" ] || { echo "no script at $SUBJECT" >&2; exit 1; }
[ -f "$GATE" ]     || { echo "no gate at $GATE — the delegated parser probe cannot be pinned" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }
# ck <0|1> <message>
ck() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/reval.XXXXXX")" || { echo "❌ cannot mktemp" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

run_self_test() { # <script> -> stdout+stderr in $T/out, rc in $RC
  # From the repo root: the script's DEFAULT gate probe is the repo-relative
  # `scripts/check-pipeline-compliance.sh`, exactly as the workflow invokes it. GATE_SCRIPT is passed
  # explicitly so a MUTANT copy (which lives in $T, not in scripts/) still reaches the real gate and
  # the only difference measured is the mutation itself.
  ( cd "$ROOT" && GATE_SCRIPT="$GATE" REVALIDATE_SELF_TEST=1 bash "$1" ) >"$T/out" 2>&1
  RC=$?
}

echo "(1) the self-test runs at all, and its full assertion population is present"
run_self_test "$SUBJECT"
ck $([ "$RC" -eq 0 ] && echo 0 || echo 1) "REVALIDATE_SELF_TEST=1 exits 0 (rc=$RC)"
N="$(sed -n 's/.*REVALIDATE SELF-TEST: \([0-9][0-9]*\) assertions passed.*/\1/p' "$T/out" | tail -1)"
if [ -n "$N" ]; then
  ok "the suite reports its own assertion count ($N)"
else
  bad "no 'REVALIDATE SELF-TEST: <n> assertions passed' line — a self-test that runs nothing reads green. Output: $(tr '\n' ' ' < "$T/out" | cut -c1-200)"
fi
ck $([ -n "$N" ] && [ "$N" -ge "$N_FLOOR" ] && echo 0 || echo 1) \
   "assertion-count pin: >= $N_FLOOR assertions executed (measured ${N:-0}; section loss tripwire)"

echo "(2) MUTATION — an admit-anyone trust check must be REFUSED by the suite"
# The one decision with `actions: write` reachable from it: a stranger's comment must never dispatch a
# re-run of the required check. If the allow-list widens to everyone and this suite stays green, the
# pin does not exist.
MUT="$T/admit-all.sh"
sed "s/^    OWNER|MEMBER|COLLABORATOR) return 0 ;;/    *) return 0 ;;/" "$SUBJECT" > "$MUT"
ck $(grep -q '^    \*) return 0 ;;' "$MUT" && echo 0 || echo 1) "the mutation applied (trust allow-list widened)"
run_self_test "$MUT"
ck $([ "$RC" -ne 0 ] && echo 0 || echo 1) "...a widened allow-list makes the suite FAIL (rc=$RC)"
ck $(grep -q "trusted_association admitted" "$T/out" && echo 0 || echo 1) \
   "...and it NAMES the widened arm (the assertion that caught it)"

echo "(3) MUTATION — an unknown conclusion falling through as non-red must be REFUSED"
# The merge rail's own polarity allow-list: a conclusion nobody named must never be treated as green.
# This exact class shipped inverted once, which is why the arm exists.
MUT2="$T/unknown-non-red.sh"
sed "s/^    \*) printf 'rerun' ;;/    *) printf 'skip:already-non-red' ;;/" "$SUBJECT" > "$MUT2"
ck $(grep -q "^    \*) printf 'skip:already-non-red' ;;" "$MUT2" && echo 0 || echo 1) "the mutation applied (unknown conclusion now reads non-red)"
run_self_test "$MUT2"
ck $([ "$RC" -ne 0 ] && echo 0 || echo 1) "...an unknown conclusion read as non-red makes the suite FAIL (rc=$RC)"

echo "(4) MUTATION — a deleted retraction force must be REFUSED"
# A retraction's newest run is GREEN by construction, so a polarity that only re-runs reds turns the
# retraction arm into a log line: the stale green stands. Pin the force.
MUT3="$T/no-force.sh"
# The ONLY producer of the retraction decision is the `printf 'rerun:retracted'` inside `rerun_decision`;
# the two other mentions are the caller's case arm and the assertion itself, so the mutation targets that
# exact source line — with awk, whose line comparison is identical on BSD and GNU. (A `sed` `/c\` rewrite
# is NOT: it emitted "extra characters after \ at the end of c command", applied no mutation, and this
# very arm then reported GREEN over an unmutated script — the vacuous-pin class this suite exists for.)
MUT3="$T/no-force.sh"
TARGET_LINE="        printf 'rerun:retracted'"
REPL_LINE="        printf 'skip:already-non-red'"
awk -v t="$TARGET_LINE" -v r="$REPL_LINE" '$0 == t { print r; next } { print }' "$SUBJECT" > "$MUT3"
ck $(grep -qxF "$TARGET_LINE" "$SUBJECT" && ! grep -qxF "$TARGET_LINE" "$MUT3" && echo 0 || echo 1) \
   "the mutation applied (retraction no longer forces a re-run)"
run_self_test "$MUT3"
ck $([ "$RC" -ne 0 ] && echo 0 || echo 1) "...a retraction that cannot force makes the suite FAIL (rc=$RC)"

echo "(5) the suite is DISCOVERED by the shard runner (a fixture nothing runs pins nothing)"
LIST="$( cd "$ROOT" && bash scripts/run-bash-shards.sh --list 2>/dev/null )"
LRC=$?
ck $([ "$LRC" -eq 0 ] && echo 0 || echo 1) "run-bash-shards.sh --list exits 0 (rc=$LRC)"
REL="${BASH_SOURCE[0]#"$ROOT"/}"; REL="${REL#./}"
# ⛔ NO PIPE INTO A QUIET GREP (#841/#864): the producer is a builtin, so it inverts to a
# here-string — under `pipefail` a `grep -q` that exits at the first match leaves the writer with
# SIGPIPE, and the whole `ck` reads 1 on a LIST that DOES contain the path.
ck $(grep -qxF "$REL" <<<"$LIST" && echo 0 || echo 1) \
   "...and '‑‑list' CONTAINS '$REL' — this suite runs on the PR lane, not only on issue_comment"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "revalidate-required-check-on-issue-comment: OK — $PASS assertion(s), all passed"
  exit 0
fi
echo "revalidate-required-check-on-issue-comment: $FAIL assertion(s) FAILED (of $((PASS + FAIL)))"
exit 1
