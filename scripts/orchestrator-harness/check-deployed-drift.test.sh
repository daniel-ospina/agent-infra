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
# ⛔ A PYTHON DRIVER IS PART OF THE FIXTURE FROM THE START (agent-infra#4015). The byte arm compared
# `*.sh` only, so the fixture could not express the population that actually failed on the fleet: a
# `.py` driver behind every one of the three outages was never compared. §12 grades it.
printf '#!/usr/bin/env python3\nprint("driver v1")\n' > "$REPO/scripts/orchestrator-harness/driver.py"
( cd "$REPO" && $G add -A && $G commit -q -m fixture ) >/dev/null 2>&1
HEAD1="$(git -C "$REPO" rev-parse HEAD)"
ck "fixture repo has a commit" "$([ -n "$HEAD1" ] && echo 0 || echo 1)"

# deploy — the deployed copy at $O is byte-identical to the ref's harness dir, with a truthful stamp.
# ⛔ THE COPY SET IS THE CHECK'S OWN DECLARED SURFACE (`*.sh|*.py|*.mjs`), not a hand-written list:
# a fixture that copies a narrower set than the check compares would red every arm with a MISSING
# file and grade nothing. (The STAMP's fold stays `*.sh` on purpose — that is the writers' contract,
# and §12 relies on it: a `.py` edit must be caught by the BYTE arm, not by the digest.)
deploy() {
  rm -rf "$O"; mkdir -p "$O"
  local f
  for f in "$REPO"/scripts/orchestrator-harness/*; do
    case "${f##*/}" in *.sh|*.py|*.mjs) cp "$f" "$O/" || return 1 ;; esac
  done
  local payload
  payload="$( ( cd "$O" && for f in *.sh; do $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
  # ⛔ THE STAMP NAMES THE TIP *NOW*, not the first commit: §8 advances the fixture, and every arm
  # after it that expects a CURRENT box was silently grading a BEHIND one through a stale `commit`.
  printf '{\n "commit": "%s",\n "payloadSha256": "%s",\n "agentInfraDirty": false\n}\n' \
    "$(git -C "$REPO" rev-parse HEAD)" "$payload" > "$O/.agent-infra-stamp.json"
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
# cp_ship <dir> — populate a candidate copy with the fixture's SHIPPED SET, i.e. the same
# declared extensions the check compares (#4015). The arms below copy a fixture that must be
# CLEAN except for the one difference they plant; a copy narrower than the compared set would make
# each of them drift for a MISSING `.py` instead of grading its own subject.
cp_ship() { local f d="${1%/}"; for f in "$SRCDIR"/*; do case "${f##*/}" in *.sh|*.py|*.mjs) cp "$f" "$d/" ;; esac; done; }
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
cp_ship "$EXTRA/"
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
# ⛔ THE SUMMARY MUST NOT CONTRADICT THE LINE ABOVE IT (measured 2026-10-30, review of #3053). The record's
# commit IS the ref tip here, so `Q_IDENT=1` with `RELATION=current` fell through to `payload-differs` —
# a token README §4.3 defines as "the bytes differ from the checkout but the record STILL DESCRIBES $O",
# the one thing a `sourceDirty=true` record does not do — and then printed "the box is recorded from
# <sha> — current main … a known state, not a defect" directly beneath "does not describe the deployed
# bytes". Both arms below redden if the fall-through or the routine-state sentence comes back.
ck "…the token is harness=source-dirty:<sha12>" "$(qF "harness=source-dirty:" "$OUT" && echo 0 || echo 1)"
ck "…and NOT payload-differs (which claims the record describes \$O)" \
   "$(qF "harness=payload-differs" "$OUT" && echo 1 || echo 0)"
ck "…and it does NOT print the routine-state sentence under a DIRTY record" \
   "$(qF "known state, not a defect" "$OUT" && echo 1 || echo 0)"
ck "…it says the box was never identifiable, and how to make it so" \
   "$(qF "never identifiable" "$OUT" && echo 0 || echo 1)"
# ⛔ A DIRTY RECORD **AND** A MISSING FILE ARE TWO FACTS, and the token must carry the actionable one
# (review of #3090). The absent shipped script is what README gives its own row and remedy ("a redeploy
# CREATES it"); `source-dirty` says the record cannot describe the box, which is true but is not what
# breaks the runtime. Measured: with the DIRTY arm placed FIRST this state reported
# `harness=source-dirty:<sha>` and the `incomplete:` signal disappeared from the token.
rm -f "$O/b.sh"
run
ck "…a DIRTY record with a MISSING file still says harness=incomplete:b.sh" \
   "$(qF "harness=incomplete:b.sh" "$OUT" && echo 0 || echo 1)"
ck "…and NOT source-dirty (the absent script is the runtime signal)" \
   "$(qF "harness=source-dirty" "$OUT" && echo 1 || echo 0)"
ck "…while still naming the DIRTY source in the body" "$(qF "source was DIRTY" "$OUT" && echo 0 || echo 1)"
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
echo "── §9d the MAC deploy's record shape is NOT an identity failure (sourceDirty=false, source= live) ──"
# ⛔ THE BOX CLASS THE RECORD EXISTS FOR. `deploy-mac-orchestrator.sh` stages `git archive` into a
# throwaway dir and (before this arm) recorded `sourceDirty=unknown` — which THIS reader REFUSES — plus a
# `source=` pointing at the `$STAGE` it deletes. A record is PREFERRED over install.sh's stamp, so the box
# lost the attribution it already had: attributable before, UNKNOWN after. The deploy now states both.
MACLIVE="$TMP/mac-live/scripts/orchestrator-harness"; rm -rf "$TMP/mac-live"; mkdir -p "$MACLIVE"
MACSTAGE="$TMP/mac-stage"; rm -rf "$MACSTAGE"; mkdir -p "$MACSTAGE"
cp_ship "$MACLIVE"/
cp_ship "$MACSTAGE"/
deploy
# The suite advances $REPO (§8), so the tip is read NOW — a record naming $HEAD1 here would be a
# deliberately-BEHIND box, and this arm is about the record's SHAPE, not about being behind.
TIP_NOW="$(git -C "$REPO" rev-parse HEAD)"
bash "$PROVW" write --o "$O" --src "$MACSTAGE" --commit "$TIP_NOW" --ref main --repo "$REPO" \
  --source-dirty false --origin "$MACLIVE" >/dev/null 2>&1
grep -qF "sourceDirty=false" "$O/.harness-provenance" || echo "    (record did not carry sourceDirty=false)"
run
ck "rc is 0 — a staged mac record answers (a) instead of UNKNOWN" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the run does NOT claim the record cannot say whether its source was clean" \
   "$(qF "does not say whether its source was clean" "$OUT" && echo 1 || echo 0)"
ck "…and the provenance record is still what answered" "$(qF ".harness-provenance" "$OUT" && echo 0 || echo 1)"
# ⛔ THE POLARITY — this is the P1 REPRODUCED, and it must stay refuse-don't-guess: the SAME staged
# record without the deploy's statement still carries sourceDirty=unknown, and this reader still answers
# UNKNOWN (2). The flag is what makes the box attributable; its absence must never default to "clean".
bash "$PROVW" write --o "$O" --src "$MACSTAGE" --commit "$TIP_NOW" --ref main --repo "$REPO" >/dev/null 2>&1
run
ck "without --source-dirty the same staged record is still UNKNOWN (2) — never assumed clean" \
   "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and the reason names sourceDirty, so an operator knows what the deploy must state" \
   "$(qF "does not say whether its source was clean" "$OUT" && echo 0 || echo 1)"

echo
echo "── §9e --surface still answers when the provenance record is UNREADABLE and a stamp exists ──"
# The block that resolves the record says a missing/unreadable record is NOT a reason to skip the surface
# pass; an unconditional block below it then DISCARDED that fallback and exited 2 — so the surface pass
# never ran on the exact population it was written for (a box whose record is unusable).
deploy
extra_surface_fixture="$TMP/extra3"; rm -rf "$extra_surface_fixture"; mkdir -p "$extra_surface_fixture"
cp_ship "$extra_surface_fixture"/
printf '#!/usr/bin/env bash\necho hand-placed\n' > "$extra_surface_fixture/c.sh"
bash "$PROVW" write --o "$O" --src "$SRCDIR" --commit "$(git -C "$REPO" rev-parse HEAD)" --ref main --repo "$REPO" >/dev/null 2>&1
chmod 000 "$O/.harness-provenance" 2>/dev/null || true
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome" CELL_HOME="" HARNESS="$extra_surface_fixture" HARNESS_PIN_DIR="" \
        HARNESS_PIN_FILE="" DRIFT_PS="$TMP/ps-stub" \
        bash "$DRIFT" --o "$O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
chmod 644 "$O/.harness-provenance" 2>/dev/null || true
ck "the surface pass ANSWERED (rc 1 — the extra dir differs), it did not exit 2 on the record" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…and the surface pass actually RAN and named its hit (c.sh, hand-placed in the extra dir)" \
   "$(qF "c.sh — exists ONLY in" "$OUT" && echo 0 || echo 1)"
ck "…and it SAYS the preferred record was unusable (the fallback is never silent)" \
   "$(qF "falling back to the install.sh stamp" "$OUT" && echo 0 || echo 1)"

# ⛔ AND WITH **NO STAMP EITHER** — the population this whole half exists for (a hand-placed copy, a farmed
# cell, an operator-synced $O): the record halves abstain, the surface pass answers. The summary must not
# then say "no deployed dir was present to check" about the dir it just listed: `$O_ABSENT` means both
# "no $O" and "no usable record", and the wording must not inherit the second meaning.
# The surface candidates are CLEAN here, so the run reaches the OK summary — a surface hit would exit 1
# first and grade nothing about the message.
deploy
clean_surface="$TMP/clean-harness"; rm -rf "$clean_surface"; mkdir -p "$clean_surface"
cp_ship "$clean_surface"/
bash "$PROVW" write --o "$O" --src "$SRCDIR" --commit "$(git -C "$REPO" rev-parse HEAD)" --ref main --repo "$REPO" >/dev/null 2>&1
chmod 000 "$O/.harness-provenance" 2>/dev/null || true
rm -f "$O/.agent-infra-stamp.json"          # no stamp to fall back to
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome" CELL_HOME="" HARNESS="$clean_surface" HARNESS_PIN_DIR="" \
        HARNESS_PIN_FILE="" DRIFT_PS="$TMP/ps-stub" \
        bash "$DRIFT" --o "$O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
chmod 644 "$O/.harness-provenance" 2>/dev/null || true
ck "no usable record AND no stamp: the surface pass still answers cleanly (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the identity half admits it SKIPPED for lack of a record" \
   "$(qF "identity: SKIPPED" "$OUT" && echo 0 || echo 1)"
ck "…and the run does NOT claim no deployed dir was present (it is present)" \
   "$(qF "no deployed dir was present to check" "$OUT" && echo 1 || echo 0)"
ck "…and it says $O could NOT be identified, so its bytes were NOT verified against a record" \
   "$(qF "could NOT be identified" "$OUT" && echo 0 || echo 1)"
# ⛔ THIS CLEAN ARM EMITS THE TOKEN TOO (round 21, P2). It is the second of the three clean exits, and
# the only one a FARMed or operator-synced box ever reaches; without the token the pass recorded
# `drift=clean:rc=0` and the documented `clean:current` was unreachable on exactly that population.
ck "…and this clean exit also carries harness=current, not a bare rc=0" \
   "$(qF "harness=current" "$OUT" && echo 0 || echo 1)"

echo
echo "── §9f a pathless manifest line is CANNOT-VERIFY here too, not a MISSING named after a hash ──"
# ⛔ `%%` and `#` BOTH RETURN THE WHOLE LINE when the two-space run is absent, so a pathless `<64 hex>`
# line set `rel` to the DIGEST and this reader printed `MISSING <the hash>` — a file it fabricated from a
# field it could not parse. A record line this reader cannot read is CANNOT-VERIFY, never a drift.
deploy
bash "$PROVW" write --o "$O" --src "$SRCDIR" --commit "$(git -C "$REPO" rev-parse HEAD)" --ref main --repo "$REPO" >/dev/null 2>&1
H_A2="$(sed -n 's/^\([0-9a-f]\{64\}\)  a\.sh$/\1/p' "$O/.harness-provenance" 2>/dev/null | head -1)"
ck "the fixture record carries the entry to strip" "$([ -n "$H_A2" ] && echo 0 || echo 1)"
grep -vF "  a.sh" "$O/.harness-provenance" > "$O/.hp.tmp" 2>/dev/null && printf '%s\n' "$H_A2" >> "$O/.hp.tmp" && mv "$O/.hp.tmp" "$O/.harness-provenance"
# `files=` must stay self-consistent, or the self-description arm answers first and the pathless line is
# never reached — the arm would then grade the wrong reader.
NMAN2="$(sed -n '/^[0-9a-f]\{64\}  /p' "$O/.harness-provenance" 2>/dev/null | wc -l | tr -d ' ')"
sed "s/^files=.*/files=$NMAN2/" "$O/.harness-provenance" > "$O/.hp.tmp" 2>/dev/null && mv "$O/.hp.tmp" "$O/.harness-provenance"
run
ck "rc is 2 — the record cannot be read, so nothing about it can be claimed" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and it does NOT fabricate a MISSING file named after the digest" "$(qF "MISSING $H_A2" "$OUT" && echo 1 || echo 0)"
ck "…and it names the real reason (a manifest line with no path)" \
   "$(qF "manifest line with no path" "$OUT" && echo 0 || echo 1)"

echo
echo "── §9g a run with NO \$O compared answers harness=surface, and says nothing was identified ──"
# ⛔ THIS GRADES A POPULATION NO ASSERTION COVERED BEFORE (review of #3090). When `$O` is absent (or a
# `--surface` run finds no readable record for one) every question about `$O` abstains, and the token
# block only runs at all because the SURFACE pass raised `problems` — so the token names a real drift in
# a copy this box carries. ⛔ But NOT necessarily "the OTHER dir": with no record `$O` has no surface
# exclusion, so an `$O` that drifted is itself the dir the `surface:` line names and the token is about
# it (measured; the fixtures here use an ABSENT `$O`, which is why this assertion is sound either way).
# §5b grades the other `surface` shape (a clean `$O` plus a
# hit in another dir) and §9e runs with the surface candidates CLEAN, so it reaches the OK summary and
# prints `harness=current` (⛔ it is NOT "no token at all" — that was THIS arm's state until round 21,
# which is when its assertion arrived (`df1afa843`); round 17 gave the token to the `O_ABSENT -eq 0`
# arm only, so the two arms changed four rounds apart and the round-17 note (`:468-469`) is about the
# OTHER one. Leaving the old wording here told a maintainer that a clean run is tokenless, which is
# exactly the P0). Nothing stated what THIS shape's token is, which is why the README could
# describe `surface` as `Q_BYTES=0`-gated. (This comment previously said the arm "emits `surface`
# because NOTHING was compared" — false, and contradicted by its own fixture needing `c.sh` below:
# `$O`-absent alone emits no token, so the run must have a surface hit to print one at all.)
# ⛔ WHAT IT DOES AND DOES NOT PROVE. It DOES redden (2 arms) if this population's token becomes
# `payload-differs` — measured by mutating the `O_ABSENT` arm to emit it. It does NOT discriminate
# removal of that arm on its own: every reachable `O_ABSENT` run exits non-zero via a surface HIT, and
# the `SURF_HIT && Q_BYTES=0` arm below then answers `surface` identically, so the two are
# observationally redundant here. Say so rather than let a later reader believe this pins the arm.
absent_O="$TMP/definitely-not-here"; rm -rf "$absent_O"
no_o_extra="$TMP/extra-absent"; rm -rf "$no_o_extra"; mkdir -p "$no_o_extra"
cp_ship "$no_o_extra/"
printf '#!/usr/bin/env bash\necho hand-placed\n' > "$no_o_extra/c.sh"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome" CELL_HOME="" HARNESS="$no_o_extra" HARNESS_PIN_DIR="" \
        HARNESS_PIN_FILE="" DRIFT_PS="$TMP/ps-stub" \
        bash "$DRIFT" --o "$absent_O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "rc is 1 — the surface pass answered, and its hit is a drift" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…the identity half reports SKIPPED for the absent \$O" "$(qF "identity: SKIPPED" "$OUT" && echo 0 || echo 1)"
ck "…and the one-line answer is harness=surface" "$(qF "harness=surface" "$OUT" && echo 0 || echo 1)"
ck "…and NOT payload-differs, which would name a question nothing asked" \
   "$(qF "harness=payload-differs" "$OUT" && echo 1 || echo 0)"
# ⛔ AND THE COUNTER-CASE THAT SETTLES WHAT THE TOKEN MEANS (review of #3090, cycle 3; corrected in
# round 21): what this arm must prove is that the CLEAN path never FABRICATES a DRIFT token — the
# `surface` value in particular — because that is the reading a redeploy decision gets made on. It used
# to assert the absence of `harness=` entirely, which was true only before the `O_ABSENT -eq 0` clean arm
# was given `harness=current` (round 17), and which left the documented `drift=clean:current` unreachable
# on the other two clean exits: `harness-apply-pass.sh` fell through its reader to `clean:rc=0`, so
# anything keyed on the documented value could never fire there. The clean exits now ALL carry
# `harness=current` — the token answers "what state is the deployed tree", and `current` is the answer.
# The drift-naming claim this arm exists for is kept explicitly: `surface` must NOT appear.
no_o_clean="$TMP/clean-absent"; rm -rf "$no_o_clean"; mkdir -p "$no_o_clean"
cp_ship "$no_o_clean/"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome" CELL_HOME="" HARNESS="$no_o_clean" HARNESS_PIN_DIR="" \
        HARNESS_PIN_FILE="" DRIFT_PS="$TMP/ps-stub" \
        bash "$DRIFT" --o "$absent_O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "…with \$O absent and a CLEAN surface pass: rc 0 (nothing differs)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the clean path carries the documented token harness=current (not the reader's rc=0 fallback)" \
   "$(qF "harness=current" "$OUT" && echo 0 || echo 1)"
ck "…and it fabricates NO drift token on a clean pass (harness=surface names a drift; there is none)" \
   "$(qF "harness=surface" "$OUT" && echo 1 || echo 0)"

echo
echo "── §10 THE EXECUTING TREE: read from the PROCESS, never from a record about it (#10114) ──"
# ⛔ THIS IS THE ARM'S REFUSAL TEST, AND IT IS THE WHOLE POINT OF THE CHANGE. Every section above
# compares a directory AT REST. Measured on a live cell: the controller ran a harness directory that
# had already been DELETED while `HARNESS-PIN` named a different commit, and the run printed
# `OK: every harness dir on this box matches origin/main` and exited 0 — because the running dir was
# pushed into the candidate list from inside a pipeline (a subshell, where `drift` cannot count) and a
# candidate whose dir is ABSENT was then dropped by a bare `continue`. The word "every" excluded the
# only directory that was executing.
#
# Its own fixture repo, because the graded shape needs a dir that can MATCH the ref — and a matching
# dir must carry `orch-loop.sh`, which the fixture above deliberately does not ship.
# ⛔ RESOLVED SPELLING, because the script prints `pwd -P`-normalised candidates (review finding 2).
# Asserting the UNRESOLVED `$TMP` spelling reds on any host whose temp dir is reached through a symlink
# (macOS `/var` -> `/private/var`, a symlinked `$TMPDIR`) while the checker is behaving correctly — the
# class `harness-refresh.test.sh` already measured ("A36 redded there while CI went green").
TMPR="$( cd "$TMP" && pwd -P )"
R2="$TMPR/repo2"; D2="$TMPR/run2"
git init -q -b main "$R2" >/dev/null 2>&1 || { echo "❌ git init failed for fixture2"; exit 2; }
mkdir -p "$R2/scripts/orchestrator-harness" "$D2"
printf '#!/usr/bin/env bash\necho loop\n' > "$R2/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env bash\necho a\n' > "$R2/scripts/orchestrator-harness/a.sh"
( cd "$R2" && $G add -A && $G commit -q -m fixture2 ) >/dev/null 2>&1 || { echo "❌ fixture2 commit failed"; exit 2; }
cp "$R2/scripts/orchestrator-harness/orch-loop.sh" "$R2/scripts/orchestrator-harness/a.sh" "$D2/"
PSH="$TMP/ps-cat"; printf '#!/bin/sh\ncat "$PS_TABLE" 2>/dev/null\nexit 0\n' > "$PSH"; chmod +x "$PSH"
EMPTYHOME6="$TMP/emptyhome6"; mkdir -p "$EMPTYHOME6"
surf() { # <ps-table> [extra HARNESS dir] — an isolated --surface run against fixture2
  OUT="$( cd "$TMP" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="${2:-}" HARNESS_PIN_DIR="" HARNESS_PIN_FILE="" \
          DRIFT_PS="$PSH" PS_TABLE="$1" \
          bash "$DRIFT" --o "$TMP/no-such-deployed" --repo "$R2" --ref main \
               --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
}
# The same run with the CHECKER's cwd and the process-root (`/proc`) both chosen by the arm: the cwd
# because the verdict must not depend on it, the process root because a suite cannot make a live process
# exist. `DRIFT_PROC` is the seam `DRIFT_PS` is: `$PROC/<pid>/cmdline` and `$PROC/<pid>/cwd` are what the
# script reads, and a fake root is how a NUL-separated argv and a relative path are graded on both hosts.
mkdir -p "$TMP/proc-empty"
surf2() { # <checker-cwd> <ps-table> [extra HARNESS dir] [PROC root]
  OUT="$( cd "$1" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="${3:-}" HARNESS_PIN_DIR="" HARNESS_PIN_FILE="" \
          DRIFT_PS="$PSH" PS_TABLE="$2" DRIFT_PROC="${4:-$TMP/proc-empty}" \
          bash "$DRIFT" --o "$TMP/no-such-deployed" --repo "$R2" --ref main \
               --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
}

# (10a) A LIVE CONTROLLER EXECUTING A DIRECTORY THAT NO LONGER EXISTS IS DRIFT — not a skip.
GONE="$TMPR/run-gone/scripts/orchestrator-harness"
printf '4242 bash %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-gone"
surf "$TMP/ps-gone"
# ⛔ WHAT THIS FIXTURE'S PRE-CHANGE CODE DOES, MEASURED, because the label here used to claim more than
# the arm proves (review of #3202, finding 1c): with NO candidate dir the pre-change run exits **2** — the
# gone dir is dropped and the pre-existing empty-candidate refusal fires. "used to print OK" is the
# PRODUCTION state, which needs a clean candidate beside the gone tree; §10m reproduces that exact shape
# (pre-change rc 0 → now rc 1) so the false-green direction has its own discriminating arm.
ck "10a: executing a harness dir that is GONE is DRIFT (rc=$RC), not a skip" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10a: the report says the directory DOES NOT EXIST" "$(qF "DOES NOT EXIST" "$OUT" && echo 0 || echo 1)"
ck "10a: the report NAMES THE PID that is executing it, so an operator can act" "$(qF "pid 4242 is EXECUTING" "$OUT" && echo 0 || echo 1)"
ck "10a: the one-line token is harness=executes:<dir>, not a token about a copy at rest" \
   "$(qF "harness=executes:$GONE" "$OUT" && echo 0 || echo 1)"
ck "10a: …and it is NOT harness=surface (that token's remedy, reseeding a dir, cannot clear a gone tree)" \
   "$(qF "harness=surface" "$OUT" && echo 1 || echo 0)"
ck "10a: the verdict says a redeploy of \$O does not clear it" "$(qF "does not clear it" "$OUT" && echo 0 || echo 1)"
# (10a-2/10a-3) THE INVOCATION PREDICATE IS PINNED IN BOTH DIRECTIONS (agent-infra#10114, review P1).
# Both directions used to fail SILENTLY GREEN: every fixture here spells the invocation with an
# interpreter, and the only mention fixture was the `bash -c` TEXT form. That was tolerable while the
# token was cosmetic; this lane makes an `executes:` token turn a SUCCESSFUL pass into rc 1, so a
# predicate that fabricates a controller reds a healthy box on a timer, and one that drops a real
# controller restores #10114's silent green.
# (10a-2) argv[0] is a direct shebang exec — a real invocation, with no interpreter to lean on.
printf '4252 %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-argv0"
surf "$TMP/ps-argv0"
ck "10a-2: a controller exec'd directly (argv[0], no interpreter) is still an INVOCATION" \
   "$(qF "executes:$GONE" "$OUT" && echo 0 || echo 1)"
# (10a-3) A mere MENTION of the absolute path is NOT an invocation: `grep -n x <abs>/orch-loop.sh` is
# routine agent traffic, and reading it as "this process EXECUTES that tree" is the fabrication.
printf '4253 grep -n x %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-mention"
surf "$TMP/ps-mention"
ck "10a-3: grep on an ABSOLUTE orch-loop.sh path does NOT fabricate a controller" \
   "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
ck "10a-3: …it is reported as a MENTION instead, so the fact is not lost" \
   "$(qF "MENTIONS an orch-loop.sh" "$OUT" && echo 0 || echo 1)"
# (10a-3b) A WORD THAT MERELY *LOOKS* LIKE AN INTERPRETER IS STILL A MENTION (review round 12, P1).
# `_interp` used to be ARMED by any word spelled like a shell, at any position — so the grep PATTERN
# nominated the next absolute path as the executing script. Measured on the round-11 head: every form
# below produced `executes:` on a box running no controller, which (once #10114 makes the token red a
# pass and durable in `drift=`) exits 1 on a HEALTHY box with a false diagnosis. `x` above did not
# catch it because `x` is not a shell name — the class was pinned by one non-shell word only.
for _pat in sh bash env zsh dash busybox; do
  printf '4256 grep -n %s %s/orch-loop.sh\n' "$_pat" "$GONE" > "$TMP/ps-pat-$_pat"
  surf "$TMP/ps-pat-$_pat"
  ck "10a-3b: a grep PATTERN spelled '$_pat' does NOT fabricate a controller" \
     "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
done
# …and the same for an OPTION-introduced pattern, which used to be the keep-arm's blind spot.
printf '4257 grep -i env %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-pat-opt"
surf "$TMP/ps-pat-opt"
ck "10a-3b: 'grep -i env <abs>' does NOT fabricate a controller" \
   "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
# (10a-3b2) THE MENTION CLASS BEHIND A WRAPPER (review round 13, P1 — round 12's fix was MEASURED to
# still fabricate here). Round 12 only pinned `grep` in argv[0] position, so two holes stayed open:
# `env` was in the ARMING list (it is a WRAPPER, not an interpreter), and the wrapper's operand slots
# were consumed by the CHILD COMMAND and its arguments rather than by the wrapper's own operands. Both
# nominated `<GONE>/orch-loop.sh` as the executing tree on a box running no controller — and
# `timeout 300 grep -n sh <pin>/…/orch-loop.sh` is literally the recon command an agent runs over a
# deployed tree. Each form below is now a MENTION.
for _adv in "env cat" "env vim" "env grep -n foo" "cat" "vim" \
            "timeout 300 grep -n sh" "nice -n 5 grep -n sh" "sudo -u deploy grep -n sh" \
            "stdbuf -o0 grep -n sh" "nohup grep -n sh" "env FOO=bar cat" \
            "timeout 300 bash -x other.sh" \
            "sudo -n grep -n sh" "sudo -E grep -rn bash" "sudo -H grep -n sh" \
            "env -i grep -n sh" "env -v grep -n /bin/sh" "nice -5 grep -n sh" \
            "command -v grep -n sh" "timeout 300 -- grep -n sh" "sudo -- grep -n sh"; do
  printf '4259 %s %s/orch-loop.sh\n' "$_adv" "$GONE" > "$TMP/ps-adv"
  surf "$TMP/ps-adv"
  ck "10a-3b2: '$_adv <abs>/orch-loop.sh' is a MENTION, not a controller" \
     "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
done
# (10a-3c) THE PREFIX MUST SURVIVE A WRAPPER'S OPERANDS (review round 12). The fix for 10a-3b must not
# cost these: they are measured launcher shapes and each is a REAL invocation.
for _w in 'nice -n 5 /bin/bash' 'timeout 300 bash' 'sudo -u deploy bash' 'stdbuf -o0 bash' 'env bash' \
          'stdbuf -o L bash' 'sudo -E -u deploy bash' 'env FOO=bar bash' 'bash -lc' \
          'sudo --user deploy bash' 'timeout --signal KILL 300 bash'; do
  printf '4258 %s %s/orch-loop.sh\n' "$_w" "$GONE" > "$TMP/ps-wrap"
  surf "$TMP/ps-wrap"
  ck "10a-3c: '$_w <abs>/orch-loop.sh' is still an INVOCATION" \
     "$(qF "executes:$GONE" "$OUT" && echo 0 || echo 1)"
done
# (10a-3e) LAUNCHERS THE ROUND-13 REWRITE SILENTLY LOST (review round 14, P1/P2). Both were ARMED on
# d708e68ea and became a MENTION on the round-13 head — a live controller on a GONE tree reported as
# nothing at all, which is the silent green #10114 exists to end. Each is a canonical spelling:
#   • `sudo -iu <user> bash` / `sudo -Eu <user> bash` — a COMBINED cluster ending in a value letter,
#     which the bare-2-char claim rule did not recognise, so the user name was read as the COMMAND.
#   • `sudo -c <class> bash` — the `-c` arm fired on the WRAPPER's own option and ate the interpreter.
# They are discriminating: each is `text` on the round-13 head and ARMED here.
for _r in 'sudo -iu deploy bash' 'sudo -Eu deploy bash' 'sudo -c staff bash' \
          'sudo -En bash' 'sudo -Hn bash' 'sudo -Sn bash' 'setsid -c bash' \
          'sudo -n bash' 'sudo -S bash' 'sudo -k bash' 'doas -n bash'; do
  printf '4261 %s %s/orch-loop.sh\n' "$_r" "$GONE" > "$TMP/ps-restored"
  surf "$TMP/ps-restored"
  ck "10a-3e: '$_r <abs>/orch-loop.sh' is still an INVOCATION (round-13/15 regression)" \
     "$(qF "executes:$GONE" "$OUT" && echo 0 || echo 1)"
done
# ⛔ AND A WRAPPER **FLAG** MUST NOT BE CLAIMED AS IF IT TOOK A VALUE (review rounds 15-16, P1).
# Round 14's cluster class included sudo's `n s k e S` — flags, not value-taking options — so
# `sudo -En bash <abs>` claimed `bash` as `-En`'s operand and the launcher became a mention, and
# `sudo -Hn grep bash <abs>` fabricated a controller out of a grep PATTERN. The same defect survived
# in the SINGLE-LETTER arm (`sudo -n bash <abs>`), and `sudo -n` is this repo's default privilege
# prefix in four installers — so the silent green was on the common path. These hold the fabricating
# side; the INVOCATIONS that hold the other side are in 10a-3e above.
for _f in 'sudo -Hn grep bash' 'sudo -En cat sh' 'sudo -n grep -n sh'; do
  printf '4262 %s %s/orch-loop.sh\n' "$_f" "$GONE" > "$TMP/ps-flagcluster"
  surf "$TMP/ps-flagcluster"
  ck "10a-3e: '$_f <abs>/orch-loop.sh' is a MENTION (a wrapper FLAG claims no operand)" \
     "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
done
# ⛔ A PARSE-ONLY RUN IS NOT AN EXECUTION (review round 17, P2). `bash -n <abs>`, `sh -n`, `-D` and any
# short cluster containing `n` (but NOT a wrapper's `-n`, which is ordinary sudo) read the script
# without running it — the INVERSE of the fact `executes:` asserts — yet they nominated the path and
# reddened a healthy box with a durable `drift=drift:executes:`. `bash -o noexec <abs>` was already a
# mention, so one fact had two grades; `_noexec` closes the split.
# ⛔ A SHELL NAME AFTER THE COMMAND PREFIX IS A MENTION, AND A SHELL'S VALUE OPTION IS NOT A FLAG
# (review round 18, P1/P2). `echo sh -c <abs>` used to mark an interpreter as identified (the `_seen`
# branch fired on any word spelled like a shell, at any position) and the `-c` arm then nominated the
# path — a fabricated `executes:` from a mention. And `bash -o pipefail <abs>` was a MENTION because
# every shell option was treated as a flag, so a real launcher on a GONE tree reported nothing.
for _m in 'echo sh -c' 'ssh box sh -c' 'man sh -c'; do
  printf '4264 %s %s/orch-loop.sh\n' "$_m" "$GONE" > "$TMP/ps-shmention"
  surf "$TMP/ps-shmention"
  ck "10a-3e: '$_m <abs>/orch-loop.sh' is a MENTION (no interpreter in command position)" \
     "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
done
# ⛔ `-o noexec` IS A DIFFERENT MECHANISM FROM THE THREE ABOVE, SO IT GETS ITS OWN LABEL (review round
# 19, P2): an interpreter IS in command position there; the mention comes from the shell forbidding
# execution, not from a closed prefix. Sharing one label pointed a reader at the wrong block.
# ⛔ AND ONLY THE MINUS FORM DISABLES EXECUTION: `+o noexec` turns noexec OFF, and `--rcfile noexec`
# never disabled it, so those two are real executions and must stay INVOCATIONS.
printf '4266 bash -o noexec %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-noexec"
surf "$TMP/ps-noexec"
ck "10a-3e: 'bash -o noexec <abs>' is a MENTION (the shell forbids execution)" \
   "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
# ⛔ THE CLUSTER FORM IS A DIFFERENT WORD, AND THE `_optv` VALUE IS WHAT MAKES IT MENTION (round 22,
# P2). The `-o` arm hard-codes `_optv="-o"` precisely because `$_w` here is `-euo`, not `-o` — so the
# noexec-value guard must not depend on the spelling that carried the `o`. Nothing graded that: the
# `-o noexec` case above cannot discriminate, because there `$_w` == `-o` and `_optv="$_w"` would
# agree. Mutation MEASURED: `_optv="$_w"` leaves the case above MENTION but flips
# `bash -euo noexec <abs>` to INVOCATION — a fabricated `executes:` that also masks a real `behind:`,
# since `executes:` leads the token chain — with the suite still 214/0. `-euo` is the canonical bash
# strict-mode cluster, so the spelling is not exotic.
printf '4267 bash -euo noexec %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-noexec-cluster"
surf "$TMP/ps-noexec-cluster"
ck "10a-3e: 'bash -euo noexec <abs>' is a MENTION (a cluster's noexec operand still forbids it)" \
   "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
# ⛔ `-c` IS OWNED BY THE SHELL THAT IS THE CURRENT COMMAND, NOT BY ANY EARLIER ONE (review round 19,
# P2): `_seen` was never cleared, so `bash other.sh -c <abs>` and `busybox grep -c <abs>` nominated a
# path that is a `$1`/grep operand — a fabricated `executes:` that also masks a real `behind:`.
# ⛔ A VALUE-CLAIMING CLUSTER MUST NOT OPEN A FABRICATION (round 21, P1): the operand claim added for
# `-euo pipefail` must not turn the `-c` string's trailing `$0` into a script path, which is the
# 10a-4 fabrication one spelling along.
for _x in 'bash other.sh -c' 'busybox grep -c' 'bash -c x -c' 'bash -lc x -c' 'bash -euo pipefail -c x'; do
  printf '4267 %s %s/orch-loop.sh\n' "$_x" "$GONE" > "$TMP/ps-staleseem"
  surf "$TMP/ps-staleseem"
  ck "10a-3e: '$_x <abs>/orch-loop.sh' is a MENTION (a closed prefix owns no -c string)" \
     "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
done
for _v in 'bash -o pipefail' 'bash -O extglob' 'bash +o noexec' 'bash +o errexit' 'bash --rcfile noexec' \
          'bash -euo pipefail' 'bash -eo pipefail' 'bash -euxo pipefail'; do
  printf '4265 %s %s/orch-loop.sh\n' "$_v" "$GONE" > "$TMP/ps-shopt"
  surf "$TMP/ps-shopt"
  ck "10a-3e: '$_v <abs>/orch-loop.sh' is an INVOCATION (a shell value option claims its operand)" \
     "$(qF "executes:$GONE" "$OUT" && echo 0 || echo 1)"
done
for _p in 'bash -n' 'sh -n' 'bash -D' 'bash -en' 'bash -xn'; do
  printf '4263 %s %s/orch-loop.sh\n' "$_p" "$GONE" > "$TMP/ps-parseonly"
  surf "$TMP/ps-parseonly"
  ck "10a-3e: '$_p <abs>/orch-loop.sh' is a MENTION (parse-only does not execute)" \
     "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
done
# (10a-4) A TRAILING PATH AFTER A `-c` STRING IS `$0`, NOT THE SCRIPT (review VGATE of round 8). The
# `-c` arm advances past the command string, so an ordinary-word guard never sees it: `_interp` stayed
# 1 for the rest of the argv and `bash -c 'sleep 30' <gone>/orch-loop.sh` fabricated `executes:` on a
# healthy box. Reproduced against this script's own seams, and pinned here in both directions.
printf '4254 bash -c sleep_30 %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-ctrail"
surf "$TMP/ps-ctrail"
ck "10a-4: a path AFTER a -c command string is \$0, never the executing tree" \
   "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
printf '4255 bash -c %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-cscript"
surf "$TMP/ps-cscript"
ck "10a-4: but 'bash -c <abs>/orch-loop.sh' IS an invocation and must still count" \
   "$(qF "executes:$GONE" "$OUT" && echo 0 || echo 1)"
# (10a-5) A COMBINED SHORT OPTION INTRODUCES THE COMMAND STRING TOO (review round 9, P1). The arm
# matched `-c` EXACTLY, so `bash -lc 'exec <path>/orch-loop.sh'` kept `_interp=1` for the command
# string, which then matched the script patterns and fabricated `executes:` naming `<cwd>/exec …`.
# `bash -lc '…'` is this repo's own operator idiom, and `executes:` is FIRST in the token chain, so
# the fabricated token also MASKED a real `behind:`/`uncommitted-edit:` on the same box.
printf '4256 bash -lc exec_%s/orch-loop.sh\n' "$GONE" > "$TMP/ps-lc"
surf "$TMP/ps-lc"
ck "10a-5: 'bash -lc exec <abs>/orch-loop.sh' is TEXT, not a fabricated controller" \
   "$(qF "executes:$GONE" "$OUT" && echo 1 || echo 0)"
printf '4257 bash -lc %s/orch-loop.sh\n' "$GONE" > "$TMP/ps-lcpath"
surf "$TMP/ps-lcpath"
ck "10a-5: but 'bash -lc <abs>/orch-loop.sh' IS an invocation (the path is the first word)" \
   "$(qF "executes:$GONE" "$OUT" && echo 0 || echo 1)"
# ⛔ AN EXEC-ONLY DRIFT IS NOT A SURFACE HIT (review of #3202). `drift_q exec` bumps `problems` from inside
# the surface block, so `problems > SURF_BASE` was true for a gone executing tree ALONE — and the summary
# then offered "reseed the copy the RUNNING component uses" directly above "(c) … does not clear it": a
# remedy for a copy at rest, on a box whose executing tree is not there to reseed. `EXEC_N` is incremented
# 1:1 with every exec drift, so the surface delta must exclude it.
ck "10a: an EXEC-ONLY drift does NOT print the surface-hit remedy (there is no copy to reseed)" \
   "$(qF "for a surface hit, reseed" "$OUT" && echo 1 || echo 0)"

# (10b) THE NON-VACUITY PAIR: the same invocation, the controller executing a dir that IS the ref.
printf '4243 bash %s/orch-loop.sh\n' "$D2" > "$TMP/ps-healthy"
surf "$TMP/ps-healthy"
ck "10b: the same box with the controller on a matching tree is rc 0 (10a is not a permanently-red check)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "10b: …and the executing dir is COMPARED and labelled RUNNING, not merely seen" \
   "$(qF "$D2  (RUNNING)" "$OUT" && echo 0 || echo 1)"
ck "10b: …and the run SAYS which pid it read, so the green is attributable" \
   "$(qF "exec: pid 4243 executes $D2" "$OUT" && echo 0 || echo 1)"

# (10c) THE EXECUTING DIR EXISTS BUT IS NOT $REF — the same standard applied to the tree that runs.
D3="$TMPR/run3"
mkdir -p "$D3"
cp "$R2/scripts/orchestrator-harness/orch-loop.sh" "$R2/scripts/orchestrator-harness/a.sh" "$D3/"
printf '#!/usr/bin/env bash\necho stale-loop\n' > "$D3/orch-loop.sh"
printf '4244 bash %s/orch-loop.sh\n' "$D3" > "$TMP/ps-differs"
surf "$TMP/ps-differs"
ck "10c: a RUNNING tree that differs from the ref is DRIFT (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10c: …and the differing file is NAMED against the dir the controller executes" \
   "$(qF "orch-loop.sh — DIFFERS in $D3" "$OUT" && echo 0 || echo 1)"

# (10d) FAIL-CLOSED: a path that cannot be EXAMINED is BROKEN (2), never "nothing to report".
# ⛔ WHAT THIS ARM DOES **NOT** PROVE, STATED SO THE NEXT READER DOES NOT TRUST IT (review of #3202,
# measured): the exit code was **already 2 pre-change**, with AND without the clean candidate — on
# `origin/main` the executing dir is pushed into `cand-raw` unconditionally and the PRE-EXISTING
# candidate BRK (`candidate harness dir … cannot be examined`) fires on it. So `[ "$RC" -eq 2 ]` is
# regression coverage, not a discriminator, and the earlier "pre-change: rc 0" note here was false.
# What DOES discriminate is the second assertion: `grep -qF` is case-sensitive and pre-change prints
# lowercase "examined", while the new arm prints "cannot be EXAMINED" and names the pid. Both are
# asserted below, plus the negative that pins WHICH arm answered — the generic candidate filter must not
# be the one that reds this run, because that filter is exactly what used to drop the executing dir.
ln -s "$TMP/definitely-not-a-target" "$TMP/dangling-run" 2>/dev/null || true
printf '4245 bash %s/dangling-run/orch-loop.sh\n' "$TMP" > "$TMP/ps-dangling"
surf "$TMP/ps-dangling" "$D2"
ck "10d: an UNEXAMINABLE executing path is exit 2 (rc=$RC) over an otherwise CLEAN box" \
   "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "10d: …and the report says it cannot be EXAMINED" "$(qF "cannot be EXAMINED" "$OUT" && echo 0 || echo 1)"
ck "10d: …and it NAMES the pid executing it, so the executing-path arm is the one that answered" \
   "$(qF "pid 4245 is executing" "$OUT" && echo 0 || echo 1)"
ck "10d: …and the GENERIC candidate filter did not answer (it must not be the arm that reds this run)" \
   "$(qF "candidate harness dir" "$OUT" && echo 1 || echo 0)"

# (10e) AN EXECUTING DIR THAT STILL EXISTS BUT CARRIES NO SHIPPED FILE IS NOT DROPPED (review finding 1).
# The deterministic sibling of 10a: the process outlives the scripts (a deleted script is held open by
# the running interpreter), so the dir exists and the generic "is this a harness dir?" filter skipped it
# with a bare `continue` — after already printing that it was "compared against $REF below".
# ⛔ THE ASSERTION NAMES THE DECLARED EXTENSION SET, not the literal `*.sh` (#4015): the message a box's
# operator reads has to say WHAT was looked for, or a `.py`-only tree reads as "no scripts" when the
# truth is "no shipped file of any kind".
D4="$TMPR/run4"; mkdir -p "$D4"
printf '4246 bash %s/orch-loop.sh\n' "$D4" > "$TMP/ps-empty-dir"
surf "$TMP/ps-empty-dir" "$D2"
ck "10e: an executing dir with NO readable *.sh is DRIFT (rc=$RC), not silently filtered out" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10e: …and the token names the executing dir" "$(qF "harness=executes:$D4" "$OUT" && echo 0 || echo 1)"
ck "10e: …and it says the script the live process started from is GONE" \
   "$(qF "NO readable shipped file" "$OUT" && echo 0 || echo 1)"
ck "10e: …and the message NAMES the extensions it looked for (not a bare '*.sh')" \
   "$(qF "*.py" "$OUT" && echo 0 || echo 1)"
# ⛔ AND THE REMEDY ROW, WHICH IS THE LINE AN OPERATOR ACTUALLY ACTS ON (review finding 2, PR #4038).
# `DRIFT(exec)` was widened while the `(c) executing tree` remedy beneath it still said "NO readable
# *.sh" — the same defect (a message naming fewer extensions than the check covers) one paragraph
# down, in the row that tells the reader what to do about it. Pinned here so it cannot silently
# regress to a single-suffix claim.
ck "10e: …and the (c) REMEDY row names the same set, not a bare '*.sh'" \
   "$(qF '(c) executing tree' "$OUT" && qF 'NO readable shipped file (*.sh, *.py, *.mjs)' "$OUT" && echo 0 || echo 1)"

# (10f) THE ARGV SPELLINGS THE POSITIONAL READ DROPPED (review of #3202). `ps -eo command=` writes the
# `/usr/bin/env` form for a wrapped controller, and the parse this replaces required the shell at `t[1]`
# and the script at `t[2]` — so this row answered "no controller found" while the tree it executed was
# GONE, and the run printed OK / rc 0. Measured on the pre-change script: rc 0; here: rc 1 + the token.
GONE2="$TMPR/run-gone-env/scripts/orchestrator-harness"
printf '4247 /usr/bin/env bash %s/orch-loop.sh\n' "$GONE2" > "$TMP/ps-env"
surf "$TMP/ps-env" "$D2"
ck "10f: a controller launched as 'env bash <dir>/orch-loop.sh' is READ, not dropped (rc=$RC; pre-change rc 0)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10f: …and the token names that dir" "$(qF "harness=executes:$GONE2" "$OUT" && echo 0 || echo 1)"

# (10g) `bash -c <abs>/orch-loop.sh` — the second spelling it dropped (`t[2]` was `-c`).
GONE3="$TMPR/run-gone-c/scripts/orchestrator-harness"
printf '4248 bash -c %s/orch-loop.sh\n' "$GONE3" > "$TMP/ps-bash-c"
surf "$TMP/ps-bash-c" "$D2"
ck "10g: a controller launched as 'bash -c <dir>/orch-loop.sh' is READ (rc=$RC; pre-change rc 0)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10g: …and the token names that dir" "$(qF "harness=executes:$GONE3" "$OUT" && echo 0 || echo 1)"

# (10h) THE CONTROL THAT KEEPS THE WIDER SCAN HONEST: a shell running TEXT that mentions a path is NOT a
# controller (the self-match class the fleet inventory documents; `harness-cohesion.test.sh` (iv-g) pins
# the same fact). Without this arm "scan every element" could red the box for another lane's `echo`.
printf '4249 bash -c echo-bash-%s/orch-loop.sh\n' "$D2" > "$TMP/ps-text2"
surf "$TMP/ps-text2" "$D2"
ck "10h: a shell running TEXT that mentions an orch-loop.sh is NOT a controller (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "10h: …and the report SAYS it saw the mention and did not count it (never silently ignored)" \
   "$(qF "MENTIONS an orch-loop.sh" "$OUT" && echo 0 || echo 1)"

# (10i) A RELATIVE SCRIPT PATH BELONGS TO THE **CONTROLLER's** cwd, NOT THE CHECKER's (review of #3202).
# The checker runs FROM $R2 — a tree whose `scripts/orchestrator-harness/orch-loop.sh` exists and MATCHES
# the ref — so a parser that resolves the relative path against OUR cwd answers OK / rc 0. Two fakes:
# (a) the process's own cwd is UNREADABLE ⇒ BROKEN (2), never a green from our own tree;
# (b) the process's own cwd is READABLE and names a tree that DIFFERS ⇒ the DRIFT names THAT tree.
mkdir -p "$TMP/proc-rel-a" "$TMP/proc-rel-b/4250"
printf '4250 bash scripts/orchestrator-harness/orch-loop.sh\n' > "$TMP/ps-rel"
surf2 "$R2" "$TMP/ps-rel" "$D2" "$TMP/proc-rel-a"
ck "10i: an UNRESOLVABLE relative script path is BROKEN (rc=$RC), never read against the CHECKER's cwd" \
   "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "10i: …and the refusal names the reason (a relative path is the controller's, not ours)" \
   "$(qF "could not be resolved" "$OUT" && echo 0 || echo 1)"
printf 'bash\0scripts/orchestrator-harness/orch-loop.sh\0' > "$TMP/proc-rel-b/4250/cmdline"
ln -s "$D3" "$TMP/proc-rel-b/4250/cwd"
surf2 "$R2" "$TMP/ps-rel" "$D2" "$TMP/proc-rel-b"
ck "10i: …and when the controller's own cwd IS readable, THAT tree is the one compared (rc=$RC)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10i: …the drift names the CONTROLLER's tree, not the checker's" "$(qF "$D3" "$OUT" && echo 0 || echo 1)"

# (10j) A HARNESS PATH CONTAINING A SPACE — `~/Library/Application Support/…` on macOS. `ps` flattens the
# command line, so a whitespace split cut this path into fragments whose tail does not exist and dropped
# it; the NUL-separated `cmdline` keeps every element whole (review of #3202).
SPACED="$TMPR/run gone dir/scripts/orchestrator-harness"
mkdir -p "$TMP/proc-space/4251"
printf 'bash\0%s/orch-loop.sh\0' "$SPACED" > "$TMP/proc-space/4251/cmdline"
printf '4251 bash %s/orch-loop.sh\n' "$SPACED" > "$TMP/ps-space"
surf2 "$TMP" "$TMP/ps-space" "$D2" "$TMP/proc-space"
ck "10j: a harness path with a SPACE is read whole from the cmdline (rc=$RC; pre-change rc 0)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10j: …and the token names the whole path" "$(qF "harness=executes:$SPACED" "$OUT" && echo 0 || echo 1)"

# (10k) A FAILED `ps` READ IS ONE ANSWER, NOT TWO (review of #3202): the run printed
# `UNKNOWN: the process table could not be read …` and then `running: no controller was found … (nothing is
# executing a harness on this box right now)` — the second contradicting the first in one report.
printf '#!/bin/sh\nexit 1\n' > "$TMP/ps-fail"; chmod +x "$TMP/ps-fail"
OUT="$( cd "$TMP" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="$D2" HARNESS_PIN_DIR="" HARNESS_PIN_FILE="" \
        DRIFT_PS="$TMP/ps-fail" \
        bash "$DRIFT" --o "$TMP/no-such-deployed" --repo "$R2" --ref main \
             --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "10k: an UNREADABLE process table is BROKEN (rc=$RC) even with a clean candidate dir" \
   "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "10k: …and the run does NOT also claim no controller was found (the two lines contradict)" \
   "$(qF "no controller was found" "$OUT" && echo 1 || echo 0)"

# (10l) A BROKEN RUN MUST NOT ALSO CLAIM IT ANSWERED RED (review of #3202, measured). `EXEC_N>0` does not
# exclude `broken=1`: a second `brk` (here: an unreadable pin record) leaves `cand` empty, so the
# relaxation's note fired on a run that then took the BROKEN arm and exited 2 — one report saying "this run
# is RED, not unverified" and "this box's harness state is UNVERIFIED" at once. The exit code was right on
# both sides of the change; the SENTENCE was the defect. MEASURED against the reviewed head (150e105e3,
# this fix's own pre-change): the first assertion passes there and the SECOND reds — the note is printed —
# so the arm discriminates for exactly the defect it names. Against `origin/main` the whole executing-tree
# arm is absent, so there is no such note to suppress and the negative is satisfied by construction; the
# companion assertions pin that the fix is silence on the CLAIM, not the loss of the measured DRIFT(exec)
# fact or of the token-bearing arm.
ln -s "$TMP/definitely-not-a-target" "$TMP/dangling-pin" 2>/dev/null || true
OUT="$( cd "$TMP" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="" HARNESS_PIN_DIR="" \
        HARNESS_PIN_FILE="$TMP/dangling-pin" DRIFT_PS="$PSH" PS_TABLE="$TMP/ps-gone" \
        bash "$DRIFT" --o "$TMP/no-such-deployed" --repo "$R2" --ref main \
             --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "10l: an unreadable pin record + a GONE executing dir is BROKEN (rc=$RC), not a verdict" \
   "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "10l: …and it does NOT claim 'this run is RED, not unverified' over a BROKEN pass (the two contradict)" \
   "$(qF "RED, not unverified" "$OUT" && echo 1 || echo 0)"
ck "10l: …and the measured DRIFT(exec) fact is still REPORTED (silence on the claim, not on the finding)" \
   "$(qF "DRIFT(exec): pid 4242 is EXECUTING" "$OUT" && echo 0 || echo 1)"
ck "10l: …and the run says UNVERIFIED once, in the summary that decides the exit code" \
   "$(qF "harness state is UNVERIFIED" "$OUT" && echo 0 || echo 1)"

# (10m) THE PRODUCTION FALSE GREEN, REPRODUCED (review of #3202, finding 1c). §10a's fixture refuses with
# or without the fix; the box this PR was written for carries a HEALTHY copy beside the controller whose
# tree is gone. Measured on `origin/main` with this exact table and `$D2` supplied: `OK: every harness dir
# on this box matches …`, **rc 0** — the gone dir is pushed into `cand-raw` and then dropped by a bare
# `continue`, so the word "every" excluded the one directory that is executing. At this head: rc 1 and
# `harness=executes:<gone dir>`. This is the arm that discriminates the false-green direction against
# `origin/main`; §10a/§10d/§10e discriminate against the reviewed head (150e105e3) and against a future
# regression of the same arms.
surf "$TMP/ps-gone" "$D2"
ck "10m: a GONE executing tree beside a CLEAN copy is DRIFT (rc=$RC; pre-change rc 0 = the false green)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "10m: …and the run does NOT print the 'every harness dir … matches' green over it" \
   "$(qF "every harness dir on this box matches" "$OUT" && echo 1 || echo 0)"
ck "10m: …and the token names the GONE dir, not the clean copy beside it" \
   "$(qF "harness=executes:$GONE" "$OUT" && echo 0 || echo 1)"

echo
echo "── §11 A POST-DEPLOY LOSS OF THE EXEC BIT IS DRIFT, NAMED — a blob has no mode (#4003) ──"
# ⛔ THE CLASS THIS GRADES: a script that is PRESENT, BYTE-IDENTICAL and UNRUNNABLE. `git hash-object`
# hashes CONTENT; the mode lives in the tree ENTRY, so a 0644 copy of a 0755 script hashes identically
# and the byte half graded GREEN over a dispatcher the loop cannot exec — measured on this fleet:
# `nonblocking-dispatch.sh`, 36,175 B, `-rw-r--r--`, the dispatch path dead while every instrument read
# clean. The deploy half of #4003 stops the bit being CREATED wrong; this half is the only thing that can
# see a bit lost AFTER a good deploy (a restore, a `cp` without `-p`, a tarball, an `rsync` without
# `--perms`, a `core.fileMode=false` checkout).
# ⛔ ITS OWN FIXTURE REPO. A 100755 entry added to `$REPO` would join `repo-sh` and change the population
# every arm above counts (the surface fixtures copy only a.sh/b.sh), so this repo exists to keep that
# population still.
MREPO="$TMP/mode-repo"; MO="$TMP/mode-O"
MSRC="$MREPO/scripts/orchestrator-harness"
mkdir -p "$MSRC" "$MO"
printf '#!/usr/bin/env bash\necho dispatch\n' > "$MSRC/nonblocking-dispatch.sh"   # tracked 100755
printf '#!/usr/bin/env bash\necho plain\n'      > "$MSRC/plain.sh"               # tracked 100644
chmod +x "$MSRC/nonblocking-dispatch.sh"
git init -q -b main "$MREPO" >/dev/null 2>&1 || { echo "❌ git init failed for the mode fixture"; exit 2; }
( cd "$MREPO" && $G add -A && $G commit -q -m mode ) >/dev/null 2>&1
ck "§11 fixture: nonblocking-dispatch.sh is tracked 100755" \
   "$([ "$(git -C "$MREPO" ls-tree HEAD -- scripts/orchestrator-harness/nonblocking-dispatch.sh | cut -d' ' -f1)" = 100755 ] && echo 0 || echo 1)"
ck "§11 fixture: plain.sh is tracked 100644 (the negative — a 644 source is NEVER a mode finding)" \
   "$([ "$(git -C "$MREPO" ls-tree HEAD -- scripts/orchestrator-harness/plain.sh | cut -d' ' -f1)" = 100644 ] && echo 0 || echo 1)"
mdeploy() {   # byte-identical to the ref AND carrying the ref's mode: a deploy the box completed
  rm -rf "$MO"; mkdir -p "$MO"
  cp "$MSRC/nonblocking-dispatch.sh" "$MSRC/plain.sh" "$MO/" || return 1
  chmod +x "$MO/nonblocking-dispatch.sh"
  bash "$PROVW" write --o "$MO" --src "$MSRC" --ref main --repo "$MREPO" >/dev/null 2>&1
}
mrun() { OUT="$(bash "$DRIFT" --o "$MO" --repo "$MREPO" --ref main --rel scripts/orchestrator-harness --no-fetch 2>&1)"; RC=$?; }
mdeploy || { echo "❌ could not deploy the mode fixture"; exit 2; }

# ⛔ THE FALSE-RED CHECK, AND IT MUST BE THE FIRST ARM: a box whose BYTES AND MODES both match reports
# GREEN. This is the arm that keeps the new one from being "a check that reddens a healthy fleet", and
# without it a mode arm that fired on everything would pass §11b by accident.
ck "§11 fixture: plain.sh IS deployed non-executable (so the green below is not vacuous)" \
   "$([ ! -x "$MO/plain.sh" ] && echo 0 || echo 1)"
mrun
ck "§11a: bytes AND modes match ⇒ rc 0 — a healthy box stays GREEN" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "§11a: …the verdict is OK, and NO mode finding is fabricated" \
   "$( { qF "OK: deployed" "$OUT" && ! qF "NOT EXECUTABLE" "$OUT"; } && echo 0 || echo 1)"

# ⛔ THE DEFECT, PLANTED. `chmod -x` on the deployed copy only: the bytes stay the ref's exactly, which
# is the whole point — nothing a blob SHA can see has changed.
chmod -x "$MO/nonblocking-dispatch.sh"
ck "§11 planted mode loss: the deployed bytes are still IDENTICAL to the ref's (cmp — the detection below cannot be coming from bytes)" \
   "$(cmp -s "$MSRC/nonblocking-dispatch.sh" "$MO/nonblocking-dispatch.sh" && echo 0 || echo 1)"
mrun
ck "§11b: a source 100755 that \$O cannot exec is DRIFT — rc 1" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "§11b: …the report NAMES the unrunnable file, not a count" \
   "$(qF 'nonblocking-dispatch.sh — the deployed copy is NOT EXECUTABLE' "$OUT" && echo 0 || echo 1)"
ck "§11b: …and it names the deployed MODE it read, so the finding is evidence" \
   "$(qF 'mode -rw-r--r--' "$OUT" && echo 0 || echo 1)"
ck "§11b: …the token is harness=not-executable:<file> — its own state, not a byte claim" \
   "$(qF 'harness=not-executable:nonblocking-dispatch.sh' "$OUT" && echo 0 || echo 1)"
# ⛔ THE TWO FINDINGS MUST NOT COLLAPSE INTO ONE. `payload-differs` is defined as "the BYTES differ from
# the checkout", which is FALSE here (they are identical), and its remedy ("redeploy to adopt") tells an
# operator nothing about the missing bit. Both negative assertions below redden if this arm is folded
# back into the byte half or its token.
ck "§11b: …it is NOT reported as a byte difference (the bytes are the ref's — that claim would be false)" \
   "$(qF 'DIFFERS from the repo at' "$OUT" && echo 1 || echo 0)"
ck "§11b: …and the token is NOT payload-differs" \
   "$(qF 'harness=payload-differs' "$OUT" && echo 1 || echo 0)"
ck "§11b: …and the remedy is PASTABLE — it names the real path, not a placeholder" \
   "$(qF "chmod +x '$MO/nonblocking-dispatch.sh'" "$OUT" && echo 0 || echo 1)"

# ⛔ THE CONTROL PAIRED WITH §11b, one `chmod` apart on the SAME fixture: the check is not stuck red.
chmod +x "$MO/nonblocking-dispatch.sh"
mrun
ck "§11c: restoring the bit returns the verdict to OK (the arm is not permanently red)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ⛔ THE BYTE HALF IS UNCHANGED. One byte in the 644 script — no mode involved anywhere — must still be
# caught by the arm that caught it before this change.
printf '#!/usr/bin/env bash\necho plaiN\n' > "$MO/plain.sh"
mrun
ck "§11d: a BYTE difference is still detected (rc 1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
# ⛔ EITHER BYTE-QUESTION ARM MAY ANSWER, AND BOTH ARE THE BYTES QUESTION: with a provenance record the
# edit is `(a)` ("an UNCOMMITTED EDIT" — it knows which side moved); with only a stamp there is no
# manifest, so `(b)` names it as `DIFFERS from the repo at`. What must NOT change is that a one-byte
# defect is still caught and the file is still NAMED — the arm below pins the naming, and its sibling
# pins that the mode arm did not answer a byte defect.
ck "§11d: …and still reported by the BYTES question, naming the file (not by the mode arm)" \
   "$(qF 'plain.sh' "$OUT" && { qF 'DIFFERS from the repo at' "$OUT" || qF 'plain.sh — UNCOMMITTED EDIT' "$OUT"; } && echo 0 || echo 1)"
ck "§11d: …and NOT as harness=not-executable (that arm must not answer a byte defect)" \
   "$(qF 'harness=not-executable' "$OUT" && echo 1 || echo 0)"
mdeploy   # leave the fixture clean for any arm added later

# ⛔ THE REVERSE POLARITY, ASSERTED RATHER THAN IMPLIED. An executable copy of a `100644` source is NOT a
# finding: git stores only 644/755, so `+x` on a plain script breaks nothing, and a check that reddened
# it would redden boxes for a reason no deploy can explain. Without this arm the one-way-ness is only
# visible by reading the code.
chmod +x "$MO/plain.sh"
mrun
ck "§11e: an EXECUTABLE copy of a 100644 source is NOT reported (the arm is one-way, not a mode diff)" \
   "$([ "$RC" -eq 0 ] && ! qF 'NOT EXECUTABLE' "$OUT" && echo 0 || echo 1)"
mdeploy

echo
echo "── §12 THE DECLARED EXTENSION SET: a .py driver is COMPARED, not invisible (agent-infra#4015/#3016) ──"
# ⛔ THE DEFECT THIS GRADES, MEASURED: the byte arm listed the repo with
# `grep -E "^${REL}/[^/]+\.sh$"`, so `gh-limit.py`, `gh-cred.py`, `objective.py` and every other python
# driver in the harness dir were never in the compared set — in EITHER direction. A box running a stale
# `$O/gh-limit.py` printed `OK: deployed … matches` and exited 0 while `install.sh` names that exact file
# as the one whose absence silently unserialised every harness `gh` call (#2041). So the arm below
# plants a ONE-BYTE change in the `.py` driver, leaves every `.sh` untouched, and requires RED.
# ⛔ AND IT IS GRADED ON A STAMP-ONLY RECORD ON PURPOSE. The provenance manifest (question (a)) already
# walks the source recursively, so a `.py` edit is caught there and this arm would pass without the
# byte comparison ever being widened — a test that cannot distinguish the fix from the thing it
# replaced. `deploy()` writes the STAMP, whose `payloadSha256` folds `*.sh` only, so ONLY the widened
# byte arm can answer this fixture.
deploy
run
ck "12a: control — a clean box with a .py driver is still rc 0" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
printf '#!/usr/bin/env python3\nprint("driver v2")\n' > "$O/driver.py"
run
ck "12a: a STALE .py driver in \$O is DRIFT (rc=$RC; pre-change rc 0 = the false green #3016 records)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "12a: …and the report NAMES driver.py as the file that differs" \
   "$(qF 'driver.py — the deployed copy DIFFERS' "$OUT" && echo 0 || echo 1)"
ck "12a: …and it is not called OK (a silent .py must never read as a match)" \
   "$(q 'OK: deployed' "$OUT" && echo 1 || echo 0)"

# 12b — the OTHER direction, which a one-way copy check cannot see: a `.py` in `$O` the repo does not
# ship. The `.sh` half already had this arm (`a hand-placed or retired script`); the declared set makes
# the `.py` half symmetric, and a hand-placed driver is the class that survives a redeploy silently.
deploy
printf '#!/usr/bin/env python3\nprint("local only")\n' > "$O/local-only.py"
run
ck "12b: an EXTRA .py in \$O is DRIFT (rc=$RC), not 'not shipped by the repo' ignored" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "12b: …and it is NAMED as present-but-not-shipped" \
   "$(qF 'local-only.py — present in' "$OUT" && qF 'but NOT shipped by the repo at' "$OUT" && echo 0 || echo 1)"

# 12c — MISSING: a `.py` the repo ships that `$O` does not have. Graded because the enumerator change
# (repo side) and the deployed-side enumerator are SEPARATE lists; a fix to one alone leaves the other
# measuring the old set, and only this direction reds that.
deploy
rm -f "$O/driver.py"
run
ck "12c: a MISSING .py the repo ships is DRIFT (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "12c: …and it is named MISSING from \$O" \
   "$(qF 'driver.py — shipped by the repo at' "$OUT" && echo 0 || echo 1)"

# 12d — the `--surface` arm reads the SAME declared set, so a candidate dir carrying a stale `.py` is a
# surface drift too. Without this arm the extension list could be widened in the `$O` comparison and
# still leave the ARM THAT READS THE RUNNING CONTROLLER'S TREE comparing `*.sh` only.
# ⛔ ITS OWN FIXTURE REPO, deliberately: `$R2` (the §10 fixture) must keep shipping no `.py`, or every
# §10 candidate dir would drift as MISSING and the §10 arms would stop grading what they were written
# to grade. This fixture ships exactly the two files this arm needs.
R11="$TMPR/repo11"; D11="$TMPR/run11"
git init -q -b main "$R11" >/dev/null 2>&1 || { echo "❌ git init failed for fixture11"; exit 2; }
mkdir -p "$R11/scripts/orchestrator-harness" "$D11"
printf '#!/usr/bin/env bash\necho loop\n' > "$R11/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env python3\nprint("driver v1")\n' > "$R11/scripts/orchestrator-harness/driver.py"
( cd "$R11" && $G add -A && $G commit -q -m fixture11 ) >/dev/null 2>&1 || { echo "❌ fixture11 commit failed"; exit 2; }
cp "$R11/scripts/orchestrator-harness/orch-loop.sh" "$D11/"
printf '#!/usr/bin/env python3\nprint("branch local")\n' > "$D11/driver.py"
printf '4249 bash %s/orch-loop.sh\n' "$D11" > "$TMP/ps-py"
OUT="$( cd "$TMP" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="$D11" HARNESS_PIN_DIR="" HARNESS_PIN_FILE="" \
        DRIFT_PS="$PSH" PS_TABLE="$TMP/ps-py" \
        bash "$DRIFT" --o "$TMP/no-such-deployed" --repo "$R11" --ref main \
             --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "12d: a stale .py in the RUNNING dir is DRIFT (rc=$RC) via --surface" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "12d: …and the surface line NAMES driver.py against that dir" \
   "$(qF 'driver.py — DIFFERS in' "$OUT" && echo 0 || echo 1)"
ck "12d: …and it is attributed to the RUNNING controller, not to a copy at rest" \
   "$(qF '(RUNNING)' "$OUT" && echo 0 || echo 1)"
# The control: the SAME fixture with the ref's bytes in place is rc 0 — so 12d redded for the `.py`
# difference and not for the fixture being shaped in a way the surface arm refuses.
cp "$R11/scripts/orchestrator-harness/driver.py" "$D11/driver.py"
OUT="$( cd "$TMP" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="$D11" HARNESS_PIN_DIR="" HARNESS_PIN_FILE="" \
        DRIFT_PS="$PSH" PS_TABLE="$TMP/ps-py" \
        bash "$DRIFT" --o "$TMP/no-such-deployed" --repo "$R11" --ref main \
             --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "12d: …and restoring the ref's .py returns rc 0 (the .py was the only difference)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

# 12e — THE DECLARATION DECIDES THE COMPARISON, PROVEN BEHAVIOURALLY (review finding 1, PR #4038).
# ⛔ THE FALSE PASS THIS PINS, MEASURED ON THE FIRST VERSION OF THIS PR: `HARNESS_EXTS` was declared as
# "the ONE place", but the three comparisons read a HAND-WRITTEN `HARNESS_EXT_RE='sh|py|mjs'` beside it
# while only the human-readable message was derived from the declaration. Adding `ts` to the one line
# the file points at would have widened the MESSAGES and left the comparison at three extensions — the
# check would state it looked for a set it did not look for, and pass. That is #4015's own defect one
# level down, so it is graded by BEHAVIOUR rather than by reading the constants: patch ONE line of a
# copy of the script to declare a fourth extension the fixture actually ships, and require the stale
# file of that kind to be caught. On the diverged text this arm is rc 0 (the `.ts` is never compared) —
# i.e. the arm discriminates the defect, not merely the presence of the constants.
R12="$TMPR/repo12"; D12="$TMPR/run12"
git init -q -b main "$R12" >/dev/null 2>&1 || { echo "❌ git init failed for fixture12"; exit 2; }
mkdir -p "$R12/scripts/orchestrator-harness" "$D12"
printf '#!/usr/bin/env bash\necho loop\n' > "$R12/scripts/orchestrator-harness/a.sh"
printf 'export const v = 1\n' > "$R12/scripts/orchestrator-harness/wrapper.ts"
( cd "$R12" && $G add -A && $G commit -q -m fixture12 ) >/dev/null 2>&1 || { echo "❌ fixture12 commit failed"; exit 2; }
cp "$R12/scripts/orchestrator-harness/a.sh" "$R12/scripts/orchestrator-harness/wrapper.ts" "$D12/"
# A truthful stamp, or the run answers UNKNOWN (2) for lack of a record and grades nothing. Its fold is
# `*.sh`-only by contract, exactly as in `deploy()` — so the `.ts` can only be seen by the byte arm.
{ _pay="$( ( cd "$D12" && for f in *.sh; do $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
  printf '{\n "commit": "%s",\n "payloadSha256": "%s",\n "agentInfraDirty": false\n}\n' \
    "$(git -C "$R12" rev-parse HEAD)" "$_pay" > "$D12/.agent-infra-stamp.json"; }
# The patch touches the DECLARATION ONLY — if one line is not enough, the declaration is not the place.
WIDENED="$TMP/widened-drift.sh"
sed 's/^HARNESS_EXTS="sh py mjs"$/HARNESS_EXTS="sh py mjs ts"/' "$DRIFT" > "$WIDENED" \
  || { echo "❌ could not build the widened copy"; exit 2; }
ck "12e: the widened copy really declares the fourth extension (the patch landed)" \
   "$(qF 'HARNESS_EXTS="sh py mjs ts"' "$(cat "$WIDENED")" && echo 0 || echo 1)"
printf 'export const v = 2\n' > "$D12/wrapper.ts"       # ONE stale file of the newly declared kind
OUT="$( bash "$WIDENED" --o "$D12" --repo "$R12" --ref main \
        --rel scripts/orchestrator-harness --no-fetch 2>&1 )"; RC=$?
ck "12e: a stale file of a DECLARED extension is caught (rc=$RC; diverged text = rc 0, never compared)" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "12e: …and it is NAMED, so the widened set is the one that answered" \
   "$(qF 'wrapper.ts — the deployed copy DIFFERS' "$OUT" && echo 0 || echo 1)"
# ⛔ THE MESSAGE IS GRADED THROUGH A REAL MESSAGE PATH, not by re-reading the constants: the byte arm's
# report names the FILE and never the set, so a text assertion here would pin nothing an operator sees.
# The `DRIFT(exec)` line is where the set is spoken — so run the WIDENED copy's `--surface` arm over a
# running dir carrying no shipped file, and require the derived glob to carry the fourth extension.
D12e="$TMPR/run12e"; mkdir -p "$D12e"
printf '4250 bash %s/orch-loop.sh\n' "$D12e" > "$TMP/ps-ts"
OUT="$( cd "$TMP" && HOME="$EMPTYHOME6" CELL_HOME="" HARNESS="$D12e" HARNESS_PIN_DIR="" HARNESS_PIN_FILE="" \
        DRIFT_PS="$PSH" PS_TABLE="$TMP/ps-ts" \
        bash "$WIDENED" --o "$TMP/no-such-deployed" --repo "$R12" --ref main \
             --rel scripts/orchestrator-harness --no-fetch --surface 2>&1 )"; RC=$?
ck "12e: …and the operator message names the WIDENED set, derived from the one declaration" \
   "$(qF '*.sh, *.py, *.mjs, *.ts' "$OUT" && echo 0 || echo 1)"
# The control: the UNPATCHED script must NOT see the `.ts`, so this arm is proven to be about the
# declaration and not about `.ts` happening to be noticed anyway.
OUT="$( bash "$DRIFT" --o "$D12" --repo "$R12" --ref main \
        --rel scripts/orchestrator-harness --no-fetch 2>&1 )"; RC=$?
ck "12e: …and the SHIPPED declaration does not compare .ts (rc=$RC — the fix is the declaration)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

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
# ⛔ …AND THE COMPLEMENT: derivation means the RUNNER NAMES NO SUITE. Pinning both halves makes a
# re-added `run_shard` row (the #2838 regression) go red HERE, not only in tests/ci-lane-parity.
ck "…and the runner carries NO enumerated run_shard row for it (derivation, not enumeration)" \
   "$(grep -qE '^[[:space:]]*run_shard[[:space:]]+scripts/orchestrator-harness/check-deployed-drift\.test\.sh' "$SHARDS" && echo 1 || echo 0)"

echo
printf 'check-deployed-drift delta self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
