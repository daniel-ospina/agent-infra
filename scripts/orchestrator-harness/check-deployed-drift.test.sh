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
# ⛔ THE REMEDY MUST NOT BE A LIE. This branch used to print `write --o $O --src <checkout>`, which on
# THIS case (the box differs from its record) mints a record describing the changed bytes under the
# checkout's commit — silencing the alarm and arming the next deploy to overwrite the edit.
ck "…and the remedy does not mint a record from the CHANGED bytes" "$(qF 'write --o' "$OUT" && echo 1 || echo 0)"

echo
echo "── §3 restoring that ONE byte returns the verdict to OK (the check is not stuck red) ──"
deploy
run
ck "rc is 0 again" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
# ⛔ §1/§2/§3 are one fixture, one byte apart, with opposite verdicts — the non-vacuity control.

echo
echo "── §5 THE PROVENANCE RECORD: the deploy writes it, and the check reads it as question (a) ──"
# The record is `$O/.harness-provenance` — commit + one sha256 per file the deploy wrote. Written here
# by the SHIPPED writer (harness-provenance.sh), never by a fixture that re-implements the format, so
# producer and reader are graded against each other.
PROVW="$HERE/harness-provenance.sh"
SRCDIR="$REPO/scripts/orchestrator-harness"
ck "the shipped writer is present" "$([ -s "$PROVW" ] && echo 0 || echo 1)"
deploy                                       # stamp only, as before
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1
ck "the writer recorded $O/.harness-provenance" "$([ -s "$O/.harness-provenance" ] && echo 0 || echo 1)"
run
ck "rc is 0 (the record and the bytes agree)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the verdict NAMES which record answered" "$(qF ".harness-provenance" "$OUT" && echo 0 || echo 1)"

echo
echo "── §5b a SURFACE-only hit is labelled harness=surface, NOT payload-differs ──"
# `$O` answers BOTH questions cleanly here; a DIFFERENT harness dir this box carries is what differs.
# The token must name the question that actually failed: `payload-differs` is a statement about $O's
# bytes, and README's remedy for it ("redeploy to adopt") cannot clear a hit in another directory —
# the same conflation between question (a)/(b)/"another box dir" this change exists to remove.
EXTRA="$TMP/extra-orch"; rm -rf "$EXTRA"; mkdir -p "$EXTRA" "$TMP/emptyhome"
cp "$SRCDIR/a.sh" "$SRCDIR/b.sh" "$EXTRA/"
printf '#!/usr/bin/env bash\necho hand-placed\n' > "$EXTRA/c.sh"     # exists only there
printf '#!/bin/sh\nexit 0\n' > "$TMP/ps-stub"; chmod +x "$TMP/ps-stub"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome" CELL_HOME="" HARNESS="$EXTRA" HARNESS_PIN_DIR="" \
        HARNESS_PIN_FILE="" DRIFT_PS="$TMP/ps-stub" \
        bash "$DRIFT" --o "$O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "rc is 1 — a harness dir this box carries differs" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…the surface hit NAMES the hand-placed script" "$(qF "hand-placed" "$OUT" && echo 0 || echo 1)"
ck "the one-line answer is harness=surface" "$(qF "harness=surface" "$OUT" && echo 0 || echo 1)"
ck "…and NOT harness=payload-differs (which would be a false claim about \$O)" \
   "$(qF "harness=payload-differs" "$OUT" && echo 1 || echo 0)"
ck "…and \$O itself still answers (a) cleanly in the same run" "$(qF "identity: ok" "$OUT" && echo 0 || echo 1)"

echo
echo "── §5c a MISSING record entry is INCOMPLETE, not an uncommitted edit ──"
# The record names a file $O no longer has. Nothing at $O differs from the record — there is nothing
# there — so "an UNCOMMITTED EDIT … RECOVER the edit before redeploying: a deploy OVERWRITES it" sends an
# operator to recover a patch that does not exist, and contradicts the writer's own answer for the same
# bytes ("a redeploy CREATES it … not a refusal"). It is still a defect, so it still fails the run.
deploy
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1
rm -f "$O/b.sh"
run
ck "rc is 1 (the deployed tree is incomplete)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…the report says the file is MISSING" "$(qF "b.sh — the record says the deploy wrote it" "$OUT" && echo 0 || echo 1)"
ck "the token is harness=incomplete:b.sh" "$(qF "harness=incomplete:b.sh" "$OUT" && echo 0 || echo 1)"
ck "…and NOT harness=uncommitted-edit (nothing was edited)" "$(qF "harness=uncommitted-edit" "$OUT" && echo 1 || echo 0)"
ck "…and it does not tell the operator to RECOVER an edit" "$(qF "RECOVER the edit" "$OUT" && echo 1 || echo 0)"
ck "…and it says a redeploy CREATES the file" "$(qF "CREATES it" "$OUT" && echo 0 || echo 1)"
# Restore the fixture: §6's negative control is "b.sh did not change", which is meaningless about a
# file that is no longer there — and a leaked fixture is how a later arm fails for the wrong reason.
cp "$SRCDIR/b.sh" "$O/b.sh"
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1

echo
echo "── §6 an UNCOMMITTED EDIT in \$O: exit 1, the FILE is named, and which side is newer ──"
# This is the shape that silently reverted a live fix on 2026-10-28: bytes in $O that no deploy wrote.
# ⛔ THE RECORD IS BACKDATED so "which side is newer" is DECIDABLE on any filesystem: a one-second
# mtime resolution (measured on APFS under $TMPDIR) puts an edit and its record in the SAME second,
# where `-nt` is false and the honest answer is "cannot order them" — which is a different arm.
touch -t 202001010000 "$O/.harness-provenance"
printf '#!/usr/bin/env bash\necho onf\n' > "$O/a.sh"     # one byte, after the record
run
ck "rc is 1" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "the report names a.sh as an UNCOMMITTED EDIT" "$(qF "a.sh — UNCOMMITTED EDIT" "$OUT" && echo 0 || echo 1)"
ck "…and says WHICH SIDE is newer (edited after the record)" "$(qF "edited AFTER the record" "$OUT" && echo 0 || echo 1)"
ck "…and does not name the file that did not change (b.sh)" "$(qF "b.sh — " "$OUT" && echo 1 || echo 0)"
ck "the one-line answer is harness=uncommitted-edit:a.sh" "$(qF "harness=uncommitted-edit:a.sh" "$OUT" && echo 0 || echo 1)"
ck "…and it is NOT reported as a plain checkout difference (one defect, one line)" \
   "$(qF "DRIFT(checkout): a.sh" "$OUT" && echo 1 || echo 0)"

echo
echo "── §7 NO RECORD AT ALL: UNKNOWN (2), never clean ──"
rm -f "$O/.harness-provenance" "$O/.agent-infra-stamp.json"
run
ck "rc is 2 (cannot verify — never a pass)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and it says the box has no answer for which commit it runs" "$(q "UNKNOWN" "$OUT" && echo 0 || echo 1)"
ck "…and it does not print OK" "$(q "OK: deployed" "$OUT" && echo 1 || echo 0)"
# ⛔ THE ARM MUST TELL THE TWO DOWNSTREAM PATHS APART. Measured: with the missing-record diagnosis
# reverted to a `note`, this section stayed GREEN — because `rc is 2` and the word `UNKNOWN` are also
# produced one line later by "the record names no harness commit", so the assertions above cannot see
# which of the two fired. The state the operator is told differs: NO RECORD means "record this box"
# (the deploy writes one), an UNPARSEABLE identity means "the record you have is damaged". Assert the
# DIAGNOSIS, not the exit code only.
ck "…and the report names the state as NO RECORD (not a record with a bad commit)" \
   "$(qF "no harness record at" "$OUT" && echo 0 || echo 1)"

echo
echo "── §8 BEHIND is a DIFFERENT state from an uncommitted edit, and says so ──"
# A box deliberately behind a known commit is a known state; it must not read as the hand-edit class.
deploy
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1      # record at HEAD1
printf '#!/usr/bin/env bash\necho b2\n' > "$SRCDIR/b.sh"
( cd "$REPO" && $G add -A && $G commit -q -m advance ) >/dev/null 2>&1
HEAD2="$(git -C "$REPO" rev-parse HEAD)"
ck "the fixture repo advanced to a new tip" "$([ "$HEAD1" != "$HEAD2" ] && echo 0 || echo 1)"
run
ck "rc is 1 (behind is drift)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…the report says BEHIND" "$(q "BEHIND" "$OUT" && echo 0 || echo 1)"
ck "…and the token distinguishes it from a hand edit" "$(qF "harness=behind:${HEAD1:0:12}" "$OUT" && echo 0 || echo 1)"
ck "…and no file is called an uncommitted edit (the record still describes \$O)" "$(qF "UNCOMMITTED EDIT" "$OUT" && echo 1 || echo 0)"

echo
echo "── §8b a record that PREDATES the bytes is UNRECORDED, not a hand edit (the phase-A state) ──"
# `deploy-mac-orchestrator.sh PHASE=A` writes $O and, BY DESIGN, writes no record. So a routine partial
# deploy leaves bytes newer than the record with nobody having edited anything — and this reader used to
# call that "an UNCOMMITTED EDIT … RECOVER the edit before redeploying", a remedy for a patch that does
# not exist. Bytes that equal the REF's blob are a deploy the record has not caught up with.
# The record from §8 describes HEAD1's bytes. A "phase A" deploy then lands HEAD2's b.sh WITHOUT
# re-recording (that is what phase A does), so $O/b.sh == the ref's bytes and the record predates them.
cp "$SRCDIR/b.sh" "$O/b.sh"
run
ck "rc is 1 (the record is stale, and that is drift)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…the report says STALE-RECORD, not an uncommitted edit" "$(qF "STALE-RECORD b.sh" "$OUT" && echo 0 || echo 1)"
ck "…and does NOT claim an UNCOMMITTED EDIT (nothing was edited)" "$(qF "UNCOMMITTED EDIT" "$OUT" && echo 1 || echo 0)"
ck "…and it does NOT tell the operator to recover a patch" "$(qF "RECOVER the edit" "$OUT" && echo 1 || echo 0)"
ck "…and the record's own commit IS reported as behind (that part is true)" \
   "$(qF "harness=behind:${HEAD1:0:12}" "$OUT" && echo 0 || echo 1)"
ck "…and it says nothing you wrote is discarded" "$(qF "Nothing you wrote is discarded" "$OUT" && echo 0 || echo 1)"

echo
echo "── §8c a source path with TWO SPACES still round-trips through BOTH readers ──"
# The reader's manifest-line discriminator was "contains two spaces", and the record's own
# `source=<checkout path>` line carries the checkout path — so a path with two consecutive spaces was
# read as a manifest entry (this reader invented a MISSING file; the writer's `check` refused the whole
# record). One record, two readers, both wrong.
ODDROOT="$TMP/odd  repo"; mkdir -p "$ODDROOT/repo/scripts/orchestrator-harness"
cp "$REPO/scripts/orchestrator-harness/a.sh" "$REPO/scripts/orchestrator-harness/b.sh" \
   "$ODDROOT/repo/scripts/orchestrator-harness/"
( cd "$ODDROOT/repo" && $G init -q -b main . && $G add -A && $G commit -q -m odd ) >/dev/null 2>&1
ODDO="$TMP/odd-o"; mkdir -p "$ODDO"
cp "$ODDROOT/repo/scripts/orchestrator-harness"/*.sh "$ODDO/"
bash "$PROVW" write --o "$ODDO" --src "$ODDROOT/repo/scripts/orchestrator-harness" >/dev/null 2>&1
OUT="$(bash "$DRIFT" --o "$ODDO" --repo "$ODDROOT/repo" --ref main --rel scripts/orchestrator-harness --no-fetch 2>&1)"; RC=$?
ck "a record whose source path has TWO SPACES is read cleanly (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and no file is invented from the header (no MISSING, no incomplete token)" \
   "$(qF "MISSING" "$OUT" && echo 1 || echo 0)"


echo
echo "── §9 the provenance record SUPERSEDES the legacy stamp (no stale-stamp false alarm) ──"
# A stamp left stale by a redeploy that recorded its own provenance must not be the top-severity
# "post-install hand edit" alarm — the better record is what answers.
deploy                                       # the bytes at the NEW tip land in $O first…
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1      # …then the record describes them
printf '{"commit": "%s", "payloadSha256": "deadbeefdeadbeef", "agentInfraDirty": false}\n' "$HEAD1" > "$O/.agent-infra-stamp.json"
run
ck "rc is 0 — the stale legacy stamp is not a hand-edit alarm when a manifest describes the bytes" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and no hand edit is claimed" "$(qF "UNCOMMITTED EDIT" "$OUT" && echo 1 || echo 0)"

echo
echo "── §9b a PROVENANCE record whose source was DIRTY is an IDENTITY problem (not only the stamp) ──"
# ⛔ THIS ARM IS WHY THE PRECEDING FIX IS REAL. The record carries `sourceDirty`; the reader takes
# `prov_field` with ONE argument (the key) — an earlier cycle passed the record path first, so the sed
# pattern became `s/^<path>=//p`, matched nothing, and the arm was DEAD CODE: a record deployed from a
# dirty checkout read as a clean identity, masking the one signal the legacy stamp had carried. A green
# suite hid it because NO arm graded this path.
cp "$SRCDIR/a.sh" "$TMP/a.sh.committed"
printf '#!/usr/bin/env bash\necho one-WITH-A-LOCAL-FIX\n' > "$SRCDIR/a.sh"      # the source is now dirty
deploy
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1
run
ck "the record says sourceDirty=true" "$(qF "sourceDirty=true" "$(cat "$O/.harness-provenance" 2>/dev/null)" && echo 0 || echo 1)"
ck "rc is 1 (a commit name that does not describe these bytes is drift)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…and the report says the record's source was DIRTY" "$(qF "source was DIRTY" "$OUT" && echo 0 || echo 1)"
ck "…and it does NOT read the identity as ok" "$(qF "identity: ok" "$OUT" && echo 1 || echo 0)"
cp "$TMP/a.sh.committed" "$SRCDIR/a.sh"                                        # leave the fixture clean again
deploy
bash "$PROVW" write --o "$O" --src "$SRCDIR" >/dev/null 2>&1
run
ck "…and a CLEAN source reads clean again (the arm is not stuck red)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

echo
echo "── §9c the STAMP path's dirty-source arm still fires (it must not crash the run) ──"
# `selftest.sh` grades this shape ("a DIRTY source record is drift, not a pass") and it is the arm a
# repair of the record path is most likely to break — measured: an unbound `$D` in the identity line
# aborted the whole run with rc 1 and NO report, so the shard failed while the local suites were green.
deploy
N_PAY="$( ( cd "$O" && for f in *.sh; do $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
printf '{\n "commit": "%s",\n "payloadSha256": "%s",\n "agentInfraDirty": true\n}\n' "$HEAD1" "$N_PAY" > "$O/.agent-infra-stamp.json"
OUT="$(bash "$DRIFT" --o "$O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch 2>&1)"; RC=$?
ck "a dirty-source STAMP is drift (rc 1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…and the DIRTY line is PRINTED (the run does not abort on it)" "$(qF "DIRTY" "$OUT" && echo 0 || echo 1)"
ck "…and the run still produces its one-line summary" "$(qF "harness=" "$OUT" && echo 0 || echo 1)"
ck "…and no shell error leaked into the report" "$(qF "unbound variable" "$OUT" && echo 1 || echo 0)"

echo
echo "── §4 this suite is REGISTERED as a shard (the ONE list both CI lanes run) ──"
ck "run-bash-shards.sh carries this suite as a run_shard line" \
   "$(q 'run_shard scripts/orchestrator-harness/check-deployed-drift.test.sh' "$(cat "$SHARDS")" && echo 0 || echo 1)"

echo
printf 'check-deployed-drift delta self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
